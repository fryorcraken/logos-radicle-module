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

/* Branches across every peer, the local node's own first. This has no
 * `remote*` counterpart returning the same thing: a seed reports one canonical
 * ref set, while local storage holds one namespace per peer. */
char* radicle_local_list_branches(const char* home, const char* rid);

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
///
/// `socket` is the node control socket, used only for that announce step, and
/// is a parameter for the same reason `home` is: `LocalStore` owns the
/// resolution, and a second opinion on the Rust side is precisely how the read
/// path came to probe `$XDG_RUNTIME_DIR/radicle.sock` while a write announced
/// to `<home>/node/control.sock`. Because an unannounced write is legitimately
/// not an error, that disagreement surfaced nowhere. Empty falls back to
/// `<home>/node/control.sock`.
char* radicle_local_comment_on_issue(const char* home, const char* socket,
                                     const char* rid, const char* id,
                                     const char* body);

/// Opens a new issue. `description` becomes its root comment.
///
/// -> {"id":"<issue id>","announced":bool[,"announceError":"…"]}
///
/// The `id` is the ISSUE's id, not an entry id — a caller passes it straight
/// to `radicle_local_get_issue` to open what was just created.
///
/// `socket` as above.
char* radicle_local_create_issue(const char* home, const char* socket,
                                 const char* rid, const char* title,
                                 const char* description);

// ---------------------------------------------------------------------------
// Environment.
//
// Neither of these reads repository storage, so neither takes a `home` in the
// usual sense. They answer two questions a preflight has to ask before any
// write can work: where is git, and which identity does this node hold.
// ---------------------------------------------------------------------------

/// Resolves and validates a git binary.
///
/// An empty `candidate` means "find it on PATH". A non-empty one OVERRIDES
/// detection entirely — there is deliberately no fallback to PATH when the
/// configured binary is missing, because a silent fallback makes a typo in the
/// setting look like a Radicle bug. Validation runs the candidate's
/// `git --version`, so an executable that exists but is not git is refused
/// here rather than at the moment someone pushes.
///
/// Like `radicle_local_can_write`, a negative answer is NOT an error object:
/// "there is no usable git" is an answer to the question asked.
///
/// -> {"found":true,"path":"/usr/bin/git","version":"git version 2.55.0",
///     "configured":bool}
/// -> {"found":false,"path":"","version":"","configured":bool,"reason":"…"}
char* radicle_git_probe(const char* candidate);

/// Puts a configured git's directory at the front of THIS PROCESS's PATH.
///
/// **Process-global, and must be called once at module init, before any thread
/// starts.** Radicle spawns git by bare name from six separate sites across
/// `radicle` and `radicle-node`, two of which `env_clear()` and re-admit only
/// PATH — so PATH is the one channel that reaches every site, and it cannot be
/// scoped to a single call. A settings panel that changes the git path
/// therefore needs restart-to-apply semantics; see `docs/M3-phase0-findings.md`
/// §5.
///
/// Validates before mutating: an unusable path must not reshape PATH and then
/// fail later somewhere unrelated.
///
/// -> {"applied":true,"path":"/usr/bin/git"} or {"error":"…"}
char* radicle_apply_git_path(const char* configured);

/// The local node's ID, read from `keys/radicle.pub` alone.
///
/// Deliberately independent of signing. `radicle_local_can_write` also reports
/// a node id, but only when a signer could be loaded — and the identity has to
/// be visible even when the key is encrypted and locked, because the failure
/// this design is most exposed to is a user believing they are operating as one
/// identity when they are operating as another.
///
/// -> {"nodeId":"did:key:z6Mk…"} or {"nodeId":"","reason":"…"}
char* radicle_local_node_id(const char* home);

// ---------------------------------------------------------------------------
// Identity creation.
//
// The `rad auth` half of the embedded node. Unlike everything above, these do
// not assume a profile exists at `home` — they are what makes one — so `home`
// here names a directory that may not exist yet rather than one `LocalStore`
// has already detected.
// ---------------------------------------------------------------------------

/// Whether `home` already holds a **complete** Radicle identity.
///
/// The markers are `keys/radicle.pub` AND `config.json`, not the directory
/// existing. Both halves are load-bearing:
///
///  - An embedded home is a directory this module creates and may well have
///    created already — for settings, or on a run that failed between `mkdir`
///    and keygen. Treating "the directory is there" as "a profile is there"
///    would make such a setup permanently uncompletable.
///  - `Profile::init` writes the keystore FIRST and then runs seven more
///    fallible steps, so a crashed init leaves key files with no profile around
///    them. Keying on the keystore alone would report that home as occupied for
///    ever, and there is deliberately no `force` — see `init_profile`.
///
/// So a half-created home answers **false** here: it is not a profile, and
/// creating into it is the recovery rather than a destructive act.
///
/// Note this asks a different question from `LocalStore::available()`, which
/// looks for `storage/`. That one asks "can I browse this"; this one asks
/// "would creating here destroy a real identity". A home with keys and no
/// storage answers yes here and no there, and both answers are correct.
///
/// -> {"exists":bool}
char* radicle_local_profile_exists(const char* home);

