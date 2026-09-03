#include <logos_test.h>

#include "seed_client.h"

#include <map>
#include <string>
#include <vector>

using namespace radicle;

namespace {

/// Records every URL requested and replies from a scripted table, so tests
/// assert on the exact URLs the client builds without touching the network.
struct FakeSeed {
    std::vector<std::string> requested;
    std::map<std::string, std::string> replies;   // url fragment -> JSON body
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

    bool asked(const std::string& needle) const
    {
        for (const auto& u : requested)
            if (u.find(needle) != std::string::npos) return true;
        return false;
    }
};

/// Minimal repo document carrying a head SHA and one branch ref.
const char* kRepoJson = R"({
  "rid": "rad:zTEST",
  "payloads": { "xyz.radicle.project": {
      "data": { "name": "demo", "defaultBranch": "main", "description": "d" },
      "meta": { "head": "1111111111111111111111111111111111111111",
                "issues": {"open": 2, "closed": 1},
                "patches": {"open": 3, "draft": 0, "archived": 0, "merged": 4} } } },
  "refs": { "refs": { "refs/heads/main": "1111111111111111111111111111111111111111",
                      "refs/heads/dev":  "2222222222222222222222222222222222222222" },
            "tags": {} }
})";

const std::string kFullSha = "1111111111111111111111111111111111111111";
const std::string kDevSha  = "2222222222222222222222222222222222222222";

} // namespace

// ---------------------------------------------------------------------------
// Ref resolution.
//
// The seed API rejects anything but a full 40-char SHA on path parameters
// ("invalid length (have 6, want 40)"), so the client must translate first.
// These pin that translation.
// ---------------------------------------------------------------------------

LOGOS_TEST(resolve_sha_passes_through_a_full_sha_without_asking_the_seed)
{
    FakeSeed seed;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    LOGOS_ASSERT_EQ(client.resolveSha("rad:zTEST", kFullSha), kFullSha);
    // A 40-char SHA needs no lookup at all.
    LOGOS_ASSERT_TRUE(seed.requested.empty());
}

LOGOS_TEST(resolve_sha_maps_a_branch_name_to_its_commit)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTEST"] = kRepoJson;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    LOGOS_ASSERT_EQ(client.resolveSha("rad:zTEST", "dev"), kDevSha);
}

LOGOS_TEST(resolve_sha_falls_back_to_the_repo_head_when_the_ref_is_empty)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTEST"] = kRepoJson;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    LOGOS_ASSERT_EQ(client.resolveSha("rad:zTEST", ""), kFullSha);
}

LOGOS_TEST(resolve_sha_falls_back_to_head_for_an_unknown_branch)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTEST"] = kRepoJson;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    LOGOS_ASSERT_EQ(client.resolveSha("rad:zTEST", "no-such-branch"), kFullSha);
}

// ---------------------------------------------------------------------------
// URL shapes. Both of these were found by probing the live API and are easy to
// regress silently — a wrong one yields a bare 404 or 400 with no clue.
// ---------------------------------------------------------------------------

LOGOS_TEST(tree_root_request_keeps_its_trailing_slash)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTEST"] = kRepoJson;
    seed.replies["/tree/" + kFullSha] = R"({"entries":[]})";
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    client.getTree("rad:zTEST", "main", "");
    // Root tree without the trailing slash 404s.
    LOGOS_ASSERT_TRUE(seed.asked("/tree/" + kFullSha + "/"));
}

LOGOS_TEST(tree_subpath_request_has_no_trailing_slash)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTEST"] = kRepoJson;
    seed.replies["/tree/" + kFullSha] = R"({"entries":[]})";
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    client.getTree("rad:zTEST", "main", "src");
    LOGOS_ASSERT_TRUE(seed.asked("/tree/" + kFullSha + "/src"));
    LOGOS_ASSERT_FALSE(seed.asked("/tree/" + kFullSha + "/src/"));
}

LOGOS_TEST(path_requests_always_carry_a_full_sha_never_a_branch_name)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTEST"] = kRepoJson;
    seed.replies["/blob/" + kFullSha] = R"({"binary":false,"content":"x"})";
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    client.getBlob("rad:zTEST", "main", "README.md");
    LOGOS_ASSERT_TRUE(seed.asked("/blob/" + kFullSha + "/"));
    // The literal branch name must never reach a path parameter.
    LOGOS_ASSERT_FALSE(seed.asked("/blob/main/"));
}

LOGOS_TEST(issue_and_patch_filters_use_status_not_state)
{
    FakeSeed seed;
    seed.replies["/issues?page=0&perPage=10&status=closed"] = "[]";
    seed.replies["/patches?page=0&perPage=10&status=merged"] = "[]";
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    client.listIssues("rad:zTEST", "closed", 0, 10);
    client.listPatches("rad:zTEST", "merged", 0, 10);

    // `state=` is silently ignored by the seed and returns unfiltered results.
    LOGOS_ASSERT_TRUE(seed.asked("status=closed"));
    LOGOS_ASSERT_TRUE(seed.asked("status=merged"));
    LOGOS_ASSERT_FALSE(seed.asked("state=closed"));
}

