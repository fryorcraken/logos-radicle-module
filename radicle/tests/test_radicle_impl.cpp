#include <logos_test.h>

#include "radicle_impl.h"
#include "seed_client.h"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <sys/stat.h>
#include <system_error>
#include <utility>
#include <vector>

using namespace radicle;

// ---------------------------------------------------------------------------
// RadicleImpl — the module's actual public API surface.
//
// Before this file existed, radicle_impl.cpp was absent from MODULE_SOURCES
// here and no test file mentioned RadicleImpl at all: none of its 28 public
// methods had a single line of test coverage. The deeper reason it could not
// be tested is that its dependencies (a SeedClient and a LocalStore/
// LocalReader/LocalWriter trio) used to be function-local `static`s built once
// per process on first use — so even a test that constructed a RadicleImpl
// would be at the mercy of whichever earlier test had already touched the
// singletons and fixed their RAD_HOME. RadicleImpl now takes its dependencies
// through its constructor (defaulted for production callers), so every test
// below builds its own independent instance against its own scratch home.
// ---------------------------------------------------------------------------

namespace {

/// Points RAD_HOME at a scratch directory for the duration of a test. Mirrors
/// test_local_store.cpp's helper of the same name/shape exactly, so the two
/// files read the same at a glance.
struct ScopedRadHome {
    std::string dir;
    std::string previous;
    bool hadPrevious = false;

    explicit ScopedRadHome(const std::string& name)
    {
        const char* base = std::getenv("TMPDIR");
        dir = std::string(base ? base : "/tmp") + "/radicle-impl-test-" + name;
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

    void makeStorage() { ::mkdir((dir + "/storage").c_str(), 0755); }
};

/// Points XDG_DATA_HOME at a scratch directory, so `settingsPathFromEnv()` —
/// and therefore the zero-argument `RadicleImpl()` production constructor —
/// resolves to a settings file this test owns.
///
/// Every other test here injects a SettingsStore through
/// setDependenciesForTest(), which is the right shape for almost everything.
/// It cannot reach one thing: `storeForSettings()` runs in the CONSTRUCTOR's
/// member init list, over the settings the constructor itself resolved. An
/// injected store replaces the LocalStore wholesale, so the constructor's
/// mode-to-store decision is exactly the code the injection paves over. A
/// settings file already on disk before construction is the only way to drive
/// it, and it is also the real-world shape of the bug: a file that was
/// hand-edited, or half-written by an older build.
struct ScopedXdgDataHome {
    std::string dir;
    std::string previous;
    bool hadPrevious = false;

    explicit ScopedXdgDataHome(const std::string& name)
    {
        const char* base = std::getenv("TMPDIR");
        dir = std::string(base ? base : "/tmp") + "/radicle-impl-xdg-" + name;
        ::mkdir(dir.c_str(), 0755);

        if (const char* old = std::getenv("XDG_DATA_HOME")) {
            previous = old;
            hadPrevious = true;
        }
        ::setenv("XDG_DATA_HOME", dir.c_str(), 1);
    }

    ~ScopedXdgDataHome()
    {
        // Remove the whole scratch data dir, not just the environment override.
        //
        // Needed since the embedded home lives under here: a test that creates
        // an identity leaves a real keystore behind, and the NEXT run of the
        // same test would find its home occupied and be refused — a suite that
        // passes once and then fails for ever, for a reason that looks nothing
        // like the change that caused it. The directories under TMPDIR are
        // named per test, so this removes only what this fixture made.
        std::error_code ec;
        std::filesystem::remove_all(dir, ec);

        if (hadPrevious) ::setenv("XDG_DATA_HOME", previous.c_str(), 1);
        else             ::unsetenv("XDG_DATA_HOME");
    }

    /// Write `contents` to exactly where settingsPathFromEnv() will look.
    void writeSettings(const std::string& contents) const
    {
        ::mkdir((dir + "/radicle-module").c_str(), 0755);
        std::ofstream out(dir + "/radicle-module/settings.json", std::ios::trunc);
        out << contents;
    }
};

/// Unsets one environment variable for the duration of a test, and restores it.
///
/// The fixtures above all SET things, which is why the gap this closes survived:
/// every Embedded test used `ScopedXdgDataHome` and `ScopedRadHome` together, so
/// `embeddedHomeFromEnv()` was never empty and the fall-through it enables was
/// never driven. The one input combination that reaches the bug — no
/// `XDG_DATA_HOME`, no `HOME`, but a `RAD_HOME` — cannot be built out of
/// fixtures that only add variables.
struct ScopedUnsetEnv {
    std::string name;
    std::string previous;
    bool hadPrevious = false;

    explicit ScopedUnsetEnv(const char* variable)
        : name(variable)
    {
        if (const char* old = std::getenv(variable)) {
            previous = old;
            hadPrevious = true;
        }
        ::unsetenv(variable);
    }

    ~ScopedUnsetEnv()
    {
        if (hadPrevious) ::setenv(name.c_str(), previous.c_str(), 1);
    }
};

/// A scripted fake transport for SeedClient, matching test_seed_client.cpp's
/// FakeSeed. Kept local to this file (rather than shared) for the same reason
/// test_local_writer.cpp duplicates `take()`: each file owning its own fixture
/// keeps it legible without a shared-header dependency for four lines of code.
struct FakeSeed {
    std::vector<std::string> requested;
    std::map<std::string, std::string> replies;
    bool failEverything = false;

    SeedClient::Transport transport()
    {
        return [this](const std::string& url) {
            requested.push_back(url);
            HttpResponse res;
            if (failEverything) {
                res.error = "network unreachable";
                return res;
            }
            for (const auto& [fragment, body] : replies) {
                if (url.find(fragment) != std::string::npos) {
                    res.ok = true;
                    res.status = 200;
                    res.body = body;
                    return res;
                }
            }
            res.status = 404;
            res.error = "HTTP 404";
            return res;
        };
    }
};

nlohmann::json parse(const std::string& s)
{
    auto j = nlohmann::json::parse(s, nullptr, false);
    LOGOS_ASSERT_FALSE(j.is_discarded());
    return j;
}

/// A SeedClient wired to a fake transport, built the same way in every test
/// that needs one.
SeedClient fakeSeedClient(FakeSeed& fake, const std::string& url = "https://example.test")
{
    SeedClient client(url);
    client.setTransport(fake.transport());
    return client;
}

} // namespace

/// The sole caller of RadicleImpl::setDependenciesForTest() (see
/// radicle_impl.h, `friend struct RadicleImplTestFactory`). RadicleImpl does
/// not grant a public, parameterized constructor for this because this
/// module has `"interface": "universal"` and no `.rep` file — its dispatch
/// table is derived by scanning radicle_impl.h's `public:` section, and a
/// public constructor that TAKES PARAMETERS (even all-defaulted ones, so it
/// is still callable with zero arguments) is a public identifier matching
/// the class name that the generator does not exclude from that scan (it
/// emitted `lidlImpl().RadicleImpl()` in generated_code/radicle_module_impl.cpp,
/// which does not compile). A genuinely parameterless public `RadicleImpl()`
/// is fine and is exactly what production keeps — see radicle_impl.h's
/// constructor and setDependenciesForTest() doc comments for the full
/// explanation, including why a second, private constructor overload does
/// not work either (production's own `generated_code/radicle_module_impl.cpp`
/// needs a genuinely public, genuinely zero-arg `RadicleImpl()`).
///
/// Deliberately NOT inside the anonymous namespace above: the `friend struct
/// RadicleImplTestFactory;` in radicle_impl.h is unqualified, so it names
/// `::RadicleImplTestFactory` — a type in an anonymous namespace here would
/// be a different, unrelated type of the same spelling, and the call below
/// would fail to compile as "private within this context" (found
/// empirically: that is exactly what happened before this was moved out).
struct RadicleImplTestFactory {
    static RadicleImpl make(radicle::SeedClient seed = radicle::SeedClient{},
                            radicle::LocalStore local = radicle::LocalStore{},
                            radicle::SettingsStore settings = radicle::SettingsStore{""})
    {
        RadicleImpl impl;
        impl.setDependenciesForTest(std::move(seed), std::move(local), std::move(settings));
        return impl;
    }
};

namespace {

/// Short alias used at every construction site below.
///
/// The settings store defaults to an EMPTY path, which means "defaults, and
/// refuse to write". That is deliberate: a test that has not asked for
/// settings must not read or write the developer's real XDG data directory,
/// and an empty path makes that impossible by construction rather than by
/// every test remembering to override it. Tests that do exercise settings pass
/// a scratch path explicitly.
RadicleImpl makeRadicleImpl(radicle::SeedClient seed = radicle::SeedClient{},
                            radicle::LocalStore local = radicle::LocalStore{},
                            radicle::SettingsStore settings = radicle::SettingsStore{""})
{
    return RadicleImplTestFactory::make(std::move(seed), std::move(local),
                                        std::move(settings));
}

/// A scratch settings file for the tests that do exercise settings.
std::string scratchSettingsPath(const std::string& name)
{
    const char* base = std::getenv("TMPDIR");
    const std::string dir =
        std::string(base ? base : "/tmp") + "/radicle-impl-settings-" + name;
    ::mkdir(dir.c_str(), 0755);
    return dir + "/settings.json";
}

} // namespace

// ---------------------------------------------------------------------------
// localUnavailable() — the "no local node at all" error, and that it is
// distinguishable from a deeper, Rust-side failure once a profile exists.
// ---------------------------------------------------------------------------

/// This is the exact shape a view branches on: an {"error":...} object naming
/// the missing home, with no "items" key that could be misread as "zero
/// repositories" (a different, legitimate state the UI renders differently).
LOGOS_TEST(local_unavailable_names_the_missing_profile_and_has_no_items_key)
{
    ScopedRadHome home("unavailable");
    // No makeStorage(): this is the "no profile at all" case.

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{});
    const auto out = parse(impl.localGetRepo("rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5"));

