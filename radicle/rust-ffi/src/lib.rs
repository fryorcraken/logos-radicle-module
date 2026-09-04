//! Rust half of local-node reading: everything the C++ core module cannot do
//! itself, because it needs the `radicle` crate's understanding of on-disk
//! storage and Collaborative Objects.
//!
//! `local` holds the actual logic, tested directly as Rust (`cargo test`,
//! `Result<String, String>` in, no C anywhere). `ffi` is the thin
//! `extern "C"` boundary the C++ side links against — a string in, a
//! heap-owned string out, freed by `radicle_free_string`. Keeping the split
//! means the logic is testable without touching raw pointers at all.

pub mod cobs;
pub mod gitread;
pub mod local;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// Read a `const char*` argument. Empty/absent (NULL) becomes "".
///
/// # Safety
/// `ptr` must be NULL or point to a valid, NUL-terminated UTF-8 C string that
/// outlives this call.
unsafe fn read_str(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

fn to_c_string(json: String) -> *mut c_char {
    // A JSON string built by serde_json::to_string cannot itself contain a
    // NUL byte, so this only fails on a logic error, not on user input.
    CString::new(json)
        .unwrap_or_else(|_| CString::new("{\"error\":\"internal: NUL in JSON output\"}").unwrap())
        .into_raw()
}

/// Directory listing at `path` for one repo's local storage.
///
/// # Safety
/// `home`, `rid` must each be NULL or a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_get_repo(
    home: *const c_char,
    rid: *const c_char,
) -> *mut c_char {
    let home = read_str(home);
    let rid = read_str(rid);
    to_c_string(local::get_repo(&home, &rid))
}

/// Repos in local storage, paginated the same way `remoteListRepos` is.
///
/// # Safety
/// `home`, `scope` must each be NULL or a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_list_repos(
    home: *const c_char,
    scope: *const c_char,
    page: i64,
    per_page: i64,
) -> *mut c_char {
    let home = read_str(home);
    let scope = read_str(scope);
    to_c_string(local::list_repos(&home, &scope, page, per_page))
}

/// Directory listing at `path` ("" = root) for `sha`.
///
/// # Safety
/// `home`, `rid`, `sha`, `path` must each be NULL or a valid NUL-terminated
/// UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_get_tree(
    home: *const c_char,
    rid: *const c_char,
    sha: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    let (home, rid, sha, path) = (read_str(home), read_str(rid), read_str(sha), read_str(path));
    to_c_string(gitread::get_tree(&home, &rid, &sha, &path))
}

/// File contents at `path` for `sha`.
///
/// # Safety
/// As `radicle_local_get_tree`.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_get_blob(
    home: *const c_char,
    rid: *const c_char,
    sha: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    let (home, rid, sha, path) = (read_str(home), read_str(rid), read_str(sha), read_str(path));
    to_c_string(gitread::get_blob(&home, &rid, &sha, &path))
}

/// The repository's README at `sha`, or an error when it has none.
///
/// # Safety
/// `home`, `rid`, `sha` must each be NULL or a valid NUL-terminated UTF-8 C
/// string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_get_readme(
    home: *const c_char,
    rid: *const c_char,
    sha: *const c_char,
) -> *mut c_char {
    let (home, rid, sha) = (read_str(home), read_str(rid), read_str(sha));
    to_c_string(gitread::get_readme(&home, &rid, &sha))
}

/// Commit log from `sha` backwards.
///
/// # Safety
/// `home`, `rid`, `sha` must each be NULL or a valid NUL-terminated UTF-8 C
/// string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_list_commits(
    home: *const c_char,
    rid: *const c_char,
    sha: *const c_char,
    page: i64,
    per_page: i64,
) -> *mut c_char {
    let (home, rid, sha) = (read_str(home), read_str(rid), read_str(sha));
    to_c_string(gitread::list_commits(&home, &rid, &sha, page, per_page))
}

/// One commit with its diff.
///
/// # Safety
/// `home`, `rid`, `sha` must each be NULL or a valid NUL-terminated UTF-8 C
/// string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_get_commit(
    home: *const c_char,
    rid: *const c_char,
    sha: *const c_char,
) -> *mut c_char {
    let (home, rid, sha) = (read_str(home), read_str(rid), read_str(sha));
    to_c_string(gitread::get_commit(&home, &rid, &sha))
}

/// Issues, filtered by `status` ("open"|"closed"|"" for all).
///
/// # Safety
/// `home`, `rid`, `status` must each be NULL or a valid NUL-terminated UTF-8 C
/// string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_list_issues(
    home: *const c_char,
    rid: *const c_char,
    status: *const c_char,
    page: i64,
    per_page: i64,
) -> *mut c_char {
    let (home, rid, status) = (read_str(home), read_str(rid), read_str(status));
    to_c_string(cobs::list_issues(&home, &rid, &status, page, per_page))
}

/// One issue including its discussion thread.
///
/// # Safety
/// `home`, `rid`, `id` must each be NULL or a valid NUL-terminated UTF-8 C
/// string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_get_issue(
    home: *const c_char,
    rid: *const c_char,
    id: *const c_char,
) -> *mut c_char {
    let (home, rid, id) = (read_str(home), read_str(rid), read_str(id));
    to_c_string(cobs::get_issue(&home, &rid, &id))
}

/// Patches, filtered by `status` ("open"|"merged"|"archived"|"draft"|"").
///
/// # Safety
/// `home`, `rid`, `status` must each be NULL or a valid NUL-terminated UTF-8 C
/// string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_list_patches(
    home: *const c_char,
    rid: *const c_char,
    status: *const c_char,
    page: i64,
    per_page: i64,
) -> *mut c_char {
    let (home, rid, status) = (read_str(home), read_str(rid), read_str(status));
    to_c_string(cobs::list_patches(&home, &rid, &status, page, per_page))
}

/// One patch including its revisions.
///
/// # Safety
/// `home`, `rid`, `id` must each be NULL or a valid NUL-terminated UTF-8 C
/// string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_get_patch(
    home: *const c_char,
    rid: *const c_char,
    id: *const c_char,
) -> *mut c_char {
    let (home, rid, id) = (read_str(home), read_str(rid), read_str(id));
    to_c_string(cobs::get_patch(&home, &rid, &id))
}

/// Frees a string previously returned by one of the `radicle_local_*`
/// functions. Passing anything else (or double-freeing) is undefined
/// behaviour, same as `free()`.
///
/// # Safety
/// `s` must be a pointer previously returned by one of this crate's
/// `extern "C"` functions, and must not have been freed already.
#[no_mangle]
pub unsafe extern "C" fn radicle_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
