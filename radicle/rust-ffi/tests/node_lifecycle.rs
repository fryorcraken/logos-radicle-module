//! Starting and stopping a real node, in this process.
//!
//! Phase 0 deliberately did **not** write this file. Its probe was an *example*
//! rather than a test, on the argument that standing up a real runtime — real
//! control socket, real SQLite, a real thread pool — was Phase 2 work and that a
//! flaky check here would say nothing about the `local*` read path
//! (`docs/M3-phase0-findings.md`, "What the branch contains").
//!
//! That argument has expired, because the node is now the feature. An uncovered
//! `start`/`stop` is a change CI has not checked, and the specific things this
//! step got wrong are things only a running node can show: that "started" means
//! the socket answers rather than that a thread was spawned, that a second start
//! is refused, that stopping something already stopped is an answer rather than
//! an error, and — the question Phase 0 left explicitly open — whether an
//! encrypted profile can start without its passphrase.
//!
//! ## The socket path is why these tests look the way they do
//!
//! A Unix socket path is capped at 108 bytes, and this crate's own `tmp/` is
//! nowhere near short enough under a git worktree: `docs/M3-phase0-findings.md`
//! §6 measured the probe's deliberately absurd `tmp/n/h` at **114 bytes** and
//! failing. So the fixture's scratch home is fine for a *home* — that has no cap
//! — but the socket has to live somewhere short, which is exactly the split
//! `resolveSocket()` makes on the C++ side for the same reason.
//!
//! `short_socket()` below therefore puts the socket under `$XDG_RUNTIME_DIR`
//! (else `/tmp`), and **skips loudly** rather than failing if even that
//! overshoots. A skip that says why is honest; a test that cannot run and
//! reports green is the false-green shape this repo has been bitten by twice.

mod fixture;

use std::path::PathBuf;

use radicle::crypto::Seed;
use radicle::node::Alias;
use radicle::profile::{Home, Profile};
use radicle_local_ffi::node;

use fixture::{init_profile, parse, scratch_dir};

/// A socket path short enough to bind, in a directory that is not the crate's.
///
/// Returns `None` when even the shortest available base overshoots, so a caller
/// can skip with a message rather than fail with the kernel's, which names
/// neither the path nor the limit.
fn short_socket(name: &str) -> Option<PathBuf> {
    let base = std::env::var("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"));
    // Unique per test binary run, because the whole suite shares one process and
    // two tests binding one path would collide in a way that looks like a bug in
    // the code under test.
    let path = base.join(format!("rad-t-{}-{}.sock", std::process::id(), name));
    // Stale socket files outlive the process that bound them, and `bind` fails
    // on an existing path. Removing is safe: the name embeds this process's pid.
    let _ = std::fs::remove_file(&path);
    if path.as_os_str().len() + 1 > 108 {
        return None;
    }
    Some(path)
}

/// The one node this process may run — held for the whole of any test that
/// starts one.
///
/// **This is not test-harness noise; it is the design under test.** `node.rs`
/// keeps a single `Mutex<Option<Node>>` because two nodes writing one git
/// storage is the corruption hazard the isolation model exists to prevent. Every
/// test here runs in one process, so without this two of them race for that one
/// slot and the loser is refused with "a node is already running" — which is the
/// code being *correct*, reported as a test failure.
///
/// Serialising here rather than by telling CI to pass `--test-threads=1` is
/// deliberate. That flag is invisible at the point it matters, applies to the
/// whole suite rather than to the eight tests that need it, and is one edit away
/// from being dropped by someone who has no way to know it was load-bearing.
static NODE_SLOT: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Run `f` with a short socket and exclusive use of the process's node slot, or
/// skip with a message naming why.
///
/// The skip prints rather than silently returning, for the reason the module
/// docs give: this repo has shipped a suite that skipped its way to green twice
/// (the `SMOKE_*`-gated Rust tests, and the Qt5 `qmltestrunner`), and both times
/// the tell would have been output nobody was printing.
fn with_socket(name: &str, f: impl FnOnce(&str)) {
    // Recovered rather than unwrapped: a test that panics while holding this
    // poisons it, and turning one real failure into seven misleading ones buries
    // the report that matters.
    let _slot = NODE_SLOT.lock().unwrap_or_else(|e| e.into_inner());

    // Whatever a previous test left behind, so a leaked node is not inherited as
    // this test's starting state.
    stop_and_forget();

    match short_socket(name) {
        Some(path) => f(&path.display().to_string()),
        None => eprintln!(
            "SKIPPED {name}: no directory short enough for a 108-byte socket path. \
             This is the real constraint from docs/M3-phase0-findings.md §6, not a \
             quirk of the test."
        ),
    }

    // And again on the way out, so a test that asserted its way to a panic does
    // not strand a running node for the next one.
    stop_and_forget();
}

