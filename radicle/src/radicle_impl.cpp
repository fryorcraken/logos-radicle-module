#include "radicle_impl.h"

#include "local_reader.h"
#include "local_store.h"
#include "seed_client.h"

#include <nlohmann/json.hpp>

namespace {

/// Default public seed. Overridable at runtime via setRemoteSeed().
constexpr const char* kDefaultSeed = "https://seed.radicle.xyz";

/// Public seeds offered in a picker when the user has no local config.
const char* const kBuiltinSeeds[][2] = {
    {"https://seed.radicle.xyz",     "seed.radicle.xyz"},
    {"https://iris.radicle.network", "iris.radicle.network"},
    {"https://rosa.radicle.network", "rosa.radicle.network"},
};

radicle::SeedClient& seed()
{
    static radicle::SeedClient client{kDefaultSeed};
    return client;
}

radicle::LocalStore& local()
{
    static radicle::LocalStore store;
    return store;
}

std::string dump(const nlohmann::json& j)
{
    return j.dump();
}

radicle::LocalReader& localReader()
{
    // Built from LocalStore's resolved home so RAD_HOME/HOME resolution lives
    // in exactly one place. Constructed on first use, after LocalStore has
    // read the environment.
    static radicle::LocalReader reader{local().home()};
    return reader;
}

/// Uniform "there is no local profile here" error.
///
/// Reached only when detection fails — no ~/.radicle, or one with no storage/
/// directory. Once a profile exists the call goes to the backend, which
/// reports its own, more specific failure ("repository X not found locally",
/// "this repository has no README") rather than this blanket one. Keeping the
/// two apart matters: "you have no node" and "that repo isn't here" prompt
/// different actions from a user.
std::string localUnavailable()
{
    return dump(radicle::makeError(local().unavailableReason()));
}

} // namespace

// ===========================================================================
// Capability & configuration
// ===========================================================================

std::string RadicleImpl::getCapabilities()
{
    const bool localAvailable = local().available();

    nlohmann::json out{
        {"localAvailable",   localAvailable},
        {"localNodeRunning", localAvailable && local().nodeRunning()},
        {"canWriteLocal",    false},          // writes arrive in a later milestone
        {"remoteSeed",       seed().seedUrl()},
        {"remoteReachable",  seed().reachable()},
        {"remoteApiVersion", seed().apiVersion()},
        {"nodeId",           localAvailable ? local().nodeId() : std::string{}},
    };
    return dump(out);
}

