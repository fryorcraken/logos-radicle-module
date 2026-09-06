#include "radicle_impl.h"

#include <nlohmann/json.hpp>

#include <utility>

namespace {

/// Public seeds offered in a picker when the user has no local config.
const char* const kBuiltinSeeds[][2] = {
    {"https://seed.radicle.xyz",     "seed.radicle.xyz"},
    {"https://iris.radicle.network", "iris.radicle.network"},
    {"https://rosa.radicle.network", "rosa.radicle.network"},
};

std::string dump(const nlohmann::json& j)
{
    return j.dump();
}

} // namespace

// ===========================================================================
// Construction
// ===========================================================================
//
// m_seed, m_local, m_localReader and m_localWriter used to be function-local
// `static`s here: built once per process on first use, never rebuilt. That
// made the class untestable — a test's ScopedRadHome (which points RAD_HOME
// at a scratch directory) only affected whichever test happened to touch a
// given singleton first, since every later construction of a RadicleImpl in
// the same process would see the same, already-built LocalStore/LocalReader/
// LocalWriter. Making them instance members fixed that; see radicle_impl.h
// for why dependency injection is a separate, private, non-constructor method
// (setDependenciesForTest()) rather than a second constructor overload — a
// second public `RadicleImpl(...)` broke the real build, not just the unit
// tests, because this module's dispatch table is derived by scanning this
// class's `public:` section and treats ANY public constructor named
// `RadicleImpl` as a bogus zero-arg RPC method.
namespace {

/// Build the LocalStore the persisted settings ask for.
///
/// This is where mode selection actually takes effect. Before Phase 1 the home
/// was whatever the environment named, fixed for the process lifetime; now the
/// settings choose it, and the environment is the fallback rather than the
/// authority.
///
/// Seed-only deliberately yields a store with NO home. That is not a
/// degenerate case to work around — it is the mode's definition: a user who
/// has chosen to browse a seed over HTTP has said they do not want this module
/// touching a local profile, and silently reading one anyway would be the
/// module ignoring an explicit choice.
radicle::LocalStore storeForSettings(const radicle::SettingsStore& settings)
{
    const auto mode = settings.get(radicle::SettingsStore::kKeyMode);
    if (mode == radicle::SettingsStore::kModeSeedOnly)
        return radicle::LocalStore{radicle::NodePaths{}};

    return radicle::LocalStore{radicle::resolvePathsFromEnv(
        settings.get(radicle::SettingsStore::kKeyRadHome),
        settings.get(radicle::SettingsStore::kKeyRadSocket),
        // The Basecamp profile name would scope the socket per profile. This
        // module is not told which profile it is in, so the socket falls back
        // to $XDG_RUNTIME_DIR/radicle.sock — still short by construction, and
        // still independent of the home, which is the property that matters.
        // Two profiles sharing one runtime dir would collide here; setting
        // radSocket explicitly is the escape hatch, and is why that setting
        // exists rather than being derived.
        "")};
}

} // namespace

// The init list below follows radicle_impl.h's member declaration order, which
// is itself a dependency chain rather than an arbitrary layout: settings decide
// the home (that is what mode selection is), the home decides the store, and
// the reader/writer are built from the store. See the comment on those members.
RadicleImpl::RadicleImpl()
    : m_settings(radicle::settingsPathFromEnv())
    , m_seed()
    // Settings are read BEFORE the local store is built, because they decide
    // which home it points at. That ordering is the whole of mode selection.
    , m_local(storeForSettings(m_settings))
    , m_localReader(m_local.home())
    , m_localWriter(m_local.home())
{
    // A persisted seed must survive a restart — that is the cheapest proof the
    // settings store works, and it is behaviour users could see missing before.
    const auto seed = m_settings.get(radicle::SettingsStore::kKeyRemoteSeed);
    if (!seed.empty()) m_seed.setSeedUrl(seed);

    // The one process-global write, done here and nowhere else: before any
    // thread exists, once. See radicle_ffi.h for why PATH is the only channel
    // that reaches Radicle's six bare-name `git` spawn sites, and why that
    // forces restart-to-apply semantics on the gitPath setting.
    //
    // A failure is deliberately not fatal and not reported here: the module
    // still reads local storage fine without git (reads never spawn it), and
    // getCapabilities() reports gitFound/gitProblem so a view can explain the
    // consequence — no writes — at the point it matters.
    const auto gitPath = m_settings.get(radicle::SettingsStore::kKeyGitPath);
    if (!gitPath.empty()) radicle::LocalReader::applyGitPath(gitPath);
}

