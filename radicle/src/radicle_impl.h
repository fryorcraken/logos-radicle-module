#pragma once

#include <cstdint>
#include <string>
#include "local_reader.h"
#include "local_store.h"
#include "local_writer.h"
#include "logos_module_context.h"
#include "seed_client.h"

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
    /**
     * Default-constructs the production dependencies: a `SeedClient` pointed
     * at the built-in default seed, and a `LocalStore`/`LocalReader`/
     * `LocalWriter` trio resolved from RAD_HOME/HOME exactly as before this
     * constructor existed. The module registration machinery default-
     * constructs a `RadicleImpl` with no arguments, so that path is
     * unchanged.
     *
     * The two extra parameters exist for tests only: everything above this
     * class used to be a function-local `static` (see the history of this
     * file), which meant it was built once per process on first use and never
     * rebuilt — so a test's `ScopedRadHome` only ever affected whichever test
     * happened to touch the singleton first. Passing dependencies in here
     * makes each `RadicleImpl` instance its own, independent unit — a test
     * can construct one after pointing RAD_HOME at a scratch directory, or
     * hand it a `SeedClient` with a fake transport, without affecting any
     * other test.
     *
     * `local`'s home is captured once, at construction, to build the reader
     * and writer — mirroring exactly what the old lazily-initialized statics
     * did (see `radicle_impl.cpp`'s history), just scoped to the instance
     * instead of the process.
     */
    explicit RadicleImpl(radicle::SeedClient seed = radicle::SeedClient{},
                         radicle::LocalStore local = radicle::LocalStore{});

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
     *     "writeUnavailableReason":"...", // why not, "" when canWriteLocal
     *     "remoteSeed":"<url>",    // seed currently proxied to
     *     "remoteReachable":bool,  // last remote call succeeded
     *     "remoteApiVersion":"6.2.0",
     *     "nodeId":"z6Mk..."}      // local NID, empty when unavailable
     *
     * `canWriteLocal` is a real probe for a usable signing key, not a build
     * flag. It is false — with a reason naming the fix — when the node's key
     * is encrypted and neither RAD_PASSPHRASE nor ssh-agent can supply it.
     * A view MUST gate every write affordance on it rather than on
     * `localAvailable`: offering a compose box that cannot be submitted loses
     * whatever the user typed into it.
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

    /**
     * Branches (refs/heads/*), each with the commit it currently points at,
     * plus which one is the repo's default.
     * -> {"items":[{"name":"main","head":"<sha>"}],"default":"main"}
     */
    std::string remoteListBranches(const std::string& rid);

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

    std::string localListBranches(const std::string& rid);

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

    // ======================================================================
    // LOCAL WRITES — the only methods in this module that change state.
    //
    // Local-only by necessity, not by choice: the seed API rejects writes with
    // HTTP 405, so a `remote*` counterpart could only ever fail. The asymmetry
    // with the read surface above is the honest representation of that, and is
    // why this API names its source rather than hiding it.
    //
    // Each needs a signing key, so each can fail for a reason no read has —
    // see `getCapabilities().canWriteLocal`, which a view should check before
    // offering the action at all.
    // ======================================================================

    /**
     * Post a comment on an issue's discussion thread. The comment lands on the
     * thread root; there is no reply-to, because nothing renders nesting.
     *
     * -> {"id":"<entry id>",      // the new comment's entry
     *     "announced":bool,       // did the local node tell the network yet
     *     "announceError":"..."}  // present only when announced is false
     *
     * `announced:false` alongside an `id` is a SUCCESSFUL write that has not
     * been announced — an ordinary state, since the node announces on next
     * start. Do not present it as a failure, or the user will post twice.
     */
    std::string localCommentOnIssue(const std::string& rid, const std::string& id,
                                    const std::string& body);

    /**
     * Open a new issue. `description` becomes the issue's root comment — that
     * is how a Radicle issue is modelled, and why `localGetIssue` returns it
     * as `discussion[0].body` rather than as a field of its own.
     *
     * `title` must be a single line; a `\n` or `\r` is rejected rather than
     * trimmed, which is reachable by pasting into a one-line field.
     *
     * Labels and assignees are deliberately not parameters. Both exist in the
     * COB model, but assignment is by DID and needs a peer picker this module
     * does not have, and neither is rendered anywhere today.
     *
     * -> {"id":"<issue id>",     // pass straight to localGetIssue
     *     "announced":bool,
     *     "announceError":"..."} // present only when announced is false
     */
    std::string localCreateIssue(const std::string& rid, const std::string& title,
                                 const std::string& description);

logos_events:
    /// The active remote seed changed (or was re-validated).
    void remoteSeedChanged(const std::string& seedUrl);

    /// Local node availability flipped. Views should re-read getCapabilities().
    void localAvailabilityChanged(const std::string& capabilitiesJson);

private:
    // Instance-scoped dependencies. These used to be function-local `static`s
    // in radicle_impl.cpp — built once per process on first use and never
    // rebuilt, which is what made this class untestable (see the constructor
    // doc comment above). Now every RadicleImpl owns its own.
    radicle::SeedClient m_seed;
    radicle::LocalStore m_local;
    radicle::LocalReader m_localReader;
    radicle::LocalWriter m_localWriter;
};
