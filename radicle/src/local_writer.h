#pragma once

#include <string>

namespace radicle {

/**
 * Changes the local node's state, through the Rust backend.
 *
 * The write counterpart of `LocalReader`, and separate from it for the same
 * reason `cobwrite.rs` is separate from `cobs.rs`: reading and writing have
 * different requirements, and keeping them apart makes the difference legible
 * at a glance rather than per-method.
 *
 * The difference that matters is a **signing key**. Every read in this module
 * needs only `keys/radicle.pub`, so local browsing works offline with the
 * private key encrypted and untouched. A write needs the private half, which
 * comes from one of three places (a plaintext keystore, `RAD_PASSPHRASE`, or
 * ssh-agent — where `rad auth` puts it, and therefore the ordinary case). When
 * none of them yields a key, a write cannot happen at all.
 *
 * `canWrite()` is what a caller asks *before* offering the user a compose box,
 * so the box is never shown when submitting it could not work. Losing a
 * composed comment to a signing failure that could have been predicted is the
 * one failure this surface must not have.
 *
 * Every call is synchronous. A write touches local git storage and then makes
 * at most one control-socket round-trip to ask the node to announce; neither
 * blocks on the network.
 */
class LocalWriter {
public:
    /// `home` is the Radicle home and `socket` the node control socket —
    /// normally `LocalStore::home()` and `LocalStore::socket()`, which own the
    /// whole of that resolution. An empty home yields a refusal from
    /// `canWrite()` and an error object from every write, never a crash.
    ///
    /// **The socket is carried here, not re-derived downstream.** A write's
    /// announce step needs it, and the Rust side used to pick its own
    /// (`<home>/node/control.sock`, later `RAD_SOCKET`) — neither of which sees
    /// `LocalStore`'s actual preference of `$XDG_RUNTIME_DIR/radicle-*.sock`
    /// nor the module's own `radSocket` setting. So on any machine with a
    /// runtime dir the two disagreed by default, and nothing said so: an
    /// unannounced write is legitimately not an error, so the comment saved
    /// fine and the network simply never heard. One resolver, passed down.
    LocalWriter(std::string home, std::string socket);

    const std::string& home() const { return m_home; }

    /// The control socket a write's announce step will use.
    const std::string& socket() const { return m_socket; }

    /// -> {"canWrite":bool, "nodeId":"did:key:…" | "reason":"…"}
    ///
    /// Note a false answer is NOT an `{"error":...}` object: see the FFI
    /// header. `getCapabilities()` folds this into its own reply.
    std::string canWrite();

    /// Post a comment on an issue's discussion thread.
    /// -> {"id":"…","announced":bool[,"announceError":"…"]}
    std::string commentOnIssue(const std::string& rid, const std::string& id,
                               const std::string& body);

    /// Open a new issue. `description` becomes its root comment.
    /// -> {"id":"<issue id>","announced":bool[,"announceError":"…"]}
    std::string createIssue(const std::string& rid, const std::string& title,
                            const std::string& description);

private:
    std::string m_home;
    std::string m_socket;
};

} // namespace radicle
