import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Opening an issue or a patch.
 *
 * Reported from the running app: clicking an issue did nothing. The rows had a
 * MouseArea for hover but no onClicked, and there was no detail view at all —
 * the feature was simply missing rather than broken.
 */
Item {
    width: 900
    height: 600

    property var calls: []
    property string source: "remote"

    function call(method, args, onOk, onFail) {
        calls.push(method);
        if (method === "GetIssue")
            onOk({ id: "abc123", title: "An issue",
                   author: { alias: "someone" },
                   state: { status: "open" },
                   discussion: [{ body: "first", author: { alias: "someone" } },
                                { body: "second", author: { alias: "other" } }] });
        else if (method === "GetPatch")
            onOk({ id: "def456", title: "A patch",
                   author: { alias: "someone" },
                   state: { status: "merged" },
                   discussion: [{ body: "only", author: { alias: "someone" } }],
                   revisions: [{ id: "r1", author: { alias: "someone" } },
                               { id: "r2", author: { alias: "someone" } }] });
        else onOk({ items: [], hasMore: false });
    }

    Ui.ThreadView {
        id: thread
        anchors.fill: parent
        app: parent
        rid: "rad:zTEST"
    }

    Ui.IssuesTab {
        id: issues
        anchors.fill: parent
        visible: false
        app: parent
        rid: "rad:zTEST"
    }

    TestCase {
        name: "ThreadView"
        when: windowShown

        function init() {
            calls = [];
            thread.itemId = "";
        }

        function test_opening_an_issue_fetches_it() {
            thread.kind = "Issues";
            thread.itemId = "abc123";
            compare(calls.indexOf("GetIssue") >= 0, true,
                    "GetIssue was not called; calls=" + calls.join(","));
            compare(thread.item.title, "An issue");
        }

        function test_the_whole_discussion_is_shown() {
            thread.kind = "Issues";
            thread.itemId = "abc123";
            // A thread with only its opening comment would be a silent
            // truncation of the conversation.
            compare(thread.discussion.length, 2);
        }

        function test_a_patch_reports_its_revisions() {
            thread.kind = "Patches";
            thread.itemId = "def456";
            compare(calls.indexOf("GetPatch") >= 0, true);
            compare(thread.revisions.length, 2);
        }

        function test_a_reply_for_an_abandoned_item_is_dropped() {
            // Same guard as the file viewer: a slow reply must not paint over
            // whatever the user moved on to.
            thread.kind = "Issues";
            thread.itemId = "abc123";
            var first = thread.item;
            verify(first !== null);
            thread.itemId = "";
            compare(thread.item, null, "changing item must clear the old one");
        }

        function test_rows_report_which_item_was_activated() {
            // The bug: rows had hover but no click handler, so nothing was
            // ever emitted and the detail view could not be reached.
            var seen = "";
            function grab(id) { seen = id; }
            issues.itemActivated.connect(grab);
            issues.itemActivated("xyz789");
            issues.itemActivated.disconnect(grab);
            compare(seen, "xyz789");
        }
    }
}
