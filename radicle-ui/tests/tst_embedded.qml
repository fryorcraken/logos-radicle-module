import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Embedded must show "not implemented", never a repository list.
 *
 * ## The bug this pins
 *
 * `SourceState` derives the backend METHOD PREFIX from the mode, and both
 * `local` and `embedded` derive to `"local"` — deliberately, because the
 * prefix is not the mode (see SourceState.qml). Every staleness guard in this
 * codebase compares `app.source`, which is that prefix. So switching
 * `local` -> `embedded` leaves an in-flight `localListRepos` whose reply
 * passes the guard unchanged: the ATTACHED node's repositories append into a
 * list rendered under a segment reading "Embedded".
 *
 * That is precisely the identity confusion this milestone exists to prevent,
 * and the backend has already been fixed for the same lie once —
 * `storeForSettings()` used to let `embedded` fall through to the attached
 * profile's home. This is the same lie one layer up.
 *
 * ## Why "no repositories" is not an acceptable answer either
 *
 * With the backend correctly refusing (`localUnavailable`), the fail path sets
 * `loadedOnce` and the list renders "No repositories matched" — which claims
 * an embedded node exists and holds nothing. It does not exist. The empty
 * claim is a different falsehood, not a lesser one, so the requirement is a
 * distinct not-implemented state and NO request at all.
 *
 * ## Why the fake defers
 *
 * A synchronous fake cannot distinguish "did not request" from "requested and
 * discarded the reply" — both end with an empty list. This one holds its
 * replies, so the test can assert on the request log itself, and can deliver a
 * stale reply AFTER the switch to prove it cannot repopulate the list.
 *
 * And it answers with INPUT-DEPENDENT data (repos named after the scope it was
 * asked for), so "cleared" is distinguishable from "never populated" — the
 * lesson CLAUDE.md records a whole milestone being lost to.
 */
