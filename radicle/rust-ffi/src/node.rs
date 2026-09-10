//! Running a Radicle node **in this process**, started and stopped by the
//! module rather than by a user with a terminal.
//!
//! This is M3 Phase 2 step 3, and the last piece of "Embedded" that was not
//! there: steps 1 and 2 gave the mode an identity and a home of its own, and
//! everything short of a daemon already worked against them. What this adds is
//! the daemon.
//!
//! ## Why in-process, and why that is not the expensive part
//!
//! Phase 0 spiked this rather than reasoning about it
//! ([`docs/M3-phase0-findings.md`](../../../docs/M3-phase0-findings.md) §3).
//! `radicle-node`'s library target is a genuine start/stop lifecycle —
//! `Runtime::init`, `Runtime::run`, `Handle::shutdown` — and every
//! process-global act lives in its `main.rs`, not in the library: no
//! `signals::install`, no `log::set_boxed_logger`, no `panic::set_hook`, no
//! `exit()`. An embedder inherits none of them. Measured start-to-stop was 97
//! ms.
//!
//! The alternative was shipping the `radicle-node` binary inside the `.lgx` and
//! spawning it, which costs comparable *size* and adds packaging, runtime
//! discovery and orphan-process cleanup when Basecamp dies. In-process is not
//! the expensive option; running a node at all is.
//!
//! ## The signal channel is ours, and `install()` is never called
//!
//! `Runtime::init` takes `signals: mpsc::Receiver<Signal>` — the **caller**
//! supplies it. `radicle-node`'s `main.rs` fills it from real SIGINT/SIGTERM via
//! `radicle_signals::install()`, which is a `sigaction` call and therefore
//! process-global. This crate is linked into Basecamp, whose signal disposition
//! is not ours to change, so that function is never called here and the sender
//! half is driven by [`stop`] alone. The dependency exists for the `Signal`
//! enum and nothing else.
//!
//! ## The panic surface this opens, stated rather than discovered
//!
//! [`crate::guarded`] catches panics at the `extern "C"` boundary, and
//! `docs/rust-ffi.md` treats "every panic in this crate is caught at a known
//! boundary" as a safety invariant. **A node breaks that**, and it is better to
//! write that down than to let someone find it: the reactor, the worker pool and
//! the control listener are threads `radicle-node` spawns, none of them behind
//! our boundary, and `Runtime::run` itself ends with `self.pool.run().unwrap()`
//! and `self.reactor.join().unwrap()` (`runtime.rs:300-301`) — so a worker-pool
//! or reactor failure panics rather than returning `Err`.
//!
//! What that means concretely is the failure shape [`status`] is built around: a
//! node can be **half-dead with nothing reporting it** — a panicked reactor
//! while the `local*` read path answers normally, because reads never touch the
//! daemon. So "is the node running" is deliberately not answered from our own
//! state alone. `running` means the thread we spawned has not finished;
//! `serving` is a live probe of the control socket, and it is the same probe —
//! a bare `connect`, deliberately — that `LocalStore::nodeRunning()` performs
//! from C++, so the two cannot disagree about one node.
//!
//! **What that pair catches, and what it does not.** It catches a thread that
//! ended (`running` false) and a socket that has gone (`serving` false), which
//! covers a `run()` that returned or panicked outright. It does **not** catch a
//! node whose control listener still accepts while its workers are dead: that
//! thread is detached and never joined (`runtime.rs:303-304`), so the connect
//! succeeds. Distinguishing that needs a command round trip, and the crate's own
//! `Node::is_running()` does exactly that with a **30-second** read timeout
//! (`command.rs:24`) — which, in this very state, blocks for the full 30 seconds
//! on a call a UI polls, freezing every other module call behind it. The cheap
//! probe with the honest limit is the better trade until something can act on
//! the difference. See [`socket_answers`].
//!
//! ## One node per process, and why that is a data shape rather than a check
//!
//! The state is a single `Mutex<Option<Node>>`. Two nodes in one process would
//! mean two writers on one git storage — the exact hazard the whole isolation
//! design exists to prevent — and holding at most one handle makes "already
//! running" an answer this module can give rather than an invariant every call
//! site has to remember.

