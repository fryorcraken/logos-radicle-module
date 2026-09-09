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

## `git` reaches Radicle only through the process's own `PATH`

`env.rs` owns the git preflight, and the shape it has is forced rather than
chosen. Radicle's local git transport does not implement pack protocol
in-process — `storage/git/transport/local.rs:53` spawns the binary — so any
push into storage needs a `git`, and in a sandboxed Basecamp bundle that is the
most likely failure of all.

Three findings that determine the design, measured in Phase 0 rather than
assumed (`docs/M3-phase0-findings.md` §5):

- **There are six bare-name spawn sites**, not one, across `radicle` and
  `radicle-node`. So there is no single spawn path to wrap: a resolver injected
  at one call site would leave five uncovered.
- **`GIT_EXEC_PATH` is wrong on two counts.** Two of those sites `env_clear()`
  and re-admit only `PATH` and `GIT_TRACE*`, so it is stripped; and it names
  git's *helper* directory, not the `git` binary. It is the wrong variable even
  where it survives.
- **`PATH` is the only channel that reaches every site**, and writing it is
  **process-global**. `apply_git_path` must therefore be called once at module
  init, before any thread starts — not lazily when a setting changes.

That last point is why the git path setting has **restart-to-apply** semantics
and why `SettingsPanel.qml` says so on screen. The alternative — writing `PATH`
mid-run — races concurrent `getenv` (which is why `set_var` is `unsafe` from
Rust 2024 onward), and the failure would be silent and rare rather than loud.

**An explicit path overrides detection entirely, with no fallback to `PATH`.**
That is deliberate: a silent fallback makes a typo in the setting look like a
Radicle bug. Validation runs the candidate's own `git --version`, so a path
that exists but is not git is refused at set time rather than at first push.
Note this does *not* go through `radicle::git::version()` — that helper
validates whatever `PATH` currently resolves, not the candidate handed to it,
so it cannot answer the question being asked.

## Creating an identity: the one irreversible thing in this crate

`profileinit.rs` is the `rad auth` half of the embedded node. Everything else
here reads a profile or writes into one; this makes one, and that difference
carries the constraints below.

**An existing profile is refused, never overwritten, and there is no `force`.**
The signing key *is* the identity — replacing it makes every repository
delegating to it unreachable, and nothing recovers it. A `force` flag was
considered and rejected: no caller legitimately wants to destroy a key, and a
flag that exists is one a future UI can pass by accident.

**This guard is a second line, not the only one, and the file used to say
otherwise.** It claimed `Keystore::init` "would overwrite happily". It does
not: `radicle-crypto-0.19.0/src/ssh/keystore.rs:121-133` checks both key paths
and returns `AlreadyInitialized`. Deleting our guard left every test in
`tests/profile_init.rs` green at the time, because the crate caught every case.

That correction is worth keeping rather than quietly fixing, because the false
claim was doing work: it was the argument for the guard's existence, and a
reader who checked the crate would find it untrue and could reasonably delete
the guard as redundant. The two reasons that actually hold:

- **It fires before `Home::new`.** The crate's check is inside `Profile::init`,
  by which time the home directory tree exists — so a refusal there leaves a
  half-made home behind. Ours leaves the filesystem untouched.
- **The message names the consequence**, not a file. "keystore already
  initialized, file '…' exists" describes plumbing; "creating another would
  overwrite its signing key" describes what the user is about to lose.

The consequence for testing is the part that bites: because *both* guards
error, a test asserting only that a second init fails passes with ours deleted
— and so does one asserting the error names the home, since the crate's message
embeds the path too. `a_second_init_is_refused_and_leaves_the_first_identity_intact`
therefore asserts on the distinguishing wording, verified by mutation.

**There are three home states, not two, and the third is the one that bites.**
`Profile::init` writes the keystore *first* (`profile.rs:241`) and then runs
seven more fallible operations, each with a `?`. If any fails — a full disk, a
permissions hiccup, the process killed — the key files are on disk and nothing
removes them. So a home can be:

| State | Markers | Meaning |
|---|---|---|
| `Empty` | no `keys/radicle.pub` | safe to create into |
| `Complete` | keys **and** `config.json` | creating would destroy a real identity |
| `Partial` | keys, no `config.json` | crashed init; recoverable, never a usable identity |

A two-state check keyed on the keystore alone reports `Partial` as occupied for
ever — and since there is deliberately no `force`, that home becomes
**permanently uncompletable**, with the guard protecting a stub that was never
an identity while telling the user their signing key is at risk. Both halves of
that message are false, and it is the worse failure of the two the guard exists
to prevent.

`Partial` is **reported, not repaired**. Deleting key material automatically
would mean a classifier bug costs an identity — the one failure here with no
recovery — traded against a case that needs only a sentence naming the path to
remove. `keys/` is named rather than the whole home, so a home holding
unrelated files is not swept away on our advice.

