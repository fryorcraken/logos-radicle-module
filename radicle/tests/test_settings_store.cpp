#include <logos_test.h>

#include "settings_store.h"
#include "local_store.h"
// For isError() — the module's one failure-shape predicate, which every
// validation case below asserts against.
#include "seed_client.h"

#include <cstdlib>
#include <fstream>
#include <string>
#include <sys/stat.h>

using namespace radicle;

namespace {

/// A scratch settings file, removed on destruction.
///
/// Deliberately NOT pointed at the developer's real XDG data dir. The
/// `probe_*` examples read a real machine on purpose and are correctly not
/// tests; a test that wrote into a real profile would be a different thing
/// entirely.
struct ScratchSettings {
    std::string dir;

    explicit ScratchSettings(const std::string& name)
    {
        const char* base = std::getenv("TMPDIR");
        dir = std::string(base ? base : "/tmp") + "/radicle-settings-" + name;
        ::mkdir(dir.c_str(), 0755);
    }

    std::string path() const { return dir + "/settings.json"; }

    void write(const std::string& contents) const
    {
        std::ofstream out(path(), std::ios::trunc);
        out << contents;
    }
};

} // namespace

// ---------------------------------------------------------------------------
// Isolation. The test that matters most, and the one that has to be
// input-dependent: two stores in two locations must not see each other.
// ---------------------------------------------------------------------------

LOGOS_TEST(two_settings_stores_in_two_places_do_not_see_each_others_values)
{
    ScratchSettings a("isolation-a");
    ScratchSettings b("isolation-b");

    SettingsStore alice{a.path()};
    SettingsStore bob{b.path()};

    // DIFFERENT values on purpose. Identical ones would pass against a store
    // that ignored its path entirely and shared one global file — the
    // same-answer-for-every-input trap. The assertion below can only hold if
    // each store actually read its own file.
    alice.set(SettingsStore::kKeyRemoteSeed, "https://alice.example");
    bob.set(SettingsStore::kKeyRemoteSeed, "https://bob.example");

    LOGOS_ASSERT_EQ(alice.get(SettingsStore::kKeyRemoteSeed),
                    std::string("https://alice.example"));
    LOGOS_ASSERT_EQ(bob.get(SettingsStore::kKeyRemoteSeed),
                    std::string("https://bob.example"));
}

LOGOS_TEST(a_write_through_one_store_is_invisible_to_a_store_elsewhere)
{
    ScratchSettings a("isolation-write-a");
    ScratchSettings b("isolation-write-b");

    SettingsStore alice{a.path()};
    SettingsStore bob{b.path()};

    alice.set(SettingsStore::kKeyMode, SettingsStore::kModeExplore);

    // bob never wrote a mode, so it must still report the default — not
    // alice's. A shared file would hand back `explore` here.
    LOGOS_ASSERT_EQ(bob.get(SettingsStore::kKeyMode),
                    std::string(SettingsStore::kModeLocal));
}

// ---------------------------------------------------------------------------
// Persistence — the point of the whole store.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_setting_survives_being_read_back_by_a_fresh_store)
{
    // Two separate SettingsStore objects over one path: this is what "survives
    // a restart" means at this layer. The seed chosen via setRemoteSeed used
    // to be lost on restart entirely; this is the cheapest proof it is not.
    ScratchSettings s("persist");
    {
        SettingsStore first{s.path()};
        first.set(SettingsStore::kKeyRemoteSeed, "https://persisted.example");
    }

    SettingsStore second{s.path()};
    LOGOS_ASSERT_EQ(second.get(SettingsStore::kKeyRemoteSeed),
                    std::string("https://persisted.example"));
}

LOGOS_TEST(setting_one_key_leaves_the_others_untouched)
{
    ScratchSettings s("independent");
    SettingsStore store{s.path()};

    store.set(SettingsStore::kKeyMode, SettingsStore::kModeExplore);
    store.set(SettingsStore::kKeyRemoteSeed, "https://kept.example");

    // Distinct values again, so a store that overwrote the whole file on every
    // write would lose the first one and fail here.
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyMode),
                    std::string(SettingsStore::kModeExplore));
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyRemoteSeed),
                    std::string("https://kept.example"));
}

