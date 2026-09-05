# M3 Phase 0 — spike findings

Status: **spike complete.** Every claim below was produced by running a
command or reading source, not by reasoning about what ought to be true. The
commands are given so the next session can re-run them rather than trust this
file; the source citations are `file:line` into the crates as vendored in
`~/.cargo/registry`.

**Recommendation: in-process. The evidence supports it, and the one hint the
plan flagged as a likely blocker turned out to be a false alarm.**

The spike code is `radicle/rust-ffi/examples/probe_node_runtime.rs`, behind
the `node-spike` cargo feature. It is not wired into the module — see
"What the branch contains" at the end.

## The five questions

| # | Question | Answer |
|---|---|---|
| 1 | Links with `default-features = false`? | **Yes.** No `radicle-systemd` in the graph at all. |
| 2 | Does `radicle 0.25.1` stay single? | **Yes**, and so do `git2` and `libgit2-sys`. |
| 3 | Library drivable in-process, or `main()`-shaped? | **Drivable.** `Runtime::init` + `run` + `Handle::shutdown`; no process-global state touched. |
| 4 | Link size delta | **+7.05 MB** (4.88 → 11.93 MB) on a comparable full-surface link. |
| 5 | How does a configured `git` path reach the transport? | **Process `PATH` only** — and it is one line, but it is *process-global*, which is the real design constraint. |

A sixth thing turned up that the plan did not anticipate, and it is the one
finding most likely to cost a session if it is rediscovered the hard way: the
node's control socket collides with the 108-byte `sun_path` cap. See
"The socket path is a real constraint" below.

---

## 1. `default-features = false` links cleanly

Added to `radicle/rust-ffi/Cargo.toml`:

```toml
[dependencies.radicle-node]
version = "0.21.1"
optional = true
default-features = false
```

`cargo build --release --features node-spike` succeeds. `systemd` is a
default feature of `radicle-node`, so the check that matters is not "did it
build" but "is systemd actually gone":

```
$ cargo tree --features node-spike -e normal -i radicle-systemd
error: package ID specification `radicle-systemd` did not match any packages
```

Not in the graph at all. And nothing else crept in to replace it:

```
$ cargo tree --features node-spike -e features -i radicle-node
radicle-node v0.21.1
└── radicle-local-ffi v0.1.0 (…/radicle/rust-ffi)
    ├── radicle-local-ffi feature "default" (command-line)
    └── radicle-local-ffi feature "node-spike" (command-line)
```

No features enabled on `radicle-node` whatsoever. The plan's concern — "it
will try to talk to a service manager that isn't supervising it" — is
addressed by construction, not by configuration at runtime.

## 2. `radicle` stays single, and so does libgit2

This was the question that could have sunk the approach outright, because two
`radicle` copies means two `libgit2` statics and incompatible handle types
across the FFI boundary.

```
$ cargo tree --features node-spike -e normal -i radicle
radicle v0.25.1
├── radicle-fetch v0.21.1
│   ├── radicle-node v0.21.1
│   │   └── radicle-local-ffi v0.1.0 (…/radicle/rust-ffi)
│   └── radicle-protocol v0.9.1
│       └── radicle-node v0.21.1 (*)
├── radicle-local-ffi v0.1.0 (…/radicle/rust-ffi)
├── radicle-node v0.21.1 (*)
└── radicle-protocol v0.9.1 (*)
```

**One `radicle v0.25.1` node, four consumers.** `cargo tree -i` prints one
subtree per distinct version, so a second copy would appear as a second
top-level `radicle v0.x` block. There is none.

The same holds one level down, which is the check that actually protects the
FFI boundary:

```
$ cargo tree --features node-spike -e normal -i libgit2-sys
libgit2-sys v0.18.8+1.9.7
└── git2 v0.21.0
    ├── radicle v0.25.1
    …
```

One `libgit2-sys`, one `git2`. The pin comment in `Cargo.toml` about keeping
`git2` in step with radicle's own still holds and is not disturbed.