/// Stop whatever is running, so one test's node cannot leak into the next.
///
/// `with_socket` calls this on both sides of every test, so a test body does not
/// need it merely for isolation. Bodies still call it explicitly before removing
/// their scratch directory — including where a `Fixture`'s `Drop` does the
/// removing — because that is a different requirement: a running node holds its
/// storage tree open, and pulling the directory out from under it is a race
/// rather than a cleanup.
fn stop_and_forget() {
    let _ = node::stop();
}

#[test]
fn a_node_starts_answers_its_socket_and_stops() {
    with_socket("basic", |socket| {
        let fx = init_profile("node-basic");

        let reply = parse(&node::start(&fx.home(), socket, ""));
        assert_eq!(
            reply["started"],
            serde_json::json!(true),
            "the node did not start: {reply}"
        );

        // The identity that is serving, reported so a caller never has to guess
        // which node it just started — the whole point of Embedded being a
        // separate DID.
        assert!(
            reply["nodeId"].as_str().unwrap().starts_with("did:key:"),
            "a started node must report the identity it is serving as"
        );

        // Outbound-only. Asserted rather than assumed, because it is a real
        // limitation a UI has to state: peers cannot fetch from this node.
        assert_eq!(
            reply["listening"],
            serde_json::json!([]),
            "the embedded node must bind no port"
        );

        // A started node reports both halves of its state, and the socket it is
        // on. Note this pair does NOT prove that `start` waits for the socket:
        // deleting the wait entirely leaves these green, because `Runtime::init`
        // binds the socket before it returns (`runtime.rs:249`), so it is
        // already answering by the time this line runs. Verified by mutation,
        // and recorded so nobody reads these as covering the wait — see
        // `a_node_that_cannot_bind_reports_failure_and_registers_nothing`.
        let status = parse(&node::status());
        assert_eq!(status["running"], serde_json::json!(true));
        assert_eq!(status["serving"], serde_json::json!(true));
        assert_eq!(status["socket"], serde_json::json!(socket));

        let stopped = parse(&node::stop());
        assert_eq!(
            stopped["stopped"],
            serde_json::json!(true),
            "the node did not stop cleanly: {stopped}"
        );

        let after = parse(&node::status());
        assert_eq!(after["running"], serde_json::json!(false));
        assert_eq!(after["serving"], serde_json::json!(false));
    });
}

