//! M3 Phase 0 spike: is `radicle-node`'s library target drivable in-process,
//! or is it `main()`-shaped?
//!
//! Run with:
//!
//! ```text
//! cargo run --release --features node-spike --example probe_node_runtime
//! ```
//!
//! It writes its throwaway home to the repo's gitignored `tmp/`. An optional
//! first argument overrides that base directory, which is needed when the
//! checkout path is long: the node's control socket is a Unix domain socket
//! capped at 108 bytes of path, and a worktree under `.claude/worktrees/…`
//! can exhaust that on its own. The probe measures the path and says so
//! rather than failing obscurely. See `scratch()` below.
//!
//! **This is a spike, not a feature and not a test.** It is gated behind the
//! `node-spike` cargo feature so the default build — the one CMake links and
//! Nix packages — never sees `radicle-node` at all. Nothing in `src/` refers
//! to it. See `docs/M3-phase0-findings.md` for what it established; delete
//! both this file and the feature once M3 commits to an approach.
//!
//! It is deliberately an *example* rather than a `#[test]`. A test that starts
//! a real node binds a real control socket, opens real SQLite databases and
//! spawns a real thread pool; making that reliable in CI is a piece of work
//! that belongs to Phase 2, not to a spike. Calling it a test here would give
//! the crate a slow, flaky check whose failure would say nothing about the
//! `local*` path — the "check that cannot fail" trap arriving from the other
//! direction.
//!
//! What it proves, by doing rather than by reading:
//!
//! 1. `Runtime::init` + `Runtime::run` start a node with **no process-global
//!    state touched** — no `signals::install`, no logger, no panic hook, no
//!    `exit()`. All of those live in `radicle-node`'s own `main.rs`.
//! 2. The signal channel is an ordinary `mpsc::Receiver<Signal>` supplied by
//!    the *caller*, so an embedder can drive shutdown by sending on it.
//! 3. `Handle::shutdown()` stops the node from another thread, and `run()`
//!    returns rather than killing the process.
//!
//! The home is a throwaway under the repo's gitignored `tmp/`, and
//! `listen: []` means the node binds no TCP port — so running this cannot
//! collide with a real node or touch the developer's `~/.radicle`.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use radicle::crypto::Seed;
use radicle::node::{Alias, Handle as _};
use radicle::profile::{Home, Profile};
use radicle_node::runtime::Runtime;

/// A scratch home for the node, defaulting to the repo's own `tmp/`.
///
/// The names are kept absurdly short on purpose, and that is a Phase 0 finding
/// in its own right. The node's control socket is a Unix domain socket, whose
/// path is capped at `SUN_LEN` — 108 bytes on Linux, NUL included — and
/// `Home::socket_default()` appends `node/control.sock` (17 bytes) to whatever
/// home it is given. Under a worktree at
/// `…/.claude/worktrees/agent-<hash>/` the repo root alone is 84 bytes, so
/// `<root>/tmp/probe-node-runtime/home/node/control.sock` overshoots and
/// `Runtime::init` fails with the unhelpful "path must be shorter than
/// SUN_LEN", naming neither the path nor the limit.
///
/// This is the same 108-byte cap that once made *every* Basecamp module
/// segfault and is why `scaffold.toml` pins `runtime_dir` — arriving here from
/// a different direction. An embedded node inherits the problem: see the
/// findings doc, because it constrains where `RAD_HOME` may live.
///
/// An optional first argument overrides the base directory, for running this
/// from a shallower checkout.
fn scratch() -> PathBuf {
    let base = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            // …/radicle/rust-ffi -> repo root, then the repo's gitignored tmp/.
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .ancestors()
                .nth(2)
                .expect("crate is nested at least two levels below the repo root")
                .join("tmp")
        });
    let dir = base.join("n");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("could not create scratch dir");
    dir
}