**One thing to know rather than be surprised by:** `radicle-node` pulls the
entire `gix-*` family (`gix-object`, `gix-pack`, `gix-protocol`, ~35 crates) —
a second, pure-Rust git implementation used by `radicle-fetch` for the wire
protocol. That is *additive*, not a conflict: `gix` and `libgit2` do not share
handle types and never meet. It is most of the compile-time and a good share of
the size delta in §4.

## 3. The library is drivable in-process — the `radicle-signals` hint was a false alarm

This was billed as "the one genuine unknown in the entire plan". It resolves
cleanly in favour of in-process.

### The shape of the API

`radicle-node`'s `src/lib.rs` exposes exactly one substantial public module:

```rust
pub mod fingerprint;
pub(crate) mod reactor;
pub mod runtime;      // <- everything is here
mod control;
mod wire;
mod worker;
```
— `radicle-node-0.21.1/src/lib.rs:6-12`

And `runtime` is a two-call lifecycle, not a `main()`:

- `Runtime::init(home, config, socket, listen, signals, secret_key) -> Result<Runtime, Error>`
  — `runtime.rs:123-130`. Doc comment: *"Initialize the runtime. This function
  spawns threads."*
- `Runtime::run(self) -> Result<(), Error>` — `runtime.rs:264`. Runs until
  shutdown and **returns**; it does not call `exit()`.
- `Handle::shutdown(self) -> Result<(), Error>` — `runtime/handle.rs:355`.

### Why it is not `main()`-shaped: everything process-global lives in `main.rs`

The decisive evidence is what `main.rs` does that `runtime.rs` does *not*:

| Process-global act | Where it happens | In the library? |
|---|---|---|
| `radicle_signals::install(notify)` | `main.rs:357` | **No** |
| `log::set_boxed_logger` | `main.rs:415` | **No** |
| `std::panic::set_hook` | `main.rs:469` | **No** |
| `exit(1)` / `exit(2)` / `exit(3)` | `main.rs:461,466,473` | **No** |
| CLI arg parsing (`lexopt`) | `main.rs:118-192` | **No** |
| `set_file_limit` (setrlimit) | `main.rs:351` | **No** |

Every one of those is in the binary, none in `runtime`. An embedder linking
the library inherits none of them.

### The `radicle-signals` hint, resolved

The plan reasoned: *"`radicle-signals` is a non-optional dependency, which is
a hint that [the library] might [assume it owns signal handling]."* Reasonable
inference, wrong conclusion. The whole of `radicle-node`'s use of that crate:

```
$ grep -rn "radicle_signals" radicle-node-0.21.1/src
src/main.rs:16:use radicle_signals as signals;
src/runtime.rs:32:use radicle_signals::Signal;
```

The **library** uses only the `Signal` *type*. `Signal` is a plain four-variant
enum with no side effects (`radicle-signals-0.12.1/src/lib.rs:17-26`). The
process-global `install()` — the `sigaction` call — is reached only from
`main.rs`.

And critically, `Runtime::init` takes the receiving end of the channel as a
parameter:

```rust
signals: mpsc::Receiver<Signal>,     // runtime.rs:128
```

So **the caller owns the signal channel.** `main.rs` fills it from real
SIGINT/SIGTERM; an embedded node hands over a channel it drives itself, and
the host process's signal disposition is never touched. That is exactly the
property an in-process node needs, and it is present by design rather than by
luck.

### Stopping it

`run()` spawns a thread that watches the channel and calls
`self.handle.shutdown()` on `Terminate`/`Interrupt` (`runtime.rs:278-298`), so
sending on the channel is one stop path. `Handle::shutdown()` is the other and
works directly:

- it is idempotent, guarded by a `compare_exchange` on an `AtomicBool`
  (`handle.rs:357-363`), so calling both paths is safe;
- it stops the control thread by connecting to the node's *own* control socket
  and sending `Command::Shutdown` (`handle.rs:367-369`) — no signals involved;
- `Handle` is `Clone` (`handle.rs:100-110`), and `run()` itself clones one for
  the control thread (`runtime.rs:274`), so an embedder can keep a clone to
  stop the node after `run()` has consumed the `Runtime`.

### Proven by running it, not only by reading it

`examples/probe_node_runtime.rs` initialises a throwaway profile, starts a
node with `listen: []`, waits for the control socket to answer, then stops it
via both paths and joins the thread:

