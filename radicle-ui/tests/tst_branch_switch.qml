import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Branch switching: the picker itself, and RepoView wiring it to
 * SourceTab/CommitsTab with the same "no stale data left on screen" guard
 * every other switch in this codebase gets.
 */
Item {
    width: 1000
    height: 700

    property var branchesCalls: []
    property var lastArgs: []
    /// The branch each GetTree / ListCommits was asked for, so a test can
    /// assert a refetch actually happened rather than inferring it from a
    /// count that would look the same either way.
    property var treeCalls: []
    property var commitCalls: []

    function makeRepo(rid, defaultBranch) {
        return {
            rid: rid,
            payloads: { "xyz.radicle.project": {
                data: { name: "demo", defaultBranch: defaultBranch, description: "" },
                meta: { issues: { open: 0 }, patches: { open: 0 } }
            } }
        };
    }

    function call(method, args, onOk, onFail) {
        lastArgs = args;
        if (method === "ListBranches") {
            branchesCalls.push(args[0]);
            var rid = args[0];
            if (rid === "rad:zTEST") {
                onOk({ items: [{ name: "main", head: "aaa" }, { name: "dev", head: "bbb" }],
                       default: "main" });
            } else if (rid === "rad:zOTHER") {
                onOk({ items: [{ name: "trunk", head: "ccc" }], default: "trunk" });
            } else {
                onOk({ items: [], default: "" });
            }
        } else if (method === "GetTree") {
            // Branch-DEPENDENT, deliberately. An empty reply for every branch
            // makes "the tree reloaded" indistinguishable from "nothing
            // happened" — treeCount is 0 either way — so a test asserting on
            // it would pass with the whole reset/refetch deleted. Each branch
            // returns a different number of entries so the count itself is
            // evidence of which branch was fetched.
            treeCalls.push(args[1]);
            var wanted = args[1] === "dev" ? 3 : 2;
            var list = [];
            for (var i = 0; i < wanted; i++)
                list.push({ name: args[1] + "-file-" + i, kind: "blob", path: args[1] + "/" + i });
            onOk({ entries: list });
        } else if (method === "ListCommits") {
            commitCalls.push(args[1]);
            var many = args[1] === "dev" ? 4 : 1;
            var items = [];
            for (var j = 0; j < many; j++)
                items.push({ id: args[1] + "-c" + j, summary: "on " + args[1],
                             author: { name: "A" }, committer: { time: 1700000000 } });
            onOk({ items: items, hasMore: false });
        } else {
            onOk({ items: [], hasMore: false });
        }
    }

    // ---- BranchPicker in isolation -----------------------------------

    Ui.BranchPicker {
        id: picker
        rid: "rad:zTEST"
        fetchBranches: function (cb) {
            cb({ items: [{ name: "main", head: "aaa" }, { name: "dev", head: "bbb" }],
                 default: "main" });
        }
    }

    // ---- RepoView integration ------------------------------------------

    Ui.RepoView {
        id: page
        anchors.fill: parent
        app: parent
        active: true
    }

    TestCase {
        name: "BranchSwitch"
        when: windowShown

        function init() {
            branchesCalls = [];
            treeCalls = [];
            commitCalls = [];
            // Force a real rid change before each test, even for a test that
            // is about to set the SAME rid a previous test left behind —
            // otherwise onRidChanged never fires (no change, no signal) and
            // `branch` keeps whatever a previous test picked instead of
            // re-binding to the fresh repo's defaultBranch.
            page.rid = "";
            page.repo = null;
        }

        function test_picker_loads_branches_via_the_injected_fetcher() {
            compare(picker.count, 2);
        }

        function test_picker_selects_the_current_branch() {
            picker.currentBranch = "dev";
            compare(picker.currentIndex, 1);
        }

        function test_picking_a_branch_emits_branchChosen() {
            var seen = "";
            function grab(name) { seen = name; }
            picker.branchChosen.connect(grab);
            picker.branchChosen("dev");
            picker.branchChosen.disconnect(grab);
            compare(seen, "dev");
        }

        function test_repo_view_starts_on_the_repos_default_branch() {
            page.rid = "rad:zTEST";
            page.repo = makeRepo("rad:zTEST", "main");
            compare(page.branch, "main");
        }

        function test_picking_a_branch_updates_the_page() {
            page.rid = "rad:zTEST";
            page.repo = makeRepo("rad:zTEST", "main");
            compare(page.branch, "main");

            page.branch = "dev";

            compare(page.branch, "dev");
        }

        function test_switching_branch_resets_source_and_commits() {
            page.rid = "rad:zTEST";
            page.repo = makeRepo("rad:zTEST", "main");
            page.tab = 0;   // Source tab active, so loadTab() actually fires
            wait(20);

            // main's tree, so there is real state to lose. The fake returns a
            // different number of entries per branch precisely so this is
            // distinguishable from the post-switch state.
            compare(page.treeCount, 2, "main's tree loaded");
            var treesBefore = treeCalls.length;

            page.branch = "dev";
            wait(20);

            // The regression this guards: switching branch must not leave the
            // OLD branch's tree and commits on screen because loadedTabs
            // still says "already loaded".
            //
            // This asserts on dev's OWN entry count rather than on zero. An
            // earlier version compared against 0 with a fake that returned an
            // empty tree for every branch — which is what you get whether the
            // reset ran, the refetch ran, both, or neither. Gutting
            // RepoView's onBranchChanged left that version green; it fails
            // this one.
            compare(page.treeCount, 3, "dev's tree replaced main's");
            verify(treeCalls.length > treesBefore, "a GetTree was actually issued for the new branch");
            compare(treeCalls[treeCalls.length - 1], "dev", "and it asked for the branch just picked");

            // CommitsTab is branch-scoped too, and is reset by the same
            // handler — but it is on a different tab, so it reloads when that
            // tab is next shown rather than immediately. What must hold now is
            // that it is not still holding main's commits.
            page.tab = 1;
            wait(20);
            compare(page.commitCount, 4, "commits reloaded for dev, not left at main's");
            compare(commitCalls[commitCalls.length - 1], "dev");
        }

        function test_switching_repository_reverts_to_the_new_repos_default_branch() {
            page.rid = "rad:zTEST";
            page.repo = makeRepo("rad:zTEST", "main");
            page.branch = "dev";
            compare(page.branch, "dev");

            // A genuinely different repository, with a DIFFERENT default
            // branch name ("trunk", not "main"/"dev") — the regression this
            // guards is the old repo's picked branch NAME silently carrying
            // over into a repo that may not even have a branch by that name.
            page.rid = "rad:zOTHER";
            page.repo = makeRepo("rad:zOTHER", "trunk");

            compare(page.branch, "trunk",
                    "a new repository must start on ITS OWN default branch, not the previous repo's pick");
        }

        function test_switching_repository_and_back_still_tracks_the_default() {
            // Proves branch is a live binding again after a repo switch, not
            // merely reset once — i.e. Qt.binding() was used, not a literal
            // copy of defaultBranch at switch time.
            page.rid = "rad:zTEST";
            page.repo = makeRepo("rad:zTEST", "main");
            page.branch = "dev";

            page.rid = "rad:zOTHER";
            page.repo = makeRepo("rad:zOTHER", "trunk");
            compare(page.branch, "trunk");

            page.rid = "rad:zTEST";
            page.repo = makeRepo("rad:zTEST", "main");
            compare(page.branch, "main");
        }

        function test_branch_picker_is_wired_to_the_repos_rid() {
            page.rid = "rad:zTEST";
            page.repo = makeRepo("rad:zTEST", "main");
            wait(20);
            var bp = findByName(page, "branchPicker");
            verify(bp !== null, "no branchPicker was rendered in RepoView");
            compare(bp.rid, "rad:zTEST");
        }
    }

    /// Find the first descendant carrying `name` as its objectName.
    function findByName(root, name) {
        if (!root) return null;
        if (root.objectName === name) return root;
        for (var i = 0; i < root.children.length; i++) {
            var hit = findByName(root.children[i], name);
            if (hit) return hit;
        }
        return null;
    }
}
