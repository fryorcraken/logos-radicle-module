# Running the end-to-end layer

Read this when running, adding to, or debugging a sitometres spec
(`radicle-ui/tests/ui/*.yaml`). For which layer to reach for in the first
place, see "The test layers" in CLAUDE.md.

The whole sequence, in order. Steps 1 and 2 are one-time per machine; step 3
is the one you repeat.

```bash
# 1. The Basecamp with the QML inspector. That is the DEV `#app` — the
#    inspector is off in the shipping outputs, not in the dev build. The rev
#    is [repos.basecamp].pin in scaffold.toml, the one place it is written.
nix build "github:logos-co/logos-basecamp/$(tomlq -r '.repos.basecamp.pin' scaffold.toml)#app" \
  -o result-basecamp --accept-flake-config

# 2. Build the modules — the DEV variant, matching the dev Basecamp — and run
#    the spec.
lgs basecamp build --variant lgx
npx --yes '@paradoxcomputer/sitometres@0.1.2' \
  run radicle-ui/tests/ui/browse.yaml \
  --app radicle_ui \
  --app-dir .scaffold/basecamp/lgx \
  --basecamp ./result-basecamp/bin/LogosBasecamp \
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

## Running specs no longer conflicts with `lgs basecamp launch`

It used to. `setup --inspector` moved `[repos.basecamp].attr` **and**
`[repos.lgpm].attr` to the portable stack and persisted both to
`scaffold.toml`, so a spec run and an interactive `lgs basecamp launch` needed
mutually exclusive project state — and the switch was whole-project even from a
worktree, because `scaffold.toml` is tracked. Flipping it under someone doing
manual testing broke their session with a message that did not name the cause.

**Both now work at once.** The e2e layer builds its own Basecamp to a local
out-link and touches neither `attr` key, so `scaffold.toml` no longer encodes
which of the two you are doing. Nothing to flip, nothing to revert, nothing to
avoid committing.

The one caveat that survives is unrelated to scaffold: two Basecamps against
the same `~/.radicle` still contend, which is the `local.yaml` step-9 note at
the end of this file.

## Why the dev `#app`, and not the inspector bundle

The specs need a Basecamp built **with the QML inspector**, a compile-time
feature. For a long time this file said that meant
`#bin-bundle-dir-inspector`, and the job built it through
`lgs basecamp setup --inspector`. **That was wrong, and cost a great deal of
incidental complexity.** Reading logos-basecamp's `flake.nix` at the pinned
rev:

| attr | inspector | feeds |
|---|---|---|
| `app` | **on** (`inherit logosQtMcp`, no `enableInspector` flag) | the dev build |
| `appDistributed` | off (`enableInspector = false`) | `#bin-bundle-dir`, appimage, macos |
| `appDistributedWithInspector` | on | `#bin-bundle-dir-inspector` |

The inspector is off in the **shipping** outputs — which is what the flake's
own comment says — not off in the dev build. Upstream's `integration-test` and
`shutdown-test` checks, both inspector-driven, use `appPkg = app`.

Verified rather than inferred, with the same probe sitometres uses (searching
for the literal `[QmlInspector] Inspector server listening on port`):

| build | sibling probed | needle |
|---|---|---|
| `#app` | `bin/.LogosBasecamp` | present |
| `#bin-bundle-dir-inspector` | `bin/.LogosBasecamp.elf` | present |
| `#bin-bundle-dir` (shipping) | `bin/.LogosBasecamp.elf` | **absent** |

That last row is the control: it proves the probe discriminates rather than
matching anything it is pointed at. `ui-tests.yml` asserts the `#app` row on
every run, so a future Basecamp flipping `enableInspector` off for the dev
build fails loudly instead of silently removing the inspector this layer
depends on.

Three consequences, and together they are why this is a simplification:

- **No `basecamp setup`.** It also built lgpm and seeded `alice`/`bob`
  profiles this job never used, and it rewrites `scaffold.toml`, stripping
  every comment — which is why the pin had to be read *before* it ran. That
  ordering constraint is gone with it.
- **No `--variant` override.** sitometres' `hostVariant()` defaults to
  `linux-amd64-dev`, exactly what `.#lgx` produces. The override existed only
  because the bundle demands portable variants.
