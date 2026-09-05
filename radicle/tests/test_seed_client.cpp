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
// Branch listing.
//
// No dedicated seed endpoint exists for this: getRepo() already returns the
// full refs map (the same one resolveSha() reads), so listBranches() reuses
// that single request instead of adding another round trip.
// ---------------------------------------------------------------------------

LOGOS_TEST(list_branches_reads_refs_heads_from_the_repo_document)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTEST"] = kRepoJson;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    const auto out = client.listBranches("rad:zTEST");
    LOGOS_ASSERT_FALSE(isError(out));
    LOGOS_ASSERT_EQ(out["items"].size(), size_t(2));
    LOGOS_ASSERT_EQ(out["default"].get<std::string>(), std::string("main"));
}

LOGOS_TEST(list_branches_strips_the_refs_heads_prefix)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTEST"] = kRepoJson;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    const auto out = client.listBranches("rad:zTEST");
    bool sawMain = false, sawDev = false;
    for (const auto& item : out["items"]) {
        const std::string name = item["name"].get<std::string>();
        // The raw ref key ("refs/heads/main") must never leak into the name.
        LOGOS_ASSERT_TRUE(name.find("refs/heads/") == std::string::npos);
        if (name == "main") { sawMain = true; LOGOS_ASSERT_EQ(item["head"].get<std::string>(), kFullSha); }
        if (name == "dev")  { sawDev = true;  LOGOS_ASSERT_EQ(item["head"].get<std::string>(), kDevSha); }
    }
    LOGOS_ASSERT_TRUE(sawMain);
    LOGOS_ASSERT_TRUE(sawDev);
}

LOGOS_TEST(list_branches_excludes_tags)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTAGGED"] = R"({
      "rid": "rad:zTAGGED",
      "payloads": { "xyz.radicle.project": {
          "data": { "name": "demo", "defaultBranch": "main" },
          "meta": { "head": "1111111111111111111111111111111111111111" } } },
      "refs": { "refs": { "refs/heads/main": "1111111111111111111111111111111111111111" },
                "tags": { "refs/tags/v1.0": "3333333333333333333333333333333333333333" } }
    })";
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    const auto out = client.listBranches("rad:zTAGGED");
    LOGOS_ASSERT_EQ(out["items"].size(), size_t(1));
    LOGOS_ASSERT_EQ(out["items"][0]["name"].get<std::string>(), std::string("main"));
}

LOGOS_TEST(list_branches_propagates_a_repo_lookup_failure)
{
    FakeSeed seed;
    seed.failEverything = true;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    const auto out = client.listBranches("rad:zTEST");
    LOGOS_ASSERT_TRUE(isError(out));
}

LOGOS_TEST(list_branches_on_a_repo_with_no_refs_returns_an_empty_list_not_an_error)
{
    FakeSeed seed;
    seed.replies["/repos/rad%3AzEMPTY"] = R"({
      "rid": "rad:zEMPTY",
      "payloads": { "xyz.radicle.project": {
          "data": { "name": "demo" }, "meta": {} } }
    })";
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());

    const auto out = client.listBranches("rad:zEMPTY");
    LOGOS_ASSERT_FALSE(isError(out));
    LOGOS_ASSERT_EQ(out["items"].size(), size_t(0));
}

/// `localListBranches` derives its answer from the local backend's repo
/// document using this same function, rather than adding a `listBranches`
/// entry point to the FFI. That is only correct if the derivation depends on
/// nothing but the document — no seed, no transport, no client state. Calling
/// it directly on a parsed document is what pins that.
LOGOS_TEST(branches_are_derived_from_the_document_alone_so_both_sources_agree)
{
    const auto doc = nlohmann::json::parse(kRepoJson);

    // Straight from the document, exactly as localListBranches does it.
    const auto direct = branchesFrom(doc);

    // Through the seed client, which fetches the same document first.
    FakeSeed seed;
    seed.replies["/repos/rad%3AzTEST"] = kRepoJson;
    SeedClient client("https://example.test");
    client.setTransport(seed.transport());
    const auto viaSeed = client.listBranches("rad:zTEST");

    // Byte-identical: a view must render either source without branching, and
    // a branch picker is no exception.
    LOGOS_ASSERT_EQ(direct.dump(), viaSeed.dump());
}

LOGOS_TEST(branches_from_passes_an_error_document_through_untouched)
{
    // localListBranches relies on this: it hands the local backend's reply
    // straight in, and an error must stay an error rather than becoming an
    // empty branch list that would render as "this repo has no branches".
    const auto err = makeError("repository not found locally");
    LOGOS_ASSERT_TRUE(isError(branchesFrom(err)));
    LOGOS_ASSERT_EQ(branchesFrom(err)["error"].get<std::string>(),
                    std::string("repository not found locally"));
}

// ---------------------------------------------------------------------------
// branchesFromRawJson — what RadicleImpl::localListBranches actually calls:
// parse the local backend's raw reply, then derive branches from it.
//
// The real Rust FFI backend always returns valid JSON (built with
// serde_json), so it can never trigger the malformed-JSON branch below by
// itself. This function exists specifically so that branch is directly
// testable with a hand-crafted string, rather than being dead code nothing
// exercises — see CLAUDE.md's note that this branch was previously
// unreachable in any test.
// ---------------------------------------------------------------------------

