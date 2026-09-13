//! A panic inside a read must not unwind across the `extern "C"` boundary.
//!
//! `lib.rs`'s `guarded()` exists for this, and its doc comment is explicit that
//! it is a SOUNDNESS guard rather than error handling: a Rust panic unwinding
//! through an `extern "C"` frame is undefined behaviour — the process may
//! abort, or corrupt itself quietly.
//!
//! It was written and then never wired in. Every `radicle_local_*` function
//! called `to_c_string(...)` directly, so nothing was guarded, and the only
//! symptom was a dead-code warning — which `cargo clippy -- -D warnings` in CI
//! turned into a build failure, and which is how it was noticed at all.
//!
//! These tests pin the wiring rather than the guard's internals. `guarded()`
//! could be unit-tested against a closure that panics, but that would prove
//! only that `catch_unwind` works; what actually broke here was the *call
//! sites*, so the assertions go through the real `extern "C"` entry points.
//!
//! Why these inputs panic: `read_str` turns a NULL pointer into "", and
//! `open_storage("")` returns `Err("no Radicle home given")` rather than
//! panicking — so a NULL home is a clean error, not a panic, and proves
//! nothing. The panic that IS reachable comes from `git2`/`radicle` internals
//! on a malformed path, so these drive the boundary with the pathological
//! inputs a C caller can actually produce and assert the process survives and
//! returns parseable JSON every time.
//!
//! If a future change removes `guarded()` from a call site, the panic it was
//! catching aborts the whole test binary — the failure is loud and immediate,
//! which is the point.

use std::ffi::{CStr, CString};

/// Call one of the `extern "C"` entry points and read its reply back as a
/// Rust `String`, freeing the pointer the way the C++ side does.
fn call<F>(f: F) -> String
where
    F: FnOnce() -> *mut std::os::raw::c_char,
{
    let raw = f();
    assert!(!raw.is_null(), "the FFI boundary must never return NULL");
    let out = unsafe { CStr::from_ptr(raw) }
        .to_string_lossy()
        .into_owned();
    unsafe { radicle_local_ffi::radicle_free_string(raw) };
    out
}

fn c(s: &str) -> CString {
    CString::new(s).expect("no NUL in test input")
}

/// Every reply must be parseable JSON carrying an `error` key — never a
/// truncated string, never a crash.
fn assert_is_error_json(label: &str, json: &str) {
    let v: serde_json::Value = serde_json::from_str(json)
        .unwrap_or_else(|e| panic!("{label}: reply was not JSON: {e}\n{json}"));
    assert!(
        v.get("error").and_then(|e| e.as_str()).is_some(),
        "{label}: expected an error object, got {json}"
    );
}

#[test]
fn a_null_home_is_a_clean_error_across_the_boundary() {
    let rid = c("rad:z2G42jiTsL6fXYCn9y4bbJBG7QqKn");
    let out = call(|| unsafe {
        radicle_local_ffi::radicle_local_get_repo(std::ptr::null(), rid.as_ptr())
    });
    assert_is_error_json("get_repo(NULL home)", &out);
}

