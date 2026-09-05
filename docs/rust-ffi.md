# The Rust FFI crate: `radicle/rust-ffi/`

Read this before touching `radicle/rust-ffi/` or the `local*` read path.
Everything here is confirmed against the shipped code, not planned.

The crate backs the `local*` half of the core module's API: reading this
machine's `~/.radicle` in-process, instead of proxying to a seed over HTTP.
The hard constraint, stated in `radicle_impl.h`'s doc comment, is that a repo
from `remoteGetRepo` and one from `localGetRepo` must deserialize identically,
so a view renders either without branching.

## Why a flat `extern "C"` string API and not `cxx`

Every module method is already `std::string in, std::string out` JSON — see
`radicle_impl.h`'s conventions section: "returning JSON keeps the radicle
crate's churn behind this wall." `cxx` buys typed struct marshalling across
the boundary, which is exactly what this codebase has deliberately avoided
needing. A flat API matches the existing shape with the least new machinery:

```c
// caller owns nothing until it gets a pointer back; frees it with
// radicle_free_string. NULL home = not found via RAD_HOME/HOME (mirrors
// LocalStore's own env lookup).
char* radicle_local_list_repos(const char* home, const char* scope,
                                int64_t page, int64_t per_page);
char* radicle_local_get_repo(const char* home, const char* rid);
// ...one function per local* method, same signature shape as radicle_impl.h.
void  radicle_free_string(char* s);
```

The Rust side builds the JSON itself via `serde_json` and returns a
`CString::into_raw()` pointer; `radicle_free_string` calls `CString::from_raw`
to drop it. `radicle_impl.cpp` does **not** call `extern "C"` functions
directly — it goes through `LocalReader`, which owns the FFI boundary the same
way `SeedClient` owns the HTTP one.

`radicle_ffi.h` is cbindgen-generated but **checked in** rather than generated
at configure time, so the header is reviewable.

## Reading local storage — confirmed against heartwood (crates/radicle, v0.25.1)

- **Git-native (repos, tree, blob, commit)**:
  `radicle::storage::git::Storage::open(path, info: UserInfo)` opens the
  profile's storage root — no signer, no passphrase; `UserInfo` is config, not
  a key. `storage.repository(rid) -> Repository` opens one repo; `Repository`
  wraps a `git2::Repository` (`.backend`) plus helpers for refs, head, tree,
  blob, commit — all `ReadRepository` trait methods, all read-only.
- **COBs (issues, patches)**: NOT plain git objects — each COB is a DAG of
  signed operations under `refs/cobs/<typename>/<id>/...`, replayed
  (`Evaluate`) into current state. The crate does the replay for you:
  `radicle::cob::issue::Issues::open(&repository, ReadOnly)` then `.get(&id)` /
  `.all()` (via `Deref` to `store::Store`), confirmed in
  `crates/radicle/src/cob/issue.rs`. `radicle::cob::patch::Patches::open`
  mirrors it exactly. Critically, `store::access::ReadOnly` is a zero-field
  unit struct requiring no signer, so this works fully offline with no
  passphrase prompt.
- **The SQLite cache is NOT required for correctness.**
  `Cache<..., cache::NoCache>` exists specifically as a direct-read path —
  `NoCacheIter` walks `store.all()`/`store.get()` straight off git refs, no DB
  involved. That is what this crate uses, so it owns no SQLite file's
  lifecycle. The real `rad` CLI's `~/.radicle/cache/cobs.db` is a read-through
  optimization for its own use, not a dependency other readers need.
- **There is no public `radicle::test` module**, and no `fixtures` or
  `rad_util` helper — they are crate-internal (`#[cfg(test)]`) and cannot be
  pulled in as a dev-dependency. The public modules are: `cli, cob,
  collections, explorer, git, identity, io, node, prelude, profile, rad,
  serde_ext, sql, storage, version, web`. Build fixtures through the public
  API: `Profile::init(Home, Alias, Option<Passphrase>, Seed)` creates a
  keystore and storage root, and `rad::init(&Repository, ProjectName, &str,
  BranchName, Visibility, &impl Signer, &impl WriteStorage)` pushes a git
  working copy in as a real Radicle repo. That is what
  `rust-ffi/tests/local_storage.rs` does.
- **COB reading is not a separate subsystem.** No `automerge` knowledge
  needed, no signature-verification code to write — `Issue`/`Patch` come out
  with fields matching what `remoteGetIssue`/`remoteGetPatch` expose. The open
  question was always JSON *shape* matching, settled empirically against
  `test_seed_client.cpp`'s fixture JSON rather than guessed from
  radicle-httpd's serialization.

**Reading needs no passphrase** — only `keys/radicle.pub` is read. `UserInfo.key`
is used when *signing*, which this never does, so the private key stays
encrypted and untouched. Confirmed empirically: the fixtures init a profile
with `None` for the passphrase and the read path works against it.

**`radicle 0.25.1` / `radicle-oid 0.2.2` need no pin.** An older memory records
`radicle = "0.24"` failing until `radicle-oid` was pinned to `0.2.0`; that does
not apply to this version line.

## `cargo clippy -- -D warnings` is load-bearing here, not style policing

CI runs `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings`.
That is not tidiness: a dead-code warning in an FFI crate is usually a *safety*
feature that was written and never wired in, and `-D warnings` is what turns
"nobody noticed" into a red build. Two such cases, both caught exactly that way:

