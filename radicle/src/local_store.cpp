#include "local_store.h"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <fstream>
#include <sstream>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <utility>

namespace radicle {

namespace {

bool pathExists(const std::string& path)
{
    struct stat st{};
    return ::stat(path.c_str(), &st) == 0;
}

std::string envOr(const char* name, const std::string& fallback)
{
    const char* v = std::getenv(name);
    return (v && *v) ? std::string(v) : fallback;
}

/**
 * Extract the host from a `nid@host:port` seed spec in config.json.
 *
 * Preferred seeds are recorded as peer-to-peer addresses (port 8776). The JSON
 * API we proxy to is a *separate* service (radicle-httpd) on the same host over
 * HTTPS — and plenty of seeds run the p2p node without it, so being listed here
 * is no guarantee the API answers.
 */
std::string seedSpecToHost(const std::string& spec)
{
    std::string host = spec;

    const size_t at = host.find('@');
    if (at != std::string::npos) host = host.substr(at + 1);

    const size_t colon = host.find(':');
    if (colon != std::string::npos) host = host.substr(0, colon);

    return host;
}

} // namespace

// ---------------------------------------------------------------------------
// Path resolution. Pure functions of their arguments — the environment is read
// only by the *FromEnv wrappers, so every precedence branch is testable
// without setenv and without a scratch HOME.
// ---------------------------------------------------------------------------

std::string resolveHome(const std::string& configuredHome,
                        const std::string& radHomeEnv,
                        const std::string& userHomeEnv)
{
    if (!configuredHome.empty()) return configuredHome;
    if (!radHomeEnv.empty())     return radHomeEnv;
    if (!userHomeEnv.empty())    return userHomeEnv + "/.radicle";
    return {};
}

std::string resolveSocket(const std::string& configuredSocket,
                          const std::string& radSocketEnv,
                          const std::string& runtimeDirEnv,
                          const std::string& profile,
                          const std::string& home)
{
    if (!configuredSocket.empty()) return configuredSocket;
    if (!radSocketEnv.empty())     return radSocketEnv;

    // The preferred shape: short by construction, per user session, cleaned up
    // on logout. See the header for why deriving it from the home cannot work.
    if (!runtimeDirEnv.empty()) {
        const std::string name = profile.empty() ? std::string("radicle")
                                                 : "radicle-" + profile;
        return runtimeDirEnv + "/" + name + ".sock";
    }

    // Genuine fallback, not a preference: this is where a hand-run `rad` node
    // puts its socket, so `local` mode has to still find it when there is no
    // runtime dir to prefer.
    if (!home.empty()) return home + "/node/control.sock";
    return {};
}

NodePaths resolvePaths(const std::string& configuredHome,
                       const std::string& configuredSocket,
                       const std::string& radHomeEnv,
                       const std::string& userHomeEnv,
                       const std::string& radSocketEnv,
                       const std::string& runtimeDirEnv,
                       const std::string& profile)
{
    NodePaths out;
    out.home = resolveHome(configuredHome, radHomeEnv, userHomeEnv);
    out.socket = resolveSocket(configuredSocket, radSocketEnv, runtimeDirEnv,
                               profile, out.home);

    if (out.home.empty()) {
        out.problem = "no Radicle home found (set RAD_HOME or HOME)";
        return out;
    }

    // The kernel's own message names neither the path nor the limit, which is
    // what makes this failure expensive. Say both, plus the actual length, so
    // a user knows by how much they are over and which path to shorten.
    if (out.socket.size() + 1 > kSunPathMax) {
        out.problem = "the node control socket path is too long: "
                    + out.socket + " is " + std::to_string(out.socket.size())
                    + " bytes, but a Unix socket path is capped at "
                    + std::to_string(kSunPathMax - 1)
                    + " bytes (plus a terminating NUL). Set RAD_SOCKET to a "
                      "shorter path, such as one under $XDG_RUNTIME_DIR.";
    }
    return out;
}

NodePaths resolvePathsFromEnv(const std::string& configuredHome,
                              const std::string& configuredSocket,
                              const std::string& profile)
{
    return resolvePaths(configuredHome,
                        configuredSocket,
                        envOr("RAD_HOME", ""),
                        envOr("HOME", ""),
                        envOr("RAD_SOCKET", ""),
                        envOr("XDG_RUNTIME_DIR", ""),
                        profile);
}

// ---------------------------------------------------------------------------
// LocalStore
// ---------------------------------------------------------------------------

LocalStore::LocalStore()
    : m_paths(resolvePathsFromEnv("", "", ""))
{
    detect();
}

LocalStore::LocalStore(NodePaths paths)
    : m_paths(std::move(paths))
{
    detect();
}

void LocalStore::detect()
{
    // `storage/` is the marker that this is a real profile rather than a bare
    // directory that happens to exist.
    m_available = !m_paths.home.empty() && pathExists(m_paths.home + "/storage");
}

std::string LocalStore::unavailableReason() const
{
    if (!m_available) {
        if (m_paths.home.empty())
            return "no Radicle home found (set RAD_HOME or HOME)";
        return "no Radicle profile at " + m_paths.home
             + " — install Radicle and run `rad auth` to browse local repositories";
    }

    // Unreachable in practice: callers check available() first, and when a
    // profile exists the read goes to the backend, which reports its own more
    // specific failure. Kept as a total function rather than an assert so a
    // future caller that forgets the guard still gets a sentence a user can
    // act on instead of an empty string.
    return "a Radicle profile was found at " + m_paths.home
         + " but the request could not be served";
}

bool LocalStore::nodeRunning() const
{
    if (!m_available) return false;

    const std::string& sockPath = m_paths.socket;
    if (sockPath.empty()) return false;
    if (sockPath.size() >= sizeof(sockaddr_un{}.sun_path)) return false;
    if (!pathExists(sockPath)) return false;

    // The socket file can outlive the daemon, so a stat is not enough —
    // only a successful connect proves someone is listening.
    const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return false;

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sockPath.c_str());

    const bool connected =
        ::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0;
    ::close(fd);
    return connected;
}

std::string LocalStore::nodeId() const
{
    if (!m_available) return {};

    // Deliberately delegated to the Rust backend rather than derived here.
    // The node id is the multibase-encoded public key, so producing it from
    // `keys/radicle.pub` means base64-decoding an SSH blob and base58-encoding
    // the result — machinery the `radicle` crate already has and this file
    // would only reimplement. `RadicleImpl::getCapabilities` reads it through
    // `LocalReader::nodeId()`, which needs only the public half of the key and
    // therefore works with the private key still encrypted.
    return {};
}

std::vector<std::string> LocalStore::preferredSeedUrls() const
{
    std::vector<std::string> out;
    if (!m_available) return out;

    std::ifstream in(m_paths.home + "/config.json");
    if (!in) return out;

    std::stringstream buffer;
    buffer << in.rdbuf();

    auto config = nlohmann::json::parse(buffer.str(), nullptr, false);
    if (config.is_discarded() || !config.is_object()) return out;

    const auto seeds = config.value("preferredSeeds", nlohmann::json::array());
    if (!seeds.is_array()) return out;

    for (const auto& entry : seeds) {
        if (!entry.is_string()) continue;
        std::string host = seedSpecToHost(entry.get<std::string>());
        if (!host.empty()) out.push_back("https://" + host);
    }
    return out;
}

} // namespace radicle