LOGOS_TEST(an_empty_status_filter_is_omitted_entirely)
{
    FakeSeed seed;
    seed.replies["/issues?page=0&perPage=10"] = "[]";
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    client.listIssues("rad:zTEST", "", 0, 10);
    LOGOS_ASSERT_FALSE(seed.asked("status="));
}

LOGOS_TEST(a_search_query_is_percent_encoded)
{
    FakeSeed seed;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    client.listRepos("hello world/x", 0, 10);
    LOGOS_ASSERT_TRUE(seed.asked("query=hello%20world%2Fx"));
}

// ---------------------------------------------------------------------------
// Failure shape. Callers branch on exactly one thing: the `error` key.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_transport_failure_becomes_an_error_object)
{
    FakeSeed seed;
    seed.failEverything = true;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    const auto res = client.getRepo("rad:zTEST");
    LOGOS_ASSERT_TRUE(isError(res));
    LOGOS_ASSERT_CONTAINS(res["error"].get<std::string>(), "network unreachable");
}

LOGOS_TEST(an_unresolvable_ref_reports_which_ref_failed)
{
    FakeSeed seed;
    seed.failEverything = true;      // so the repo lookup cannot resolve a head
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    const auto res = client.getTree("rad:zTEST", "main", "");
    LOGOS_ASSERT_TRUE(isError(res));
    LOGOS_ASSERT_CONTAINS(res["error"].get<std::string>(), "main");
}

LOGOS_TEST(a_blob_request_without_a_path_is_rejected_before_any_request)
{
    FakeSeed seed;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    const auto res = client.getBlob("rad:zTEST", "main", "");
    LOGOS_ASSERT_TRUE(isError(res));
    LOGOS_ASSERT_TRUE(seed.requested.empty());
}

// ---------------------------------------------------------------------------
// Pagination. The seed returns bare arrays with no envelope and no total, so
// the client synthesises one; `hasMore` is inferred from a full page.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_full_page_reports_more_available)
{
    const auto out = paginate(nlohmann::json::array({1, 2, 3}), 0, 3);
    LOGOS_ASSERT_EQ(out["items"].size(), size_t(3));
    LOGOS_ASSERT_EQ(out["page"].get<int>(), 0);
    LOGOS_ASSERT_TRUE(out["hasMore"].get<bool>());
}

LOGOS_TEST(a_short_page_reports_the_end_of_the_list)
{
    const auto out = paginate(nlohmann::json::array({1, 2}), 1, 3);
    LOGOS_ASSERT_EQ(out["page"].get<int>(), 1);
    LOGOS_ASSERT_FALSE(out["hasMore"].get<bool>());
}

LOGOS_TEST(pagination_passes_an_error_through_untouched)
{
    const auto out = paginate(makeError("boom"), 0, 10);
    LOGOS_ASSERT_TRUE(isError(out));
    LOGOS_ASSERT_EQ(out["error"].get<std::string>(), std::string("boom"));
}

// ---------------------------------------------------------------------------
// Seed selection.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_trailing_slash_on_the_seed_url_does_not_double_up_in_requests)
{
    FakeSeed seed;
    SeedClient client("https://example.test/");
    client.setTransport(seed.transport());

    client.listRepos("", 0, 10);
    LOGOS_ASSERT_TRUE(seed.asked("https://example.test/api/v1/repos"));
    LOGOS_ASSERT_FALSE(seed.asked("//api/v1"));
}

LOGOS_TEST(probe_records_the_api_version_the_seed_advertises)
{
    FakeSeed seed;
    seed.replies["/api/v1"] = R"({"apiVersion":"6.2.0","nid":"z6MkTEST"})";
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    const auto index = client.probe();
    LOGOS_ASSERT_FALSE(isError(index));
    LOGOS_ASSERT_EQ(client.apiVersion(), std::string("6.2.0"));
    LOGOS_ASSERT_TRUE(client.reachable());
}

LOGOS_TEST(changing_the_seed_clears_the_previous_versions_state)
{
    FakeSeed seed;
    seed.replies["/api/v1"] = R"({"apiVersion":"6.2.0","nid":"z6MkTEST"})";
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());
    client.probe();
    LOGOS_ASSERT_EQ(client.apiVersion(), std::string("6.2.0"));

    client.setSeedUrl("https://other.test");
    // Stale version/reachability from the old seed must not linger.
    LOGOS_ASSERT_EQ(client.apiVersion(), std::string(""));
    LOGOS_ASSERT_FALSE(client.reachable());
}
