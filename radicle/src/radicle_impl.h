#pragma once

#include <cstdint>
#include <string>
#include "logos_module_context.h"

/**
 * @brief Radicle core module — all Radicle business logic lives here.
 *
 * This module owns every network call, every JSON parse, SHA resolution and
 * caching. UI modules are thin views: they call these methods and render the
 * JSON that comes back. Nothing Radicle-specific belongs in a UI plugin.
 * (Basecamp sandboxes QML anyway — no HTTP and no file access from the view.)
 *
 * ---------------------------------------------------------------------------
 * TWO SOURCES, NAMED APART ON PURPOSE
 * ---------------------------------------------------------------------------
 * Radicle data can come from two fundamentally different places. They have
 * different reachability, different privacy and different write semantics, so
 * this API never hides which one you are talking to:
 *
 *   remote*  — PROXY to a public seed node over HTTPS (radicle-httpd
 *              `/api/v1`). Needs no local `rad` install and no local node.
 *              Sees only PUBLIC repos the seed replicates. Strictly
 *              READ-ONLY: the seed API rejects writes (HTTP 405).
 *              Requires network. This is the "browse anything" path.
 *
 *   local*   — the LOCAL node's own storage (~/.radicle), read in-process.
 *              Works offline. Sees your PRIVATE repos. Can sign and write.
 *              Returns an error if no local node/profile is present.
 *
 * Anything with neither prefix is source-neutral: capability probes and
 * configuration that describe the module itself.
 *
 * A caller picks the source explicitly. `remoteListRepos` and `localListRepos`
 * are different questions with different answers — merging them behind one
 * "listRepos" would hide exactly the distinction users care about.
 *
 * ---------------------------------------------------------------------------
 * CONVENTIONS
 * ---------------------------------------------------------------------------
 * - Every method returns a JSON string. Success shapes are documented per
 *   method; failure is always `{"error":"<message>"}`. Callers check for the
 *   `error` key. Returning JSON (not typed structs) keeps the QtRO/QML
 *   boundary simple and keeps the radicle crate's churn behind this wall.
 * - The JSON SHAPES ARE THE CONTRACT AND ARE SOURCE-INDEPENDENT: a repo from
 *   `remoteGetRepo` and one from `localGetRepo` deserialize identically, so a
 *   view can render either without branching. Only reachability differs.
 * - `sha` arguments accept a branch name, a short SHA or a full 40-char SHA;
 *   the module resolves them. (The seed API itself demands a full 40-char SHA
 *   and 400s on anything shorter — that normalization is our job, not the
 *   caller's.)
 * - Paginated calls take `page` (0-based) and `perPage`, and return
 *   `{"items":[...],"page":N,"hasMore":bool}`.
 *
 * Module code is Qt-free: std::string in, std::string out.
 */
class RadicleImpl : public LogosModuleContext
{
public:
    // ======================================================================
    // Capability & configuration  (source-neutral)
    // ======================================================================

    /**
     * What this module can currently do. Call this first; a UI uses it to
     * decide which sources to offer and whether to show write affordances.
     *
     * -> {"localAvailable":bool,   // a local profile/storage was found
     *     "localNodeRunning":bool, // the node daemon answers its control socket
     *     "canWriteLocal":bool,    // local writes possible (implies a signer)
     *     "remoteSeed":"<url>",    // seed currently proxied to
     *     "remoteReachable":bool,  // last remote call succeeded
     *     "remoteApiVersion":"6.2.0",
     *     "nodeId":"z6Mk..."}      // local NID, empty when unavailable
     */
    std::string getCapabilities();

    /**
     * Point the remote proxy at a different seed (e.g.
     * "https://seed.radicle.xyz"). Validates by fetching `/api/v1` and
     * recording its apiVersion. Affects only `remote*` calls.
     * -> {"seed":"<url>","apiVersion":"6.2.0","nid":"z6Mk..."}
     */
    std::string setRemoteSeed(const std::string& seedUrl);

