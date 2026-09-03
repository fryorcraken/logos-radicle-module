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
- **Architectural note for M2, not urgent now:** `Main.qml`'s `call()`
  hardcodes `"remote" + method` — every QML caller is wired to the `remote*`
  source with no way to choose `local*`, even though the core module's
  `local*` surface is already fully implemented and forwarded. Fine today
  (there's no local-node UI yet), but when M2 adds one, every call site
  threading through `Main.qml.call()` will need a `source` parameter added.
  Cheaper to add that parameter now (default `"remote"`, no behaviour
  change) than to retrofit it across seven files once M2 lands.
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

### What is left, in order

1. **Commit and push** to both remotes: `git push origin main` and
   `git push rad main`.
2. **Release CI**: `ci.yml` already has a `release` job attaching `.lgx`
   artefacts on a `v*` tag, but it has never run. Check it produces both
   portable and `-dev` variants.
3. **Cut the first release** and confirm the assets are attached.
4. **Register in the catalog.** The fork already exists at
   `fryorcraken/logos-modules` (from `logos-co/logos-modules-release-base`).
   Still to do: edit its `logos-repo.json` (replace every `CHANGE-ME`, point
   `indexUrl` at the fork), run `./scripts/add-module.sh` for this repo, then
   run its **Release all modules** workflow.
5. **Hand over the catalog URL** for prod Basecamp:
   `https://raw.githubusercontent.com/fryorcraken/logos-modules/main/logos-repo.json`
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
