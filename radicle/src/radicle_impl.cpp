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
// LocalWriter. Making them instance members and threading them through the
// constructor is the minimum change that fixes that: production code (the
// module registration, which default-constructs a RadicleImpl) is unaffected,
// and a test can now build one after arranging its own environment.
RadicleImpl::RadicleImpl(radicle::SeedClient seed, radicle::LocalStore local)
    : m_seed(std::move(seed))
    , m_local(std::move(local))
    // Built from LocalStore's resolved home so RAD_HOME/HOME resolution lives
    // in exactly one place. Captured here, at construction, exactly as the
    // old statics captured it on first use.
    , m_localReader(m_local.home())
    , m_localWriter(m_local.home())
{
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

    nlohmann::json out{
        {"localAvailable",         localAvailable},
        {"localNodeRunning",       localAvailable && m_local.nodeRunning()},
        {"canWriteLocal",          canWrite},
        {"writeUnavailableReason", writeReason},
        {"remoteSeed",             m_seed.seedUrl()},
        {"remoteReachable",        m_seed.reachable()},
        {"remoteApiVersion",       m_seed.apiVersion()},
        {"nodeId",                 localAvailable ? m_local.nodeId() : std::string{}},
    };
    return dump(out);
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

    // Derived from the repo document rather than added to the FFI surface,
    // exactly as `SeedClient::listBranches` derives it from `getRepo`. The
    // local backend already returns `refs.refs` in the same shape, so a
    // dedicated Rust entry point would be a second implementation of one
    // filter — and a second place for the two sources to drift apart.
    //
    // branchesFromRawJson() is what does the parse-then-derive: see its doc
    // comment in seed_client.h for why this is a free function rather than
    // inlined here (in short: so the malformed-JSON branch is directly
    // testable, since the real Rust backend can never produce it).
    return dump(radicle::branchesFromRawJson(m_localReader.getRepo(rid)));
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
