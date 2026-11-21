# Design

## Context

See `proposal.md` for why the stack moves and for the set it moves to. This
file records how, and why each pin and setting is the value it is.

Three facts about the stack shape every decision below, and none of them is
visible from this repo's own files:

- **Scaffold supports exactly one Basecamp release at a time.** v0.5.0's is
  0.3.0 (`DEFAULT_BASECAMP_RELEASE` in its `src/constants.rs`). Its launcher
  resolution, the environment `launch` exports, the bundled-module list and
  the retired-pin migration all describe that release and no other — scaffold's
  own ADR "Scaffold Supports One Basecamp Release".
- **The Basecamp pin, the `lgpm` pin and the module-builder generation are one
  set.** `lgpm` writes what Basecamp's embedded package-manager library then
  scans, so scaffold's `lgpm` pin is the rev the Basecamp release locks (ADR
  "Basecamp Pin Bumps Move as a Set"). The module-builder generation decides the
  SDK and protocol a module links, and Basecamp refuses calls from a module
  built against a different one.
- **This repo's code reaches the stack only through three seams**: the flake
  input `logos-module-builder` (both modules), `scaffold.toml`'s
  `[repos.basecamp]`/`[repos.lgpm]` pins (setup, install, launch, and the e2e
  layer's Basecamp rev), and `LGS_VERSION` in the two workflows. Nothing in
  `radicle/src/`, `radicle/rust-ffi/` or `radicle-ui/src/` names a Basecamp or
  SDK version.

## Goals / Non-Goals

**Goals:**

- Every gate CLAUDE.md lists is green on the new set, with no module source,
  metadata, QML test or sitometres spec changed unless the new stack forces it.
- Every document that states a fact about the old stack either says the new
  fact or stops stating it.
- Concurrent `lgs basecamp launch alice` / `bob` work, which the shared
  `runtime_dir` workaround silently prevented (Decision 5).

**Non-Goals:**

- See proposal.md "Not in this change". In particular nothing here moves the
  settings file or the embedded home into Basecamp 0.3.0's `module_data`.

## Decisions

### 1. Basecamp 0.3.0, not 0.3.2

Basecamp 0.3.1 and 0.3.2 are tagged, and module-builder runs to 0.3.3. This
change still stops at Basecamp 0.3.0, because that is the release scaffold
v0.5.0 supports, and the other pins only mean something relative to it.

Moving to 0.3.2 would mean deriving the `lgpm` pin by hand from 0.3.2's
`flake.lock`, choosing the module-builder generation whose SDK set matches
it, and then running `setup`, `install` and `launch` with a scaffold whose
launcher, exported environment and bundled-module list describe 0.3.0. The
ADR is explicit that a non-default pin is built but gets no compatibility
code: `basecamp doctor` names the release scaffold actually supports, and
every difference is the project's problem. That is the position this change
exists to leave. While this repo was on 0.2.3 under scaffold 0.3.1 it was
inside scaffold's support; v0.5.0 lists that exact pair among its retired
sets, which is what started this change.

The rejected alternative was to take the newest Basecamp and pin `lgpm` and
module-builder to match it by hand. It would have bought two point releases
of Basecamp fixes. It would also have put this repo back on a combination
scaffold's tests never run, the same way it ran on an unmerged scaffold PR
branch for three force-pushes. The cost of staying on 0.3.0 is a wait, and a
newer Basecamp is not a fix for anything this repo needs today.

So the next stack bump starts from a scaffold release that names a newer
Basecamp in `DEFAULT_BASECAMP_RELEASE`, not from a Basecamp release.
`docs/PLAN.md`'s "The Logos stack" keeps that rule as the constraint still
ahead; this entry is its reasoning.

### 2. The pins are scaffold's literal defaults, written by hand

`[repos.basecamp].pin` is `bbe5da0e…` (logos-basecamp tag `0.3.0`, which
`git rev-parse 0.3.0^{commit}` confirms in a clone) and `[repos.lgpm].pin` is
`d3af2972…`. They are copied from `DEFAULT_BASECAMP_PIN` and
`DEFAULT_LGPM_PIN` in scaffold v0.5.0's `src/constants.rs`, and not from a
Basecamp `flake.lock`.

Scaffold's `setup` would have made the same edit itself: the old pair is
exactly a `RETIRED_BASECAMP_PIN_SETS` entry, labelled "0.2.3". It was not
used to make the edit because `setup` rewrites `scaffold.toml` through
`save_project_config`, which v0.5.0 still documents as destructive (see
Decision 6). Writing the pins by hand keeps the edit a two-line diff a reviewer
can check against the constants. `setup` was then run on the hand-edited file
as a check: it printed no "moved off a retired pin" line, which it would have
printed for any value that was still a retired default.

Copying the literal default, rather than a Basecamp tag name or a newer
commit on the 0.3.0 line, is what keeps the next migration automatic. Scaffold
matches retired pins by exact rev. A project on scaffold's default today is
moved by a future `setup` when that default retires. A project on any other
value is left alone, and nothing says it was left.

### 3. logos-module-builder 0.3.0, not 0.3.3

Both `flake.nix` files pin tag `0.3.0`. Scaffold v0.5.0's
`BASECAMP_DEPENDENCIES` comment states the constraint: a module must be
"built against the same `logos-protocol` / `logos-cpp-sdk` basecamp 0.3.0
links, or basecamp refuses its calls at runtime", and module-builder `0.3.0`'s
SDK set is exactly Basecamp 0.3.0's, while `0.3.1` is "already past basecamp".

What breaks without this pin: the modules still build, which is why it is a
guard worth writing down. A module-builder past the Basecamp would compile
and package cleanly, and then fail at runtime when Basecamp refused the
module's calls. Only the sitometres specs would see that. In CI that is
`ui-tests.yml`'s whole matrix, every spec failing at its first
backend-dependent step. No other gate links a module against a real Basecamp.

Relocking moved only the `logos-module-builder` subtree of
`radicle/flake.lock` (`nix flake update logos-module-builder --flake
./radicle`). `nixpkgs-fetch` was deliberately not touched. The builder's own
nixpkgs did not move either: it is still `e9f00bd` (2025-09-28) before and
after. So `radicle/flake.nix`'s notes on the builder's rustc 1.89 and its
User-Agent-less fetcher still hold, and the Rust staticlib's toolchain story is
unchanged.

`radicle-ui/flake.lock` is not relocked, because it has never been tracked
(`git log --all -- radicle-ui/flake.lock` is empty). Its only non-builder
input is `radicle.url = "path:../radicle"`, which `lgs` overrides with the
working tree on every build anyway. A committed lock would pin a `narHash` of a
directory that changes with every commit. The proposal's Impact list names
the file, and the reason it is untracked holds.

### 4. Per-profile HOME: what Local mode under `launch` sees

SKETCH

### 5. `runtime_dir` goes; the Wayland socket is named absolutely instead

SKETCH

## Risks / Trade-offs
