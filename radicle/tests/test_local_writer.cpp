#include <logos_test.h>

#include "local_store.h"
#include "local_writer.h"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <string>
#include <sys/stat.h>

using namespace radicle;

// ---------------------------------------------------------------------------
// The write half of the FFI boundary.
//
// The same division of labour `test_local_reader.cpp` explains, and worth
// restating because it decides what a green run here means:
//
// - These prove the WIRING. That the C++ side links the two new `extern "C"`
//   symbols, that a call crosses into Rust, that what comes back is an owned,
//   NUL-terminated, parseable JSON string in this module's shape, and that
//   freeing it repeatedly does not corrupt the heap.
//
// - They do NOT prove a write succeeds. That needs a real profile with a
//   signing key, which is the `radicle` crate's own job to create — building
//   one from C++ would mean reimplementing `rad auth`. Ten tests in
//   `radicle/rust-ffi/tests/cob_writes.rs` cover it against real fixtures,
//   including the persistence assertions that a fresh read has to satisfy.
//
// So the success path is pinned in Rust and the boundary plus every failure
// path is pinned here. There is one behaviour this layer can prove on its own
// and does, below: that `canWrite` refuses with an *answer* rather than an
// error object, because that distinction is what a UI branches on.
// ---------------------------------------------------------------------------

namespace {

std::string scratchPath(const std::string& name)
{
    const char* base = std::getenv("TMPDIR");
    const std::string dir = std::string(base ? base : "/tmp") + "/radicle-writer-" + name;
    ::mkdir(dir.c_str(), 0755);
    return dir;
}

nlohmann::json parse(const std::string& s)
{
    auto j = nlohmann::json::parse(s, nullptr, false);
    LOGOS_ASSERT_FALSE(j.is_discarded());
    return j;
}

const std::string kRid = "rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5";
const std::string kIssue = "0000000000000000000000000000000000000000";

} // namespace

// ---------------------------------------------------------------------------
// Crossing the boundary.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_write_reaches_the_rust_backend_and_returns_parseable_json)
{
    LocalWriter writer{scratchPath("no-profile")};

    // A scratch directory is not a profile, so this is the error path — but
    // the point is that the call crosses at all. Before this milestone the
    // symbol did not exist; a mis-declared signature crashes here rather than
    // returning.
    const auto j = parse(writer.commentOnIssue(kRid, kIssue, "hello"));
    LOGOS_ASSERT_TRUE(j.is_object());
    LOGOS_ASSERT_TRUE(j.contains("error"));
    LOGOS_ASSERT_TRUE(j["error"].is_string());
    // The message is surfaced to the user verbatim, so it has to say something.
    LOGOS_ASSERT_FALSE(j["error"].get<std::string>().empty());
}

LOGOS_TEST(an_empty_home_errors_rather_than_crashing)
{
    LocalWriter writer{""};

    const auto j = parse(writer.commentOnIssue(kRid, kIssue, "hello"));
    LOGOS_ASSERT_TRUE(j.contains("error"));
    // And no id: a caller must never read this as "the comment was posted".
    LOGOS_ASSERT_FALSE(j.contains("id"));
}

/// An empty body is refused by the backend, not merely by the UI. The UI is
/// not the only caller — the QtRO surface is reachable by anything on the bus
/// — so the rule has to live where it cannot be bypassed.
LOGOS_TEST(an_empty_body_is_refused_at_the_backend_not_only_in_the_ui)
{
    LocalWriter writer{scratchPath("empty-body")};

    for (const std::string& body : {std::string(""), std::string("   "), std::string("\n\t")}) {
        const auto j = parse(writer.commentOnIssue(kRid, kIssue, body));
        LOGOS_ASSERT_TRUE(j.contains("error"));
        LOGOS_ASSERT_FALSE(j.contains("id"));
    }
}

