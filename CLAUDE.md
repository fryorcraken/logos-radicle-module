# Working on this repository

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

### M1.1 — what the review pass found before merge

Three review agents (correctness/architecture, test quality, QML traps) ran
against the finished branch. The test-quality pass worked by mutation — revert
the fix, see whether any test notices — which is what turned up the first item
below and is worth repeating on future milestones.

- **Branch switching never reloaded anything.** See "A binding does not update
  inside the handler that changed its source" above. The headline feature of
  this milestone was broken end to end and every gate was green.
- **Two ways to record a wrong `lastSyncedCommit`**, both of which make the
  sync button claim a repository is current at a commit it never fetched —
  the one failure the staleness feature must never have. `pendingSyncHead` was
  cleared only in `reset()`, so a sync whose `ListBranches` failed committed
  the *previous* sync's head; and `syncAll()`'s head lookup read `branch` live
  in its callback, so a branch switch mid-lookup stored the new branch's head
  for a sync of the old branch's files.
- **Two tests that could not fail**, both fixed to assert the thing that
  actually broke: `CommitView`'s back-button test (a click test structurally
  cannot see a covering overlay, so it now asserts the overlay's visibility)
  and the branch-switch reset test (see above).
- **`pollEpoch` is load-bearing, though two of the three reviews said to
  delete it.** Its case is a `reset()` with rid and branch *unchanged* —
  re-opening the same repository — where the other guard terms match and only
  the epoch can drop a poll issued before the reset. The tests named for it
  did not pin it; one that does was added. Worth noting as a case where the
  reviews agreed with each other and were still wrong: the fix was to write
  the test that would settle it, not to take the majority view.
- **Dismissed:** a latent `states` property shadowing `Item.states` in
  `IssuesTab`/`PatchesTab`/`FilterChips`. Real, but empirically harmless
  today — `states` is not a default property, so child parenting is
  unaffected, and nothing in the codebase uses QML state machinery. Renaming
  three components' public property at release time is the riskier move.
  Worth doing in M1.2, before anyone adds a state-based transition and it
  starts failing silently.

### M1.1 — implemented on a branch, not yet merged to main

All three items below are done, on branch `worktree-agent-a42af4ef65b0dcc3b`
in a separate worktree — not on this `main`, and not pushed anywhere. Not
merged pending human review. All four test-layer gates that can run without a
live Basecamp are green: `check-qml-syntax.sh`, `run-qml-tests.sh` (13 files,
118 tests), and `cd radicle && nix build '.#checks.x86_64-linux.unit-tests'`
(34 tests). The sitometres end-to-end spec was not run or updated — it needs
a live Basecamp build, which was out of scope for that session, and it still
does not exercise branch switching or the sync button at all (pre-existing
gap, see "The end-to-end spec passes" above).

What landed, roughly in the order it was built:

