import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Creating an issue — the second write, and the one with two fields to lose.
 *
 * Same shape as tst_comment.qml, and for the same reason: this can fail by
 * throwing away something the user wrote, and a written-out issue description
 * is the most expensive thing in this UI to retype.
 *
 * The fake backend returns INPUT-DEPENDENT data, which is what makes the
 * reload assertions mean anything. `ListIssues` reports exactly the issues
 * created so far, so "the list reloaded after a create" is distinguishable
 * from "the list never reloaded" — the distinction a fake returning a fixed
 * list structurally cannot make, and the trap that left branch switching dead
 * for a whole milestone with every gate green.
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

    /// Issues created so far. `ListIssues` reports them, so the list's own
    /// length is the evidence a reload happened.
    property var issues: []

    property bool failWrites: false
    property bool announceFails: false
    property bool deferReplies: false
    property var pendingOk: null
    property var pendingFail: null

    function call(method, args, onOk, onFail, callSource) {
        calls.push(method);
        lastArgs = args;

        if (method === "CreateIssue") {
            var title = args[1];
            var ok = function () {
                root.issues.push({ id: "issue" + (root.issues.length + 1),
                                   title: title,
                                   author: { alias: "me" },
                                   state: { status: "open" } });
                var reply = { id: "issue" + root.issues.length };
                reply.announced = !root.announceFails;
                if (root.announceFails)
                    reply.announceError = "the local node is not running";
                onOk(reply);
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

        if (method === "ListIssues") {
            onOk({ items: root.issues.slice(), hasMore: false });
            return;
        }

        if (method === "GetIssue") {
            onOk({ id: args[1], title: "An issue",
                   author: { alias: "me" },
                   state: { status: "open" },
                   discussion: [] });
            return;
        }

        onOk({ items: [], hasMore: false });
    }

    function deliver(succeed) {
        var ok = pendingOk, fail = pendingFail;
        pendingOk = null;
        pendingFail = null;
        if (succeed) ok(); else fail();
    }

    // --- units under test ----------------------------------------------

    Ui.NewIssueForm {
        id: form
        anchors.fill: parent
        app: root
        rid: "rad:zTEST"
        canWrite: root.canWrite
        unavailableReason: root.writeUnavailableReason
    }

    Ui.IssuesTab {
        id: issuesTab
        anchors.fill: parent
        visible: false
        app: root
        rid: "rad:zTEST"
    }

    /// The real RepoView, so the wiring between the form and the list is
    /// asserted rather than reproduced. A test that called `issuesTab.reset()`
    /// itself would prove only that reset works — not that RepoView.onCreated
    /// actually calls it, which is the thing that would silently regress.
    Ui.RepoView {
        id: repoPage
        anchors.fill: parent
        visible: false
        app: root
        rid: "rad:zTEST"
        repo: ({ rid: "rad:zTEST",
                 payloads: { "xyz.radicle.project":
                             { data: { name: "r", defaultBranch: "main" },
                               meta: { head: "abc" } } } })
    }

    TestCase {
        name: "NewIssueForm"
        when: windowShown

        function init() {
            root.calls = [];
            root.issues = [];
            root.failWrites = false;
            root.announceFails = false;
            root.deferReplies = false;
            root.canWrite = true;
            root.writeUnavailableReason = "";
            root.source = "local";
            form.rid = "rad:zTEST";
            form.reset();
        }

        // ---- what may be submitted ------------------------------------

        function test_an_empty_form_cannot_be_submitted() {
            compare(form.canSubmit, false);
        }

        function test_a_title_alone_cannot_be_submitted() {
            // The backend refuses an empty description too. The two must agree
            // or the button offers what the write rejects.
            form.title = "a title";
            form.description = "";
            compare(form.canSubmit, false, "a description is required");
        }

        function test_a_description_alone_cannot_be_submitted() {
            form.title = "";
            form.description = "a description";
            compare(form.canSubmit, false, "a title is required");
        }

        function test_whitespace_only_fields_cannot_be_submitted() {
            form.title = "   ";
            form.description = "\n\t ";
            compare(form.canSubmit, false);
        }

        function test_both_fields_filled_can_be_submitted() {
            form.title = "a title";
            form.description = "a description";
            compare(form.canSubmit, true);
        }

        function test_submitting_an_incomplete_form_issues_no_call() {
            form.title = "a title";
            form.description = "";
            form.submit();
            compare(root.calls.indexOf("CreateIssue"), -1,
                    "submit() must be inert, not merely the button disabled: "
                    + "calls=" + root.calls.join(","));
        }

        function test_nothing_can_be_submitted_without_write_capability() {
            root.canWrite = false;
            form.title = "a title";
            form.description = "a description";
            compare(form.canSubmit, false,
                    "no signing key means no submit, whatever is typed");

            form.submit();
            compare(root.calls.indexOf("CreateIssue"), -1);
        }

        // ---- creating ---------------------------------------------------

        function test_a_create_sends_both_fields_to_the_backend() {
            form.title = "the title";
            form.description = "the description";
            form.submit();

            compare(root.calls.indexOf("CreateIssue") >= 0, true,
                    "calls=" + root.calls.join(","));
            compare(root.lastArgs[0], "rad:zTEST");
            compare(root.lastArgs[1], "the title", "the title is passed verbatim");
            compare(root.lastArgs[2], "the description",
                    "the description is passed verbatim");
        }

        function test_a_successful_create_clears_both_fields() {
            form.title = "the title";
            form.description = "the description";
            form.submit();

            compare(form.title, "", "a created issue is no longer a draft");
            compare(form.description, "");
            compare(form.error, "");
        }

        function test_a_successful_create_reports_the_new_issue_id() {
            // The id is what a caller opens next, so it has to arrive.
            var seen = null;
            function grab(id) { seen = id; }
            form.created.connect(grab);
            form.title = "the title";
            form.description = "the description";
            form.submit();
            form.created.disconnect(grab);

            compare(seen, "issue1", "created() must carry the new issue's id");
        }

        // ---- the failure that matters -----------------------------------

        function test_a_failed_create_keeps_both_fields() {
            // The whole reason this is a component rather than inline. A
            // written-out description is the most expensive thing this UI
            // could throw away, and clearing on failure is the easy mistake.
            root.failWrites = true;
            form.title = "a title I would hate to retype";
            form.description = "a description I would hate even more";
            form.submit();

            compare(form.title, "a title I would hate to retype",
                    "a failed create must NOT clear the title");
            compare(form.description, "a description I would hate even more",
                    "a failed create must NOT clear the description");
            verify(form.error !== "");
        }

        function test_a_failed_create_can_be_retried_and_then_succeeds() {
            root.failWrites = true;
            form.title = "retry title";
            form.description = "retry body";
            form.submit();
            compare(form.title, "retry title");

            root.failWrites = false;
            form.submit();
            compare(form.title, "", "the retry created the surviving draft");
            compare(root.issues.length, 1);
            compare(root.issues[0].title, "retry title");
        }

        function test_starting_a_create_clears_the_previous_error() {
            root.failWrites = true;
            form.title = "t";
            form.description = "d";
            form.submit();
            verify(form.error !== "");

            root.failWrites = false;
            form.submit();
            compare(form.error, "",
                    "a stale error must not outlive the attempt that fixed it");
        }

        // ---- announced vs merely saved -----------------------------------

        function test_an_unannounced_create_still_counts_as_created() {
            root.announceFails = true;
            form.title = "a title";
            form.description = "a description";
            form.submit();

            compare(form.title, "", "it was created — the draft is spent");
            compare(form.error, "",
                    "not announcing is NOT an error and must never show as one");
            compare(root.issues.length, 1, "and it really was written");
        }

        function test_an_unannounced_create_says_so() {
            root.announceFails = true;
            form.title = "a title";
            form.description = "a description";
            form.submit();

            verify(form.queuedNotice !== "",
                   "an unannounced create must say so, not pass silently");
            verify(form.queuedNotice.indexOf("not yet announced") >= 0,
                   "got: " + form.queuedNotice);
            verify(form.queuedNotice.indexOf("not running") >= 0,
                   "the node's reason must reach the user: " + form.queuedNotice);
        }

        function test_an_announced_create_says_nothing_extra() {
            form.title = "a title";
            form.description = "a description";
            form.submit();
            compare(form.queuedNotice, "");
        }

        function test_the_notice_and_the_error_are_never_both_set() {
            root.announceFails = true;
            form.title = "t"; form.description = "d";
            form.submit();
            verify(form.queuedNotice !== "");
            compare(form.error, "");

            root.announceFails = false;
            root.failWrites = true;
            form.title = "t2"; form.description = "d2";
            form.submit();
            verify(form.error !== "");
            compare(form.queuedNotice, "",
                    "a failure must clear the previous queued notice");
        }

        // ---- in flight ---------------------------------------------------

        function test_a_create_in_flight_blocks_a_second_one() {
            // Worse than a double comment: two clicks would leave two separate
            // issues that someone has to go and close.
            root.deferReplies = true;
            form.title = "once"; form.description = "only once";
            form.submit();

            compare(form.creating, true);
            compare(form.canSubmit, false, "locked while in flight");

            form.submit();   // the second click
            var attempts = 0;
            for (var i = 0; i < root.calls.length; ++i)
                if (root.calls[i] === "CreateIssue") attempts += 1;
            compare(attempts, 1, "only one request went out");

            root.deliver(true);
            compare(form.creating, false);
            compare(root.issues.length, 1, "exactly one issue exists");
        }

        function test_a_reply_after_switching_repository_is_dropped() {
            root.deferReplies = true;
            form.title = "for the first repo";
            form.description = "body";
            form.submit();

            form.rid = "rad:zOTHER";
            form.title = "for the other repo";
            form.description = "other body";

            root.deliver(true);

            compare(form.title, "for the other repo",
                    "the other repo's draft must survive");
            compare(form.description, "other body");
        }

        // ---- cancel and reset ---------------------------------------------

        function test_cancelling_is_reported() {
            var seen = 0;
            function grab() { seen += 1; }
            form.cancelled.connect(grab);
            form.cancelled();
            form.cancelled.disconnect(grab);
            compare(seen, 1);
        }

        function test_reset_clears_everything() {
            root.failWrites = true;
            form.title = "t"; form.description = "d";
            form.submit();
            verify(form.error !== "");

            form.reset();
            compare(form.title, "");
            compare(form.description, "");
            compare(form.error, "");
            compare(form.queuedNotice, "");
            compare(form.creating, false);
        }
    }

    TestCase {
        name: "IssuesTabReloadsAfterCreate"
        when: windowShown

        function init() {
            root.calls = [];
            root.issues = [];
            root.source = "local";
            issuesTab.rid = "rad:zTEST";
            issuesTab.reset();
        }

        /// Regression, found while writing the reload tests below.
        ///
        /// `IssuesTab` had no `count` property at all, yet `RepoView.issueCount`
        /// and `Main.issueCount` had both been reading `issues.count` since
        /// they were written. Both were therefore `undefined`, and a spec
        /// asserting `issueCount > 0` would have been comparing against
        /// undefined rather than a number. Nothing noticed because no spec
        /// asserts on it — `CommitsTab` has had the equivalent all along, so
        /// the gap was invisible by inspection. `PatchesTab` was missing it too.
        ///
        /// Fails before the fix with "Actual (): undefined".
        function test_the_tab_reports_how_many_rows_it_is_showing() {
            issuesTab.load();
            compare(typeof issuesTab.count, "number",
                    "count must be a real property, not undefined");
            compare(issuesTab.count, 0);

            root.issues.push({ id: "issue1", title: "one",
                               author: { alias: "me" },
                               state: { status: "open" } });
            issuesTab.reset();
            issuesTab.load();
            compare(issuesTab.count, 1, "and it must track the model");
        }

        /// The load-bearing one. IssuesTab is cache-first, so simply calling
        /// load() after a create serves the page from before it and the new
        /// issue is silently absent — a screen that looks like it worked while
        /// showing stale data. RepoView's onCreated calls reset() first; this
        /// asserts that reset-then-load is what actually picks the issue up.
        function test_a_created_issue_appears_only_after_the_cache_is_dropped() {
            issuesTab.load();
            compare(issuesTab.count, 0, "no issues to begin with");

            // Create one behind the tab's back, as the form does.
            root.issues.push({ id: "issue1", title: "a new issue",
                               author: { alias: "me" },
                               state: { status: "open" } });

            // A plain load() hits the cache and cannot see it.
            issuesTab.load();
            compare(issuesTab.count, 0,
                    "cache-first load() serves the page from before the create "
                    + "— which is why RepoView drops the cache first");

            // reset() then load() — what RepoView.onCreated actually does.
            issuesTab.reset();
            issuesTab.load();
            compare(issuesTab.count, 1,
                    "dropping the cache is what makes the new issue appear");
        }

        /// The wiring, asserted through the real RepoView rather than by
        /// re-doing what it does. This is what fails if `onCreated` is ever
        /// simplified to a plain `load()` — the create succeeds, the screen
        /// returns to the list, and the new issue is simply not on it.
        function test_repo_view_drops_the_cache_when_an_issue_is_created() {
            repoPage.tab = 2;
            repoPage.composingIssue = true;

            var form2 = findChild(repoPage, "newIssueForm");
            verify(form2 !== null, "the form must be reachable by objectName");

            form2.title = "created through RepoView";
            form2.description = "a description";
            form2.submit();

            compare(repoPage.composingIssue, false,
                    "a successful create closes the form");
            // It opened the new issue, which is where the user should land.
            compare(repoPage.openThread, "issue1",
                    "the new issue is opened rather than left to be hunted for");
            compare(root.issues.length, 1);
        }

        function test_the_reloaded_list_carries_the_new_issue() {
            root.issues.push({ id: "issue1", title: "the created one",
                               author: { alias: "me" },
                               state: { status: "open" } });
            issuesTab.reset();
            issuesTab.load();

            compare(issuesTab.count, 1);
            // Asserting on the count alone would pass against a list of the
            // wrong issue; the title says which one arrived.
            var seen = "";
            function grab(id) { seen = id; }
            issuesTab.itemActivated.connect(grab);
            issuesTab.itemActivated("issue1");
            issuesTab.itemActivated.disconnect(grab);
            compare(seen, "issue1");
        }
    }
}