```
profile home: …/rad-spike/n/h
node id:      z6MkwVDfCg9LbbY6xjH3EZk8YSFQZujV5Y4y1ZWeER9tDiN3
control socket path is 76 bytes (SUN_LEN cap is 108)
Runtime::init OK in 66.419437ms
  control socket: …/n/h/node/control.sock
  listening on:   [] (empty means outbound-only)
control socket answering: true (after 95.625584ms)
Runtime::run returned cleanly — the node is stoppable in-process
total: 97.378247ms
```

Start to stop in **97 ms**, in-process, no signals installed, no port bound,
`Runtime::run` returning normally rather than the process dying. That is the
answer to question 3.

(That run used a short base directory outside the repo. Re-running it with the
in-repo default reports `114 bytes` and skips — see §6, which is why.)

### Two smaller facts worth not rediscovering

- **`radicle-node` does not re-export `Signal`.** A caller constructing the
  channel needs `radicle-signals` as a direct dependency by name, which is why
  the `node-spike` feature enables both crates. Only the enum is used;
  `install()` must stay uncalled.
- **`config.listen = vec![]` really does bind no port** — `runtime.local_addrs`
  came back empty, confirming the plan's "outbound-only" default costs nothing
  at startup and cannot collide.

## 4. Link size: +7.05 MB

The naive measurement is misleading and worth explaining, because it will be
re-taken by someone else.

| Artefact | Bytes | MB |
|---|---:|---:|
| `libradicle_local_ffi.a`, default | 54,072,958 | 51.57 |
| `libradicle_local_ffi.a`, `--features node-spike` | 56,858,038 | 54.23 |
| `examples/probe_real_profile` (full `local*` read surface, linked) | 4,875,448 | 4.65 |
| `examples/probe_node_runtime` (same, plus the node runtime, linked) | 11,928,344 | 11.38 |

**Use the last two, not the first two.** A `staticlib` archive is not a link —
it carries every object file whether or not anything references it, and since
nothing in `src/` mentions `radicle_node`, the `+2.7 MB` on the archive
measures only what `cargo` handed the archiver. The example binaries are real
links with dead-code elimination applied, over the same crate, differing only
in whether the node runtime is reachable.

So the honest cost of embedding is **+7.05 MB, roughly 2.4×** on the linked
artefact. Most of it is the `gix-*` family from §2 plus the reactor and worker
pool.

For context on whether that is acceptable: the shipped `.lgx` already carries a
51 MB static archive, and 7 MB is what the *alternative* would cost too —
a spawned `radicle-node` binary is a similar size and has to be shipped inside
the `.lgx` regardless. **In-process is not the expensive option here; running a
node at all is.** That reframing is what makes §3's answer decisive rather than
merely encouraging.

**The default build is unaffected**, which is the property that keeps this
branch safe to merge: rebuilt with no features, the archive is 54,072,958
bytes against 54,073,164 before the change — a 206-byte difference that is
build-path metadata, not code. `cargo tree -e normal -i radicle` in the default
build prints a single `radicle v0.25.1` with one consumer, exactly as before.

## 5. The `git` path reaches the transport through the process's `PATH`, and nothing else

The plan asked whether honouring a configured absolute git path is "a one-line
child-`PATH` tweak or needs a wrapper on the spawn path". The answer is: it is
one line, but it is a *process-global* line, and that is the part worth
designing around.

### There are five bare-name spawn sites, not one

The plan cited one. There are more, across both crates:

| Site | What it spawns |
|---|---|
| `radicle-0.25.1/src/storage/git/transport/local.rs:53` | `upload-pack` / `receive-pack` — every push into storage |
| `radicle-0.25.1/src/git.rs:134` | `git version` — the preflight check |
| `radicle-0.25.1/src/storage/git/transport/remote/mock.rs:63` | test-only |
| `radicle-node-0.21.1/src/worker/upload_pack.rs:63` | serving fetches to peers |
| `radicle-node-0.21.1/src/worker/garbage.rs:54` | `git gc --auto` |

All five are `Command::new("git")` — a bare name, resolved through `PATH`. A
search for any configuration hook finds nothing:

```
$ grep -rn "GIT_EXEC_PATH\|git_binary\|git_path" radicle-0.25.1/src
(no output)
```

There is no config field, no builder, no injectable resolver. **A wrapper on
"the" spawn path is not an option, because there is no single spawn path** —
that alone rules out the wrapper approach the plan floated.

### The two node sites make `PATH` the only viable channel

This is the decisive detail, and it points the opposite way from the plan's
`GIT_EXEC_PATH` suggestion:

```rust
let mut cmd = Command::new("git");
cmd.current_dir(git_dir)
    .env_clear()
    .envs(std::env::vars().filter(|(key, _)| key == "PATH" || key.starts_with("GIT_TRACE")))
```
— `radicle-node-0.21.1/src/worker/upload_pack.rs:63-66`, identical at
`garbage.rs:54-57`

These sites `env_clear()` and then re-admit **only `PATH`** (and `GIT_TRACE*`)
from the parent. So:

- **`GIT_EXEC_PATH` would not work**, on two independent counts: it is stripped
  by the filter above, and it names git's *helper* directory (`git-remote-http`
  and friends), not the `git` binary. It is the wrong variable regardless.
- **`PATH` is the one channel that reaches every site**, because these two
  explicitly preserve it and the three in `radicle` inherit the environment
  wholesale.
- They read `std::env::vars()` — the **process-wide** environment at spawn
  time, not a per-call config the module could scope.

### What that means for the design

Honouring a configured absolute path means prepending its directory to the
**module process's own `PATH`** before anything can reach a transport. Concretely:

- **It is one line** (`std::env::set_var("PATH", …)`), so the plan's optimistic
  branch is the right one.
- **But it is global state.** The core module shares its process with
  everything else Basecamp loads into it, and `set_var` is `unsafe` from Rust
  2024 onward precisely because it races with concurrent `getenv`. It must
  therefore happen **once, at module init, before any thread starts** — not
  lazily when a setting changes. A settings panel that lets the user change the
  git path will need either a restart-to-apply, or to accept that the write
  happens while a node thread is running.
- **`git::version()` (`git.rs:133`) is public and never called inside the
  crate** — it is a helper the CLI uses. So the wizard's preflight can call it
  directly to validate a candidate binary, exactly as the plan's "validate on
  set, not on first push" wants. Note it also spawns the bare name, so it
  validates *whatever `PATH` currently resolves*, not a path handed to it — to
  validate a specific candidate, spawn `<candidate> --version` directly rather
  than going through this helper.

None of this changes the plan's shape; it sharpens step 0 of the wizard and
adds one ordering constraint to Phase 1.

## 6. The socket path is a real constraint — not in the plan, and it will bite

`Runtime::init` binds the control socket, a Unix domain socket, whose path is
capped at `SUN_LEN`: **108 bytes on Linux, NUL included**. `Home::socket_default()`
appends `node/control.sock` — 17 bytes — to the Radicle home.

This is not hypothetical. The first probe run failed outright:

```
FAILED: Runtime::init returned i/o error: path must be shorter than SUN_LEN
```

The error names **neither the path nor the limit**, which is how it costs an
afternoon. Measured, in this worktree:

| Home | Socket path | Result |
|---|---:|---|
| `<repo>/tmp/n/h` (worktree at `.claude/worktrees/agent-<hash>/`) | 114 bytes | **fails** |
| a short dir outside the repo | 76 bytes | works |

**This repo already knows this cap by a different name.** It is the same
108-byte `sun_path` limit that made *every* Basecamp module segfault over QtRO
sockets, and is why `runtime_dir` is pinned in `scaffold.toml` with a
load-bearing comment. It arrives here from the opposite direction: not the
socket Basecamp creates, but the one an embedded node would.

Consequences for M3, which belong in Phase 1's `RAD_HOME` work rather than
being discovered in Phase 2:

- **The embedded home cannot go just anywhere.** The plan's "`RAD_HOME` →
  Basecamp's own XDG dir" is right in principle, but Basecamp's per-profile XDG
  paths are already deep (`…/profiles/alice/…`), and adding a Radicle home plus
  `node/control.sock` beneath one may not fit. **Measure before choosing**, the
  way the probe does.
