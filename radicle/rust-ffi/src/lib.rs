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
pub mod cobwrite;
pub mod env;
pub mod gitread;
pub mod local;
pub mod profileinit;

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

/// Run one read and hand back its JSON, converting a panic into an error
/// object rather than letting it cross the C ABI.
///
/// **This is a soundness guard, not error handling.** A Rust panic unwinding
/// through an `extern "C"` frame is undefined behaviour — the process may
/// abort, or corrupt itself quietly. The read paths are written not to panic
/// (every fallible call returns `Result`, and the pagination arithmetic
/// saturates rather than overflowing), but "written not to" is a claim about
/// code that will keep changing, and the `radicle` crate's own internals can
/// panic for reasons this crate does not control.
///
/// `AssertUnwindSafe` is justified because the closure owns everything it
/// touches: the arguments are freshly-copied `String`s and the return value is
/// a `String`. There is no `&mut` to shared state that a partial unwind could
/// leave inconsistent — a panic mid-read abandons a `git2` handle, which is
/// exactly what dropping it would do anyway.
fn guarded(f: impl FnOnce() -> String) -> *mut c_char {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
    to_c_string(result.unwrap_or_else(|_| {
        // Deliberately generic: the panic payload may be a non-UTF-8 or
        // non-string type, and formatting it here risks panicking again.
        "{\"error\":\"the local backend hit an internal error reading storage\"}".to_string()
    }))
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
    guarded(move || local::get_repo(&home, &rid))
}

/// Branches across every peer in local storage, the local node's own first.
///
/// Unlike the other reads this has no `remote*` twin that returns the same
/// thing: a seed reports one canonical ref set, while local storage holds one
/// namespace per peer. `local::list_branches` documents the reply shape and
/// why it cannot be folded into `get_repo`'s `refs.refs`.
///
/// # Safety
/// `home`, `rid` must each be NULL or a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_list_branches(
    home: *const c_char,
    rid: *const c_char,
) -> *mut c_char {
    let home = read_str(home);
    let rid = read_str(rid);
    guarded(move || local::list_branches(&home, &rid))
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
    guarded(move || local::list_repos(&home, &scope, page, per_page))
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
    guarded(move || gitread::get_tree(&home, &rid, &sha, &path))
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
    guarded(move || gitread::get_blob(&home, &rid, &sha, &path))
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
    guarded(move || gitread::get_readme(&home, &rid, &sha))
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
    guarded(move || gitread::list_commits(&home, &rid, &sha, page, per_page))
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
    guarded(move || gitread::get_commit(&home, &rid, &sha))
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
    guarded(move || cobs::list_issues(&home, &rid, &status, page, per_page))
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
    guarded(move || cobs::get_issue(&home, &rid, &id))
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
    guarded(move || cobs::list_patches(&home, &rid, &status, page, per_page))
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
    guarded(move || cobs::get_patch(&home, &rid, &id))
}

// ---------------------------------------------------------------------------
// Writes.
//
// Everything above reads. These two change state, and they go through the same
// `guarded` boundary for the same reason — a panic crossing `extern "C"` is
// undefined behaviour regardless of which direction the data was flowing.
// ---------------------------------------------------------------------------

/// Whether a write could succeed right now, and why not when it could not.
///
/// Answers with `{"canWrite":bool,...}` rather than an error object when the
/// answer is no: "you cannot write" is an answer to the question asked. See
/// `cobwrite::can_write`.
///
/// # Safety
/// `home` must be NULL or a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_can_write(home: *const c_char) -> *mut c_char {
    let home = read_str(home);
    guarded(move || cobwrite::can_write(&home))
}

/// Post a comment on an issue's discussion thread.
///
/// `socket` is the node control socket the caller resolved, used only for the
/// announce step. It is a parameter for the same reason `home` is: exactly one
/// place — `LocalStore` on the C++ side — decides where the node lives, and a
/// second opinion here is how the read and write paths came to probe two
/// different sockets. Empty means "fall back to `<home>/node/control.sock`".
///
/// # Safety
/// `home`, `socket`, `rid`, `id`, `body` must each be NULL or a valid
/// NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_comment_on_issue(
    home: *const c_char,
    socket: *const c_char,
    rid: *const c_char,
    id: *const c_char,
    body: *const c_char,
) -> *mut c_char {
    let (home, socket, rid, id, body) = (
        read_str(home),
        read_str(socket),
        read_str(rid),
        read_str(id),
        read_str(body),
    );
    guarded(move || cobwrite::comment_on_issue(&home, &socket, &rid, &id, &body))
}