LOGOS_TEST(set_returns_the_whole_settings_object_not_just_the_changed_key)
{
    ScratchSettings s("returns-all");
    SettingsStore store{s.path()};

    const auto result = store.set(SettingsStore::kKeyMode, SettingsStore::kModeExplore);

    LOGOS_ASSERT_FALSE(isError(result));
    // A caller re-renders from this one reply, so every key has to be present
    // or the view shows a stale value for whatever is missing.
    LOGOS_ASSERT_TRUE(result.contains(SettingsStore::kKeyMode));
    LOGOS_ASSERT_TRUE(result.contains(SettingsStore::kKeyRadHome));
    LOGOS_ASSERT_TRUE(result.contains(SettingsStore::kKeyRadSocket));
    LOGOS_ASSERT_TRUE(result.contains(SettingsStore::kKeyGitPath));
    LOGOS_ASSERT_TRUE(result.contains(SettingsStore::kKeyRemoteSeed));
}

// ---------------------------------------------------------------------------
// Defaults and damaged files.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_missing_settings_file_yields_defaults_rather_than_an_error)
{
    ScratchSettings s("missing");
    SettingsStore store{s.path()};

    // `local`, because that is what the module did before settings existed:
    // read whatever home the environment names. A user upgrading must not find
    // the module behaving differently.
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyMode),
                    std::string(SettingsStore::kModeLocal));
}

LOGOS_TEST(a_corrupted_settings_file_yields_defaults_rather_than_a_dead_module)
{
    ScratchSettings s("corrupt");
    s.write("{ this is not json at all");

    SettingsStore store{s.path()};
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyMode),
                    std::string(SettingsStore::kModeLocal));
}

LOGOS_TEST(unknown_keys_in_the_file_are_ignored_rather_than_surfaced)
{
    ScratchSettings s("unknown-in-file");
    s.write(R"({"mode":"explore","somethingElse":"x"})");

    SettingsStore store{s.path()};
    // The known key is honoured...
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyMode),
                    std::string(SettingsStore::kModeExplore));
    // ...and the unknown one does not appear in the reported settings.
    LOGOS_ASSERT_FALSE(store.all().contains("somethingElse"));
}

LOGOS_TEST(a_mode_in_the_file_that_this_build_does_not_know_is_not_handed_back)
{
    // `set()` validates, so this cannot come from the module — but the file is
    // on disk, and a hand edit, a torn write, or a NEWER build all produce one.
    // It used to be read back verbatim, and both consumers then treated it as
    // Local by falling through an else: the module reported the attached
    // profile's home and full read access under a mode name the UI cannot draw.
    ScratchSettings s("unknown-mode-in-file");
    s.write(R"({"mode":"turbo","remoteSeed":"https://kept.example.test"})");

    SettingsStore store{s.path()};

    // Explore, NOT the `local` default: a file this build cannot interpret is
    // no basis for claiming a node identity, and Explore is the one mode that
    // touches no local profile. Asserting the specific value rather than merely
    // "known" is what pins that down — a fallback to `local` is a known mode
    // too, and is exactly the leak this guards against.
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyMode),
                    std::string(SettingsStore::kModeExplore));

    // The rest of the file survives. A corrupt mode is not a reason to discard
    // settings that parsed perfectly well — and asserting it here is what stops
    // a future "just return defaults" simplification from silently dropping the
    // user's seed along with the bad mode.
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyRemoteSeed),
                    std::string("https://kept.example.test"));
}

LOGOS_TEST(a_known_mode_in_the_file_is_read_back_unchanged)
{
    // The other half, and the reason the test above means anything: the
    // sanitising must be input-dependent. A load() that returned Explore for
    // every stored mode would pass the assertion above and fail here.
    ScratchSettings s("known-mode-in-file");

    for (const char* mode : {SettingsStore::kModeLocal,
                             SettingsStore::kModeEmbedded,
                             SettingsStore::kModeExplore}) {
        s.write(std::string(R"({"mode":")") + mode + R"("})");
        SettingsStore store{s.path()};
        LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyMode), std::string(mode));
    }
}