std::string RadicleImpl::setRemoteSeed(const std::string& seedUrl)
{
    if (seedUrl.empty())
        return dump(radicle::makeError("seed URL is required"));

    const std::string previous = seed().seedUrl();
    seed().setSeedUrl(seedUrl);

    const nlohmann::json index = seed().probe();
    if (radicle::isError(index)) {
        seed().setSeedUrl(previous);   // keep the last known-good seed
        return dump(index);
    }

    remoteSeedChanged(seed().seedUrl());

    return dump(nlohmann::json{
        {"seed",       seed().seedUrl()},
        {"apiVersion", seed().apiVersion()},
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
    return dump(radicle::paginate(seed().listRepos(query, page, perPage), page, perPage));
}

std::string RadicleImpl::remoteGetRepo(const std::string& rid)
{
    return dump(seed().getRepo(rid));
}

std::string RadicleImpl::remoteListBranches(const std::string& rid)
{
    return dump(seed().listBranches(rid));
}

std::string RadicleImpl::remoteGetTree(const std::string& rid, const std::string& sha,
                                       const std::string& path)
{
    return dump(seed().getTree(rid, sha, path));
}

std::string RadicleImpl::remoteGetBlob(const std::string& rid, const std::string& sha,
                                       const std::string& path)
{
    return dump(seed().getBlob(rid, sha, path));
}

std::string RadicleImpl::remoteGetReadme(const std::string& rid, const std::string& sha)
{
    return dump(seed().getReadme(rid, sha));
}

std::string RadicleImpl::remoteListCommits(const std::string& rid, const std::string& sha,
                                           int64_t page, int64_t perPage)
{
    return dump(radicle::paginate(seed().listCommits(rid, sha, page, perPage), page, perPage));
}

std::string RadicleImpl::remoteGetCommit(const std::string& rid, const std::string& sha)
{
    return dump(seed().getCommit(rid, sha));
}

std::string RadicleImpl::remoteListIssues(const std::string& rid, const std::string& status,
                                          int64_t page, int64_t perPage)
{
    return dump(radicle::paginate(seed().listIssues(rid, status, page, perPage), page, perPage));
}

std::string RadicleImpl::remoteGetIssue(const std::string& rid, const std::string& id)
{
    return dump(seed().getIssue(rid, id));
}

std::string RadicleImpl::remoteListPatches(const std::string& rid, const std::string& status,
                                           int64_t page, int64_t perPage)
{
    return dump(radicle::paginate(seed().listPatches(rid, status, page, perPage), page, perPage));
}

std::string RadicleImpl::remoteGetPatch(const std::string& rid, const std::string& id)
{
    return dump(seed().getPatch(rid, id));
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
    if (!local().available()) return localUnavailable();
    return localReader().listRepos(scope, page, perPage);
}

std::string RadicleImpl::localGetRepo(const std::string& rid)
{
    if (!local().available()) return localUnavailable();
    return localReader().getRepo(rid);
}

std::string RadicleImpl::localListBranches(const std::string& rid)
{
    if (!local().available()) return localUnavailable();

    // Derived from the repo document rather than added to the FFI surface,
    // exactly as `SeedClient::listBranches` derives it from `getRepo`. The
    // local backend already returns `refs.refs` in the same shape, so a
    // dedicated Rust entry point would be a second implementation of one
    // filter — and a second place for the two sources to drift apart.
    const auto repo = nlohmann::json::parse(localReader().getRepo(rid), nullptr, false);
    if (repo.is_discarded()) return dump(radicle::makeError("malformed reply from local storage"));
    if (radicle::isError(repo)) return dump(repo);

    return dump(radicle::branchesFrom(repo));
}

std::string RadicleImpl::localGetTree(const std::string& rid, const std::string& sha,
                                      const std::string& path)
{
    if (!local().available()) return localUnavailable();
    return localReader().getTree(rid, sha, path);
}

std::string RadicleImpl::localGetBlob(const std::string& rid, const std::string& sha,
                                      const std::string& path)
{
    if (!local().available()) return localUnavailable();
    return localReader().getBlob(rid, sha, path);
}

std::string RadicleImpl::localGetReadme(const std::string& rid, const std::string& sha)
{
    if (!local().available()) return localUnavailable();
    return localReader().getReadme(rid, sha);
}

std::string RadicleImpl::localListCommits(const std::string& rid, const std::string& sha,
                                          int64_t page, int64_t perPage)
{
    if (!local().available()) return localUnavailable();
    return localReader().listCommits(rid, sha, page, perPage);
}

std::string RadicleImpl::localGetCommit(const std::string& rid, const std::string& sha)
{
    if (!local().available()) return localUnavailable();
    return localReader().getCommit(rid, sha);
}

std::string RadicleImpl::localListIssues(const std::string& rid, const std::string& status,
                                         int64_t page, int64_t perPage)
{
    if (!local().available()) return localUnavailable();
    return localReader().listIssues(rid, status, page, perPage);
}

std::string RadicleImpl::localGetIssue(const std::string& rid, const std::string& id)
{
    if (!local().available()) return localUnavailable();
    return localReader().getIssue(rid, id);
}

std::string RadicleImpl::localListPatches(const std::string& rid, const std::string& status,
                                          int64_t page, int64_t perPage)
{
    if (!local().available()) return localUnavailable();
    return localReader().listPatches(rid, status, page, perPage);
}

std::string RadicleImpl::localGetPatch(const std::string& rid, const std::string& id)
{
    if (!local().available()) return localUnavailable();
    return localReader().getPatch(rid, id);
}
