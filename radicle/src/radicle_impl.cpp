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
/// Explore deliberately yields a store with NO home. That is not a degenerate
/// case to work around — it is the mode's definition: a user who has chosen to
/// browse a seed over HTTP has said they do not want this module touching a
/// local profile, and silently reading one anyway would be the module ignoring
/// an explicit choice.
///
/// **Embedded resolves a home of its own, and never reads the environment to
/// find it.** `embeddedHomeFor()` derives it from Basecamp's per-profile XDG
/// data dir alone — the same rule the settings file uses, so the two are
/// separated per Basecamp profile by construction. It deliberately has no
/// branch that could reach `RAD_HOME` or `$HOME/.radicle`.
///
/// That absence is the mode's whole promise made structural. Embedded means "a
/// SEPARATE identity from any node you already run"; a resolution that could
/// fall through to the environment would give the user their EXISTING node's
/// DID in the chrome, their existing repositories, and writes enabled against
/// them, all under a segment reading "Embedded" — and worse, would put two nodes
/// on one git storage. This mode used to do exactly that, by falling through a
/// bare `return`, which is why every mode is named explicitly below.
///
/// Note the home is resolved whether or not anything is there yet. An embedded
/// home with no identity in it is not an error state — it is the state before
/// the wizard has run — so `localAvailable` is false and
/// `unavailableReason()` says so in words that fit this mode (see
/// `NodePaths::absentProfileReason`), rather than telling a user whose whole
/// reason for choosing Embedded is not owning `rad` to go and run `rad auth`.
///
/// **Every mode that resolves a home is named explicitly, and the fall-through
/// is the INERT case.** This comment used to claim the opposite was already
/// true — "every mode is named, so adding a fourth is a compile-time visit" —
/// while the code named only Explore and Embedded and let everything else,
/// Local included, reach the environment through a bare trailing `return`. So
/// an unrecognised mode inherited Local's behaviour exactly: the attached
/// profile's home, `localAvailable: true`, full read access, all under a mode
/// name the UI has no segment for. That is the same identity confusion the
/// Embedded paragraph above describes, reached through a corrupt settings file
/// rather than through the picker, and the false comment is most of why it
/// survived review.
///
/// The direction of the default is the whole fix. A trailing `return` that
/// reads the environment makes "unhandled" mean "read the user's node"; one
/// that yields empty paths makes it mean "do nothing". A mode this function has
/// not been taught about is by definition one whose intended behaviour is
/// unknown, and the only safe guess about a node identity is not to claim one.
///
/// `SettingsStore::load()` also refuses to hand out an unknown mode at all, so
/// in practice this branch is reached only by a KNOWN mode that a future change
/// adds to `settings_store.h` and forgets to add here. Both halves are wanted:
/// the store stops the corrupt-file case, and this stops the forgetful-edit
/// case. Neither subsumes the other.
radicle::LocalStore storeForSettings(const radicle::SettingsStore& settings)
{
    const auto mode = settings.get(radicle::SettingsStore::kKeyMode);

    if (mode == radicle::SettingsStore::kModeLocal)
        return radicle::LocalStore{radicle::resolvePathsFromEnv(
            settings.get(radicle::SettingsStore::kKeyRadHome),
            settings.get(radicle::SettingsStore::kKeyRadSocket),
            // The Basecamp profile name would scope the socket per profile.
            // This module is not told which profile it is in, so the socket
            // falls back to $XDG_RUNTIME_DIR/radicle.sock — still short by
            // construction, and still independent of the home, which is the
            // property that matters. Two profiles sharing one runtime dir would
            // collide here; setting radSocket explicitly is the escape hatch,
            // and is why that setting exists rather than being derived.
            "")};

    if (mode == radicle::SettingsStore::kModeEmbedded) {
        const std::string home = radicle::embeddedHomeFromEnv();

        // **An unresolvable embedded home is inert, and this guard is the whole
        // of that.** It is not defensive tidiness — without it this mode aliases
        // the user's own profile, which is the exact failure the mode exists to
        // prevent.
        //
        // The mechanism is a composition, which is why it survived review of
        // each half. `embeddedHomeFor()` reads only the XDG data dir and returns
        // "" when neither XDG_DATA_HOME nor HOME is set — correct in isolation,
        // and pinned by `no_environment_at_all_yields_no_embedded_home`. But an
        // empty `configuredHome` is exactly what `resolveHome()` treats as "not
        // configured", so it falls through to RAD_HOME and then to
        // $HOME/.radicle. Passing the empty string straight in therefore hands
        // Embedded whatever node the environment names.
        //
        // An earlier comment here claimed the home "comes from the XDG data dir
        // alone — never from the environment — so this can never resolve to the
        // user's own profile". True of `embeddedHomeFor()`; false of this call,
        // and false in the one direction that matters. That is the same shape as
        // step 1's `Keystore::init` claim: a load-bearing comment asserting a
        // safety property the code does not have is worse than no comment,
        // because a reader who trusts it stops checking.
        //
        // Reachable wherever HOME is not propagated but RAD_HOME is — a
        // misconfigured `[basecamp.env]`, shell inheritance, a future
        // profile-launch regression. `scaffold.toml` always sets XDG_DATA_HOME
        // today, but that makes the bug improbable rather than impossible, and
        // the structural argument must not rest on it implicitly.
        //
        // `getEmbeddedIdentity()` and `createEmbeddedIdentity()` already guard
        // this same emptiness explicitly; this was the one path that did not.
        if (home.empty()) {
            radicle::NodePaths paths;
            paths.absentProfileReason =
                "no embedded Radicle home could be resolved — this module keeps "
                "it under the Basecamp profile's data directory, and neither "
                "XDG_DATA_HOME nor HOME is set, so there is nowhere to put one.";
            return radicle::LocalStore{std::move(paths)};
        }

        // The home is passed explicitly, so `resolveHome()` returns it rather
        // than consulting the environment at all — which is only true because
        // of the guard above.
        //
        // The socket is resolved exactly as Local's is, which is the point of
        // `resolveSocket` taking the home as its LAST resort rather than its
        // first: Basecamp's data dir is far past the 108-byte cap, and
        // $XDG_RUNTIME_DIR keeps the socket short regardless of how long the
        // home is. See docs/M3-phase0-findings.md §6.
        auto paths = radicle::resolvePathsFromEnv(
            home, settings.get(radicle::SettingsStore::kKeyRadSocket), "");
        paths.absentProfileReason =
            "no embedded identity yet — Basecamp keeps its own Radicle home at "
            + paths.home
            + " and has not created an identity in it. This is a separate "
              "identity from any Radicle node you already run.";
        return radicle::LocalStore{std::move(paths)};
    }

    if (mode == radicle::SettingsStore::kModeExplore)
        return radicle::LocalStore{radicle::NodePaths{}};

    // Unknown, or known-but-unmapped. Inert.
    return radicle::LocalStore{radicle::NodePaths{}};
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
    // The writer takes the store's SOCKET as well as its home: the announce
    // step needs it, and the store is the one place that resolves it.
    , m_localWriter(m_local.home(), m_local.socket())
{
    adoptPersistedSettings();

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

void RadicleImpl::adoptPersistedSettings()
{
    // A persisted seed must survive a restart — that is the cheapest proof the
    // settings store works, and it is behaviour users could see missing before.
    const auto seed = m_settings.get(radicle::SettingsStore::kKeyRemoteSeed);
    if (!seed.empty()) m_seed.setSeedUrl(seed);
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
    m_localWriter = radicle::LocalWriter(m_local.home(), m_local.socket());

    // And adoption runs again over the injected settings and seed client, so
    // the instance a test holds is the one a restart would produce. Without
    // this the constructor's adoption was overwritten by the injection and the
    // only test covering it had to set the value it then asserted — a test that
    // stayed green with the adoption deleted. See adoptPersistedSettings().
    adoptPersistedSettings();
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

    // The startable SET, not just a boolean about the mode in force. A picker
    // draws three rows and has to annotate each one *before* it is chosen; the
    // boolean cannot answer that, because in `explore` — the default — it is
    // true and says nothing whatever about Embedded. Deriving the set from it
    // left the Embedded row uncaveated in exactly the state every new user
    // starts in. See SettingsStore::startableModes().
    nlohmann::json startableModes = nlohmann::json::array();
    for (const auto& m : radicle::SettingsStore::startableModes())
        startableModes.push_back(m);

    // Phrased from the mode's own name rather than hardcoding "Embedded".
    // Today embedded is the only unstartable mode, so the two read identically
    // — but a hardcoded sentence becomes silently wrong the moment that stops
    // being true, and nothing would report it.
    //
    // The modes it suggests instead come from the constants for the same
    // reason: this sentence used to spell out "Attach", and when the mode
    // vocabulary was unified with the UI's it would have gone on confidently
    // recommending a mode that no longer exists, with nothing going red.
    std::string modeReason;
    if (!startable) {
        modeReason = "the '" + mode + "' mode is selected but this build cannot "
                     "start that node yet — it arrives in a later milestone. '"
                     + radicle::SettingsStore::kModeExplore + "' still browses a "
                     "seed, and '" + radicle::SettingsStore::kModeLocal
                     + "' uses a Radicle node you already run.";
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
        {"startableModes",         startableModes},
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
        m_localWriter = radicle::LocalWriter(m_local.home(), m_local.socket());
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
// EMBEDDED IDENTITY
//
// Neither method takes a home. That is the safety property: a home parameter
// would be a way for a caller to point KEY CREATION at the user's real
// ~/.radicle, and no caller should ever want to. The path is resolved here,
// from the XDG data dir alone.
// ===========================================================================

std::string RadicleImpl::getEmbeddedIdentity()
{
    const std::string home = radicle::embeddedHomeFromEnv();

    if (home.empty()) {
        return dump(nlohmann::json{
            {"home",    ""},
            {"exists",  false},
            {"nodeId",  ""},
            // Not an {"error":...} object: the question was answered, and the
            // answer is that there is nowhere to put an identity. A caller has
            // to render that as a blocked wizard step rather than as a failed
            // call it might retry.
            {"problem", "no data directory found for this module (set "
                        "XDG_DATA_HOME or HOME), so there is nowhere to keep an "
                        "embedded Radicle home"},
        });
    }

    const auto probe =
        nlohmann::json::parse(radicle::LocalReader::profileExists(home), nullptr, false);
    const bool exists = !probe.is_discarded() && probe.value("exists", false);

    // Read only when there is something to read. `nodeId` on an empty home
    // reports its own "no key" reason, which would be a second, worse-worded
    // answer to a question `exists` has already answered.
    std::string nodeId;
    if (exists) {
        radicle::LocalReader reader{home};
        const auto id = nlohmann::json::parse(reader.nodeId(), nullptr, false);
        if (!id.is_discarded()) nodeId = id.value("nodeId", "");
    }

    return dump(nlohmann::json{
        {"home",    home},
        {"exists",  exists},
        {"nodeId",  nodeId},
        {"problem", ""},
    });
}

std::string RadicleImpl::createEmbeddedIdentity(const std::string& alias,
                                                const std::string& passphrase)
{
    const std::string home = radicle::embeddedHomeFromEnv();
    if (home.empty()) {
        return dump(radicle::makeError(
            "no data directory found for this module (set XDG_DATA_HOME or "
            "HOME), so there is nowhere to create an embedded Radicle home"));
    }

    // Every refusal — occupied home, half-created home, bad alias, relative
    // path — is the backend's, and its messages are passed through verbatim
    // rather than paraphrased. They name the consequence and the path to act
    // on; a second opinion here could only drift from what is enforced.
    const std::string reply = radicle::LocalReader::initProfile(home, alias, passphrase);

    const auto parsed = nlohmann::json::parse(reply, nullptr, false);
    if (parsed.is_discarded() || radicle::isError(parsed)) return reply;

    // The new identity has to be visible without a restart, but ONLY if this
    // instance is actually pointed at the embedded home. Rebuilding
    // unconditionally would repoint a module sitting in Local at a home the
    // user did not ask it to read — the same repointing `setSetting` does
    // deliberately, done here as a side effect of an unrelated action.
    //
    // The mode is deliberately NOT switched. Choosing a mode is the user's, and
    // moving the whole UI underneath someone who only meant to set an embedded
    // node up for later is a control doing more than it said.
    if (m_settings.get(radicle::SettingsStore::kKeyMode)
        == radicle::SettingsStore::kModeEmbedded) {
        m_local = storeForSettings(m_settings);
        m_localReader = radicle::LocalReader(m_local.home());
        m_localWriter = radicle::LocalWriter(m_local.home(), m_local.socket());
        // Which identity is in force is exactly what this event announces, and
        // it has just changed from none to one.
        localAvailabilityChanged(getCapabilities());
    }

    return reply;
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
