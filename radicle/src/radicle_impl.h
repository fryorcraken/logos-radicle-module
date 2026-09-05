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
     * `LocalWriter` trio resolved from RAD_HOME/HOME. The module
     * registration machinery default-constructs a `RadicleImpl` with no
     * arguments, and `generated_code/radicle_module_impl.cpp`'s `lidlImpl()`
     * does too (`static RadicleImpl impl;`), so this constructor must stay
     * both public and genuinely callable with zero arguments.
     *
     * Deliberately NOT parameterized for dependency injection — see
     * `setDependenciesForTest()` in the `private:` section below for why:
     * this module has `"interface": "universal"` and no `.rep` file, so its
     * dispatch table is derived by scanning this header's `public:` section,
     * and a public constructor that TAKES PARAMETERS (even all-defaulted
     * ones, so it is still callable with zero arguments) reads to that scan
     * as a zero-arg RPC method named `RadicleImpl`, which the generator does
     * not compile correctly. A genuinely parameterless `RadicleImpl()`, like
     * this one, is NOT scanned as a candidate method — verified empirically
     * by building `nix build '.#lgx'` with exactly this shape. Keeping this
     * constructor to exactly the zero-parameter production shape, with no
     * second, parameterized overload, is what keeps it out of that trap
     * while still satisfying `lidlImpl()`'s own default construction.
     */
    RadicleImpl();

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
    // A `friend class` needs no prior forward declaration of RadicleImpl or
    // of any function signature elsewhere in this file — unlike a `friend`
    // function, the name is simply injected here. That matters empirically,
    // not just stylistically: an earlier attempt at this fix forward-declared
    // a free test factory function returning `RadicleImpl` above the class,
    // and that second, separate textual `class RadicleImpl`-shaped mention
    // made the generator scan the wrong (empty) span and report "no public
    // methods found in class RadicleImpl" for the real class below. Keep
    // exactly one textual `class RadicleImpl` in this file — the definition
    // below — and give test-only code access via a `friend struct`/`friend
    // class` naming a type defined entirely in the test file, never via a
    // forward-declared free function.
    //
    // RadicleImplTestFactory (tests/test_radicle_impl.cpp) is the only
    // caller of setDependenciesForTest() below; every test goes through it
    // instead of touching a RadicleImpl's dependencies directly.
    friend struct RadicleImplTestFactory;

    /**
     * Rewires this already-constructed instance's dependencies: a `SeedClient`
     * and a `LocalStore`/`LocalReader`/`LocalWriter` trio built from
     * `local`'s resolved home. Test-only — see below for why this is not a
     * constructor.
     *
     * Before this method existed, PR #23 threaded these through an
     * `explicit RadicleImpl(SeedClient, LocalStore)` constructor (both
     * parameters defaulted, so the module-registration machinery's ordinary
     * `RadicleImpl()` still default-constructed the production instance
     * unchanged). That compiled and all 73 unit tests passed, because the
     * unit-test build compiles `radicle_impl.cpp` directly and never touches
     * `generated_code/`. It broke the real build: this module has
     * `"interface": "universal"` and no `.rep` file, so
     * `logos-cpp-generator`/`logos-qt-generator` derives the module's
     * dispatch table by scanning this header's `public:` section, and a
     * public, all-defaulted (so callable with zero arguments) `RadicleImpl(
     * ...)` reads to that scan like a zero-arg RPC method named
     * `RadicleImpl` — the generator does not exclude constructors from it.
     * It emitted `lidlImpl().RadicleImpl()` as a dispatch case in
     * `generated_code/radicle_module_impl.cpp`, which does not compile
     * (there is no such member function).
     *
     * Only `nix build '.#lgx'` exercises `generated_code/`, which is why the
     * unit tests missed this — see CLAUDE.md's note on cheap gates that
     * cannot see this class of bug.
     *
     * Making the constructor private instead (tried and reverted — verified
     * empirically, not assumed) does not work either: it breaks the
     * *production* path, not just the scan. `generated_code/
     * radicle_module_impl.cpp`'s `lidlImpl()` holds `static RadicleImpl
     * impl;` — a real, ordinary default construction the generated code
     * itself performs, in a free function outside this class, which a
     * private constructor makes inaccessible ("'RadicleImpl::RadicleImpl(...)'
     * is private within this context"). So the constructor must stay
     * genuinely public and genuinely zero-argument for `lidlImpl()` to keep
     * building it, and the injected-dependencies overload cannot exist as a
     * second, differently-shaped `RadicleImpl(...)` — the generator's
     * "public identifier named RadicleImpl" trigger does not care how many
     * parameters it takes or whether they are defaulted, only that it is a
     * public constructor.
     *
     * The fix keeps a public, genuinely zero-parameter `RadicleImpl()` (no
     * defaulted parameters at all — see below the private section for why
     * even that is empirically fine) to do the same construction work the
     * deleted two-parameter constructor did, and moves dependency injection
     * to this ordinary, differently-named private method instead. A private
     * method is not scanned into the dispatch table at all (it is not in
     * `public:`), so it carries no risk of colliding with the generator's
     * constructor heuristic.
     */
    void setDependenciesForTest(radicle::SeedClient seed, radicle::LocalStore local);

    // Instance-scoped dependencies. These used to be function-local `static`s
    // in radicle_impl.cpp — built once per process on first use and never
    // rebuilt, which is what made this class untestable (see the constructor
    // doc comment above). Now every RadicleImpl owns its own.
    radicle::SeedClient m_seed;
    radicle::LocalStore m_local;
    radicle::LocalReader m_localReader;
    radicle::LocalWriter m_localWriter;
};
