# Working on this repository

## Status — 2026-09-03

### Uncommitted work in the tree

Everything below is edited but **not committed, not built, not in Basecamp**.
Run the gates, rebuild both modules, then commit.

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
- **Three bugs from the architecture review**, each with the reasoning in a
  comment at the site:
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
- **`tst_clicks.qml` (new)** — the first test here that issues a real
  `mouseClick` rather than emitting a signal by hand.
- **Icon** is now the Radicle alien. The first attempt drew it on its own
  rounded tile with padding, which left a tiny glyph inside Basecamp's *own*
  tile — so it is now transparent and fills 95% of the canvas, with the strokes
  thickened (`ImageFilter.MaxFilter`) so the outline survives being scaled down
  to sidebar size. **Regenerate rather than hand-edit**: it is produced from
  Noto Emoji with PIL, and the colour font renders as an empty glyph through
  PIL, so use `NotoEmoji-Regular.ttf`, not `Noto-COLRv1.ttf`. Not yet seen in
  Basecamp — needs the rebuild in step 2 below to confirm the size reads well.

### One failing test — a real bug, not a flaky test

`tst_clicks.qml::test_a_commit_row_click_activates_it` fails. Issue rows click
fine; commit rows do not, despite `CommitsTab.qml` and `IssuesTab.qml` looking
structurally identical at the delegate. **Diff the two delegates carefully** —
the difference is subtle and is the actual bug. 62 of 63 component tests pass.

This test earning its keep is the point: the earlier "click" test emitted the
signal directly, so deleting `onClicked` left it passing. See the rule below.

### What is left, in order

1. **Fix the commit-row click**, then run the gates:
   `radicle-ui/tests/check-qml-syntax.sh` and
   `radicle-ui/tests/run-qml-tests.sh` (both take no arguments and set
   `QT_QPA_PLATFORM` themselves).
2. **Rebuild and reload Basecamp** to confirm commit detail and diffs render,
   and that the alien icon now reads at sidebar size (it was too small before;
   the fix is in the tree but has never been seen running):
   `cd radicle-ui && nix build '.#lgx' --override-input radicle path:../radicle`,
   then `lgs basecamp launch alice --log-file --quiet`. Verify it is up with
   `ps -eo comm | grep -i logosbasecamp` — the process is named
   `.LogosBasecamp`, and the log file is stale between runs, so a log grep will
   happily report a Basecamp that is not running.
3. **Commit and push** to both remotes: `git push origin main` and
   `git push rad main`.
4. **Release CI**: `ci.yml` already has a `release` job attaching `.lgx`
   artefacts on a `v*` tag, but it has never run. Check it produces both
   portable and `-dev` variants.
5. **Cut the first release** and confirm the assets are attached.
6. **Register in the catalog.** The fork already exists at
   `fryorcraken/logos-modules` (from `logos-co/logos-modules-release-base`).
   Still to do: edit its `logos-repo.json` (replace every `CHANGE-ME`, point
   `indexUrl` at the fork), run `./scripts/add-module.sh` for this repo, then
   run its **Release all modules** workflow.
7. **Hand over the catalog URL** for prod Basecamp:
   `https://raw.githubusercontent.com/fryorcraken/logos-modules/main/logos-repo.json`
   — unverified until step 6 is done.

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
