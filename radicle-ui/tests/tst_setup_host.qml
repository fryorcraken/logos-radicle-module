import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * The setup's HOST: which acts raise it, what raising does to the surface
 * beside it, and what lowering leaves behind.
 *
 * ## Why this file exists at all, and what it cannot claim
 *
 * Nothing instantiates `Main.qml` — Basecamp sizes and parents it, and it reads
 * a `logos` global that does not exist under `qmltestrunner`. So the host's
 * rules are reproduced here with the REAL components they act on: a real
 * `RepoList` rendering the real `EmbeddedState`, a real `SetupWizard` over a
 * real `SetupFlow`, and the two overlay flags with the same functions `Main.qml`
 * defines on them.
 *
 * That is a reproduction, and the honest limit is that a divergence between this
 * file and `Main.qml` is invisible to it — the same gap `design.md` already
 * records for `tst_embedded_wiring.qml`. What closes it is `local.yaml`, which
 * drives the real `Main.qml` and asserts `setupShown`/`settingsShown` through
 * the same clicks a user makes. Neither layer is sufficient alone: this one can
 * ask questions a spec cannot (a start request that no control offers), and the
 * spec can see the wiring this one reproduces.
 *
 * ## The two flags are read off the PANES, not off the booleans
 *
 * `Main.qml` exposes `setupShown` and `settingsShown` as the panes' own
 * `visible`, and so does this fixture. A copy of the condition agrees with the
 * item whether or not the item draws, which is the trap `reposEmbeddedPanel`
 * documents — and the failure worth catching here is precisely a surface that
 * was raised and never rendered.
 */
