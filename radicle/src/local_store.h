#pragma once

#include <string>
#include <vector>

namespace radicle {

/**
 * Where this machine's Radicle home is, and what the node's control socket
 * path should be.
 *
 * Split out of `LocalStore` so both can be answered without touching the
 * filesystem or constructing a store. That matters for two reasons:
 *
 *  - the socket path has a hard 108-byte limit (`sun_path`) that has to be
 *    checked and reported before anything tries to bind or connect, and a
 *    check that needs a live profile cannot run during preflight;
 *  - the home is no longer fixed for the process lifetime. Mode selection
 *    (Attach / Embedded / Seed-only) chooses it, so the resolution has to be a
 *    function of its inputs rather than something a constructor did once.
 *
 * Both are pure functions of their arguments — no environment reads inside —
 * so a test can drive every branch without setenv and without a scratch HOME.
 * `resolveHomeFromEnv` is the one place that reads the environment, and it is
 * a thin wrapper over `resolveHome`.
 */
struct NodePaths {
    /// The Radicle home. Empty when nothing could be resolved.
    std::string home;
    /// The node control socket. Never derived from `home` — see below.
    std::string socket;
    /// Empty when the paths are usable; otherwise a sentence naming what is
    /// wrong, suitable for showing a user verbatim.
    std::string problem;
};

/// The `sun_path` capacity for a Unix domain socket on Linux, NUL included.
///
/// Named rather than inlined because the number is the whole point of the
/// check: the kernel's own error ("path must be shorter than SUN_LEN") names
/// neither the path nor the limit, which is exactly what makes it expensive to
/// diagnose. Anything reporting a length failure must say both.
inline constexpr size_t kSunPathMax = 108;

/**
 * Resolve the Radicle home from an explicit override, else `RAD_HOME`, else
 * `$HOME/.radicle`.
 *
 * `configuredHome` wins when non-empty: that is the settings store's chosen
 * home (Attach mode pointing at a specific profile). `radHomeEnv` and
 * `userHomeEnv` are the environment values, passed in rather than read, so the
 * precedence is testable without mutating the process environment.
 */
std::string resolveHome(const std::string& configuredHome,
                        const std::string& radHomeEnv,
                        const std::string& userHomeEnv);

/**
 * Resolve the node control socket path.
 *
 * **The socket is deliberately NOT derived from the home**, and that is a
 * design requirement rather than a convenience. A Unix socket path is capped
 * at 108 bytes, and Basecamp's own per-profile data directory is already far
 * past that before a socket name is appended — so "the socket follows the
 * home" cannot work in a dev profile and has only a few bytes of slack in an
 * installed one. `$XDG_RUNTIME_DIR` is short by construction, scoped to the
 * user's session, and cleaned up on logout, which is what this repo already
 * relies on for QtRO's own sockets.
 *
 * Precedence: an explicit `configuredSocket`, else `RAD_SOCKET`, else
 * `$XDG_RUNTIME_DIR/radicle-<profile>.sock`, else the crate's own default of
 * `<home>/node/control.sock`. The last is a genuine fallback, not a preference
 * — it is what a hand-run `rad` node uses, so Attach mode must still find it
 * when no runtime dir exists.
 *
 * `profile` names the Basecamp profile so two profiles do not collide on one
 * socket; an empty one yields `radicle.sock`.
 */
std::string resolveSocket(const std::string& configuredSocket,
                          const std::string& radSocketEnv,
                          const std::string& runtimeDirEnv,
                          const std::string& profile,
                          const std::string& home);

/**
 * Resolve both, and check the socket against the 108-byte cap.
 *
 * The check lives here rather than at the point of connection so that a
 * too-long path is reported once, by something that knows the number, instead
 * of surfacing as an opaque i/o error from deep inside the crate. `problem`
 * names the path AND the limit AND the actual length, because a user cannot
 * act on "path too long" without knowing by how much.
 */
NodePaths resolvePaths(const std::string& configuredHome,
                       const std::string& configuredSocket,
                       const std::string& radHomeEnv,
                       const std::string& userHomeEnv,
                       const std::string& radSocketEnv,
                       const std::string& runtimeDirEnv,
                       const std::string& profile);

/// `resolvePaths` with the environment read from the process. The single place
/// this module consults `RAD_HOME`/`HOME`/`RAD_SOCKET`/`XDG_RUNTIME_DIR`.
NodePaths resolvePathsFromEnv(const std::string& configuredHome,
                              const std::string& configuredSocket,
                              const std::string& profile);

/**
 * The local half of the module: everything that comes from this machine's
 * Radicle home rather than from a seed over the network.
 *
 * Detection is deliberately dependency-free: it is filesystem and socket
 * probing, so it works with no `rad` binary and no Rust in the build. The
 * actual reading of repositories and COBs happens in `LocalReader`, over the
 * Rust backend; this class answers "is there anything there, and where".
 *
 * The home is supplied at construction rather than resolved internally, so a
 * caller that has chosen a mode can point the store at that mode's home. The
 * default constructor keeps the previous behaviour — resolve from the
 * environment — for callers that have no mode to apply.
 */
class LocalStore {
public:
    /// Resolve the home from the environment (`RAD_HOME`, else
    /// `$HOME/.radicle`), with the socket resolved alongside it.
    LocalStore();

    /// Use an already-resolved set of paths. This is the constructor mode
    /// selection uses: the caller decides which home applies, and the store
    /// reports on that one.
    explicit LocalStore(NodePaths paths);

    /// Radicle home. Non-empty even if the directory does not exist.
    const std::string& home() const { return m_paths.home; }

    /// The node control socket path this store would probe.
    const std::string& socket() const { return m_paths.socket; }

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
    void detect();

    NodePaths m_paths;
    bool m_available = false;
};

} // namespace radicle
