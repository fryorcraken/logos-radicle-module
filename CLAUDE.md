# Working on this repository

## Where to look for what

This file is the always-relevant part: how to build and run things, the test
layers, and the traps that have bitten changes here. Two areas have their own
file, because they only matter when you are doing that specific thing. **Read
them when the trigger applies, not otherwise:**

| Read | When |
|---|---|
| [`docs/rust-ffi.md`](docs/rust-ffi.md) | Touching `radicle/rust-ffi/`, the `local*` read path, or `flake.nix`'s per-system handling |
| [`docs/writes.md`](docs/writes.md) | Touching the `local*` **write** path — `cobwrite.rs`, `LocalWriter`, the composers — or adding a write action |
| [`docs/e2e.md`](docs/e2e.md) | Running, adding to, or debugging a sitometres spec (`radicle-ui/tests/ui/*.yaml`) |

`docs/` also holds the design and planning documents those link to:
`M2.2-write-actions-design.md` (shipped), `M2.2-write-features-proposal.md`
and `M3-embedded-node-plan.md` (not started).

## What this is, and where it stands

Two modules in one repo, published to the Logos catalog from GitHub:
`radicle/` (core — all HTTP, JSON, filesystem and FFI) and `radicle-ui/`
(QML view, forwards everything to core). The split is forced: Basecamp
sandboxes the QML engine, so a view cannot fetch or read anything itself.

The API names its source explicitly rather than hiding it behind one call —
`remote*` proxies to a seed node over HTTP, `local*` reads this machine's
`~/.radicle` through the Rust staticlib. They are different questions with
different answers, so they stay different methods; the JSON shapes they return
are identical, so a view renders either without branching. Every method returns
a JSON string, and failures are always `{"error":"..."}`.
`radicle/src/radicle_impl.h` is the full contract.

**Reading works everywhere:** browsing any public repo through a seed (search,
paging, file tree, blob viewer, README, sync-to-cache, commits with diffs,
issues and patches with full discussion), branch switching, sync staleness
detection, and the same surface again against the local node.

**Writing has begun, local node only.** Two write actions are on `main` and
covered end to end: commenting on an issue, and creating one. Both are gated on
`getCapabilities().canWriteLocal`, a real probe — a profile can exist while its
key stays locked, so **gate every write affordance on `canWriteLocal`, never on
`localAvailable`**. Closing/reopening, labels, assignees, patch review and
commenting on a patch are deliberately deferred; see
[`docs/writes.md`](docs/writes.md).

**Current version is 0.2.1** — the writes are merged but not yet released.
Both modules' versions must match, and `ci.yml` asserts it.

Two facts about releasing that are not recoverable from git history, both
consequences of this repo being a monorepo (two modules under one git repo)
where the catalog expects one module per submodule:

- **The catalog's release action must support a `module_path` pointing *inside*
  a submodule.** Older versions fail checkout with "pathspec did not match any
  file(s) known to git" for this layout. The fix is commit `974960591a8d`,
  which is the tip of tag `v1.3`, and the catalog's `_release-module.yml` is
  pinned to `@v1.3` (catalog commit `06078c6`). Upstream has since advanced the
  moving `v1` tag to the same commit, so `@v1` would also work; `@v1.3` is kept
  deliberately, because a moving tag would let the release pipeline change
  under the catalog without a commit here saying so.
- **The catalog's `release-all.yml` auto-discovery cannot see this repo's two
  modules**, because it reads module paths straight from `.gitmodules`
  submodule paths. `radicle` and `radicle_ui` each need their own
  manually-triggered workflow, not the umbrella.

## How to work in this repo, and what Bash costs

**Reach for `lgs` for anything build-, run- or install-shaped.** This is a
scaffold-managed project; the next section is the verb table. Raw `nix build`
has exactly **one** legitimate use left here — the core module's unit tests,
because `lgs` has no verb for a flake's `checks` outputs. The inspector
Basecamp used to be the second and no longer is: `lgs basecamp setup
--inspector` builds it (see below). If you find yourself writing a `nix build`
pair with a hand-written `--override-input`, or `mkdir dist && cp
result-*/*.lgx`, stop — `lgs` already does that, and does it in dependency
order.

