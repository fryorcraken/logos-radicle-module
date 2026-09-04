#include "local_store.h"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <fstream>
#include <sstream>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

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

LocalStore::LocalStore()
{
    std::string home = envOr("RAD_HOME", "");
    if (home.empty()) {
        const std::string userHome = envOr("HOME", "");
        if (!userHome.empty()) home = userHome + "/.radicle";
    }

    m_home = home;
    // `storage/` is the marker that this is a real profile rather than a bare
    // directory that happens to exist.
    m_available = !m_home.empty() && pathExists(m_home + "/storage");
}

std::string LocalStore::unavailableReason() const
{
    if (!m_available) {
        if (m_home.empty())
            return "no Radicle home found (set RAD_HOME or HOME)";
        return "no Radicle profile at " + m_home
             + " — install Radicle and run `rad auth` to browse local repositories";
    }

    // Unreachable in practice: callers check available() first, and when a
    // profile exists the read goes to the backend, which reports its own more
    // specific failure. Kept as a total function rather than an assert so a
    // future caller that forgets the guard still gets a sentence a user can
    // act on instead of an empty string.
    return "a Radicle profile was found at " + m_home
         + " but the request could not be served";
}

bool LocalStore::nodeRunning() const
{
    if (!m_available) return false;

    const std::string sockPath = envOr("RAD_SOCKET", m_home + "/node/control.sock");
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

    // The node id is the multibase-encoded public key. Deriving it from
    // keys/radicle.pub means base64-decoding the SSH blob and base58-encoding
    // the result, which is more machinery than this milestone needs — the
    // running node reports it directly over the control socket, and the Rust
    // shim will expose it too. Reported as empty until then.
    return {};
}

std::vector<std::string> LocalStore::preferredSeedUrls() const
{
    std::vector<std::string> out;
    if (!m_available) return out;

    std::ifstream in(m_home + "/config.json");
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