use std::path::PathBuf;
use std::sync::{mpsc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use radicle::node::Handle as _;
use radicle::profile::Home;
use serde_json::json;

/// How long [`start`] waits for the control socket to answer before reporting
/// that the node did not come up.
///
/// Polled rather than slept: a fixed sleep is the shape that passes on a fast
/// machine and flakes on a slow one. Phase 0 measured 97 ms start-to-stop on an
/// idle profile, so this is roughly two orders of magnitude of headroom for a
/// loaded machine, a cold page cache or a large storage tree.
const START_TIMEOUT: Duration = Duration::from_secs(20);

/// How long [`Node::shut_down`] waits for the node thread to finish after asking
/// it to.
///
/// Bounded rather than an unbounded `join()`, because Phase 0 explicitly did
/// **not** measure shutdown cost with a fetch in flight — it stopped an idle
/// node in 97 ms — and an unbounded join turns an unmeasured cost into a frozen
/// caller. Exceeding it is reported, not swallowed.
///
/// **This is not an application-exit budget, because there is no exit path.**
/// An earlier version of this comment said "Basecamp closing is exactly when a
/// user notices a hang", which presumes a shutdown hook this module does not
/// have: `RadicleImpl` has no destructor, the module contract exposes no unload
/// callback, and nothing calls `stop` on the way out. If Basecamp exits with a
/// node running, the process dies with the node's threads mid-flight and its
/// control socket file left on disk — after which the next start fails inside
/// `Runtime::bind` with `AlreadyRunning`.
///
/// That gap is real and is recorded in `docs/M3-embedded-node-plan.md` under
/// step 3 rather than fixed here: adding a destructor to `RadicleImpl` risks the
/// generator that derives this module's dispatch table from its `public:`
/// section, which has already once emitted a call to a constructor it mistook
/// for an RPC method. `stop` is the only stop path today, and it is one a user
/// takes.
const STOP_TIMEOUT: Duration = Duration::from_secs(10);

/// A running node, and the two independent ways to stop it.
struct Node {
    /// The home it was started against, so [`status`] can report which node this
    /// is without re-reading any settings. A module that reports a node running
    /// but not which home it belongs to is one round-trip away from the identity
    /// confusion this milestone exists to prevent.
    home: String,
    /// Its control socket, likewise — and this one is load-bearing rather than
    /// informational: it is what [`status`] probes to tell a live node from a
    /// thread that panicked.
    socket: String,
    /// The signal channel `Runtime::init` was handed the receiving end of.
    /// Sending `Terminate` is one stop path.
    notify: mpsc::SyncSender<radicle_signals::Signal>,
    /// A clone of the runtime's handle, kept because `run()` consumes the
    /// `Runtime`. `Handle::shutdown()` is the other stop path, and is idempotent
    /// — guarded by a `compare_exchange` on an `AtomicBool`
    /// (`handle.rs:357-363`) — so using both is safe.
    handle: radicle_node::runtime::handle::Handle,
    /// The thread `run()` is on.
    ///
    /// `Option` because [`Node::shut_down`] takes it to join — and `None` for a
    /// runtime that was built but whose thread never started, which is a real
    /// state rather than a placeholder: see [`start_inner`]'s spawn-failure path.
    thread: Option<std::thread::JoinHandle<Result<(), radicle_node::runtime::Error>>>,
}

impl Node {
    /// Stop this node and wait, briefly, for its thread to end.
    ///
    /// `Ok(())` means the node is stopped. An `Err` names why it might not be,
    /// and the caller has still lost its handle on it — this consumes `self`
    /// precisely so that a `Node` cannot be discarded without going through
    /// here.
    ///
    /// **That is the point of this being a method rather than inline code in
    /// [`stop`].** `Runtime::init` spawns the reactor and the whole worker pool
    /// and binds the control socket BEFORE it returns (`runtime.rs:226`, `:234`,
    /// `:249`), and `radicle-node` has **no `Drop` impl for `Runtime` or
    /// `ControlSocket`** — the socket file is unlinked only on `run()`'s success
    /// path (`runtime.rs:307`). So dropping a `Node` does not stop anything: it
    /// detaches the threads, leaves the socket bound, and leaves the socket file
    /// on disk, after which every later start fails inside `Runtime::bind` with
    /// `AlreadyRunning` and nothing can explain why. Every path that gives up a
    /// `Node` therefore calls this.
    fn shut_down(mut self) -> Result<(), String> {
        // Two independent stop paths, deliberately both used.
        //
        // The channel is the one an embedder owns; `Handle::shutdown()` is the
        // one that works even if the runtime's signal thread has already exited.
        // Neither subsumes the other, and using both is safe because `shutdown`
        // is idempotent, guarded by a `compare_exchange` (`handle.rs:357-363`).
        // Failures are ignored here on purpose — what matters is whether the
        // THREAD ended, which is checked below; a handle whose socket has
        // already gone is a node that is already stopping.
        let _ = self.notify.try_send(radicle_signals::Signal::Terminate);
        let _ = self.handle.shutdown();

        // No thread means `Runtime::init` succeeded and the spawn did not. The
        // shutdown above is still exactly what is needed — it is what stops the
        // reactor and workers `init` already started — and there is nothing to
        // join.
        let Some(thread) = self.thread.take() else {
            return Ok(());
        };

        // Bounded rather than a bare `join()`. See STOP_TIMEOUT: shutdown cost
        // under load is unmeasured, and Basecamp closing is when a user notices
        // a hang.
        let deadline = Instant::now() + STOP_TIMEOUT;
        while Instant::now() < deadline && !thread.is_finished() {
            std::thread::sleep(Duration::from_millis(20));
        }

        if !thread.is_finished() {
            // Deliberately NOT joined: the caller has already given up its
            // handle, so a later start is not blocked by a thread that will not
            // end. Reported rather than swallowed, because a node still holding
            // its storage is a fact the next start may trip over and the user is
            // the only one who can act on it.
            return Err(format!(
                "the node did not stop within {} seconds. It may still be \
                 holding its control socket and storage; restarting Basecamp \
                 will clear it.",
                STOP_TIMEOUT.as_secs()
            ));
        }

        match thread.join() {
            Ok(Ok(())) => Ok(()),
            // `Runtime::run` returning an error at shutdown is worth reporting:
            // it is the difference between a clean stop and one that lost work.
            Ok(Err(e)) => Err(format!("the node stopped with an error: {e}")),
            // The panic shape the module docs name. It has already happened by
            // the time we see it — the point of reporting it is that the
            // alternative is a node that silently stopped serving while
            // everything else kept answering normally.
            Err(_) => Err("the node thread panicked; the node is stopped".to_string()),
        }
    }
}

/// The one node this process may run. See the module docs for why one.
fn cell() -> &'static Mutex<Option<Node>> {
    static NODE: OnceLock<Mutex<Option<Node>>> = OnceLock::new();
    NODE.get_or_init(|| Mutex::new(None))
}