- **`guarded()` was never called.** Its doc comment says it is a soundness
  guard, not error handling — a Rust panic unwinding through an `extern "C"`
  frame is undefined behaviour. Every `radicle_local_*` function called
  `to_c_string(...)` directly, so nothing was guarded. All twelve read entry
  points now route through it, and `tests/panic_guard.rs` drives the real
  boundary with pathological inputs (junk RIDs, traversal-shaped paths,
  `i64::MAX`/`i64::MIN` paging), asserting parseable JSON comes back every
  time. If a change drops `guarded` from a call site, the panic aborts the
  whole test binary — loud, which is the point.
- **`init_private_repo` was never called**, and its absence had hollowed out a
  test: `list_repos_narrows_by_scope` asserted `count("private") == 0` against
  a fixture containing only public repos — which passes just as happily
  against a filter returning nothing for any input. It now creates a private
  repo and asserts `count("private") == 1`. **A fixture that answers the same
  for every input cannot tell working from broken.**

So when clippy flags dead code here, read what the dead thing was *for* before
deleting it or reaching for `#[allow]`. Twice now the answer has been "it
should have been called".

## Testing this crate

The rescued original code came with `SMOKE_*`-env-gated tests that returned
early when the var was unset, so `cargo test` went green having executed none
of the code under test — the same false-green shape as the Qt5 `qmltestrunner`.
They were replaced with fixtures built through the crate's public API.

When adding coverage, verify it fails when it should: break `local.rs` on
purpose and watch the assertion go red. That takes a minute and is the only
thing separating a real test from a skip.

**Two probe examples read this machine's real `~/.radicle`**, because a fixture
built by the same code that reads it can agree with itself while both are wrong
about what a real `rad`-created profile looks like: `probe_real_profile` (every
read, one repo, empty sha) and `probe_ui_args` (every repo, with the
`defaultBranch` the UI actually passes as the sha — a different input down a
different path). Neither is a test: they depend on what is on this machine, so
they can neither pass nor fail meaningfully in CI.

## Building it per-system — the arm64 regression

`radicle/flake.nix` once passed `stageRustFfi "x86_64-linux"` — one hardcoded
literal, plus the same literal in `tests.extraCmakeFlags` and
`tests.extraBuildInputs`. `mkLogosModule` fans out over four systems but takes
`preConfigure` as **one value shared by all of them**, so every platform staged
the amd64 archive. `linux-arm64` and `darwin-arm64` both failed in the
catalog's release workflow. The ~65s arm64 failure was the tell: far too fast
to be a real compile, because nothing was compiled — Nix declined to realise an
x86_64 derivation with no x86_64 builder.

**Why every gate missed it.** This machine, this repo's CI, and this repo's
releases are all x86_64; the catalog is the first thing that ever builds arm64.
The whole local gate set was green and *structurally incapable* of seeing it.
**When a change touches `flake.nix`'s system handling, the only real check is
the derivation graph, not a build on this machine.**

**How to verify, since a build cannot** — free, and it takes seconds:

```
nix path-info --derivation <flake>/radicle#packages.aarch64-linux.lgx
nix-store --query --requisites <that .drv>      # grep for radicle-local-ffi
nix derivation show <the ffi .drv>              # check its "system"
```

Before the fix both systems' lgx pulled the byte-identical
`radicle-local-ffi-…drv` with `"system": "x86_64-linux"`. After, each pulls a
different derivation carrying its own platform. Re-run that if this file is
ever touched again.

**The plausible fix that is worse than the bug.** Emitting a shell
`case "$system" in` and letting the builder pick its own arm looks right —
`$system` really is in the builder env — and is wrong. Every arm's store path
sits in the string, so **every arm becomes an inputDrv of every system's
derivation**. Measured: `nix build .#packages.x86_64-linux.lgx` then fails on
this machine with "Required system: 'aarch64-linux'". It trades an arm64
failure for an amd64 one.

What works is `externalLibInputs`, the builder's per-system escape hatch.
`resolveExtInput` resolves each entry as `value.packages.${system}.default`
*inside* `forAllSystems`. Declaring the archive as a `nix.external_libraries`
entry also makes both builds stage it into `lib/` themselves —
logos-plugin-qt's "Copy external libraries" block for the plugin,
`copyExternals = true` for the unit tests — so no `preConfigure` is needed and
the two `CMakeLists.txt` `find_library` calls just work. **Do not add a `cp`
back on top**: the builder's copy arrives mode-444 from the store and a second
one fails with "Permission denied".

**One site the fix deliberately does not reach.** `tests.extraBuildInputs`
still names an x86_64 zlib, because it is resolved outside `forAllSystems` and
is not an `externalLibInputs` entry. So `checks.aarch64-linux.unit-tests` will
not realise on an arm64 machine. Left alone on purpose: `checks` are not on the
release path, and fixing it means either an upstream per-system `tests` hook or
calling `mkLogosModule` once per system. Revisit only if the unit tests ever
need to run on arm64.

Darwin is excluded from `ffiSystems` deliberately — the crate links a native
libgit2/openssl through the `*-sys` crates, so a Darwin arm would mean
cross-compiling Rust for Darwin from Linux. A Darwin build fails with the
builder's own "does not provide packages.aarch64-darwin.default", naming the
platform instead of silently linking a Linux archive.