/// The inputs most likely to reach a panic in `git2`/`radicle` internals: a
/// home that exists but is not a profile, paths with NUL-adjacent oddities,
/// and absurd pagination. None may take the process down.
#[test]
fn pathological_inputs_return_json_rather_than_unwinding() {
    let home = c("/nonexistent/definitely/not/a/radicle/home");
    let rid = c("rad:z2G42jiTsL6fXYCn9y4bbJBG7QqKn");
    let junk_rid = c("not-a-rid-at-all");
    let sha = c("../../../etc/passwd");
    let path = c("../../..");
    let status = c("\u{fffd}");

    assert_is_error_json(
        "get_repo",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_get_repo(home.as_ptr(), junk_rid.as_ptr())
        }),
    );

    assert_is_error_json(
        "get_tree",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_get_tree(
                home.as_ptr(),
                rid.as_ptr(),
                sha.as_ptr(),
                path.as_ptr(),
            )
        }),
    );

    assert_is_error_json(
        "get_blob",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_get_blob(
                home.as_ptr(),
                rid.as_ptr(),
                sha.as_ptr(),
                path.as_ptr(),
            )
        }),
    );

    assert_is_error_json(
        "get_readme",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_get_readme(home.as_ptr(), rid.as_ptr(), sha.as_ptr())
        }),
    );

    assert_is_error_json(
        "get_commit",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_get_commit(home.as_ptr(), rid.as_ptr(), sha.as_ptr())
        }),
    );

    assert_is_error_json(
        "get_issue",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_get_issue(
                home.as_ptr(),
                rid.as_ptr(),
                junk_rid.as_ptr(),
            )
        }),
    );

    assert_is_error_json(
        "get_patch",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_get_patch(
                home.as_ptr(),
                rid.as_ptr(),
                junk_rid.as_ptr(),
            )
        }),
    );

    // The paginated entry points, with the arithmetic-overflow inputs
    // `list_repos`' own comment calls out: `page * per_page` on two large
    // i64s panics in a debug build, and a panic here would be UB rather than
    // merely a bad answer. Saturating arithmetic is the primary defence;
    // `guarded` is the backstop, and both are exercised here.
    for (label, out) in [
        (
            "list_repos",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_list_repos(
                    home.as_ptr(),
                    status.as_ptr(),
                    i64::MAX,
                    i64::MAX,
                )
            }),
        ),
        (
            "list_commits",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_list_commits(
                    home.as_ptr(),
                    rid.as_ptr(),
                    sha.as_ptr(),
                    i64::MAX,
                    i64::MAX,
                )
            }),
        ),
        (
            "list_issues",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_list_issues(
                    home.as_ptr(),
                    rid.as_ptr(),
                    status.as_ptr(),
                    i64::MIN,
                    i64::MIN,
                )
            }),
        ),
        (
            "list_patches",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_list_patches(
                    home.as_ptr(),
                    rid.as_ptr(),
                    status.as_ptr(),
                    i64::MIN,
                    i64::MIN,
                )
            }),
        ),
    ] {
        assert_is_error_json(label, &out);
    }
}

/// The write entry points must be guarded exactly as the reads are.
///
/// A write is the one place where an unwind could leave more than a dropped
/// `git2` handle behind — it is mid-way through appending to a COB's operation
/// DAG — so a new `extern "C"` function that forgot `guarded` would be the
/// worst instance of the bug this file exists for, not a lesser one.
///
/// `can_write` is asserted separately because it deliberately does NOT return
/// an error object when the answer is no: `{"canWrite":false,"reason":...}` is
/// a successful answer to the question. The property under test here is only
/// that the boundary survives and returns parseable JSON.
#[test]
fn the_write_entry_points_are_guarded_too() {
    let home = c("/nonexistent/definitely/not/a/radicle/home");
    let rid = c("rad:z2G42jiTsL6fXYCn9y4bbJBG7QqKn");
    let junk = c("not-an-oid-at-all");
    let traversal = c("../../../etc/passwd");
    let body = c("hello");
    // The socket argument gets the same pathological treatment as every other
    // string here. It reaches `Node::new` and then a connect(2), so a value
    // over the 108-byte sun_path cap, or one shaped like a traversal, must come
    // back as JSON rather than as a panic crossing the ABI.
    let overlong_socket = c(&"/run/user/1000/".to_string().repeat(20));

    assert_is_error_json(
        "comment_on_issue(junk id)",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_comment_on_issue(
                home.as_ptr(),
                traversal.as_ptr(),
                rid.as_ptr(),
                junk.as_ptr(),
                body.as_ptr(),
            )
        }),
    );

    assert_is_error_json(
        "comment_on_issue(traversal-shaped id)",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_comment_on_issue(
                home.as_ptr(),
                overlong_socket.as_ptr(),
                traversal.as_ptr(),
                traversal.as_ptr(),
                body.as_ptr(),
            )
        }),
    );

    // Every string argument NULL at once — the shape `read_str` maps to "",
    // and the one a C caller produces most easily by mistake.
    assert_is_error_json(
        "comment_on_issue(all NULL)",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_comment_on_issue(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
            )
        }),
    );

    assert_is_error_json(
        "create_issue(bad home)",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_create_issue(
                home.as_ptr(),
                overlong_socket.as_ptr(),
                rid.as_ptr(),
                body.as_ptr(),
                body.as_ptr(),
            )
        }),
    );

    // A title carrying the characters `Title::new` rejects, alongside a
    // traversal-shaped rid: the validation runs before storage is opened, so
    // this exercises the early-return path across the boundary.
    let multiline = c("two\nlines");
    assert_is_error_json(
        "create_issue(multi-line title)",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_create_issue(
                home.as_ptr(),
                traversal.as_ptr(),
                traversal.as_ptr(),
                multiline.as_ptr(),
                body.as_ptr(),
            )
        }),
    );

    assert_is_error_json(
        "create_issue(all NULL)",
        &call(|| unsafe {
            radicle_local_ffi::radicle_local_create_issue(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
            )
        }),
    );

    for (label, out) in [
        (
            "can_write(bad home)",
            call(|| unsafe { radicle_local_ffi::radicle_local_can_write(home.as_ptr()) }),
        ),
        (
            "can_write(NULL home)",
            call(|| unsafe { radicle_local_ffi::radicle_local_can_write(std::ptr::null()) }),
        ),
    ] {
        let v: serde_json::Value = serde_json::from_str(&out)
            .unwrap_or_else(|e| panic!("{label}: reply was not JSON: {e}\n{out}"));
        assert_eq!(v["canWrite"], false, "{label}: got {out}");
        assert!(
            v["reason"].as_str().is_some(),
            "{label}: a refusal must carry a reason: {out}"
        );
    }
}

