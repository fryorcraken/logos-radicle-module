#include "node_config.h"

#include "radicle_ffi.h"

#include <nlohmann/json.hpp>

#include <utility>

namespace radicle {

namespace {

/// Take ownership of a string the Rust side allocated, copy it into a
/// `std::string`, and free the original.
///
/// Deliberately a duplicate of the same helper in `local_reader.cpp`,
/// `local_writer.cpp` and `embedded_node.cpp` rather than a shared one, for the
/// reason stated there: it is four lines, and each file owning its own keeps the
/// ownership rule for a boundary visible in the file that crosses it. Getting it
/// wrong here is a leak or a double-free, not a wrong answer.
std::string take(char* owned)
{
    if (!owned)
        return nlohmann::json{{"error", "local backend returned no data"}}.dump();

    std::string out(owned);
    radicle_free_string(owned);
    return out;
}

} // namespace

NodeConfig::NodeConfig(std::string home)
    : m_home(std::move(home))
{
}

std::string NodeConfig::get()
{
    return take(radicle_node_get_config(m_home.c_str()));
}

std::string NodeConfig::set(const std::string& changes)
{
    return take(radicle_node_set_config(m_home.c_str(), changes.c_str()));
}

std::string NodeConfig::listSeeded()
{
    return take(radicle_node_list_seeded(m_home.c_str()));
}

std::string NodeConfig::seed(const std::string& rid, const std::string& scope)
{
    return take(radicle_node_seed(m_home.c_str(), rid.c_str(), scope.c_str()));
}

std::string NodeConfig::unseed(const std::string& rid)
{
    return take(radicle_node_unseed(m_home.c_str(), rid.c_str()));
}

} // namespace radicle