    LOGOS_ASSERT_TRUE(out.contains("error"));
    LOGOS_ASSERT_FALSE(out.contains("items"));
    const std::string message = out["error"].get<std::string>();
    // The message a user sees has to say where we looked, and has to be the
    // "no profile" wording, not a generic failure.
    LOGOS_ASSERT_CONTAINS(message, home.dir);
    LOGOS_ASSERT_CONTAINS(message, "rad auth");
}

/// Every local* method must return exactly this shape when there is no
/// profile — the guard prologue is repeated deliberately (see CLAUDE.md) but
/// must behave identically at each of the twelve call sites.
LOGOS_TEST(every_local_method_reports_the_same_unavailable_error_when_no_profile_exists)
{
    ScopedRadHome home("unavailable-all");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{});
    const std::string rid = "rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5";

    const std::vector<std::string> bodies = {
        impl.localListRepos("all", 0, 10),
        impl.localGetRepo(rid),
        impl.localListBranches(rid),
        impl.localGetTree(rid, "", ""),
        impl.localGetBlob(rid, "", "README.md"),
        impl.localGetReadme(rid, ""),
        impl.localListCommits(rid, "", 0, 10),
        impl.localGetCommit(rid, ""),
        impl.localListIssues(rid, "", 0, 10),
        impl.localGetIssue(rid, "abc"),
        impl.localListPatches(rid, "", 0, 10),
        impl.localGetPatch(rid, "abc"),
        impl.localCommentOnIssue(rid, "abc", "hello"),
        impl.localCreateIssue(rid, "title", "description"),
    };

    for (const auto& body : bodies) {
        const auto j = parse(body);
        LOGOS_ASSERT_TRUE(j.contains("error"));
        LOGOS_ASSERT_CONTAINS(j["error"].get<std::string>(), "rad auth");
    }
}

/// The distinction this milestone is built to preserve: once a profile
/// EXISTS (storage/ is present, so LocalStore::available() is true), a
/// request that fails deeper in the stack — here, because the scratch
/// profile has no keys/repos for the Rust backend to find anything in —
/// must NOT come back with the "no profile, run rad auth" wording.
/// localUnavailable() must only fire on the outer guard, never re-appear as a
/// generic catch-all once that guard has passed.
LOGOS_TEST(a_deeper_backend_failure_is_not_reported_as_localUnavailable)
{
    ScopedRadHome home("has-profile-no-key");
    home.makeStorage();   // a profile exists...

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{});
    const auto out = parse(impl.localGetRepo("rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5"));

    LOGOS_ASSERT_TRUE(out.contains("error"));
    const std::string message = out["error"].get<std::string>();
    // ...so the "no profile" wording must not appear: whatever the Rust layer
    // says instead (e.g. no key found, repo not found), it is a different
    // sentence prompting a different fix than "run rad auth".
    LOGOS_ASSERT_TRUE(message.find("rad auth") == std::string::npos);

    // Asserting only what the message is NOT is input-independent: a wrong
    // home (RadicleImpl's LocalReader pointed somewhere other than
    // LocalStore's own home()) also fails deeper than the "no profile" guard
    // and also omits "rad auth" — so that assertion alone cannot tell "read
    // the scratch home this test built" from "read some other, wrong
    // directory entirely". Pin what the message IS instead: with only
    // storage/ present and no keys/, the Rust backend's open_storage() (see
    // radicle/rust-ffi/src/local.rs) fails at the key lookup and names the
    // exact keys/ directory it looked in. That directory is derived from
    // *this test's* ScopedRadHome, so the message can only contain it if
    // RadicleImpl actually built its LocalReader from m_local.home() as
    // radicle_impl.cpp:43-44 claims — not from a different, hardcoded path.
    // A mutation that severs that wiring (e.g. hardcoding LocalReader's home
    // to some other directory) makes this fail: the message would instead
    // name that other directory, or report a different failure altogether
    // (a missing storage/ there would trip a different Storage::open error,
    // not a missing-key one), never home.dir + "/keys".
    LOGOS_ASSERT_CONTAINS(message, home.dir + "/keys");
    LOGOS_ASSERT_CONTAINS(message, "no Radicle key found");
}

// ---------------------------------------------------------------------------
// localListBranches — the only local* method with real logic of its own.
// ---------------------------------------------------------------------------

/// The end-to-end wiring check: that RadicleImpl::localListBranches really
/// reaches the Rust backend through the real LocalReader, and passes its
/// failures through.
///
/// This used to assert the derivation went through `branchesFromRawJson` over
/// `getRepo`'s document. It no longer does — that path reported exactly one
/// branch per repository, because `refs.refs` holds the canonical
/// delegate-consensus ref while real branches live under
/// `refs/namespaces/<nid>/`, so the local path now calls a dedicated backend
/// entry point (`local::list_branches`).
///
/// The property under test survives the change, which is why the test does:
/// on a repo the scratch profile does not have, the backend's own
/// {"error":...} must propagate rather than becoming an empty branch list
/// (which would render as "this repo has no branches" — a different, wrong
/// answer). The mechanism moved; the contract did not.
LOGOS_TEST(local_list_branches_propagates_a_backend_failure_rather_than_reporting_no_branches)
{
    ScopedRadHome home("branches-empty-profile");
    home.makeStorage();

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{});
    // A repo that does not exist in this empty scratch profile: the backend
    // returns an {"error":...} object, which localListBranches must pass
    // straight through rather than turning into an empty branch list.
    const auto out = parse(impl.localListBranches("rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5"));

    LOGOS_ASSERT_TRUE(out.contains("error"));
    LOGOS_ASSERT_FALSE(out.contains("items"));
}

// ---------------------------------------------------------------------------
// getCapabilities() — the method a UI calls first.
// ---------------------------------------------------------------------------

LOGOS_TEST(get_capabilities_reports_local_unavailable_and_remote_seed_info_with_no_profile)
{
    ScopedRadHome home("caps-no-profile");

    FakeSeed fake;
    auto impl = makeRadicleImpl(fakeSeedClient(fake, "https://seed.example.test"), LocalStore{});
    const auto caps = parse(impl.getCapabilities());

    LOGOS_ASSERT_FALSE(caps["localAvailable"].get<bool>());
    LOGOS_ASSERT_FALSE(caps["localNodeRunning"].get<bool>());
    LOGOS_ASSERT_FALSE(caps["canWriteLocal"].get<bool>());
    // canWrite is false because there is no local profile, so the reason must
    // be the SAME "no profile" wording localUnavailable() would give — this
    // is the `writeReason = local().unavailableReason()` seam before the
    // `if (localAvailable)` probe ever runs.
    LOGOS_ASSERT_CONTAINS(caps["writeUnavailableReason"].get<std::string>(), "rad auth");
    LOGOS_ASSERT_EQ(caps["remoteSeed"].get<std::string>(), std::string("https://seed.example.test"));
    LOGOS_ASSERT_TRUE(caps["nodeId"].get<std::string>().empty());
}