Item {
    id: root
    width: 900
    height: 600

    // ------------------------------------------------------------------
    // A fake standing in for Main.qml's call routing, holding every reply.
    // ------------------------------------------------------------------
    QtObject {
        id: app

        /// The mode in force, exactly as Main.qml binds it from capabilities.
        property string mode: "local"

        /// The derived method prefix. NOT settable, and identical for `local`
        /// and `embedded` — which is the whole reason this bug exists, so the
        /// fixture reproduces it rather than papering over it.
        readonly property string source: (mode === "local" || mode === "embedded")
                                         ? "local" : "remote"

        /// Which modes this build can start, exactly as capabilities report it.
        /// Held as the SET rather than as a boolean per mode, so `modeStartable`
        /// below is derived here the same way Main.qml derives it — a fixture
        /// that hardcoded the boolean could not tell a RepoList reading the
        /// capability from one still comparing against the word "embedded".
        property var startableModes: ["explore", "local"]

        readonly property bool modeStartable: {
            for (var i = 0; i < startableModes.length; i++)
                if (startableModes[i] === mode) return true;
            return false;
        }

        /// Every call this fake was asked to make, in order. Asserted on
        /// directly: "the list is empty" and "no request was issued" are
        /// different facts, and only the log can tell them apart.
        property var callLog: []

        property var pending: null

        function call(method, args, onOk, onFail) {
            callLog.push(source + method);
            pending = { method: method, args: args, onOk: onOk, onFail: onFail };
        }

        /// Answer the held request with data derived from its own arguments, so
        /// a list populated by THIS reply is distinguishable from one populated
        /// by any other.
        function deliver() {
            if (pending === null) return false;
            var scope = pending.args[0];
            var p = pending;
            pending = null;
            p.onOk({ items: [
                { rid: "rad:z" + scope + "1", name: scope + "-repo-one" },
                { rid: "rad:z" + scope + "2", name: scope + "-repo-two" }
            ], hasMore: false });
            return true;
        }

        function reset() {
            callLog = [];
            pending = null;
        }
    }

    Ui.RepoList {
        id: list
        anchors.fill: parent
        app: app
    }

    function findByName(node, name) {
        if (!node) return null;
        if (node.objectName === name) return node;
        for (var i = 0; i < node.children.length; i++) {
            var hit = findByName(node.children[i], name);
            if (hit) return hit;
        }
        return null;
    }

    TestCase {
        name: "EmbeddedShowsNotImplemented"
        when: windowShown

        function init() {
            // Order matters: clear the list through its own reload() while
            // still in Local (so the clearing path is the real one), and only
            // then wipe the call log, so the reset's own request does not
            // count against a test asserting on the log.
            app.mode = "local";
            app.startableModes = ["explore", "local"];
            list.reload();
            app.reset();
        }

        /// **The not-implemented state is derived, not hardcoded.**
        ///
        /// This pins the Phase 2 handover. `notImplemented` used to read
        /// `app.mode === "embedded"` — a third copy of "which mode cannot
        /// start", beside the core module's `startableModes()` and
        /// `modeIsStartable()`. Phase 2 makes Embedded startable by adding one
        /// entry to that list, and against the hardcoded version this screen
        /// would have kept saying "not implemented" for ever, with every gate
        /// green.
        ///
        /// So the assertion is made by moving ONLY the capability — the same
        /// mode, the same component, no edit to RepoList — and it is made in
        /// BOTH directions, because a derivation that merely ignored the mode
        /// would pass the "now startable" half on its own.
        function test_a_mode_becoming_startable_clears_the_not_implemented_state() {
            app.mode = "embedded";
            list.reload();
            verify(list.notImplemented,
                   "precondition: Embedded is not startable in this build");
            compare(app.callLog.length, 0, "precondition: and issues no request");

            // Phase 2, simulated at the only place it should have to happen.
            app.startableModes = ["explore", "local", "embedded"];
            app.reset();
            list.reload();

            verify(!list.notImplemented,
                   "a mode the backend now reports as startable must stop "
                   + "rendering the not-implemented state — RepoList was not "
                   + "touched, so this can only pass if it reads the capability");
            compare(app.callLog.length, 1,
                    "and it must actually list, rather than staying inert: "
                    + JSON.stringify(app.callLog));
            verify(app.deliver(), "the request must be answerable");
            compare(list.count, 2, "with the repositories it fetched on screen");
        }

        /// The other direction: a mode that IS startable today must go inert if
        /// the backend stops reporting it. Without this, a `notImplemented` that
        /// was simply stuck at false would pass the test above.
        function test_a_mode_ceasing_to_be_startable_shows_the_not_implemented_state() {
            list.reload();
            verify(!list.notImplemented, "precondition: Local is startable");
            verify(app.deliver(), "precondition: and lists");
            compare(list.count, 2, "precondition: with rows on screen");

            app.startableModes = ["explore"];
            app.reset();
            list.reload();

            verify(list.notImplemented,
                   "Local dropping out of the startable set must render the "
                   + "not-implemented state, on the mode name alone this "
                   + "could never happen");
            compare(list.count, 0, "and clear the rows it was showing");
            compare(app.callLog.length, 0,
                    "and issue nothing: " + JSON.stringify(app.callLog));
        }

        /// The baseline the other tests are read against: in Local the list
        /// really does request and really does populate. Without this, a fix
        /// that broke listing everywhere would pass every assertion below.
        function test_local_still_lists_repositories() {
            list.reload();
            compare(app.callLog.length, 1,
                    "Local must issue exactly one list request, got: "
                    + JSON.stringify(app.callLog));
            compare(app.callLog[0], "localListRepos");
            verify(app.deliver(), "the request must be answerable");
            compare(list.count, 2,
                    "Local must show the repositories it fetched");
        }

        /// **The fix.** Embedded issues no request at all. Asserted on the log
        /// rather than on the list, because fetching and then hiding the result
        /// is exactly how this bug returns.
        function test_embedded_issues_no_list_request() {
            app.mode = "embedded";
            list.reload();
            compare(app.callLog.length, 0,
                    "Embedded must not touch the backend — it has no node to "
                    + "ask. Calls issued: " + JSON.stringify(app.callLog));
        }

        /// And it says so, in its own state — not as an empty list.
        function test_embedded_shows_the_not_implemented_state() {
            app.mode = "embedded";
            list.reload();
            compare(list.count, 0, "there is nothing to list");
            verify(list.notImplemented,
                   "Embedded must render a not-implemented state");

            var note = root.findByName(list, "notImplementedNote");
            verify(note !== null && note.visible,
                   "the not-implemented state must actually be on screen");
            verify(note.text.indexOf("not available in this version") !== -1,
                   "it must use the same words as the toggle's caption, got: "
                   + note.text);
        }

        /// "No repositories" is a DIFFERENT and equally wrong claim: it implies
        /// an embedded node exists and holds nothing.
        function test_embedded_does_not_claim_the_node_is_empty() {
            app.mode = "embedded";
            list.reload();

            var empty = root.findByName(list, "listEmptyState");
            verify(empty === null || !empty.visible,
                   "Embedded must not render the empty-list message — it "
                   + "claims a node exists with nothing in it");
        }

        /// **The reported symptom.** Switching away from Local must CLEAR the
        /// repositories already on screen. Input-dependent fake data, so this
        /// can tell "cleared" from "never populated": the list is proven
        /// non-empty first, with names that came from the Local request.
        function test_switching_from_local_to_embedded_clears_the_list() {
            list.reload();
            verify(app.deliver(), "precondition: a Local reply");
            compare(list.count, 2, "precondition: Local populated the list");

            app.mode = "embedded";
            list.reload();
            compare(list.count, 0,
                    "the attached node's repositories are still on screen "
                    + "under an Embedded badge — the exact identity confusion "
                    + "this milestone exists to prevent");
        }

        /// And a reply already in flight when the switch happens cannot
        /// repopulate it. This is the half a synchronous fake cannot reach: the
        /// guard compares the method PREFIX, which does not change between
        /// `local` and `embedded`, so nothing in the guard drops this reply.
        function test_a_local_reply_landing_after_the_switch_is_dropped() {
            list.reload();
            verify(app.pending !== null, "precondition: a request is in flight");

            app.mode = "embedded";
            list.reload();
            compare(list.count, 0, "precondition: the switch cleared the list");

            // The stale reply arrives now.
            app.deliver();
            compare(list.count, 0,
                    "a reply issued in Local repopulated the list after the "
                    + "user switched to Embedded");
            verify(list.notImplemented,
                   "and the not-implemented state must still be showing");
        }

        /// Paging must not offer itself either — "Load more" against a node
        /// that does not exist is the same fetch by another route.
        function test_embedded_offers_no_paging() {
            app.mode = "embedded";
            list.reload();
            compare(list.hasMore, false,
                    "Embedded must not offer to fetch a further page");
        }
    }
}