/// Open a new issue. `description` becomes its root comment.
///
/// `socket` is the node control socket the caller resolved; see
/// `radicle_local_comment_on_issue`.
///
/// # Safety
/// `home`, `socket`, `rid`, `title`, `description` must each be NULL or a valid
/// NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_create_issue(
    home: *const c_char,
    socket: *const c_char,
    rid: *const c_char,
    title: *const c_char,
    description: *const c_char,
) -> *mut c_char {
    let (home, socket, rid, title, description) = (
        read_str(home),
        read_str(socket),
        read_str(rid),
        read_str(title),
        read_str(description),
    );
    guarded(move || cobwrite::create_issue(&home, &socket, &rid, &title, &description))
}

// ---------------------------------------------------------------------------
// Environment: where git is, and which identity the node holds.
//
// Neither reads repository storage, so neither takes the usual `home`-first
// shape. Both still go through `guarded` — the panic boundary is about the ABI,
// not about what the function does behind it.
// ---------------------------------------------------------------------------

/// Resolve and validate a git binary.
///
/// An empty `candidate` means "find it on PATH"; a non-empty one overrides
/// detection entirely, with no silent fallback. See `env::git_probe`.
///
/// -> {"found":bool,"path":"…","version":"…","configured":bool[,"reason":"…"]}
///
/// # Safety
/// `candidate` must be NULL or a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_git_probe(candidate: *const c_char) -> *mut c_char {
    let candidate = read_str(candidate);
    guarded(move || env::git_probe(&candidate))
}

/// Put a configured git's directory at the front of this process's `PATH`.
///
/// **Process-global, and init-time only.** The six bare-name `git` spawn sites
/// across `radicle` and `radicle-node` read the process environment at spawn
/// time, so this is the only channel that reaches all of them — and it must
/// happen before any thread starts. See `env::prepend_to_path`.
///
/// -> {"applied":bool,"path":"…"} or {"error":"…"}
///
/// # Safety
/// `configured` must be NULL or a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_apply_git_path(configured: *const c_char) -> *mut c_char {
    let configured = read_str(configured);
    guarded(move || match env::apply_git_path(&configured) {
        Ok(path) => serde_json::json!({ "applied": true, "path": path }).to_string(),
        Err(reason) => serde_json::json!({ "error": reason }).to_string(),
    })
}

/// The local node's ID, from the public half of the keystore only.
///
/// Independent of signing on purpose: the identity must be visible even when
/// the key is encrypted and locked. See `env::node_id`.
///
/// -> {"nodeId":"did:key:z6Mk…"} or {"nodeId":"","reason":"…"}
///
/// # Safety
/// `home` must be NULL or a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_node_id(home: *const c_char) -> *mut c_char {
    let home = read_str(home);
    guarded(move || env::node_id(&home))
}

// ---------------------------------------------------------------------------
// Identity creation.
//
// The `rad auth` half of the embedded node: this is the only entry point that
// brings an identity into existence rather than reading or changing one. It
// goes through `guarded` like everything else — a panic crossing `extern "C"`
// is undefined behaviour whatever the function was doing — and it matters more
// here than anywhere else, because the panic would land mid-keygen with a
// half-written keystore on disk.
// ---------------------------------------------------------------------------

/// Whether `home` already holds a Radicle identity.
///
/// Asked separately from creating one so a wizard can tell a user what it is
/// about to do *before* it does it. `radicle_local_init_profile` refuses an
/// occupied home anyway — this is not the safety check, it is what lets the
/// safety check never be the thing a user first hears about.
///
/// -> {"exists":bool}
///
/// # Safety
/// `home` must be NULL or a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_profile_exists(home: *const c_char) -> *mut c_char {
    let home = read_str(home);
    guarded(move || serde_json::json!({ "exists": profileinit::profile_exists(&home) }).to_string())
}

/// Create a Radicle identity at `home`, the way `rad auth` does.
///
/// An empty `passphrase` means an unencrypted key on disk, matching
/// `ssh-keygen` and the crate's own `env::passphrase()`. An existing profile is
/// **refused, never overwritten** — see `profileinit::init_profile`.
///
/// -> {"created":true,"nodeId":"did:key:z6Mk…","home":"…","alias":"…","encrypted":bool}
/// -> {"error":"…"}
///
/// # Safety
/// `home`, `alias`, `passphrase` must each be NULL or a valid NUL-terminated
/// UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn radicle_local_init_profile(
    home: *const c_char,
    alias: *const c_char,
    passphrase: *const c_char,
) -> *mut c_char {
    let (home, alias, passphrase) = (read_str(home), read_str(alias), read_str(passphrase));
    guarded(move || profileinit::init_profile(&home, &alias, &passphrase))
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