/// With no profile at all, localNodeRunning must be false.
///
/// Honest limitation, found by mutation-testing this exact line: removing
/// the `localAvailable &&` conjunction in getCapabilities() (leaving bare
/// `m_local.nodeRunning()`) does NOT make this test fail, because
/// LocalStore::nodeRunning() already has its own internal
/// `if (!m_available) return false;` guard (local_store.cpp) — so the
/// conjunction here is defense in depth against a future LocalStore that
/// drops that internal guard, not independently observable through the real
/// LocalStore today. Testing the conjunction itself would need a fake
/// LocalStore (it has no virtual/injectable seam, unlike SeedClient), which
/// is more surgery than this fix's "minimum change" scope covers. Recorded
/// here rather than silently passing this off as coverage it is not.
LOGOS_TEST(get_capabilities_reports_localNodeRunning_false_when_no_profile_regardless_of_socket)
{
    ScopedRadHome home("caps-node-running-guard");
    // No makeStorage(): available() is false.
    FakeSeed fake;
    auto impl = makeRadicleImpl(fakeSeedClient(fake), LocalStore{});
    const auto caps = parse(impl.getCapabilities());

    LOGOS_ASSERT_FALSE(caps["localAvailable"].get<bool>());
    LOGOS_ASSERT_FALSE(caps["localNodeRunning"].get<bool>());
}

LOGOS_TEST(get_capabilities_reflects_the_seed_clients_reachability_and_version)
{
    ScopedRadHome home("caps-seed-state");

    FakeSeed fake;
    fake.replies["/api/v1"] = R"({"apiVersion":"6.2.0","nid":"z6MkTest"})";
    SeedClient seed = fakeSeedClient(fake, "https://seed.example.test");
    // Probe once, as setRemoteSeed() would, so reachable()/apiVersion() have
    // real values to report.
    seed.probe();

    auto impl = makeRadicleImpl(std::move(seed), LocalStore{});
    const auto caps = parse(impl.getCapabilities());

    LOGOS_ASSERT_TRUE(caps["remoteReachable"].get<bool>());
    LOGOS_ASSERT_EQ(caps["remoteApiVersion"].get<std::string>(), std::string("6.2.0"));
}

// ---------------------------------------------------------------------------
// setRemoteSeed — the rollback on a failed probe.
// ---------------------------------------------------------------------------

LOGOS_TEST(set_remote_seed_adopts_the_new_seed_on_a_successful_probe)
{
    FakeSeed fake;
    fake.replies["/api/v1"] = R"({"apiVersion":"6.2.0","nid":"z6MkNew"})";
    auto impl = makeRadicleImpl(fakeSeedClient(fake, "https://old.example.test"), LocalStore{});

    const auto out = parse(impl.setRemoteSeed("https://example.test"));
    LOGOS_ASSERT_FALSE(out.contains("error"));
    LOGOS_ASSERT_EQ(out["seed"].get<std::string>(), std::string("https://example.test"));

    // The change stuck: getCapabilities() now reports the new seed.
    const auto caps = parse(impl.getCapabilities());
    LOGOS_ASSERT_EQ(caps["remoteSeed"].get<std::string>(), std::string("https://example.test"));
}

/// The rollback this milestone protects: a probe failure must leave the
/// PREVIOUS seed active, not the one that just failed to validate. Without
/// the rollback, a typo'd seed URL would silently become the active (and
/// broken) seed.
LOGOS_TEST(set_remote_seed_rolls_back_to_the_previous_seed_on_a_failed_probe)
{
    FakeSeed fake;
    fake.failEverything = true;
    auto impl = makeRadicleImpl(fakeSeedClient(fake, "https://good.example.test"), LocalStore{});

    const auto out = parse(impl.setRemoteSeed("https://bad.example.test"));
    LOGOS_ASSERT_TRUE(out.contains("error"));

    // The seed must have rolled back — a subsequent capabilities call reports
    // the ORIGINAL seed, not the one that failed to probe.
    const auto caps = parse(impl.getCapabilities());
    LOGOS_ASSERT_EQ(caps["remoteSeed"].get<std::string>(), std::string("https://good.example.test"));
}

LOGOS_TEST(set_remote_seed_refuses_an_empty_url_without_touching_the_current_seed)
{
    FakeSeed fake;
    auto impl = makeRadicleImpl(fakeSeedClient(fake, "https://good.example.test"), LocalStore{});

    const auto out = parse(impl.setRemoteSeed(""));
    LOGOS_ASSERT_TRUE(out.contains("error"));

    const auto caps = parse(impl.getCapabilities());
    LOGOS_ASSERT_EQ(caps["remoteSeed"].get<std::string>(), std::string("https://good.example.test"));
}

// ---------------------------------------------------------------------------
// listKnownSeeds — the built-ins only, deliberately NOT including
// preferredSeeds from a local profile's config.json.
// ---------------------------------------------------------------------------

/// Documents a real shipped bug that would silently return if `preferredSeeds`
/// were ever merged back in: those are peer-to-peer addresses (port 8776),
/// not the HTTPS JSON API this module proxies to, and offering them in the
/// picker showed the previous seed's data under the wrong name.
LOGOS_TEST(list_known_seeds_returns_only_builtins_even_with_a_local_profile_config)
{
    ScopedRadHome home("known-seeds");
    home.makeStorage();
    std::ofstream cfg(home.dir + "/config.json");
    cfg << R"({"preferredSeeds":["z6MkrLMM@my-own-seed.example.test:8776"]})";
    cfg.close();

    // Sanity check: the profile really does have a preferred seed to omit.
    LocalStore store;
    LOGOS_ASSERT_FALSE(store.preferredSeedUrls().empty());

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{});
    const auto out = parse(impl.listKnownSeeds());

    LOGOS_ASSERT_TRUE(out.contains("items"));
    for (const auto& item : out["items"]) {
        LOGOS_ASSERT_EQ(item["source"].get<std::string>(), std::string("builtin"));
        const std::string url = item["url"].get<std::string>();
        LOGOS_ASSERT_TRUE(url.find("my-own-seed.example.test") == std::string::npos);
    }
    // Exactly the three known built-ins, no more.
    LOGOS_ASSERT_EQ(out["items"].size(), size_t(3));
}

LOGOS_TEST(list_known_seeds_is_the_same_regardless_of_local_profile_availability)
{
    // With no profile at all, the answer must be identical: listKnownSeeds()
    // is source-neutral and must not depend on local availability either.
    ScopedRadHome home("known-seeds-no-profile");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{});
    const auto out = parse(impl.listKnownSeeds());
    LOGOS_ASSERT_EQ(out["items"].size(), size_t(3));
}

// ---------------------------------------------------------------------------
// Settings, and the capability fields that report which node is in use.
// ---------------------------------------------------------------------------

LOGOS_TEST(get_settings_reports_defaults_when_nothing_has_been_persisted)
{
    ScopedRadHome home("settings-defaults");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("defaults")});

    // `explore` — the first-run default, because a fresh install may have no
    // Radicle home and `local` there can show nothing at all. See
    // SettingsStore::load() for the whole argument.
    const auto out = parse(impl.getSettings());
    LOGOS_ASSERT_EQ(out["mode"].get<std::string>(), std::string("explore"));
    LOGOS_ASSERT_TRUE(out["gitPath"].get<std::string>().empty());
}

LOGOS_TEST(a_setting_written_through_the_module_is_readable_through_it)
{
    ScopedRadHome home("settings-roundtrip");
    const auto path = scratchSettingsPath("roundtrip");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});

    // A NON-default mode, so this proves the value made the round trip rather
    // than the read simply falling back to the default. Writing `explore` would
    // read back correctly even if the write had been dropped entirely.
    const auto written = parse(impl.setSetting("mode", "local"));
    LOGOS_ASSERT_FALSE(written.contains("error"));

    const auto read = parse(impl.getSettings());
    LOGOS_ASSERT_EQ(read["mode"].get<std::string>(), std::string("local"));
}

LOGOS_TEST(set_setting_refuses_an_unknown_key_through_the_module_boundary)
{
    ScopedRadHome home("settings-unknown");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("unknown")});

    const auto out = parse(impl.setSetting("nonsense", "x"));
    // The module's one failure shape, same as every other method.
    LOGOS_ASSERT_TRUE(out.contains("error"));
}

