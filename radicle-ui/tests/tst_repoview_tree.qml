import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * RepoView must render a tree for a repo whose branches are all peer-qualified.
 *
 * `local.yaml` step 9 fails there — `localGetTree` is called and the backend
 * returns entries for the same arguments, but `treeCount` stays 0. That is a
 * wiring failure between RepoView, BranchPicker and SourceTab, which is
 * exactly the layer a component test can see and the backend probes cannot.
 *
 * The fake returns a DIFFERENT number of entries per branch, so the count
 * itself says which branch was fetched — a fake answering the same for every
 * input could not tell "fetched the right branch" from "fetched nothing".
 */
Item {
    id: harness
    width: 1000
    height: 700

    property var treeCalls: []
    property var branchCalls: []

    function makeRepo(rid, defaultBranch) {
        return {
            rid: rid,
            payloads: { "xyz.radicle.project": {
                data: { name: "seeded", defaultBranch: defaultBranch, description: "" },
                meta: { issues: { open: 0 }, patches: { open: 0 } }
            } }
        };
    }

    // Mirrors the seeded CI profile: the repo's own `master` plus a peer's
    // branches, all reported by list_branches as qualified names.
    function call(method, args, onOk, onFail) {
        if (method === "ListBranches") {
            branchCalls.push(args[0]);
            onOk({
                items: [
                    { name: "master", head: "aaaaaaa1",
                      remote: "z6MkSelfAAA", isLocal: true },
                    { name: "feature/seeded", head: "aaaaaaa2",
                      remote: "z6MkSelfAAA", isLocal: true },
                    { name: "z6MkPeerBBB/master", head: "bbbbbbb1",
                      remote: "z6MkPeerBBB", isLocal: false },
                    { name: "z6MkPeerBBB/their-work", head: "bbbbbbb2",
                      remote: "z6MkPeerBBB", isLocal: false }
                ],
                default: "master"
            });
        } else if (method === "GetTree") {
            // Record the sha the view actually asked for. This is the whole
            // point of the test: if `branch` is empty or unresolvable when the
            // fetch goes out, it shows up here.
            treeCalls.push(args[1]);
            var wanted = args[1] === "feature/seeded" ? 3 : 2;
            var list = [];
            for (var i = 0; i < wanted; i++)
                list.push({ name: "f" + i, kind: "blob", path: "f" + i });
            onOk({ entries: list });
        } else if (method === "GetReadme") {
            onOk({ path: "README.md", content: "# seeded\n" });
        } else {
            onOk({ items: [], hasMore: false });
        }
    }

    Ui.RepoView {
        id: page
        anchors.fill: parent
        app: harness
        active: true
    }

    TestCase {
        name: "RepoViewTree"
        when: windowShown

        function init() {
            treeCalls = [];
            branchCalls = [];
            page.rid = "";
            page.repo = null;
        }

        /// The failing e2e step, reduced: open a repo, expect a populated tree.
        function test_opening_a_repo_renders_its_tree() {
            page.rid = "rad:zSEEDED";
            page.repo = makeRepo("rad:zSEEDED", "master");

            tryVerify(function () { return page.treeCount > 0; }, 2000,
                      "the tree must render. GetTree was called with: "
                      + JSON.stringify(treeCalls));
        }

        /// And it must have asked for the DEFAULT branch, not "" or a peer's.
        function test_the_tree_is_fetched_for_the_default_branch() {
            page.rid = "rad:zSEEDED";
            page.repo = makeRepo("rad:zSEEDED", "master");

            tryVerify(function () { return treeCalls.length > 0; }, 2000,
                      "expected a GetTree call");
            compare(treeCalls[0], "master",
                    "the view must fetch the repo's default branch");
        }

        /// The picker must show it, not blank — the regression that started
        /// this whole redesign.
        function test_the_picker_shows_the_default_branch() {
            page.rid = "rad:zSEEDED";
            page.repo = makeRepo("rad:zSEEDED", "master");

            tryVerify(function () { return page.branchLabel !== ""; }, 2000,
                      "the picker must not be blank");
            compare(page.branchLabel, "master");
        }
    }
}
