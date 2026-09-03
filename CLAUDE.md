# Working on this repository

## Tests are part of the change, not a follow-up

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

### Known unresolved: `open` can hang

With everything above correct — inspector attached, Logos Core up, both modules
staged as `linux-amd64` and their libraries resolving — a local run still sat in
`step 1/19: the app opens` indefinitely, well past the spec's own 30s timeout,
with `radicle` never appearing in Basecamp's log. So `open` does not appear to
honour the spec timeout, and the plugin was not being loaded. Not yet root-caused
against a headless bundle; if you hit it, start from Basecamp's log in the
throwaway user-dir rather than from sitometres' output, which says nothing
useful. The CI job bounds this with a 30-minute step timeout so it fails with
artefacts rather than hanging the whole job.

## CI

`.github/workflows/ci.yml` runs the fast layers on every push and pull request:
metadata lint, qmllint, the QML component tests and the LGX builds. It also
validates that the sitometres specs parse.

`.github/workflows/ui-tests.yml` runs the sitometres specs for real, on pushes
to `main` and on demand. It is deliberately not on pull requests: it builds
Basecamp from source, because the inspector-enabled bundle is not in the public
binary cache, so it is measured in tens of minutes.
