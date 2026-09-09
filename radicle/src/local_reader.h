#pragma once

#include <cstdint>
#include <string>

namespace radicle {

/**
 * Reads the local node's storage (~/.radicle) through the Rust backend.
 *
 * This is the local counterpart of `SeedClient`: it owns one boundary (the
 * `extern "C"` surface in `radicle_ffi.h`) so nothing else in the module has
 * to think about raw pointers or who frees what. Every method returns the same
 * JSON string the corresponding `local*` module method returns, so
 * `radicle_impl.cpp` is a one-line forward.
 *
 * The shapes match `remote*`'s byte for byte — that is the contract
 * `radicle_impl.h` states and the reason a view renders either source without
 * branching. They are pinned by tests in `radicle/rust-ffi/tests/` (against a
 * real profile) and in `radicle/tests/test_local_reader.cpp` (at this layer).
 *
 * Every call is synchronous and reads from disk. There is no network and no
 * daemon involved: local browsing works with the node stopped.
 */
class LocalReader {
public:
    /// `home` is the Radicle home — normally `LocalStore::home()`, which owns
    /// the RAD_HOME/HOME resolution. An empty home yields an error object from
    /// every method rather than a crash.
    explicit LocalReader(std::string home);

    const std::string& home() const { return m_home; }

    std::string listRepos(const std::string& scope, int64_t page, int64_t perPage);
    std::string getRepo(const std::string& rid);
    std::string listBranches(const std::string& rid);
    std::string getTree(const std::string& rid, const std::string& sha,
                        const std::string& path);
    std::string getBlob(const std::string& rid, const std::string& sha,
                        const std::string& path);
    std::string getReadme(const std::string& rid, const std::string& sha);
    std::string listCommits(const std::string& rid, const std::string& sha,
                            int64_t page, int64_t perPage);
    std::string getCommit(const std::string& rid, const std::string& sha);
    std::string listIssues(const std::string& rid, const std::string& status,
                           int64_t page, int64_t perPage);
    std::string getIssue(const std::string& rid, const std::string& id);
    std::string listPatches(const std::string& rid, const std::string& status,
                            int64_t page, int64_t perPage);
    std::string getPatch(const std::string& rid, const std::string& id);

    /// The local node's ID, from the public half of the keystore only.
    ///
    /// Needs no signer and no passphrase, which is the whole point: the
    /// identity has to be visible even when the key is locked. `LocalWriter`
    /// also reports a node id, but only alongside a *usable signer*, so it goes
    /// dark in exactly the case where a user is most likely to be confused
    /// about which identity they hold.
    ///
    /// -> {"nodeId":"did:key:z6Mk…"} or {"nodeId":"","reason":"…"}
    std::string nodeId();

    /// Resolve and validate a git binary. Static because it is a question about
    /// the machine, not about a particular Radicle home — there is no sensible
    /// per-home answer, and making it an instance method would imply one.
    ///
    /// -> {"found":bool,"path":"…","version":"…","configured":bool[,"reason":…]}
    static std::string gitProbe(const std::string& candidate);

    /// Put a configured git's directory on this process's PATH.
    ///
    /// **Process-global and init-time only** — see `radicle_ffi.h` for why PATH
    /// is the only channel that reaches all six of Radicle's git spawn sites,
    /// and why that forces restart-to-apply semantics on the setting.
    ///
    /// -> {"applied":true,"path":"…"} or {"error":"…"}
    static std::string applyGitPath(const std::string& configured);

    // -----------------------------------------------------------------------
    // Identity creation.
    //
    // These CREATE state, which makes their presence on a class called
    // `LocalReader` worth justifying rather than assuming.
    //
    // The alternative was `LocalWriter`, and it does not fit: that class is
    // constructed with one home and one socket and answers about *that*
    // profile — `canWrite()`, `commentOnIssue()` — because a write needs a
    // signing key from a keystore that already exists. Creating an identity is
    // the opposite situation. It takes the home as an argument precisely
    // BECAUSE no profile is there yet, so there is nothing for an instance to
    // be bound to, and binding one to a home it is about to create would invert
    // the dependency this whole layer is built on: `LocalStore` resolves a
    // home, then a reader/writer is built from it.
    //
    // So these are static for the same reason `gitProbe` is: they answer a
    // question about a *path*, not about the profile this instance holds. The
    // grouping is by "needs no existing profile", which is the property a
    // caller actually has to know.
    // -----------------------------------------------------------------------

    /// Whether `home` already holds a **complete** Radicle identity.
    ///
    /// Asked separately from creating one so a wizard can tell a user what it
    /// is about to do before it does it. `initProfile` refuses an occupied home
    /// regardless — this is not the safety check, it is what stops the safety
    /// check from being the first thing a user hears about.
    ///
    /// Deliberately a different question from `LocalStore::available()`: that
    /// looks for `storage/` and means "can I browse this", while this means
    /// "would creating here destroy a real identity".
    ///
    /// **A half-created home answers false.** `Profile::init` writes the
    /// keystore before seven further fallible steps, so a crashed init leaves
    /// key files with no profile around them; treating that as occupied would
    /// make the home permanently uncompletable, since there is no `force`. The
    /// markers are therefore `keys/radicle.pub` *and* `config.json`.
    ///
    /// -> {"exists":bool}
    static std::string profileExists(const std::string& home);

    /// Create a Radicle identity at `home`, the way `rad auth` does.
    ///
    /// **Refuses an existing profile rather than overwriting it.** The signing
    /// key is the identity; replacing it is not recoverable and makes every
    /// repository delegating to it unreachable.
    ///
    /// The `radicle` crate refuses a second init too, so this is a second line
    /// of defence, not the only one — it fires before the home directory is
    /// created, and its message names the consequence rather than a keystore
    /// file. Worth stating because the opposite was once claimed here.
    ///
    /// `home` must be absolute; a relative path is refused, not resolved.
    ///
    /// An empty `passphrase` means an unencrypted key on disk — the same
    /// convention `ssh-keygen` and the crate's own `env::passphrase()` use. The
    /// reply reports `encrypted` so a caller states the outcome rather than
    /// assuming it matched the input.
    ///
    /// -> {"created":true,"nodeId":"…","home":"…","alias":"…","encrypted":bool}
    /// -> {"error":"…"}
    static std::string initProfile(const std::string& home, const std::string& alias,
                                   const std::string& passphrase);

private:
    std::string m_home;
};

} // namespace radicle