void RadicleImpl::setDependenciesForTest(radicle::SeedClient seed, radicle::LocalStore local,
                                         radicle::SettingsStore settings)
{
    m_seed = std::move(seed);
    m_local = std::move(local);
    m_settings = std::move(settings);
    // Rebuilt from the new LocalStore's home, exactly as the constructor
    // above builds them the first time — a test that changes `local`
    // (typically after pointing RAD_HOME at a scratch directory) must see
    // its reader/writer follow, not keep reading whatever home the
    // zero-arg constructor resolved first.
    m_localReader = radicle::LocalReader(m_local.home());
    m_localWriter = radicle::LocalWriter(m_local.home());
}

namespace {

/// Uniform "there is no local profile here" error.
///
/// Reached only when detection fails — no ~/.radicle, or one with no storage/
/// directory. Once a profile exists the call goes to the backend, which
/// reports its own, more specific failure ("repository X not found locally",
/// "this repository has no README") rather than this blanket one. Keeping the
/// two apart matters: "you have no node" and "that repo isn't here" prompt
/// different actions from a user.
std::string localUnavailable(const radicle::LocalStore& local)
{
    return dump(radicle::makeError(local.unavailableReason()));
}

} // namespace

// ===========================================================================
// Capability & configuration
// ===========================================================================

