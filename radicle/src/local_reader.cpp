#include "local_reader.h"

#include "radicle_ffi.h"

#include <nlohmann/json.hpp>

#include <utility>

namespace radicle {

namespace {

/// Take ownership of a string the Rust side allocated, copy it into a
/// `std::string`, and free the original.
///
/// Every FFI call in this file goes through here, so there is exactly one
/// place that can leak or double-free, and it is four lines long. A NULL
/// return can only mean the allocation itself failed, which is reported in the
/// module's own error shape rather than as an empty string a caller would
/// parse as malformed JSON.
std::string take(char* owned)
{
    if (!owned)
        return nlohmann::json{{"error", "local backend returned no data"}}.dump();

    std::string out(owned);
    radicle_free_string(owned);
    return out;
}

} // namespace

LocalReader::LocalReader(std::string home)
    : m_home(std::move(home))
{
}

std::string LocalReader::listRepos(const std::string& scope, int64_t page, int64_t perPage)
{
    return take(radicle_local_list_repos(m_home.c_str(), scope.c_str(), page, perPage));
}

std::string LocalReader::getRepo(const std::string& rid)
{
    return take(radicle_local_get_repo(m_home.c_str(), rid.c_str()));
}

std::string LocalReader::getTree(const std::string& rid, const std::string& sha,
                                 const std::string& path)
{
    return take(radicle_local_get_tree(m_home.c_str(), rid.c_str(), sha.c_str(), path.c_str()));
}

std::string LocalReader::getBlob(const std::string& rid, const std::string& sha,
                                 const std::string& path)
{
    return take(radicle_local_get_blob(m_home.c_str(), rid.c_str(), sha.c_str(), path.c_str()));
}

std::string LocalReader::getReadme(const std::string& rid, const std::string& sha)
{
    return take(radicle_local_get_readme(m_home.c_str(), rid.c_str(), sha.c_str()));
}

std::string LocalReader::listCommits(const std::string& rid, const std::string& sha,
                                     int64_t page, int64_t perPage)
{
    return take(radicle_local_list_commits(m_home.c_str(), rid.c_str(), sha.c_str(),
                                           page, perPage));
}

std::string LocalReader::getCommit(const std::string& rid, const std::string& sha)
{
    return take(radicle_local_get_commit(m_home.c_str(), rid.c_str(), sha.c_str()));
}

std::string LocalReader::listIssues(const std::string& rid, const std::string& status,
                                    int64_t page, int64_t perPage)
{
    return take(radicle_local_list_issues(m_home.c_str(), rid.c_str(), status.c_str(),
                                          page, perPage));
}

std::string LocalReader::getIssue(const std::string& rid, const std::string& id)
{
    return take(radicle_local_get_issue(m_home.c_str(), rid.c_str(), id.c_str()));
}

std::string LocalReader::listPatches(const std::string& rid, const std::string& status,
                                     int64_t page, int64_t perPage)
{
    return take(radicle_local_list_patches(m_home.c_str(), rid.c_str(), status.c_str(),
                                           page, perPage));
}

std::string LocalReader::getPatch(const std::string& rid, const std::string& id)
{
    return take(radicle_local_get_patch(m_home.c_str(), rid.c_str(), id.c_str()));
}

} // namespace radicle
