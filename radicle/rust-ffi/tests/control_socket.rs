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