/// Take the lock, recovering from a poisoned mutex rather than panicking.
///
/// A poisoned lock means a previous holder panicked while holding it. Panicking
/// again here would be a panic on a path whose whole job is to survive one — and
/// the data behind it is a single `Option<Node>`, not a structure a partial
/// update could leave inconsistent. Recovering keeps the module answering
/// instead of turning one bad call into a permanently dead node surface.
fn locked() -> std::sync::MutexGuard<'static, Option<Node>> {
    cell().lock().unwrap_or_else(|e| e.into_inner())
}

/// Whether anything is listening on `socket` right now.
///
/// This is the definition of "running" that matters, and it is deliberately not
/// our own bookkeeping: a thread that panicked mid-flight still has a
/// `JoinHandle` that has not been joined, so our state would keep saying
/// `running` about a node nobody can talk to. The socket answers or it does not.
///
/// ## Why this is a bare `connect`, and not `Node::is_running()`
///
/// The obvious implementation is `radicle::node::Node::new(path).is_running()`,
/// and it is a **30-second blocking call in exactly the state this function
/// exists to detect.** `is_running` sends a `Status` command and reads the
/// reply with `DEFAULT_TIMEOUT`, which is 30 seconds
/// (`radicle-0.25.1/src/node/command.rs:24`). A half-dead node — one whose
/// control listener thread still accepts, because `run()` detaches it and never
/// joins it, but whose worker pool or reactor has died — accepts the connection
/// and then never answers. So the probe blocks for the full 30 seconds, and
/// this module's calls arrive serialized on one thread: a UI polling
/// `getNodeStatus()` would freeze every `remote*` call and every local read
/// along with it.
///
/// A bare `connect` proves someone is listening and returns immediately. That
/// is a weaker fact, and it is deliberately the SAME weaker fact
/// `LocalStore::nodeRunning()` establishes on the C++ side
/// (`local_store.cpp:203-213`) — so `serving` here and `localNodeRunning` there
/// are one question with one answer, rather than two probes with different
/// semantics that disagree precisely in the interesting case.
///
/// What that costs is honest and worth stating: a node whose listener accepts
/// but which cannot serve reads as `serving: true` here. Distinguishing that
/// needs a command round trip, and a round trip needs a timeout short enough not
/// to block a UI — which is a real improvement to make when something can act on
/// the difference, not a reason to block for 30 seconds now.
fn socket_answers(socket: &str) -> bool {
    if socket.is_empty() || socket.len() + 1 > SUN_PATH_MAX {
        return false;
    }
    std::os::unix::net::UnixStream::connect(socket).is_ok()
}

/// Start a node against `home`, with its control socket at `socket`.
///
/// -> `{"started":true,"home":"…","socket":"…","nodeId":"did:key:z6Mk…","listening":[…]}`
/// -> `{"error":"…"}`
///
/// ## Both paths are parameters, and neither is read from the environment
///
/// `home` and `socket` arrive from the C++ side because exactly one place
/// resolves them — `LocalStore`, via `resolvePaths()` — and a second opinion
/// here is precisely how the read path and the write path once came to probe two
/// different sockets (see `tests/control_socket.rs`, and `cobwrite.rs`'s
/// announce step, which had the same bug). A node that binds a socket the rest
/// of the module is not watching is that bug in its most consequential form:
/// every `localNodeRunning` probe would say no while a node ran perfectly.
///
/// It also matters for isolation. `Home::socket_from_env()` honours `RAD_SOCKET`
/// and `Profile::home()` honours `RAD_HOME`; a node that consulted either could
/// be aimed at the user's real `~/.radicle` by an environment this module did
/// not set. Embedded's promise is a separate identity, and it has to hold
/// structurally rather than because nothing happened to export those variables.
///
/// ## `listen: []` — outbound-only, and stated as a limitation
///
/// The node binds **no TCP port**. That is the right default for a desktop
/// behind NAT: it needs no port, no firewall rule, and cannot collide with a
/// node the user already runs on 8776. It is also a real limitation the UI must
/// be honest about — an outbound-only node can fetch and announce, but peers
/// **cannot fetch from it**. The reply reports `listening` so a caller states
/// what is true rather than implying a full node.
///
/// Accepting inbound connections is a config-panel opt-in with a port field
/// (plan §"The configuration panel"), not a default, and not this step.
///
/// ## The passphrase, and the question Phase 0 left open
///
/// Phase 0 could only prove that an *unencrypted* profile starts without a
/// prompt; whether an encrypted one needs its passphrase at start or only at
/// sign time was inference from `main.rs`'s flow rather than a measurement
/// (§7). It needs it **at start**: `Runtime::init` takes a signer, so the secret
/// key must be readable before the node exists — there is no later point to
/// supply it. `tests/node_lifecycle.rs` measures that directly rather than
/// leaving it inferred, in both directions.
///
/// The consequence for the wizard is worth stating where the code is: a profile
/// created *with* a passphrase cannot be started unattended, and this reports
/// that as a reason naming the passphrase rather than as an opaque key error.
pub fn start(home: &str, socket: &str, passphrase: &str) -> String {
    match start_inner(home, socket, passphrase) {
        Ok(v) => v,
        Err(e) => crate::local::error(e),
    }
}

