#include <logos_test.h>

#include "local_store.h"

#include <cstdlib>
#include <fstream>
#include <string>
#include <sys/stat.h>

using namespace radicle;

namespace {

/// Points RAD_HOME at a scratch directory for the duration of a test, so the
/// developer's real ~/.radicle is never read or written.
struct ScopedRadHome {
    std::string dir;
    std::string previous;
    bool hadPrevious = false;

    explicit ScopedRadHome(const std::string& name)
    {
        const char* base = std::getenv("TMPDIR");
        dir = std::string(base ? base : "/tmp") + "/radicle-test-" + name;
        ::mkdir(dir.c_str(), 0755);

        if (const char* old = std::getenv("RAD_HOME")) {
            previous = old;
            hadPrevious = true;
        }
        ::setenv("RAD_HOME", dir.c_str(), 1);
    }

    ~ScopedRadHome()
    {
        if (hadPrevious) ::setenv("RAD_HOME", previous.c_str(), 1);
        else             ::unsetenv("RAD_HOME");
    }

    void makeStorage()  { ::mkdir((dir + "/storage").c_str(), 0755); }

    void writeConfig(const std::string& json)
    {
        std::ofstream out(dir + "/config.json");
        out << json;
    }
};

} // namespace

// ---------------------------------------------------------------------------
// Availability.
//
// "No local node" and "a local node with no repos" are different answers and a
// view must be able to tell them apart, so availability is explicit rather
// than inferred from an empty list.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_directory_without_storage_is_not_a_radicle_profile)
{
    ScopedRadHome home("no-storage");
    LocalStore store;
    LOGOS_ASSERT_FALSE(store.available());
}

LOGOS_TEST(a_directory_with_storage_is_a_radicle_profile)
{
    ScopedRadHome home("with-storage");
    home.makeStorage();
    LocalStore store;
    LOGOS_ASSERT_TRUE(store.available());
    LOGOS_ASSERT_EQ(store.home(), home.dir);
}

LOGOS_TEST(the_unavailable_reason_names_the_path_it_looked_at)
{
    ScopedRadHome home("reason");
    LocalStore store;
    // The message is shown to a user verbatim, so it must say where we looked.
    LOGOS_ASSERT_CONTAINS(store.unavailableReason(), home.dir);
}

LOGOS_TEST(a_missing_node_socket_means_the_node_is_not_running)
{
    ScopedRadHome home("no-socket");
    home.makeStorage();
    LocalStore store;
    LOGOS_ASSERT_FALSE(store.nodeRunning());
}

// ---------------------------------------------------------------------------
// Preferred seeds.
//
// config.json records seeds as peer-to-peer specs (`nid@host:port`), but the
// JSON API we proxy to is HTTPS on the same host — so they need translating,
// and this is what feeds the seed picker.
// ---------------------------------------------------------------------------

LOGOS_TEST(preferred_seeds_convert_p2p_specs_to_https_origins)
{
    ScopedRadHome home("seeds");
    home.makeStorage();
    home.writeConfig(R"({"preferredSeeds":[
        "z6MkrLMM@iris.radicle.network:8776",
        "z6Mkmqog@rosa.radicle.network:8776"]})");

    LocalStore store;
    const auto seeds = store.preferredSeedUrls();

    LOGOS_ASSERT_EQ(seeds.size(), size_t(2));
    LOGOS_ASSERT_EQ(seeds[0], std::string("https://iris.radicle.network"));
    LOGOS_ASSERT_EQ(seeds[1], std::string("https://rosa.radicle.network"));
}

LOGOS_TEST(a_seed_spec_without_a_node_id_still_yields_a_host)
{
    ScopedRadHome home("seeds-bare");
    home.makeStorage();
    home.writeConfig(R"({"preferredSeeds":["seed.example.test:8776"]})");

    LocalStore store;
    const auto seeds = store.preferredSeedUrls();
    LOGOS_ASSERT_EQ(seeds.size(), size_t(1));
    LOGOS_ASSERT_EQ(seeds[0], std::string("https://seed.example.test"));
}

