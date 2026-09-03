# Working on this repository

## M2.1 — scope and FFI decision, 2026-09-03

M2.1 = read-only local-node browsing: mirror every `remote*` method with a
working `local*` implementation, reading `~/.radicle` in-process instead of
proxying to a seed over HTTP. `radicle_impl.h`'s doc comment already commits
to the hard constraint: a repo from `remoteGetRepo` and `localGetRepo` must
deserialize identically, so a view renders either without branching.

### FFI approach: a Rust staticlib with a flat `extern "C"` string API, not `cxx`

There is no Rust anywhere in this repo yet — no `Cargo.toml`, no hints in
`radicle/flake.nix`, `radicle/CMakeLists.txt` or `metadata.json`'s
`nix.cmake.extra_link_libraries`. This is a from-scratch FFI boundary.

Considered `cxx` (typed C++/Rust interop, codegen'd bridge) vs a plain
`cbindgen`-style C header over a `staticlib`. Chose the latter: every existing
module method is already `std::string in, std::string out` JSON — see
`radicle_impl.h`'s own conventions section, "returning JSON keeps the
radicle crate's churn behind this wall." `cxx` buys typed struct marshalling
across the boundary, which is exactly the thing this codebase has deliberately
avoided needing. A flat API matches the existing shape with the least new
machinery:

```c
// caller owns nothing until it gets a pointer back; frees it with
// radicle_free_string. NULL home = not found via RAD_HOME/HOME (mirrors
// LocalStore's own env lookup, so behaviour stays identical if both live for
// a while).
char* radicle_local_list_repos(const char* home, const char* scope,
                                int64_t page, int64_t per_page);
char* radicle_local_get_repo(const char* home, const char* rid);
// ...one function per local* method, same signature shape as radicle_impl.h.
void  radicle_free_string(char* s);
```

The Rust side builds the JSON itself (via `serde_json`, matching the shapes
below) and returns a `CString::into_raw()` pointer; `radicle_free_string`
calls `CString::from_raw` to drop it. `local_store.cpp` calls these from a new
`radicle::LocalRepoReader` (or similar) that owns the FFI boundary, the same
way `SeedClient` owns the HTTP boundary — `radicle_impl.cpp` should not call
`extern "C"` functions directly.

Nix wiring (not yet built, this is the plan): a `rustPlatform.buildRustPackage`
derivation in `radicle/flake.nix` producing the staticlib, added to
`metadata.json`'s `nix.cmake.extra_link_libraries` /
`nix.cmake.extra_include_dirs` (that extension point already exists in
`metadata.json`'s schema, unused today — this is what it's for) so
`logos_module()`'s `LINK_LIBRARIES` picks it up. `radicle/CMakeLists.txt`
gets a `radicle_ffi.h` (cbindgen-generated, checked in rather than
generated-at-configure-time so the header is reviewable) alongside the
existing sources.

**Known gotcha, unconfirmed whether still live**: a prior memory recorded
`radicle = "0.24"` failing to build until `radicle-oid` was pinned to
`0.2.0`. Checked crates.io/GitHub as of this session: `radicle` is now at
`0.25.1` and `radicle-oid` at `0.2.2` upstream — the pin this module needs, if
any, has to be re-verified empirically against whatever `Cargo.lock` resolves
to; do not assume the old pin still applies to the new version line.

### Reading local storage — confirmed against heartwood source (crates/radicle, tag matching v0.25.1)

- **Git-native (repos, tree, blob, commit)**: `radicle::storage::git::Storage::open(path, info: UserInfo)`
  opens the profile's storage root (no signer, no passphrase — `UserInfo` is
  config, not a key). `storage.repository(rid) -> Repository` opens one repo;
  `Repository` wraps a `git2::Repository` (`.backend`) plus helpers for refs,
  head, tree, blob, commit — all `ReadRepository` trait methods, all
  read-only. This is genuinely "a few more calls on the same object", same
  complexity class as what `SeedClient` already does over HTTP.