Item {
    id: harness
    width: 900
    height: 700

    // ------------------------------------------------------------------
    // A backend for the flow, answering from the scenario it was given.
    // ------------------------------------------------------------------
    QtObject {
        id: fake

        property string mode: "embedded"
        property bool identityExists: false
        property string identityNodeId: ""
        property bool serving: false
        property string home: "/basecamp/embedded-home"

        property var callLog: []

        function reset() { callLog = []; }

        function capabilities(cb) {
            callLog.push("getCapabilities");
            cb({ mode: mode, gitFound: true, gitProblem: "",
                 pathsProblem: "",
                 nodeId: identityExists ? identityNodeId : "" });
        }
        function identity(cb) {
            callLog.push("getEmbeddedIdentity");
            cb({ home: home, exists: identityExists,
                 nodeId: identityExists ? identityNodeId : "", problem: "" });
        }
        function nodeStatus(cb) {
            callLog.push("getNodeStatus");
            cb({ running: serving, serving: serving, home: home, reason: "" });
        }
        function seeds(cb) {
            callLog.push("listKnownSeeds");
            cb({ items: [{ url: "https://seed.radicle.xyz", alias: "radicle" }] });
        }
        function create(alias, passphrase, cb) {
            callLog.push("createEmbeddedIdentity:" + alias);
            cb({ created: true, nodeId: "did:key:z6MkCREATED", home: home });
        }
        // No `start`: this fake stands behind the WIZARD's injected calls, and
        // the wizard has none that starts a node. A fake offering one would let
        // a future edit wire a start back into the flow and stay green.
        function setting(key, value, cb) {
            callLog.push("setSetting:" + key + ":" + value);
            if (key === "mode") mode = value;
            cb({ mode: mode });
        }
    }

    // ------------------------------------------------------------------
    // What RepoList reads off its host, as Main.qml exposes it.
    // ------------------------------------------------------------------

    property string mode: "embedded"
    readonly property string source: (mode === "local" || mode === "embedded")
                                     ? "local" : "remote"
    property var startableModes: ["explore", "local", "embedded"]
    readonly property bool modeStartable: {
        for (var i = 0; i < startableModes.length; i++)
            if (startableModes[i] === mode) return true;
        return false;
    }

    property string embeddedPathsProblem: ""
    property string embeddedHome: "/basecamp/embedded-home"
    property bool embeddedIdentityExists: false
    /// Encrypted, so the Embedded panel sitting under these tests is INERT: it
    /// starts nothing by itself. Every test here is about the setup's host, and
    /// a panel quietly issuing starts underneath them would be a second thing
    /// happening in each.
    property bool embeddedEncrypted: true
    property bool embeddedRunning: false
    property bool embeddedServing: false
    property bool embeddedStartPending: false
    property string embeddedStartError: ""
    property bool embeddedStartSucceeded: false

    /// The host's own answer to "which requests do I route", exactly as
    /// `Main.qml` reports it: the setup and a start are hosted, a restart is
    /// not.
    property bool embeddedSetupHosted: true
    property bool embeddedStartHosted: true
    property bool embeddedRestartHosted: false

    /// Every `startEmbeddedNode` the panel issued. `Main.qml` performs the call;
    /// here it is only recorded, so a test can tell "the panel asked this host
    /// to start" from "the setup was raised".
    property var startLog: []
    function startEmbeddedNode(passphrase) { startLog.push(passphrase); }

    property var listLog: []
    function call(method, args, onOk, onFail) {
        listLog.push(source + method);
    }

    // ------------------------------------------------------------------
    // The host's rules, as Main.qml defines them.
    // ------------------------------------------------------------------

    property bool settingsOpen: false
    property bool setupOpen: false

    /// The observables the end-to-end layer reads, off the panes themselves.
    readonly property bool setupShown: setupPane.visible
    readonly property bool settingsShown: settingsPane.visible

    /// Every time `refreshEmbedded()` was called. `Main.qml` re-reads what the
    /// home and node are doing when the setup is lowered, because the flow may
    /// have created an identity or started a node — and the panel underneath is
    /// derived from those replies.
    property int refreshCount: 0
    function refreshEmbedded() { refreshCount = refreshCount + 1; }

    function openSetup() {
        settingsOpen = false;
        setupOpen = true;
        setupWizard.show();
    }

    function takeEmbeddedAction(kind) {
        if (!routesEmbeddedAction(kind)) return;
        if (kind === "setup") openSetup();
        else if (kind === "start") startEmbeddedNode("");
    }

    function routesEmbeddedAction(kind) {
        switch (kind) {
        case "setup":              return embeddedSetupHosted;
        case "start":              return embeddedStartHosted;
        case "restart":            return embeddedRestartHosted;
        default:                   return false;
        }
    }

    function toggleSettings() {
        if (settingsOpen) {
            settingsOpen = false;
            return;
        }
        setupOpen = false;
        settingsOpen = true;
    }

    // ------------------------------------------------------------------
    // The surfaces.
    // ------------------------------------------------------------------

    Ui.RepoList {
        id: repoList
        anchors.fill: parent
        app: harness
        onEmbeddedActionTaken: function (kind) {
            harness.takeEmbeddedAction(kind);
        }
    }

    /// A second, freshly-built `RepoList` — the only way to model "the module
    /// becomes ready ALREADY in Embedded" at this layer.
    ///
    /// `repoList` above is constructed once, before any test runs, and every
    /// test reaches its state by mutating the harness and calling `reload()`.
    /// That is a live mode change, not a startup: a host that raised the setup
    /// from a `Component.onCompleted` reading a restored `embedded` mode would
    /// never be caught by it, because the completion already happened while the
    /// fixture was in whatever state the previous test left. Building one
    /// against a harness that is already in the state under test is what makes
    /// the startup path observable.
    Component {
        id: freshRepoList

        Ui.RepoList {
            anchors.fill: parent
            app: harness
            onEmbeddedActionTaken: function (kind) {
                harness.takeEmbeddedAction(kind);
            }
        }
    }

    Rectangle {
        id: settingsPane
        objectName: "settingsPane"
        anchors.fill: parent
        visible: harness.settingsOpen
        color: "white"
    }

    Rectangle {
        id: setupPane
        objectName: "setupPane"
        anchors.fill: parent
        visible: harness.setupOpen
        color: "white"

        Ui.SetupWizard {
            id: setupWizard
            objectName: "setupWizard"
            anchors.fill: parent

            flow.fetchCapabilities: function (cb) { fake.capabilities(cb); }
            flow.fetchIdentity: function (cb) { fake.identity(cb); }
            flow.fetchNodeStatus: function (cb) { fake.nodeStatus(cb); }
            flow.fetchSeeds: function (cb) { fake.seeds(cb); }
            // No `flow.startNode`: the flow has no such property, and its
            // absence is the requirement — the setup starts no node in any
            // step, for any reason.
            flow.createIdentity: function (a, p, cb) { fake.create(a, p, cb); }
            flow.saveSetting: function (k, v, cb) { fake.setting(k, v, cb); }

            onClosed: {
                harness.setupOpen = false;
                harness.refreshEmbedded();
            }
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

    TestCase {
        name: "SetupHost"
        when: windowShown

        function init() {
            harness.mode = "embedded";
            harness.embeddedPathsProblem = "";
            harness.embeddedHome = "/basecamp/embedded-home";
            harness.embeddedIdentityExists = false;
            harness.embeddedEncrypted = true;
            harness.embeddedRunning = false;
            harness.embeddedServing = false;
            harness.embeddedStartPending = false;
            harness.embeddedStartError = "";
            harness.embeddedStartSucceeded = false;
            harness.embeddedSetupHosted = true;
            harness.embeddedStartHosted = true;
            harness.embeddedRestartHosted = false;
            harness.settingsOpen = false;
            harness.setupOpen = false;
            harness.refreshCount = 0;
            harness.listLog = [];
            harness.startLog = [];

            fake.mode = "embedded";
            fake.identityExists = false;
            fake.identityNodeId = "";
            fake.serving = false;
            fake.reset();

            repoList.reload();
        }

        function action() { return harness.findByName(repoList, "embeddedStateAction"); }

        // ---- the panel's action reaches the host --------------------------

        /// **The regression this piece exists to close.** The panel's action
        /// emitted to nobody; now it raises the setup.
        ///
        /// Clicked through the rendered control rather than by emitting the
        /// signal, because the whole defect was that no control reached a host —
        /// invoking `takeEmbeddedAction` directly would assert the handler works
        /// while leaving the button wired to nothing.
        function test_the_panels_setup_action_raises_the_setup() {
            compare(repoList.embedded.current, "noIdentity", "precondition");
            verify(!harness.setupShown, "precondition: the setup is not raised");

            action().clicked();

            verify(harness.setupShown, "the setup must be raised");
            verify(!harness.settingsShown, "and settings must not be");
        }

        /// The setup is raised only in response to an act that NAMES opening it.
        ///
        /// Selecting Embedded is not such an act: choosing a mode and
        /// configuring a node are different questions, and a modal appearing
        /// because a segment was clicked is the same defect class as writing the
        /// mode because a screen was opened.
        function test_selecting_embedded_does_not_raise_the_setup() {
            harness.mode = "local";
            harness.embeddedIdentityExists = false;
            repoList.reload();
            verify(!harness.setupShown, "precondition");

            // The mode settles on embedded with no identity — exactly the state
            // a tempting implementation would auto-open on.
            harness.mode = "embedded";
            repoList.reload();

            verify(!harness.setupShown,
                   "selecting Embedded must not raise the setup, however "
                   + "obviously the state calls for one");

            // Control: the act that DOES name opening it still works, so this is
            // not satisfied by a host that never raises anything.
            action().clicked();
            verify(harness.setupShown, "control: the setup action raises it");
        }

        /// **Starting up ALREADY in Embedded with no identity does not raise the
        /// setup either.** The spec names two distinct triggers that must not
        /// raise it, and the test above covers only one: selecting Embedded
        /// live. This is the other — Embedded restored as the mode already in
        /// force when the module becomes ready.
        ///
        /// The distinction is not pedantic. The test above reaches `embedded` by
        /// mutating a `RepoList` that completed construction long before, so a
        /// host that auto-raised the setup from a completion handler reading a
        /// restored mode would sail through it. Before this test existed, a null
        /// implementation that opened the setup unconditionally on startup
        /// whenever the resumed mode was `embedded` with no identity passed
        /// every test in this suite and in `local.yaml`, which always starts in
        /// `explore` and reaches `embedded` only by a click.
        ///
        /// So this builds a fresh `RepoList` against a harness already in that
        /// state, which is the closest this layer gets to a module start.
        function test_starting_up_in_embedded_does_not_raise_the_setup() {
            harness.mode = "embedded";
            harness.embeddedIdentityExists = false;
            harness.setupOpen = false;
            verify(!harness.setupShown, "precondition: nothing is raised");

            var fresh = freshRepoList.createObject(harness);
            verify(fresh !== null, "precondition: the fresh list was built");
            fresh.reload();

            compare(fresh.embedded.current, "noIdentity",
                    "precondition: it came up in exactly the state that most "
                    + "obviously calls for a setup");
            verify(!harness.setupShown,
                   "becoming ready already in Embedded with no identity must "
                   + "not raise the setup: the user asked for a mode to be "
                   + "restored, not for a modal");

            // Control: the fresh list's own action still reaches the host, so
            // this is not satisfied by a list wired to nothing.
            harness.findByName(fresh, "embeddedStateAction").clicked();
            verify(harness.setupShown,
                   "control: the fresh list's setup action does raise it");

            fresh.destroy();
        }

        /// **A start request does not raise the setup**, and a setup request
        /// does — the pair is the requirement.
        ///
        /// **This is now the sharper test, because a start IS routed.** While
        /// nothing hosted one, `takeEmbeddedAction("start")` returned at the
        /// first line and the assertion held for a reason that had nothing to do
        /// with the rule. Here the request reaches a branch and is carried out,
        /// and the setup still must not be raised — which is what the rule
        /// actually says: the setup creates an identity and puts the mode in
        /// force, so a node that already has an identity has nothing left for
        /// any of its steps to do.
        function test_a_start_request_does_not_raise_the_setup() {
            harness.takeEmbeddedAction("start");
            verify(!harness.setupShown,
                   "a start request must not raise a flow with no step that "
                   + "starts anything: it would present four steps, three of "
                   + "them already done, none of them the act that was asked "
                   + "for");
            compare(harness.startLog.length, 1,
                    "and the start must have been CARRIED OUT instead, or this "
                    + "asserts about a request that reached nobody: "
                    + JSON.stringify(harness.startLog));

            harness.takeEmbeddedAction("restart");
            verify(!harness.setupShown, "nor must a restart request");
            compare(harness.startLog.length, 1,
                    "and an unhosted restart must not be carried out as a "
                    + "start either: " + JSON.stringify(harness.startLog));

            harness.takeEmbeddedAction("setup");
            verify(harness.setupShown,
                   "control: the request to SET UP the node does raise it, so "
                   + "this is not a host that raises nothing");
        }

        /// **Every kind the host declares hosted is a kind it actually routes.**
        ///
        /// This is the gap that made "hosting a start is one property" a
        /// half-truth. `embeddedStartHosted` alone decides whether the panel
        /// renders an ENABLED control, but the routing was a bare
        /// `if (kind === "setup")` — so flipping the flag on its own would ship
        /// an enabled button that silently does nothing when clicked, which is
        /// the exact dead end `embedded-state`'s spec says this capability
        /// exists to remove.
        ///
        /// Asserted as a relationship rather than per-kind, so it holds for the
        /// kinds that exist today AND for the day a restart becomes routable:
        /// the host is asked which kinds it hosts, and every one of them must be
        /// accepted by the router. Reverting `takeEmbeddedAction` to the bare
        /// `if (kind === "setup")` turns this red on the `start` leg, which is
        /// now armed in the ordinary configuration rather than only
        /// hypothetically.
        function test_every_hosted_kind_is_one_the_host_routes() {
            // Today's configuration: setup and start are hosted; restart is not.
            compare(harness.routesEmbeddedAction("setup"), true,
                    "setup is hosted, so it must route");
            compare(harness.routesEmbeddedAction("start"), true,
                    "and so is a start, now that `encrypted` says whether a "
                    + "passphrase is needed");
            compare(harness.routesEmbeddedAction("restart"), false,
                    "a restart is not: it is two calls whose refusals are "
                    + "different sentences, and nothing sequences the pair");

            // **The two flags are independent**, which is the split this change
            // made. One flag for both would answer the same in each leg below.
            harness.embeddedStartHosted = false;
            compare(harness.routesEmbeddedAction("start"), false,
                    "unhosting the start unroutes it");
            compare(harness.routesEmbeddedAction("restart"), false,
                    "and leaves the restart where it was");

            harness.embeddedStartHosted = true;
            harness.embeddedRestartHosted = true;
            compare(harness.routesEmbeddedAction("restart"), true,
                    "a hosted restart must be routed, not silently dropped: an "
                    + "enabled control that does nothing is the defect this "
                    + "capability exists to remove");

            // And an unnamed kind still routes nowhere, so this is not
            // satisfied by a host that accepts everything.
            compare(harness.routesEmbeddedAction(""), false,
                    "control: an unnamed act routes nowhere");
            compare(harness.routesEmbeddedAction("explode"), false,
                    "control: nor does an unrecognised one");
        }

        // ---- the two surfaces are never raised together -------------------

        /// Raising either one lowers the other. Two opaque surfaces raised at
        /// once leaves one unreachable behind the other with no control to lower
        /// it — the one-way door this module has already shipped once.
        function test_raising_each_surface_lowers_the_other() {
            harness.toggleSettings();
            verify(harness.settingsShown, "precondition: settings are raised");

            harness.openSetup();
            verify(harness.setupShown, "the setup is raised");
            verify(!harness.settingsShown, "and settings are lowered");

            harness.toggleSettings();
            verify(harness.settingsShown, "settings are raised again");
            verify(!harness.setupShown, "and the setup is lowered");
        }

        /// **Lowering one raises nothing.** A user who closes the setup is
        /// returned to the screen underneath, not handed a surface they did not
        /// ask for. This is why the exclusion is enforced at the raise rather
        /// than by a binding of one to the other.
        function test_lowering_one_raises_nothing() {
            harness.openSetup();
            verify(harness.setupShown, "precondition");
            verify(!harness.settingsShown, "precondition");

            harness.findByName(setupWizard, "wizardClose").clicked();

            verify(!harness.setupShown, "the setup is lowered");
            verify(!harness.settingsShown,
                   "and nothing else was raised in its place");
        }

        // ---- lowering ------------------------------------------------------

        /// **The surface reports; the host lowers it.** The wizard does not
        /// close itself — a surface that did would leave whatever raised it
        /// still believing it is up.
        ///
        /// Clicked rather than emitted, for the same reason the settings Back
        /// control is: the defect worth catching is a control that reaches no
        /// handler.
        function test_the_setup_is_lowered_by_its_report() {
            action().clicked();
            verify(harness.setupShown, "precondition: raised");

            harness.findByName(setupWizard, "wizardClose").clicked();
            verify(!harness.setupShown, "the flow's report lowers it");

            // And raising it again without a report leaves it up, so this is not
            // a surface that lowers itself on some other trigger.
            action().clicked();
            verify(harness.setupShown,
                   "raised again, and with no report it stays raised");
        }

        /// Lowering re-reads what the home and node are doing, because the flow
        /// may have created an identity or started a node — the panel underneath
        /// is derived from those replies, and would otherwise go on rendering
        /// the state that was true before the flow ran.
        ///
        /// That is a REFRESH of the screen underneath, not a change to it: the
        /// mode in force, the view and the repository are all untouched.
        function test_lowering_refreshes_what_the_panel_derives_from() {
            action().clicked();
            compare(harness.refreshCount, 0, "precondition");

            harness.findByName(setupWizard, "wizardClose").clicked();

            compare(harness.refreshCount, 1,
                    "the host must re-read the identity and node status, or the "
                    + "panel behind goes on showing the pre-setup state");
            compare(harness.mode, "embedded",
                    "and the mode in force is untouched");
        }

        // ---- what a raise does to the flow --------------------------------

        /// **Raising the setup restarts the flow**, so a second showing derives
        /// its step rather than resuming where the first was closed.
        ///
        /// This is the rule that needs the host, not just the flow: the overlay
        /// is not destroyed when it is lowered, so `Component.onCompleted` fires
        /// for the first showing only. A host relying on construction would
        /// leave every later showing on a remembered step.
        function test_raising_the_setup_restarts_the_flow() {
            fake.mode = "embedded";
            fake.identityExists = false;

            action().clicked();
            compare(setupWizard.currentStep, "identity",
                    "the first showing lands where the backend says the work is");

            // The user walks BACK and closes, so the step the first showing was
            // closed on is EARLIER than the one the second must derive. That
            // direction is what makes the assertion discriminate: closing on a
            // later step and re-deriving to an earlier one would also be
            // satisfied by a flow that simply reset to step 0.
            verify(setupWizard.flow.back());
            compare(setupWizard.currentStep, "embedded");
            harness.findByName(setupWizard, "wizardClose").clicked();

            // The backend has moved on between showings: an identity now
            // exists, so the work the identity step does is done.
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkEXISTING";

            action().clicked();
            compare(setupWizard.currentStep, "network",
                    "a second showing must re-derive from the backend, not "
                    + "resume at the step the first was closed on and not "
                    + "restart from the beginning");
        }
    }
}