**Why `config.json` is the completeness marker and `storage/` is not.**
`Home::new` creates all four subdirectories up front — `storage`, `keys`,
`node`, `cobs` (`profile.rs:595-599` via `subdirectories()` at `:654`) —
*before* any key is written. So `storage/` is present in the `Partial` state
too, and keying on it restores the original bug exactly. Verified by mutation,
and pinned by
`a_half_created_home_still_has_storage_which_is_why_config_is_the_marker`, which
asserts the directory's presence directly so a future crate version that
reorders creation fails loudly rather than making the marker choice look
arbitrary. `config.json` is a file written by `Config::init`, the statement
immediately after keygen, so it means precisely "keygen succeeded and init got
at least one step further".

The marker is deliberately narrower than "fully usable": a home that failed at,
say, the COB cache migration has a `config.json` and reads as `Complete`. That
is the safe direction to err — refusing to overwrite a home with real key
material *and* a config is right even when a later database is missing. Only
the pre-config window is unambiguously "nothing here was ever an identity".

Note this is also a *different* question from `LocalStore::available()`, which
looks for `storage/`: that asks "can I browse this", this asks "would creating
here destroy a real identity". A home with keys and no storage answers yes to
the second and no to the first, and both are correct. One consequence worth
knowing: `available()` reports a `Partial` home as browsable, since `storage/`
is there. Harmless for reads — it is empty — but it is why the two questions
cannot share a marker.

**A relative `home` is refused, not resolved**, mirroring the git-path check
below and for a stronger reason: this writes a permanent signing key, and a
Basecamp-launched module's working directory is not something the user chose or
can see. The test asserts nothing was created at the resolved location, because
"it returned an error" would not notice a guard that fired too late.

**The seed comes from `/dev/urandom`, not from the crate's own
`profile::env::rng()`.** That helper returns a `fastrand::Rng` — wyrand, which
is not a CSPRNG. It is the right tool where the crate uses it (jitter,
shuffling) and the wrong one for the seed of a permanent signing identity.
`getrandom` would be the idiomatic dependency and is deliberately not used:
`Cargo.lock` is vendored wholesale by `flake.nix` under a pinned hash, so
naming a direct dependency rewrites the lock and invalidates that hash even
when the package is already in the graph transitively. Eight lines of
`File::read_exact` is what `getrandom` does on Linux anyway.

**The marker for "a profile is here" is `keys/radicle.pub`, not the directory
existing** — and it is deliberately a *different* question from
`LocalStore::available()`, which looks for `storage/`. That one asks "can I
browse this"; this one asks "would creating here destroy a key". A home with
keys and no storage answers yes to the second and no to the first, and both
answers are correct. Collapsing them would make an embedded home this module
had already `mkdir`'d — for settings, or on a run that failed between the
directory and keygen — permanently uncompletable, with an error blaming a
profile that does not exist.

**The isolation test is the one that carries the file, and it is written to be
able to fail.** `two_homes_get_two_different_identities` asserts two homes
yield two *different* node ids. The obvious version — two directories, both
hold a key — passes against a hardcoded seed, which is not hypothetical:
`tests/fixture/mod.rs` uses `Seed::new([7u8;32])` deliberately so failures
reproduce. Two homes, one identity, every directory-shaped assertion green.
This was verified by temporarily returning that fixed seed and watching the
assertion go red with the same DID on both sides.

## `cargo clippy -- -D warnings` is load-bearing here, not style policing

CI runs `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings`.
That is not tidiness: a dead-code warning in an FFI crate is usually a *safety*
feature that was written and never wired in, and `-D warnings` is what turns
"nobody noticed" into a red build. Two such cases, both caught exactly that way:

- **`guarded()` was never called.** Its doc comment says it is a soundness
  guard, not error handling — a Rust panic unwinding through an `extern "C"`
  frame is undefined behaviour. Every `radicle_local_*` function called
  `to_c_string(...)` directly, so nothing was guarded. Every read entry point
  now routes through it, and `tests/panic_guard.rs` drives the real
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

**The `extraBuildInputs` site, which used to be the gap.** It is resolved
outside `forAllSystems` and is not an `externalLibInputs` entry, so one list is
shared by every `checks.<system>.unit-tests`. Naming a single system's zlib
therefore made every *other* system's check unrealisable — the same shape as
the staticlib bug above, in the one place that fix does not reach. It now takes
the zlib of every `ffiSystems` entry: on any given machine only that machine's
check is ever realised, and the rest are inert store paths in a list Nix never
builds. Do not "simplify" it back to one system.

**Darwin is in `ffiSystems`, and the reasoning that once excluded it was
wrong.** The old argument was that a Darwin arm would mean cross-compiling Rust
for Darwin from a Linux builder. Nothing cross-compiles: both release pipelines
build each variant natively on its own runner — the catalog's action maps
`darwin-arm64` to `macos-latest`, and `ci.yml`'s build matrix does the same.
`buildInputs` resolves through `import nixpkgs { inherit system; }`, so a Darwin
build links Darwin's own openssl and zlib, and there is no `target_os` gate or
`cfg(unix)` branch anywhere in `rust-ffi/`.

Excluding Darwin did not fail loudly — it made the catalog's `darwin-arm64` job
fail, which that pipeline treats as an expected partial, so the release shipped
anyway with a "Missing variants" line nobody reads. That is how radicle v0.2.0
shipped linux-amd64 alone. Both modules have since built on all three platforms:
the catalog's `sidecar.json` records `missingVariants: []` for v0.1.1 and again
for v0.2.3.