- **COBs (issues, patches)**: NOT plain git objects — each COB is a DAG of
  signed operations under `refs/cobs/<typename>/<id>/...`, replayed
  (`Evaluate`) into current state. The crate does the replay for you:
  `radicle::cob::issue::Issues::open(&repository, ReadOnly)` then `.get(&id)`
  / `.all()` (via `Deref` to `store::Store`) — confirmed in
  `crates/radicle/src/cob/issue.rs`. `radicle::cob::patch::Patches::open`
  mirrors it exactly (`crates/radicle/src/cob/patch.rs`). Critically,
  `store::access::ReadOnly` is a zero-field unit struct requiring no signer
  (`crates/radicle/src/cob/store/access.rs`) — read access needs only a
  `&Repository`, so this works fully offline with no passphrase prompt.
- **The SQLite cache (`radicle::cob::issue::cache::Cache` /
  `cob::cache::StoreReader`/`StoreWriter`) is NOT required for correctness.**
  `Cache<..., cache::NoCache>` exists specifically as a direct-read path —
  `NoCacheIter` walks `store.all()`/`store.get()` straight off git refs, no
  DB involved (confirmed in `crates/radicle/src/cob/issue/cache.rs`,
  `impl Issues for Cache<..., cache::NoCache>`). Use `NoCache` for M2.1: it
  avoids owning a SQLite file's lifecycle/location entirely. The real `rad`
  CLI's on-disk cache (`~/.radicle/cache/cobs.db`) is a read-through
  optimization for its own use, not a dependency other readers need.
- Net effect: **COB reading is not the separate subsystem it looked like
  from the outside.** No `automerge` crate knowledge needed, no custom
  signature-verification code to write — `Issue`/`Patch` (the replayed
  state structs) come out with fields matching what `remoteGetIssue`/
  `remoteGetPatch` already expose (title, description, state, thread/
  comments for issues; revisions/reviews for patches). The actual open
  question is JSON *shape* matching, not read mechanics — `radicle-httpd`
  (which produces the `remote*` shapes) lives in a separate repo, not in
  this heartwood checkout, so its exact serde output wasn't directly
  confirmed this session. Match `test_seed_client.cpp`'s fixture JSON
  (`radicle/tests/test_seed_client.cpp`, `kRepoJson` etc.) empirically
  against real local output once a repo is available to compare, rather
  than guessing radicle-httpd's serialization from first principles.

### Sequencing: repos + tree + blob + commits first, issues + patches as a flagged follow-up if time runs out

Not because COBs are hard — the research above says they're not
meaningfully harder than git-native reads — but because there's more total
surface (two more list+get method pairs, two more JSON shapes to match, two
more sets of unit tests) and this is one session. Build and land git-native
`local*` completely and tested first; if session time remains, continue
straight into issues/patches using the same `Issues::open`/`Patches::open`
+ `NoCache` pattern — there's no architectural reason to stop, only a budget
one.

## Status — 2026-09-03

### What landed this session

All of the below is committed. Next step is pushing to both remotes, then
the release/catalog work — see the ordered list further down.

- **`remoteGetCommit` / `localGetCommit` wired through.** They were implemented
  in the core module and URL-tested, but missing from `radicle_ui.rep`, so no
  backend forwarder and no path from QML. Added to the `.rep` and to
  `radicle_ui_backend.{h,cpp}`.
- **`CommitView.qml` (new).** Commit message, author, insertion/deletion counts
  and a diff renderer over `diff.files[].hunks[].lines` — coloured gutter, old
  and new line numbers, plain monospace. The seed sends raw text, not
  pre-tokenized lines, so there is no syntax highlighting on purpose.
- **Commit rows made clickable**, wired into `RepoView` alongside the issue and
  patch detail views. The `StackLayout` detail indices are now named
  (`threadIndex`, `commitIndex`) instead of a hardcoded `4`, so inserting a tab
  cannot silently point at the wrong child.
