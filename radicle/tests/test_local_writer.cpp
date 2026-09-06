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

/// Sets one environment variable for the duration of a test and restores
/// whatever was there — including "nothing", which is a distinct state from
/// "empty" for every resolver in this module. `nullptr` unsets.
struct ScopedEnv {
    std::string name;
    std::string previous;
    bool hadPrevious = false;

    ScopedEnv(const char* variable, const char* value)
        : name(variable)
    {
        if (const char* old = std::getenv(variable)) {
            previous = old;
            hadPrevious = true;
        }
        if (value) ::setenv(variable, value, 1);
        else       ::unsetenv(variable);
    }

    ~ScopedEnv()
    {
        if (hadPrevious) ::setenv(name.c_str(), previous.c_str(), 1);
        else             ::unsetenv(name.c_str());
    }
};

/// A writer over a scratch home with no particular socket.
///
/// Most tests below are about the boundary and the failure paths, where the
/// socket is irrelevant — the write never gets far enough to announce. The
/// tests that ARE about the socket name it explicitly, which is what makes them
/// legible as being about that and not about anything else.
LocalWriter writerFor(const std::string& name)
{
    return LocalWriter{scratchPath(name), ""};
}

} // namespace

// ---------------------------------------------------------------------------
// Crossing the boundary.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_write_reaches_the_rust_backend_and_returns_parseable_json)
{
    auto writer = writerFor("no-profile");

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
    LocalWriter writer{"", ""};

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
    auto writer = writerFor("empty-body");

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
    auto writer = writerFor("odd-args");

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
// createIssue.
// ---------------------------------------------------------------------------

LOGOS_TEST(create_issue_reaches_the_rust_backend_and_returns_parseable_json)
{
    auto writer = writerFor("create-no-profile");

    const auto j = parse(writer.createIssue(kRid, "a title", "a description"));
    LOGOS_ASSERT_TRUE(j.is_object());
    LOGOS_ASSERT_TRUE(j.contains("error"));
    LOGOS_ASSERT_FALSE(j["error"].get<std::string>().empty());
}

/// The title and description rules live in the backend, not only in the UI —
/// the QtRO surface is reachable by anything on the bus, so a rule enforced
/// only in QML is not enforced.
LOGOS_TEST(an_empty_title_or_description_is_refused_at_the_backend)
{
    auto writer = writerFor("create-empty");

    for (const std::string& title : {std::string(""), std::string("  ")}) {
        const auto j = parse(writer.createIssue(kRid, title, "a description"));
        LOGOS_ASSERT_TRUE(j.contains("error"));
        LOGOS_ASSERT_FALSE(j.contains("id"));
    }

    for (const std::string& body : {std::string(""), std::string("\n\t")}) {
        const auto j = parse(writer.createIssue(kRid, "a title", body));
        LOGOS_ASSERT_TRUE(j.contains("error"));
        LOGOS_ASSERT_FALSE(j.contains("id"));
    }
}

/// A newline in the title is rejected outright by the crate rather than
/// trimmed, and it is reachable by pasting a line of text into a one-line
/// field. The message has to name the fix, because the crate's own
/// ("invalid characters in title") names neither the character nor what to do.
LOGOS_TEST(a_multi_line_title_is_refused_with_a_message_naming_the_fix)
{
    auto writer = writerFor("create-multiline");

    for (const std::string& title : {std::string("two\nlines"),
                                     std::string("carriage\rreturn")}) {
        const auto j = parse(writer.createIssue(kRid, title, "a description"));
        LOGOS_ASSERT_TRUE(j.contains("error"));
        const std::string message = j["error"].get<std::string>();
        LOGOS_ASSERT_TRUE(message.find("single line") != std::string::npos);
    }
}

LOGOS_TEST(create_issue_arguments_cross_the_boundary_intact)
{
    auto writer = writerFor("create-odd-args");

    // Quotes, backslashes and multi-byte glyphs must survive JSON encoding in
    // both the title and the description without truncation or corruption.
    const auto j = parse(writer.createIssue(kRid,
                                            "a \"quoted\" title 👾",
                                            "a \\ description with ünïcödé"));
    LOGOS_ASSERT_TRUE(j.is_object());
    LOGOS_ASSERT_TRUE(j.contains("error"));
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
        LocalWriter writer{home, ""};
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

    LocalWriter writer{store.home(), store.socket()};
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
// The control socket: the read path and the write path must agree on it.
// ---------------------------------------------------------------------------

/// The bug this pins is a **disagreement**, not a wrong constant, which is why
/// it needs a test that compares two things rather than checking one.
///
/// `LocalStore` resolves the socket, preferring `$XDG_RUNTIME_DIR/radicle-*.sock`
/// and honouring the module's own `radSocket` setting; that is what
/// `nodeRunning()` probes and what the UI reports. The write path's announce
/// step used to derive its own — `<home>/node/control.sock`, and after a first
/// partial fix, `RAD_SOCKET` from the environment. Neither sees the runtime-dir
/// preference or the setting, so **on any machine with a runtime dir the two
/// disagreed by default**, and nothing said so: an unannounced write is
/// legitimately not an error, so the comment saved and the network never heard.
///
/// The environment here is set up so the preferred path is chosen — a runtime
/// dir present and RAD_SOCKET absent — which is precisely the configuration the
/// old code got wrong and every other configuration it got right.
LOGOS_TEST(the_writer_announces_to_the_same_socket_the_store_probes)
{
    ScopedEnv runtimeDir{"XDG_RUNTIME_DIR", "/run/user/4242"};
    ScopedEnv radSocket{"RAD_SOCKET", nullptr};   // unset: the interesting case

    const NodePaths paths = resolvePathsFromEnv("/home/somebody/.radicle", "", "");
    LocalStore store{paths};

    // Built exactly as RadicleImpl builds it.
    LocalWriter writer{store.home(), store.socket()};

    LOGOS_ASSERT_EQ(writer.socket(), store.socket());

    // And the resolved value really is the runtime-dir one, not the home-derived
    // fallback — otherwise the equality above would hold trivially against the
    // very code being guarded against.
    LOGOS_ASSERT_EQ(store.socket(), std::string("/run/user/4242/radicle.sock"));
    LOGOS_ASSERT_TRUE(writer.socket().find(store.home()) == std::string::npos);
}

/// The other half: a writer must carry whatever socket it was handed, verbatim.
/// Input-dependent, so a writer that ignored the argument and re-derived from
/// the home would fail here rather than passing on a lucky match.
LOGOS_TEST(a_writer_carries_the_socket_it_was_given_rather_than_deriving_one)
{
    LocalWriter a{"/home/alice/.radicle", "/run/user/1000/radicle-alice.sock"};
    LocalWriter b{"/home/alice/.radicle", "/run/user/1000/radicle-bob.sock"};

    LOGOS_ASSERT_EQ(a.socket(), std::string("/run/user/1000/radicle-alice.sock"));
    LOGOS_ASSERT_EQ(b.socket(), std::string("/run/user/1000/radicle-bob.sock"));
    // Same home, two sockets: a writer deriving from the home cannot do this.
    LOGOS_ASSERT_TRUE(a.socket() != b.socket());
}

// ---------------------------------------------------------------------------
// Memory ownership.
// ---------------------------------------------------------------------------

/// Each call allocates on the Rust side and `LocalWriter::take` frees it.
/// Churning the surface turns a leak or double-free into something a sanitizer
/// build or the allocator itself notices, rather than a slow drift.
LOGOS_TEST(repeated_write_calls_do_not_leak_or_double_free)
{
    auto writer = writerFor("write-churn");

    for (int i = 0; i < 200; ++i) {
        LOGOS_ASSERT_FALSE(writer.canWrite().empty());
        LOGOS_ASSERT_FALSE(writer.commentOnIssue(kRid, kIssue, "hello").empty());
        LOGOS_ASSERT_FALSE(writer.createIssue(kRid, "a title", "a body").empty());
    }
}
