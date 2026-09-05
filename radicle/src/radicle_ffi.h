#pragma once

#include <cstdint>

/**
 * @brief C ABI of the Rust local-node backend (`radicle/rust-ffi/`).
 *
 * Checked in by hand rather than generated at configure time, so the boundary
 * is reviewable in a diff: a change here is a change to the contract between
 * the two languages, and should be as visible as any other API change.
 *
 * Every function returns a heap-allocated, NUL-terminated UTF-8 JSON string
 * that the caller owns and must release with `radicle_free_string`. The JSON
 * is either the documented success shape for that method or
 * `{"error":"<message>"}` — the same one-failure-shape convention the rest of
 * this module uses (see `radicle_impl.h`).
 *
 * `home` is an explicit path to the Radicle home. Resolution of
 * `RAD_HOME`/`HOME` stays on the C++ side (`LocalStore::home()`) so exactly
 * one place decides where the profile lives.
 *
 * A NULL string argument is read as "". No function takes ownership of any
 * argument.
 *
 * Do not call these directly from `radicle_impl.cpp` — `LocalReader` owns this
 * boundary, the way `SeedClient` owns the HTTP one.
 */
extern "C" {

char* radicle_local_list_repos(const char* home, const char* scope,
                               int64_t page, int64_t perPage);

char* radicle_local_get_repo(const char* home, const char* rid);

char* radicle_local_get_tree(const char* home, const char* rid,
                             const char* sha, const char* path);

char* radicle_local_get_blob(const char* home, const char* rid,
                             const char* sha, const char* path);

char* radicle_local_get_readme(const char* home, const char* rid,
                               const char* sha);

char* radicle_local_list_commits(const char* home, const char* rid,
                                 const char* sha, int64_t page, int64_t perPage);

char* radicle_local_get_commit(const char* home, const char* rid,
                               const char* sha);

char* radicle_local_list_issues(const char* home, const char* rid,
                                const char* status, int64_t page, int64_t perPage);

char* radicle_local_get_issue(const char* home, const char* rid, const char* id);

char* radicle_local_list_patches(const char* home, const char* rid,
                                 const char* status, int64_t page, int64_t perPage);

char* radicle_local_get_patch(const char* home, const char* rid, const char* id);

// ---------------------------------------------------------------------------
// Writes.
//
// Everything above reads. These two change state, and they are the only
// functions here that need a signing key. See `LocalWriter` and
// `docs/M2.2-write-actions-design.md`.
// ---------------------------------------------------------------------------

/// Whether a write could succeed right now, and why not when it could not.
///
/// Unlike every other function here, a negative answer is NOT an error object:
/// it returns `{"canWrite":false,"reason":"…"}`, because "you cannot write" is
/// an answer to the question asked rather than a failure to answer it. A
/// caller that treats it as an error will show a failure where it should show
/// an explanation.
///
/// -> {"canWrite":true,"nodeId":"did:key:z6Mk…"}
/// -> {"canWrite":false,"reason":"…"}
char* radicle_local_can_write(const char* home);

/// Posts a comment on an issue's discussion thread.
///
/// -> {"id":"<entry id>","announced":bool[,"announceError":"…"]}
///
/// `announced` false with an `id` present is a SUCCESSFUL write that the local
/// node has not yet told the network about — an ordinary state, not a failure.
char* radicle_local_comment_on_issue(const char* home, const char* rid,
                                     const char* id, const char* body);

/// Opens a new issue. `description` becomes its root comment.
///
/// -> {"id":"<issue id>","announced":bool[,"announceError":"…"]}
///
/// The `id` is the ISSUE's id, not an entry id — a caller passes it straight
/// to `radicle_local_get_issue` to open what was just created.
char* radicle_local_create_issue(const char* home, const char* rid,
                                 const char* title, const char* description);

/// Releases a string returned by any of the above. Passing anything else, or
/// freeing twice, is undefined behaviour — the same contract as `free()`.
void radicle_free_string(char* s);

} // extern "C"
