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

            var row = findByName(issues, "threadRow");
            verify(row !== null, "no threadRow delegate was rendered");

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

        function test_rows_show_a_pointer_cursor() {
            // A row that does nothing should not look clickable, and one that
            // does should. Both rows failed this before they had handlers.
            issues.load();
            commits.load();
            wait(50);
            compare(findByName(issues, "threadRow").cursorShape, Qt.PointingHandCursor);
            compare(findByName(commits, "commitRow").cursorShape, Qt.PointingHandCursor);
        }
    }
}
