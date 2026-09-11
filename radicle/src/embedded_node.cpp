#include "embedded_node.h"

#include "radicle_ffi.h"

#include <nlohmann/json.hpp>

namespace radicle {

namespace {

/// Take ownership of a string the Rust side allocated, copy it into a
/// `std::string`, and free the original.
///
/// Deliberately a duplicate of the same helper in `local_reader.cpp` and
/// `local_writer.cpp` rather than a shared one, for the reason stated there: it
/// is four lines, and each file owning its own keeps the ownership rule for a
/// boundary visible in the file that crosses it. Getting it wrong here is a leak
/// or a double-free, not a wrong answer.
std::string take(char* owned)
{
    if (!owned)
        return nlohmann::json{{"error", "local backend returned no data"}}.dump();

    std::string out(owned);
    radicle_free_string(owned);
    return out;
}

} // namespace

std::string EmbeddedNode::start(const std::string& home, const std::string& socket,
                                const std::string& passphrase)
{
    return take(radicle_node_start(home.c_str(), socket.c_str(), passphrase.c_str()));
}

std::string EmbeddedNode::stop()
{
    return take(radicle_node_stop());
}

std::string EmbeddedNode::status()
{
    return take(radicle_node_status());
}

} // namespace radicle