LOGOS_TEST(set_setting_refuses_a_git_path_that_does_not_exist_and_names_it)
{
    // The negative case that makes the setting meaningful at this layer too:
    // a module that accepted any string would pass a happy-path test.
    ScopedRadHome home("settings-bad-git");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("bad-git")});

    const auto out = parse(impl.setSetting("gitPath", "/definitely/not/here/git"));
    LOGOS_ASSERT_TRUE(out.contains("error"));
    LOGOS_ASSERT_CONTAINS(out["error"].get<std::string>(),
                          std::string("/definitely/not/here/git"));
}

LOGOS_TEST(capabilities_report_the_active_mode_and_that_every_mode_can_start)
{
    // This test used to assert the opposite for Embedded — not startable, with
    // a reason naming a later milestone — and it FAILED when Embedded gained a
    // home, which is exactly what it was for. It is kept rather than deleted
    // because the property it pins is unchanged: capabilities must report the
    // mode actually in force and whether THAT mode can start, per mode.
    //
    // The `modeUnavailableReason` assertion is the part that carries the
    // change. It must be empty for a startable mode: it is what `SourceToggle`
    // and `ModePicker` render as a caveat, so a leftover sentence would put
    // "this build cannot start the selected mode" under a mode that now can.
    ScopedRadHome home("caps-mode");
    ScopedXdgDataHome xdg("caps-mode");
    const auto path = scratchSettingsPath("caps-mode");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});

    for (const char* mode : {"explore", "local", "embedded"}) {
        impl.setSetting("mode", mode);
        const auto caps = parse(impl.getCapabilities());
        LOGOS_ASSERT_EQ(caps["mode"].get<std::string>(), std::string(mode));
        LOGOS_ASSERT_TRUE(caps["modeStartable"].get<bool>());
        LOGOS_ASSERT_TRUE(caps["modeUnavailableReason"].get<std::string>().empty());
    }

    // Input-dependent, and the reason this is not vacuous: a `modeStartable`
    // stuck at true would satisfy the loop above. A mode this build cannot
    // interpret must still report false, with a sentence.
    //
    // Driven through a settings FILE rather than `setSetting`, because
    // `setSetting` validates and would refuse — which is the point: the only
    // way an unknown mode reaches capabilities is off disk.
    xdg.writeSettings("{\"mode\":\"turbo\"}");
    RadicleImpl fromDisk;
    const auto caps = parse(fromDisk.getCapabilities());
    // `load()` sanitises an unknown mode to explore, so what capabilities
    // report is a startable mode — which is itself the property under test:
    // there is no reachable state in which `mode` names something unstartable.
    LOGOS_ASSERT_EQ(caps["mode"].get<std::string>(), std::string("explore"));
    LOGOS_ASSERT_TRUE(caps["modeStartable"].get<bool>());
    LOGOS_ASSERT_FALSE(SettingsStore::modeIsStartable("turbo"));
}

LOGOS_TEST(capabilities_report_which_modes_are_startable_not_just_the_current_one)
{
    // The honesty guarantee the mode picker depends on. `modeStartable` answers
    // a question about the CURRENT mode; a picker offering three rows needs the
    // answer for all three, and deriving one from the other is not possible:
    // in `local` mode (the default, and where a first-time user always is)
    // `modeStartable` is true, which says nothing at all about Embedded.
    //
    // Before this field existed the UI derived the set from that boolean, so in
    // the default state the Embedded row carried no caveat — the user selected
    // it, it persisted, and only THEN did a warning appear. That is exactly the
    // "control that silently does nothing" the design refuses to ship.
    //
    // Asserted in the DEFAULT (`local`) state on purpose: the buggy derivation
    // was correct in every other state, so a test that first switched to
    // embedded would have passed against it.
    //
    // Embedded is now IN the set, and this test failed when it joined — which
    // is what it was written to do. The field it pins is unchanged and still
    // needed: `modeStartable` is one boolean about one mode, and a picker
    // drawing three rows cannot derive three answers from it. That stays true
    // whether the set is two entries or three, and it is what a fourth mode
    // would rely on.
    ScopedRadHome home("caps-startable-set");
    ScopedXdgDataHome xdg("caps-startable-set");
    const auto path = scratchSettingsPath("caps-startable-set");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});

    impl.setSetting("mode", "local");
    const auto caps = parse(impl.getCapabilities());

    LOGOS_ASSERT_EQ(caps["mode"].get<std::string>(), std::string("local"));
    LOGOS_ASSERT_TRUE(caps["modeStartable"].get<bool>());

    LOGOS_ASSERT_TRUE(caps.contains("startableModes"));
    LOGOS_ASSERT_TRUE(caps["startableModes"].is_array());

    const auto startable = caps["startableModes"];
    const auto has = [&startable](const char* mode) {
        for (const auto& m : startable)
            if (m.is_string() && m.get<std::string>() == mode) return true;
        return false;
    };

    LOGOS_ASSERT_TRUE(has("local"));
    LOGOS_ASSERT_TRUE(has("explore"));
    LOGOS_ASSERT_TRUE(has("embedded"));

    // The set is reported, not invented: it must agree exactly with the store's
    // own answer, element for element. This is what keeps the field a view of
    // `startableModes()` rather than a second list `getCapabilities` maintains
    // — the drift that would let the UI and the module disagree about which
    // modes work, with nothing failing.
    LOGOS_ASSERT_EQ(startable.size(), SettingsStore::startableModes().size());
    for (const auto& m : SettingsStore::startableModes())
        LOGOS_ASSERT_TRUE(has(m.c_str()));

    // And it contains nothing else — an unknown mode must not appear, or the
    // agreement above could be satisfied by a superset.
    LOGOS_ASSERT_FALSE(has("turbo"));
}

LOGOS_TEST(the_startable_set_does_not_change_with_the_selected_mode)
{
    // Input-dependent in the direction that matters: the set is a fact about
    // the BUILD, so selecting the unstartable mode must not make it startable
    // and must not drop a mode that still is. A capabilities call that returned
    // "everything except the current mode when the current mode is bad" would
    // pass the test above and fail here.
    ScopedRadHome home("caps-startable-stable");
    const auto path = scratchSettingsPath("caps-startable-stable");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});

    impl.setSetting("mode", "local");
    const auto inLocal = parse(impl.getCapabilities())["startableModes"];

    impl.setSetting("mode", "embedded");
    const auto inEmbedded = parse(impl.getCapabilities())["startableModes"];

    // Asserted non-empty first, or this whole test passes vacuously against a
    // build with no `startableModes` at all: two absent values compare equal.
    LOGOS_ASSERT_TRUE(inLocal.is_array());
    LOGOS_ASSERT_FALSE(inLocal.empty());
    LOGOS_ASSERT_EQ(inLocal.dump(), inEmbedded.dump());
}

LOGOS_TEST(embedded_mode_does_not_alias_the_existing_local_profile)
{
    // The identity-confusion failure this whole milestone exists to prevent,
    // arriving through the mode picker itself.
    //
    // Embedded promises "a SEPARATE identity from any node you already run".
    // `storeForSettings` once special-cased only `explore`, so embedded fell
    // through to the same env resolution as `local` — a user who selected it
    // got their EXISTING node's DID in the chrome, their existing repositories,
    // and writes enabled against them, all under a segment reading "Embedded".
    //
    // Embedded now resolves a home of its OWN, from the XDG data dir alone. So
    // the assertion is no longer "no home" — it is the stronger and more
    // durable "a DIFFERENT home, and specifically not the one RAD_HOME names".
    // The weaker version would pass against a resolver that returned empty for
    // every mode, which is exactly what it used to be asserting.
    ScopedRadHome home("caps-embedded-own-home");
    home.makeStorage();
    ScopedXdgDataHome xdg("embedded-own-home");

    const auto path = scratchSettingsPath("embedded-own-home");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});

    // `local` first, to prove the profile IS visible from this environment —
    // without this the assertions below would pass against a module that could
    // never see any profile at all.
    impl.setSetting("mode", "local");
    const auto usingLocal = parse(impl.getCapabilities());
    LOGOS_ASSERT_EQ(usingLocal["radHome"].get<std::string>(), home.dir);
    LOGOS_ASSERT_TRUE(usingLocal["localAvailable"].get<bool>());

    impl.setSetting("mode", "embedded");
    const auto caps = parse(impl.getCapabilities());

    LOGOS_ASSERT_EQ(caps["mode"].get<std::string>(), std::string("embedded"));

    // A home of its own, under this Basecamp profile's data dir.
    const std::string embeddedHome = caps["radHome"].get<std::string>();
    LOGOS_ASSERT_FALSE(embeddedHome.empty());
    LOGOS_ASSERT_CONTAINS(embeddedHome, xdg.dir);
    LOGOS_ASSERT_EQ(embeddedHome, embeddedHomeFor(xdg.dir, ""));

    // And emphatically NOT the user's. This is the assertion that carries the
    // mode: RAD_HOME names a real, readable profile in this test, and Embedded
    // must not be pointed at it.
    LOGOS_ASSERT_TRUE(embeddedHome != home.dir);
    LOGOS_ASSERT_FALSE(caps["localAvailable"].get<bool>());
    LOGOS_ASSERT_FALSE(caps["canWriteLocal"].get<bool>());
}

