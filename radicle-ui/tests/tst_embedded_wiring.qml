import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Switching INTO Embedded must ask the backend for nothing, and must therefore
 * end with no error on screen.
 *
 * ## Why tst_embedded.qml cannot see this
 *
 * That file drives `RepoList` directly, with `app.mode` already settled on the
 * mode under test. Under that fixture Embedded is correctly inert: `fetch()`
 * returns early and no request is logged. Every assertion in it passes, and
 * passed while `local.yaml` step 36 was red.
 *
 * What it cannot reproduce is the WINDOW. In the real app the mode is not a
 * property the click assigns — it is a binding to `getCapabilities().mode`, and
 * the click only starts a `setSetting` round trip. `Main.qml` reloads the list
 * one event-loop turn after the click (`sourceReload`, a zero-interval Timer),
 * which is many turns BEFORE the capabilities reply lands. So `RepoList.fetch()`
 * runs while `app.mode` is still the mode the user just LEFT, `notImplemented`
 * is still false, and `localListRepos` goes out for a node that does not exist.
 *
 * The backend then refuses it — `storeForSettings()` hands Embedded an empty
 * `NodePaths`, so the call returns `{"error": …}` — and `Main.call()` routes
 * that through `nav.fail()`, which latches. `NavState.error` clears only on
 * success, on `reset()` and on `back()`, and nothing runs any of the three
 * afterwards: `onSourceChanged` is the handler that would have reset, and the
 * derived prefix does not change, because `local` and `embedded` BOTH route to
 * `"local"`. The user is left looking at a not-implemented screen with an error
 * banner underneath it saying a node they were never asking about is missing.
 *
 * ## What this harness is
 *
 * `Main.qml`'s wiring, reproduced with the REAL components it wires together —
 * a real `SourceState`, a real `NavState`, a real `RepoList` and the real
 * zero-interval reload Timer — over a backend that answers on a later turn.
 * The deferral is the whole point: a synchronous fake settles `mode` before the
 * Timer fires and the bug cannot occur, which is exactly why every existing
 * synchronous fixture is green.
 *
 * The `local -> embedded` direction is the one that breaks. `explore ->
 * embedded` is covered too, and it passes either way — the prefix changes
 * there, so `onSourceChanged` fires and resets. A test written only against
 * that leg would prove nothing.
 */