LOGOS_TEST(a_missing_config_yields_no_seeds_rather_than_failing)
{
    ScopedRadHome home("no-config");
    home.makeStorage();
    LocalStore store;
    LOGOS_ASSERT_TRUE(store.preferredSeedUrls().empty());
}

LOGOS_TEST(malformed_config_json_yields_no_seeds_rather_than_failing)
{
    ScopedRadHome home("bad-config");
    home.makeStorage();
    home.writeConfig("{ this is not json");

    LocalStore store;
    LOGOS_ASSERT_TRUE(store.preferredSeedUrls().empty());
}

LOGOS_TEST(a_config_without_preferred_seeds_yields_none)
{
    ScopedRadHome home("empty-config");
    home.makeStorage();
    home.writeConfig(R"({"node":{"alias":"someone"}})");

    LocalStore store;
    LOGOS_ASSERT_TRUE(store.preferredSeedUrls().empty());
}

LOGOS_TEST(seeds_are_not_read_when_there_is_no_profile)
{
    ScopedRadHome home("no-profile-seeds");
    // config.json present but no storage/ — not a profile, so report nothing.
    home.writeConfig(R"({"preferredSeeds":["z6Mk@iris.radicle.network:8776"]})");

    LocalStore store;
    LOGOS_ASSERT_FALSE(store.available());
    LOGOS_ASSERT_TRUE(store.preferredSeedUrls().empty());
}

// ---------------------------------------------------------------------------
// Path resolution.
//
// Every case below passes its inputs explicitly rather than through setenv, so
// each precedence branch is pinned by a DIFFERENT expected answer. That is the
// point: a resolver that ignored its arguments and always returned
// `$HOME/.radicle` would satisfy a test that only ever supplies one input, and
// this repo has shipped exactly that shape of test before.
// ---------------------------------------------------------------------------

LOGOS_TEST(an_explicit_home_wins_over_both_environment_values)
{
    // All three inputs are distinct, so the assertion says which one was used.
    LOGOS_ASSERT_EQ(resolveHome("/chosen", "/from-rad-home", "/user"),
                    std::string("/chosen"));
}

LOGOS_TEST(rad_home_wins_over_the_user_home_when_no_explicit_home_is_set)
{
    LOGOS_ASSERT_EQ(resolveHome("", "/from-rad-home", "/user"),
                    std::string("/from-rad-home"));
}

LOGOS_TEST(the_user_home_is_the_last_resort_and_gains_a_dot_radicle_suffix)
{
    LOGOS_ASSERT_EQ(resolveHome("", "", "/user"), std::string("/user/.radicle"));
}

LOGOS_TEST(no_home_at_all_resolves_to_empty_rather_than_a_bare_dot_radicle)
{
    // "/.radicle" would be a plausible-looking path pointing at the filesystem
    // root — worse than admitting nothing was found.
    LOGOS_ASSERT_TRUE(resolveHome("", "", "").empty());
}

LOGOS_TEST(an_explicit_socket_wins_over_every_other_source)
{
    LOGOS_ASSERT_EQ(resolveSocket("/chosen.sock", "/env.sock", "/run/user/1000",
                                  "alice", "/home/u/.radicle"),
                    std::string("/chosen.sock"));
}

LOGOS_TEST(rad_socket_wins_over_the_runtime_dir)
{
    LOGOS_ASSERT_EQ(resolveSocket("", "/env.sock", "/run/user/1000",
                                  "alice", "/home/u/.radicle"),
                    std::string("/env.sock"));
}

LOGOS_TEST(the_runtime_dir_is_preferred_over_deriving_the_socket_from_the_home)
{
    // This is the constraint the whole design turns on: the socket must NOT
    // follow the home, because a per-profile data dir blows the 108-byte cap.
    LOGOS_ASSERT_EQ(resolveSocket("", "", "/run/user/1000", "alice",
                                  "/home/u/.radicle"),
                    std::string("/run/user/1000/radicle-alice.sock"));
}

