#include "radicle_impl.h"

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

/// Uniform "this build has no local backend" error for every local* method.
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

    // Seeds from this machine's Radicle config. They are recorded as p2p
    // addresses; whether the host also serves the HTTP API is a separate
    // question, so they are labelled as the user's own rather than presented
    // as equivalent to the public ones.
    for (const std::string& url : local().preferredSeedUrls()) {
        bool seen = false;
        for (const auto& existing : items)
            if (existing.value("url", "") == url) { seen = true; break; }
        if (seen) continue;

        // Show the bare host, not the scheme — "frog.royer.one", not
        // "https://frog.royer.one".
        std::string alias = url;
        const std::string scheme = "https://";
        if (alias.rfind(scheme, 0) == 0) alias = alias.substr(scheme.size());

        items.push_back({{"url", url}, {"alias", alias}, {"source", "config"}});
    }

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
// LOCAL — the local node's storage.
//
// The local backend (the Rust shim over the radicle crate) lands in a later
// milestone. Until then every method reports precisely why it is unavailable
// rather than pretending to be empty: an empty repo list and "no local node"
// are very different answers, and a view must be able to tell them apart.
// ===========================================================================

std::string RadicleImpl::localListRepos(const std::string&, int64_t, int64_t)      { return localUnavailable(); }
std::string RadicleImpl::localGetRepo(const std::string&)                  { return localUnavailable(); }
std::string RadicleImpl::localGetTree(const std::string&, const std::string&,
                                      const std::string&)                 { return localUnavailable(); }
std::string RadicleImpl::localGetBlob(const std::string&, const std::string&,
                                      const std::string&)                 { return localUnavailable(); }
std::string RadicleImpl::localGetReadme(const std::string&, const std::string&) { return localUnavailable(); }
std::string RadicleImpl::localListCommits(const std::string&, const std::string&,
                                          int64_t, int64_t)                       { return localUnavailable(); }
std::string RadicleImpl::localGetCommit(const std::string&, const std::string&) { return localUnavailable(); }
std::string RadicleImpl::localListIssues(const std::string&, const std::string&,
                                         int64_t, int64_t)                        { return localUnavailable(); }
std::string RadicleImpl::localGetIssue(const std::string&, const std::string&)  { return localUnavailable(); }
std::string RadicleImpl::localListPatches(const std::string&, const std::string&,
                                          int64_t, int64_t)                       { return localUnavailable(); }
std::string RadicleImpl::localGetPatch(const std::string&, const std::string&)  { return localUnavailable(); }