/// The environment entry points are guarded exactly like the rest.
///
/// These are the newest `extern "C"` functions in the crate, which is precisely
/// why they are here: the bug this file exists for was an entry point that
/// forgot `guarded`, and the most likely place for that to happen again is
/// whatever was added last. Two of them additionally SPAWN A PROCESS, so they
/// reach failure modes the read paths do not — a path that is a directory, a
/// binary that cannot be executed — and none of those may cross the boundary as
/// a panic.
///
/// Like `can_write`, `git_probe` answers a negative with `{"found":false,...}`
/// rather than an error object, so the property asserted is parseable JSON in
/// the documented shape rather than an `error` key.
#[test]
fn the_environment_entry_points_are_guarded_too() {
    let missing = c("/nonexistent/definitely/not/a/git");
    let a_directory = c("/");
    let traversal = c("../../../etc/passwd");
    let home = c("/nonexistent/definitely/not/a/radicle/home");

    for (label, out) in [
        (
            "git_probe(missing)",
            call(|| unsafe { radicle_local_ffi::radicle_git_probe(missing.as_ptr()) }),
        ),
        (
            // A path that exists but is a directory, not an executable: the
            // spawn fails rather than the stat.
            "git_probe(a directory)",
            call(|| unsafe { radicle_local_ffi::radicle_git_probe(a_directory.as_ptr()) }),
        ),
        (
            "git_probe(traversal-shaped)",
            call(|| unsafe { radicle_local_ffi::radicle_git_probe(traversal.as_ptr()) }),
        ),
        (
            "git_probe(NULL)",
            call(|| unsafe { radicle_local_ffi::radicle_git_probe(std::ptr::null()) }),
        ),
    ] {
        let v: serde_json::Value = serde_json::from_str(&out)
            .unwrap_or_else(|e| panic!("{label}: reply was not JSON: {e}\n{out}"));
        assert!(
            v["found"].is_boolean(),
            "{label}: must answer the question asked: {out}"
        );
    }

    // node_id answers `{"nodeId":"","reason":…}` for anything it cannot read,
    // so the assertion is on the shape rather than on an error key.
    for (label, out) in [
        (
            "node_id(bad home)",
            call(|| unsafe { radicle_local_ffi::radicle_local_node_id(home.as_ptr()) }),
        ),
        (
            "node_id(NULL home)",
            call(|| unsafe { radicle_local_ffi::radicle_local_node_id(std::ptr::null()) }),
        ),
        (
            "node_id(traversal-shaped home)",
            call(|| unsafe { radicle_local_ffi::radicle_local_node_id(traversal.as_ptr()) }),
        ),
    ] {
        let v: serde_json::Value = serde_json::from_str(&out)
            .unwrap_or_else(|e| panic!("{label}: reply was not JSON: {e}\n{out}"));
        assert!(
            v["nodeId"].is_string(),
            "{label}: nodeId must always be present, even when empty: {out}"
        );
    }

    // apply_git_path mutates PATH on success, so it is driven only with inputs
    // that must FAIL — a test that permanently reshaped this process's PATH
    // would corrupt every later test in the binary, including the ones that
    // resolve git for real.
    assert_is_error_json(
        "apply_git_path(missing)",
        &call(|| unsafe { radicle_local_ffi::radicle_apply_git_path(missing.as_ptr()) }),
    );
    assert_is_error_json(
        "apply_git_path(a directory)",
        &call(|| unsafe { radicle_local_ffi::radicle_apply_git_path(a_directory.as_ptr()) }),
    );
}