LOGOS_TEST(embedded_with_no_resolvable_home_is_inert_rather_than_aliasing_rad_home)
{
    // **The aliasing bug, reached through the one input combination every other
    // Embedded test here structurally cannot drive.**
    //
    // `embeddedHomeFor()` returns "" when neither XDG_DATA_HOME nor HOME is set
    // — correct, and pinned in test_settings_store.cpp. But an empty
    // `configuredHome` is precisely what `resolveHome()` reads as "not
    // configured", so it falls through to RAD_HOME. Passing that empty string
    // into `resolvePathsFromEnv()` therefore pointed Embedded at the user's own
    // profile: the exact failure this mode exists to prevent, arriving through
    // a composition where each half is individually correct.
    //
    // Every other Embedded test uses ScopedXdgDataHome AND ScopedRadHome
    // together, so `embeddedHomeFromEnv()` is never empty in them and the
    // fall-through is unreachable. That is why the bug survived: not a missing
    // assertion, a missing INPUT.
    //
    // RAD_HOME is set to a real, readable profile, so a fall-through would
    // produce `localAvailable: true` and a populated home — loudly wrong rather
    // than subtly so.
    ScopedRadHome home("embedded-no-xdg");
    home.makeStorage();
    ScopedUnsetEnv noXdg("XDG_DATA_HOME");
    ScopedUnsetEnv noHome("HOME");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("embedded-no-xdg")});

    // `local` first, and asserted, so this test cannot pass against a module
    // that never resolves any home at all. Without it every assertion below is
    // satisfied by a build where all three modes are inert.
    impl.setSetting("mode", "local");
    LOGOS_ASSERT_EQ(parse(impl.getCapabilities())["radHome"].get<std::string>(), home.dir);

    // setSetting rebuilds the store through storeForSettings(), which is the
    // function under test.
    impl.setSetting("mode", "embedded");
    const auto caps = parse(impl.getCapabilities());

    LOGOS_ASSERT_EQ(caps["mode"].get<std::string>(), std::string("embedded"));

    // THE assertion. Not merely "empty" — specifically not RAD_HOME's value,
    // which is what the fall-through produces. Both are checked because they
    // fail differently: a home that is empty is inert, and a home that is
    // someone else's is the aliasing bug.
    LOGOS_ASSERT_TRUE(caps["radHome"].get<std::string>() != home.dir);
    LOGOS_ASSERT_TRUE(caps["radHome"].get<std::string>().empty());
    LOGOS_ASSERT_FALSE(caps["localAvailable"].get<bool>());
    LOGOS_ASSERT_FALSE(caps["canWriteLocal"].get<bool>());

    // And it says why, rather than going blank. The message must not be the
    // dangling "...Radicle home at " that concatenating an empty home produced.
    const std::string reason = caps["writeUnavailableReason"].get<std::string>();
    LOGOS_ASSERT_FALSE(reason.empty());
    LOGOS_ASSERT_CONTAINS(reason, std::string("XDG_DATA_HOME"));
    LOGOS_ASSERT_TRUE(reason.find("home at  ") == std::string::npos);
}

LOGOS_TEST(the_embedded_identity_methods_refuse_when_no_home_can_be_resolved)
{
    // The same emptiness through the two methods that already guarded it. Kept
    // beside the test above so the three paths that must agree are read
    // together — `storeForSettings()` was the odd one out, and a future edit
    // that re-introduced the gap in any one of them fails here.
    ScopedRadHome home("embedded-methods-no-xdg");
    home.makeStorage();
    ScopedUnsetEnv noXdg("XDG_DATA_HOME");
    ScopedUnsetEnv noHome("HOME");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("embedded-methods")});

    // The read reports a problem rather than an error: the question was
    // answered, and the answer is that there is nowhere to put an identity.
    const auto probe = parse(impl.getEmbeddedIdentity());
    LOGOS_ASSERT_TRUE(probe["home"].get<std::string>().empty());
    LOGOS_ASSERT_FALSE(probe["exists"].get<bool>());
    LOGOS_ASSERT_FALSE(probe["problem"].get<std::string>().empty());

    // The write refuses outright, and creates nothing anywhere — least of all
    // in the profile RAD_HOME names.
    const auto created = parse(impl.createEmbeddedIdentity("tester", ""));
    LOGOS_ASSERT_TRUE(created.contains("error"));

    struct stat st{};
    LOGOS_ASSERT_TRUE(::stat((home.dir + "/keys").c_str(), &st) != 0);
}

LOGOS_TEST(embedded_with_no_identity_yet_does_not_tell_the_user_to_run_rad_auth)
{
    // A user chooses Embedded precisely because they do not have `rad`. Telling
    // them to install it and run `rad auth` is advice for the mode they did not
    // pick, and it arrives at the one moment they are most likely to believe
    // the module is broken.
    //
    // The assertion is on both halves — the wrong advice is absent AND the
    // right explanation is present — because a reason that went empty would
    // satisfy the first alone, and an empty reason is the "blank pane" failure
    // this repo has shipped before.
    ScopedRadHome home("caps-embedded-reason");
    home.makeStorage();
    ScopedXdgDataHome xdg("embedded-reason");

    const auto path = scratchSettingsPath("embedded-reason");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});

    // Local first, and asserted, because the `rad auth` advice must SURVIVE
    // there. Without this the test passes against a build that deleted the
    // sentence outright, which would strand every user who really does need it.
    impl.setSetting("mode", "local");
    // A home with storage but no key: available, so the reason comes from the
    // write probe rather than from the absent-profile path. Use a home with no
    // storage instead to reach the sentence under test.
    const auto localCaps = parse(impl.getCapabilities());
    LOGOS_ASSERT_TRUE(localCaps["localAvailable"].get<bool>());

    impl.setSetting("mode", "embedded");
    const auto caps = parse(impl.getCapabilities());
    const std::string reason = caps["writeUnavailableReason"].get<std::string>();

    LOGOS_ASSERT_FALSE(reason.empty());
    LOGOS_ASSERT_TRUE(reason.find("rad auth") == std::string::npos);
    // It names the home, so a user can see WHERE the identity would go, and
    // states the consequence the whole mode turns on.
    LOGOS_ASSERT_CONTAINS(reason, caps["radHome"].get<std::string>());
    LOGOS_ASSERT_CONTAINS(reason, std::string("separate identity"));
}

LOGOS_TEST(the_rad_auth_advice_survives_for_a_local_home_with_no_profile)
{
    // The other direction of the test above, as its own case because it needs a
    // different environment: `local` pointed at a home with NO storage is
    // exactly the user who should be told to install Radicle. A change that
    // replaced the default wording everywhere would pass the embedded test and
    // fail here.
    ScopedRadHome home("caps-local-no-profile-advice");
    // Deliberately no makeStorage().
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("local-advice")});

    impl.setSetting("mode", "local");
    const auto caps = parse(impl.getCapabilities());

    LOGOS_ASSERT_FALSE(caps["localAvailable"].get<bool>());
    LOGOS_ASSERT_CONTAINS(caps["writeUnavailableReason"].get<std::string>(),
                          std::string("rad auth"));
}

// ---------------------------------------------------------------------------
// The embedded identity: reading what is there, and creating it.
// ---------------------------------------------------------------------------