- **`RAD_SOCKET` is the escape hatch, and this is what it is for.** The plan
  lists it as a knob for avoiding collisions; it is *also* how to keep the
  socket short when the home must be long. `Home::socket_from_env()`
  (`profile.rs:692`) honours it, and `Runtime::init` takes the socket path as
  an explicit parameter independent of the home — so the two can be separated
  deliberately.
- **Whatever is chosen needs a length check with a real error message**, since
  the crate's own is unusable. The probe's guard (measure, compare to 108,
  say the number) is the minimum shape.

The probe deliberately keeps its directory names down to `n/h` for this reason
and still does not fit in a worktree — which is the clearest possible statement
of how little headroom there is.

## 7. What this does not answer

Left open on purpose; none of it blocks the in-process decision.

- **Whether the node needs the passphrase at start or only at sign time.** The
  probe inits with `None`, so it only proves the *unencrypted* case starts
  without prompting. `main.rs:291-325` reads the secret key up front via
  `keystore.secret_key(passphrase)` and fails if it cannot, which strongly
  suggests an encrypted key needs the passphrase **at start**, not at sign
  time — but that is inference from the binary's flow, not a measurement, and
  the plan's open question stays open until someone inits an encrypted profile
  and tries.
- **`git` availability inside a shipped Basecamp bundle.** Untouched here. Still
  the most likely "works on my machine" failure, and now with five spawn sites
  behind it instead of one.
- **Windows/macOS.** Not attempted; this was measured on Linux x86_64 only.
- **Long-run behaviour.** The probe starts and stops a node in 97 ms. It says
  nothing about memory growth, fd usage, or what happens when the host process
  forks — all Phase 2 concerns.

## Recommendation

**Build the embedded node in-process, as the plan proposed.** Every risk it
flagged for Phase 0 came back clear:

- the dependency graph stays single at `radicle`, `git2` and `libgit2-sys`;
- `default-features = false` genuinely excludes systemd;
- the runtime is a real start/stop API whose process-global concerns all live
  in the binary, not the library — the `radicle-signals` worry was misplaced;
- the size cost is ~7 MB, and a spawned binary would cost comparably while
  adding packaging, discovery and orphan-cleanup work.

Two things the plan should absorb before Phase 1:

1. **The git path is a process-global `PATH` write, ordered before any thread
   starts** — not a per-spawn wrapper, and not `GIT_EXEC_PATH`. There are five
   bare-name spawn sites, two of which `env_clear()` down to `PATH`.
2. **Socket path length is a first-class constraint on where `RAD_HOME` may
   live**, with `RAD_SOCKET` as the deliberate escape hatch. Measure the
   resolved path against 108 bytes and fail with a message that says so.

## What the branch contains

Deliberately minimal, and **not wired into the shipped module**:

- `radicle/rust-ffi/Cargo.toml` — a `node-spike` feature (default off) enabling
  optional `radicle-node` (`default-features = false`) and `radicle-signals`.
  The example is declared `required-features = ["node-spike"]`, so
  `cargo build --all-targets` and `cargo clippy --all-targets` in the default
  build never compile either crate.
- `radicle/rust-ffi/examples/probe_node_runtime.rs` — the probe, following the
  existing `probe_*` convention: an example, not a test, because standing up a
  real node with real SQLite and a real socket is Phase 2 work and a flaky
  `cargo test` here would say nothing about the `local*` path.
- `Cargo.lock` — updated by resolving the optional dependency.
- This document, and the struck-through items in
  `docs/M3-embedded-node-plan.md`.

Nothing in `src/` references `radicle-node`; `CMakeLists.txt` and `flake.nix`
are untouched. **Deleting the feature and the example removes the spike
entirely** — which is the right move once M3 commits, rather than letting a
probe drift into looking like a supported entry point.

Gates on this branch, all green (`radicle/rust-ffi/`):

| Gate | Result |
|---|---|
| `cargo fmt --check` | clean |
| `cargo clippy --all-targets -- -D warnings` | clean (never compiles `radicle-node`) |
| `cargo clippy --all-targets --features node-spike -- -D warnings` | clean |
| `cargo test` | 51 passed, 0 failed, 0 ignored |
