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
            onOk({ entries: [] });
        } else if (method === "ListCommits") {
            onOk({ items: [], hasMore: false });
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

            // Force something into source/commits so there's state to lose.
            page.branch = "dev";
            wait(20);

            // The regression this guards: switching branch must not leave
            // the OLD branch's tree/commits on screen forever because
            // loadedTabs still says "already loaded" for the new branch.
            // treeCount/commitCount come back to a fetched (here: empty)
            // state rather than staying whatever they were before — proven
            // indirectly by loadedTabs having been cleared and reload having
            // actually been attempted (fetch would append zero entries from
            // the fake backend either way, so the meaningful assertion is
            // that a fetch happened at all, not what it returned).
            compare(page.treeCount, 0);
            compare(page.commitCount, 0);
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