LOGOS_TEST(the_embedded_identity_reports_the_home_and_that_nothing_is_there_yet)
{
    ScopedRadHome home("embedded-identity-empty");
    home.makeStorage();                 // a REAL profile in the environment...
    ScopedXdgDataHome xdg("embedded-identity-empty");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("emb-id-empty")});

    const auto out = parse(impl.getEmbeddedIdentity());

    LOGOS_ASSERT_EQ(out["home"].get<std::string>(), embeddedHomeFor(xdg.dir, ""));
    // ...which must NOT be reported as the embedded one. This is the assertion
    // that makes the reply about the embedded home rather than about whatever
    // profile happens to be reachable.
    LOGOS_ASSERT_TRUE(out["home"].get<std::string>() != home.dir);
    LOGOS_ASSERT_FALSE(out["exists"].get<bool>());
    LOGOS_ASSERT_TRUE(out["nodeId"].get<std::string>().empty());
    LOGOS_ASSERT_TRUE(out["problem"].get<std::string>().empty());
}

LOGOS_TEST(creating_the_embedded_identity_makes_one_the_module_can_then_report)
{
    // The whole round trip: create, and see the same identity come back through
    // the read path. Asserting the node id MATCHES is what distinguishes a real
    // creation from a reply invented and never written.
    ScopedRadHome home("embedded-identity-create");
    ScopedXdgDataHome xdg("embedded-identity-create");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("emb-id-create")});

    LOGOS_ASSERT_FALSE(parse(impl.getEmbeddedIdentity())["exists"].get<bool>());

    const auto created = parse(impl.createEmbeddedIdentity("tester", ""));
    LOGOS_ASSERT_FALSE(created.contains("error"));
    LOGOS_ASSERT_TRUE(created["created"].get<bool>());
    const std::string nid = created["nodeId"].get<std::string>();
    LOGOS_ASSERT_FALSE(nid.empty());
    LOGOS_ASSERT_EQ(created["home"].get<std::string>(), embeddedHomeFor(xdg.dir, ""));

    const auto after = parse(impl.getEmbeddedIdentity());
    LOGOS_ASSERT_TRUE(after["exists"].get<bool>());
    // The SAME identity, not merely some identity: a read path pointed at a
    // different home would report `exists:false`, and one that invented an id
    // would report a different string.
    LOGOS_ASSERT_EQ(after["nodeId"].get<std::string>(), nid);
}

LOGOS_TEST(creating_an_embedded_identity_never_touches_the_users_own_home)
{
    // The irreversible failure, and the only one worth a test of its own: a
    // creation that resolved the user's `~/.radicle` would refuse (their
    // keystore exists) or, worse, overwrite it.
    //
    // RAD_HOME points at a scratch home with no profile — so if creation read
    // it, a profile would appear THERE and the assertion below would catch it.
    // That is the input-dependent form: the two homes are different and only
    // one of them may gain a key.
    ScopedRadHome home("embedded-create-isolation");
    ScopedXdgDataHome xdg("embedded-create-isolation");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("emb-iso")});

    const auto created = parse(impl.createEmbeddedIdentity("tester", ""));
    LOGOS_ASSERT_TRUE(created["created"].get<bool>());

    struct stat st{};
    LOGOS_ASSERT_TRUE(::stat((home.dir + "/keys").c_str(), &st) != 0);
    LOGOS_ASSERT_TRUE(::stat((home.dir + "/config.json").c_str(), &st) != 0);
    // And the key really did land in the embedded home, or the assertion above
    // is satisfied just as well by a creation that failed entirely.
    LOGOS_ASSERT_TRUE(
        ::stat((embeddedHomeFor(xdg.dir, "") + "/keys/radicle.pub").c_str(), &st) == 0);
}

LOGOS_TEST(a_second_embedded_identity_is_refused_and_names_the_consequence)
{
    // No force, ever: the signing key IS the identity. The refusal is asserted
    // on its WORDING because the `radicle` crate refuses a second init too, so
    // "it errored" is equally true with this module's guard deleted.
    ScopedRadHome home("embedded-create-twice");
    ScopedXdgDataHome xdg("embedded-create-twice");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("emb-twice")});

    const auto first = parse(impl.createEmbeddedIdentity("tester", ""));
    const std::string original = first["nodeId"].get<std::string>();
    LOGOS_ASSERT_FALSE(original.empty());

    const auto second = parse(impl.createEmbeddedIdentity("someone-else", ""));
    LOGOS_ASSERT_TRUE(second.contains("error"));
    LOGOS_ASSERT_CONTAINS(second["error"].get<std::string>(),
                          std::string("would overwrite its signing key"));

    // The identity on disk is untouched — which is what the refusal is FOR. A
    // guard that errored after rewriting the keystore passes the check above.
    LOGOS_ASSERT_EQ(parse(impl.getEmbeddedIdentity())["nodeId"].get<std::string>(),
                    original);
}

LOGOS_TEST(the_passphrase_reaches_the_backend_and_the_outcome_is_reported)
{
    // The wizard's passphrase must actually arrive. A module that dropped the
    // argument would create an unencrypted key and report `encrypted:false`,
    // which is why both directions are asserted against two separate homes:
    // one answer for every input proves nothing.
    ScopedRadHome home("embedded-passphrase");

    ScopedXdgDataHome plain("embedded-pass-plain");
    {
        auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                    SettingsStore{scratchSettingsPath("emb-plain")});
        const auto out = parse(impl.createEmbeddedIdentity("tester", ""));
        LOGOS_ASSERT_FALSE(out["encrypted"].get<bool>());
    }

    ScopedXdgDataHome sealed("embedded-pass-sealed");
    {
        auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                    SettingsStore{scratchSettingsPath("emb-sealed")});
        const auto out =
            parse(impl.createEmbeddedIdentity("tester", "correct horse battery"));
        LOGOS_ASSERT_TRUE(out["encrypted"].get<bool>());
    }
}

LOGOS_TEST(creating_the_identity_in_embedded_mode_makes_the_node_readable_at_once)
{
    // Without the rebuild in createEmbeddedIdentity, this instance's
    // LocalReader still points at the home as it was — no profile — and the
    // user sees the wizard succeed while the app goes on saying there is no
    // identity, until a restart. The failure is silent and reads as "creating
    // the identity did nothing".
    ScopedRadHome home("embedded-live-rebuild");
    ScopedXdgDataHome xdg("embedded-live-rebuild");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("emb-live")});
    impl.setSetting("mode", "embedded");

    LOGOS_ASSERT_FALSE(parse(impl.getCapabilities())["localAvailable"].get<bool>());

    const auto created = parse(impl.createEmbeddedIdentity("tester", ""));
    LOGOS_ASSERT_TRUE(created["created"].get<bool>());

    const auto caps = parse(impl.getCapabilities());
    LOGOS_ASSERT_TRUE(caps["localAvailable"].get<bool>());
    // The identity the module now reports is the one just created, read back
    // through the capabilities path rather than echoed from the creation reply.
    LOGOS_ASSERT_EQ(caps["nodeId"].get<std::string>(),
                    created["nodeId"].get<std::string>());
}

LOGOS_TEST(creating_the_identity_does_not_repoint_a_module_that_is_in_local_mode)
{
    // The other side of the rebuild: it must be conditional. Creating an
    // embedded identity is a legitimate thing to do while browsing your own
    // node — setting it up for later — and it must not silently swap which node
    // the app is reading.
    ScopedRadHome home("embedded-create-from-local");
    home.makeStorage();
    ScopedXdgDataHome xdg("embedded-create-from-local");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("emb-from-local")});
    impl.setSetting("mode", "local");
    LOGOS_ASSERT_EQ(parse(impl.getCapabilities())["radHome"].get<std::string>(), home.dir);

    LOGOS_ASSERT_TRUE(parse(impl.createEmbeddedIdentity("tester", ""))["created"].get<bool>());

    const auto caps = parse(impl.getCapabilities());
    // Still Local, still the user's home. And the mode is unchanged: creating
    // an identity is not choosing a mode.
    LOGOS_ASSERT_EQ(caps["mode"].get<std::string>(), std::string("local"));
    LOGOS_ASSERT_EQ(caps["radHome"].get<std::string>(), home.dir);

    // But the identity really was created — otherwise this test passes against
    // a build where createEmbeddedIdentity does nothing at all.
    LOGOS_ASSERT_TRUE(parse(impl.getEmbeddedIdentity())["exists"].get<bool>());
}