std::string RadicleImpl::getCapabilities()
{
    const bool localAvailable = m_local.available();

    // `canWriteLocal` is a real probe, not a build flag. A read needs only the
    // public key; a write needs the private half, which comes from a plaintext
    // keystore, RAD_PASSPHRASE, or ssh-agent — and when none of them yields
    // one, no write can succeed no matter how the UI is wired.
    //
    // The reason is carried alongside because a view has to explain the
    // absence: "you have a node but cannot sign" and "you have no node" prompt
    // completely different actions from a user, and collapsing both into a
    // missing button explains neither. Probing here, once, is also what lets a
    // view refuse to *offer* a compose box rather than accepting text and
    // failing on submit.
    bool canWrite = false;
    std::string writeReason = m_local.unavailableReason();
    if (localAvailable) {
        // writeCapabilityFrom() is what does the parse-then-collapse: see its
        // doc comment in seed_client.h for why this is a free function
        // rather than inlined here (in short: so both branches — a granted
        // write and a refused one — are directly testable, since LocalWriter
        // has no fake seam and a real granted write needs a signing key no
        // test here can arrange).
        const auto cap = radicle::writeCapabilityFrom(m_localWriter.canWrite());
        canWrite = cap["canWrite"].get<bool>();
        writeReason = cap["writeUnavailableReason"].get<std::string>();
    }

    // The NID comes from the Rust backend rather than LocalStore, and comes
    // from the PUBLIC half of the keystore rather than from the signer. Both
    // choices matter: deriving it here would mean base64-decoding an SSH blob
    // and base58-encoding the result, which the `radicle` crate already does;
    // and reading it via the signer would make the identity disappear exactly
    // when the key is locked — the case where a user is most likely to be
    // confused about which identity they are operating as.
    std::string nodeId;
    if (localAvailable) {
        const auto id = nlohmann::json::parse(m_localReader.nodeId(), nullptr, false);
        if (!id.is_discarded()) nodeId = id.value("nodeId", "");
    }

    // Which node this module is pointed at, and whether this build can run it.
    // Reported unconditionally — a view has to be able to say "you are in
    // Embedded mode and the daemon is not implemented yet" rather than showing
    // an empty repository list that looks like a node with nothing in it.
    const auto mode = m_settings.get(radicle::SettingsStore::kKeyMode);
    const bool startable = radicle::SettingsStore::modeIsStartable(mode);
    std::string modeReason;
    if (!startable) {
        modeReason = "Embedded mode is selected but this build cannot start a "
                     "node yet — the embedded daemon arrives in a later "
                     "milestone. Browsing a seed still works; switch to Attach "
                     "to use a Radicle node you already run.";
    }

    // The git preflight. Not cosmetic: Radicle spawns git to read and write
    // storage, so no git means no writes, and in a sandboxed bundle that is
    // the most likely failure of all.
    const auto git = nlohmann::json::parse(
        radicle::LocalReader::gitProbe(m_settings.get(radicle::SettingsStore::kKeyGitPath)),
        nullptr, false);
    const bool gitFound = !git.is_discarded() && git.value("found", false);

    nlohmann::json out{
        {"localAvailable",         localAvailable},
        {"localNodeRunning",       localAvailable && m_local.nodeRunning()},
        {"canWriteLocal",          canWrite},
        {"writeUnavailableReason", writeReason},
        {"remoteSeed",             m_seed.seedUrl()},
        {"remoteReachable",        m_seed.reachable()},
        {"remoteApiVersion",       m_seed.apiVersion()},
        {"nodeId",                 nodeId},

        {"mode",                   mode},
        {"modeStartable",          startable},
        {"modeUnavailableReason",  modeReason},
        {"radHome",                m_local.home()},
        {"radSocket",              m_local.socket()},
        {"pathsProblem",           m_local.pathsProblem()},

        {"gitFound",               gitFound},
        {"gitPath",                git.is_discarded() ? "" : git.value("path", "")},
        {"gitVersion",             git.is_discarded() ? "" : git.value("version", "")},
        {"gitConfigured",          !git.is_discarded() && git.value("configured", false)},
        {"gitProblem",             gitFound ? std::string{}
                                            : (git.is_discarded()
                                                   ? std::string("the git preflight gave an "
                                                                 "unreadable answer")
                                                   : git.value("reason", ""))},
    };
    return dump(out);
}

std::string RadicleImpl::getSettings()
{
    return dump(m_settings.all());
}

std::string RadicleImpl::setSetting(const std::string& key, const std::string& value)
{
    const auto result = m_settings.set(key, value);
    if (radicle::isError(result)) return dump(result);

    // Changing the mode or the home repoints this instance at a different
    // profile, so the store and its reader/writer are rebuilt now rather than
    // at next launch. Without this the setting would be persisted and inert
    // until restart — which is defensible for gitPath (a process-global PATH
    // write that cannot safely happen mid-run) but not for the home, where
    // nothing prevents rebuilding and a stale reader would answer for the
    // previous profile.
    if (key == radicle::SettingsStore::kKeyMode
        || key == radicle::SettingsStore::kKeyRadHome
        || key == radicle::SettingsStore::kKeyRadSocket) {
        m_local = storeForSettings(m_settings);
        m_localReader = radicle::LocalReader(m_local.home());
        m_localWriter = radicle::LocalWriter(m_local.home());
        // Which node is in use is exactly what this event exists to announce.
        localAvailabilityChanged(getCapabilities());
    }

    if (key == radicle::SettingsStore::kKeyRemoteSeed && !value.empty()) {
        // Only the URL is adopted here; validation against the live seed is
        // setRemoteSeed's job. Doing it here too would put a network round trip
        // on a settings write and give two places an opinion about what makes a
        // seed acceptable.
        m_seed.setSeedUrl(value);
        remoteSeedChanged(value);
    }

    return dump(result);
}

