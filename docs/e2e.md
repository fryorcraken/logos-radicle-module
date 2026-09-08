# Running the end-to-end layer

Read this when running, adding to, or debugging a sitometres spec
(`radicle-ui/tests/ui/*.yaml`). For which layer to reach for in the first
place, see "The test layers" in CLAUDE.md.

The whole sequence, in order. Steps 1 and 2 are one-time per machine; step 3
is the one you repeat.

```bash
# 1. The inspector Basecamp — via `lgs`, no raw `nix build`. The rev comes
#    from [repos.basecamp].pin in scaffold.toml; --inspector selects the attr
#    AND classifies it as the portable stack.
#    It writes basecamp_bin= to .scaffold/state/basecamp.state.
lgs basecamp setup --inspector

# 2. Read where setup put the bundle. No copy, no symlink: --basecamp points
#    straight at scaffold's own binary inside the read-only out-link. Source
#    the state file rather than reconstructing the path or hunting /nix/store.
. .scaffold/state/basecamp.state

# 3. Build the modules and run the spec. Match CI's SITOMETRES pin exactly —
#    the probe fix that makes step 2 a one-liner is unreleased, so plain
#    `@0.1.0` (or an unpinned npx) refuses the bundle.
lgs basecamp build-portable --print-output
npx --yes 'github:fryorcraken/sitometres#ab6b3ea20fa74bd480705856660defdbd4160fd9' \
  run radicle-ui/tests/ui/browse.yaml \
  --app radicle_ui \
  --app-dir .scaffold/basecamp/portable \
  --basecamp "$basecamp_bin" \
  --variant linux-amd64 \
  --strict          # without it sitometres exits 0 on INCONCLUSIVE
```

Everything below is why each of those lines is shaped the way it is.

## Writing specs

Prefer `state:` over `text:`. `text:` reads QML properties rather than pixels,
so it also matches items that are loaded but hidden — a cached `StackLayout`
page keeps answering for a screen the user has navigated away from. `state:`
asks the app what it believes is true.

Assert on `calls:` when the point of the change is that a call happens. A step
that only checks what is on screen will pass against a view rendering stale
cached data. **But note `calls:` does not work for QML→backend hops here**: QML
dispatches through the `radicle_ui` QtRO replica and that hop is not logged as
a LogosAPIClient invocation, so sitometres reports "no backend calls at all"
while the data plainly arrives. Assert the effect with `state:` instead.

**`objectName` must sit on the clickable element**, not its parent. Naming a
Repeater delegate matched one element instead of four, because the delegate
Item is not clickable — its MouseArea is.

Give anything a spec needs to click a stable `objectName`. Specs select by
`objectName`, not by label, so renaming a button must not break a test — and
changing an `objectName` is an interface change.

**Add new specs to the `ui-tests.yml` matrix.** It runs one job per spec;
`SPEC` was once hardcoded to `browse.yaml` and three specs sat in the tree
running nowhere. A spec outside the matrix is decoration. `ci.yml`'s schema
check already globs `tests/ui/*.yaml` and needs no change.

## What this layer structurally cannot see

Worth knowing before you try to cover something here and quietly fail to.

**Window geometry — there is no way to drive it.** The step vocabulary is
closed and validated (`open`, `click`, `type`, `eval`, `set`, `wait_for`,
`sleep`, `screenshot`, `expect`; an unknown key throws), and none of it takes a
size. Neither does any CLI flag — `--headed` shows the window but does not size
it. `geometry` exists in sitometres' inspector protocol only as a **read-only**
field it never writes.

`eval:` is unvalidated passthrough, so `root.Window.window.width = 1400` *would*
be forwarded — but the run is on the `offscreen` platform plugin where resizing
is meaningless, the app's root is docked inside Basecamp's own layout which
would override it on the next relayout, and `eval:` is a side-effect step whose
result is never asserted on. Do not reach for it: what you would add is a step
that cannot see the thing it claims to cover.

This matters because a whole class of real defects lives there — the Settings
chip pushed off the right edge below ~750px, the header drawn twice in a very
tall window. Both were found by dragging a window edge and both passed CI.
**They belong at the component layer**, where a fixture owns the geometry:
`tst_header_width.qml` drives the width down across a range and asserts the
Settings chip keeps pixels on screen *and* stays clickable; `tst_layout.qml`
asserts the header is drawn once. Measure against the container's bounds, not
against `item.width` — an overflowing `RowLayout` child keeps its full width and
its `visible` stays true, so every property-based check passes while the user
sees nothing.

**The system clipboard does not work.** sitometres forces
`QT_QPA_PLATFORM=offscreen`, and the clipboard round-trip inside the Basecamp
bundle fails there. Measured, not assumed: `local.yaml`'s identity click lands
and `NodeIdentity`'s copy confirmation correctly declines to appear, because
that confirmation is *earned* — the element pastes the clipboard back and
compares before claiming success.

