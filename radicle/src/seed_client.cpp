#include "seed_client.h"

#include "http_client.h"

#include <algorithm>
#include <cctype>
#include <sstream>
#include <utility>

namespace radicle {

namespace {

/// Length of a full hex git object id. The seed API accepts nothing shorter.
constexpr size_t kFullShaLen = 40;

bool isFullSha(const std::string& s)
{
    return s.size() == kFullShaLen
        && std::all_of(s.begin(), s.end(), [](unsigned char c) {
               return std::isxdigit(c) != 0;
           });
}

std::string trimTrailingSlash(std::string s)
{
    while (!s.empty() && s.back() == '/') s.pop_back();
    return s;
}

/// Encode a slash-separated path, preserving the separators.
std::string encodePath(const std::string& path)
{
    std::string out;
    std::string segment;
    std::istringstream stream(path);
    while (std::getline(stream, segment, '/')) {
        if (segment.empty()) continue;
        if (!out.empty()) out += '/';
        out += urlEncode(segment);
    }
    return out;
}

} // namespace

nlohmann::json makeError(const std::string& msg)
{
    return nlohmann::json{{"error", msg}};
}

bool isError(const nlohmann::json& j)
{
    return j.is_object() && j.contains("error");
}

std::string urlEncode(const std::string& s)
{
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            out += static_cast<char>(c);
        } else {
            out += '%';
            out += hex[c >> 4];
            out += hex[c & 0x0F];
        }
    }
    return out;
}

nlohmann::json paginate(const nlohmann::json& arr, int64_t page, int64_t perPage)
{
    if (isError(arr)) return arr;
    if (!arr.is_array()) return makeError("expected a JSON array from seed");

    const int64_t count = static_cast<int64_t>(arr.size());
    return nlohmann::json{
        {"items", arr},
        {"page", page},
        {"hasMore", perPage > 0 && count >= perPage},
    };
}

SeedClient::SeedClient(std::string seedUrl)
    : m_seedUrl(trimTrailingSlash(std::move(seedUrl)))
{
}

void SeedClient::setTransport(Transport transport)
{
    m_transport = std::move(transport);
}

void SeedClient::setSeedUrl(const std::string& seedUrl)
{
    m_seedUrl = trimTrailingSlash(seedUrl);
    m_apiVersion.clear();
    m_nid.clear();
    m_reachable = false;
}

nlohmann::json SeedClient::getJson(const std::string& path)
{
    const std::string url = m_seedUrl + "/api/v1" + path;
    const HttpResponse res = m_transport ? m_transport(url) : httpGet(url);

    if (!res.ok) {
        m_reachable = false;
        // The seed reports its own errors as JSON; surface that message when
        // present, since it is far more useful than a bare status code.
        if (!res.body.empty()) {
            auto parsed = nlohmann::json::parse(res.body, nullptr, false);
            if (!parsed.is_discarded() && parsed.is_object() && parsed.contains("error")) {
                return makeError(parsed["error"].get<std::string>());
            }
        }
        return makeError(res.error.empty() ? "request failed" : res.error);
    }

    auto parsed = nlohmann::json::parse(res.body, nullptr, false);
    if (parsed.is_discarded()) {
        m_reachable = false;
        return makeError("malformed JSON from seed");
    }

    m_reachable = true;
    return parsed;
}

nlohmann::json SeedClient::probe()
{
    nlohmann::json index = getJson("");
    if (isError(index)) return index;

    if (index.contains("apiVersion") && index["apiVersion"].is_string())
        m_apiVersion = index["apiVersion"].get<std::string>();
    if (index.contains("nid") && index["nid"].is_string())
        m_nid = index["nid"].get<std::string>();

    return index;
}

nlohmann::json SeedClient::listRepos(const std::string& query, int64_t page, int64_t perPage)
{
    std::string path = "/repos?page=" + std::to_string(page)
                     + "&perPage=" + std::to_string(perPage);
    if (!query.empty()) path += "&query=" + urlEncode(query);
    return getJson(path);
}

nlohmann::json SeedClient::getRepo(const std::string& rid)
{
    return getJson("/repos/" + urlEncode(rid));
}

nlohmann::json branchesFrom(const nlohmann::json& repo)
{
    if (isError(repo)) return repo;

    // Same map resolveSha() reads: refs.refs is "refs/heads/main" -> sha,
    // plus tag refs under the same object that this deliberately ignores —
    // branches and tags are different concepts and a picker for one should
    // not silently include the other.
    static const std::string kHeadsPrefix = "refs/heads/";
    const auto& refs = repo.value("refs", nlohmann::json::object());
    const auto& inner = refs.value("refs", nlohmann::json::object());

    nlohmann::json items = nlohmann::json::array();
    for (const auto& [key, value] : inner.items()) {
        if (key.rfind(kHeadsPrefix, 0) != 0) continue;   // not a branch ref
        if (!value.is_string()) continue;
        items.push_back({{"name", key.substr(kHeadsPrefix.size())},
                          {"head", value.get<std::string>()}});
    }

    const auto& payloads = repo.value("payloads", nlohmann::json::object());
    const auto& project = payloads.value("xyz.radicle.project", nlohmann::json::object());
    const std::string defaultBranch =
        project.value("data", nlohmann::json::object()).value("defaultBranch", "");

    return nlohmann::json{{"items", items}, {"default", defaultBranch}};
}