/// Creates a Radicle identity at `home`, the way `rad auth` does.
///
/// **An existing profile is refused, never overwritten.** This is the one
/// irreversible operation in the module: the signing key *is* the identity, and
/// every repository delegating to it becomes unreachable if it is replaced.
/// There is deliberately no `force` — a flag that exists is a flag a future UI
/// can pass by accident.
///
/// Note the crate refuses a second init as well (`Keystore::init` returns
/// `AlreadyInitialized`), so this module's own guard is a second line rather
/// than the only one. It earns its place by firing *before* the home directory
/// tree is created, and by naming the consequence instead of a keystore file.
/// Stated here because the opposite was claimed at one point, and a reader who
/// checks the crate would otherwise find the justification false.
///
/// A **half-created** home — key material present, initialisation unfinished —
/// is reported distinctly and as recoverable, naming the path to remove. It is
/// neither "occupied" nor "absent", and calling it occupied would leave the
/// home permanently uncompletable while claiming a signing key is at risk that
/// nothing ever signed with. It is reported rather than repaired: deleting key
/// material automatically would turn a classifier bug into a destroyed
/// identity.
///
/// `home` must be an **absolute** path. A relative one is refused rather than
/// resolved against a working directory this module does not control.
///
/// An empty `passphrase` writes the key UNENCRYPTED, matching `ssh-keygen` and
/// the crate's own `env::passphrase()`. That is a real trade rather than a
/// default to hide: an unencrypted key lets the node start unattended and lets
/// writes happen with no prompt, at the cost of a secret in plaintext on disk.
/// The outcome comes back as `encrypted` so a caller states what happened
/// instead of assuming it followed the input.
///
/// -> {"created":true,"nodeId":"did:key:z6Mk…","home":"…","alias":"…",
///     "encrypted":bool}
/// -> {"error":"…"}
char* radicle_local_init_profile(const char* home, const char* alias,
                                 const char* passphrase);

// ---------------------------------------------------------------------------
// The node daemon.
//
// These three are unlike everything above in one way that matters: they leave
// something RUNNING after they return. Every other function here completes
// within its call, while a started node is threads, a bound socket and open
// databases that outlive the boundary entirely.
//
// The node runs IN THIS PROCESS — `radicle-node` linked as a library and driven
// through `Runtime::init`/`run`/`Handle::shutdown`, not a spawned binary. See
// `docs/M3-phase0-findings.md` §3 for why, and `EmbeddedNode` for the C++ side
// that owns this boundary.
//
// **One consequence to know rather than discover:** the Rust side's `guarded()`
// panic boundary does not reach the threads the node spawns. `radicle_node_*`
// itself is guarded like everything else, but a reactor or worker-pool panic
// inside a running node is outside it — which is why `radicle_node_status`
// reports `serving` (a live socket probe) alongside `running` (bookkeeping),
// since only the first can tell a working node from one that died quietly.
// ---------------------------------------------------------------------------

/// Starts a node in this process against `home`, listening on `socket`.
///
/// Both paths are parameters rather than resolved on the Rust side, for the
/// same reason `home` is everywhere else here — `LocalStore` owns resolution —
/// and for one more that is specific to this call: a node that bound a socket
/// the rest of the module was not watching would report as never running while
/// running perfectly, since `localNodeRunning` probes the socket `LocalStore`
/// resolved. Consulting `RAD_HOME`/`RAD_SOCKET` here would also let an
/// environment this module never set aim the embedded node at the user's own
/// `~/.radicle`, which is the one thing the mode exists to prevent.
///
/// An empty `passphrase` means the key is unencrypted. **An encrypted profile
/// needs its passphrase at START, not at sign time** — `Runtime::init` takes a
/// decrypted signing key, so there is no later point to supply one. Phase 0 left
/// this open; `tests/node_lifecycle.rs` now measures it in both directions.
///
/// The node binds **no TCP port** (`listen: []`): it can fetch and announce, but
/// peers cannot fetch from it. That is the right default for a desktop behind
/// NAT and a real limitation a UI must state; `listening` reports it.
///
/// Returns only once the control socket answers, or with an error saying why it
/// never did — a spawned thread is not a started node.
///
/// -> {"started":true,"home":"…","socket":"…","nodeId":"did:key:z6Mk…",
///     "listening":[]}
/// -> {"error":"…"}
char* radicle_node_start(const char* home, const char* socket,
                         const char* passphrase);

/// Stops the node this process started.
///
/// Like `radicle_local_can_write`, a negative answer is NOT an error object:
/// stopping a node that is not running is what the caller asked for, so it
/// returns `{"stopped":false,"reason":"…"}`. An `{"error":…}` here means a node
/// WAS running and did not stop cleanly.
///
/// -> {"stopped":bool[,"reason":"…"]} or {"error":"…"}
char* radicle_node_stop(void);

/// What this process's node is doing.
///
/// **`running` and `serving` answer different questions and both are reported.**
/// `running` is bookkeeping — a node was started here and its thread has not
/// finished. `serving` is a live probe of the control socket. They agree in
/// every ordinary state; the two moments they disagree are the interesting ones
/// (mid-startup, and after an internal panic), and collapsing them into one
/// boolean would make the second invisible.
///
/// -> {"running":bool,"home":"…","socket":"…","serving":bool,"reason":"…"}
char* radicle_node_status(void);

/// Releases a string returned by any of the above. Passing anything else, or
/// freeing twice, is undefined behaviour — the same contract as `free()`.
void radicle_free_string(char* s);

} // extern "C"
