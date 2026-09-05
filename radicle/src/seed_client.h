#pragma once

#include <cstdint>
#include <functional>
#include <nlohmann/json.hpp>
#include <string>

#include "http_client.h"

namespace radicle {

/**
 * Client for a Radicle seed node's read-only JSON API (radicle-httpd
 * `/api/v1`). This is the "remote" half of the module: it needs no local
 * `rad` install and no local node, and it can only ever read — the seed API
 * rejects writes with HTTP 405.
 *
 * Every method returns a JSON object. On failure that object is
 * `{"error":"..."}`, so callers have exactly one failure shape to check.
 */
class SeedClient {
public:
    /// Fetches a URL and returns its body. Injectable so tests can drive the
    /// client without a network; production uses the Qt HTTP client.
    using Transport = std::function<HttpResponse(const std::string& url)>;

    /// `seedUrl` is an origin such as "https://seed.radicle.xyz" (no /api/v1).
    explicit SeedClient(std::string seedUrl = "https://seed.radicle.xyz");

    /// Replace the transport. Passing an empty function restores the default.
    void setTransport(Transport transport);

    void setSeedUrl(const std::string& seedUrl);
    const std::string& seedUrl() const { return m_seedUrl; }

    /// Last observed API version from `/api/v1` ("" until probed).
    const std::string& apiVersion() const { return m_apiVersion; }
    bool reachable() const { return m_reachable; }

    /// Fetch `/api/v1` and cache apiVersion + nid. -> the index object.
    nlohmann::json probe();

    nlohmann::json listRepos(const std::string& query, int64_t page, int64_t perPage);
    nlohmann::json getRepo(const std::string& rid);
    /**
     * Branches (refs/heads/*) for a repo, each with the name (prefix
     * stripped) and the commit it points at, plus which one is the repo's
     * default. No dedicated seed endpoint exists for this: getRepo() already
     * returns the full refs map (see resolveSha(), which reads the same
     * data), so this reuses that single request rather than adding another
     * round trip.
     * -> {"items":[{"name":"main","head":"<sha>"}],"default":"main"}
     */
    nlohmann::json listBranches(const std::string& rid);
    nlohmann::json getTree(const std::string& rid, const std::string& sha,
                           const std::string& path);
    nlohmann::json getBlob(const std::string& rid, const std::string& sha,
                           const std::string& path);
    nlohmann::json getReadme(const std::string& rid, const std::string& sha);
    nlohmann::json listCommits(const std::string& rid, const std::string& sha,
                               int64_t page, int64_t perPage);
    nlohmann::json getCommit(const std::string& rid, const std::string& sha);
    nlohmann::json listIssues(const std::string& rid, const std::string& status,
                              int64_t page, int64_t perPage);
    nlohmann::json getIssue(const std::string& rid, const std::string& id);
    nlohmann::json listPatches(const std::string& rid, const std::string& status,
                               int64_t page, int64_t perPage);
    nlohmann::json getPatch(const std::string& rid, const std::string& id);

    /**
     * Resolve a branch name / short SHA / empty string to a full 40-char SHA.
     *
     * This exists because the seed API refuses anything shorter: asking for
     * `tree/master` returns HTTP 400 ("invalid length (have 6, want 40)").
     * Callers pass whatever the user clicked and this sorts it out, consulting
     * the repo's head and refs. An already-40-char input is returned as-is.
     */
    std::string resolveSha(const std::string& rid, const std::string& ref);

private:
    /// GET `path` under /api/v1 and parse. Returns {"error":...} on failure.
    nlohmann::json getJson(const std::string& path);

    Transport m_transport;
    std::string m_seedUrl;
    std::string m_apiVersion;
    std::string m_nid;
    bool m_reachable = false;
};

/// Build `{"error": msg}`.
nlohmann::json makeError(const std::string& msg);

/// True when `j` is an error object produced by makeError().
bool isError(const nlohmann::json& j);

/// Percent-encode one path segment (leaves unreserved chars alone).
std::string urlEncode(const std::string& s);

/**
 * Wrap a bare JSON array from the seed into the module's paginated envelope
 * `{"items":[...],"page":N,"hasMore":bool}`.
 *
 * The seed returns plain arrays with no total count and no next-page link, so
 * `hasMore` is inferred: a full page probably has more behind it. That can
 * yield one empty final page, which is the standard trade-off for this shape
 * and is cheaper than an extra probing request per page.
 *
 * Passes `{"error":...}` objects through untouched.
 */
nlohmann::json paginate(const nlohmann::json& arr, int64_t page, int64_t perPage);

/**
 * Derive `{"items":[{"name","head"}],"default":"<branch>"}` from a repo
 * document's `refs.refs` map.
 *
 * Free-standing rather than a SeedClient method because BOTH sources need it
 * and both already produce the repo document in the same shape — the remote
 * one from the seed, the local one from the Rust backend. A second
 * implementation for the local side (or a `localListBranches` entry point in
 * the FFI) would be one filter written twice, and a place for the two sources
 * to drift apart on which refs count as branches.
 *
 * Passes `{"error":...}` objects through untouched.
 */
nlohmann::json branchesFrom(const nlohmann::json& repo);

/**
 * Parse a raw JSON reply (as returned by `LocalReader::getRepo`) and derive
 * branches from it via `branchesFrom()`.
 *
 * Factored out of `RadicleImpl::localListBranches` so the "backend returned
 * something that isn't even JSON" branch — reported as `{"error":"malformed
 * reply from local storage"}` — is directly unit-testable with a hand-crafted
 * malformed string. The real Rust backend always returns valid JSON (it is
 * built with `serde_json`), so this path cannot be reached by driving the real
 * FFI in a test; it exists as a defensive check against a future backend
 * change or a corrupted read, and a free function is the only way to exercise
 * it without one.
 */
nlohmann::json branchesFromRawJson(const std::string& raw);

/**
 * Collapse a raw `LocalWriter::canWrite()` reply (`{"canWrite":bool,
 * "reason":"..."}` or `{"canWrite":true,"nodeId":"..."}`) into the two fields
 * `getCapabilities()` reports: whether a write is possible, and the reason a
 * view should show when it is not.
 *
 * -> {"canWrite":bool,"writeUnavailableReason":"..."}
 *
 * `writeUnavailableReason` MUST be "" exactly when canWrite is true — a view
 * that saw a non-empty reason next to `canWriteLocal:true` would show a
 * contradiction on screen (an explanation for a write that is, in fact,
 * available). A malformed/unparseable raw reply is reported as
 * `{"canWrite":false,"writeUnavailableReason":"<a stated reason>"}` rather
 * than propagated as an `{"error":...}` — `getCapabilities()` itself never
 * fails; "the backend could not explain itself" is one more reason a write
 * isn't currently possible, not a failure to answer the capabilities query.
 *
 * Factored out of `RadicleImpl::getCapabilities()` so this collapse — which
 * needs a controllable `canWrite()` reply to test both branches, and
 * `LocalWriter` has no fake seam of its own — is directly unit-testable with
 * a hand-crafted probe string instead of only being reachable through a real
 * signing key.
 */
nlohmann::json writeCapabilityFrom(const std::string& rawProbe);

} // namespace radicle