- **The commit-row click bug is fixed — and it was a test bug, not a delegate
  bug.** `CommitsTab.qml` and `IssuesTab.qml` were structurally identical at
  the delegate (the MouseArea declared after the RowLayout in both, once
  aligned). The actual cause: in `tst_clicks.qml`, `commits` and `issues`
  overlap (`anchors.fill: parent` on both) and `commits` is `visible: false`
  by default so the issues click test doesn't hit a commits row underneath.
  `TestCase.mouseClick` cannot deliver a synthetic event into an invisible
  item's children, so the commit-row click test always failed regardless of
  the delegate. Fix: the test now flips `commits.visible = true` for the
  duration of that one test, then restores it. All 63 (now 70, see below)
  component tests pass.
- **`tst_clicks.qml` (new in the prior session)** — the first test here that
  issues a real `mouseClick` rather than emitting a signal by hand. This is
  what caught the test bug above in the first place.
- **Icon: transparent background, white Noto-Emoji alien glyph.** Went
  through several attempts this session:
  1. Transparent Noto-Emoji alien — showed inside a solid green tile in
     Basecamp's sidebar.
  2. Opaque white-background/purple-glyph version, on the theory the tile
     colour was showing through transparency — the green tile was still
     there, unchanged, because that theory was wrong.
  3. Investigated instead of guessing further. The green tile is an accent
     colour Basecamp/the module catalog assigns per module — it lives in a
     `color` field in the *catalog's* `logos-repo.json` (the fork at
     `fryorcraken/logos-modules`, set up as part of this session — see below),
     not in this repo's `metadata.json` and not something baked into the PNG.
     So: standard dock-icon pattern — fully transparent background, bold
     white glyph, so it reads correctly on whatever accent tile colour the
     catalog assigns. Tried a hand-drawn simplified silhouette instead of the
     emoji glyph at this point — rejected on sight, went back to the real
     👾 emoji.
  4. **Final: the real Noto-Emoji 👾 glyph, rendered white, transparent
     background** — same PIL method as before (`NotoEmoji-Regular.ttf`, not
     the COLRv1 variant, thickened via `ImageFilter.MaxFilter`, 95% canvas
     fill), just white fill instead of the original blue.
  **Regenerate rather than hand-edit** — there's no checked-in generator
  script; write one ad hoc from this description if you need to tweak it
  again. Confirmed rendering with no QML/resource errors and confirmed
  visually acceptable in a live Basecamp.
  **If a deliberate accent colour is wanted instead of the green default,
  that's set in the catalog's `logos-repo.json`, not here.**
- **Sync progress bar could visibly regress — fixed.** Reported live: the
  Download All button went from ~90% back to ~50% mid-download. Root cause:
  `syncQueued`/`syncDone` count nodes as the tree is discovered
  breadth-first, so `syncQueued` can jump up (a directory's reply reveals
  several new children) faster than `syncDone` catches up, dropping the raw
  ratio. Fixed by making `SourceTab.syncProgress` a value that only ever
  advances — updated explicitly in `finishSyncIfDone()` (`bumpSyncProgress()`
  keeps the max of the current value and the fresh ratio) instead of being a
  live binding recomputed on every read, and reset to 0 in both `reset()` and
  at the start of `syncAll()`. Regression test in `tst_repo_switch.qml`
  (`test_sync_progress_never_goes_backwards`) reproduces the exact shape that
  triggered it — a root file completing before a sibling directory's larger
  contents are discovered — and asserts the sequence of progress values seen
  after each reply is non-decreasing and ends at 100%.
- **Sync button relabelled.** Idle-state label now reads "Download All" the
  first time a repository is opened (never synced) and "Re-sync" once a sync
  has completed for it, instead of always saying "Sync" — makes the
  first-time full-download cost visible before the user commits to it.
  Backed by a new `SourceTab.syncedOnce` bool: set on `finishSyncIfDone()`
  (not on `cancelSync()`, so an interrupted sync doesn't falsely claim
  completion), cleared in `reset()` so switching repositories doesn't carry
  over another repo's synced state. Tooltip text updated to match
  ("Re-download every file to refresh the local cache" when already synced).
  Covered by three new tests in `tst_repo_switch.qml`.