#[test]
fn a_node_that_cannot_bind_reports_failure_and_registers_nothing() {
    // A start that fails must leave no node behind, or the module is
    // permanently unstartable after one bad socket: the next `start` would be
    // refused by a corpse and `status` would report a node that never existed.
    // That cleanup is `start_inner`'s failure branch, and this is what covers it.
    //
    // **What this does NOT cover is the wait for the socket**, and that is worth
    // stating because it is what the test was originally written for and does
    // not do. `Runtime::init` binds the control socket itself
    // (`runtime.rs:249`), so an unbindable path fails inside `init` and returns
    // long before the wait is reached — verified by mutation: deleting the wait
    // leaves this green.
    //
    // The wait is therefore uncovered here, deliberately rather than by
    // oversight. What it guards is a node whose `init` succeeded and whose
    // *thread* then failed, which needs a runtime induced to die after binding —
    // no input to `start` produces that, and faking it would mean a seam in
    // `node.rs` that exists only for the test. The honest statement is that this
    // suite covers the failure paths `start` can be driven into from outside,
    // and that the post-init wait is reasoned rather than measured. `node.rs`'s
    // comment on the wait says the same thing, so the two cannot drift into one
    // claiming coverage the other denies.
    let _slot = NODE_SLOT.lock().unwrap_or_else(|e| e.into_inner());
    stop_and_forget();

    let fx = init_profile("node-nobind");
    let reply = parse(&node::start(
        &fx.home(),
        "/nonexistent-directory-for-a-socket/x.sock",
        "",
    ));

    assert!(
        reply["started"].is_null(),
        "a node that cannot bind its socket must not report success: {reply}"
    );
    assert!(
        reply["error"].as_str().is_some(),
        "the failure must be reported as an error: {reply}"
    );

    // And nothing is left registered, so the next start is not refused by a node
    // that never existed. This is the cleanup path in `start_inner`'s failure
    // branch; without it the module would be permanently unstartable after one
    // bad socket.
    let status = parse(&node::status());
    assert_eq!(status["running"], serde_json::json!(false));

    stop_and_forget();
}

#[test]
fn an_encrypted_profile_cannot_start_without_its_passphrase_and_can_with_it() {
    // **This is the measurement Phase 0 left as inference.** Its §7 said the
    // passphrase is "probably" needed at start, reasoning from `main.rs`'s flow
    // rather than running it — and explicitly kept the question open because the
    // probe only ever exercised an unencrypted key.
    //
    // It is written as one test in two directions on purpose. The negative half
    // alone would pass against a node that could never start at all; the
    // positive half alone would pass against one that ignored the passphrase
    // entirely. Only the pair distinguishes "the passphrase is required at
    // start" from either failure — the same input-dependence rule that
    // `two_homes_get_two_different_identities` exists for.
    with_socket("encrypted", |socket| {
        let dir = scratch_dir("node-encrypted");
        let home = Home::new(dir.join("home")).expect("could not create Radicle home");
        let profile = Profile::init(
            home,
            Alias::new("locked"),
            Some(radicle::crypto::ssh::keystore::Passphrase::from(
                "correct horse".to_string(),
            )),
            Seed::new([11u8; 32]),
        )
        .expect("could not init an encrypted profile");
        let home = profile.home().path().display().to_string();

        // Without it: refused, with a message that says the passphrase is needed
        // AT START rather than one that reads like a corrupt key file.
        let refused = parse(&node::start(&home, socket, ""));
        let msg = refused["error"]
            .as_str()
            .unwrap_or_else(|| panic!("an encrypted profile must not start unattended: {refused}"));
        assert!(
            msg.contains("START"),
            "the message must say the passphrase is needed at start, since there \
             is no later point to supply one; got: {msg}"
        );

        // Nothing was left behind by the refusal. A failed start that registers
        // a node would make the next one report "already running".
        assert_eq!(parse(&node::status())["running"], serde_json::json!(false));

        // With it: starts. This is the half that proves the refusal above is
        // about the passphrase and not about the profile being unusable.
        let started = parse(&node::start(&home, socket, "correct horse"));
        assert_eq!(
            started["started"],
            serde_json::json!(true),
            "the same profile must start once the passphrase is supplied: {started}"
        );

        stop_and_forget();
        let _ = std::fs::remove_dir_all(&dir);
    });
}