Item {
    id: harness

    width: 900
    height: 600

    // ------------------------------------------------------------------
    // A backend that answers on a later turn, and refuses the way the real
    // module refuses.
    // ------------------------------------------------------------------
    QtObject {
        id: backend

        /// What the module has persisted. The single source of truth the fake
        /// answers from, so a write that never lands is visible as a mode that
        /// never moves rather than being masked by an echo.
        property string storedMode: "local"

        /// Outstanding `setSetting` writes, and outstanding list requests, held
        /// separately: the ORDER they are delivered in is the thing under test,
        /// and a single queue would let the test accidentally impose one.
        property var writeQueue: []
        property var listQueue: []

        /// Every list call issued, in order. `nav.error` says a call failed;
        /// only this says which surface it was made against, and whether it
        /// should ever have been made.
        property var callLog: []

        function setSetting(key, value, cb) {
            writeQueue.push({ key: key, value: value, cb: cb });
        }

        /// A list request. Recorded and held; `deliverList()` answers it the
        /// way the real backend would for whatever mode is persisted NOW —
        /// which is the point, since a reply's fate depends on the mode in
        /// force when it lands, not when it was issued.
        function listRepos(scope, onOk, onFail) {
            callLog.push("localListRepos(" + scope + ")");
            listQueue.push({ scope: scope, onOk: onOk, onFail: onFail });
        }

        function pendingWrites() { return writeQueue.length; }
        function pendingLists()  { return listQueue.length; }

        /// Answer the oldest write: persist, then republish capabilities, in
        /// that order — which is what `RadicleImpl::setSetting` does.
        function deliverWrite() {
            if (writeQueue.length === 0) return false;
            var w = writeQueue.shift();
            if (w.key === "mode") storedMode = w.value;
            harness.publishCapabilities();
            w.cb({ mode: storedMode });
            return true;
        }

        /// Answer the oldest list request as the real backend would: Embedded
        /// (and Explore) get a `LocalStore` with empty `NodePaths`, so a
        /// `local*` call against either is refused rather than answered empty.
        /// Refusing is what makes this test about an ERROR rather than about an
        /// empty list.
        function deliverList() {
            if (listQueue.length === 0) return false;
            var q = listQueue.shift();
            if (storedMode !== "local") {
                q.onFail("no Radicle profile found on this machine");
                return true;
            }
            q.onOk({ items: [
                { rid: "rad:z" + q.scope + "1", name: q.scope + "-repo-one" },
                { rid: "rad:z" + q.scope + "2", name: q.scope + "-repo-two" }
            ], hasMore: false });
            return true;
        }

        function reset() {
            writeQueue = []; listQueue = []; callLog = [];
        }
    }

    // ------------------------------------------------------------------
    // Main.qml's own wiring, with the real components it wires.
    // ------------------------------------------------------------------

    property var caps: ({ mode: "local", localAvailable: true,
                          startableModes: ["explore", "local"] })

    /// Push the backend's state into `caps` as a WHOLE new object, the way
    /// `onCapsJsonChanged` does — a mutated `var` does not re-evaluate the
    /// bindings that read it.
    function publishCapabilities() {
        caps = {
            mode: backend.storedMode,
            localAvailable: backend.storedMode === "local",
            startableModes: ["explore", "local"]
        };
    }

    /// The REAL SourceState, with Main.qml's own handlers on its real signals.
    ///
    /// The trigger under test — "reload when the mode SETTLES, not when it is
    /// clicked and not when the derived prefix moves" — lives in SourceState
    /// rather than in Main.qml precisely so this fixture can drive the actual
    /// rule instead of a copy of it. An earlier version of this file
    /// reproduced the wiring inline, and its assertions were therefore
    /// unaffected by fixing Main.qml: it tested the fixture.
    readonly property Ui.SourceState sourceState: Ui.SourceState {
        mode: harness.caps.mode || "explore"
        localAvailable: harness.caps.localAvailable === true
        startableModes: harness.caps.startableModes !== undefined
                        ? harness.caps.startableModes : []
        onChanged: nav.reset()
        onSettled: {
            nav.reset();
            sourceReload.restart();
        }
    }

    readonly property string source: sourceState.current
    readonly property string mode: sourceState.mode
    readonly property bool modeStartable: sourceState.modeStartable

    readonly property Timer sourceReload: Timer {
        interval: 0
        repeat: false
        onTriggered: repoList.reload()
    }

    Ui.NavState { id: nav }

    /// Main.qml's `call()`, reproduced including the two parts that matter:
    /// the reply reaches NavState BEFORE `RepoList`'s own staleness guard runs
    /// (so the guard dropping the data does not stop the strip going red), and
    /// a failure for a mode no longer in force is settled rather than reported.
    ///
    /// The real `NavState` is used, not a stub, so `settle()` vs `fail()` is
    /// the component's own behaviour rather than this file's opinion of it.
    function call(method, args, onOk, onFail) {
        nav.begin();
        var wantMode = harness.mode;
        function reportFailure(message) {
            if (harness.mode === wantMode) nav.fail(message);
            else nav.settle();
            if (onFail) onFail();
        }
        backend.listRepos(args[0], function (data) {
            nav.succeed();
            onOk(data);
        }, reportFailure);
    }

    /// Main.qml's `setMode()`, reproduced verbatim in shape.
    function setMode(next) {
        if (!sourceState.select(next)) return;
        backend.setSetting("mode", next, function (reply) {
            if (reply && reply.error) nav.error = reply.error;
        });
    }

    Ui.RepoList {
        id: repoList
        anchors.fill: parent
        app: harness
    }

    // ==================================================================
    TestCase {
        name: "EmbeddedWiring"
        when: windowShown

        function init() {
            backend.storedMode = "local";
            backend.reset();
            harness.publishCapabilities();
            // Republishing capabilities can move `mode`, which fires
            // `settled()` and ARMS the reload Timer. Let that fire and be
            // answered here, before the log is cleared — otherwise a reload
            // belonging to setup lands inside the test body and is counted
            // against it. This cost a false failure once.
            settle();
            repoList.reload();
            backend.deliverList();
            settle();
            backend.reset();
            nav.reset();
        }

        /// Let the zero-interval reload Timer fire.
        function settle() {
            wait(0);
            wait(0);
        }

        /// The baseline. Without it, a fix that simply stopped listing
        /// everywhere would satisfy every assertion below.
        function test_local_lists_and_reports_no_error() {
            compare(harness.mode, "local", "precondition");
            repoList.reload();
            compare(backend.pendingLists(), 1,
                    "Local must issue a list request, got: "
                    + JSON.stringify(backend.callLog));
            verify(backend.deliverList(), "and it must be answerable");
            compare(repoList.count, 2, "with rows on screen");
            compare(nav.error, "", "and nothing errored");
        }

        /// **The bug.** Clicking Embedded from Local must issue NO list call.
        ///
        /// The reload fires one turn after the click; the capabilities reply
        /// that makes `mode` say `embedded` is a round trip away. In that
        /// window `RepoList.notImplemented` is still false and the fetch goes
        /// out against a node that does not exist.
        function test_switching_to_embedded_issues_no_list_request() {
            harness.setMode("embedded");
            settle();

            compare(backend.callLog.length, 0,
                    "switching to Embedded asked the backend for repositories "
                    + "before the mode had settled — calls issued: "
                    + JSON.stringify(backend.callLog));
        }

        /// **The assertion local.yaml step 36 makes**, at the layer that can
        /// see why it fails. Nothing was asked of a node that does not exist,
        /// so nothing can have errored.
        function test_switching_to_embedded_leaves_no_error() {
            harness.setMode("embedded");
            settle();
            // The write lands, capabilities republish, mode becomes embedded.
            verify(backend.deliverWrite(), "the mode write must be answerable");
            settle();
            // Whatever was in flight now lands. In the buggy ordering this is
            // the `localListRepos` refusal, and it latches into nav.error.
            backend.deliverList();
            settle();

            compare(harness.mode, "embedded", "precondition: Embedded is in force");
            verify(repoList.notImplemented,
                   "precondition: and the not-implemented state is showing");
            compare(repoList.count, 0, "precondition: with no repositories");
            compare(nav.error, "",
                    "Embedded shows a not-implemented screen with an error "
                    + "banner under it — nothing was asked of a node that does "
                    + "not exist, so nothing can have errored. Calls issued: "
                    + JSON.stringify(backend.callLog));
        }

        /// The same switch arriving from Explore, which fails for a related but
        /// distinct reason and was NOT what this file first predicted.
        ///
        /// The guess was that this leg would pass either way: the method prefix
        /// does move here (`remote` -> `local`), so the old `onSourceChanged`
        /// fired a second `nav.reset()`. It fails anyway, because that reset
        /// runs when the mode settles while the stale `remoteListRepos` reply
        /// lands AFTER it — and `Main.call()` hands every reply to
        /// `nav.fail()` before RepoList's own staleness guard gets to drop it.
        ///
        /// Worth keeping for exactly that: the prediction was wrong, and a
        /// suite that only covered the leg the author expected to break would
        /// have shipped this one.
        function test_switching_to_embedded_from_explore_leaves_no_error() {
            harness.setMode("explore");
            settle();
            verify(backend.deliverWrite(), "explore must be persisted");
            settle();
            backend.deliverList();
            settle();
            backend.reset();
            nav.reset();

            harness.setMode("embedded");
            settle();
            verify(backend.deliverWrite(), "embedded must be persisted");
            settle();
            backend.deliverList();
            settle();

            compare(nav.error, "",
                    "calls issued: " + JSON.stringify(backend.callLog));
        }

        /// **A reply from the mode being LEFT must not paint an error over
        /// Embedded**, even though it was a perfectly legitimate request when
        /// it was issued.
        ///
        /// This is the residual hole in the fix above, exercised on purpose:
        /// not fetching in Embedded stops NEW calls, but a call already in
        /// flight when the user clicks still lands afterwards, and
        /// `Main.call()` hands it to `nav.fail()` before RepoList's staleness
        /// guard can drop it. The reply is deliberately held until after the
        /// mode has settled, which is the worst ordering rather than a
        /// convenient one — deliver it before the settle and `onSettled`'s own
        /// reset would mask the problem.
        function test_a_reply_from_the_previous_mode_does_not_error_over_embedded() {
            // A request issued while Local is genuinely in force.
            repoList.reload();
            compare(backend.pendingLists(), 1, "precondition: a call is in flight");

            harness.setMode("embedded");
            settle();
            verify(backend.deliverWrite(), "the mode write must be answerable");
            settle();

            // Only now does the Local request come back — refused, because the
            // module has already repointed at a home that does not exist.
            backend.deliverList();
            settle();

            compare(harness.mode, "embedded", "precondition: Embedded is in force");
            compare(repoList.count, 0, "precondition: nothing is listed");
            compare(nav.error, "",
                    "a reply to a request the user has already navigated away "
                    + "from painted an error over a screen that asked for "
                    + "nothing");
        }

        /// Leaving Embedded must still list. A fix that made the reload inert
        /// for anything sharing Local's prefix would pass every assertion above
        /// and break the mode the user actually browses in.
        function test_switching_back_from_embedded_to_local_lists_again() {
            harness.setMode("embedded");
            settle();
            backend.deliverWrite();
            settle();
            backend.deliverList();
            settle();
            backend.reset();

            harness.setMode("local");
            settle();
            verify(backend.deliverWrite(), "local must be persisted");
            settle();

            compare(backend.pendingLists(), 1,
                    "returning to Local must list this machine's repositories, "
                    + "calls issued: " + JSON.stringify(backend.callLog));
            verify(backend.deliverList(), "and the request must be answerable");
            compare(repoList.count, 2, "with rows back on screen");
            compare(nav.error, "", "and no error left over from Embedded");
        }

        /// And Explore must still list after Embedded, by the other route.
        function test_switching_from_embedded_to_explore_lists_again() {
            harness.setMode("embedded");
            settle();
            backend.deliverWrite();
            settle();
            backend.deliverList();
            settle();
            backend.reset();

            harness.setMode("explore");
            settle();
            verify(backend.deliverWrite(), "explore must be persisted");
            settle();

            compare(backend.pendingLists(), 1,
                    "returning to Explore must list from the seed, calls "
                    + "issued: " + JSON.stringify(backend.callLog));
        }
    }
}
