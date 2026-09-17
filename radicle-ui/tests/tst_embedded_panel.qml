import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * The Embedded state panel, as RepoList renders it — and the fetch guard that
 * decides whether a request goes out at all.
 *
 * ## Why this exists beside tst_embedded_state.qml
 *
 * That file asks the derivation directly: which state, which sentence, which
 * action. This one asks whether any of it reaches the screen, and whether the
 * screen acts on it. A derivation that is correct and never rendered is the
 * blank pane this capability exists to remove, and it would pass every
 * assertion in the other file.
 *
 * ## The fake answers from the mode AND from its arguments
 *
 * `local` and `embedded` derive to the SAME method prefix (`"local"` — see
 * SourceState.qml), so a fake keyed on the prefix answers identically for both
 * and cannot tell "listed the embedded node" from "listed the user's node under
 * an Embedded badge". It holds its replies too, because a synchronous fake
 * cannot distinguish "did not request" from "requested and discarded the reply"
 * — both end with an empty list, and the difference is the whole requirement.
 */
Item {
    id: root
    width: 900
    height: 600

    QtObject {
        id: app

        property string mode: "embedded"
        readonly property string source: (mode === "local" || mode === "embedded")
                                         ? "local" : "remote"

        /// All three modes start, as the backend now reports.
        property var startableModes: ["explore", "local", "embedded"]
        readonly property bool modeStartable: {
            for (var i = 0; i < startableModes.length; i++)
                if (startableModes[i] === mode) return true;
            return false;
        }

        // The three replies the state derives from, exactly as Main.qml exposes
        // them. Defaults describe a workable home holding an identity, with the
        // node stopped — so each test moves one field and reads one answer.
        property string embeddedPathsProblem: ""
        property string embeddedHome: "/basecamp/embedded-home"
        property bool embeddedIdentityExists: true
        property bool embeddedRunning: false
        property bool embeddedServing: false
        property bool embeddedStartPending: false
        property string embeddedStartError: ""

        property var callLog: []
        property var pending: null

        function call(method, args, onOk, onFail) {
            callLog.push(source + method);
            pending = { mode: mode, args: args, onOk: onOk, onFail: onFail };
        }

        /// Answer with rows named after the MODE the request was issued for, so
        /// which node answered is readable off the list itself.
        function deliver() {
            if (pending === null) return false;
            var p = pending;
            pending = null;
            p.onOk({ items: [
                { rid: "rad:z" + p.mode + "1", name: p.mode + "-repo-one" },
                { rid: "rad:z" + p.mode + "2", name: p.mode + "-repo-two" }
            ], hasMore: false });
            return true;
        }

        function deliverEmpty() {
            if (pending === null) return false;
            var p = pending;
            pending = null;
            p.onOk({ items: [], hasMore: false });
            return true;
        }

        function reset() { callLog = []; pending = null; }
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

    /// Every action this screen could take if it decided to act on its own.
    /// None of them is reachable from `RepoList`, which is the point — see
    /// `test_rendering_the_state_writes_nothing`.
    property var writesObserved: []

    TestCase {
        name: "EmbeddedStatePanel"
        when: windowShown

        function init() {
            app.mode = "embedded";
            app.startableModes = ["explore", "local", "embedded"];
            app.embeddedPathsProblem = "";
            app.embeddedHome = "/basecamp/embedded-home";
            app.embeddedIdentityExists = true;
            app.embeddedRunning = false;
            app.embeddedServing = false;
            app.embeddedStartPending = false;
            app.embeddedStartError = "";
            root.writesObserved = [];
            list.reload();
            app.reset();
        }

        function note() { return root.findByName(list, "embeddedStateNote"); }
        function action() { return root.findByName(list, "embeddedStateAction"); }
        function emptyMsg() { return root.findByName(list, "listEmptyState"); }

        // ---- the panel renders --------------------------------------------

        /// **The regression itself.** A user picks Embedded, has no identity,
        /// and gets a panel — not an empty list, not a red banner, not nothing.
        function test_a_home_with_no_identity_renders_the_panel() {
            app.embeddedIdentityExists = false;
            list.reload();

            verify(list.embeddedPanelShown,
                   "the state panel must be on screen");
            compare(list.embedded.current, "noIdentity");
            compare(list.count, 0, "with no rows");
            verify(!list.sayingNothing,
                   "and the pane must not be blank");

            var n = note();
            verify(n !== null && n.visible, "the sentence must be rendered");
            verify(n.text.indexOf("its own identity") !== -1,
                   "stating the node runs as a new identity: " + n.text);
            verify(n.text.indexOf("separate from any Radicle node") !== -1,
                   "separate from the one the user already runs: " + n.text);
        }

        /// The sentence follows the STATE, verbatim where the backend wrote it.
        /// Read off the rendered `Text`, never off the state object — a walk to
        /// the item is what distinguishes "rendered" from "derived and dropped".
        function test_the_rendered_sentence_follows_the_state() {
            app.embeddedPathsProblem = "the node control socket path is too "
                                     + "long: 131 bytes exceeds the 108-byte cap";
            list.reload();
            var blocked = note().text;
            verify(blocked.indexOf("108-byte cap") !== -1,
                   "the pathsProblem sentence must be rendered verbatim, got: "
                   + blocked);

            app.embeddedPathsProblem = "";
            app.embeddedIdentityExists = false;
            list.reload();
            verify(note().text.indexOf("108-byte cap") === -1,
                   "and must be gone once it no longer holds, got: "
                   + note().text);
            verify(note().text !== blocked,
                   "with a different sentence for a different state");
        }

        /// A blocked home offers no control at all, and a resolving one does —
        /// the control proving the assertion discriminates.
        function test_a_blocked_home_offers_no_control() {
            app.embeddedPathsProblem = "no home could be created";
            list.reload();
            var a = action();
            verify(a === null || !a.visible || !a.enabled,
                   "nothing that would write may be offered");

            app.embeddedPathsProblem = "";
            app.embeddedIdentityExists = false;
            list.reload();
            a = action();
            verify(a !== null && a.visible && a.enabled,
                   "control: a resolving home DOES offer one");
            compare(a.text, "Set up the embedded node");
        }

        /// The rendered action differs per state, so a user is not offered a
        /// start where a setup is what is needed.
        function test_the_rendered_action_differs_per_state() {
            app.embeddedIdentityExists = false;
            list.reload();
            var setupLabel = action().text;

            app.embeddedIdentityExists = true;
            list.reload();
            var startLabel = action().text;
            verify(startLabel !== setupLabel,
                   "a stopped node must not offer the setup's words: "
                   + startLabel);

            app.embeddedRunning = true;
            list.reload();
            verify(action().text !== startLabel,
                   "and a node that has stopped serving must offer a restart "
                   + "rather than a start, got: " + action().text);
        }

        // ---- the empty-list wording ---------------------------------------

        /// **"No repositories matched" is withheld wherever no node answered.**
        /// It is a claim about a node — that one exists, was asked, and answered
        /// with nothing — and in these states none did.
        function test_the_empty_list_wording_is_absent_where_no_node_was_asked() {
            var states = [
                { label: "blocked",     apply: function () {
                    app.embeddedPathsProblem = "nowhere"; } },
                { label: "noIdentity",  apply: function () {
                    app.embeddedIdentityExists = false; } },
                { label: "stopped",     apply: function () { } },
                { label: "startFailed", apply: function () {
                    app.embeddedStartError = "refused"; } },
                { label: "starting",    apply: function () {
                    app.embeddedRunning = true;
                    app.embeddedStartPending = true; } }
            ];

            for (var i = 0; i < states.length; i++) {
                init();
                states[i].apply();
                list.reload();
                compare(list.embedded.current, states[i].label,
                        "precondition for " + states[i].label);
                var e = emptyMsg();
                verify(e === null || !e.visible,
                       states[i].label + " rendered the empty-list wording, "
                       + "which claims a node exists and holds nothing");
                verify(list.embeddedPanelShown,
                       states[i].label + " must render the panel instead");
            }
        }

        /// A serving node that holds nothing MAY say so — and the sentence says
        /// what the generic wording cannot: that this node lists what it is
        /// seeding, so an empty list reads as nothing seeded rather than as
        /// something lost.
        function test_a_serving_node_that_holds_nothing_may_say_so() {
            app.embeddedRunning = true;
            app.embeddedServing = true;
            list.reload();
            verify(app.deliverEmpty(), "the request must be answerable");

            compare(list.embedded.current, "runningEmpty");
            verify(list.embeddedPanelShown, "the panel stands here too");
            verify(note().text.indexOf("seeding") !== -1,
                   "the sentence must say this node lists what it is seeding, "
                   + "got: " + note().text);
            verify(!list.sayingNothing, "and the pane is not blank");
        }

        // ---- the fetch guard ----------------------------------------------

        /// **No request is issued while there is no node to ask.** Asserted on
        /// the call log, not on the list: fetching and hiding the reply is
        /// exactly how this bug returns.
        function test_no_request_is_issued_while_there_is_no_node_to_ask() {
            app.embeddedIdentityExists = false;
            list.reload();
            compare(app.callLog.length, 0,
                    "a home with no identity must be asked nothing, calls: "
                    + JSON.stringify(app.callLog));

            app.embeddedIdentityExists = true;
            app.embeddedRunning = true;
            app.embeddedServing = true;
            app.reset();
            list.reload();
            compare(app.callLog.length, 1,
                    "a serving node MUST be asked, calls: "
                    + JSON.stringify(app.callLog));
            verify(app.deliver(), "and answer");
            compare(list.count, 2, "with its own rows on screen");
            verify(!list.embeddedPanelShown,
                   "and the panel stands down once there are rows — it would "
                   + "otherwise cover them");
        }

        /// **The guard is not keyed on startability.** Embedded IS in the
        /// startable set here — that is the whole point, and it is what made the
        /// old guard stop firing.
        function test_the_guard_is_not_keyed_on_startability() {
            verify(app.modeStartable,
                   "precondition: the backend reports Embedded startable");
            verify(!list.notImplemented,
                   "precondition: so the unstartable path is not what is acting");

            app.embeddedIdentityExists = false;
            list.reload();
            compare(app.callLog.length, 0,
                    "a startable mode with no node must still be asked nothing, "
                    + "calls: " + JSON.stringify(app.callLog));
        }

        /// A stopped node is asked nothing; a node that has stopped SERVING is
        /// asked, because reads never touch the daemon.
        function test_a_stopped_node_is_asked_nothing_a_non_serving_one_is_asked() {
            list.reload();
            compare(list.embedded.current, "stopped", "precondition");
            compare(app.callLog.length, 0,
                    "a stopped node must be asked nothing, calls: "
                    + JSON.stringify(app.callLog));

            app.embeddedRunning = true;
            app.reset();
            list.reload();
            compare(list.embedded.current, "notServing", "precondition");
            compare(app.callLog.length, 1,
                    "a loaded node that has stopped serving still answers "
                    + "reads, calls: " + JSON.stringify(app.callLog));
        }

        /// A refused start left no node loaded, so it is asked nothing for the
        /// same reason a stopped one is — and the empty-list wording stays away.
        function test_a_refused_start_leaves_the_node_unasked() {
            app.embeddedStartError = "the passphrase did not unlock the key";
            list.reload();

            compare(list.embedded.current, "startFailed", "precondition");
            compare(app.callLog.length, 0,
                    "calls: " + JSON.stringify(app.callLog));
            var e = emptyMsg();
            verify(e === null || !e.visible,
                   "and no claim that a node answered with nothing");
            verify(note().text.indexOf("did not unlock") !== -1,
                   "the refusal is displayed verbatim, got: " + note().text);
        }

        /// Paging must not offer itself either — "Load more" against a node that
        /// does not exist is the same fetch by another route.
        function test_a_mode_with_no_node_offers_no_paging() {
            app.embeddedIdentityExists = false;
            list.reload();
            compare(list.hasMore, false);
        }

        // ---- the blank-pane observable -------------------------------------

        /// **`sayingNothing` is false in every state that renders a panel** —
        /// which is what the end-to-end blank-pane assertion consumes.
        function test_the_blank_pane_observable_is_false_whenever_a_state_renders() {
            var cases = [
                { label: "blocked",     apply: function () {
                    app.embeddedPathsProblem = "nowhere"; } },
                { label: "noIdentity",  apply: function () {
                    app.embeddedIdentityExists = false; } },
                { label: "stopped",     apply: function () { } },
                { label: "starting",    apply: function () {
                    app.embeddedRunning = true;
                    app.embeddedStartPending = true; } },
                { label: "startFailed", apply: function () {
                    app.embeddedStartError = "refused"; } },
                { label: "notServing",  apply: function () {
                    app.embeddedRunning = true; } }
            ];

            for (var i = 0; i < cases.length; i++) {
                init();
                cases[i].apply();
                list.reload();
                compare(list.embedded.current, cases[i].label,
                        "precondition for " + cases[i].label);
                verify(!list.sayingNothing,
                       cases[i].label + " rendered a blank pane: no rows, no "
                       + "message, nothing for the user to act on");
            }
        }

        /// **The observable follows the rendered item, not a recomputed copy.**
        ///
        /// The panel is prevented from rendering while the conditions selecting
        /// its state are unchanged, and `sayingNothing` must NOTICE. A version
        /// reading `embeddedShown` — the condition rather than the item — would
        /// stay false here, which is the fixture-answering-the-same-for-every-
        /// input trap living inside the observable itself.
        function test_the_observable_follows_the_rendered_item() {
            app.embeddedIdentityExists = false;
            list.reload();
            verify(!list.sayingNothing, "precondition: the panel is rendering");

            var panel = root.findByName(list, "embeddedState");
            verify(panel !== null, "precondition: the panel item exists");
            panel.visible = false;

            verify(list.sayingNothing,
                   "with the panel not rendering and nothing else on screen, "
                   + "the blank-pane observable must be TRUE — it reads the "
                   + "item's own visible, not a copy of its condition");

            panel.visible = Qt.binding(function () { return list.embeddedShown; });
            verify(!list.sayingNothing, "and restoring the binding restores it");
        }

        // ---- the action requests, it does not act -------------------------

        /// **Rendering the state writes nothing.** A state panel that acted
        /// because it was displayed would act without being asked. `RepoList` is
        /// injected with ONE call function, so every backend call it could make
        /// is in the log — which makes this structural rather than a promise.
        function test_rendering_the_state_writes_nothing() {
            app.embeddedIdentityExists = false;
            list.reload();
            verify(list.embeddedPanelShown, "precondition: the panel rendered");

            compare(app.callLog.length, 0,
                    "no call of any kind may be issued by rendering — no "
                    + "createEmbeddedIdentity, no startNode, no setSetting. "
                    + "Calls: " + JSON.stringify(app.callLog));
        }

        /// The action REQUESTS the setup and performs none of it: exactly one
        /// signal, naming what was asked for, and still no backend call.
        function test_the_action_requests_setup_rather_than_performing_it() {
            app.embeddedIdentityExists = false;
            list.reload();

            var seen = [];
            function record(kind) { seen.push(kind); }
            list.embeddedActionTaken.connect(record);

            action().clicked();

            compare(seen.length, 1,
                    "the request to open the setup must be emitted exactly once");
            compare(seen[0], "setup", "naming what was asked for");
            compare(app.callLog.length, 0,
                    "and nothing may have been created: "
                    + JSON.stringify(app.callLog));

            list.embeddedActionTaken.disconnect(record);
        }

        /// The act named follows the state, so a host routing on it cannot
        /// start a node where a setup was asked for.
        function test_the_act_named_follows_the_state() {
            var seen = [];
            function record(kind) { seen.push(kind); }
            list.embeddedActionTaken.connect(record);

            app.embeddedIdentityExists = false;
            list.reload();
            action().clicked();

            app.embeddedIdentityExists = true;
            list.reload();
            action().clicked();

            app.embeddedRunning = true;
            list.reload();
            action().clicked();

            compare(seen.join(" "), "setup start restart");
            list.embeddedActionTaken.disconnect(record);
        }

        // ---- the generic unstartable path still exists --------------------

        /// `source-modes`' other condition. A mode the reported startable set
        /// omits renders the unstartable explanation, asks nothing, and does not
        /// claim to be empty — and it does so WITHOUT the Embedded panel, which
        /// is a different state with different words.
        function test_a_mode_the_startable_set_omits_still_declines() {
            app.startableModes = ["explore"];
            app.mode = "local";
            list.reload();

            verify(list.notImplemented, "precondition");
            compare(app.callLog.length, 0,
                    "calls: " + JSON.stringify(app.callLog));
            var n = root.findByName(list, "notImplementedNote");
            verify(n !== null && n.visible,
                   "the unstartable explanation must be visible");
            verify(!list.embeddedPanelShown,
                   "and the Embedded panel must not be: this is a different "
                   + "state, and Local is not Embedded");
            verify(!list.sayingNothing, "the pane is not blank");
        }
    }
}