#[test]
fn a_wrong_passphrase_is_refused_and_says_so() {
    // Distinct from the case above: "no passphrase offered" and "the wrong one"
    // prompt different actions from a user, and the crate reports both as the
    // same decryption failure. Without this, a resolver that ignored the
    // passphrase argument entirely would still satisfy the negative half of the
    // test above.
    with_socket("wrongpass", |socket| {
        let dir = scratch_dir("node-wrongpass");
        let home = Home::new(dir.join("home")).expect("could not create Radicle home");
        let profile = Profile::init(
            home,
            Alias::new("locked"),
            Some(radicle::crypto::ssh::keystore::Passphrase::from(
                "correct horse".to_string(),
            )),
            Seed::new([12u8; 32]),
        )
        .expect("could not init an encrypted profile");
        let home = profile.home().path().display().to_string();

        let refused = parse(&node::start(&home, socket, "wrong horse"));
        let msg = refused["error"]
            .as_str()
            .unwrap_or_else(|| panic!("a wrong passphrase must not start a node: {refused}"));
        assert!(
            msg.contains("passphrase did not unlock"),
            "a wrong passphrase must be reported as such, not as a missing one; got: {msg}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    });
}

#[test]
fn a_second_start_is_refused_while_one_is_running() {
    // One node per process is the design, and the reason is not tidiness: two
    // nodes on one git storage is the corruption hazard the whole isolation
    // model exists to prevent. Asserted here because nothing else can — the
    // single-`Option` shape makes it true, and this is what would notice if that
    // shape were replaced by a collection.
    with_socket("second", |socket| {
        let fx = init_profile("node-second");

        let first = parse(&node::start(&fx.home(), socket, ""));
        assert_eq!(first["started"], serde_json::json!(true), "{first}");

        let second = parse(&node::start(&fx.home(), socket, ""));
        let msg = second["error"]
            .as_str()
            .unwrap_or_else(|| panic!("a second start must be refused: {second}"));
        assert!(
            msg.contains("already running"),
            "the refusal must say a node is already running; got: {msg}"
        );
        // The message names the socket, so a user can tell WHICH node is in the
        // way — there is otherwise nothing on screen that identifies it.
        assert!(
            msg.contains(socket),
            "the refusal must name the socket: {msg}"
        );

        // The refusal must not have disturbed the running node. A second start
        // that stopped the first while refusing would be far worse than one that
        // succeeded.
        let status = parse(&node::status());
        assert_eq!(status["serving"], serde_json::json!(true));

        stop_and_forget();
    });
}

#[test]
fn stopping_when_nothing_runs_is_an_answer_rather_than_an_error() {
    // The same reasoning as `can_write` reporting `canWrite:false`: a caller
    // that asked for the node to be stopped has got what it wanted. Making it an
    // error means every shutdown path has to special-case the ordinary case.
    //
    // Takes the slot like every other test here even though it starts nothing:
    // the assertion is about there being NO node, which another test's running
    // one would falsify.
    let _slot = NODE_SLOT.lock().unwrap_or_else(|e| e.into_inner());
    stop_and_forget();

    let reply = parse(&node::stop());
    assert_eq!(reply["stopped"], serde_json::json!(false));
    assert!(reply["error"].is_null(), "not running is not a failure");
    assert!(reply["reason"].as_str().unwrap().contains("no node"));
}

#[test]
fn starting_against_a_home_with_no_identity_says_so() {
    // **Two states, not one, and they need different sentences.**
    //
    // A bare directory is not a Radicle home at all — nothing has ever been
    // created there. A home with its four subdirectories but no keystore is the
    // state after the home exists and before the identity does, which is the
    // ordinary first state of Embedded rather than a misconfiguration.
    //
    // Both are covered here because the code takes two different routes to them
    // — `Home::load` refuses the first, `read_signer` the second — and a test
    // that drove only one would leave the other free to regress into an
    // unhelpful crate-level error. That is not hypothetical: this test asserted
    // only "no signing key" until `Home::load` replaced `Home::new`, at which
    // point the bare-directory case started failing earlier with a different
    // message and the assertion caught it.
    with_socket("noidentity", |socket| {
        let dir = scratch_dir("node-noidentity");

        // 1. A bare directory. `Home::load` refuses it rather than creating the
        //    tree — which `Home::new` would have done, silently leaving an empty
        //    Radicle home on disk behind a failed start.
        let bare = dir.join("bare");
        std::fs::create_dir_all(&bare).expect("could not create dir");

        let reply = parse(&node::start(&bare.display().to_string(), socket, ""));
        let msg = reply["error"]
            .as_str()
            .unwrap_or_else(|| panic!("a bare directory cannot run a node: {reply}"));
        assert!(
            msg.contains("could not open the Radicle home"),
            "the message must say the home could not be opened; got: {msg}"
        );

        // And nothing was created there. A start must never bring a home into
        // existence — that is `createEmbeddedIdentity`'s job, and only its job.
        assert!(
            !bare.join("keys").exists() && !bare.join("storage").exists(),
            "a failed start must not create a Radicle home"
        );

        // 2. A real home with no keystore: created by `Home::new`, exactly as a
        //    crashed or not-yet-run identity creation would leave it. This is
        //    the state the wizard's first screen describes.
        let empty = dir.join("empty");
        radicle::profile::Home::new(&empty).expect("could not create a Radicle home");

        let reply = parse(&node::start(&empty.display().to_string(), socket, ""));
        let msg = reply["error"]
            .as_str()
            .unwrap_or_else(|| panic!("a home with no identity cannot run a node: {reply}"));
        assert!(
            msg.contains("no signing key"),
            "the message must name the missing identity; got: {msg}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    });
}

#[test]
fn a_node_started_against_one_home_reports_that_home_and_not_another() {
    // Input-dependent on the home, which is the assertion a `status` that
    // reported a constant — or that re-read the environment instead of the home
    // it was started against — would fail. The whole identity-confusion failure
    // mode is a module reporting one home while serving another.
    with_socket("whichhome", |socket| {
        let fx = init_profile("node-whichhome");

        let started = parse(&node::start(&fx.home(), socket, ""));
        assert_eq!(started["started"], serde_json::json!(true), "{started}");
        assert_eq!(started["home"], serde_json::json!(fx.home()));

        let status = parse(&node::status());
        assert_eq!(
            status["home"],
            serde_json::json!(fx.home()),
            "status must report the home the node was actually started against"
        );

        stop_and_forget();
    });
}

#[test]
fn a_home_that_changes_its_signing_key_is_refused() {
    // The fingerprint guard, which `radicle-node`'s own `main.rs` performs and
    // its library does not — so an embedder that skipped it would silently drop
    // a protection the daemon otherwise has.
    //
    // What it catches is precisely this module's standing failure mode arriving
    // from the one direction the mode's structural guarantees do not cover: the
    // home stays put and the KEY changes underneath it, so storage built by one
    // identity would be served as another.
    with_socket("fingerprint", |socket| {
        let fx = init_profile("node-fingerprint");
        let home = fx.home();

        // First start records the fingerprint.
        let first = parse(&node::start(&home, socket, ""));
        assert_eq!(first["started"], serde_json::json!(true), "{first}");
        stop_and_forget();

        // Swap the keystore for a different identity's, leaving everything else
        // — storage, config, databases — exactly as it was.
        let other = scratch_dir("node-fingerprint-other");
        let other_home = Home::new(other.join("home")).expect("could not create Radicle home");
        Profile::init(
            other_home,
            Alias::new("impostor"),
            None,
            Seed::new([13u8; 32]),
        )
        .expect("could not init the second profile");

        let keys = PathBuf::from(&home).join("keys");
        let other_keys = other.join("home").join("keys");
        for name in ["radicle", "radicle.pub"] {
            std::fs::copy(other_keys.join(name), keys.join(name))
                .unwrap_or_else(|e| panic!("could not swap {name}: {e}"));
        }

        let refused = parse(&node::start(&home, socket, ""));
        let msg = refused["error"].as_str().unwrap_or_else(|| {
            panic!("a home whose signing key changed must not start: {refused}")
        });
        assert!(
            msg.contains("different identity"),
            "the refusal must name the consequence — storage belonging to \
             another identity — rather than a fingerprint file; got: {msg}"
        );

        stop_and_forget();
        let _ = std::fs::remove_dir_all(&other);
    });
}
