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

} // namespace radicle