// ---------------------------------------------------------------------------
// Validation on write. Each case asserts the REFUSAL and that nothing changed
// — a validator that reported an error and stored the value anyway would pass
// a test that only checked the return.
// ---------------------------------------------------------------------------

LOGOS_TEST(an_unknown_setting_key_is_refused_by_name)
{
    ScratchSettings s("unknown-key");
    SettingsStore store{s.path()};

    const auto result = store.set("noSuchSetting", "x");
    LOGOS_ASSERT_TRUE(isError(result));
    LOGOS_ASSERT_CONTAINS(result["error"].get<std::string>(), std::string("noSuchSetting"));
}

LOGOS_TEST(an_unknown_mode_is_refused_and_the_message_lists_the_valid_ones)
{
    ScratchSettings s("bad-mode");
    SettingsStore store{s.path()};

    const auto result = store.set(SettingsStore::kKeyMode, "turbo");
    LOGOS_ASSERT_TRUE(isError(result));
    // Every valid mode by NAME, from the constants. The message used to be
    // spelled out in the validator and this assertion checked one hardcoded
    // word, so a rename could leave the sentence naming modes that no longer
    // exist with nothing going red. Asserting all three ties the message to the
    // set it claims to describe.
    LOGOS_ASSERT_CONTAINS(result["error"].get<std::string>(),
                          std::string(SettingsStore::kModeExplore));
    LOGOS_ASSERT_CONTAINS(result["error"].get<std::string>(),
                          std::string(SettingsStore::kModeLocal));
    LOGOS_ASSERT_CONTAINS(result["error"].get<std::string>(),
                          std::string(SettingsStore::kModeEmbedded));

    // And the stored value is untouched, which is the half a return-only
    // assertion would miss.
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyMode),
                    std::string(SettingsStore::kModeLocal));
}

LOGOS_TEST(all_three_modes_are_accepted)
{
    ScratchSettings s("modes");
    SettingsStore store{s.path()};

    for (const char* mode : {SettingsStore::kModeLocal,
                             SettingsStore::kModeEmbedded,
                             SettingsStore::kModeExplore}) {
        const auto result = store.set(SettingsStore::kKeyMode, mode);
        LOGOS_ASSERT_FALSE(isError(result));
        LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyMode), std::string(mode));
    }
}

LOGOS_TEST(embedded_is_selectable_but_reported_as_not_startable)
{
    // Phase 1 persists the choice; Phase 2 starts the daemon. The UI needs to
    // be able to say so plainly rather than offering a control that silently
    // does nothing.
    LOGOS_ASSERT_TRUE(SettingsStore::isKnownMode(SettingsStore::kModeEmbedded));
    LOGOS_ASSERT_FALSE(SettingsStore::modeIsStartable(SettingsStore::kModeEmbedded));

    // The other two are startable today, which is what makes the assertion
    // above about Embedded specifically rather than about every mode.
    LOGOS_ASSERT_TRUE(SettingsStore::modeIsStartable(SettingsStore::kModeLocal));
    LOGOS_ASSERT_TRUE(SettingsStore::modeIsStartable(SettingsStore::kModeExplore));
}

LOGOS_TEST(a_git_path_that_does_not_exist_is_refused_and_named)
{
    // The negative case that makes the git setting meaningful. A test that only
    // set a valid git would pass against a store that ignored the value
    // entirely.
    ScratchSettings s("bad-git");
    SettingsStore store{s.path()};

    const auto result = store.set(SettingsStore::kKeyGitPath, "/definitely/not/here/git");
    LOGOS_ASSERT_TRUE(isError(result));
    LOGOS_ASSERT_CONTAINS(result["error"].get<std::string>(),
                          std::string("/definitely/not/here/git"));
    LOGOS_ASSERT_TRUE(store.get(SettingsStore::kKeyGitPath).empty());
}

LOGOS_TEST(an_empty_git_path_is_accepted_because_it_means_find_it_on_path)
{
    ScratchSettings s("empty-git");
    SettingsStore store{s.path()};

    const auto result = store.set(SettingsStore::kKeyGitPath, "");
    LOGOS_ASSERT_FALSE(isError(result));
}