LOGOS_TEST(branches_from_raw_json_reports_a_named_error_for_unparseable_input)
{
    const auto out = branchesFromRawJson("{ this is not json");
    LOGOS_ASSERT_TRUE(isError(out));
    LOGOS_ASSERT_EQ(out["error"].get<std::string>(),
                    std::string("malformed reply from local storage"));
    // Not an empty branch list: "malformed reply" and "no branches" are
    // different answers.
    LOGOS_ASSERT_FALSE(out.contains("items"));
}

LOGOS_TEST(branches_from_raw_json_reports_the_same_error_for_a_completely_empty_string)
{
    const auto out = branchesFromRawJson("");
    LOGOS_ASSERT_TRUE(isError(out));
    LOGOS_ASSERT_EQ(out["error"].get<std::string>(),
                    std::string("malformed reply from local storage"));
}

LOGOS_TEST(branches_from_raw_json_derives_branches_from_valid_json_exactly_like_branchesFrom)
{
    const auto direct = branchesFrom(nlohmann::json::parse(kRepoJson));
    const auto viaRaw = branchesFromRawJson(kRepoJson);
    LOGOS_ASSERT_EQ(direct.dump(), viaRaw.dump());
}

LOGOS_TEST(branches_from_raw_json_passes_a_backend_error_object_through_untouched)
{
    // A well-formed JSON error object (what the real backend sends for "repo
    // not found") must reach branchesFrom() unchanged — parsing succeeds, so
    // this exercises the *other* branch, distinguishing it from the
    // malformed-JSON case above.
    const std::string raw = makeError("repository not found locally").dump();
    const auto out = branchesFromRawJson(raw);
    LOGOS_ASSERT_TRUE(isError(out));
    LOGOS_ASSERT_EQ(out["error"].get<std::string>(),
                    std::string("repository not found locally"));
}

// ---------------------------------------------------------------------------
// writeCapabilityFrom — what RadicleImpl::getCapabilities() actually calls to
// collapse LocalWriter::canWrite()'s raw reply into canWrite/
// writeUnavailableReason. LocalWriter has no fake transport (unlike
// SeedClient), and a real "canWrite:true" reply needs an actual signing key
// no test here can arrange — so this function exists to make BOTH branches of
// the collapse testable with a hand-crafted probe string.
// ---------------------------------------------------------------------------

/// The collapse this function exists for: a granted write must report an
/// EMPTY reason. A view checks this field to decide whether to show an
/// explanation, and a stale non-empty reason next to canWriteLocal:true would
/// be a contradiction on screen — an explanation for a write that is, in
/// fact, available.
LOGOS_TEST(write_capability_from_collapses_the_reason_to_empty_when_writable)
{
    // Deliberately includes a stray "reason" alongside canWrite:true (a
    // shape the real backend should never send, but the collapse must not
    // depend on the backend's good behaviour): if the ternary collapsing the
    // reason to "" on a writable answer were ever removed, this "reason"
    // value would leak through and this assertion would catch it. A probe
    // object with no "reason" key at all would pass either way, since
    // `.value("reason", "")` defaults to "" regardless — that shape was
    // tried first and could not tell a working collapse from a broken one.
    const auto out = writeCapabilityFrom(
        R"({"canWrite":true,"nodeId":"did:key:z6MkTest","reason":"stale reason that must not leak"})");
    LOGOS_ASSERT_TRUE(out["canWrite"].get<bool>());
    LOGOS_ASSERT_TRUE(out["writeUnavailableReason"].get<std::string>().empty());
}

/// A refusal must carry the backend's own reason through unchanged — the
/// whole point of probing at all is to tell a user WHY they cannot write.
LOGOS_TEST(write_capability_from_carries_the_backend_reason_through_when_not_writable)
{
    const auto out = writeCapabilityFrom(R"({"canWrite":false,"reason":"key is encrypted"})");
    LOGOS_ASSERT_FALSE(out["canWrite"].get<bool>());
    LOGOS_ASSERT_EQ(out["writeUnavailableReason"].get<std::string>(),
                    std::string("key is encrypted"));
}

LOGOS_TEST(write_capability_from_reports_a_named_reason_for_unparseable_input)
{
    const auto out = writeCapabilityFrom("{ not json");
    LOGOS_ASSERT_FALSE(out["canWrite"].get<bool>());
    LOGOS_ASSERT_FALSE(out["writeUnavailableReason"].get<std::string>().empty());
}

LOGOS_TEST(write_capability_from_defaults_to_not_writable_when_canWrite_is_missing)
{
    // A backend reply missing the field entirely must not be misread as
    // writable — the safe default on a malformed/incomplete answer is "no".
    const auto out = writeCapabilityFrom(R"({"reason":"something odd"})");
    LOGOS_ASSERT_FALSE(out["canWrite"].get<bool>());
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