/// The identity entry points are guarded too.
///
/// This file advertises itself as the inventory of every `extern "C"` function,
/// which is only useful if it actually is one — an entry point outside its watch
/// is exactly the gap it exists to close, and these two were added after it was
/// written. They are guarded in `lib.rs`; this is what keeps that true.
///
/// `init_profile` is the sharpest case in the crate. A panic mid-keygen would
/// cross the ABI having already written a secret key to disk, so an unwind here
/// is not merely UB, it is UB with partial key material left behind.
///
/// Every input below must FAIL, deliberately: a test that successfully created
/// an identity would write a permanent key somewhere on the developer's disk,
/// and `tests/profile_init.rs` is the layer with scratch homes and cleanup. The
/// success path is covered there.
#[test]
fn the_identity_entry_points_are_guarded_too() {
    let unwritable = c("/proc/nonexistent-cannot-create/home");
    let relative = c("relative/not/absolute");
    let traversal = c("../../../etc/passwd");
    let alias = c("tester");
    let bad_alias = c("has spaces");
    let pass = c("");

    for (label, out) in [
        (
            "init_profile(unwritable home)",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_init_profile(
                    unwritable.as_ptr(),
                    alias.as_ptr(),
                    pass.as_ptr(),
                )
            }),
        ),
        (
            "init_profile(relative home)",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_init_profile(
                    relative.as_ptr(),
                    alias.as_ptr(),
                    pass.as_ptr(),
                )
            }),
        ),
        (
            "init_profile(traversal-shaped home)",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_init_profile(
                    traversal.as_ptr(),
                    alias.as_ptr(),
                    pass.as_ptr(),
                )
            }),
        ),
        (
            "init_profile(bad alias)",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_init_profile(
                    unwritable.as_ptr(),
                    bad_alias.as_ptr(),
                    pass.as_ptr(),
                )
            }),
        ),
        (
            // All NULL — the shape `read_str` maps to "", and the one a C
            // caller produces most easily by mistake.
            "init_profile(all NULL)",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_init_profile(
                    std::ptr::null(),
                    std::ptr::null(),
                    std::ptr::null(),
                )
            }),
        ),
    ] {
        assert_is_error_json(label, &out);
    }

    // profile_exists answers `{"exists":bool}` rather than an error object —
    // "there is nothing there" is an answer to the question, not a failure to
    // answer it — so the assertion is on the documented shape.
    for (label, out) in [
        (
            "profile_exists(unwritable home)",
            call(|| unsafe {
                radicle_local_ffi::radicle_local_profile_exists(unwritable.as_ptr())
            }),
        ),
        (
            "profile_exists(traversal-shaped home)",
            call(|| unsafe { radicle_local_ffi::radicle_local_profile_exists(traversal.as_ptr()) }),
        ),
        (
            "profile_exists(NULL home)",
            call(|| unsafe { radicle_local_ffi::radicle_local_profile_exists(std::ptr::null()) }),
        ),
    ] {
        let v: serde_json::Value = serde_json::from_str(&out)
            .unwrap_or_else(|e| panic!("{label}: reply was not JSON: {e}\n{out}"));
        assert!(
            v["exists"].is_boolean(),
            "{label}: must answer the question asked: {out}"
        );
    }
}