- **Test-coverage follow-up**, done first to build context on the codebase's
  patterns. `NavState.qml` — the `nav.busy`/`nav.error` counter/latch logic —
  pulled out of `Main.qml` into its own component (same shape as
  `ListCache.qml`) so it is directly testable; `tst_nav.qml` added.
  `tst_sync_epoch.qml` added, using a deferred-reply fake backend (the
  technique `CommitsTab`'s staleness test already used) to actually trigger
  `SourceTab.syncEpoch`'s stale-reply-after-a-new-sync-starts path, which a
  synchronously-replying fake structurally cannot exercise. `tst_clicks.qml`
  gained `PatchesTab`'s `threadRow`. Writing `tst_commitview.qml` (previously
  no test file existed) found two real, previously unnoticed bugs in
  `CommitView.qml`, both fixed in the same change: the view rendered as a
  completely blank pane (its own `property var data` shadowed `Item`'s
  built-in default `data` property, silently breaking child-item parenting —
  caught by rendering the item and checking the grabbed image wasn't a flat
  colour), and the back button was unreachable for any commit with an empty
  diff (`LoadingState`'s overlay was keyed on `files.length` rather than "did
  a commit load", unlike `ThreadView`'s equivalent).
- **Branch switching.** The seed API had no dedicated branch-listing
  endpoint, but `getRepo()`'s response already carries the full refs map
  (`resolveSha()` already read it) — `SeedClient::listBranches()` reuses that
  one request. Wired through `remoteListBranches`/`localListBranches` (the
  latter the standard "no local backend" error, matching every other
  `local*` method), the `.rep`, and the backend forwarders, with unit tests
  in `test_seed_client.cpp`. UI: `BranchPicker.qml` (same
  dependency-injection shape as `SeedPicker.qml`, not editable — branches are
  a closed set), replacing the static branch chip in `RepoView.qml`.
  `RepoView.branch` is a live binding to `defaultBranch` that a pick
  overrides; switching repository re-binds it via `Qt.binding()` (not a
  one-shot copy) so a branch picked on one repo cannot leak its name into a
  different repo; switching branch resets and reloads only `SourceTab`/
  `CommitsTab` (the two tabs that are actually branch-scoped — Issues/
  Patches are repository-wide COBs). `tst_branch_switch.qml` added.
- **Sync staleness detection.** `SourceTab` gained `lastSyncedCommit` (the
  branch head captured when a sync completes, via the same `ListBranches`
  call branch switching added) and `checkForUpdate()`, a lightweight poll on
  a five-minute `Timer`, guarded by a new `pollEpoch` mirroring `syncEpoch`'s
  role. The sync button gets a third visual state ("Update", in
  `Theme.warn`) alongside "Download All"/"Re-sync"/in-progress — colour and
  label only, `onClicked` untouched, so re-syncing stays exactly as
  clickable in every state. `tst_staleness.qml` added, including two tests
  using a deferred-reply fake to prove the `pollEpoch` guard against a poll
  reply arriving after a repo/branch switch — confirmed to fail before the
  guard, per the regression-test-first rule.

Original scoping notes below, left as written at the time (branch listing
turned out to need no new seed HTTP endpoint, just reuse of `getRepo()` —
narrower than "check whether the API already exposes this" implied):

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
own environment for exactly this reason. Bash is for `lgs`, `nix`, `git`, `gh`
and running those scripts by absolute path.

## This is a scaffold-managed project — reach for `lgs` first

`scaffold.toml` at the root is a `logos-scaffold` (`lgs`) config, and both
modules are captured in it as `[modules.radicle]` / `[modules.radicle_ui]` with
`role = "project"`. That means the build, install, launch and dev-shell paths
all have an `lgs` verb, and reaching straight for `nix build` skips the part
scaffold does for you — resolving each module's flake ref, ordering the two
builds by dependency, and deriving the sibling `--override-input`.

**Version:** everything below needs `lgs` **v0.3.0 or newer** — that release
introduced the top-level `[modules.*]` schema this repo uses (v0.2.0 keyed them
under `[basecamp.modules.*]`) along with `develop`, `build`, `run` and `paths`.
The machine this was written on runs a master build, which also self-reports
`0.3.0`; master is a handful of fix commits ahead of the tag and adds no
subcommands, so the tagged v0.3.0 is enough. `lgs --version` cannot distinguish
the two — if a command here is missing, you are on v0.2.0 or older.

| Instead of | Run |
|---|---|
| `cd radicle && nix build '.#lgx'` (both modules, then `lgpm install`) | `lgs basecamp install` |
| `nix build '.#lgx-portable'` in each dir, with a hand-written `--override-input` | `lgs basecamp build-portable` |
| `nix build '.#lgx'` just to check it compiles | `lgs basecamp build --variant lgx [--module radicle_ui]` |
| `nix develop` in a module dir | `lgs basecamp develop radicle_ui` |
| launching Basecamp by hand | `lgs basecamp launch alice` |

`lgs basecamp paths alice` prints where that profile's log, module and XDG dirs
actually resolve to — quicker than guessing when a log is not where you expect.
`lgs basecamp doctor` reports drift between `[modules.*]` and the installed
profiles.

Two things `lgs` deliberately does **not** cover, both kept as raw `nix` below:
the core module's unit tests (`nix build '.#checks…'` — no `lgs` equivalent),
and the inspector-enabled Basecamp bundle for sitometres (a third-party flake
plus a workaround for a sitometres probe bug — outside scaffold's scope). CI
also stays on explicit `nix build` calls on purpose: it needs per-step
`--out-link` names and `--print-build-logs`, and per-sub-flake jobs give useful
matrix parallelism. Do not convert `.github/workflows/`.

### Your local `basecamp` skill copy may be a stale v0.2.0 one

`lgs init` generates `.claude/skills/`, `.cursor/` and `AGENTS.md`, and
`.gitignore` excludes all three — they are regenerated, not checked in. That
means the copy on your disk is whatever `lgs init` last wrote, and it does not
refresh itself when you upgrade `lgs`.

The copy on this machine is a **v0.2.0-era** one: it documents the schema as
`[basecamp.modules.<name>]` throughout (including its own activation criteria)
and omits `develop`, `build`, `run` and `paths`, so it reads as if `install` /
`launch` / `build-portable` were the whole verb set and raw `nix` the only way
to do anything else. That is exactly backwards for this repo.

**Upstream is already correct** — logos-scaffold's v0.3.0 skill has the
`[modules.*]` schema and all ten subcommands, so there is nothing to report.
Re-run `lgs init` to refresh the local copy. Until then, prefer this file, and
treat `lgs basecamp --help` as authoritative over either.

### If you are working in a git worktree

A worktree has no `.scaffold/` — that directory is untracked, so it does not
come along. `lgs basecamp doctor` there fails on missing basecamp/lgpm binaries
and missing `alice`/`bob` profiles until you run `lgs basecamp setup` in the
worktree itself.

What it does **not** mean is that you are building the main tree's code.
`scaffold.toml`'s module refs are relative (`path:./radicle#lgx`), and `lgs`
resolves them against the project root it was invoked from — so from a
worktree, `install` and `build-portable` build that worktree's sources. The
consequence is isolation, not a wrong-code hazard: the worktree's
`launch alice` is a *separate* Basecamp instance with its own profile state,
not the one the main tree launches.

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

## A binding does not update inside the handler that changed its source

`RepoView.onBranchChanged` reset Source and Commits and then called
`maybeLoad()` in the same breath. `SourceTab.branch` and `CommitsTab.branch`
are bindings to `RepoView.branch`, and inside that handler they have **not been
re-evaluated yet** — so the refetch went out for the branch the tabs were
already on, the reply repopulated the pane, and picking a branch did nothing
at all. The whole feature was dead on arrival and every gate was green.

If a handler changes a property and then calls something that reads a *binding*
derived from it, defer the call by one event-loop turn (a zero-interval
`Timer`) or pass the new value explicitly. Do not assume the binding has
settled.

This class is invisible to the end-to-end layer too: `branches.yaml` asserts
`treeCount > 0`, which is just as true of the old branch's entries left on
screen. It was caught only by a component test whose fake returns a **different
number of entries per branch**, so the count itself says which branch was
fetched.

Which is the general lesson, and the reason it hid for a whole milestone: a
fake that returns the same thing for every input cannot tell "reloaded" from
"never reloaded". The original test asserted `treeCount === 0` against a fake
returning an empty tree for every branch — true whether the reset ran, the
refetch ran, both, or neither. **Make fakes return input-dependent data**, or
the assertion is decoration. Deleting the entire `onBranchChanged` body left
all 122 tests passing.

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

The unit-test row is raw `nix` on purpose — `lgs` has no verb for a flake's
`checks` outputs. Everything *building* the modules goes through `lgs` instead;
see the tooling note above.

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

### Testing a branch from a worktree: do not use `lgs basecamp`

`lgs basecamp install` and `launch` read `scaffold.toml`, and its
`[basecamp.modules]` entries are **absolute paths into the main tree**
(`path:/…/radicle-logos-module/radicle`). Run from a worktree they therefore
build and install `main`'s code, not the branch you are testing — and they say
nothing about it, so the run looks fine while the change under test was never
loaded. One agent in this session lost time to exactly that.

From a worktree, build the worktree's own flakes and launch the pinned binary
yourself: `nix build '.#lgx-portable'` in each module directory (the UI one
with `--override-input radicle path:../radicle`), then point `--basecamp` at
the copied bundle. That is what the commands in this section already do.

Possible follow-up, not done: make `lgs` worktree-aware — a `--flake` override,
or relative module paths in `scaffold.toml` — so the tool does the right thing
from any checkout instead of needing this note.

Stage the **portable** modules, and say so explicitly:

```bash
lgs basecamp build-portable
# both modules land in .scaffold/basecamp/portable/ as <NN>-<module>.lgx
# then point sitometres at that directory and pass:
--variant linux-amd64
```

**No copying into `dist/` is needed** — and this used to say otherwise, so it
is worth being explicit about why. sitometres has no `--dist` flag. It takes a
single `--app-dir` search root (default: cwd) and looks for `.lgx` beneath it.
Both modules must be findable from that one root, because `browse.yaml`
declares `with: [radicle]`. The old instructions built each module separately —
two sub-flake `result-*` symlinks, no single directory holding both — so they
copied the pair into `dist/` purely to collect them. That was the entire reason
for the copy, and `build-portable` already does the collecting.

Confirmed by a real run rather than inferred: sitometres consumes
`.scaffold/basecamp/portable/` as-is. It follows the `/nix/store` symlinks and
is not confused by the `<NN>-` load-order prefix in the filenames — the two
details most likely to have broken it. Do not "fix" this back into a copy step.

Nothing on the sitometres side blocks this. The only sitometres bug still
worked around here is the inspector probe above.

`build-portable` builds both `role = "project"` modules in dependency order and
**derives the `--override-input radicle path:<abs>` itself**, by reading
`radicle-ui/flake.nix` — which is why that input must stay on one line:

```nix
radicle.url = "path:../radicle";
```

Scaffold's sibling-override parser is line-based. Flattening this into the
multi-line `inputs.radicle = { url = "…"; };` form is not a syntax error and
nothing warns: the override silently stops applying, and `radicle-ui` gets
built against the locked pin instead of the working tree. If a portable build
mysteriously ships stale core-module behaviour, check this line first.

(`build-portable` is an alias for `build --variant lgx-portable`. Use
`lgs basecamp build --module radicle_ui` when you only want one of them.)

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
to `main`, on pull requests, and on demand. It is a **matrix, one job per
spec** (`browse`, `branches`, `source`, `sync`) — `SPEC` used to be hardcoded
to `browse.yaml`, so three specs sat in the tree running nowhere. If you add a
spec, add it to that matrix, or it is decoration. `ci.yml`'s schema check
already globs `tests/ui/*.yaml` and needs no change. It builds Basecamp from source —
the inspector-enabled bundle is not in the public binary cache — but a warm Nix
store cache brings that to about three minutes. A fork PR, or the first run
after `BASECAMP_REV` changes, pays roughly nine minutes.