Read files with the `Read` tool, not `cat` or `grep` through Bash.

The permission setup blocks Bash commands it cannot statically analyse, and
each one costs the user a manual approval click. What that means in practice:

| Free — never prompts | Costs a click every time |
|---|---|
| the `Read` tool, for any file | `cat`, `grep`, `ls`, `head`, `tail` |
| one plain command per call | `\|`, `&&`, `;`, `$(…)`, `<(…)` |
| `lgs …`, `git …`, `nix build …` | a glob, a loop, a `VAR=value` prefix |
| `gh api …`, `gh pr …`, `gh run …` | the same with `--jq` appended |
| the test scripts, by absolute path | `sh <relative-path>` |
| | reading a path under `/nix/store` |

Three that catch people repeatedly:

- **`gh` is free until you filter it.** `gh api repos/o/r/releases` runs
  unprompted; adding `--jq '.[].tag_name'` makes it unanalysable and costs a
  click. Run it plain and read the JSON — that costs nothing.
- **Never `readlink` or `ls` a `/nix/store` path** to find out where an
  artefact went. The paths are documented below; use them.
- **Do not `curl` a third-party API to predict whether a command will work.**
  Run the command. `curl https://crates.io/…` to check a version exists is
  both blocked from this sandbox (it returns empty, which reads as "not
  found") and pointless — `cargo install <crate> --version X` answers the same
  question by succeeding or failing, and leaves you with the tool installed.
  Where a fact really is needed up front, `gh api` reaches GitHub without a
  prompt; reach for that instead of inventing a network call.

The test scripts take no arguments and set their own environment for exactly
this reason.

### Scratch files go in `./tmp/`, not `/tmp`

`./tmp/` at the repo root is this project's agent scratch space and is already
gitignored. Use it for intermediate files — extracted sections, assembly
parts, command output you need to re-read, anything that is working material
rather than a deliverable.

Do **not** use `/tmp`, `$TMPDIR`, or a session scratchpad outside the repo,
even when a harness offers one. Scratch that lives beside the work is visible
to the person reviewing it, survives in the worktree where the change is being
made, and can be inspected without knowing a session-specific path. Scratch in
a system temp directory is invisible to everyone but the agent that wrote it.

Clean up when you are done: `./tmp/` is ignored, so leftovers are harmless to
the repo but confusing to the next reader.

## This is a scaffold-managed project — reach for `lgs` first

`scaffold.toml` at the root is a `logos-scaffold` (`lgs`) config, and both
modules are captured in it as `[modules.radicle]` / `[modules.radicle_ui]` with
`role = "project"`. That means the build, install, launch and dev-shell paths
all have an `lgs` verb, and reaching straight for `nix build` skips the part
scaffold does for you — resolving each module's flake ref, ordering the two
builds by dependency, and deriving the sibling `--override-input`.

**Version: this repo currently needs an UNRELEASED build, not a crates.io
release.** Install this and nothing else:

```bash
cargo install --git https://github.com/logos-co/scaffold.git \
  --rev cd4fe509badf84929135aee73972bafee30d30e8 logos-scaffold --locked
```

That is the same commit both CI workflows pin in `LGS_REV`, and it is a
pinned **commit** rather than the branch: a moving ref would silently change
the tool driving every build here.

Two things this repo depends on are on
[logos-co/scaffold#266](https://github.com/logos-co/scaffold/pull/266), which
is still open — `basecamp setup --inspector` (the whole reason the last raw
`nix build` for Basecamp is gone) and `--print-output` on `basecamp build` /
`build-portable`. **Neither exists in v0.3.1**, so installing the release and
following the e2e sequence in [`docs/e2e.md`](docs/e2e.md) gets you an
unrecognised-flag error on step 1.

When #266 ships in a release, revert all three sites to
`cargo install logos-scaffold --version <that release>` and put `LGS_VERSION`
back in both workflows. Nothing else changes — the flags keep their names.

For background on the last release: v0.3.0 moved the module table from
`[basecamp.modules.*]` to the top-level `[modules.*]` this repo uses, and added
`develop`, `build`, `run` and `paths`; v0.3.1 (2026-09-03) is eight fix commits
on top. **The verb table below was written against released v0.3.1** and every
verb in it still behaves the same on the pinned build — only `--inspector` and
`--print-output` are additions.

Do not be misled by `version = "0.2.0"` at the top of `scaffold.toml`: that is
the **file schema** version, not the CLI version, and `0.2.0` is what `lgs`
0.3.x expects (`SCAFFOLD_TOML_SCHEMA_VERSION` in scaffold's own source).
Bumping it to match the CLI would make the file unparseable.

One trap if you are on a build from a clone rather than the release. The
version string was bumped 0.3.0 → 0.3.1 only in the release commit itself, so
any master build from that eight-commit window reports `0.3.0` while carrying
most of v0.3.1's code, and `--version` cannot tell you which. This repo was
originally documented from exactly such a build. If `lgs --version` says
`0.3.0`, check whether it is a path install (`cargo install` prints the package
source when it replaces one) before assuming you are behind. A genuinely
missing command below means v0.2.0 or older, which is a schema difference you
will notice anyway.

### The verb table

| You want to | Run |
|---|---|
| build both modules, both variants | `lgs basecamp build --variant all` |
| build just the portable artefacts (e2e, AppImage) | `lgs basecamp build-portable` |
| check one module still compiles | `lgs basecamp build --variant lgx --module radicle_ui` |
| install into the dev profiles | `lgs basecamp install` |
| launch Basecamp for manual testing | `lgs basecamp launch alice` |
| enter a module's dev shell | `lgs basecamp develop radicle_ui` |
| find a profile's log / module / XDG dirs | `lgs basecamp paths alice` |
| check `[modules.*]` against installed state | `lgs basecamp doctor` |
| read the module-project contract | `lgs basecamp docs` |

`build` takes `--variant {lgx,lgx-portable,all}` and an optional
`--module <name>`; `build-portable` is the alias for `--variant lgx-portable`.
Both read `[modules.*]`, build in dependency order, and **derive
`--override-input radicle path:../radicle` for `radicle-ui` themselves** — never
write that flag by hand.

### Where the artefacts land

Deterministic, and worth knowing so you never probe the filesystem for them:

```
.scaffold/basecamp/lgx/<NN>-<module>.lgx        # dev    (--variant lgx)
.scaffold/basecamp/portable/<NN>-<module>.lgx   # portable
```

Concretely `01-radicle.lgx` and `02-radicle_ui.lgx` in each. `NN` is the
load-order index, so the numbering *is* the dependency order. They are
**symlinks into the nix store**; both directories are wiped and recreated on
each build. Use `cp -L` if you need a real file.

Note the two variants land in **separate directories**, so `--variant all`
gives you per-module, per-variant addressing — not one flat directory.

### `build` does not need `basecamp setup`

`setup` pins and builds the basecamp + lgpm binaries and seeds the `alice` /
`bob` profiles. A *build* touches none of that, and `lgs basecamp docs`
explicitly supports a hand-authored `[modules.*]` table in "CI / sandboxed
environments where `lgs basecamp setup` can't or shouldn't run". Verified here:
`lgs basecamp build --variant all` runs green in a fresh worktree with no
`.scaffold/` at all. Only `install` and `launch` need `setup`.

### Environment goes in `scaffold.toml`, not on the command line

Do not prefix commands with `VAR=value`. It trips the permission checker (an
approval click every time) and it puts configuration somewhere nothing else
can see it.

`lgs` reads `[basecamp.env]` and `[basecamp.profiles.<name>]` from
`scaffold.toml` and exports them to the Basecamp process itself. That is
already where `QT_LOGGING_RULES` and `QT_FORCE_STDERR_LOGGING` live — which is
why QML import failures are visible at all — and where `runtime_dir` is pinned
per profile. If you need a variable set for a run, add it there; then every
future launch has it too, and the reason can be written down beside it.

The same principle covers the test scripts: `run-qml-tests.sh` and
`check-qml-syntax.sh` take no arguments and set their own environment
deliberately. Extend that when adding a script rather than inventing flags.

### `basecamp setup` strips the comments from `scaffold.toml` — again

It rewrites the file, and the rewrite drops every comment. This repo's
`scaffold.toml` carries load-bearing ones — why `runtime_dir` is pinned to the
session's real runtime dir (the `sun_path` 108-byte cap that made *every*
module segfault, and Qt needing `XDG_RUNTIME_DIR` to find the Wayland socket).
Losing them re-opened a bug that cost a full debugging session.

This was briefly fixed and then **un-fixed under us**, which is worth reading
as a caution about pinning to an open PR branch rather than as a complaint.
Scaffold#266 grew a `toml_edit`-based `save_project_config` that rewrote in
place and preserved comments; its author then reverted that work into a
separate PR (`fix/preserve-scaffold-toml-comments`) on the grounds that ~500
lines of config-writer surgery had nothing to do with selecting a basecamp
build. The revert is #266's current head, and it is what `LGS_REV` now pins —
so the comment stripping is back, and only the inspector opt-in and
`--print-output` remain.

Verified rather than assumed, on the pinned build: a `setup --inspector` run in
a worktree removed 26 of `scaffold.toml`'s comment lines.

**So: run `git diff scaffold.toml` after any `setup` and restore what it
destroyed.** The comment block above `[basecamp.profiles.*]` says this itself.
When `fix/preserve-scaffold-toml-comments` merges, this section reverts to
"fixed".

### The one thing `lgs` genuinely does not cover

**The core module's unit tests.** There is no verb for a flake's `checks`
outputs, so that stays `nix build '.#checks…'`. That single raw `nix build` is
legitimate and is not a sign you should hand-roll the rest.

Everything else has a verb. Use it.

### Building the inspector Basecamp: `setup --inspector`

This used to be the second gap, and this file used to carry a long analysis of
how close scaffold was to closing it. It is closed:

```bash
lgs basecamp setup --inspector
```

selects `.#bin-bundle-dir-inspector` **and classifies it as the portable
stack**, which is the half that actually mattered. Scaffold decides
dev-vs-portable from a list the inspector attr was missing from, so setting
`[repos.basecamp].attr` by hand — which was expressible all along — would have
built the right binary and then seeded profiles it cannot load: the wrong XDG
subpath (`Logos/LogosBasecampDev`), and worse, `[repos.lgpm].attr = "cli"`
against a portable bundle. Basecamp would then decline every module with one
warning line and open to an empty UI, the silent-failure shape this repo has
been bitten by repeatedly. `--inspector` moves both attrs together and
persists them, so a later plain `setup` cannot silently drop the opt-in;
`--no-inspector` reverts.

The rev needs no flag: scaffold reads `[repos.basecamp].pin` from
`scaffold.toml`, and that pin is already the `aa237766…` the e2e layer wants.
**That pin is the single source of truth for the rev** — `ui-tests.yml` derives
its `BASECAMP_REV` from it with `tomlq` in the "Resolve the pinned Basecamp
rev" step, rather than carrying its own literal.

`ui-tests.yml` used to carry that literal, which was safe only while the
workflow also did the build; once `setup` took that over, a hardcoded copy
became a second source of truth for one fact, and the divergence would have
been invisible — the store cache would key on the stale rev, restore a store
that cannot help, and recompile Basecamp on every run forever without anything
failing.

Three ordering constraints on the resolve step, all load-bearing: it must run
**after** the apt step (which installs `tomlq`), **before** the cache step
(which keys on the value it exports), and **before** `setup --inspector`, which
rewrites `scaffold.toml`'s `attr` keys in place. That last one is safe today
because `setup` never touches `pin` — but it is why the read happens first, and
a reorder would be a deliberate choice rather than an accident. Note the
runner's preinstalled `yq` is the **Go** one and has no `tomlq`; the apt `yq`
is the Python one that does, so the install is not redundant.

**Where the binary lands.** Not a `./result` symlink — `setup` writes it to
`~/.cache/logos-scaffold/basecamp/<pin>/app-result/` and records the path in
`.scaffold/state/basecamp.state` as `basecamp_bin=`. Read it from there; do
not reconstruct it, and do not `ls` the nix store to find it.

**The sitometres probe workaround is still needed.** `app-result` is a nix
out-link, so the bundle is still read-only and still has `.LogosBasecamp.elf`
where the probe looks for `.LogosBasecamp` — verified by pointing `--basecamp`
straight at it and getting "no Basecamp with the QML inspector compiled in".
`lgs` changed where the bundle comes from, not what is inside it.

**`setup` still strips `scaffold.toml` comments** on the pinned build — that
fix was reverted back out of #266. `git diff scaffold.toml` after every `setup`
and restore the `runtime_dir` / `sun_path` block; see the section on it above.

### Upstream asks against logos-scaffold

Two of the three this repo had filed are **closed by
[logos-co/scaffold#266](https://github.com/logos-co/scaffold/pull/266)**, which
is what `LGS_REV` pins; the third was closed and then reopened by #266's own
revert:

- ~~Select the inspector bundle through scaffold~~ — filed as
  [#265](https://github.com/logos-co/scaffold/issues/265), closed by `setup
  --inspector`. The issue asked for a one-line addition to
  `BASECAMP_PORTABLE_ATTRS`; the PR made it an explicit flag instead, on the
  grounds that an attr name the user has to know and spell is a poor opt-in for
  a deliberately-not-a-release output. It also moves `[repos.lgpm].attr` in
  lockstep, which the one-line version would not have.
- **`basecamp setup` should preserve `scaffold.toml` comments** — briefly
  closed by #266, then reverted out of it into
  `fix/preserve-scaffold-toml-comments`, so it is **open again** and the
  stripping is live on the pinned build. See "`basecamp setup` strips the
  comments from `scaffold.toml` — again" above.
- ~~`basecamp build` should pass build logs through~~ — closed as
  `--print-output` (reusing `install`'s existing flag name rather than adding
  `--print-build-logs` as a second name for the same thing). Both workflows
  pass it.

**The one still open is not a scaffold ask at all:** sitometres' inspector
probe, which is why the e2e layer pins a git commit rather than a released
version. See [`docs/e2e.md`](docs/e2e.md).

The remaining scaffold-shaped wish is small: nothing exposes a flake's `checks`
outputs, so the core module's unit tests stay on raw `nix build`. Not filed —
it is a different feature area from anything above.

### The bundled `basecamp` skill may document an older release

`lgs init` generates `.claude/skills/`, `.cursor/` and `AGENTS.md`; `.gitignore`
excludes `.claude/` wholesale (so `settings.json`, `agents/` and `worktrees/`
are untracked too), and none of it refreshes when you upgrade `lgs`. So the
copy on disk documents whichever release last ran `init` — which may predate
the `[modules.*]` schema and the `develop` / `build` / `run` / `paths` verbs,
making it read as though raw `nix` were the only way to do anything.

That is version skew, not a defect: the file correctly describes the release it
came from, and upstream's v0.3.x skill is already correct. Nothing to report
upstream — re-run `lgs init` to refresh it. Until then, treat
`lgs basecamp --help` as authoritative, then this file.

### If you are working in a git worktree

This is the `lgs` half only. For the git-level mechanics — where worktrees
live, what they branch from, the shared stash stack, and cleaning them up —
see "Working in a git worktree" below.

A worktree has no `.scaffold/` — that directory is untracked, so it does not
come along.

**`build` and `build-portable` work anyway**, creating `.scaffold/basecamp/`
as they go (see "`build` does not need `basecamp setup`" above). Only
`install`, `launch` and `doctor` need the binaries and seeded profiles, so run
`lgs basecamp setup` in the worktree itself when you want those — and check
`git diff scaffold.toml` afterwards, because `setup` strips its comments.

What none of this means is that you are building the main tree's code.
`scaffold.toml`'s module refs are relative (`path:./radicle#lgx`), and `lgs`
resolves them against the project root it was invoked from — so from a
worktree, every verb acts on that worktree's sources. The consequence is
isolation, not a wrong-code hazard: the worktree's `launch alice` is a
*separate* Basecamp instance with its own profile state, not the one the main
tree launches.

## Working in a git worktree

Non-trivial work happens in a worktree, on its own branch — that is how M1.1,
M2.1 and most of what followed were built. The mechanics that differ from a
normal checkout are below; the `lgs`-specific half is under "If you are working
in a git worktree" in the scaffold section, and is worth reading before you run
any verb from one.

**Where they live, and why that surprises people.** Worktrees are created under
`.claude/worktrees/<name>/` — inside the repository directory, but `.gitignore`
excludes `.claude/` wholesale, so they are invisible to git status in the main
tree. Do not `cd` back to the main checkout to "check something" mid-task; run
every command from the worktree, or you will read and edit the wrong tree.

**You branch from `origin/main`, not from your local `main`.** The default base
is the fetched remote head at creation time. If local `main` is behind or ahead
of `origin/main`, the worktree matches neither — verified here: the main tree
sat at `6771497`, `origin/main` at `b8e50f4`, and a worktree created between
them came off a third commit. **Read files from the worktree rather than
trusting a copy already in context**, including this one. A stale `CLAUDE.md`
is the most likely thing to mislead you, because it is the file most likely to
be in context from the start and least likely to be re-read.

**The stash stack is shared with the main checkout and every other worktree,
and other sessions may be using it concurrently.** Never bare `git stash` /
`git stash pop`. Prefer a throwaway WIP commit to set work aside — it is local
to your branch and cannot be popped by anyone else. If you must stash, use
`git stash push -u -m "<unique-tag>"` and recover with `git stash apply <sha>`,
never `pop`.

**Clean up when the branch lands.** Worktrees accumulate silently and nothing
prunes them: this repo reached **15** at once, most on branches merged
milestones ago — M1.1's `worktree-agent-a42af4ef65b0dcc3b` was still on disk
long after PR #2 merged, two worktrees shared one branch, and one sat on a
stale detached HEAD. That is not free: each is a full checkout, each holds a
branch ref alive so merged branches never look merged, and a stale one is an
invitation to edit code that is no longer anybody's `main`. After a branch is
merged, `git worktree remove <path>` it. `git worktree list` is the thing to
run when you are unsure what is lying around; `git worktree prune` clears
entries whose directories are already gone.

One consequence to expect rather than debug: a worktree's `lgs basecamp launch
alice` is a **separate** Basecamp instance with its own profile state. That is
isolation working as intended — but see the `local.yaml` caveat about two
Basecamps contending on the same `~/.radicle`, which that isolation does *not*
protect you from.

## How to shape a change

Three habits, in the order you need them: make room for the change before
making it, put the complexity in the data rather than the control flow, and
give every function one job. They are not independent — the second and third
are usually *how* you do the first.

### Make the change easy, then make the easy change

If a change is awkward to make, that awkwardness is information about the
code, not about the change. The move is two commits, not one: first a
refactor that changes no behaviour and makes room, then the feature or fix,
which is now small. Keep them separate — a diff that reshapes and alters
behaviour at once cannot be reviewed for either, and cannot be reverted
without losing the half you wanted.

The refactor commit must leave every gate green on its own. If it cannot,
it is not a refactor.

This repo has the worked example. `Main.qml`'s `nav.busy`/`nav.error` logic
had no test because it was tangled into a 300-line file; the fix was not a
cleverer test but pulling it out into `NavState.qml` — after which the test
was obvious and `tst_nav.qml` fell out in minutes. Same story with
`SourceState.qml`, extracted from the Seed/Local routing so the method
selection could be tested without a view. **When a test is hard to write,
suspect the shape of the code before blaming the test layer.**

The counter-pressure, which is equally real: do not refactor speculatively.
`IssuesTab.qml` and `PatchesTab.qml` have been near-identical for three
milestones and are still not merged, because nothing has yet needed them to
diverge or a third consumer to appear. Make room for *the change in front of
you*, not for one you imagine.

### Put the complexity in the data structure, not the logic

Prefer reshaping state so an invariant holds by construction over adding a
branch that checks it. A branch has to be got right at every call site and
tested at each one; a data shape is right everywhere at once, and a new call
site inherits it for free.

The `wantRid`/`wantBranch`/`syncEpoch` staleness guards are this repo's
standing example — and its standing counter-example. The same guard is
hand-written slightly differently in `CommitsTab`, `IssuesTab`, `PatchesTab`
and `ThreadView`. Every time one of them was written from memory, something
was dropped: `ThreadView` captured `wantId` but not `wantRid`;
`CommitsTab.fetch()` captured neither. Each omission then needed its own
regression test to pin down. A shared "request whose reply is dropped unless
the state it was issued against still holds" — one shape, one test — would
have made all four correct at once and made the fifth correct before it was
written.

So when you find yourself writing the fourth slightly-different copy of a
guard, that is the signal to reshape rather than to add a fourth test.

### One function, one job

Single Responsibility is the SOLID letter that pays for itself here; the
others follow from it more often than they need to be invoked by name.

A function that does one thing is one you can name precisely, test without
scaffolding, and read without holding a second concern in your head. The
tell that a function has two jobs is usually in its name: an `And`, a vague
verb like `handle`/`process`/`update`, or a comment mid-body introducing the
next phase. `finishSyncIfDone()` earns its length because everything in it
serves one decision; a `syncAndRecordHead()` would not.

Two consequences worth stating, because both have bitten this repo:

- **Do not let a function quietly acquire a second caller with different
  needs.** That is how `syncAll()`'s head lookup came to read `branch` live
  in its callback and record the wrong branch's head. Pass what the
  function needs; do not have it reach out for ambient state.
- **A guard is a job.** `guarded()` in `rust-ffi` exists solely to stop a
  panic unwinding through an `extern "C"` frame. It is not error handling,
  it is not mixed into the read functions, and every entry point goes
  through it. Keeping it separate is what made "is it called everywhere?"
  a question with an answer — and `tests/panic_guard.rs` the test that
  answers it.

Interfaces stay small for the same reason. The core module's contract is
`std::string in, std::string out` JSON per method precisely so the radicle
crate's churn stays behind that wall — see `radicle_impl.h`. Widening an
interface is a decision to make deliberately, not a side effect of needing
one more field.

## Tests are part of the change, not a follow-up

All test layers run on **every pull request**, so coverage is not
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

## The gates, all on every PR

| Gate | Runs on | Catches |
|---|---|---|
| QML syntax (`check-qml-syntax.sh`) | every PR | a file Qt cannot parse — `qmllint` does **not** catch this |
| Core unit tests | every PR | logic: URLs, ref resolution, pagination, error shapes |
| Rust backend (`fmt`, `clippy -D warnings`, `test`) | every PR | the `local*` read path; dead code that is a never-wired safety guard — see [`docs/rust-ffi.md`](docs/rust-ffi.md) |
| QML component tests | every PR | one component's own behaviour |
| End-to-end spec (sitometres) | every PR + push to main | the wiring: does the module load, does the replica connect, does data arrive |

The end-to-end job takes about three minutes warm. A PR from a fork, or the
first run after `BASECAMP_REV` changes, pays roughly nine minutes because the
Nix store cache is cold.

## The test layers

Pick the cheapest layer that can actually see the behaviour you changed.

| Layer | Lives in | Run it with | Covers |
|---|---|---|---|
| Core module unit tests | `radicle/tests/` | `cd radicle && nix build '.#checks.x86_64-linux.unit-tests'` | URL building, ref resolution, pagination, error shapes, local-profile detection — no network |
| Rust FFI tests | `radicle/rust-ffi/tests/` | `cd radicle/rust-ffi && cargo test` | The `local*` read path against real fixture profiles; the panic guard at the `extern "C"` boundary |
| QML component tests | `radicle-ui/tests/tst_*.qml` | `sh radicle-ui/tests/run-qml-tests.sh` | One component in isolation: selection state, layout invariants, load ordering |
| End-to-end UI specs | `radicle-ui/tests/ui/*.yaml` | See [`docs/e2e.md`](docs/e2e.md) | Real clicks in a real Basecamp, real QtRO transport, real seed calls |

The unit-test row is raw `nix` on purpose — `lgs` has no verb for a flake's
`checks` outputs. Everything *building* the modules goes through `lgs`, in CI
as well as locally; see "This is a scaffold-managed project" at the top.

Logic that does not need a view belongs in the core module, where it is testable
without Qt at all. A component test is the right layer for anything one QML file
decides on its own. Reach for a sitometres spec when the thing that broke was
the *wiring* — a signal that never arrived, a call the view forgot to make, a
screen that loaded but showed the previous screen's data. Component tests
structurally cannot see those.

## The end-to-end layer lives in `docs/e2e.md`

Running a spec is two commands once the inspector Basecamp is built, but every
flag in them is load-bearing and the failure modes are silent — a wrong
`--variant` gets you a UI that opens to nothing and a timeout with no
explanation. The sequence, the reason for each flag, how to write specs
(`state:` over `text:`, `objectName` on the clickable element, adding to the
`ui-tests.yml` matrix), and the `RAD_HOME` requirement for `local.yaml` are all
in [`docs/e2e.md`](docs/e2e.md). Read it before running or editing one.

`browse.yaml` currently runs green: 18 steps, ~21s against a real Basecamp.

## CI

`.github/workflows/ci.yml` runs the fast layers on every push and pull request:
QML syntax, metadata lint, qmllint, the QML component tests and the LGX builds.
It also validates that the sitometres specs parse.

`.github/workflows/ui-tests.yml` runs the sitometres specs for real, on pushes
to `main`, on pull requests, and on demand. It is a **matrix, one job per
spec** (`browse`, `branches`, `source`, `sync`, `write`) — `SPEC` used to be
hardcoded to `browse.yaml`, so three specs sat in the tree running nowhere. If
you add a spec, add it to that matrix, or it is decoration. `write` is the odd
one out: it needs a signable key, so the job seeds a throwaway profile for the
run and hands it over as `RAD_HOME` — see [`docs/writes.md`](docs/writes.md).
`ci.yml`'s schema check
already globs `tests/ui/*.yaml` and needs no change. It builds Basecamp from source —
the inspector-enabled bundle is not in the public binary cache — but a warm Nix
store cache brings that to about three minutes. A fork PR, or the first run
after `BASECAMP_REV` changes, pays roughly nine minutes.

### Does CI use `lgs`?

**Yes — every module build in both workflows, and now the Basecamp build too.**
Exactly **one** raw `nix build` is left in CI, and it is the named gap rather
than a preference: `ci.yml`'s core-module unit tests, because nothing exposes a
flake's `checks` outputs.

- **`ci.yml`'s `build` job**: four `nix build` calls became one
  `lgs basecamp build --variant all --print-output`.
- **`ui-tests.yml`**: two `nix build` calls became one
  `lgs basecamp build-portable --print-output`, and sitometres now points
  `--app-dir` straight at `.scaffold/basecamp/portable/`. The `rm -rf dist &&
  mkdir dist && cp …` staging step is gone entirely.
- **`ui-tests.yml`'s inspector Basecamp**: the last raw `nix build` for a
  Basecamp became `lgs basecamp setup --inspector`. See "Building the inspector