LOGOS_TEST(an_overlong_socket_path_is_refused_at_set_time)
{
    ScratchSettings s("long-socket");
    SettingsStore store{s.path()};

    const std::string tooLong = "/" + std::string(120, 'x') + ".sock";
    const auto result = store.set(SettingsStore::kKeyRadSocket, tooLong);

    LOGOS_ASSERT_TRUE(isError(result));
    LOGOS_ASSERT_CONTAINS(result["error"].get<std::string>(), std::string("107"));
    LOGOS_ASSERT_TRUE(store.get(SettingsStore::kKeyRadSocket).empty());
}

LOGOS_TEST(a_socket_path_within_the_cap_is_accepted)
{
    ScratchSettings s("ok-socket");
    SettingsStore store{s.path()};

    const auto result = store.set(SettingsStore::kKeyRadSocket, "/run/user/1000/rad.sock");
    LOGOS_ASSERT_FALSE(isError(result));
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyRadSocket),
                    std::string("/run/user/1000/rad.sock"));
}

LOGOS_TEST(a_seed_url_without_a_scheme_is_refused)
{
    ScratchSettings s("bad-seed");
    SettingsStore store{s.path()};

    const auto result = store.set(SettingsStore::kKeyRemoteSeed, "seed.radicle.xyz");
    LOGOS_ASSERT_TRUE(isError(result));
    LOGOS_ASSERT_TRUE(store.get(SettingsStore::kKeyRemoteSeed).empty());
}

LOGOS_TEST(both_http_and_https_seed_urls_are_accepted)
{
    ScratchSettings s("seed-schemes");
    SettingsStore store{s.path()};

    LOGOS_ASSERT_FALSE(isError(store.set(SettingsStore::kKeyRemoteSeed,
                                         "https://seed.example")));
    // http is allowed deliberately: a local or LAN seed over plain http is a
    // real configuration, and refusing it would be this module inventing a
    // policy the seed API does not have.
    LOGOS_ASSERT_FALSE(isError(store.set(SettingsStore::kKeyRemoteSeed,
                                         "http://localhost:8080")));
}

// ---------------------------------------------------------------------------
// Where the file goes.
// ---------------------------------------------------------------------------

LOGOS_TEST(the_settings_path_follows_xdg_data_home_when_set)
{
    LOGOS_ASSERT_EQ(settingsPathFor("/xdg/data", "/home/u"),
                    std::string("/xdg/data/radicle-module/settings.json"));
}

LOGOS_TEST(the_settings_path_falls_back_to_the_xdg_default_under_the_user_home)
{
    LOGOS_ASSERT_EQ(settingsPathFor("", "/home/u"),
                    std::string("/home/u/.local/share/radicle-module/settings.json"));
}

LOGOS_TEST(two_basecamp_profiles_get_two_settings_files)
{
    // This is what keeps alice and bob apart, and it is the reason the path is
    // derived from XDG_DATA_HOME rather than from anything this module chooses
    // for itself: Basecamp already hands each profile its own.
    const std::string alice = settingsPathFor("/profiles/alice/xdg-data", "/home/u");
    const std::string bob   = settingsPathFor("/profiles/bob/xdg-data", "/home/u");

    LOGOS_ASSERT_TRUE(alice != bob);
    LOGOS_ASSERT_CONTAINS(alice, std::string("alice"));
    LOGOS_ASSERT_CONTAINS(bob, std::string("bob"));
}

LOGOS_TEST(no_environment_at_all_yields_no_settings_path)
{
    // Better than a path relative to nothing: an empty path makes the store
    // fall back to defaults in memory rather than writing somewhere arbitrary.
    LOGOS_ASSERT_TRUE(settingsPathFor("", "").empty());
}

LOGOS_TEST(a_store_with_no_path_still_reports_defaults_rather_than_failing)
{
    SettingsStore store{""};
    LOGOS_ASSERT_EQ(store.get(SettingsStore::kKeyMode),
                    std::string(SettingsStore::kModeLocal));

    // ...and refuses to write, naming the problem rather than silently
    // pretending the value was stored.
    const auto result = store.set(SettingsStore::kKeyMode, SettingsStore::kModeExplore);
    LOGOS_ASSERT_TRUE(isError(result));
}