fn main() {
    let dir = scratch();
    let home = Home::new(dir.join("h")).expect("could not create Radicle home");

    // No passphrase: the key is written unencrypted. That answers the plan's
    // open question "does the node need the passphrase at start or only at
    // sign time" only for the unencrypted case — see the findings doc.
    let profile = Profile::init(home, Alias::new("spike"), None, Seed::new([9u8; 32]))
        .expect("could not init profile");
    println!("profile home: {}", profile.home().path().display());
    println!("node id:      {}", profile.id());

    // The signing key, read straight from the keystore with no passphrase.
    let signer = radicle::crypto::ssh::Keystore::new(&profile.home().keys())
        .secret_key(None)
        .expect("could not read secret key")
        .expect("no secret key on disk");

    // The three isolation knobs from the plan, all exercised at once:
    //   - home:   a throwaway dir, not ~/.radicle
    //   - socket: inside that home, so no collision with a running node
    //   - listen: empty, so no TCP port is bound at all
    let mut config = profile.config.node.clone();
    config.listen = vec![];
    config.connect.clear();
    // `socket_default()`, not `socket_from_env()`: the latter honours
    // RAD_SOCKET, so running this probe on a machine that exports it would
    // aim at the developer's real node. Isolation has to be by construction.
    let socket = profile.home().socket_default();

    // Say so before failing on it. `Runtime::init`'s error for an over-long
    // socket path is "i/o error: path must be shorter than SUN_LEN", which
    // names neither the path nor the limit.
    let socket_len = socket.as_os_str().len();
    println!("control socket path is {socket_len} bytes (SUN_LEN cap is 108)");
    if socket_len >= 108 {
        println!(
            "SKIPPED: this path is too long for a Unix domain socket. \
             This checkout's path is too deep. Re-run from a shallower clone, \
             or pass a shorter base directory as the first argument. This is a \
             real constraint on an embedded node, not a quirk of the probe — \
             see docs/M3-phase0-findings.md."
        );
        return;
    }

    // The whole question in one line: the caller owns the signal channel.
    // `radicle-node`'s `main.rs` calls `radicle_signals::install(notify)` to
    // fill it from real SIGINT/SIGTERM; nothing in the *library* does. An
    // embedded node hands over a channel it drives itself, and the process's
    // own signal disposition is never touched.
    let (notify, signals) = mpsc::sync_channel(1);

    let started = Instant::now();
    let runtime = match Runtime::init(
        profile.home().clone(),
        config,
        socket.clone(),
        vec![],
        signals,
        signer,
    ) {
        Ok(rt) => rt,
        Err(e) => {
            println!("FAILED: Runtime::init returned {e}");
            return;
        }
    };
    println!("Runtime::init OK in {:?}", started.elapsed());
    println!("  control socket: {}", socket.display());
    println!(
        "  listening on:   {:?} (empty means outbound-only)",
        runtime.local_addrs
    );

    // A clone of the handle, kept on this thread so we can stop the node after
    // `run()` has consumed the Runtime. `Handle` is `Clone` precisely because
    // `run()` itself clones one for the control thread (runtime.rs:274).
    let handle = runtime.handle.clone();

    let node = std::thread::spawn(move || runtime.run());

    // Wait for the control socket to answer, which is what "started" means to
    // anything outside the process. Poll rather than sleep a fixed time — a
    // fixed sleep is the shape that passes on a fast machine and flakes on a
    // slow one.
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut up = false;
    while Instant::now() < deadline {
        if radicle::node::Node::new(&socket).is_running() {
            up = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    println!(
        "control socket answering: {up} (after {:?})",
        started.elapsed()
    );

    // Two independent stop paths, to show neither needs a real signal:
    //   1. the signal channel the caller owns
    //   2. Handle::shutdown() directly
    // Send on the channel first; if the node is already down, the handle call
    // is a no-op thanks to its compare_exchange guard (handle.rs:357).
    let _ = notify.try_send(radicle_signals::Signal::Terminate);
    handle.shutdown().ok();

    match node.join() {
        Ok(Ok(())) => println!("Runtime::run returned cleanly — the node is stoppable in-process"),
        Ok(Err(e)) => println!("Runtime::run returned an error: {e}"),
        Err(_) => println!("FAILED: the node thread panicked"),
    }
    println!("total: {:?}", started.elapsed());

    let _ = std::fs::remove_dir_all(&dir);
}
