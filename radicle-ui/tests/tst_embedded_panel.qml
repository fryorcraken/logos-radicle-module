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
        /// **Encrypted by default in this fixture**, although unencrypted is the
        /// commoner case in life. It is the value that makes the stopped state
        /// INERT — nothing is started, nothing is asked for — so every test that
        /// is not about starting departs from a panel that does nothing by
        /// itself. The autostart tests arm it the other way explicitly, and the
        /// arming is what makes them read as the subject rather than as a side
        /// effect every other test is silently sitting in.
        property bool embeddedEncrypted: true
        property bool embeddedRunning: false
        property bool embeddedServing: false
        property bool embeddedStartPending: false
        property string embeddedStartError: ""
        property bool embeddedStartSucceeded: false

        /// Which requests this host routes, exactly as `Main.qml` reports them:
        /// the setup and a start are hosted, a RESTART is not. Held as
        /// properties rather than baked into the panel, because the requirement
        /// is that hosting an action enables it with nothing else changed — so a
        /// test moves one of these and reads the answer back.
        property bool embeddedSetupHosted: true
        property bool embeddedStartHosted: true
        property bool embeddedRestartHosted: false

        property var callLog: []
        property var pending: null

        /// Every `startEmbeddedNode` this panel issued, with the passphrase it
        /// carried — so "started by itself" is distinguishable from "did not",
        /// and "started once" from "started on every reading".
        ///
        /// Recorded rather than performed: this fake does NOT move
        /// `embeddedStartPending`, so a test can assert on the calls without the
        /// state moving underneath it. The tests that need the real sequence set
        /// `embeddedStartPending` themselves, which is what `Main.qml` does.
        property var startLog: []

        function startEmbeddedNode(passphrase) {
            startLog.push(passphrase);
        }

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

        function reset() { callLog = []; pending = null; startLog = []; }
    }

    Ui.RepoList {
        id: list
        anchors.fill: parent
        app: app
    }

    /// A second, freshly-built `RepoList` — the only way to model "the module
    /// becomes ready ALREADY in the stopped state" at this layer.
    ///
    /// `list` above is constructed once, before any test runs, and every test
    /// reaches its state by mutating the harness. That is a live CHANGE, which
    /// always fires the `onWantsAutoStartChanged` handler — so a `RepoList` that
    /// relied on the change signal alone would pass every test in this file
    /// while never starting a node for the user who opens Basecamp with Embedded
    /// already the mode in force and an unencrypted key. That is the ordinary
    /// case for anyone who has used the mode before, and it is the one this
    /// component cannot reproduce any other way.
    ///
    /// Measured, not assumed: deleting `Component.onCompleted: autoStartIfWanted()`
    /// reddened NOTHING in this file until this Component existed.
    /// The harness under its own id, for the Component below.
    ///
    /// **`app: app` inside the Component resolves to the RepoList's OWN `app`
    /// property, not to the outer object** — QML scoping puts the item's
    /// properties in front of the file's ids — so the fresh list would come up
    /// with a null host and derive `blocked`. Caught by the precondition rather
    /// than by reading; it is the same shadowing trap this repo records for
    /// component names and `on*` properties.
    readonly property var hostApp: app

    Component {
        id: freshList

        Ui.RepoList {
            anchors.fill: parent
            app: root.hostApp
        }
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
            app.embeddedEncrypted = true;
            app.embeddedRunning = false;
            app.embeddedServing = false;
            app.embeddedStartPending = false;
            app.embeddedStartError = "";
            app.embeddedStartSucceeded = false;
            app.embeddedSetupHosted = true;
            app.embeddedStartHosted = true;
            app.embeddedRestartHosted = false;
            root.writesObserved = [];
            list.reload();
            app.reset();
        }

        function note() { return root.findByName(list, "embeddedStateNote"); }
        function action() { return root.findByName(list, "embeddedStateAction"); }
        function emptyMsg() { return root.findByName(list, "listEmptyState"); }
        function passphrase() {
            return root.findByName(list, "embeddedPassphrase");
        }

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

            // The control leg is the no-identity state rather than the stopped
            // one, because the setup action is the one this version hosts — a
            // stopped node's start is rendered disabled, so it could no longer
            // tell "blocked offers nothing" from "nothing is ever enabled".
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
        ///
        /// Read off `actionKind` rather than off what each click emitted,
        /// because two of the three acts reach no host in this version and are
        /// therefore rendered disabled — which is a different requirement,
        /// covered by the two tests below. What this one pins is that the three
        /// states name three different acts, which is what a host routes on and
        /// what must already be right on the day the other two are hosted.
        function test_the_act_named_follows_the_state() {
            var named = [];

            app.embeddedIdentityExists = false;
            list.reload();
            named.push(list.embedded.actionKind);

            app.embeddedIdentityExists = true;
            list.reload();
            named.push(list.embedded.actionKind);

            app.embeddedRunning = true;
            list.reload();
            named.push(list.embedded.actionKind);

            compare(named.join(" "), "setup start restart");
        }

        /// **An action that is not enabled emits no request**, and takes no
        /// other route to one either.
        ///
        /// `clicked()` is invoked directly rather than through a pointer, which
        /// is the stronger test: `enabled: false` stops a mouse, not a
        /// programmatic emit, so a panel relying on `enabled` alone would pass a
        /// click-driven check and fail this. The requirement is about the
        /// request, not about the mouse.
        /// **The unhosted example is now the RESTART**, and it moved because
        /// start became hosted. A stopped node was the example while nothing
        /// could start one; with a start routed, this test written against
        /// `stopped` would be asserting that an ENABLED control emits nothing,
        /// which is a different and false claim.
        function test_an_action_that_is_not_enabled_emits_no_request() {
            var seen = [];
            function record(kind) { seen.push(kind); }
            list.embeddedActionTaken.connect(record);

            // A node that has stopped serving: the act is a restart, which
            // reaches nobody.
            app.embeddedRunning = true;
            list.reload();
            compare(list.embedded.actionKind, "restart", "precondition");
            var a = action();
            verify(a !== null && a.visible, "the control is rendered");
            verify(!a.enabled, "and is not enabled");

            a.clicked();

            compare(seen.length, 0,
                    "no request may be emitted: " + JSON.stringify(seen));
            compare(app.startLog.length, 0,
                    "and no start may have been issued either — the guard is "
                    + "about the REQUEST, and a restart routed as a start would "
                    + "be refused by the backend rather than sequenced: "
                    + JSON.stringify(app.startLog));

            list.embeddedActionTaken.disconnect(record);
        }

        /// **Hosting an action is what enables it**, through the rendered
        /// control — one property moves on the host and the button follows, with
        /// nothing else changed. A panel hard-coding which states are enabled
        /// would answer identically for both halves.
        function test_hosting_an_action_enables_the_rendered_control() {
            // The restart, for the reason the test above records: it is the act
            // this version does not host, so it is the one whose enablement can
            // be moved by moving a flag.
            app.embeddedRunning = true;
            list.reload();
            compare(list.embedded.actionKind, "restart", "precondition");
            verify(!action().enabled, "unhosted, the control is not enabled");

            var note = root.findByName(list, "embeddedStateUnavailable");
            verify(note !== null && note.visible,
                   "and the panel says why rather than leaving it unexplained");
            verify(note.text.indexOf("not yet available from here") !== -1,
                   "naming that it is not yet available here, got: " + note.text);

            app.embeddedRestartHosted = true;
            verify(action().enabled,
                   "hosting the request enables the control, with nothing else "
                   + "changed");
            verify(!note.visible,
                   "and the unavailability sentence goes with it");
        }

        /// **Start and restart are hosted independently, through the rendered
        /// panel.** One flag governed both while both were unhosted; with start
        /// routed, one flag would enable a restart that reaches nobody.
        ///
        /// Both legs hold `embeddedStartHosted` TRUE and differ only in the
        /// restart flag, so a panel reading one flag for both answers the same
        /// in each and fails.
        function test_hosting_a_start_does_not_host_a_restart() {
            compare(app.embeddedStartHosted, true, "precondition");
            compare(app.embeddedRestartHosted, false, "precondition");

            // stopped, with an encrypted key so a control is offered at all.
            list.reload();
            compare(list.embedded.actionKind, "start", "precondition");
            verify(action().enabled, "the hosted start is enabled");

            app.embeddedRunning = true;
            list.reload();
            compare(list.embedded.actionKind, "restart", "precondition");
            verify(!action().enabled,
                   "while the restart is not — hosting one must not host the "
                   + "other");
        }

        /// The hosted setup action IS enabled and DOES emit, so the two tests
        /// above are not satisfied by a panel that enables nothing and emits
        /// nothing whatever it is told.
        function test_a_hosted_action_is_enabled_and_emits() {
            app.embeddedIdentityExists = false;
            list.reload();

            var seen = [];
            function record(kind) { seen.push(kind); }
            list.embeddedActionTaken.connect(record);

            verify(action().enabled, "the setup action is hosted, so enabled");
            action().clicked();
            compare(seen.join(" "), "setup", "and emits its request");

            // And withdrawing the host withdraws both.
            app.embeddedSetupHosted = false;
            verify(!action().enabled, "unhosting it disables the control");
            action().clicked();
            compare(seen.join(" "), "setup",
                    "and no second request is emitted: " + JSON.stringify(seen));

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

        // ---- starting by itself -------------------------------------------

        /// **The node genuinely starts itself**, and this is the test that says
        /// so: the other file proves the panel WANTS to, this one proves a call
        /// goes out.
        ///
        /// `encrypted` is the only field moved between the two legs, and the
        /// node status is identical in both — so a panel starting on the node's
        /// state rather than on the key answers the same in each and fails.
        function test_an_unencrypted_stopped_node_is_started_without_being_asked() {
            app.embeddedEncrypted = false;
            list.reload();

            compare(app.startLog.length, 1,
                    "exactly one start must have been issued with no action "
                    + "taken: " + JSON.stringify(app.startLog));
            compare(app.startLog[0], "",
                    "carrying an empty passphrase, which is the only secret a "
                    + "surface that asked for none can mean");
            compare(list.embedded.actionKind, "",
                    "and no control is offered beside it — a button the module "
                    + "has already pressed asks for an act with one answer");

            // The control: the same node status with an encrypted key starts
            // nothing and asks instead.
            app.reset();
            app.embeddedEncrypted = true;
            list.reload();
            compare(app.startLog.length, 0,
                    "an encrypted key must not be started unasked — there is no "
                    + "passphrase to start it with: "
                    + JSON.stringify(app.startLog));
        }

        /// **With start unhosted, the module issues no start of its own.**
        ///
        /// The other file holds the decision; this one proves no CALL goes out,
        /// which is the half that was wrong. `autoStartIfWanted()` reached
        /// `app.startEmbeddedNode("")` on the node's state and the key alone,
        /// so a host declaring start unrouted was ignored by the one path the
        /// user never presses — and the reviewer's mutation (declaring
        /// `embeddedStartHosted = false` and watching the start still fire) is
        /// exactly this assertion, written down.
        ///
        /// `embeddedStartHosted` is the ONLY field moved between the legs: the
        /// stopped unencrypted status is identical in both, so a surface that
        /// starts on the node's state regardless answers the same in each.
        function test_an_unhosted_start_is_not_issued_by_the_module_either() {
            // Unhosted FIRST, then the key. `wantsAutoStart` is watched on its
            // change edge, so unsealing the key while start is still hosted
            // fires the very start this test is about — the order is the test,
            // not tidiness.
            app.embeddedStartHosted = false;
            app.embeddedEncrypted = false;
            list.reload();

            compare(app.startLog.length, 0,
                    "a start the host does not route must not be issued "
                    + "automatically: an act whose request reaches nobody is "
                    + "not one the module may take on the user's behalf: "
                    + JSON.stringify(app.startLog));

            // The control: the same status with start hosted does start, so
            // this is the flag doing the work and not a list that never starts.
            app.reset();
            app.embeddedStartHosted = true;
            list.reload();
            compare(app.startLog.length, 1,
                    "and with start hosted the same stopped unencrypted node "
                    + "is started: " + JSON.stringify(app.startLog));
        }

        /// **A module that BECOMES READY already stopped starts its node too.**
        ///
        /// This is the case a live mode change cannot reach, and the one an
        /// ordinary user hits every time: Basecamp opens with Embedded already
        /// the mode in force, the key is unencrypted, and the node is not
        /// running. `wantsAutoStart` is then true from its first evaluation, so
        /// no change signal ever fires and a surface watching only for changes
        /// would sit there doing nothing.
        ///
        /// Built against a harness ALREADY in that state, which is as close to a
        /// module start as this layer gets.
        function test_a_list_built_already_stopped_starts_its_node() {
            app.embeddedEncrypted = false;
            app.reset();

            var fresh = freshList.createObject(root);
            verify(fresh !== null, "the fresh list must build");
            compare(fresh.embedded.current, "stopped",
                    "precondition: it is built already in the stopped state");

            compare(app.startLog.length, 1,
                    "a list that finds itself stopped with an unencrypted key "
                    + "must start the node, with no change signal to hang it "
                    + "on: " + JSON.stringify(app.startLog));
            compare(app.startLog[0], "", "with an empty passphrase");

            // The control: the same construction against an ENCRYPTED key
            // starts nothing, so this is not a list that starts on being built.
            app.reset();
            app.embeddedEncrypted = true;
            var sealed = freshList.createObject(root);
            compare(app.startLog.length, 0,
                    "an encrypted key must not be started on construction "
                    + "either: " + JSON.stringify(app.startLog));

            // **Destroyed and WAITED FOR.** `destroy()` is deferred to the next
            // event-loop turn, so a list left merely scheduled goes on watching
            // the harness — and the next test's single expected start arrives
            // twice. Found the expensive way: three unrelated tests reported two
            // calls where they expected one.
            fresh.destroy();
            sealed.destroy();
            wait(0);
        }

        /// **Issued once per arrival, not on every reading.**
        ///
        /// The reply is withheld — `embeddedStartPending` stays true, exactly as
        /// `Main.qml` leaves it while a start is in flight — and the backend is
        /// then made to report the same node status twice more. A panel
        /// re-issuing on each reading would start a node repeatedly against a
        /// backend that is slow to answer.
        function test_the_automatic_start_is_issued_once_not_on_every_reading() {
            app.embeddedEncrypted = false;
            list.reload();
            compare(app.startLog.length, 1, "precondition: one start went out");

            // The call is now outstanding, which is what a real host records
            // before the reply lands.
            app.embeddedStartPending = true;

            // The same status reported a second and a third time.
            list.reload();
            list.reload();

            compare(app.startLog.length, 1,
                    "still exactly one: a start already in flight must not be "
                    + "re-issued: " + JSON.stringify(app.startLog));
        }

        /// A refused automatic start is reported as a refusal, not more quietly
        /// for having been automatic — and it is NOT retried unasked, which
        /// would loop against a backend that refuses every time.
        function test_a_refused_automatic_start_is_reported_and_not_retried() {
            app.embeddedEncrypted = false;
            list.reload();
            compare(app.startLog.length, 1, "precondition");

            // The refusal lands.
            app.embeddedStartPending = false;
            app.embeddedStartError = "the passphrase did not unlock keys/radicle";
            list.reload();

            compare(list.embedded.current, "startFailed",
                    "a refused start is the start-failed state");
            verify(note().text.indexOf("did not unlock") !== -1,
                   "with the backend's own words, got: " + note().text);
            compare(app.startLog.length, 1,
                    "and no second start may be issued unasked: "
                    + JSON.stringify(app.startLog));
        }

        // ---- the passphrase, where one is needed ---------------------------

        /// **An encrypted identity is asked for its passphrase on THIS
        /// surface**, with a field and a control, rather than being sent to a
        /// flow whose other steps are already done.
        function test_an_encrypted_identity_is_offered_a_passphrase_field() {
            list.reload();
            compare(list.embedded.current, "stopped", "precondition");

            var f = passphrase();
            verify(f !== null && f.visible,
                   "a field to type the passphrase into must be present");
            verify(f.echoMode !== TextInput.Normal,
                   "and must not display what is typed");
            compare(app.startLog.length, 0,
                    "nothing is started until it is submitted: "
                    + JSON.stringify(app.startLog));

            // The control: an unencrypted key offers no field, because there is
            // nothing to ask for.
            app.embeddedEncrypted = false;
            list.reload();
            verify(!passphrase().visible,
                   "an unencrypted key has nothing to ask for");
        }

        /// The typed passphrase is the one submitted, and it does not outlive
        /// the call it was taken for.
        function test_the_typed_passphrase_is_submitted_and_not_retained() {
            list.reload();
            passphrase().text = "correct horse battery";

            action().clicked();

            compare(app.startLog.length, 1,
                    "exactly one start: " + JSON.stringify(app.startLog));
            compare(app.startLog[0], "correct horse battery",
                    "carrying what was typed, not an empty string");
            compare(passphrase().text, "",
                    "and the field must not go on holding it: the call already "
                    + "has the value, and this module's dev Basecamp ships a "
                    + "QML inspector that reads live object properties");
        }

        /// **A typed-but-never-submitted passphrase does not survive the field
        /// being hidden and shown again.**
        ///
        /// The reviewer's cycle, exactly: type into the field, let it go
        /// invisible by a route that is NOT a submit — the node starts serving
        /// through an external event, e.g. someone starting it from a command
        /// line while the panel is open — then let it come back when the node
        /// stops again. The only clearing point used to be inside
        /// `submitEmbeddedPassphrase()`, which never ran here, so the field
        /// returned pre-filled with a secret the user had abandoned.
        ///
        /// `app.startLog` is asserted empty at the hide, which is what makes
        /// this a test about the SHOWING rather than about submission: a panel
        /// that cleared by quietly submitting would fail that assertion.
        function test_an_abandoned_passphrase_does_not_survive_the_showing() {
            list.reload();
            verify(passphrase().visible, "precondition: the field is offered");
            passphrase().text = "leaked-secret";

            // The node starts serving without this surface asking — the field's
            // visibility condition changes by a route other than submit.
            app.embeddedServing = true;
            app.embeddedRunning = true;
            list.reload();
            verify(!passphrase().visible,
                   "precondition: the field is no longer shown");
            compare(app.startLog.length, 0,
                    "precondition: nothing was submitted — the field went away "
                    + "on its own: " + JSON.stringify(app.startLog));

            // The node stops again and the same field is shown once more.
            app.embeddedServing = false;
            app.embeddedRunning = false;
            list.reload();
            verify(passphrase().visible,
                   "precondition: the field is offered again");

            compare(passphrase().text, "",
                    "the abandoned passphrase must not come back with the "
                    + "field: it outlived the showing it was typed for, and "
                    + "this module's dev Basecamp ships a QML inspector that "
                    + "reads live object properties, so resident means "
                    + "readable");
        }

        /// A refused passphrase can be corrected: the field survives the
        /// refusal, and a second submission carries the second value.
        function test_a_refused_passphrase_can_be_corrected() {
            list.reload();
            passphrase().text = "wrong one";
            action().clicked();
            compare(app.startLog[0], "wrong one", "precondition");

            app.embeddedStartError = "the passphrase did not unlock keys/radicle";
            list.reload();

            compare(list.embedded.current, "startFailed", "precondition");
            verify(passphrase().visible,
                   "the field must still be present so a mistyped passphrase "
                   + "can be corrected");
            verify(note().text.indexOf("did not unlock") !== -1,
                   "with the refusal displayed as the backend worded it, got: "
                   + note().text);

            passphrase().text = "the right one";
            action().clicked();
            compare(app.startLog.length, 2,
                    "a second start goes out: " + JSON.stringify(app.startLog));
            compare(app.startLog[1], "the right one",
                    "carrying the SECOND value — a panel holding the first "
                    + "would retry what was already refused");
        }

        // ---- a node this surface started is not one in the way -------------

        /// **The defect the setup flow shipped, through the rendered panel.**
        ///
        /// Both legs report `serving:true` with an identical node status; only
        /// `embeddedStartSucceeded` differs, which is the one fact the status
        /// cannot carry.
        function test_a_node_this_surface_started_is_not_rendered_as_contention() {
            app.embeddedEncrypted = false;
            app.embeddedStartSucceeded = true;
            app.embeddedRunning = true;
            app.embeddedServing = true;
            list.reload();
            app.deliverEmpty();

            verify(note().text.indexOf("already answering") === -1,
                   "nothing may warn about a node this surface started: "
                   + note().text);
            verify(note().text.indexOf("contend") === -1,
                   "nor about contending for its socket: " + note().text);

            // The control: a serving node this surface did NOT start IS
            // reported, because that one is somebody else's.
            app.embeddedStartSucceeded = false;
            list.reload();
            app.deliverEmpty();
            verify(note().text.indexOf("already answering") !== -1,
                   "a node found serving that this surface did not start must "
                   + "be reported as such, got: " + note().text);
        }
    }
}
