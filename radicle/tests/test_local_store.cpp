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
