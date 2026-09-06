//! Which control socket a write's announce step talks to.
//!
//! This is a narrow file for one bug with an outsized consequence. `announce()`
//! is what tells the local node that a COB's refs moved; if it opens the wrong
//! socket, the write still lands in git storage and the module still reports
//! success, so the failure is completely silent — the comment is saved, and
//! nobody on the network ever hears about it.
//!
//! The socket path is therefore not an implementation detail. It has to honour
//! the same `RAD_SOCKET` the rest of the module honours, because Phase 0
//! established that the socket **cannot** live under the Radicle home in
//! Basecamp's layout: a per-profile data dir blows the 108-byte `sun_path` cap
//! before a socket name is even appended. A node started with a relocated
//! socket is the normal case here, not an exotic one.

use radicle_local_ffi::cobwrite;

#[test]
fn the_socket_follows_rad_socket_rather_than_the_home() {
    // The bug this pins: `announce()` used to hardcode `<home>/node/control.sock`,
    // ignoring RAD_SOCKET entirely. Against a node whose socket was relocated —
    // which is every node this module will start, given the sun_path cap — the
    // announce silently went to a path with nothing listening.
    let chosen = cobwrite::control_socket_path("/some/home", Some("/run/user/1000/rad.sock"));
    assert_eq!(chosen, std::path::PathBuf::from("/run/user/1000/rad.sock"));
}

#[test]
fn without_rad_socket_the_socket_falls_back_under_the_home() {
    // The fallback must stay: a hand-run `rad` node puts its socket here, and
    // Attach mode has to keep finding it.
    let chosen = cobwrite::control_socket_path("/some/home", None);
    assert_eq!(
        chosen,
        std::path::PathBuf::from("/some/home/node/control.sock")
    );
}

#[test]
fn two_homes_yield_two_sockets_when_rad_socket_is_unset() {
    // Input-dependent on purpose. A resolver that returned a constant would
    // satisfy either test above on its own; this one fails against any
    // implementation that ignores the home it was handed.
    let a = cobwrite::control_socket_path("/home/a", None);
    let b = cobwrite::control_socket_path("/home/b", None);
    assert_ne!(a, b);
    assert!(a.starts_with("/home/a"));
    assert!(b.starts_with("/home/b"));
}

#[test]
fn the_socket_the_caller_resolved_is_the_socket_used_even_when_it_is_not_under_the_home() {
    // The bug the *first* fix left behind. Honouring `RAD_SOCKET` from the
    // environment is not enough, because the environment is not where this
    // module's socket choice lives: `LocalStore::resolveSocket` prefers
    // `$XDG_RUNTIME_DIR/radicle-<profile>.sock`, and also honours the module's
    // own `radSocket` setting — neither of which is exported anywhere.
    //
    // So on any machine with a runtime dir and no RAD_SOCKET set, the read path
    // probed `$XDG_RUNTIME_DIR/radicle.sock` while a write's announce went to
    // `<home>/node/control.sock`. They disagreed BY DEFAULT, and the
    // disagreement was invisible for the reason this file opens with: an
    // unannounced write is legitimately not an error.
    //
    // The fix is that the resolved socket arrives as a parameter — the way the
    // home already does — so exactly one place decides it. This asserts the
    // path handed in wins over the home-derived default, which is what a
    // resolver that had gone back to reading the environment would fail.
    let chosen = cobwrite::control_socket_path(
        "/home/alice/.radicle",
        Some("/run/user/1000/radicle-alice.sock"),
    );
    assert_eq!(
        chosen,
        std::path::PathBuf::from("/run/user/1000/radicle-alice.sock"),
        "the caller's resolved socket must win over anything derived from the home"
    );
}

#[test]
fn two_callers_with_the_same_home_and_different_sockets_get_different_sockets() {
    // Input-dependent on the parameter that was previously ignored. Before the
    // socket was threaded through, `announce` derived it from the home alone,
    // so these two would have been identical — which is exactly the shape of
    // the bug: one home, one socket, no matter what the module had resolved.
    let a = cobwrite::control_socket_path("/home/alice/.radicle", Some("/run/user/1000/a.sock"));
    let b = cobwrite::control_socket_path("/home/alice/.radicle", Some("/run/user/1000/b.sock"));
    assert_ne!(a, b);
}

#[test]
fn an_empty_rad_socket_is_treated_as_unset_rather_than_as_an_empty_path() {
    // An exported-but-empty RAD_SOCKET is ordinary shell behaviour. Treating it
    // as a real path would produce an empty socket path, which fails to connect
    // with a message naming nothing at all.
    let chosen = cobwrite::control_socket_path("/some/home", Some(""));
    assert_eq!(
        chosen,
        std::path::PathBuf::from("/some/home/node/control.sock")
    );
}