/// The node entry points are guarded too.
///
/// These are the newest `extern "C"` functions in the crate, and this file only
/// earns its claim to be an inventory of every one of them if it keeps up. The
/// bug it exists for was an entry point that forgot `guarded`, and the most
/// likely place for that to recur is whatever was added last.
///
/// **The guard's reach is narrower here than anywhere else in this file, and
/// that is worth stating rather than leaving implied.** `guarded` catches a
/// panic in the `radicle_node_*` frame; it has no reach into the reactor, worker
/// pool or control listener that a *started* node spawns. So what this test
/// covers is the boundary, not the node — which is the whole extent of what
/// `guarded` was ever able to promise, and `node.rs`'s module docs say so.
///
/// Every input below must FAIL to start a node. That is deliberate for the same
/// reason `the_identity_entry_points_are_guarded_too` never creates an identity:
/// a successful start here would leave a real node running in the test binary,
/// bound to a real socket, for every later test to trip over.
#[test]
fn the_node_entry_points_are_guarded_too() {
    let missing_home = c("/nonexistent/definitely/not/a/radicle/home");
    let relative = c("relative/not/absolute");
    let traversal = c("../../../etc/passwd");
    let socket = c("/nonexistent/definitely/not/a/socket/dir/x.sock");
    // Past the 108-byte sun_path cap, which must be reported rather than
    // reaching `bind` as an OS error naming neither the path nor the limit.
    let long_socket = c(&format!("/tmp/{}.sock", "x".repeat(120)));
    let pass = c("");

    for (label, out) in [
        (
            "node_start(missing home)",
            call(|| unsafe {
                radicle_local_ffi::radicle_node_start(
                    missing_home.as_ptr(),
                    socket.as_ptr(),
                    pass.as_ptr(),
                )
            }),
        ),
        (
            "node_start(relative home)",
            call(|| unsafe {
                radicle_local_ffi::radicle_node_start(
                    relative.as_ptr(),
                    socket.as_ptr(),
                    pass.as_ptr(),
                )
            }),
        ),
        (
            "node_start(traversal-shaped home)",
            call(|| unsafe {
                radicle_local_ffi::radicle_node_start(
                    traversal.as_ptr(),
                    socket.as_ptr(),
                    pass.as_ptr(),
                )
            }),
        ),
        (
            "node_start(over-long socket)",
            call(|| unsafe {
                radicle_local_ffi::radicle_node_start(
                    missing_home.as_ptr(),
                    long_socket.as_ptr(),
                    pass.as_ptr(),
                )
            }),
        ),
        (
            // All NULL — the shape `read_str` maps to "", and the one a C caller
            // produces most easily by mistake.
            "node_start(all NULL)",
            call(|| unsafe {
                radicle_local_ffi::radicle_node_start(
                    std::ptr::null(),
                    std::ptr::null(),
                    std::ptr::null(),
                )
            }),
        ),
    ] {
        assert_is_error_json(label, &out);
    }

    // `stop` and `status` answer with a documented shape rather than an error
    // object when nothing is running — "no node" is an answer to the question,
    // not a failure to answer it — so the property asserted is that shape.
    let stopped = call(|| radicle_local_ffi::radicle_node_stop());
    let v: serde_json::Value = serde_json::from_str(&stopped)
        .unwrap_or_else(|e| panic!("node_stop: reply was not JSON: {e}\n{stopped}"));
    assert!(
        v["stopped"].is_boolean(),
        "node_stop must answer the question asked: {stopped}"
    );

    let status = call(|| radicle_local_ffi::radicle_node_status());
    let v: serde_json::Value = serde_json::from_str(&status)
        .unwrap_or_else(|e| panic!("node_status: reply was not JSON: {e}\n{status}"));
    assert!(
        v["running"].is_boolean() && v["serving"].is_boolean(),
        "node_status must always report both halves of the state: {status}"
    );
}

/// `radicle_free_string(NULL)` is a documented no-op. Worth pinning because
/// the C++ `take()` helper calls it on every reply, and a crash here would be
/// a crash on the happy path.
#[test]
fn freeing_null_is_a_noop() {
    unsafe { radicle_local_ffi::radicle_free_string(std::ptr::null_mut()) };
}
