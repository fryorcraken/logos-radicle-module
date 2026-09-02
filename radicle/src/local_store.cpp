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
 * Turn a `nid@host:port` seed spec from config.json into an HTTPS origin.
 *
 * Preferred seeds are recorded as peer-to-peer addresses (port 8776), but the
 * JSON API we proxy to is served over HTTPS on the same host. So we keep the
 * host and drop both the node id and the p2p port.
 */
std::string seedSpecToHttpsOrigin(const std::string& spec)
{
    std::string host = spec;

    const size_t at = host.find('@');
    if (at != std::string::npos) host = host.substr(at + 1);

    const size_t colon = host.find(':');
    if (colon != std::string::npos) host = host.substr(0, colon);

    if (host.empty()) return {};
    return "https://" + host;
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

    // A profile exists, so the only thing missing is the backend itself.
    return "local repository browsing is not available in this build "
           "(profile found at " + m_home + ")";
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
        std::string origin = seedSpecToHttpsOrigin(entry.get<std::string>());
        if (!origin.empty()) out.push_back(std::move(origin));
    }
    return out;
}

} // namespace radicle