- **Four bugs from architecture review, same class each time**, each with
  the reasoning in a comment at the site:
  - `nav.busy` was a boolean where concurrent requests are the norm, so the
    first reply cleared the strip while others were in flight. Now a counter.
    It also cleared `nav.error` on every request start, which meant a later
    request erased an earlier one's error — during a sync, errors were
    effectively unobservable.
  - `ThreadView` captured `wantId` but not `wantRid`, the one loader not
    following the codebase's own guard convention.
  - `SourceTab`'s sync counters were incremented by replies from a previous
    repository, so a fresh sync could report itself finished while still
    fetching. Requests now carry a `syncEpoch`.
  - **`CommitsTab.fetch()` had no staleness guard at all** — found by this
    session's own architecture-review pass, not live. Unlike `IssuesTab`/
    `PatchesTab`'s `fetch()`, it didn't capture `wantRid`/`wantBranch` before
    the async call, so a reply landing after the user switched repos or
    branches would populate the new repo's list with the old repo's commits
    and flip `loading`/`hasMore` for a screen that had already moved on. Now
    matches the `IssuesTab`/`PatchesTab` guard shape. Regression test:
    `tst_repo_switch.qml::test_a_stale_commits_reply_is_dropped_after_switching_repos`,
    using a new deferred-reply fake backend (`deferredApp`) that lets the
    test hold a reply, switch `rid`, then deliver it and assert it's dropped.

### Two independent reviews before cutting the release

Ran a test-coverage review and an architecture review (both read-only,
separate subagents) as a pre-release check. Findings, and what was done with
each:

- **Acted on now:** the `CommitsTab.fetch()` staleness gap above — same bug
  class as four prior fixes, small and mechanical, so fixed in this pass
  rather than deferred.
- **Deferred, not blocking:** `Main.qml`'s `nav.busy`/`nav.error` counter
  logic has no dedicated test (only incidental coverage via layout tests);
  `SourceTab.syncEpoch`'s actual race (a stale reply arriving *after* a new
  sync starts) is only exercised under a synchronous fake backend that can't
  trigger the false path; `CommitView.qml` (320 lines, the diff renderer) has
  no test file at all; `PatchesTab.qml`'s `threadRow` click has no coverage
  in `tst_clicks.qml`, unlike issue and commit rows; `radicle_impl.cpp`'s
  `local*` methods aren't unit-tested for the *shape* of their "unavailable"
  error; the end-to-end spec (`browse.yaml`) never exercises the file tree,
  blob viewer, README, or patches flows, despite those being shipped
  features. None of these are regressions from this session's work — they're
  pre-existing gaps the coverage review surfaced. Worth a follow-up pass,
  not a release blocker.
- **Acted on now (cheap, zero behaviour change):** `Main.qml`'s `call()`
  hardcoded `"remote" + method`, so every QML caller was wired to the
  `remote*` source with no way to choose `local*`, even though the core
  module's `local*` surface is already fully implemented and forwarded.
  Added an optional `source` parameter (defaults to `"remote"`) — none of
  the 13 existing call sites needed touching. Whoever builds M2's local-node
  UI now has a parameter to pass instead of a hardcoded prefix to retrofit
  across every caller.
- **Flagged, not actioned:** `IssuesTab.qml`/`PatchesTab.qml` are near-
  identical (same fetch/cache/pagination shape, differing only in the status
  list and backend method name) — real duplication, but CLAUDE.md's stance
  against premature abstraction means this waits for a second bugfix
  divergence or a third consumer before extracting a shared component.

All gates pass (syntax, QML component tests, core module unit tests), and
both modules have been rebuilt and confirmed loading with no errors in a
live `alice` Basecamp profile (checked the log for QML/import failures —
none — and confirmed "Successfully loaded UI module: radicle_ui").

### M1.1 — proposed next milestone, not started

Two feature requests came up live while dogfooding M1 in Basecamp. Neither is
in scope for M1 (browse-only, no branch concept beyond the default) or M2
(local-node browsing). Scoping notes so whoever picks this up doesn't have to
re-derive the reasoning:

- **Branch switching.** The "main" chip in `RepoView.qml` (next to the Sync
  button) is currently a static, non-interactive label reading
  `page.defaultBranch` — there is no branch-switching feature anywhere in the
  codebase today. Needs: a way to list a repo's branches/refs (check whether
  the seed HTTP API already exposes this — `radicle/src/radicle_impl.h` is
  the core module's API surface), a picker UI, and `SourceTab`/`CommitsTab`/
  etc. re-pointing their `branch` property and resetting cached state the
  same way a repo switch does today.
- **Detect when a re-sync is worth doing.** Right now "Re-sync" (post-first-
  sync idle label, see above) is always the same colour/affordance regardless
  of whether the remote has moved since the last sync — there's no signal
  telling the user whether re-syncing would actually fetch anything new.
  Proposed shape from the conversation that raised it: periodically check the
  remote's HEAD (a lightweight call, not a full sync) — every ~5 minutes was
  suggested as a starting point — and compare against the commit captured at
  the last completed sync; if they differ, give the button a distinct
  "update available" colour/state rather than disabling/enabling it outright,
  since the button's clickability shouldn't depend on this (re-syncing is
  never wrong, just sometimes unnecessary). Needs the last-synced commit
  captured somewhere in `SourceTab` (there's currently no such field — only
  `syncedOnce`, a bool) and a lightweight polling mechanism that respects
  `syncEpoch`/repo-switch semantics the same way `syncAll()` does, so a stale
  poll reply from a previous repository can't flip the indicator for the
  wrong repo.
- **Review test coverage as part of M1.1**, not just for the new
  branch-switching/staleness-detection code — the gaps this session's
  pre-release review surfaced and deferred (see above: `nav.busy`/`nav.error`,
  the actual `syncEpoch` race, `CommitView.qml`, `PatchesTab` click coverage)
  are still open. Roll that follow-up pass into M1.1 rather than letting it
  drift further.
- **Favour data structure over code logic when closing those gaps.** Where a
  coverage gap traces back to branchy, ad hoc guard logic repeated slightly
  differently across `CommitsTab`/`IssuesTab`/`PatchesTab`/`ThreadView`
  (the `wantRid`/`wantEpoch`-style staleness checks), prefer reshaping the
  shared state so the invariant is structural — impossible to get wrong by
  construction — over adding more test cases to pin down more branches. The
  architecture review's flagged `IssuesTab`/`PatchesTab` duplication is the
  concrete case in point: a well-chosen shared data shape for "list tab with
  staleness guard" would make the guard correct everywhere at once, instead
  of needing a dedicated regression test per component (as `CommitsTab`
  needed this session).
