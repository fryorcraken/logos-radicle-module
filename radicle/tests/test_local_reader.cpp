#include <logos_test.h>

#include "local_reader.h"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <string>
#include <utility>
#include <vector>
#include <sys/stat.h>

using namespace radicle;

// ---------------------------------------------------------------------------
// The FFI boundary itself.
//
// What these can and cannot prove, stated plainly so nobody reads more into a
// green run than is there:
//
// - They DO prove the boundary is real and correctly wired: that the C++ side
//   links the Rust archive, that a call crosses into it, that the string that
//   comes back is owned, NUL-terminated, valid JSON in this module's shape,
//   and that freeing it does not corrupt the heap. Before this milestone every
//   one of these methods returned a canned "unavailable" string without
//   crossing anything, so a passing test here is a behaviour change.
//
// - They do NOT re-prove the *content* of a successful read against real
//   storage. Building a Radicle profile needs a keystore and signed identity
//   documents, which is the `radicle` crate's own job — doing it from C++
//   would mean reimplementing `rad auth`. That coverage lives in
//   `radicle/rust-ffi/tests/` (28 tests over real profiles built through the
//   crate's public API), which is the layer that can create one cheaply.
//
// So: shapes and success paths are pinned in Rust; the wiring and the failure
// paths are pinned here. Neither layer alone is sufficient, which is why both
// exist.
// ---------------------------------------------------------------------------

namespace {

/// A scratch directory that is a plausible path but not a Radicle profile.
std::string scratchPath(const std::string& name)
{
    const char* base = std::getenv("TMPDIR");
    const std::string dir = std::string(base ? base : "/tmp") + "/radicle-reader-" + name;
    ::mkdir(dir.c_str(), 0755);
    return dir;
}

nlohmann::json parse(const std::string& s)
{
    auto j = nlohmann::json::parse(s, nullptr, false);
    LOGOS_ASSERT_FALSE(j.is_discarded());
    return j;
}

/// Every method, called uniformly, so a test can assert a property across the
/// whole surface rather than repeating itself eleven times.
std::vector<std::pair<std::string, std::string>> callEveryMethod(LocalReader& reader)
{
    const std::string rid = "rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5";
    return {
        {"listRepos",   reader.listRepos("all", 0, 10)},
        {"getRepo",     reader.getRepo(rid)},
        {"getTree",     reader.getTree(rid, "", "")},
        {"getBlob",     reader.getBlob(rid, "", "README.md")},
        {"getReadme",   reader.getReadme(rid, "")},
        {"listCommits", reader.listCommits(rid, "", 0, 10)},
        {"getCommit",   reader.getCommit(rid, "")},
        {"listIssues",  reader.listIssues(rid, "", 0, 10)},
        {"getIssue",    reader.getIssue(rid, "abc")},
        {"listPatches", reader.listPatches(rid, "", 0, 10)},
        {"getPatch",    reader.getPatch(rid, "abc")},
    };
}

} // namespace

// ---------------------------------------------------------------------------
// Crossing the boundary at all.
// ---------------------------------------------------------------------------

LOGOS_TEST(every_local_method_returns_parseable_json_from_the_rust_backend)
{
    LocalReader reader{scratchPath("no-profile")};

    // The point is not the *content* — a scratch directory has no storage, so
    // each of these is an error — but that the call reaches Rust, comes back
    // with a heap string this side owns, and that the string is JSON. A
    // mis-linked archive fails to link; a mis-declared signature crashes here.
    for (const auto& [name, body] : callEveryMethod(reader)) {
        LOGOS_ASSERT_FALSE(body.empty());
        const auto j = parse(body);
        LOGOS_ASSERT_TRUE(j.is_object());
        LOGOS_ASSERT_TRUE(j.contains("error"));
        LOGOS_ASSERT_TRUE(j["error"].is_string());
        // The message must say something, not just be present: it is surfaced
        // to the user verbatim.
        LOGOS_ASSERT_FALSE(j["error"].get<std::string>().empty());
    }
}

/// The regression this milestone is: these methods used to return the module's
/// canned "not available in this build" string without touching any backend.
/// If that string ever comes back, the routing has been reverted.
LOGOS_TEST(no_local_method_reports_the_backend_as_missing_from_this_build)
{
    LocalReader reader{scratchPath("not-stubbed")};

    for (const auto& [name, body] : callEveryMethod(reader)) {
        LOGOS_ASSERT_TRUE(body.find("not available in this build") == std::string::npos);
    }
}

/// An empty home must be an error, not a crash and not an empty list. This is
/// the null-ish input the FFI's `read_str` maps to "" on the Rust side, so it
/// exercises that path deliberately.
LOGOS_TEST(an_empty_home_errors_rather_than_crashing)
{
    LocalReader reader{""};

    const auto j = parse(reader.listRepos("all", 0, 10));
    LOGOS_ASSERT_TRUE(j.contains("error"));
    // "no repositories" and "no node" are different answers — an empty items
    // array here would be the wrong one.
    LOGOS_ASSERT_FALSE(j.contains("items"));
}

// ---------------------------------------------------------------------------
// Memory ownership.
// ---------------------------------------------------------------------------

/// Each call allocates on the Rust side and `LocalReader::take` frees it.
/// Repeating the whole surface many times turns a leak or a double-free into
/// something a sanitizer build or the allocator itself will notice, rather
/// than a slow drift nobody attributes to this code.
LOGOS_TEST(repeated_calls_do_not_leak_or_double_free)
{
    LocalReader reader{scratchPath("churn")};

    for (int i = 0; i < 200; ++i) {
        for (const auto& [name, body] : callEveryMethod(reader)) {
            LOGOS_ASSERT_FALSE(body.empty());
        }
    }
}

/// A rid with characters that need care crossing a C string boundary must come
/// back as a normal error, not a truncated or corrupted one.
LOGOS_TEST(an_odd_rid_crosses_the_boundary_intact)
{
    LocalReader reader{scratchPath("odd-rid")};

    for (const std::string& rid : {std::string("not-a-rid"),
                                   std::string(""),
                                   std::string("rad:"),
                                   std::string("rad:z with spaces"),
                                   std::string("rad:zünïcödé")}) {
        const auto j = parse(reader.getRepo(rid));
        LOGOS_ASSERT_TRUE(j.contains("error"));
        LOGOS_ASSERT_TRUE(j["error"].is_string());
    }
}