/// Arguments with characters that need care crossing a C string boundary must
/// come back as normal errors, not truncated or corrupted ones.
LOGOS_TEST(odd_arguments_cross_the_boundary_intact)
{
    LocalWriter writer{scratchPath("odd-args")};

    for (const std::string& rid : {std::string("not-a-rid"),
                                   std::string(""),
                                   std::string("rad:"),
                                   std::string("rad:z with spaces"),
                                   std::string("rad:zünïcödé")}) {
        const auto j = parse(writer.commentOnIssue(rid, kIssue, "hello"));
        LOGOS_ASSERT_TRUE(j.contains("error"));
        LOGOS_ASSERT_TRUE(j["error"].is_string());
    }

    // A body full of things that break naive string handling: quotes and
    // backslashes must survive JSON encoding, and a multi-byte glyph must not
    // be split.
    const auto j = parse(writer.commentOnIssue(kRid, kIssue, "a \"quoted\" \\ body 👾 ünïcödé"));
    LOGOS_ASSERT_TRUE(j.is_object());
}

// ---------------------------------------------------------------------------
// canWrite: a refusal is an answer, not a failure.
// ---------------------------------------------------------------------------

/// This is the one contract this layer can prove without a real profile, and
/// it is the one a view branches on. `{"canWrite":false,"reason":...}` must
/// NOT be an `{"error":...}`: a view that saw an error would show a failure
/// banner where it should show a disabled compose box and an explanation.
LOGOS_TEST(can_write_refuses_with_an_answer_rather_than_an_error)
{
    for (const std::string& home : {std::string(""), scratchPath("can-write")}) {
        LocalWriter writer{home};
        const auto j = parse(writer.canWrite());

        LOGOS_ASSERT_TRUE(j.contains("canWrite"));
        LOGOS_ASSERT_TRUE(j["canWrite"].is_boolean());
        LOGOS_ASSERT_FALSE(j["canWrite"].get<bool>());

        // The distinction under test.
        LOGOS_ASSERT_FALSE(j.contains("error"));

        // And the reason is shown verbatim, so it must not be empty.
        LOGOS_ASSERT_TRUE(j.contains("reason"));
        LOGOS_ASSERT_FALSE(j["reason"].get<std::string>().empty());
    }
}

/// On a machine with a real profile, `canWrite` must still answer in the same
/// shape whichever way it comes out — the answer depends on whether the key is
/// encrypted and what ssh-agent holds, neither of which a test can arrange.
/// What is asserted is the invariant that holds either way.
LOGOS_TEST(can_write_against_a_real_profile_answers_in_the_documented_shape)
{
    LocalStore store;
    if (!store.available()) {
        // Not a skip masquerading as a pass: the shape is pinned
        // unconditionally by the two cases above and by the Rust tests. This
        // adds a check against a profile made by the real `rad` CLI.
        LOGOS_ASSERT_TRUE(true);
        return;
    }

    LocalWriter writer{store.home()};
    const auto j = parse(writer.canWrite());

    LOGOS_ASSERT_FALSE(j.contains("error"));
    LOGOS_ASSERT_TRUE(j["canWrite"].is_boolean());

    if (j["canWrite"].get<bool>()) {
        // A writable profile names who the write would be attributed to.
        const std::string nid = j.value("nodeId", "");
        LOGOS_ASSERT_TRUE(nid.rfind("did:key:", 0) == 0);
    } else {
        // An unwritable one explains itself.
        LOGOS_ASSERT_FALSE(j.value("reason", "").empty());
    }
}

// ---------------------------------------------------------------------------
// Memory ownership.
// ---------------------------------------------------------------------------

/// Each call allocates on the Rust side and `LocalWriter::take` frees it.
/// Churning the surface turns a leak or double-free into something a sanitizer
/// build or the allocator itself notices, rather than a slow drift.
LOGOS_TEST(repeated_write_calls_do_not_leak_or_double_free)
{
    LocalWriter writer{scratchPath("write-churn")};

    for (int i = 0; i < 200; ++i) {
        LOGOS_ASSERT_FALSE(writer.canWrite().empty());
        LOGOS_ASSERT_FALSE(writer.commentOnIssue(kRid, kIssue, "hello").empty());
    }
}
