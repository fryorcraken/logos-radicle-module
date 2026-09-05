#include <logos_test.h>

#include "radicle_impl.h"
#include "seed_client.h"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <sys/stat.h>
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
                            radicle::LocalStore local = radicle::LocalStore{})
    {
        RadicleImpl impl;
        impl.setDependenciesForTest(std::move(seed), std::move(local));
        return impl;
    }
};

namespace {

/// Short alias used at every construction site below.
RadicleImpl makeRadicleImpl(radicle::SeedClient seed = radicle::SeedClient{},
                            radicle::LocalStore local = radicle::LocalStore{})
{
    return RadicleImplTestFactory::make(std::move(seed), std::move(local));
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

/// This is the end-to-end wiring check: that RadicleImpl::localListBranches
/// really does call through m_localReader.getRepo() and derive branches from
/// whatever comes back, rather than the two ever silently drifting apart.
/// test_seed_client.cpp pins branchesFromRawJson() itself in isolation
/// (including its malformed-JSON / is_discarded() branch, which the real Rust
/// backend can never trigger since it always emits valid JSON via
/// serde_json); this test pins that localListBranches actually reaches it
/// through the real LocalReader, on a repo the scratch profile does not have,
/// so the backend's own {"error":...} propagates rather than becoming an
/// empty branch list (which would render as "this repo has no branches" — a
/// different, wrong answer).
LOGOS_TEST(local_list_branches_derives_branches_from_the_repo_document_via_branchesFrom)
{
    ScopedRadHome home("branches-empty-profile");
    home.makeStorage();

    auto impl = makeRadicleImpl(SeedClient{}, LocalStore{});
    // A repo that does not exist in this empty scratch profile: getRepo()
    // returns an {"error":...} object from the Rust backend, which
    // localListBranches must pass straight through via branchesFrom() rather
    // than turning into an empty branch list (which would render as "this
    // repo has no branches" — a different, wrong answer).
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