    /**
     * Seeds worth offering in a picker: the built-in public ones, plus
     * `preferredSeeds` from the local ~/.radicle/config.json when present.
     * -> {"items":[{"url":"...","alias":"...","source":"builtin"|"config"}]}
     */
    std::string listKnownSeeds();

    // ======================================================================
    // REMOTE — proxied to a public seed over HTTPS.
    // No local node required. Public repos only. Read-only.
    // ======================================================================

    /**
     * Search/list repos the seed replicates. `query` may be empty for all.
     * -> {"items":[<repo>],"page":N,"hasMore":bool}
     */
    std::string remoteListRepos(const std::string& query, int64_t page, int64_t perPage);

    /**
     * One repo's metadata: name, description, defaultBranch, head SHA,
     * delegates, visibility, and issue/patch counts.
     * -> <repo>
     */
    std::string remoteGetRepo(const std::string& rid);

    /// Directory listing at `path` ("" = root) for `sha`.
    /// -> {"path":"...","entries":[{"name","path","kind":"tree"|"blob","oid"}]}
    std::string remoteGetTree(const std::string& rid, const std::string& sha,
                              const std::string& path);

    /// File contents. Binary files return `binary:true` and empty content.
    /// -> {"path":"...","name":"...","binary":bool,"content":"..."}
    std::string remoteGetBlob(const std::string& rid, const std::string& sha,
                              const std::string& path);

    /// Rendered-source README for `sha`, or an error if the repo has none.
    /// -> {"path":"...","content":"..."}
    std::string remoteGetReadme(const std::string& rid, const std::string& sha);

    /// Commit log from `sha` backwards. -> {"items":[<commit>],...}
    std::string remoteListCommits(const std::string& rid, const std::string& sha,
                                  int64_t page, int64_t perPage);

    /// A single commit with its diff. -> <commit> + {"diff":{...}}
    std::string remoteGetCommit(const std::string& rid, const std::string& sha);

    /// Issues. `status` is "open"|"closed"|"" (all). -> {"items":[<issue>],...}
    std::string remoteListIssues(const std::string& rid, const std::string& status,
                                 int64_t page, int64_t perPage);

    /// One issue including its full discussion thread. -> <issue>
    std::string remoteGetIssue(const std::string& rid, const std::string& id);

    /// Patches. `status` is "open"|"merged"|"archived"|"draft"|"".
    std::string remoteListPatches(const std::string& rid, const std::string& status,
                                  int64_t page, int64_t perPage);

    /// One patch including revisions and reviews. -> <patch>
    std::string remoteGetPatch(const std::string& rid, const std::string& id);

    // ======================================================================
    // LOCAL — the local node's storage. Offline-capable, sees private repos.
    // Every method errors with {"error":...} when no local profile exists.
    // Mirrors the remote surface above and returns the SAME JSON shapes.
    // ======================================================================

    /// Repos in local storage. `scope`: "all"|"delegate"|"private"|"seeded".
    std::string localListRepos(const std::string& scope, int64_t page, int64_t perPage);

    std::string localGetRepo(const std::string& rid);

    std::string localGetTree(const std::string& rid, const std::string& sha,
                             const std::string& path);

    std::string localGetBlob(const std::string& rid, const std::string& sha,
                             const std::string& path);

    std::string localGetReadme(const std::string& rid, const std::string& sha);

    std::string localListCommits(const std::string& rid, const std::string& sha,
                                 int64_t page, int64_t perPage);

    std::string localGetCommit(const std::string& rid, const std::string& sha);

    std::string localListIssues(const std::string& rid, const std::string& status,
                                int64_t page, int64_t perPage);

    std::string localGetIssue(const std::string& rid, const std::string& id);

    std::string localListPatches(const std::string& rid, const std::string& status,
                                 int64_t page, int64_t perPage);

    std::string localGetPatch(const std::string& rid, const std::string& id);

logos_events:
    /// The active remote seed changed (or was re-validated).
    void remoteSeedChanged(const std::string& seedUrl);

    /// Local node availability flipped. Views should re-read getCapabilities().
    void localAvailabilityChanged(const std::string& capabilitiesJson);
};