LOGOS_TEST(a_persisted_mode_this_build_does_not_know_does_not_alias_the_local_profile)
{
    // The same identity confusion as the test above, arriving through the one
    // door that test cannot reach: a settings FILE naming a mode this build has
    // never heard of.
    //
    // `set()` validates the mode; `load()` did not, so a hand-edited file, a
    // half-written one, or a file written by a newer build was read back
    // verbatim. `storeForSettings()` then named only `explore` and `embedded`
    // and let everything else fall through to the environment — so an unknown
    // mode inherited Local's behaviour exactly, and the module reported the
    // attached profile's home, `localAvailable: true` and full read access
    // under a mode the UI has no segment for.
    //
    // Both halves are asserted through the production constructor, because both
    // halves live there: the file is read by `settingsPathFromEnv()` and the
    // store is built in the member init list.
    ScopedRadHome home("caps-unknown-mode");
    home.makeStorage();
    ScopedXdgDataHome xdg("unknown-mode");

    // `local` FIRST, from an equally real settings file, to prove this
    // environment's profile IS visible. Without it every assertion below passes
    // just as happily against a module that can never see any profile at all —
    // the "a fixture that answers the same for every input" failure.
    xdg.writeSettings("{\"mode\":\"local\"}");
    {
        RadicleImpl usingLocal;
        const auto caps = parse(usingLocal.getCapabilities());
        LOGOS_ASSERT_EQ(caps["mode"].get<std::string>(), std::string("local"));
        LOGOS_ASSERT_EQ(caps["radHome"].get<std::string>(), home.dir);
        LOGOS_ASSERT_TRUE(caps["localAvailable"].get<bool>());
    }

    xdg.writeSettings("{\"mode\":\"turbo\"}");
    RadicleImpl impl;
    const auto caps = parse(impl.getCapabilities());

    // The unknown value never reaches a consumer. It resolves to Explore — the
    // one mode that touches no local profile — rather than to the `local`
    // default, because a file this build cannot interpret is no basis for
    // claiming a node identity. See SettingsStore::load().
    LOGOS_ASSERT_EQ(caps["mode"].get<std::string>(), std::string("explore"));
    // And no profile leaks through, which is the property that matters: home,
    // availability and write access are all as if no node existed.
    LOGOS_ASSERT_TRUE(caps["radHome"].get<std::string>().empty());
    LOGOS_ASSERT_FALSE(caps["localAvailable"].get<bool>());
    LOGOS_ASSERT_FALSE(caps["canWriteLocal"].get<bool>());
}

LOGOS_TEST(capabilities_report_the_resolved_home_and_socket)
{
    ScopedRadHome home("caps-paths");
    home.makeStorage();
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("caps-paths")});

    const auto caps = parse(impl.getCapabilities());
    // The home actually in use, so a user can see WHICH node they are reading
    // rather than inferring it from whether their repos showed up.
    LOGOS_ASSERT_EQ(caps["radHome"].get<std::string>(), home.dir);
    LOGOS_ASSERT_TRUE(caps.contains("radSocket"));
    LOGOS_ASSERT_TRUE(caps.contains("pathsProblem"));
}

LOGOS_TEST(explore_mode_reports_no_local_home_at_all)
{
    // Explore is not "`local` with the local bits hidden": the user has said
    // they do not want this module touching a local profile, so it must not
    // report one even when a perfectly good profile exists in the environment.
    ScopedRadHome home("caps-explore");
    home.makeStorage();

    const auto path = scratchSettingsPath("explore");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});

    // `local` first, to prove the profile IS visible — otherwise the assertion
    // below would pass against a module that never sees any profile.
    impl.setSetting("mode", "local");
    LOGOS_ASSERT_EQ(parse(impl.getCapabilities())["radHome"].get<std::string>(), home.dir);

    impl.setSetting("mode", "explore");
    const auto caps = parse(impl.getCapabilities());
    LOGOS_ASSERT_TRUE(caps["radHome"].get<std::string>().empty());
    LOGOS_ASSERT_FALSE(caps["localAvailable"].get<bool>());
}

LOGOS_TEST(capabilities_report_the_git_preflight)
{
    ScopedRadHome home("caps-git");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("caps-git")});

    const auto caps = parse(impl.getCapabilities());
    // Present regardless of the answer: a view has to be able to say "no git,
    // so no writes" rather than showing a write button that cannot work.
    LOGOS_ASSERT_TRUE(caps.contains("gitFound"));
    LOGOS_ASSERT_TRUE(caps.contains("gitPath"));
    LOGOS_ASSERT_TRUE(caps.contains("gitVersion"));
    LOGOS_ASSERT_TRUE(caps.contains("gitConfigured"));

    // With no configured path, any git found was auto-detected — so the flag
    // that distinguishes the two must say so.
    LOGOS_ASSERT_FALSE(caps["gitConfigured"].get<bool>());
}

LOGOS_TEST(a_persisted_seed_is_adopted_when_the_module_starts)
{
    // The cheapest proof the settings store works, and a real user-visible
    // improvement: setRemoteSeed used to be lost on restart entirely.
    ScopedRadHome home("seed-persist");
    const auto path = scratchSettingsPath("seed-persist");

    {
        SettingsStore settings{path};
        settings.set(SettingsStore::kKeyRemoteSeed, "https://persisted.example.test");
    }

    // A fresh RadicleImpl over the same settings file — which is what a
    // restart is, at this layer. Nothing below writes the seed: adoption is
    // what is under test, so the test must not perform it.
    //
    // This test used to call setSetting() with the very value it then asserted,
    // because setDependenciesForTest replaced the seed client after the
    // constructor had adopted. It therefore passed with the adoption deleted
    // outright — which is the one thing a regression test must never do. The
    // fix was in the code, not here: adoption is now a named method both the
    // constructor and the injection run, so this asserts the real path.
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});

    const auto caps = parse(impl.getCapabilities());
    LOGOS_ASSERT_EQ(caps["remoteSeed"].get<std::string>(),
                    std::string("https://persisted.example.test"));
}

LOGOS_TEST(a_seed_is_adopted_from_the_settings_it_was_given_not_from_a_fixed_default)
{
    // Input-dependent, which is what makes the test above mean something: two
    // settings files carrying two different seeds must produce two differently
    // configured modules. An adoption step that hardcoded a URL, or one that
    // read the wrong store, passes the single-value test and fails this.
    ScopedRadHome home("seed-persist-two");

    const auto pathA = scratchSettingsPath("seed-persist-a");
    const auto pathB = scratchSettingsPath("seed-persist-b");
    {
        SettingsStore a{pathA};
        a.set(SettingsStore::kKeyRemoteSeed, "https://alpha.example.test");
        SettingsStore b{pathB};
        b.set(SettingsStore::kKeyRemoteSeed, "https://beta.example.test");
    }

    auto implA = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{pathA});
    auto implB = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{pathB});

    LOGOS_ASSERT_EQ(parse(implA.getCapabilities())["remoteSeed"].get<std::string>(),
                    std::string("https://alpha.example.test"));
    LOGOS_ASSERT_EQ(parse(implB.getCapabilities())["remoteSeed"].get<std::string>(),
                    std::string("https://beta.example.test"));
}

// ===========================================================================
// The node.
//
// What this layer owns is the GATING — which modes may start a node, and what
// is refused before the backend is reached. Whether a node actually starts,
// binds and stops is `rust-ffi/tests/node_lifecycle.rs`, which can stand up a
// real runtime; standing one up here would make the C++ unit tests slow, need a
// socket path short enough to bind, and prove something the layer below already
// proves.
//
// Every test below therefore drives a path that returns BEFORE
// `EmbeddedNode::start` is called. That is a deliberate boundary, not a gap:
// each one asserts a decision this file makes.
// ===========================================================================

LOGOS_TEST(starting_a_node_in_local_mode_is_refused_because_that_node_is_the_users)
{
    // The refusal that matters most, and it is not about tidiness: `local` names
    // a node the user runs themselves, very possibly right now. Starting a
    // second one against that home puts two nodes on one git storage, which is
    // the corruption hazard the whole isolation model exists to prevent.
    ScopedRadHome home("node-start-local");
    home.makeStorage();
    ScopedXdgDataHome xdg("node-start-local");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("node-start-local")});
    impl.setSetting("mode", "local");

    // The profile IS readable in this environment — without asserting that,
    // every assertion below would also pass against a module that could not see
    // any profile at all and refused for an unrelated reason.
    LOGOS_ASSERT_TRUE(parse(impl.getCapabilities())["localAvailable"].get<bool>());

    const auto reply = parse(impl.startNode(""));
    LOGOS_ASSERT_TRUE(reply.contains("error"));

    // The message must name the mode and point at the one that does run a node.
    // A bare "not supported" leaves a user with a control that failed and no
    // idea what to do instead.
    const std::string error = reply["error"].get<std::string>();
    LOGOS_ASSERT_CONTAINS(error, std::string("local"));
    LOGOS_ASSERT_CONTAINS(error, std::string("embedded"));
}