Note `tst_source.qml` carries a comment asserting the opposite ("an offscreen Qt
platform plugin always provides one"). That is true of `qmltestrunner` against
the host session and **not** of the bundle, so neither layer can prove the copy
happy path end to end: the component layer has a clipboard but not the bundle,
and the bundle has no clipboard. What `local.yaml` asserts instead is that the
control is wired and inert-safe — the click reaches a handler, no QML error is
raised, and the view is intact afterwards.

**What to assert when the interesting thing is unreachable.** Prefer a state
that is *never correct in any configuration*, so it needs no known-good
baseline. `RepoList.sayingNothing` is the worked example: no rows, and no
rendered explanation of why. `repoCount === 0` cannot catch a blank pane —
it is exactly what a working empty node reports — but "nothing on screen and
nothing saying why" is wrong at any window size, in any mode, on any profile.
Read such a property off the placeholder items' own `visible` rather than
recomputing their conditions, or it will agree with them while they render
nothing.

## `setup --inspector` and `lgs basecamp launch` cannot coexist

`--inspector` does not only pick a different Basecamp: it moves
`[repos.basecamp].attr` **and** `[repos.lgpm].attr` to the portable stack
(`bin-bundle-dir-inspector` / `cli-portable`), and it persists both to
`scaffold.toml`. That is exactly what the specs need and exactly what an
interactive `lgs basecamp launch` cannot use — the dev profiles are seeded for
the dev stack, so a launch afterwards fails with **"no variant for this
stack"** and the app opens to nothing.

The two states are mutually exclusive, and the switch is a whole-project one
even from a worktree, because `scaffold.toml` is tracked and shared. So:

- **Before running `setup --inspector`, check nobody is driving Basecamp by
  hand.** Flipping it under someone doing manual testing breaks their session
  with a message that does not name the cause.
- **`lgs basecamp setup --no-inspector` reverts it**, and is what to run when
  handing the machine back for interactive use.
- Leaving the two `attr` lines flipped in your working tree is what a spec run
  needs, but **do not commit them** — they are local machine state, not a
  project decision. `git diff scaffold.toml` after any `setup` shows both them
  and the comment stripping described above; restore the comments, keep the
  attrs, commit neither.

CI is unaffected: each runner does one or the other and is destroyed.

## Why step 1 is `lgs` and not `nix`

The specs need a Basecamp built **with the QML inspector**, a compile-time
feature that is off in the shipping AppImage. This used to be a raw `nix build`
because scaffold had no way to select that output; `setup --inspector` closed
it. What has not changed is that this is the expensive, one-time-per-machine
step, and that it produces a bundle sitometres still cannot consume directly —
which is step 2, and is not licence to hand-roll the module builds too.

## Why `SITOMETRES` is a git commit (the inspector probe bug)

**Published sitometres (0.1.0) cannot run this bundle at all.** It refuses with
"no Basecamp with the QML inspector compiled in" even though the inspector is
there: `hasInspector()` in `src/app/discover.ts` probes exactly
`bin/LogosBasecamp` (a ~5 KB sh wrapper) and `bin/.LogosBasecamp` (absent),
never the `bin/.LogosBasecamp.elf` that nix's `dirBundler` actually ships.

That bug is why this job used to carry a copy-and-symlink step — `cp -RL` the
bundle somewhere writable, then create the filename the probe wanted. **That
step is gone.** `ui-tests.yml` and step 2 above point `--basecamp` straight at
scaffold's `basecamp_bin`.

Filed as
[paradoxcomputer/sitometres#1](https://github.com/paradoxcomputer/sitometres/issues/1),
fixed by [#3](https://github.com/paradoxcomputer/sitometres/pull/3), which is
open — hence a git pin rather than a version. The fix probes three spellings
(`.<base>`, `.<base>.elf`, `.<base>-wrapped`) and resolves symlinks before
looking beside the binary; `-wrapped` is what nixpkgs `makeWrapper` emits.

`npx` on a git ref runs the package's `prepare` script, so the TypeScript is
compiled at install time and no published artefact is needed.

**Pin the commit, never the branch.** A moving ref would silently change the
tool that gates every spec — the same hazard `LGS_REV` guards against, and one
this repo watched happen for real when scaffold#266 was force-pushed
mid-session. Revert to `@paradoxcomputer/sitometres@<version>` once #3 ships;
nothing else changes, because the workaround step is already deleted.

**Do not point `--basecamp` at the `.elf` directly** — that clears the probe
and then fails to spawn with `ENOENT`, because the wrapper is what sets the
bundled library and Qt plugin paths. The wrapper is the binary; the `.elf` is
what the probe needs to *find beside* it.

**Check the issue tracker before re-filing.** This was filed twice — the second
time by an agent that found the bug in sitometres' source and opened a
duplicate without looking first.

## Why `--app-dir` points straight at the portable directory

**No copying into `dist/` is needed.** sitometres has no `--dist` flag; it
takes a single `--app-dir` search root and looks for `.lgx` beneath it. Both
modules must be findable from that one root, because `browse.yaml` declares
`with: [radicle]`. The old instructions built each module separately — two
sub-flake `result-*` symlinks, no single directory holding both — so they
copied the pair into `dist/` purely to collect them. `build-portable` already
does the collecting.

Confirmed by a real run rather than inferred: sitometres consumes
`.scaffold/basecamp/portable/` as-is. It follows the `/nix/store` symlinks and
is not confused by the `<NN>-` load-order prefix — the two details most likely
to have broken it. **Do not "fix" this back into a copy step.**

## Keep `radicle.url` on one line

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

## Why `--variant linux-amd64`

sitometres unpacks one platform variant from the `.lgx` and defaults to
`linux-amd64-dev`, which suits the dev app (`#app`) but not the bundle. The
bundle accepts only `[linux-x86_64, linux-amd64]`, so staging `.#lgx` gets you
a line in Basecamp's log —

```
Warning: module 'radicle' … was installed for variant 'linux-amd64-dev' which is
not supported on this platform and will not be loadable
```

— and then a UI that opens to nothing and a spec that times out on its first
step, with nothing in sitometres' output explaining why. Both halves are
needed: the portable build *and* `--variant`.

## `local.yaml` needs RAD_HOME — run it with `run-local-e2e.sh`

sitometres gives every run a **throwaway `$HOME`** so a test cannot touch your
real wallets and keys. `LocalStore` resolves the Radicle home from `RAD_HOME`,
else `$HOME/.radicle` — so under that throwaway HOME there is no profile,
`getCapabilities` reports `localAvailable=false`, the toggle hides its "Local"
segment, and `local.yaml` fails at step 3 with

```
state "root.localAvailable === true" — evaluated to false
```

on **every** machine, including one with a perfectly good profile.

That spec's header used to claim the failure meant "this machine has no Radicle
profile". It did not, and the mistake was expensive: the one automated check
covering local browsing was permanently red for a reason unrelated to the code
under test, so it was never run, and the local path shipped with no working
end-to-end coverage at all. **A check that cannot pass is worth no more than
one that cannot fail.**

`radicle-ui/tests/run-local-e2e.sh` passes `--env RAD_HOME=<your profile>`,
which restores local browsing while keeping the throwaway HOME's isolation. Use
it rather than invoking sitometres by hand. `--real-home` would also work and
is deliberately not used: it hands the app every credential in `$HOME` to make
one directory readable.

**It IS in CI**, and this section used to say the opposite. The exclusion was
justified by "a CI runner has no Radicle profile, and seeding one is its own
piece of work" — which stopped being true the moment
`examples/seed_write_profile.rs` was written for `write.yaml`. That seeder
builds a profile with a signable key, a repository, an issue and branches
belonging to two peers, and `ui-tests.yml` now runs it for both `write` and
`local`, handing each the result as `RAD_HOME`. The reason outlived itself by
long enough that half the module — everything reading `~/.radicle` — had no
end-to-end coverage anywhere.

`run-local-e2e.sh` is the *local* route to the same spec, pointed at your own
node rather than a seeded fixture. Almost every assertion holds either way;
`local.yaml` names the one step that does not and says why.

One caveat before you chase a ghost: step 9 (`treeCount > 0`) can fail
spuriously when **another Basecamp is running against the same `~/.radicle`** —
two processes contending on the same git storage. Five consecutive clean runs
with no other instance up; two failures while an interactive `lgs basecamp
launch alice` was being driven by hand. Close the interactive instance first,
and do not read a lone step-9 failure as a code defect until you have.

## If `open` hangs on step 1

This was once recorded as unresolved. It was not a sitometres or headless-bundle
problem: the QML had a **syntax error**, so the view never compiled and the
plugin never loaded. `check-qml-syntax.sh` now catches that class before it can
ship. If step 1 hangs again, read Basecamp's log in the throwaway user-dir
first — sitometres' own output says nothing useful.

## Should this be a `scaffold.toml` script, or a `run-e2e.sh`?

**Neither yet — and if either, `run-e2e.sh`.**

`scaffold.toml` has no general script or task surface. Its schema is
`[repos.*]`, `[modules.*]`, `[wallet]`, `[framework]`, `[localnet]`,
`[circuits]`, `[basecamp.env]`, `[basecamp.profiles.*]`. The one hook-like
surface is `lgs run`'s post-deploy hooks, bolted to the LEZ pipeline — build,
localnet, topup, deploy. This repo runs no localnet and deploys no guest
programs, so there is nothing for them to hang off.

Nor is it worth asking scaffold for an `lgs basecamp test` verb: that means
scaffold taking a dependency on one third-party test tool and a hardcoded
Basecamp flake attr, and since `build-portable` absorbed the build-and-collect
dance the remaining flow is two commands.

That leaves `radicle-ui/tests/run-e2e.sh`, matching `run-qml-tests.sh` and
`check-qml-syntax.sh` beside it — same pattern, no arguments, sets its own
environment. Worth adding **when someone writes it against a verified-working
invocation** rather than transcribing this file. The thing to get right: steps
1 and 2 are one-time and expensive, so it must detect an existing bundle and
skip them, or it will rebuild Basecamp on every run and nobody will use it.