LOGOS_TEST(two_profiles_get_two_sockets_in_the_same_runtime_dir)
{
    // Input-dependent on purpose: a resolver ignoring `profile` would return
    // the same path for both, and both Basecamp profiles would then talk to
    // whichever node bound it first.
    const std::string alice =
        resolveSocket("", "", "/run/user/1000", "alice", "/home/u/.radicle");
    const std::string bob =
        resolveSocket("", "", "/run/user/1000", "bob", "/home/u/.radicle");

    LOGOS_ASSERT_EQ(alice, std::string("/run/user/1000/radicle-alice.sock"));
    LOGOS_ASSERT_EQ(bob, std::string("/run/user/1000/radicle-bob.sock"));
    LOGOS_ASSERT_TRUE(alice != bob);
}

LOGOS_TEST(with_no_runtime_dir_the_socket_falls_back_to_the_crates_own_default)
{
    // Attach mode against a hand-run `rad` node has to still find its socket.
    LOGOS_ASSERT_EQ(resolveSocket("", "", "", "alice", "/home/u/.radicle"),
                    std::string("/home/u/.radicle/node/control.sock"));
}

LOGOS_TEST(a_socket_path_within_the_cap_reports_no_problem)
{
    const NodePaths paths = resolvePaths("/home/u/.radicle", "", "", "", "",
                                         "/run/user/1000", "alice");
    LOGOS_ASSERT_TRUE(paths.problem.empty());
    LOGOS_ASSERT_EQ(paths.socket, std::string("/run/user/1000/radicle-alice.sock"));
}

LOGOS_TEST(an_overlong_socket_path_is_refused_and_the_message_names_path_and_limit)
{
    // The exact failure Phase 0 measured: Basecamp's per-profile data dir with
    // the node's socket suffix appended. The crate's own error names neither
    // the path nor the limit, so this message must name both or it is no
    // better than the one it replaces.
    const std::string tooLong(120, 'x');
    const NodePaths paths =
        resolvePaths("/home/u/.radicle", "/" + tooLong + ".sock", "", "", "", "", "alice");

    LOGOS_ASSERT_FALSE(paths.problem.empty());
    LOGOS_ASSERT_CONTAINS(paths.problem, tooLong);          // the path
    LOGOS_ASSERT_CONTAINS(paths.problem, std::string("107")); // the limit
}

LOGOS_TEST(a_socket_path_exactly_at_the_cap_is_accepted)
{
    // 107 bytes plus the NUL is exactly 108. Off-by-one here would reject a
    // path the kernel accepts, which is the kind of thing that only shows up
    // on someone else's longer username.
    const NodePaths paths =
        resolvePaths("/home/u/.radicle", std::string(107, 'y'), "", "", "", "", "");
    LOGOS_ASSERT_TRUE(paths.problem.empty());
}

LOGOS_TEST(one_byte_over_the_cap_is_refused)
{
    const NodePaths paths =
        resolvePaths("/home/u/.radicle", std::string(108, 'y'), "", "", "", "", "");
    LOGOS_ASSERT_FALSE(paths.problem.empty());
}

LOGOS_TEST(a_store_built_from_explicit_paths_reports_those_paths)
{
    // The constructor mode selection uses: the caller chose the home, and the
    // store must report on that one rather than re-reading the environment.
    ScopedRadHome env("explicit-paths");
    env.makeStorage();

    NodePaths paths;
    paths.home = env.dir;
    paths.socket = "/run/user/1000/radicle-test.sock";

    LocalStore store{paths};
    LOGOS_ASSERT_EQ(store.home(), env.dir);
    LOGOS_ASSERT_EQ(store.socket(), std::string("/run/user/1000/radicle-test.sock"));
    LOGOS_ASSERT_TRUE(store.available());
}

LOGOS_TEST(a_store_pointed_at_a_different_home_than_the_environment_uses_the_given_one)
{
    // Guards the actual regression the refactor makes possible: a store that
    // ignored its argument and re-read RAD_HOME would pass a test where the
    // two agree, and fail the whole point of mode selection.
    ScopedRadHome env("env-home");
    env.makeStorage();   // the environment's home IS a profile

    NodePaths paths;
    paths.home = env.dir + "-elsewhere";   // this one is not
    paths.socket = "/run/user/1000/radicle-other.sock";

    LocalStore store{paths};
    LOGOS_ASSERT_EQ(store.home(), env.dir + "-elsewhere");
    LOGOS_ASSERT_FALSE(store.available());
}