LOGOS_TEST(starting_a_node_in_explore_mode_is_refused_for_a_different_reason)
{
    // Distinct from the case above, and the distinction is the point: `explore`
    // has no home at all — that is its definition — so there is nothing to start
    // a node in. `local` has a home and a node that is not ours.
    //
    // Two refusals with two reasons rather than one generic "wrong mode",
    // because the user's next action differs: one is "your node is already
    // yours to run", the other is "pick a mode that has a node".
    ScopedRadHome home("node-start-explore");
    home.makeStorage();
    ScopedXdgDataHome xdg("node-start-explore");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("node-start-explore")});
    impl.setSetting("mode", "explore");

    const auto reply = parse(impl.startNode(""));
    LOGOS_ASSERT_TRUE(reply.contains("error"));

    const std::string error = reply["error"].get<std::string>();
    LOGOS_ASSERT_CONTAINS(error, std::string("explore"));
    LOGOS_ASSERT_CONTAINS(error, std::string("embedded"));

    // And it is NOT the local-mode sentence. Without this the two refusals could
    // collapse into one message and both tests above would still pass — the
    // same-answer-for-every-input trap, arriving through error text.
    LOGOS_ASSERT_TRUE(error.find("you run yourself") == std::string::npos);
}

LOGOS_TEST(starting_a_node_with_no_embedded_identity_says_so_in_the_modes_own_words)
{
    // The ordinary first state of Embedded: a home resolved, nothing in it yet.
    // This is not a misconfiguration and must not read as one — in particular it
    // must not say "run `rad auth`", which is advice for the mode whose whole
    // premise is that the user never does.
    //
    // `NodePaths::absentProfileReason` carries that sentence, and this asserts
    // the node path reuses it rather than inventing a second, worse one.
    ScopedRadHome home("node-start-no-identity");
    home.makeStorage();
    ScopedXdgDataHome xdg("node-start-no-identity");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("node-start-no-id")});
    impl.setSetting("mode", "embedded");

    const auto reply = parse(impl.startNode(""));
    LOGOS_ASSERT_TRUE(reply.contains("error"));

    const std::string error = reply["error"].get<std::string>();
    LOGOS_ASSERT_CONTAINS(error, std::string("no embedded identity yet"));
    // The sentence that must never appear here.
    LOGOS_ASSERT_TRUE(error.find("rad auth") == std::string::npos);

    // And RAD_HOME's real, readable profile was not reached. A start that fell
    // through to the environment would have found a perfectly good profile
    // there — which is the aliasing failure, arriving through the node path.
    LOGOS_ASSERT_TRUE(error.find(home.dir) == std::string::npos);
}

LOGOS_TEST(stopping_and_status_answer_in_every_mode_including_ones_that_cannot_start)
{
    // **Deliberately NOT gated on the mode, unlike `startNode`**, and this is
    // what pins that asymmetry.
    //
    // A node that is running has to be stoppable whatever the settings now say.
    // A user who starts an embedded node and then switches to Local would
    // otherwise hold a running node with no control that can reach it — a mode
    // switch as a way to strand a daemon. Status is ungated for the same reason
    // plus one of its own: it is the call a view polls, and one that refused
    // outside Embedded would leave a UI unable to explain a node it can see.
    ScopedRadHome home("node-stop-any-mode");
    home.makeStorage();
    ScopedXdgDataHome xdg("node-stop-any-mode");

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{},
                                SettingsStore{scratchSettingsPath("node-stop-any")});

    for (const char* mode : {"explore", "local", "embedded"}) {
        impl.setSetting("mode", mode);

        // Nothing is running in this test process, so the answer is
        // `stopped:false` with a reason — an ANSWER, not an error. A caller that
        // asked for the node to be stopped has got what it asked for, and making
        // that a failure means every shutdown path special-cases the normal one.
        const auto stopped = parse(impl.stopNode());
        LOGOS_ASSERT_FALSE(stopped.contains("error"));
        LOGOS_ASSERT_FALSE(stopped["stopped"].get<bool>());

        // Status always reports BOTH halves. A view reading only `running` would
        // be blind to a node that died internally, which is the failure the two
        // fields exist to separate.
        const auto status = parse(impl.getNodeStatus());
        LOGOS_ASSERT_FALSE(status.contains("error"));
        LOGOS_ASSERT_FALSE(status["running"].get<bool>());
        LOGOS_ASSERT_FALSE(status["serving"].get<bool>());
    }
}

LOGOS_TEST(a_too_long_socket_is_reported_before_a_start_is_attempted)
{
    // The 108-byte `sun_path` cap, named in full rather than discovered.
    //
    // This is the failure Phase 0 measured and the one whose native error costs
    // an afternoon: the kernel says "path must be shorter than SUN_LEN", naming
    // neither the path, nor its length, nor the limit. `pathsProblem` names all
    // three, and the node path must surface it BEFORE attempting a start —
    // otherwise the useful message is replaced by the useless one.
    ScopedRadHome home("node-long-socket");
    home.makeStorage();
    ScopedXdgDataHome xdg("node-long-socket");

    const auto path = scratchSettingsPath("node-long-socket");
    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});
    impl.setSetting("mode", "embedded");

    // Written straight into the settings file rather than through `setSetting`,
    // which validates the length and would refuse it. That refusal is the right
    // behaviour and is covered in test_settings_store.cpp; what is under test
    // here is the SECOND line of defence — a socket that arrived some other way
    // (a hand-edited file, or the environment, which the store never sees).
    {
        std::ofstream out(path, std::ios::trunc);
        out << nlohmann::json{
            {"mode", "embedded"},
            {"radHome", ""},
            {"radSocket", "/tmp/" + std::string(120, 'x') + ".sock"},
            {"gitPath", ""},
            {"remoteSeed", ""},
        }.dump();
    }

    // Rebuilt so the store re-reads the file above — and then `setSetting` is
    // called, because construction alone is not enough here.
    //
    // `setDependenciesForTest` REPLACES `m_local` with the store it is handed,
    // which is the environment-resolved default. Only `setSetting` on a
    // home-affecting key runs `storeForSettings()`, which is what applies the
    // mode and the socket from the file. Without this the impl sits on
    // RAD_HOME's profile and the assertions below fail against a message about
    // a completely different home — which is exactly how the first draft of this
    // test failed, and is worth recording because every other Embedded test in
    // this file happens to call `setSetting` for its own reasons and so never
    // meets it.
    //
    // Re-setting `mode` to the value already in the file is the smallest way to
    // trigger that rebuild.
    auto reloaded = makeRadicleImpl(SeedClient{}, LocalStore{}, SettingsStore{path});
    reloaded.setSetting("mode", "embedded");
    const auto reply = parse(reloaded.startNode(""));

    LOGOS_ASSERT_TRUE(reply.contains("error"));
    const std::string error = reply["error"].get<std::string>();

    // All three facts, because a user cannot act on "too long" without knowing
    // which path, by how much, and against what limit.
    LOGOS_ASSERT_CONTAINS(error, std::string("too long"));
    LOGOS_ASSERT_CONTAINS(error, std::string(".sock"));   // the path
    LOGOS_ASSERT_CONTAINS(error, std::string("130"));     // its actual length
    // The limit as a user experiences it: 107 usable bytes, the message spelling
    // out that the 108th is the NUL. Asserted as 107 rather than 108
    // deliberately — the first draft asserted "108" and failed here, which is the
    // check doing its job: `kSunPathMax` is the capacity INCLUDING the
    // terminator, and reporting that raw number would overstate what fits by
    // one. A user shortening a path to exactly 108 bytes on our advice would hit
    // the same error again.
    LOGOS_ASSERT_CONTAINS(error, std::string("107"));

    // And it never reached the backend. The Rust side's message for a home with
    // no key is a perfectly good sentence about a different problem, and letting
    // it win here would replace the one message that names the cap with one that
    // does not — the exact substitution this ordering exists to prevent.
    LOGOS_ASSERT_TRUE(error.find("no signing key") == std::string::npos);
}