nlohmann::json branchesFromRawJson(const std::string& raw)
{
    const auto repo = nlohmann::json::parse(raw, nullptr, false);
    if (repo.is_discarded()) return makeError("malformed reply from local storage");
    return branchesFrom(repo);
}

nlohmann::json writeCapabilityFrom(const std::string& rawProbe)
{
    const auto probe = nlohmann::json::parse(rawProbe, nullptr, false);
    if (probe.is_discarded()) {
        return nlohmann::json{
            {"canWrite", false},
            {"writeUnavailableReason", "the local backend gave an unreadable answer about signing"},
        };
    }

    const bool canWrite = probe.value("canWrite", false);
    return nlohmann::json{
        {"canWrite", canWrite},
        {"writeUnavailableReason", canWrite ? std::string{} : probe.value("reason", "")},
    };
}

nlohmann::json SeedClient::listBranches(const std::string& rid)
{
    return branchesFrom(getRepo(rid));
}

std::string SeedClient::resolveSha(const std::string& rid, const std::string& ref)
{
    if (isFullSha(ref)) return ref;

    const nlohmann::json repo = getRepo(rid);
    if (isError(repo)) return {};

    // Named ref: look it up in the repo's canonical refs first.
    if (!ref.empty()) {
        const auto& refs = repo.value("refs", nlohmann::json::object());
        const auto& inner = refs.value("refs", nlohmann::json::object());
        for (const std::string& prefix : {std::string("refs/heads/"), std::string("")}) {
            const std::string key = prefix + ref;
            if (inner.contains(key) && inner[key].is_string())
                return inner[key].get<std::string>();
        }
    }

    // Empty ref, or a name we could not match: fall back to the repo head.
    const auto& payloads = repo.value("payloads", nlohmann::json::object());
    const auto& project = payloads.value("xyz.radicle.project", nlohmann::json::object());
    const auto& meta = project.value("meta", nlohmann::json::object());
    if (meta.contains("head") && meta["head"].is_string())
        return meta["head"].get<std::string>();

    return {};
}

nlohmann::json SeedClient::getTree(const std::string& rid, const std::string& sha,
                                   const std::string& path)
{
    const std::string full = resolveSha(rid, sha);
    if (full.empty()) return makeError("could not resolve '" + sha + "' to a commit");

    // The root tree endpoint requires a trailing slash; subpaths must not have
    // one. Getting this wrong yields a 404 with no explanation.
    const std::string encoded = encodePath(path);
    const std::string suffix = encoded.empty() ? "/" : ("/" + encoded);
    return getJson("/repos/" + urlEncode(rid) + "/tree/" + full + suffix);
}

nlohmann::json SeedClient::getBlob(const std::string& rid, const std::string& sha,
                                   const std::string& path)
{
    if (path.empty()) return makeError("blob path is required");

    const std::string full = resolveSha(rid, sha);
    if (full.empty()) return makeError("could not resolve '" + sha + "' to a commit");

    return getJson("/repos/" + urlEncode(rid) + "/blob/" + full + "/" + encodePath(path));
}

nlohmann::json SeedClient::getReadme(const std::string& rid, const std::string& sha)
{
    const std::string full = resolveSha(rid, sha);
    if (full.empty()) return makeError("could not resolve '" + sha + "' to a commit");

    return getJson("/repos/" + urlEncode(rid) + "/readme/" + full);
}

nlohmann::json SeedClient::listCommits(const std::string& rid, const std::string& sha,
                                       int64_t page, int64_t perPage)
{
    std::string path = "/repos/" + urlEncode(rid) + "/commits?page=" + std::to_string(page)
                     + "&perPage=" + std::to_string(perPage);
    if (!sha.empty()) {
        const std::string full = resolveSha(rid, sha);
        if (full.empty()) return makeError("could not resolve '" + sha + "' to a commit");
        path += "&parent=" + full;
    }
    return getJson(path);
}

nlohmann::json SeedClient::getCommit(const std::string& rid, const std::string& sha)
{
    const std::string full = resolveSha(rid, sha);
    if (full.empty()) return makeError("could not resolve '" + sha + "' to a commit");

    return getJson("/repos/" + urlEncode(rid) + "/commits/" + full);
}

nlohmann::json SeedClient::listIssues(const std::string& rid, const std::string& status,
                                      int64_t page, int64_t perPage)
{
    std::string path = "/repos/" + urlEncode(rid) + "/issues?page=" + std::to_string(page)
                     + "&perPage=" + std::to_string(perPage);
    if (!status.empty()) path += "&status=" + urlEncode(status);
    return getJson(path);
}

nlohmann::json SeedClient::getIssue(const std::string& rid, const std::string& id)
{
    return getJson("/repos/" + urlEncode(rid) + "/issues/" + urlEncode(id));
}

nlohmann::json SeedClient::listPatches(const std::string& rid, const std::string& status,
                                       int64_t page, int64_t perPage)
{
    std::string path = "/repos/" + urlEncode(rid) + "/patches?page=" + std::to_string(page)
                     + "&perPage=" + std::to_string(perPage);
    if (!status.empty()) path += "&status=" + urlEncode(status);
    return getJson(path);
}

nlohmann::json SeedClient::getPatch(const std::string& rid, const std::string& id)
{
    return getJson("/repos/" + urlEncode(rid) + "/patches/" + urlEncode(id));
}

} // namespace radicle