- **Repo header actions, mirroring Radicle Desktop's own repo view.** Two
  screenshots from `app.radicle.xyz` supplied by the user show a small
  action cluster next to the repo header: a link/share dropdown ("Open on
  app.radicle.xyz", "Copy link to app.radicle.xyz", "Copy repository ID")
  and a checkout affordance that expands to show `rad checkout rad:<id>`
  with a copy button, alongside `Private`/`Public` and `Delegates N/M`
  badges. For this module: "Open on app.radicle.xyz" and the delegate
  count both need data this module may not fetch today — check what
  `remoteGetRepo`/`localGetRepo` already return before assuming a new API
  call is needed. "Copy repository ID" and "Copy link" are clipboard-only,
  no new data. The `rad checkout` command line is pure string templating
  from the `rid` this module already has — no new API surface, just a
  small UI affordance. Note this was added to CLAUDE.md after the M1.1
  worktree agent's task was already dispatched — if its current session is
  still active, this is follow-up scope for a later pass, not something to
  interrupt in-flight work for.

### M1 shipped — status as of 2026-09-03

1. ✅ **Committed and pushed** to both remotes.
2. ✅ **Release CI verified**: `ci.yml`'s `release` job ran for real on the
   `v0.1.0` tag and attached all four expected `.lgx` artefacts (both
   modules, portable + `-dev` each).
3. ✅ **First release cut**: `v0.1.0`, assets confirmed at
   `https://github.com/fryorcraken/logos-radicle-module/releases/tag/v0.1.0`.
4. ✅ **Registered in the catalog.** The fork at `fryorcraken/logos-modules`
   is set up: `logos-repo.json` edited, both modules released
   (`radicle-v0.1.0`, `radicle_ui-v0.1.0`), index rebuilt and confirmed to
   list both. **One real snag along the way, worth knowing if this repo's
   layout is ever copied**: `logos-radicle-module` is a monorepo (two
   modules, `radicle/` and `radicle-ui/`, under one git repo) but the
   catalog's release-action `@v1` tag can only handle `module_path` pointing
   at a submodule's *root* — it fails checkout with "pathspec did not match
   any file(s) known to git" for any `module_path` that's a subdirectory of
   a submodule. The fix (`module_path` may point inside a submodule) exists
   on the action's `master` branch
   (`logos-co/logos-modules-release-action@974960591a8d`) but isn't in a
   tagged `v1.x` yet — the catalog's `_release-module.yml` is pinned to that
   exact commit rather than a moving ref. **Re-pin to a tagged `v1.x` once
   the fix ships in one.** Also: `release-all.yml`'s auto-discovery reads
   module paths straight from `.gitmodules` submodule paths, so it can't see
   the two modules inside one submodule either — `radicle` and `radicle_ui`
   each need their own manually-triggered workflow
   (`release-radicle.yml`, `release-radicle_ui.yml`), not the umbrella.
5. ✅ **Catalog URL handed over** — ready to add to Basecamp:
   `https://raw.githubusercontent.com/fryorcraken/logos-modules/main/logos-repo.json`

### M1.1 and M2.1 — in progress in separate worktrees

Both started 2026-09-03, each in its own git worktree/branch, isolated from
`main` and from each other:

- **M1.1** (branch switching, sync staleness detection, the deferred
  test-coverage follow-up from the pre-release review — see the M1.1 section
  above for full scope): in progress. First commit landed —
  `Main.qml`'s `nav.busy`/`nav.error` state extracted into a dedicated,
  tested `NavState` component, closing the first deferred coverage gap via
  structural extraction rather than just adding test cases (the
  data-structure-over-logic principle noted above). Instructed to push and
  open a draft PR once at a good stopping point, and to watch/fix its own
  CI rather than leave it red.
- **M2.1** (read-only local-node browsing — the `local*` API surface already
  declared in `radicle_impl.h` is fully stubbed, returning
  `localUnavailable()` unconditionally; `LocalStore` only does filesystem/
  socket *detection*, no actual reading of `~/.radicle/storage`; there is no
  Rust/FFI integration in this module at all yet). This is real, from-scratch
  work — a new FFI boundary into the `radicle` crate, plus reading git-native
  data (repos/trees/blobs/commits) and COBs (issues/patches, which need the
  crate's COB machinery, not just git). Scoped as: design/scope first
  (FFI approach, how COBs get read, whether full parity fits one session or
  issues+patches become a flagged follow-up), then implement bottom-up
  (Rust/C++ core proven with tests before any QML wiring). `Main.qml.call()`
  already has the `source` parameter needed for QML call sites to eventually
  pass `"local"` (added this session, see above). **M2.2** (write actions —
  issues/patches/comments, a GitHub-Desktop-style workflow) is a planning
  task for later, explicitly out of scope for the M2.1 agent.
   — unverified until step 4 is done.

**M2 (local-node browsing) is explicitly out of scope until the user has
reviewed the M1 work above** — do not start it unprompted.

### M1 gaps closed, and what M1 is

M1 is: browse any public Radicle repository through a seed node's HTTP API,
with no local `rad` node. Working today — seed selection (three built-ins plus
any endpoint typed in), repository search and listing with paging, repository
home with file tree, blob viewer and README, a Sync button that pulls a whole
repo into the local cache, commit list, issue list and detail with full
discussion, patch list and detail with revisions, and cache-first filter
switching. Read-only throughout.

An audit found three things claimed as done that were not: the issue detail
view did not exist, commit rows were click-dead, and there was no diff
rendering at all. The first is shipped; the other two are the uncommitted work
above. **Local browsing (`local*`) is deliberately unimplemented** — it needs
the Rust FFI backend, which is M2. Those methods return a specific reason
rather than an empty list, because "no local node" and "no repositories" are
different answers.

### A note on tooling in this repo

Read files with the `Read` tool, not `cat` or `grep` through Bash. This
session's permission setup blocks Bash commands it cannot statically analyse —
inline `VAR=value` prefixes, `sh <relative-path>`, `cd && grep <relative>` —
and each one costs a prompt. The test scripts take no arguments and set their
own environment for exactly this reason. Bash is for `nix`, `git`, `gh` and
running those scripts by absolute path.

## Tests are part of the change, not a follow-up

All four test layers run on **every pull request**, so coverage is not
something added later — an uncovered change is a change CI has not checked.
Write the test as you write the code, not after it.

Every new UI feature ships with UI test coverage in the same change. Every UI
bug fixed ships with a regression test in the same change, and that test must
provably fail before the fix: write it first, watch it fail, then fix the code.
A regression test that has never failed proves nothing about the bug it claims
to cover.

This is not a request for exhaustive coverage. It is a request that the change
which introduces behaviour is the change that pins it down.

## Before anything else, make the failure visible

Basecamp swallows QML errors. A view that fails to compile, a plugin skipped for
a missing manifest field, a binding that evaluates to `undefined` — all present
identically as "clicking the app does nothing". Four separate bugs here wore
that same face.

`scaffold.toml` sets `QT_LOGGING_RULES=qt.qml.import.debug=true` so Basecamp
prints why a view failed. Read `.scaffold/basecamp/profiles/alice/basecamp.log`
before forming a theory; one line there beats an afternoon of guessing.

Note that `qmllint` does not catch syntax errors — it passed a file Qt then
refused with "Unexpected token `}'". `radicle-ui/tests/check-qml-syntax.sh`
covers that, and runs first in CI.

## The end-to-end spec passes

`radicle-ui/tests/ui/browse.yaml` runs green: 18 steps, ~21s against a real
Basecamp. Two things to know if you add steps to it:

- **`objectName` must sit on the clickable element**, not its parent. Naming a
  Repeater delegate matched one element instead of four, because the delegate
  Item is not clickable — its MouseArea is.
- **`calls:` assertions do not work here.** QML dispatches through the
  `radicle_ui` QtRO replica and that hop is not logged as a LogosAPIClient
  invocation, so sitometres reports "no backend calls at all" while the data
  plainly arrives. Assert the effect with `state:` instead.

## The four gates, all on every PR

| Gate | Runs on | Catches |
|---|---|---|
| QML syntax (`check-qml-syntax.sh`) | every PR | a file Qt cannot parse — `qmllint` does **not** catch this |
| Core unit tests | every PR | logic: URLs, ref resolution, pagination, error shapes |
| QML component tests | every PR | one component's own behaviour |
| End-to-end spec (sitometres) | every PR + push to main | the wiring: does the module load, does the replica connect, does data arrive |

The end-to-end job takes about three minutes warm. A PR from a fork, or the
first run after `BASECAMP_REV` changes, pays roughly nine minutes because the
Nix store cache is cold.

## The three layers

Pick the cheapest layer that can actually see the behaviour you changed.

| Layer | Lives in | Run it with | Covers |
|---|---|---|---|
| Core module unit tests | `radicle/tests/` | `cd radicle && nix build '.#checks.x86_64-linux.unit-tests'` | URL building, ref resolution, pagination, error shapes, local-profile detection — no network |
| QML component tests | `radicle-ui/tests/tst_*.qml` | `sh radicle-ui/tests/run-qml-tests.sh` | One component in isolation: selection state, layout invariants, load ordering |
| End-to-end UI specs | `radicle-ui/tests/ui/*.yaml` | `npx @paradoxcomputer/sitometres run radicle-ui/tests/ui/browse.yaml` | Real clicks in a real Basecamp, real QtRO transport, real seed calls |

Logic that does not need a view belongs in the core module, where it is testable
without Qt at all. A component test is the right layer for anything one QML file
decides on its own. Reach for a sitometres spec when the thing that broke was
the *wiring* — a signal that never arrived, a call the view forgot to make, a
screen that loaded but showed the previous screen's data. Component tests
structurally cannot see those.

## Writing sitometres specs

Prefer `state:` over `text:`. `text:` reads QML properties rather than pixels,
so it also matches items that are loaded but hidden — a cached `StackLayout`
page keeps answering for a screen the user has navigated away from. `state:`
asks the app what it believes is true.

Assert on `calls:` when the point of the change is that a call happens. A step
that only checks what is on screen will pass against a view rendering stale
cached data.

Give anything a spec needs to click a stable `objectName`. Specs select by
`objectName`, not by label, so renaming a button in the UI must not break a
test and changing an `objectName` must be treated as an interface change.

## Running the end-to-end layer

The specs need a Basecamp built **with the QML inspector**, which is a
compile-time feature and is off in the shipping AppImage:

```bash
nix build 'github:logos-co/logos-basecamp/aa237766baf61404e12da86b7303cb41065464c9#bin-bundle-dir-inspector' -o result-bundle
```

sitometres 0.1.0 will then refuse it with "no Basecamp with the QML inspector
compiled in", even though the inspector is there. It decides by scanning for the
inspector's log strings and probes exactly two paths: `bin/LogosBasecamp` (a
5 KB shell wrapper) and `bin/.LogosBasecamp` (absent). The real ELF is
`bin/.LogosBasecamp.elf`, which it never looks at.

Do not simply point `--basecamp` at the `.elf`: that clears the check and then
fails to spawn with `ENOENT`, because the wrapper is what sets up the bundled
library and Qt plugin paths. Copy the bundle somewhere writable and give the
probe the name it wants, keeping the wrapper as the binary:

```bash
cp -RL result-bundle basecamp && chmod -R u+w basecamp
ln -sfn .LogosBasecamp.elf basecamp/bin/.LogosBasecamp
# then: --basecamp basecamp/bin/LogosBasecamp
```

Drop all of this once sitometres also probes the `.elf`.

Stage the **portable** modules, and say so explicitly:

```bash
cd radicle    && nix build '.#lgx-portable'
cd radicle-ui && nix build '.#lgx-portable' --override-input radicle path:../radicle
# then, from the repo root, with both .lgx copied into dist/
--variant linux-amd64
```

sitometres unpacks one platform variant from the `.lgx` and defaults to
`linux-amd64-dev`, which suits the dev app (`#app`) but not the bundle. The
bundle accepts only `[linux-x86_64, linux-amd64]`, so staging `.#lgx` gets you a
line in Basecamp's log —

```
Warning: module 'radicle' … was installed for variant 'linux-amd64-dev' which is
not supported on this platform and will not be loadable
```

— and then a UI that opens to nothing and a spec that times out on its first
step, with nothing in sitometres' own output explaining why. Both halves are
needed: the portable build *and* `--variant`.

### If `open` hangs on step 1

This was once recorded here as unresolved. It was not a sitometres or
headless-bundle problem: the QML had a **syntax error**, so the view never
compiled and the plugin never loaded. `check-qml-syntax.sh` now catches that
class before it can ship. If step 1 hangs again, read Basecamp's log in the
throwaway user-dir first — sitometres' own output says nothing useful.

## CI

`.github/workflows/ci.yml` runs the fast layers on every push and pull request:
QML syntax, metadata lint, qmllint, the QML component tests and the LGX builds.
It also validates that the sitometres specs parse.

`.github/workflows/ui-tests.yml` runs the sitometres specs for real, on pushes
to `main`, on pull requests, and on demand. It builds Basecamp from source —
the inspector-enabled bundle is not in the public binary cache — but a warm Nix
store cache brings that to about three minutes. A fork PR, or the first run
after `BASECAMP_REV` changes, pays roughly nine minutes.
