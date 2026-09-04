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
    /// `home` is the Radicle home — normally `LocalStore::home()`, which owns
    /// the RAD_HOME/HOME resolution. An empty home yields a refusal from
    /// `canWrite()` and an error object from every write, never a crash.
    explicit LocalWriter(std::string home);

    const std::string& home() const { return m_home; }

    /// -> {"canWrite":bool, "nodeId":"did:key:…" | "reason":"…"}
    ///
    /// Note a false answer is NOT an `{"error":...}` object: see the FFI
    /// header. `getCapabilities()` folds this into its own reply.
    std::string canWrite();

    /// Post a comment on an issue's discussion thread.
    /// -> {"id":"…","announced":bool[,"announceError":"…"]}
    std::string commentOnIssue(const std::string& rid, const std::string& id,
                               const std::string& body);

private:
    std::string m_home;
};

} // namespace radicle
