import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Commenting on an issue — the first write in this module.
 *
 * Every other failure here shows stale or missing data. This one can lose
 * something the user typed, so the tests are shaped around that: what happens
 * to the draft on failure, and whether the box is ever offered when submitting
 * it could not work.
 *
 * The fake backend returns INPUT-DEPENDENT data, which is load-bearing rather
 * than thorough. `GetIssue` returns a thread whose length is the number of
 * comments posted so far, so "the thread reloaded after a post" is
 * distinguishable from "the thread never reloaded". A fake returning the same
 * two comments every time would pass whether the reload happened or not — the
 * exact trap that left branch switching dead for a whole milestone with every
 * gate green.
 */
Item {
    id: root
    width: 900
    height: 600

    // --- fake backend --------------------------------------------------

    property var calls: []
    property var lastArgs: []
    property string source: "local"
    property bool canWrite: true
    property string writeUnavailableReason: ""

    /// Comments posted so far. `GetIssue` reports them, so the thread's own
    /// length is the evidence a reload happened.
    property var posted: []

    /// When true, CommentOnIssue fails instead of succeeding.
    property bool failWrites: false
    /// When true, the reply is held until `deliver()` is called — the only way
    /// to observe the in-flight state, which a synchronous fake cannot.
    property bool deferReplies: false
    property var pendingOk: null
    property var pendingFail: null

    function call(method, args, onOk, onFail, callSource) {
        calls.push(method);
        lastArgs = args;

        if (method === "CommentOnIssue") {
            var body = args[2];
            var ok = function () {
                root.posted.push(body);
                onOk({ id: "entry" + root.posted.length, announced: true });
            };
            var fail = function () { if (onFail) onFail(); };

            if (deferReplies) {
                pendingOk = ok;
                pendingFail = fail;
                return;
            }
            if (failWrites) fail(); else ok();
            return;
        }

        if (method === "GetIssue") {
            var discussion = [{ body: "the original description",
                                author: { alias: "someone" } }];
            for (var i = 0; i < posted.length; ++i)
                discussion.push({ body: posted[i], author: { alias: "me" } });
            onOk({ id: args[1], title: "An issue",
                   author: { alias: "someone" },
                   state: { status: "open" },
                   discussion: discussion });
            return;
        }

        onOk({ items: [], hasMore: false });
    }

    /// Release a held reply.
    function deliver(succeed) {
        var ok = pendingOk, fail = pendingFail;
        pendingOk = null;
        pendingFail = null;
        if (succeed) ok(); else fail();
    }

    // --- units under test ----------------------------------------------

    Ui.CommentComposer {
        id: composer
        anchors.fill: parent
        app: root
        rid: "rad:zTEST"
        itemId: "issue1"
        canWrite: root.canWrite
    }

    Ui.ThreadView {
        id: thread
        anchors.fill: parent
        visible: false
        app: root
        rid: "rad:zTEST"
        canWrite: root.canWrite
        writeUnavailableReason: root.writeUnavailableReason
    }

    TestCase {
        name: "CommentComposer"
        when: windowShown

        function init() {
            root.calls = [];
            root.posted = [];
            root.failWrites = false;
            root.deferReplies = false;
            root.canWrite = true;
            root.writeUnavailableReason = "";
            root.source = "local";
            composer.rid = "rad:zTEST";
            composer.itemId = "issue1";
            composer.reset();
        }

        // ---- what may be submitted ------------------------------------

        function test_an_empty_draft_cannot_be_submitted() {
            composer.body = "";
            compare(composer.canSubmit, false, "nothing to post");
        }

        function test_a_whitespace_only_draft_cannot_be_submitted() {
            // The backend refuses these too. The two must agree on what counts
            // as empty, or the button offers something the write rejects.
            composer.body = "   \n\t ";
            compare(composer.canSubmit, false,
                    "whitespace is not a comment");
        }

        function test_submitting_an_empty_draft_issues_no_call() {
            composer.body = "";
            composer.submit();
            compare(root.calls.indexOf("CommentOnIssue"), -1,
                    "submit() must be inert, not merely the button disabled: "
                    + "calls=" + root.calls.join(","));
        }

        function test_a_real_draft_can_be_submitted() {
            composer.body = "a comment";
            compare(composer.canSubmit, true);
        }

        function test_nothing_can_be_submitted_without_write_capability() {
            root.canWrite = false;
            composer.body = "a comment";
            compare(composer.canSubmit, false,
                    "no signing key means no submit, whatever is typed");

            composer.submit();
            compare(root.calls.indexOf("CommentOnIssue"), -1,
                    "and submit() must issue no call either");
        }

        function test_nothing_can_be_submitted_without_an_issue() {
            composer.itemId = "";
            composer.body = "a comment";
            compare(composer.canSubmit, false);
        }

        // ---- posting ---------------------------------------------------

        function test_a_successful_post_sends_the_body_to_the_backend() {
            composer.body = "hello there";
            composer.submit();

            compare(root.calls.indexOf("CommentOnIssue") >= 0, true,
                    "calls=" + root.calls.join(","));
            compare(root.lastArgs[0], "rad:zTEST", "the rid is passed");
            compare(root.lastArgs[1], "issue1", "the issue id is passed");
            compare(root.lastArgs[2], "hello there",
                    "the body is passed verbatim");
        }

        function test_a_successful_post_clears_the_draft() {
            composer.body = "hello there";
            composer.submit();
            compare(composer.body, "", "a posted comment is no longer a draft");
            compare(composer.error, "", "and there is nothing to report");
        }

        function test_a_successful_post_announces_itself() {
            var seen = 0;
            function grab() { seen += 1; }
            composer.posted.connect(grab);
            composer.body = "hello";
            composer.submit();
            composer.posted.disconnect(grab);

            compare(seen, 1, "posted() drives the thread reload");
        }

        // ---- the failure that matters ----------------------------------

        function test_a_failed_post_keeps_the_draft() {
            // The whole reason this control is a component rather than three
            // lines inline. Retyping a lost comment is the outcome worth
            // designing against, and clearing on failure is the easy mistake.
            root.failWrites = true;
            composer.body = "something I would hate to retype";
            composer.submit();

            compare(composer.body, "something I would hate to retype",
                    "a failed post must NOT clear the draft");
            verify(composer.error !== "");
        }

        function test_a_failed_post_can_be_retried_and_then_succeeds() {
            root.failWrites = true;
            composer.body = "retry me";
            composer.submit();
            compare(composer.body, "retry me");

            root.failWrites = false;
            composer.submit();
            compare(composer.body, "", "the retry posted the surviving draft");
            compare(root.posted.length, 1);
            compare(root.posted[0], "retry me");
        }

        function test_starting_a_post_clears_the_previous_error() {
            root.failWrites = true;
            composer.body = "one";
            composer.submit();
            verify(composer.error !== "");

            root.failWrites = false;
            composer.submit();
            compare(composer.error, "",
                    "a stale error must not outlive the attempt that fixed it");
        }

        // ---- in flight --------------------------------------------------

        function test_a_post_in_flight_blocks_a_second_one() {
            // Without this a double-click posts the same comment twice, and
            // there is no way to take one back.
            root.deferReplies = true;
            composer.body = "once";
            composer.submit();

            compare(composer.posting, true);
            compare(composer.canSubmit, false, "locked while in flight");

            composer.submit();   // the second click
            var attempts = 0;
            for (var i = 0; i < root.calls.length; ++i)
                if (root.calls[i] === "CommentOnIssue") attempts += 1;
            compare(attempts, 1, "only one request went out");

            root.deliver(true);
            compare(composer.posting, false);
        }

        function test_a_reply_for_an_abandoned_issue_is_dropped() {
            // Same staleness guard every loader here uses. Without it, a reply
            // landing after the user opened a different issue would clear that
            // issue's draft — losing text belonging to a screen the reply has
            // nothing to do with.
            root.deferReplies = true;
            composer.body = "for issue1";
            composer.submit();

            composer.itemId = "issue2";
            composer.body = "a draft for issue2";

            root.deliver(true);

            compare(composer.body, "a draft for issue2",
                    "issue2's draft must survive issue1's reply");
        }

        function test_a_reply_after_switching_repository_is_dropped() {
            root.deferReplies = true;
            composer.body = "for the first repo";
            composer.submit();

            composer.rid = "rad:zOTHER";
            composer.body = "for the other repo";

            root.deliver(true);

            compare(composer.body, "for the other repo",
                    "the other repo's draft must survive");
        }

        // ---- reset ------------------------------------------------------

        function test_reset_clears_the_draft_and_the_error() {
            root.failWrites = true;
            composer.body = "draft";
            composer.submit();
            verify(composer.error !== "");

            composer.reset();
            compare(composer.body, "");
            compare(composer.error, "");
            compare(composer.posting, false);
        }
    }

    TestCase {
        name: "ThreadViewComposer"
        when: windowShown

        function init() {
            root.calls = [];
            root.posted = [];
            root.failWrites = false;
            root.deferReplies = false;
            root.canWrite = true;
            root.writeUnavailableReason = "";
            root.source = "local";
            thread.kind = "Issues";
            thread.rid = "rad:zTEST";
            thread.itemId = "";
        }

        // ---- when the box is offered at all -----------------------------

        function test_the_box_is_offered_for_a_local_issue() {
            thread.itemId = "issue1";
            compare(thread.commentable, true);
        }

        function test_the_box_is_not_offered_while_browsing_a_seed() {
            // A repo open from a seed may not be in local storage at all, so
            // the write could not be aimed at anything. Showing a box that
            // fails for a reason the user cannot act on is worse than none.
            root.source = "remote";
            thread.itemId = "issue1";
            compare(thread.commentable, false);
        }

        function test_the_box_is_not_offered_for_a_patch() {
            // A patch comment belongs to a revision, and getPatch does not
            // serialize revision threads — so it would have nowhere to appear.
            thread.kind = "Patches";
            thread.itemId = "patch1";
            compare(thread.commentable, false);
        }

        // ---- the reload, which is the point of posted() ------------------

        function test_a_posted_comment_appears_in_the_thread() {
            thread.itemId = "issue1";
            compare(thread.discussion.length, 1, "just the root comment");

            root.posted.push("a new comment");
            thread.load();

            compare(thread.discussion.length, 2,
                    "the reload must pick up the new comment");
            compare(thread.discussion[1].body, "a new comment");
        }

        function test_opening_a_different_issue_clears_the_draft() {
            // A draft belongs to the issue it was written against. Carrying it
            // across would let one issue's text be posted onto another.
            thread.itemId = "issue1";
            var box = findChild(thread, "commentComposer");
            verify(box !== null, "the composer must be reachable by objectName");

            box.body = "a draft for issue1";
            thread.itemId = "issue2";

            compare(box.body, "",
                    "the draft must not follow the user to another issue");
        }

        function test_the_composer_survives_the_reload_a_post_triggers() {
            // load() clears `item` and `loadedOnce` on the way in. If the
            // panel were gated on either, posting would destroy the composer
            // during the very reload the post triggered — and the user would
            // watch the box vanish as their comment went in.
            //
            // `thread` is hidden in this harness (it overlaps the composer
            // under test), and a child of a hidden item reports visible:false
            // whatever its own binding says. So the thread is shown for the
            // duration of this one test and restored afterwards, the same way
            // tst_clicks.qml does for the commits tab.
            thread.visible = true;
            try {
                thread.itemId = "issue1";
                var panel = findChild(thread, "commentComposerPanel");
                verify(panel !== null,
                       "the panel must be reachable by objectName");
                compare(panel.visible, true, "offered once an issue is open");

                thread.load();
                compare(panel.visible, true,
                        "the composer must stay put across its own refresh");
            } finally {
                thread.visible = false;
            }
        }
    }
}