std::string RadicleImpl::setRemoteSeed(const std::string& seedUrl)
{
    if (seedUrl.empty())
        return dump(radicle::makeError("seed URL is required"));

    const std::string previous = m_seed.seedUrl();
    m_seed.setSeedUrl(seedUrl);

    const nlohmann::json index = m_seed.probe();
    if (radicle::isError(index)) {
        m_seed.setSeedUrl(previous);   // keep the last known-good seed
        return dump(index);
    }

    remoteSeedChanged(m_seed.seedUrl());

    return dump(nlohmann::json{
        {"seed",       m_seed.seedUrl()},
        {"apiVersion", m_seed.apiVersion()},
        {"nid",        index.value("nid", "")},
    });
}

std::string RadicleImpl::listKnownSeeds()
{
    nlohmann::json items = nlohmann::json::array();
    for (const auto& s : kBuiltinSeeds) {
        items.push_back({{"url", s[0]}, {"alias", s[1]}, {"source", "builtin"}});
    }

    // NOTE: `preferredSeeds` from ~/.radicle/config.json is deliberately NOT
    // merged in. Those are peer-to-peer addresses (port 8776); the JSON API we
    // proxy to is radicle-httpd on :443, a separate service many seeds simply
    // do not run. Listing them implied they were browsable when they were not
    // — selecting one showed the previous seed's data under its name. A user
    // whose own seed does serve the API can add it explicitly with
    // setRemoteSeed().

    return dump(nlohmann::json{{"items", items}});
}

// ===========================================================================
// REMOTE — proxied to a public seed over HTTPS
// ===========================================================================

std::string RadicleImpl::remoteListRepos(const std::string& query, int64_t page, int64_t perPage)
{
    return dump(radicle::paginate(m_seed.listRepos(query, page, perPage), page, perPage));
}

std::string RadicleImpl::remoteGetRepo(const std::string& rid)
{
    return dump(m_seed.getRepo(rid));
}

std::string RadicleImpl::remoteListBranches(const std::string& rid)
{
    return dump(m_seed.listBranches(rid));
}

std::string RadicleImpl::remoteGetTree(const std::string& rid, const std::string& sha,
                                       const std::string& path)
{
    return dump(m_seed.getTree(rid, sha, path));
}

std::string RadicleImpl::remoteGetBlob(const std::string& rid, const std::string& sha,
                                       const std::string& path)
{
    return dump(m_seed.getBlob(rid, sha, path));
}

std::string RadicleImpl::remoteGetReadme(const std::string& rid, const std::string& sha)
{
    return dump(m_seed.getReadme(rid, sha));
}

std::string RadicleImpl::remoteListCommits(const std::string& rid, const std::string& sha,
                                           int64_t page, int64_t perPage)
{
    return dump(radicle::paginate(m_seed.listCommits(rid, sha, page, perPage), page, perPage));
}

std::string RadicleImpl::remoteGetCommit(const std::string& rid, const std::string& sha)
{
    return dump(m_seed.getCommit(rid, sha));
}

std::string RadicleImpl::remoteListIssues(const std::string& rid, const std::string& status,
                                          int64_t page, int64_t perPage)
{
    return dump(radicle::paginate(m_seed.listIssues(rid, status, page, perPage), page, perPage));
}

std::string RadicleImpl::remoteGetIssue(const std::string& rid, const std::string& id)
{
    return dump(m_seed.getIssue(rid, id));
}

std::string RadicleImpl::remoteListPatches(const std::string& rid, const std::string& status,
                                           int64_t page, int64_t perPage)
{
    return dump(radicle::paginate(m_seed.listPatches(rid, status, page, perPage), page, perPage));
}

std::string RadicleImpl::remoteGetPatch(const std::string& rid, const std::string& id)
{
    return dump(m_seed.getPatch(rid, id));
}

// ===========================================================================
// LOCAL — the local node's storage, read in-process through the Rust backend.
//
// Each method is a two-step: refuse early when there is no profile at all,
// otherwise hand off to LocalReader, which owns the FFI boundary and returns
// the finished JSON. The shapes match the remote* methods above byte for byte
// — that is the contract radicle_impl.h states, and the reason a view renders
// either source without branching.
//
// Read-only. Nothing here signs, writes, or contacts the node daemon, so it
// works offline and with the node stopped.
// ===========================================================================

