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

/// `radicle_free_string(NULL)` is a documented no-op. Worth pinning because
/// the C++ `take()` helper calls it on every reply, and a crash here would be
/// a crash on the happy path.
#[test]
fn freeing_null_is_a_noop() {
    unsafe { radicle_local_ffi::radicle_free_string(std::ptr::null_mut()) };
}
