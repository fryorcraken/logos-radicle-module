import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Rows respond to a real mouse click.
 *
 * Every other test in this directory drives components by setting properties
 * or calling functions, which is why two click-dead rows shipped: the issue
 * rows (reported by the user) and the commit rows (found later by audit). Both
 * had a MouseArea with hoverEnabled and no onClicked, and the test written for
 * the first one emitted the signal by hand — so deleting the handler left it
 * passing.
 *
 * These tests use TestCase's mouseClick against the real delegate, so removing
 * an onClicked makes them fail.
 *
 * PatchesTab's threadRow had the same shape of risk (a click-driven detail
 * view) with no coverage here at all — flagged by the pre-release coverage
 * review alongside nav.busy/nav.error, the syncEpoch race, and CommitView.
 * Covered below the same way commits is: shown for real for the duration of
 * one test, since it overlaps issues/commits and stays hidden otherwise.
 */
Item {
    width: 900
    height: 700

    property var lastCall: ""

    function call(method, args, onOk, onFail) {
        lastCall = method;
        if (method === "ListIssues" || method === "ListPatches")
            onOk({ items: [{ id: "i1", title: "One", state: { status: "open" },
                             author: { alias: "someone" } }],
                   hasMore: false });
        else if (method === "ListCommits")
            onOk({ items: [{ id: "0123456789abcdef0123456789abcdef01234567",
                             summary: "A commit",
                             author: { name: "Someone" },
                             committer: { time: 1700000000 } }],
                   hasMore: false });
        else onOk({ items: [], hasMore: false });
    }

    Ui.IssuesTab {
        id: issues
        anchors.fill: parent
        app: parent
        rid: "rad:zTEST"
    }

    Ui.CommitsTab {
        id: commits
        anchors.fill: parent
        visible: false
        app: parent
        rid: "rad:zTEST"
        branch: "main"
    }

    Ui.PatchesTab {
        id: patches
        anchors.fill: parent
        visible: false
        app: parent
        rid: "rad:zTEST"
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

    TestCase {
        name: "RowsAreClickable"
        when: windowShown

        function test_an_issue_row_click_activates_it() {
            issues.load();
            wait(50);

            var row = findByName(issues, "issueRow");
            verify(row !== null, "no issueRow delegate was rendered");

            var seen = "";
            function grab(id) { seen = id; }
            issues.itemActivated.connect(grab);
            // A real click, not a hand-emitted signal: this is what the
            // previous test failed to do, which is how a row with no
            // onClicked passed.
            mouseClick(row, row.width / 2, row.height / 2);
            issues.itemActivated.disconnect(grab);

            compare(seen, "i1", "clicking an issue row must activate it");
        }

        function test_a_commit_row_click_activates_it() {
            commits.load();
            wait(50);

            var row = findByName(commits, "commitRow");
            verify(row !== null, "no commitRow delegate was rendered");

            // commits and issues overlap (both anchors.fill: parent), and
            // stay hidden by default so issues' own click test does not hit
            // a commits row instead. mouseClick cannot reach an invisible
            // item's children, so this test needs the tab shown for real.
            commits.visible = true;
            var seen = "";
            function grab(sha) { seen = sha; }
            commits.commitActivated.connect(grab);
            mouseClick(row, row.width / 2, row.height / 2);
            commits.commitActivated.disconnect(grab);
            commits.visible = false;

            compare(seen, "0123456789abcdef0123456789abcdef01234567",
                    "clicking a commit row must activate it");
        }

        function test_a_patch_row_click_activates_it() {
            // PatchesTab's rows used to share IssuesTab's "threadRow" name.
            // They are "patchRow" and "issueRow" now, because a sitometres
            // spec searches the whole app rather than one tab and the shared
            // name matched both sets of delegates — a click by index landed on
            // whichever list came first, reported success, and opened nothing.
            // This test could not see that: findByName is scoped to one tab.
            //
            // All three tabs still overlap (anchors.fill: parent) and stay
            // hidden by default — same reason as commits above: mouseClick
            // cannot reach an invisible item's children, so this test needs the
            // tab shown for real.
            patches.load();
            wait(50);

            var row = findByName(patches, "patchRow");
            verify(row !== null, "no patchRow delegate was rendered");

            patches.visible = true;
            var seen = "";
            function grab(id) { seen = id; }
            patches.itemActivated.connect(grab);
            mouseClick(row, row.width / 2, row.height / 2);
            patches.itemActivated.disconnect(grab);
            patches.visible = false;

            compare(seen, "i1", "clicking a patch row must activate it");
        }

        function test_rows_show_a_pointer_cursor() {
            // A row that does nothing should not look clickable, and one that
            // does should. Both rows failed this before they had handlers.
            issues.load();
            commits.load();
            patches.load();
            wait(50);
            compare(findByName(issues, "issueRow").cursorShape, Qt.PointingHandCursor);
            compare(findByName(commits, "commitRow").cursorShape, Qt.PointingHandCursor);
            compare(findByName(patches, "patchRow").cursorShape, Qt.PointingHandCursor);
        }
    }
}