std::string RadicleImpl::localListRepos(const std::string& scope, int64_t page, int64_t perPage)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.listRepos(scope, page, perPage);
}

std::string RadicleImpl::localGetRepo(const std::string& rid)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.getRepo(rid);
}

std::string RadicleImpl::localListBranches(const std::string& rid)
{
    if (!m_local.available()) return localUnavailable(m_local);

    // This used to derive the list from `getRepo`'s `refs.refs` via
    // `branchesFromRawJson`, exactly as `SeedClient::listBranches` derives it,
    // on the reasoning that one filter over one shape leaves the two sources
    // no room to drift. That reasoning assumed the two sources were reporting
    // the same thing. They are not: `refs.refs` is the *canonical*
    // `refs/heads/*`, which in local storage holds a single
    // delegate-consensus ref, while every peer's branches — including this
    // node's own — live under `refs/namespaces/<nid>/`. The derived version
    // therefore reported exactly one branch for every repository on the
    // machine.
    //
    // The namespaced refs cannot just be folded into `refs.refs` instead:
    // `resolveSha` reads that same map to turn a name into a commit, so
    // widening it would change what an unqualified branch name resolves to.
    // Branches get their own reply from the local backend; `refs.refs` keeps
    // its canonical meaning. See `local::list_branches` for the shape.
    //
    // `branchesFromRawJson` therefore has no caller on this path any more. It
    // is deliberately left in place: it is still `SeedClient`-side logic with
    // its own tests, and the malformed-reply branch it was extracted to make
    // testable is a property of the seed path too.
    return m_localReader.listBranches(rid);
}

std::string RadicleImpl::localGetTree(const std::string& rid, const std::string& sha,
                                      const std::string& path)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.getTree(rid, sha, path);
}

std::string RadicleImpl::localGetBlob(const std::string& rid, const std::string& sha,
                                      const std::string& path)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.getBlob(rid, sha, path);
}

std::string RadicleImpl::localGetReadme(const std::string& rid, const std::string& sha)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.getReadme(rid, sha);
}

std::string RadicleImpl::localListCommits(const std::string& rid, const std::string& sha,
                                          int64_t page, int64_t perPage)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.listCommits(rid, sha, page, perPage);
}

std::string RadicleImpl::localGetCommit(const std::string& rid, const std::string& sha)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.getCommit(rid, sha);
}

std::string RadicleImpl::localListIssues(const std::string& rid, const std::string& status,
                                         int64_t page, int64_t perPage)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.listIssues(rid, status, page, perPage);
}

std::string RadicleImpl::localGetIssue(const std::string& rid, const std::string& id)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.getIssue(rid, id);
}

std::string RadicleImpl::localListPatches(const std::string& rid, const std::string& status,
                                          int64_t page, int64_t perPage)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.listPatches(rid, status, page, perPage);
}

std::string RadicleImpl::localGetPatch(const std::string& rid, const std::string& id)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localReader.getPatch(rid, id);
}

// ===========================================================================
// LOCAL WRITES — the only methods here that change state.
//
// The same two-step as the reads above: refuse early when there is no profile,
// otherwise hand off to the backend, which reports its own more specific
// failure. The extra failure a write has and a read does not is "no usable
// signing key", and that one is reported by the Rust side, not here, because
// only it can tell an encrypted keystore from an absent agent.
// ===========================================================================

std::string RadicleImpl::localCommentOnIssue(const std::string& rid, const std::string& id,
                                             const std::string& body)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localWriter.commentOnIssue(rid, id, body);
}

std::string RadicleImpl::localCreateIssue(const std::string& rid, const std::string& title,
                                          const std::string& description)
{
    if (!m_local.available()) return localUnavailable(m_local);
    return m_localWriter.createIssue(rid, title, description);
}