- **No dev-vs-portable classification problem** — the entire subject of
  [logos-co/scaffold#265](https://github.com/logos-co/scaffold/issues/265).
  It only ever arose from choosing the bundle.

The one raw `nix build` here is deliberate: `lgs` has no verb that builds a
Basecamp attr without also running `setup`'s profile seeding.

## Why `SITOMETRES` is a plain version again

It was pinned to a fork commit for the **inspector probe bug**: released
sitometres refused the *bundle* with "no Basecamp with the QML inspector
compiled in" even though the inspector was there, because `hasInspector()` in
`src/app/discover.ts` probed `bin/LogosBasecamp` (a ~5 KB sh wrapper) and
`bin/.LogosBasecamp`, never the `bin/.LogosBasecamp.elf` that nix's
`dirBundler` ships for a bundle. Filed as
[paradoxcomputer/sitometres#1](https://github.com/paradoxcomputer/sitometres/issues/1).

**The dev `#app` ships `bin/.LogosBasecamp`** — the spelling the released probe
has always looked for — so that bug is not on this path at all. Confirmed by
running `browse.yaml` green on both `0.1.0` and `0.1.2` against the dev app
before the switch.

**Pin the version, never a range or `latest`.** A moving ref would silently
change the tool that gates every spec.

**Do not point `--basecamp` at the `.LogosBasecamp` ELF directly** — that
clears the probe and then fails to spawn with `ENOENT`, because the wrapper is
what sets the library and Qt plugin paths. The wrapper is the binary; the
dot-file is what the probe needs to *find beside* it.

**Check the issue tracker before re-filing.** #1 was filed twice — the second
time by an agent that found the bug in sitometres' source and opened a
duplicate without looking first.

## Why `--app-dir` points straight at the build directory

**No copying into `dist/` is needed.** sitometres has no `--dist` flag; it
takes a single `--app-dir` search root and looks for `.lgx` beneath it. Both
modules must be findable from that one root, because `browse.yaml` declares
`with: [radicle]`. The old instructions built each module separately — two
sub-flake `result-*` symlinks, no single directory holding both — so they
copied the pair into `dist/` purely to collect them. `lgs basecamp build`
already does the collecting.

Confirmed by a real run rather than inferred: sitometres consumes
`.scaffold/basecamp/lgx/` as-is. It follows the `/nix/store` symlinks and is
not confused by the `<NN>-` load-order prefix — the two details most likely to
have broken it. **Do not "fix" this back into a copy step.**

## Keep `radicle.url` on one line

`lgs basecamp build` builds both `role = "project"` modules in dependency order
and **derives the `--override-input radicle path:<abs>` itself**, by reading
`radicle-ui/flake.nix` — which is why that input must stay on one line:

```nix
radicle.url = "path:../radicle";
```

Scaffold's sibling-override parser is line-based. Flattening this into the
multi-line `inputs.radicle = { url = "…"; };` form is not a syntax error and
nothing warns: the override silently stops applying, and `radicle-ui` gets
built against the locked pin instead of the working tree. If a build
mysteriously ships stale core-module behaviour, check this line first.

## Why there is no `--variant` flag

There used to be one, and the reason it is gone is worth keeping: **the
Basecamp and the modules must come from the same stack.**

sitometres unpacks one platform variant from the `.lgx`, defaulting to
`hostVariant()` — `linux-amd64-dev`. A dev Basecamp accepts exactly that; a
portable bundle accepts only `[linux-x86_64, linux-amd64]`. Since this layer
now runs the dev `#app` with `.#lgx` modules, the default is already right and
`--variant linux-amd64` would *break* it.

Mismatch the halves either way and Basecamp logs one line —

```
Warning: module 'radicle' … was installed for variant '<x>' which is
not supported on this platform and will not be loadable
```

— then the UI opens to nothing and the spec times out on its first step, with
nothing in sitometres' output explaining why. The pairing is what matters, not
the particular flag.

## `local.yaml` needs RAD_HOME — run it with `run-local-e2e.sh`

sitometres gives every run a **throwaway `$HOME`** so a test cannot touch your
real wallets and keys. `LocalStore` resolves the Radicle home from `RAD_HOME`,
else `$HOME/.radicle` — so under that throwaway HOME there is no profile,
`getCapabilities` reports `localAvailable=false`, and `local.yaml` fails with

```
state "root.localAvailable === true" — evaluated to false
```

on **every** machine, including one with a perfectly good profile.

Two details of that sentence have since changed. The toggle does **not** hide
its "Local" segment — the three-segment control draws all three and annotates
the ones that cannot work, so the click target is always there. And that
assertion now runs **after** the click rather than before it, because
`localAvailable` is reported for the mode in force and the app starts in
`explore`; see "The app starts in Explore" below.

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

## The app starts in Explore, and every spec depends on that

A run under sitometres has a throwaway `$HOME` and therefore no settings file,
so what the app opens in is `SettingsStore::load()`'s **default mode**. That
default is `explore`, and the reason is the one this layer proves: `explore` is
the only mode that can show anything without a local profile, which is exactly
what a throwaway `$HOME` — and a first-run user — has.

It was `local` for one milestone, defended by a comment about not changing
behaviour for existing users. Every seed-browsing spec (`browse`, `branches`,
`source`, `sync`) went red at once, all at the step where repositories were
supposed to arrive, because the app issued `localListRepos` against a home that
did not exist and never asked the seed. `write` survived only because it clicks
`sourceToggle_local` explicitly rather than relying on the default — which is
the useful signal, not luck: **a spec that names the mode it needs is immune to
the default moving.**

Two consequences for writing specs here:

- **Do not assert `localAvailable`, `canWrite`, `nodeIdentity` or anything else
  mode-scoped before switching modes.** `storeForSettings()` hands Explore a
  store with no home *by design* — Explore means "do not touch a local profile"
  — so all of them are false in Explore however good the profile is. `local`
  and `write` both had such assertions ahead of their click, passing only
  because the default happened to be `local`; both now click first.
- **Prefer `wait_for` over `expect` for anything downstream of a mode click.**
  Switching mode is a backend round trip (`setSetting`, then a fresh
  `getCapabilities`), so a synchronous `expect` immediately after the click
  races the reply.

The QML side has a matching default: `SourceState.mode` starts at `explore` and
`Main.qml` binds `caps.mode || "explore"`. That fallback covers the window
between `Component.onCompleted` and the first capabilities reply — and it is a
real window, because `onBackendReady()` calls `repoList.reload()` without
waiting for one. `tst_source.qml` pins it on a `SourceState` nothing has
assigned to, which is the only way to observe it.

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
Basecamp flake attr, and since `lgs basecamp build` absorbed the
build-and-collect dance the remaining flow is two commands.

That leaves `radicle-ui/tests/run-e2e.sh`, matching `run-qml-tests.sh` and
`check-qml-syntax.sh` beside it — same pattern, no arguments, sets its own
environment. Worth adding **when someone writes it against a verified-working
invocation** rather than transcribing this file. The thing to get right: step 1
is expensive and one-time, so it must detect an existing `result-basecamp` and
skip it, or it will rebuild Basecamp on every run and nobody will use it.
