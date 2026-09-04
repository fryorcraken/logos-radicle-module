#include "local_writer.h"

#include "radicle_ffi.h"

#include <nlohmann/json.hpp>

#include <utility>

namespace radicle {

namespace {

/// Take ownership of a string the Rust side allocated, copy it into a
/// `std::string`, and free the original.
///
/// Deliberately a duplicate of `local_reader.cpp`'s `take()` rather than a
/// shared helper. It is four lines, and each file owning its own means the
/// ownership rule for a boundary is visible in the file that crosses it —
/// which matters more here than the duplication costs, because getting it
/// wrong is a leak or a double-free rather than a wrong answer.
std::string take(char* owned)
{
    if (!owned)
        return nlohmann::json{{"error", "local backend returned no data"}}.dump();

    std::string out(owned);
    radicle_free_string(owned);
    return out;
}

} // namespace

LocalWriter::LocalWriter(std::string home)
    : m_home(std::move(home))
{
}

std::string LocalWriter::canWrite()
{
    return take(radicle_local_can_write(m_home.c_str()));
}

std::string LocalWriter::commentOnIssue(const std::string& rid, const std::string& id,
                                        const std::string& body)
{
    return take(radicle_local_comment_on_issue(m_home.c_str(), rid.c_str(),
                                               id.c_str(), body.c_str()));
}

} // namespace radicle
