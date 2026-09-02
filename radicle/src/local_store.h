#pragma once

#include <string>
#include <vector>

namespace radicle {

/**
 * The local half of the module: everything that comes from this machine's
 * ~/.radicle rather than from a seed over the network.
 *
 * In this milestone it only *detects and describes* the local installation —
 * enough for a view to say "you have a node, here are your preferred seeds"
 * and to know that local browsing is not yet wired up. Reading local
 * repositories, COBs and signing writes arrive with the Rust shim over the
 * `radicle` crate in a later milestone; this class is where that plugs in.
 *
 * Detection is deliberately dependency-free: it is filesystem and socket
 * probing, so it works with no `rad` binary and no Rust in the build.
 */
class LocalStore {
public:
    LocalStore();

    /// Radicle home (RAD_HOME, else ~/.radicle). Non-empty even if absent.
    const std::string& home() const { return m_home; }

    /// True when `home()` looks like a real Radicle profile (has storage/).
    bool available() const { return m_available; }

    /// Why local browsing is unavailable — for surfacing verbatim to a user.
    std::string unavailableReason() const;

    /// True when the node daemon's control socket accepts a connection.
    bool nodeRunning() const;

    /// Local node ID from keys/radicle.pub, or "" when unavailable.
    std::string nodeId() const;

    /// `preferredSeeds` from config.json, normalized to https:// origins.
    std::vector<std::string> preferredSeedUrls() const;

private:
    std::string m_home;
    bool m_available = false;
};

} // namespace radicle