fn start_inner(home: &str, socket: &str, passphrase: &str) -> Result<String, String> {
    if home.is_empty() {
        return Err("no Radicle home given to start a node in".to_string());
    }
    if socket.is_empty() {
        return Err("no control socket path given to start a node on".to_string());
    }

    // The same 108-byte cap that made every Basecamp module segfault over QtRO
    // sockets, arriving from the other direction. `Runtime::init`'s own error is
    // "i/o error: path must be shorter than SUN_LEN", which names neither the
    // path nor the limit nor the actual length — which is exactly what made it
    // cost Phase 0 an afternoon.
    //
    // Checked here as well as in `resolvePaths()` on the C++ side, and that is
    // not redundant for the reason `SettingsStore::set` is not: this is the only
    // check on the value that actually reaches `bind`, and a future caller that
    // resolves a socket some other way inherits it.
    if socket.len() + 1 > SUN_PATH_MAX {
        return Err(format!(
            "the node control socket path is too long: {socket} is {} bytes, but \
             a Unix socket path is capped at {} bytes (plus a terminating NUL). \
             Set radSocket to a shorter path, such as one under $XDG_RUNTIME_DIR.",
            socket.len(),
            SUN_PATH_MAX - 1
        ));
    }

    // Refuse a start while one is running, and clear the slot when what is in it
    // is finished — but never simply *drop* what was there.
    //
    // Both halves are done under one `take()` and outside the lock, in this
    // order, and each detail is load-bearing:
    //
    // - **"Already running" is decided on the thread alone, not on the socket.**
    //   An earlier version required BOTH a live thread and an answering socket
    //   to refuse, which meant a node that was mid-startup — or in the half-dead
    //   state this module is written around — fell through to being replaced. It
    //   would then be dropped without a shutdown while its reactor and workers
    //   were still running, and a second `Runtime::init` would go up against the
    //   same git storage. Two nodes on one storage is the exact hazard the
    //   isolation design exists to prevent, so the liveness test has to be the
    //   conservative one: if the thread has not finished, there is a node.
    // - **A finished node is shut down, not dropped.** `Runtime::init` already
    //   spawned the reactor and worker pool and bound the socket, and nothing in
    //   `radicle-node` drops any of it — see `Node::shut_down`. A `thread` that
    //   finished means `run()` returned; the shutdown is still what releases the
    //   rest, and its failure is ignored here because the node it refers to is
    //   already gone and this call is about starting a new one.
    // One named guard, taken once and dropped before the shutdown below.
    //
    // Written this way after the obvious version deadlocked: `locked().take()`
    // followed by `*locked() = Some(existing)` to put a still-running node back
    // takes the same non-reentrant mutex twice, and the first temporary guard is
    // still alive for the whole statement. The test suite hung rather than
    // failing, which is the shape a deadlock always has — so the fix is not to
    // sequence two locks more carefully but to take one, inspect under it, and
    // decide before releasing.
    let corpse = {
        let mut guard = locked();
        match guard.as_ref() {
            Some(existing) if existing.thread.as_ref().is_some_and(|t| !t.is_finished()) => {
                return Err(format!(
                    "a node is already running for {} on {} — stop it before \
                     starting another. This module runs at most one node, \
                     because two nodes writing one git storage is the failure \
                     the embedded mode exists to prevent.",
                    existing.home, existing.socket
                ));
            }
            // Finished, or nothing there. Take it out under the same lock so no
            // other caller can adopt it, and shut it down after releasing.
            _ => guard.take(),
        }
    };
    // Outside the lock: `shut_down` waits on a thread, and holding the process's
    // one node lock across that would block `status` and `stop` behind it. The
    // failure is ignored because the node it refers to has already finished and
    // this call is about starting a new one.
    if let Some(existing) = corpse {
        let _ = existing.shut_down();
    }

    let home_path = PathBuf::from(home);

    // **Not `Profile::load()`, and that is the whole of the isolation guarantee
    // at this layer.** `Profile::load` calls `profile::home()` (`profile.rs:278`,
    // `:509`), which reads `RAD_HOME` and then `$HOME/.radicle` — so a node
    // started through it could be aimed at the user's own profile by an
    // environment this module never set. Embedded's promise is a separate
    // identity, and it has to hold structurally rather than because nothing
    // happened to export that variable.
    //
    // What is given up is small and replaced below: `Profile::load` also loads
    // the config, reads the public key and opens storage. `Runtime::init` opens
    // storage itself from `home.storage()`, and the other two are the next two
    // statements. `local::open_storage` declines `Profile::load` for the same
    // reason.
    //
    // **And `Home::load`, not `Home::new`.** `Home::new` *creates* the directory
    // and all four subdirectories if they are missing (`profile.rs:586-602`),
    // which is right for `init_profile` — it is making a home — and wrong here.
    // Starting a node must never bring a home into existence: against a typo'd
    // or not-yet-created path, `new` would silently leave an empty Radicle home
    // on disk and then fail with "no signing key", reporting the second problem
    // and causing the first. `load` refuses a home that is not there, which is
    // the honest answer to "start a node in this home".
    let radicle_home = Home::load(&home_path).map_err(|e| {
        format!("could not open the Radicle home {home}: {e}. A node can only be started in a home that already holds an identity.")
    })?;

    let signer = read_signer(&radicle_home, passphrase)?;

    // The node's own key/home consistency check, which `main.rs` performs and
    // the library does not.
    //
    // It is not ceremony here: it is the one check that catches a signing key
    // swapped under an existing home, and this module's standing failure mode is
    // a user operating as an identity they did not expect. The node stores a
    // fingerprint of the public key on first start and refuses to start against
    // a different one afterwards — so a home whose storage was built by one
    // identity cannot quietly start serving as another.
    verify_fingerprint(&radicle_home, &signer)?;

    // Start from the home's own `config.json` rather than a config built here,
    // so a future configuration panel writing that file takes effect instead of
    // this function silently being the only opinion that counts. A missing or
    // unreadable config is an error rather than a default: a node started
    // against settings nobody wrote is a node doing something the user did not
    // ask for.
    let config = radicle::profile::Config::load(radicle_home.config().as_path())
        .map_err(|e| format!("could not read the node configuration at {home}: {e}"))?;
    let mut config = config.node;
    // Outbound-only. See the doc comment: the safe default, and a real
    // limitation the reply reports rather than hides.
    config.listen = vec![];

    // The caller owns the signal channel; `radicle_signals::install()` is never
    // called from this crate.
    //
    // Capacity 1, and the send is a `try_send` that may therefore drop a second
    // signal on a full channel. That is fine because the channel is the
    // *secondary* stop path, not the primary one: `Handle::shutdown()` is what
    // actually stops the node and is idempotent, and the channel exists so an
    // embedder can stop it the way `main.rs` does. A dropped duplicate Terminate
    // costs nothing when the first one is already queued.
    let (notify, signals) = mpsc::sync_channel(1);

    // The node id, taken before the signer is moved into the runtime. Reported
    // so a caller can say WHICH identity is now serving without a second call —
    // and can compare it against `getCapabilities().nodeId`, since the whole
    // point of Embedded is that those two are different from the user's own.
    let node_id = {
        use radicle::crypto::Signer as _;
        radicle::identity::Did::from(*signer.public_key()).to_string()
    };

    let socket_path = PathBuf::from(socket);
    let runtime = radicle_node::runtime::Runtime::init(
        radicle_home,
        config,
        socket_path.clone(),
        // `listen` here is the runtime's own argument, separate from
        // `config.listen`. Both are empty: outbound-only, no port bound, and
        // therefore no way to collide with a node the user already runs.
        vec![],
        signals,
        signer,
    )
    .map_err(|e| format!("could not start the node: {e}"))?;

    let listening: Vec<String> = runtime.local_addrs.iter().map(|a| a.to_string()).collect();

    // **From here on the runtime must be shut down on every path, including the
    // one where nothing has started yet.**
    //
    // `Runtime::init` is not a passive constructor. Its own doc comment says
    // "This function spawns threads", and by the time it returns the reactor
    // (`runtime.rs:226`) and every worker (`:234`) are running and the control
    // socket is bound (`:249`). `radicle-node` has no `Drop` for `Runtime` or
    // `ControlSocket`, and the socket file is unlinked only on `run()`'s success
    // path (`:307`).
    //
    // So a bare `?` on the spawn below would detach the reactor and the whole
    // worker pool, leave the socket bound with nothing registered to stop it,
    // and leave its file on disk — after which every later `start` fails inside
    // `Runtime::bind` with `AlreadyRunning` and nothing can say why. The node
    // would be unstartable until Basecamp restarted.
    //
    // A `Node` with `thread: None` is therefore built FIRST, so the runtime is
    // owned by something that knows how to stop it before anything else can go
    // wrong. `Node::shut_down` handles the no-thread case explicitly.
    let mut node = Node {
        home: home.to_string(),
        socket: socket.to_string(),
        notify,
        handle: runtime.handle.clone(),
        thread: None,
    };

    match std::thread::Builder::new()
        // Named so a stack trace or a thread dump says which thread this is.
        // A panicking reactor is one of the failure shapes the module docs name,
        // and an unnamed thread makes that report harder to read.
        .name("radicle-node".to_string())
        .spawn(move || runtime.run())
    {
        Ok(thread) => node.thread = Some(thread),
        Err(e) => {
            // The runtime's already-running threads are stopped before this
            // returns, rather than leaked. The shutdown's own failure is folded
            // into the message: both facts matter to a caller, and the spawn
            // failure is the one that explains the rest.
            let cleanup = node.shut_down().err().unwrap_or_default();
            return Err(format!(
                "could not spawn the node thread: {e}{}",
                if cleanup.is_empty() {
                    String::new()
                } else {
                    format!(" (and stopping the partly-started node reported: {cleanup})")
                }
            ));
        }
    }

    *locked() = Some(node);

    // The lock is not held across the wait below. Holding it for up to
    // `START_TIMEOUT` would make `status` — the call a UI polls to render
    // progress — block for the whole startup, which is precisely the moment a UI
    // most needs to answer.
    //
    // **The window that opens, stated rather than implied away:** a concurrent
    // `stop()` can take this node while the loop below is still waiting. That
    // call stops a real node and succeeds; this one then sees the socket go
    // quiet and reports a failed start. The *message* is misleading in that
    // interleaving — the node did start, and was then stopped — but nothing
    // leaks and nothing is inconsistent, because whoever wins the `take()` owns
    // the node and is the one that shuts it down. Not defended against: closing
    // it means either holding the lock across the wait (the hang above) or a
    // generation counter, to prevent a wrong sentence in a sequence the UI does
    // not produce — a view offering Start does not also offer Stop while the
    // start is in flight.

    // "Started" means the control socket answers, not that a thread was spawned.
    //
    // **What this wait does and does not catch, since the two are easily
    // confused.** `Runtime::init` binds the socket before it returns
    // (`runtime.rs:249`), so by the time we get here a connect almost always
    // succeeds immediately and this loop completes on its first iteration — and
    // deleting the wait entirely leaves the test suite green, which
    // `tests/node_lifecycle.rs` records honestly rather than claiming otherwise.
    //
    // It is kept for the narrow case it can still catch: a thread that finished
    // before serving, which the `is_finished` check below turns into a fast,
    // explanatory failure instead of a success. `Runtime::run` ends with
    // `self.pool.run().unwrap()` and `self.reactor.join().unwrap()`
    // (`runtime.rs:300-301`), so a worker-pool or reactor failure panics rather
    // than returning `Err` — the module docs' half-dead shape. This is where it
    // is cheapest to report.
    let deadline = Instant::now() + START_TIMEOUT;
    let mut up = false;
    while Instant::now() < deadline {
        if socket_answers(socket) {
            up = true;
            break;
        }
        // Cheap to check and it ends the wait early: if the thread is already
        // finished the socket is never going to answer, and waiting the full
        // timeout would turn a fast, clean failure into a 20-second hang.
        if locked()
            .as_ref()
            .and_then(|n| n.thread.as_ref())
            .is_some_and(|t| t.is_finished())
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    if !up {
        // Clean up rather than leaving a handle to a node that never came up —
        // otherwise the next `start` is refused by a corpse and `status` reports
        // a node that is not there.
        //
        // The socket is checked before taking, rather than calling `stop_inner`
        // outright, because the lock was released above: what is in the slot now
        // is not necessarily what this call put there. Stopping someone else's
        // node while reporting our own failed start would be a second bug
        // reported as the first. Identity by socket path is enough here — the
        // slot holds at most one node, and no two nodes can share a socket,
        // since binding it is what `Runtime::init` does.
        let mine = {
            let mut guard = locked();
            match guard.as_ref() {
                Some(n) if n.socket == socket => guard.take(),
                _ => None,
            }
        };
        // The reason from the thread is preferred over a generic timeout: it is
        // the actual failure, where the timeout is only how we noticed.
        let reason = mine.and_then(|n| n.shut_down().err());
        return Err(match reason {
            Some(r) => format!("the node did not start: {r}"),
            None => format!(
                "the node did not answer on {socket} within {} seconds of \
                 starting, and stopped without reporting why",
                START_TIMEOUT.as_secs()
            ),
        });
    }

    Ok(json!({
        "started": true,
        "home": home,
        "socket": socket,
        "nodeId": node_id,
        // Reported so a caller can state that peers cannot fetch from this node
        // rather than implying a full one. Empty is the expected value today.
        "listening": listening,
    })
    .to_string())
}

/// The `sun_path` capacity for a Unix domain socket on Linux, NUL included.
///
/// Mirrors `kSunPathMax` in `local_store.h`. Two constants for one number is not
/// ideal, but the alternatives are worse: the C++ side cannot read a Rust
/// constant without an FFI call on a path that must work before any node exists,
/// and inlining `108` in either place is what makes a length error name no limit
/// at all. `tests/node_lifecycle.rs` asserts the message names the number, so a
/// drift between the two shows up as a wrong sentence rather than as silence.
const SUN_PATH_MAX: usize = 108;

/// Read the node's signing key, mapping the crate's errors onto the cause.
///
/// ## This settles the question Phase 0 left open
///
/// The plan asked whether the node needs the passphrase **at start** or only at
/// sign time, and answered "probably at start" by reading `main.rs`'s flow
/// rather than by measuring (`docs/M3-phase0-findings.md` §7). The type
/// signature settles it: `Runtime::init` takes a `SigningKey` — the decrypted
/// private half — as a parameter, so it must be readable before the node exists.
/// There is no later point at which a passphrase could be supplied.
///
/// So an encrypted embedded profile **cannot start unattended**, and that is a
/// consequence the wizard states rather than discovers. It is also why the
/// no-passphrase branch below carries the longer message: an encrypted key with
/// no passphrase offered is by far the most likely failure here, and the crate's
/// own error for it is a decryption failure that reads like file corruption.
///
/// ## Deliberately not `cobwrite::signer`'s three-source search
///
/// That function tries the plaintext keystore, then `RAD_PASSPHRASE`, then
/// ssh-agent, because a *write* has to work in whatever session the user's own
/// `rad auth` left behind. None of that applies here, and two parts of it are
/// actively wrong for an embedded node:
///
/// - **ssh-agent holds the USER's key**, put there by `rad auth` against their
///   own profile. Reaching for it while starting a node in Basecamp's own home
///   is how an embedded node would come to run as the identity the mode exists
///   to be separate from — and the fingerprint check would then refuse the
///   start, which is the good outcome of a lookup that should not happen.
/// - **`RAD_PASSPHRASE` is the environment**, and the same argument that keeps
///   `RAD_HOME` out of this file keeps it out too: what unlocks Basecamp's key
///   is the caller's to pass, not the ambient environment's to decide.
///
/// The passphrase is therefore a parameter and the keystore is the only source.
fn read_signer(home: &Home, passphrase: &str) -> Result<radicle::crypto::SigningKey, String> {
    use radicle::crypto::ssh::keystore::Passphrase;
    use radicle::crypto::ssh::Keystore;

    let keys = home.keys();
    let keystore = Keystore::new(&keys);

    // Empty means "the key is unencrypted", the same convention `init_profile`
    // writes with and the same one `ssh-keygen` and the crate's own
    // `env::passphrase()` use. Three places agreeing beats a fourth meaning.
    let pass = if passphrase.is_empty() {
        None
    } else {
        Some(Passphrase::from(passphrase.to_string()))
    };

    let secret = keystore.secret_key(pass).map_err(|e| {
        if passphrase.is_empty() {
            format!(
                "could not read the node's signing key: {e}. If this identity was \
                 created with a passphrase, the node needs it at START — the key \
                 is decrypted before the node exists, so there is no later point \
                 to supply one."
            )
        } else {
            format!("the passphrase did not unlock the node's signing key: {e}")
        }
    })?;

    secret.ok_or_else(|| {
        format!(
            "no signing key at {} — this Radicle home has no identity to run a \
             node as. Create one first.",
            keys.display()
        )
    })
}

/// Refuse to start if the key does not match the one this home was built with.
///
/// `radicle-node` writes a fingerprint of its public key into `<home>/node/` on
/// first start and compares against it afterwards. Its `main.rs` performs the
/// check; the library does not, so an embedder that skips it silently drops a
/// guard the daemon otherwise has.
///
/// It is worth having here specifically because of what this module is: the
/// failure it catches is a home whose storage was built by one identity being
/// served by another, which is the identity confusion the whole Embedded design
/// is written against, arriving from the one direction the mode's structural
/// guarantees do not cover — the key file changing rather than the home.
///
/// A missing fingerprint means a first start, and initialises it.
fn verify_fingerprint(home: &Home, signer: &radicle::crypto::SigningKey) -> Result<(), String> {
    use radicle_node::fingerprint::{Fingerprint, FingerprintVerification};

    let existing = Fingerprint::read(home)
        .map_err(|e| format!("could not read the node's key fingerprint: {e}"))?;

    match existing {
        Some(fp) if fp.verify(signer) != FingerprintVerification::Match => Err(format!(
            "the signing key does not match the one this Radicle home was \
             started with before. Refusing to start: the storage at {} belongs \
             to a different identity, and serving it as this one would publish \
             refs nobody can verify.",
            home.path().display()
        )),
        Some(_) => Ok(()),
        None => Fingerprint::init(home, signer)
            .map_err(|e| format!("could not record the node's key fingerprint: {e}")),
    }
}

/// Stop the node this process started.
///
/// -> `{"stopped":true}` or `{"stopped":false,"reason":"…"}` when none was
/// running, or `{"error":"…"}` when one was running and did not stop cleanly.
///
/// "Nothing was running" is an answer rather than an error, for the same reason
/// `can_write` reports `canWrite:false`: a caller stopping a node that is
/// already stopped has got what it asked for, and making that a failure means
/// every shutdown path has to special-case it.
pub fn stop() -> String {
    match stop_inner() {
        Ok(Some(())) => json!({ "stopped": true }).to_string(),
        Ok(None) => json!({
            "stopped": false,
            "reason": "no node was running in this process",
        })
        .to_string(),
        Err(e) => crate::local::error(e),
    }
}

/// The stop itself. `Ok(None)` means there was nothing to stop.
///
/// The slot is cleared and the lock released BEFORE the shutdown runs. Holding
/// it across `Node::shut_down` would block `status` — the call a UI polls while
/// watching a node stop — for up to `STOP_TIMEOUT`, which is precisely when a UI
/// most needs to answer. Taking the node out first is also what makes the
/// shutdown unable to race a second `stop`: whoever wins the `take()` owns it,
/// and the loser sees an empty slot and says so.
fn stop_inner() -> Result<Option<()>, String> {
    let Some(node) = locked().take() else {
        return Ok(None);
    };
    node.shut_down().map(Some)
}

/// What this process's node is doing.
///
/// -> `{"running":bool,"home":"…","socket":"…","serving":bool[,"reason":"…"]}`
///
/// **`running` and `serving` are different questions and both are reported.**
/// `running` is our own bookkeeping — a node was started here and its thread has
/// not finished. `serving` is a live probe of the control socket, and it is the
/// one that can tell a working node from a thread whose reactor panicked.
///
/// They agree in every ordinary state, and the two moments they disagree are
/// exactly the interesting ones: during the first fraction of a second after
/// `start` (running, not yet serving), and after an internal panic (running,
/// never serving again). Collapsing them into one boolean would make the second
/// invisible, which is the failure mode the module docs single out.
pub fn status() -> String {
    // Everything needed is copied out and the lock RELEASED before the socket is
    // probed. That ordering is deliberate: this is the call a UI polls, and
    // holding the process's one node lock across any I/O means a slow or wedged
    // probe blocks `start` and `stop` too. The values copied are a snapshot, but
    // a status reply is a snapshot by nature — it describes the moment it was
    // asked, and a caller that needs a later answer asks again.
    let (home, socket, running) = {
        let guard = locked();
        let Some(node) = guard.as_ref() else {
            return json!({
                "running": false,
                "home": "",
                "socket": "",
                "serving": false,
                "reason": "no node has been started in this process",
            })
            .to_string();
        };
        (
            node.home.clone(),
            node.socket.clone(),
            node.thread.as_ref().is_some_and(|t| !t.is_finished()),
        )
    };

    let serving = socket_answers(&socket);

    // Named only when the two disagree, because that is the state a user cannot
    // otherwise account for: everything reads normal and nothing reaches the
    // network.
    let reason = if running && !serving {
        "the node thread is alive but its control socket is not answering — it \
         may still be starting, or it may have failed internally"
    } else if !running && serving {
        // Another node — a hand-run `rad` daemon — is on this socket. Worth
        // naming rather than reporting as our own node running.
        "this process's node has stopped, but something else is answering on \
         its control socket"
    } else if !running {
        "the node thread has finished"
    } else {
        ""
    };

    json!({
        "running": running,
        "home": home,
        "socket": socket,
        "serving": serving,
        "reason": reason,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Only the checks that start no node live here. Everything that stands up a
    // real runtime is in tests/node_lifecycle.rs, where a scratch home and a
    // short socket path can be arranged — and where the socket length matters,
    // since this crate's own directory is deep enough to overshoot the cap.

    #[test]
    fn starting_without_a_home_is_refused_rather_than_resolved_from_the_environment() {
        // The C++ side owns home resolution. Guessing one here is how Embedded
        // would come to run against the user's own ~/.radicle.
        let v: serde_json::Value = serde_json::from_str(&start("", "/run/x.sock", "")).unwrap();
        assert!(v["error"].as_str().unwrap().contains("no Radicle home"));
    }

    #[test]
    fn starting_without_a_socket_is_refused() {
        let v: serde_json::Value = serde_json::from_str(&start("/some/home", "", "")).unwrap();
        assert!(v["error"].as_str().unwrap().contains("no control socket"));
    }

    #[test]
    fn an_over_long_socket_names_the_path_its_length_and_the_limit() {
        // The kernel's own error names none of the three, which is exactly what
        // made this expensive to diagnose in Phase 0. Asserting on all three
        // means a message that regresses to "path too long" fails here.
        let long = format!("/tmp/{}.sock", "x".repeat(120));
        let v: serde_json::Value = serde_json::from_str(&start("/some/home", &long, "")).unwrap();
        let msg = v["error"].as_str().unwrap();
        assert!(msg.contains(&long), "the message must name the path");
        assert!(
            msg.contains(&long.len().to_string()),
            "the message must name the actual length"
        );
        assert!(
            msg.contains(&(SUN_PATH_MAX - 1).to_string()),
            "the message must name the limit"
        );
    }

    #[test]
    fn status_with_no_node_reports_not_running_rather_than_an_error() {
        // "Nothing is running" is an answer to the question asked. Reporting it
        // as an error would make every UI poll look like a failure.
        let v: serde_json::Value = serde_json::from_str(&status()).unwrap();
        assert_eq!(v["running"], json!(false));
        assert_eq!(v["serving"], json!(false));
        assert!(v["reason"].as_str().unwrap().contains("no node"));
    }
}
