import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * The embedded node's guided setup: step order, preflight findings, blocking,
 * and the three consequences the flow must state where the choice is made.
 *
 * ## The fakes answer from what they were ASKED, not from a fixed object
 *
 * Every fake here derives its reply from its own arguments or from a scenario
 * the test sets first, and the scenarios differ from each other in a value the
 * assertion reads back. That is not decoration: CLAUDE.md records a whole
 * milestone lost to a fake returning an empty tree for every branch, where the
 * assertion `treeCount === 0` was true whether the refetch ran, the reset ran,
 * both, or neither — deleting the entire feature left 122 tests green.
 *
 * So the rule applied throughout: before writing an assertion, ask what the
 * NULL implementation would produce. Where the answer is "the same thing", the
 * test is changed until it is not. Concretely —
 *
 *  - the two preflight scenarios fail DIFFERENT findings, so "the git finding
 *    is red" cannot pass against a flow that reddens everything;
 *  - the refusal messages are distinct sentences, so "a message is displayed"
 *    cannot pass against one that displays the first refusal for ever;
 *  - the two DIDs in the confirm tests differ, and the second assertion checks
 *    the FIRST is absent as well as the second present.
 *
 * ## Why the state object is driven directly
 *
 * `SetupFlow` is where every ordering, blocking and staleness rule lives, so it
 * is what these assertions ask. Reaching through a rendered wizard to find a
 * disabled Button would test the same rule through a layer that cannot fail
 * independently — and `tst_setup_wizard_view.qml` covers what only the screen
 * can answer.
 */
Item {
    id: harness
    width: 700
    height: 900

    // ------------------------------------------------------------------
    // A backend whose replies follow from the scenario it was given, and
    // which can HOLD a reply so a test can deliver it after a step change.
    // ------------------------------------------------------------------
    QtObject {
        id: fake

        // ---- the scenario -------------------------------------------------
        property bool gitFound: true
        property string gitProblem: ""
        property string pathsProblem: ""
        property string mode: "embedded"
        property var startableModes: ["explore", "local", "embedded"]

        /// What `getCapabilities()` reports as the mode in force, when that has
        /// to differ from what `setSetting` was given. Empty means "whatever
        /// the setting holds", which is the ordinary case.
        ///
        /// It exists so a test can tell "the flow re-read capabilities" apart
        /// from "the flow trusted the value it wrote" — two behaviours that are
        /// indistinguishable while the two values agree.
        property string capabilitiesMode: ""

        property bool identityExists: false
        property string identityNodeId: ""
        property string identityProblem: ""
        property string home: "/home/u/.local/share/basecamp/radicle"

        property bool serving: false

        /// What createEmbeddedIdentity will answer with. A distinctive sentence
        /// per scenario, so two refusals are distinguishable.
        property string createRefusal: ""
        property string createdNodeId: "did:key:z6MkCREATED"

        property string startRefusal: ""
        property bool startStarted: true
        property var startListening: []
        property string startNodeId: "did:key:z6MkSTARTED"

        property string settingRefusal: ""

        property var seedItems: [
            { url: "https://seed.radicle.xyz", alias: "radicle", source: "builtin" }
        ]

        // ---- observation --------------------------------------------------
        property var callLog: []

        /// A reply held rather than delivered, so a test can land it after the
        /// user has moved. A synchronous fake cannot express "the reply arrived
        /// late", which is exactly the requirement being pinned.
        property var held: null

        /// Clears what was OBSERVED, and the node state the fake mutates.
        ///
        /// `serving` is in here because `start()` now sets it — a started node
        /// answers its socket. Everything else is a scenario the test sets
        /// itself, and is deliberately left alone so a mid-test `reset()` does
        /// not silently undo the scenario the test just established.
        function reset() {
            callLog = [];
            held = null;
            heldSeeds = null;
            serving = false;
        }

        function capabilities(cb) {
            callLog.push("getCapabilities");
            cb({
                mode: capabilitiesMode !== "" ? capabilitiesMode : mode,
                startableModes: startableModes,
                modeUnavailableReason: "",
                gitFound: gitFound,
                gitProblem: gitProblem,
                pathsProblem: pathsProblem,
                nodeId: identityExists ? identityNodeId : ""
            });
        }

        /// Whether `identity()` holds its reply instead of delivering it, so a
        /// test can observe the flow while a PREFLIGHT probe is outstanding.
        /// A synchronous fake settles before the next line of test code runs,
        /// which makes "the choice is withheld while the probe is in flight"
        /// indistinguishable from "the choice is never withheld".
        property bool holdIdentity: false

        function identity(cb) {
            callLog.push("getEmbeddedIdentity");
            if (holdIdentity) {
                held = function () { fake.deliverIdentity(cb); };
                return;
            }
            deliverIdentity(cb);
        }

        function deliverIdentity(cb) {
            // Note: `problem`, never `error` — the question was answered. The
            // core module documents this shape as designed for this wizard.
            cb({
                home: home,
                exists: identityExists,
                nodeId: identityExists ? identityNodeId : "",
                problem: identityProblem
            });
        }

        function nodeStatus(cb) {
            callLog.push("getNodeStatus");
            cb({ running: serving, serving: serving,
                 home: home, socket: "/run/u/radicle.sock", reason: "" });
        }

        /// Whether `seeds()` holds its reply instead of delivering it.
        ///
        /// This is the one probe that does NOT gate `preflightDone` — the seed
        /// list is the network step's data, not a finding — so it is the reply
        /// that can still be genuinely in flight at the moment the resume lands.
        /// That makes it the only way this synchronous harness can express the
        /// hazard the single-assignment landing exists to avoid: a landing that
        /// bumped the epoch would discard it, and nothing else here would
        /// notice, because every gating reply has already been written by then.
        property bool holdSeeds: false

        function seeds(cb) {
            callLog.push("listKnownSeeds");
            if (holdSeeds) {
                heldSeeds = function () { cb({ items: seedItems }); };
                return;
            }
            cb({ items: seedItems });
        }

        /// Held separately from `held`, so a test can hold the seed reply
        /// across a landing without disturbing the identity/start holds.
        property var heldSeeds: null

        function deliverHeldSeeds() {
            if (heldSeeds === null) return false;
            var f = heldSeeds;
            heldSeeds = null;
            f();
            return true;
        }

        function create(alias, passphrase, cb) {
            // The ARGUMENTS are logged, because "an identity was created" and
            // "the alias the user typed was the one sent" are different facts.
            callLog.push("createEmbeddedIdentity:" + alias + ":" + passphrase);
            if (createRefusal !== "") { cb({ error: createRefusal }); return; }
            cb({ created: true, nodeId: createdNodeId, home: home,
                 alias: alias, encrypted: passphrase !== "" });
        }

        function start(passphrase, cb) {
            callLog.push("startNode:" + passphrase);
            if (startRefusal !== "") { cb({ error: startRefusal }); return; }
            // A started node is one the socket answers for: the real
            // `startNode` returns only once the control socket responds, so a
            // fake that reported `started:true` while `getNodeStatus` kept
            // saying `serving:false` would be modelling a state the backend
            // cannot produce — and a test written against it would be asserting
            // about a node that does not exist.
            if (startStarted) serving = true;
            cb({ started: startStarted, home: home,
                 socket: "/run/u/radicle.sock",
                 nodeId: startNodeId, listening: startListening });
        }

        /// Holds its reply instead of delivering it. Used only where the
        /// requirement is about a reply arriving after the user moved on.
        function startHeld(passphrase, cb) {
            callLog.push("startNode:" + passphrase);
            held = function () {
                cb({ started: true, home: home, socket: "/run/u/radicle.sock",
                     nodeId: startNodeId, listening: startListening });
            };
        }

        function deliverHeld() {
            if (held === null) return false;
            var f = held;
            held = null;
            f();
            return true;
        }

        function setting(key, value, cb) {
            callLog.push("setSetting:" + key + ":" + value);
            if (settingRefusal !== "") { cb({ error: settingRefusal }); return; }
            // The real setSetting returns the whole settings object; the mode
            // in force then follows from a capabilities re-read, which is what
            // the flow does.
            mode = value;
            cb({ mode: value, radHome: "", radSocket: "",
                 gitPath: "", remoteSeed: "" });
        }
    }

    Ui.SetupFlow {
        id: flow
        fetchCapabilities: function (cb) { fake.capabilities(cb); }
        fetchIdentity: function (cb) { fake.identity(cb); }
        fetchNodeStatus: function (cb) { fake.nodeStatus(cb); }
        fetchSeeds: function (cb) { fake.seeds(cb); }
        createIdentity: function (a, p, cb) { fake.create(a, p, cb); }
        startNode: function (p, cb) { fake.start(p, cb); }
        saveSetting: function (k, v, cb) { fake.setting(k, v, cb); }
    }

    /// A second flow whose start call HOLDS its reply. Separate instance rather
    /// than a mutable property on the first, so the late-reply tests cannot
    /// leave the ordinary ones depending on which ran first.
    Ui.SetupFlow {
        id: heldFlow
        fetchCapabilities: function (cb) { fake.capabilities(cb); }
        fetchIdentity: function (cb) { fake.identity(cb); }
        fetchNodeStatus: function (cb) { fake.nodeStatus(cb); }
        fetchSeeds: function (cb) { fake.seeds(cb); }
        createIdentity: function (a, p, cb) { fake.create(a, p, cb); }
        startNode: function (p, cb) { fake.startHeld(p, cb); }
        saveSetting: function (k, v, cb) { fake.setting(k, v, cb); }
    }

    /// Walk the flow to a named step, so a test about the start step does not
    /// re-assert the navigation rules on its way there.
    function advanceTo(f, stepName) {
        for (var i = 0; i < 10 && f.step !== stepName; i++) {
            if (!f.advance()) break;
        }
        return f.step === stepName;
    }

    TestCase {
        name: "SetupFlowSteps"
        when: windowShown

        function init() {
            fake.gitFound = true;
            fake.gitProblem = "";
            fake.pathsProblem = "";
            fake.mode = "embedded";
            fake.capabilitiesMode = "";
            fake.startableModes = ["explore", "local", "embedded"];
            fake.identityExists = false;
            fake.identityNodeId = "";
            fake.identityProblem = "";
            fake.home = "/home/u/.local/share/basecamp/radicle";
            fake.serving = false;
            fake.createRefusal = "";
            fake.createdNodeId = "did:key:z6MkCREATED";
            fake.startRefusal = "";
            fake.startStarted = true;
            fake.startListening = [];
            fake.settingRefusal = "";
            fake.holdIdentity = false;
            fake.holdSeeds = false;
            fake.seedItems = [
                { url: "https://seed.radicle.xyz", alias: "radicle",
                  source: "builtin" }
            ];
            flow.reset();
            heldFlow.reset();
            fake.reset();
        }

        // ---- six steps in a fixed order -------------------------------------

        function test_the_flow_opens_on_preflight() {
            compare(flow.step, "preflight");
            compare(flow.canGoBack, false,
                    "back must not be offered on the first step");
        }

        /// **Before capabilities have answered, the embedded step does not
        /// advance.** Found by two tests of this file failing: they walked the
        /// sequence without running the preflight, and stalled at the embedded
        /// step because `modeInForce` was still "".
        ///
        /// That is the flow being right — "advancing past the embedded step
        /// MUST require that `getCapabilities().mode` reports `embedded`", and
        /// an unanswered backend has not reported embedded. Pinned
        /// deliberately, because the tempting "fix" is to treat an empty mode
        /// as permission to continue, which would let the four node steps run
        /// against a module in explore.
        function test_an_unanswered_mode_does_not_advance() {
            compare(flow.modeInForce, "",
                    "precondition: capabilities have not answered");
            verify(flow.advance(), "preflight -> embedded is always permitted");
            compare(flow.step, "embedded");
            compare(flow.canAdvance, false,
                    "an unknown mode in force must not continue into the four "
                    + "steps that are about an embedded node");
        }

        /// Both halves matter: the sequence is walked in order AND a sixth
        /// advance is a no-op. Without the second, a flow that ran off the end
        /// of the array would pass — `steps[6]` is undefined, which is not a
        /// step but is also not obviously wrong from one assertion.
        function test_advancing_walks_the_sequence_without_skipping() {
            // The preflight has to have answered, because the embedded step
            // will not advance until capabilities report `embedded` in force —
            // the scenario's default. Without this the walk stalls there,
            // which is the flow being right rather than the walk being wrong.
            flow.runPreflight();
            var want = ["embedded", "identity", "network", "start", "confirm"];
            for (var i = 0; i < want.length; i++) {
                verify(flow.advance(), "advance " + i + " must be permitted");
                compare(flow.step, want[i],
                        "step " + i + " must be " + want[i]);
            }
            compare(flow.advance(), false,
                    "a sixth advance must not be permitted");
            compare(flow.step, "confirm",
                    "and must leave the step in force at confirm");
        }

        function test_going_back_returns_to_the_previous_step() {
            flow.runPreflight();   // see the walk test above for why
            verify(harness.advanceTo(flow, "network"));
            verify(flow.back());
            compare(flow.step, "identity");
            verify(flow.back());
            compare(flow.step, "embedded");
        }

        /// Returning to a step that already acted must report what it did
        /// rather than offer to do it again. Identity creation is not
        /// reversible through this flow.
        ///
        /// **The forward control issuing no second creation call is the part
        /// that needs asserting, not just the gate.** `canCreateIdentity` going
        /// false says the CALL is refused; it does not say the control the user
        /// clicks refrains from making it. Those are two different things now
        /// that one control does both jobs, and the call log is what separates
        /// them.
        function test_returning_to_a_step_that_acted_does_not_offer_to_act_again() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            verify(flow.canCreateIdentity, "precondition: creation is offered");

            verify(flow.submitIdentityStep("tester", "pw"));
            compare(flow.identityExists, true, "precondition: it was created");
            compare(flow.step, "network",
                    "precondition: creating advanced in the same act");

            verify(flow.back());
            compare(flow.step, "identity");
            compare(flow.canCreateIdentity, false,
                    "an identity that exists must not be offered creation "
                    + "again — createEmbeddedIdentity refuses an occupied home");
            compare(flow.identityNodeId, fake.createdNodeId,
                    "and the created node id must still be displayed");

            // The control, invoked on the returned-to step, must issue nothing.
            fake.reset();
            verify(flow.submitIdentityStep("tester", "pw"));
            for (var i = 0; i < fake.callLog.length; i++)
                verify(String(fake.callLog[i])
                           .indexOf("createEmbeddedIdentity") !== 0,
                       "the forward control must issue no creation call on a "
                       + "step whose identity already exists, got: "
                       + JSON.stringify(fake.callLog));
            compare(flow.step, "network",
                    "and must advance instead");
        }

        // ---- the preflight --------------------------------------------------

        /// **A choice that depends on the preflight is withheld while the
        /// preflight is still outstanding**, not merely before it is issued.
        ///
        /// The spec says the findings are reported "before the flow offers any
        /// choice that depends on it". A synchronous fake cannot express that
        /// window at all — the callback fires before the next line of test code
        /// — so this uses a fake that HOLDS the identity reply, the same shape
        /// the late-reply tests use for `startNode`. Without it the requirement
        /// has no test that can fail: `reset()` undoes a completed preflight,
        /// which is a different state from one still in flight.
        function test_a_choice_is_withheld_while_its_probe_is_outstanding() {
            fake.holdIdentity = true;
            flow.runPreflight();

            compare(flow.preflightDone, false,
                    "precondition: the preflight has not finished asking");
            verify(fake.held !== null,
                   "precondition: the identity reply is being held");
            compare(flow.canCreateIdentity, false,
                    "creation must not be offered while the finding it depends "
                    + "on is still outstanding");

            // And it IS offered once the held reply lands — without which a
            // flow that never offered creation at all would pass the above.
            verify(fake.deliverHeld(), "the held reply now arrives");
            compare(flow.preflightDone, true,
                    "the preflight must finish once every probe has answered");
            compare(flow.canCreateIdentity, true,
                    "and the choice must be offered once its finding answered");
        }

        function test_the_four_findings_are_reported_separately() {
            flow.runPreflight();
            compare(flow.preflightDone, true, "the preflight must finish");
            compare(flow.gitFound, true);
            compare(flow.identityExists, false);
            compare(flow.alreadyServing, false);
            compare(flow.homeResolved, true);
        }

        /// **One failing check is distinguishable from another.** Two scenarios
        /// that fail DIFFERENT findings, each asserting the others stayed
        /// green. A flow that collapsed the findings into one verdict passes
        /// neither half.
        function test_one_failing_check_is_distinguishable_from_another() {
            fake.gitFound = false;
            fake.gitProblem = "no git on PATH, tried /usr/bin/git";
            flow.runPreflight();
            compare(flow.gitFound, false, "the git finding must be failed");
            compare(flow.homeResolved, true,
                    "and the home finding must NOT be");
            compare(flow.alreadyServing, false,
                    "and the socket finding must NOT be");

            // The other direction, with nothing else changed.
            flow.reset();
            fake.reset();
            fake.gitFound = true;
            fake.gitProblem = "";
            fake.pathsProblem = "socket path exceeds the 108-byte cap";
            flow.runPreflight();
            compare(flow.homeResolved, false,
                    "the paths finding must be failed");
            compare(flow.gitFound, true,
                    "and the git finding must NOT be");
        }

        /// `exists:false` must not be reported as "the home is empty": a
        /// half-created home reports it too, and the two are indistinguishable
        /// through this reply.
        function test_no_identity_yet_is_not_reported_as_an_empty_home() {
            flow.runPreflight();
            compare(flow.identityExists, false);
            compare(flow.identityProblem, "",
                    "an ordinary empty home carries no problem sentence");

            flow.reset();
            fake.reset();
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkEXISTING";
            flow.runPreflight();
            compare(flow.identityExists, true);
            compare(flow.identityNodeId, "did:key:z6MkEXISTING",
                    "an existing identity must carry its node id");
        }

        /// The backend's sentence is shown unaltered, because it names the path
        /// that was tried and the limit that was exceeded.
        function test_a_backend_sentence_is_available_unaltered() {
            fake.gitFound = false;
            fake.gitProblem = "no git: tried /nix/store/xyz/bin/git";
            flow.runPreflight();
            compare(flow.startBlockedReason,
                    "no git: tried /nix/store/xyz/bin/git",
                    "the backend's own sentence must be what is shown, not a "
                    + "generic replacement");
        }

        /// **The preflight writes nothing.** Asserted on the call log, because
        /// "nothing changed" is equally true of a flow that wrote and then
        /// discarded the result.
        function test_the_preflight_writes_nothing() {
            flow.runPreflight();
            for (var i = 0; i < fake.callLog.length; i++) {
                var c = String(fake.callLog[i]);
                verify(c.indexOf("createEmbeddedIdentity") !== 0,
                       "the preflight must not create an identity: " + c);
                verify(c.indexOf("startNode") !== 0,
                       "the preflight must not start a node: " + c);
                verify(c.indexOf("setSetting") !== 0,
                       "the preflight must not write a setting: " + c);
            }
            verify(fake.callLog.length >= 3,
                   "precondition: it really did ask: "
                   + JSON.stringify(fake.callLog));
        }

        // ---- blocking -------------------------------------------------------

        /// **git blocks start and NOT identity.** The single most tempting
        /// mistake is one `preflightPassed` boolean gating both.
        function test_a_missing_git_blocks_start_but_not_identity() {
            fake.gitFound = false;
            fake.gitProblem = "no git found";
            flow.runPreflight();

            compare(flow.canCreateIdentity, true,
                    "identity creation writes key material and spawns no git");
            compare(flow.canStartNode, false,
                    "the node cannot start without git");
            verify(flow.startBlockedReason.indexOf("git") !== -1,
                   "the displayed reason must name the git finding, got: "
                   + flow.startBlockedReason);
        }

        /// **An occupied home blocks the CALL and not the STEP.** The two used
        /// to be one property, which is what stranded a user on a step whose
        /// only act was already complete while an amber sentence told them
        /// creation was refused.
        ///
        /// Both halves are asserted, because they are the distinction: the
        /// creation gate is closed, and the forward control is open and
        /// advances without issuing anything.
        function test_an_occupied_home_blocks_creation_without_blocking_the_step() {
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkOCCUPIED";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            fake.reset();

            compare(flow.canCreateIdentity, false,
                    "the creation call must be refused for an occupied home");
            compare(flow.canAdvanceIdentity, true,
                    "but the step's forward control must stay available — the "
                    + "step's work is already done");

            verify(flow.submitIdentityStep("tester", "pw"));
            for (var i = 0; i < fake.callLog.length; i++)
                verify(String(fake.callLog[i])
                           .indexOf("createEmbeddedIdentity") !== 0,
                       "no creation call must go out, got: "
                       + JSON.stringify(fake.callLog));
            compare(flow.step, "network",
                    "and the control must advance");
        }

        /// **An unresolvable home blocks the step itself.** The other half of
        /// the split above: with no identity and nowhere to write, the control
        /// can neither create nor advance past work that was not done.
        ///
        /// The second scenario is what makes the first mean something — with the
        /// home resolvable and nothing else changed, the control is offered.
        function test_an_unresolvable_home_blocks_the_identity_step_itself() {
            fake.identityExists = false;
            fake.pathsProblem = "socket path exceeds the 108-byte cap";
            fake.home = "";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));

            compare(flow.canAdvanceIdentity, false,
                    "with no identity and nowhere to write, the forward "
                    + "control must not be enabled");
            compare(flow.submitIdentityStep("tester", "pw"), false,
                    "and invoking it must do nothing");
            compare(flow.step, "identity",
                    "leaving the step in force unchanged");
            verify(flow.createBlockedReason !== "",
                   "with the reason stated rather than left as a disabled "
                   + "control");

            // The only change: a home that resolves.
            flow.reset();
            fake.reset();
            fake.pathsProblem = "";
            fake.home = "/home/u/.local/share/basecamp/radicle";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            compare(flow.canAdvanceIdentity, true,
                    "a home that resolves must offer the control, with nothing "
                    + "else changed");
        }

        /// **One forward control creates AND advances, in one act.** The defect
        /// this replaces was two buttons — "Create identity" and "Next" — for a
        /// step where creating the identity *is* how it is left.
        function test_one_forward_control_creates_and_advances_together() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            fake.reset();

            verify(flow.submitIdentityStep("tester", "pw"));

            var creations = 0;
            for (var i = 0; i < fake.callLog.length; i++)
                if (String(fake.callLog[i])
                        .indexOf("createEmbeddedIdentity") === 0)
                    creations = creations + 1;
            compare(creations, 1, "exactly one creation call, got: "
                    + JSON.stringify(fake.callLog));
            compare(flow.step, "network",
                    "and the step must have been left without a second "
                    + "invocation");
        }

        /// **The label names the act the control will perform.** A button
        /// reading "Create identity" on a step that will only advance states an
        /// act that will not happen.
        ///
        /// Both directions, because a label stuck on either string would pass
        /// one assertion.
        function test_the_label_names_the_act_the_control_will_perform() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            var withNone = String(flow.identityActionLabel).toLowerCase();
            verify(withNone.indexOf("create") !== -1,
                   "with no identity the label must name creating one, got: "
                   + withNone);

            flow.reset();
            fake.reset();
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkOCCUPIED";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            var withOne = String(flow.identityActionLabel).toLowerCase();
            verify(withOne.indexOf("create") === -1,
                   "with an identity the label must NOT name creating one, "
                   + "got: " + withOne);
            verify(withOne.indexOf("continue") !== -1,
                   "and must name continuing to the next step, got: "
                   + withOne);
        }

        /// **The three states are told apart**, and what decides which is what
        /// the backend reported — never the step having been shown.
        ///
        /// The distinction that matters is the second versus the third: a user
        /// who already holds an identity has SUCCEEDED at this step, and a
        /// rendering that cannot tell "you just made this" from "this was
        /// already here" is the one that told them creation was refused.
        function test_the_three_identity_states_are_told_apart() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            compare(flow.identityState, "none",
                    "no identity reported means no identity state");
            compare(flow.identityNodeId, "",
                    "and no node id to display");

            fake.createdNodeId = "did:key:z6MkJUSTMADE";
            verify(flow.submitIdentityStep("tester", "pw"));
            compare(flow.identityState, "created",
                    "an identity this showing created must report as created");
            compare(flow.identityNodeId, "did:key:z6MkJUSTMADE",
                    "carrying the node id the reply reported");

            // A fresh showing over a backend that already has one, with no
            // creation submitted.
            flow.reset();
            fake.reset();
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkWASALREADYTHERE";
            flow.runPreflight();
            compare(flow.identityState, "present",
                    "an identity found on arrival must NOT report as created "
                    + "by this showing");
            compare(flow.identityNodeId, "did:key:z6MkWASALREADYTHERE",
                    "carrying the second node id");
        }

        /// **An identity that was already there is not reported as a failure.**
        /// The refusal surface is reserved for a refusal the backend returned to
        /// THIS showing; nothing was attempted here.
        function test_an_identity_already_there_is_not_reported_as_a_failure() {
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkOCCUPIED";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));

            compare(flow.lastError, "",
                    "no refusal must be displayed for an attempt nobody made");
            compare(flow.createBlockedReason, "",
                    "and the blocking surface must not claim creation was "
                    + "refused: this step's work is done, not obstructed");
        }

        /// **Created and refused are never both in force.** They describe
        /// different outcomes of the same act, and both at once leaves the user
        /// unable to tell which occurred — which is what the screenshot showed.
        function test_created_and_refused_are_never_in_force_together() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));

            verify(flow.submitIdentityStep("tester", "pw"));
            compare(flow.identityState, "created", "precondition: created");
            compare(flow.lastError, "",
                    "a successful creation must leave no refusal displayed");
            compare(flow.createBlockedReason, "",
                    "nor any statement that creating one is refused");
        }

        /// **A half-created home is OFFERED creation**, and the backend's
        /// refusal — the only surface naming the `keys` path — is what the user
        /// sees. `getEmbeddedIdentity` cannot distinguish it from an empty home.
        function test_a_half_created_home_is_offered_creation_and_shows_its_refusal() {
            fake.identityExists = false;      // exactly as an empty home reports
            fake.identityProblem = "";
            fake.createRefusal = "a partially created home is in the way: "
                               + "remove /home/u/.local/share/radicle/keys";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));

            compare(flow.canCreateIdentity, true,
                    "creation must be offered — the preflight cannot tell a "
                    + "half-created home from an empty one");

            flow.submitIdentity("tester", "");
            compare(flow.lastError, fake.createRefusal,
                    "the backend's refusal must be displayed verbatim");
            compare(flow.identityExists, false,
                    "and the flow must not report the identity as created");
        }

        function test_a_node_already_serving_blocks_start() {
            fake.serving = true;
            flow.runPreflight();

            compare(flow.canStartNode, false);
            verify(flow.startBlockedReason.indexOf("already answering") !== -1,
                   "the reason must state a node is already answering on the "
                   + "socket, got: " + flow.startBlockedReason);
        }

        /// **A block lifts when its finding passes**, with nothing else
        /// changed. This is what proves the block is keyed on the finding
        /// rather than on some remembered verdict.
        function test_a_block_lifts_when_its_finding_passes() {
            fake.gitFound = false;
            fake.gitProblem = "no git found";
            flow.runPreflight();
            compare(flow.canStartNode, false, "precondition: start is blocked");

            flow.reset();
            fake.reset();
            fake.gitFound = true;          // the ONLY change
            fake.gitProblem = "";
            flow.runPreflight();
            compare(flow.canStartNode, true,
                    "a backend reporting the finding as passing must remove "
                    + "the block with nothing else changed");
        }

        // ---- the embedded step ----------------------------------------------
        //
        // A CONFIRMATION, not a pick. The flow sets up one mode, so there is no
        // `chooseMode(mode)` to drive with `explore` — `confirmEmbedded()` takes
        // no argument and the only write it can express is `mode=embedded`.

        function test_only_embedded_continues_the_flow() {
            fake.mode = "local";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "embedded"));
            compare(flow.modeInForce, "local", "precondition");
            compare(flow.canAdvance, false,
                    "the four steps after this one are about a node no other "
                    + "mode runs");
            verify(flow.advanceBlockedReason !== "",
                   "and the refusal must be stated rather than left as a "
                   + "disabled control");

            fake.mode = "embedded";
            flow.refreshCapabilities();
            compare(flow.modeInForce, "embedded");
            compare(flow.canAdvance, true,
                    "Embedded must continue the flow");
        }

        /// **Arriving at the step writes no mode.** A mode written on arrival
        /// would put a module into Embedded because someone opened a screen,
        /// and would make the step's stated consequence something the user was
        /// shown rather than something they answered.
        ///
        /// Asserted on the call log rather than on `modeInForce`, because a
        /// flow that wrote `embedded` against a backend already reporting
        /// `local` would leave `modeInForce` untouched and look innocent.
        function test_arriving_at_the_embedded_step_writes_no_mode() {
            fake.mode = "local";
            flow.runPreflight();
            fake.reset();

            verify(harness.advanceTo(flow, "embedded"));
            for (var i = 0; i < fake.callLog.length; i++)
                verify(String(fake.callLog[i]).indexOf("setSetting") !== 0,
                       "arriving must write no setting, got: "
                       + JSON.stringify(fake.callLog));
            compare(flow.modeInForce, "local",
                    "and the mode in force must not have moved");
        }

        /// **Going back from the step writes no mode either.** The same
        /// requirement on the other exit: a user who opened the flow and
        /// thought better of it is in the mode they started in.
        function test_going_back_from_the_embedded_step_writes_no_mode() {
            fake.mode = "local";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "embedded"));
            fake.reset();

            verify(flow.back());
            compare(flow.step, "preflight");
            for (var i = 0; i < fake.callLog.length; i++)
                verify(String(fake.callLog[i]).indexOf("setSetting") !== 0,
                       "going back must write no setting, got: "
                       + JSON.stringify(fake.callLog));
            compare(flow.modeInForce, "local",
                    "and the mode in force must not have moved");
        }

        /// **The step's control puts Embedded in force**, and exactly one write
        /// goes out carrying key `mode` and value `embedded`.
        function test_the_control_puts_embedded_in_force() {
            fake.mode = "local";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "embedded"));
            compare(flow.canAdvance, false, "precondition: not yet permitted");
            fake.reset();

            verify(flow.confirmEmbedded());

            var writes = [];
            for (var i = 0; i < fake.callLog.length; i++)
                if (String(fake.callLog[i]).indexOf("setSetting") === 0)
                    writes.push(String(fake.callLog[i]));
            compare(writes.length, 1,
                    "exactly one setting write, got: "
                    + JSON.stringify(fake.callLog));
            compare(writes[0], "setSetting:mode:embedded",
                    "with key `mode` and value `embedded`");
            compare(flow.modeInForce, "embedded");
            compare(flow.canAdvance, true, "and advancing must be permitted");
        }

        /// **The mode in force is the reply, not the value written.** The
        /// backend accepts the write and goes on reporting `local`; a flow
        /// recording its own copy would say `embedded` and let the user walk
        /// into four steps about a node the module is not running.
        ///
        /// `capabilitiesMode` is what makes this expressible: while the written
        /// value and the reported one agree, "re-read capabilities" and
        /// "trusted the value written" are indistinguishable.
        ///
        /// **What the `modeInForce` assertion alone cannot catch**, and why the
        /// call-log one is here rather than being belt-and-braces: the fake is
        /// synchronous, so `refreshCapabilities()` settles before the next line
        /// of test code. A flow that assigned `modeInForce = "embedded"` AND
        /// then re-read would have the assignment overwritten within the same
        /// turn, and every value assertion below would stay green. Proven by
        /// mutation — adding that assignment before the refresh reddens
        /// nothing. The `getCapabilities` entry in the call log is what
        /// actually pins "re-read"; deleting the refresh reddens exactly that
        /// assertion.
        function test_the_mode_in_force_is_the_reply_not_the_value_written() {
            fake.mode = "local";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "embedded"));
            fake.reset();

            fake.capabilitiesMode = "local";   // accepted, still reports local
            verify(flow.confirmEmbedded());

            verify(fake.callLog.indexOf("setSetting:mode:embedded") !== -1,
                   "the write must have gone out, got: "
                   + JSON.stringify(fake.callLog));
            verify(fake.callLog.indexOf("getCapabilities") !== -1,
                   "and capabilities must be re-read rather than the flow "
                   + "recording its own copy, got: "
                   + JSON.stringify(fake.callLog));
            compare(flow.modeInForce, "local",
                    "the mode in force must be what capabilities REPORTS");
            compare(flow.canAdvance, false,
                    "and a backend that has not reported embedded has not "
                    + "confirmed the write landed");

            // And when the backend does report it, the flow follows — without
            // which a flow that never updated `modeInForce` would pass above.
            fake.capabilitiesMode = "";
            flow.refreshCapabilities();
            compare(flow.modeInForce, "embedded",
                    "a backend reporting the new mode must move the mode in "
                    + "force");
            compare(flow.canAdvance, true);
        }

        /// **A refused write neither advances nor moves the mode in force**,
        /// and the refusal is displayed.
        function test_a_refused_mode_write_does_not_move_the_mode_in_force() {
            fake.mode = "local";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "embedded"));
            fake.settingRefusal = "the settings store refused: a distinctive "
                                + "sentence";

            verify(flow.confirmEmbedded());
            compare(flow.lastError, fake.settingRefusal,
                    "the refusal must be displayed as the backend worded it");
            compare(flow.modeInForce, "local",
                    "and the mode in force must not have moved");
            compare(flow.canAdvance, false,
                    "and advancing must not be permitted");
            compare(flow.step, "embedded",
                    "and the step in force must still be the embedded step");
        }

        /// **Returning with Embedded already in force does not re-offer it.**
        /// The write is idempotent, so this is about not asking a question the
        /// backend has already answered — which is why the flow still permits
        /// advancing rather than treating the step as unfinished.
        ///
        /// The second half is what stops a flow that never offers the control
        /// from passing: with `local` in force it must be offered.
        function test_returning_with_embedded_in_force_does_not_re_offer_it() {
            fake.mode = "embedded";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "embedded"));

            compare(flow.canConfirmEmbedded, false,
                    "the control must not be offered when the backend has "
                    + "already answered the question it asks");
            compare(flow.canAdvance, true,
                    "and advancing must still be permitted");

            flow.reset();
            fake.reset();
            fake.mode = "local";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "embedded"));
            compare(flow.canConfirmEmbedded, true,
                    "and it MUST be offered when Embedded is not in force");
        }

        /// **No other mode is expressible.** `confirmEmbedded()` takes no
        /// argument, so the flow has no way to write `explore` or `local` — the
        /// requirement holds in the state object rather than only in what the
        /// screen happens to draw.
        ///
        /// Asserted as the absence of the old entry point rather than by trying
        /// to call it: `flow.chooseMode` existing again would mean a mode
        /// argument is expressible again, which is the regression.
        function test_the_flow_cannot_express_another_mode() {
            compare(typeof flow.chooseMode, "undefined",
                    "a function taking a mode argument must not exist on this "
                    + "flow — the only write it can express is mode=embedded");
            compare(flow.confirmEmbedded.length, 0,
                    "and the confirm control must take no mode argument");
        }

        /// **What the startable set reports changes nothing here.** The flow
        /// does not read `startableModes` at all, so a backend reporting all
        /// three and one reporting only `embedded` are indistinguishable to it
        /// — which is the point: a flow setting up one mode has no unstartable
        /// alternative to caption.
        function test_the_startable_set_does_not_reach_this_step() {
            compare(flow.startableModes, undefined,
                    "the flow must not hold the startable set: with no value "
                    + "to caption FROM, no annotation can be reintroduced "
                    + "without first reintroducing the property");

            fake.mode = "embedded";
            fake.startableModes = ["explore", "local", "embedded"];
            flow.runPreflight();
            verify(harness.advanceTo(flow, "embedded"));
            var withAll = flow.canConfirmEmbedded + "|" + flow.canAdvance
                        + "|" + flow.advanceBlockedReason;

            flow.reset();
            fake.reset();
            fake.mode = "embedded";
            fake.startableModes = ["embedded"];
            flow.runPreflight();
            verify(harness.advanceTo(flow, "embedded"));
            var withOne = flow.canConfirmEmbedded + "|" + flow.canAdvance
                        + "|" + flow.advanceBlockedReason;

            compare(withOne, withAll,
                    "what the step offers must be unchanged by the startable "
                    + "set");
        }

        // ---- the identity step ----------------------------------------------

        /// The alias and passphrase reach the backend exactly as given, and an
        /// unencrypted identity is an EMPTY passphrase rather than an absent
        /// argument.
        function test_an_unencrypted_identity_is_created_with_an_empty_passphrase() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            fake.reset();

            verify(flow.submitIdentity("tester", ""));
            compare(fake.callLog.length, 1,
                    "exactly one creation call: "
                    + JSON.stringify(fake.callLog));
            compare(fake.callLog[0], "createEmbeddedIdentity:tester:",
                    "the alias must be passed as typed and the passphrase must "
                    + "be the empty string");
        }

        function test_a_set_passphrase_is_the_one_passed_through() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            fake.reset();

            verify(flow.submitIdentity("tester", "correct horse battery"));
            compare(fake.callLog[0],
                    "createEmbeddedIdentity:tester:correct horse battery");
        }

        /// **A refused creation stays on the step with the control available**,
        /// so the user can correct what was refused and submit again. The second
        /// half — the retry succeeding — is what stops a flow that never
        /// advanced from passing the first.
        function test_a_refused_creation_stays_on_the_step_and_can_retry() {
            fake.createRefusal = "alias may not contain whitespace";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));

            verify(flow.submitIdentityStep("not valid", "pw"));
            compare(flow.lastError, "alias may not contain whitespace",
                    "the refusal must be displayed as the backend worded it");
            compare(flow.step, "identity",
                    "and the step in force must still be the identity step");
            compare(flow.canAdvanceIdentity, true,
                    "with the forward control still available for the retry");
            compare(flow.identityState, "none",
                    "and nothing reported as created");

            fake.createRefusal = "";
            verify(flow.submitIdentityStep("tester", "pw"));
            compare(flow.step, "network",
                    "a retry the backend accepts must leave the step");
        }

        /// A rejected alias is reported FROM the backend, not pre-empted: the
        /// call must be issued, and the backend's message displayed.
        function test_a_rejected_alias_is_reported_from_the_backend() {
            fake.createRefusal = "alias may not contain whitespace";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            fake.reset();

            flow.submitIdentity("not valid", "pw");
            compare(fake.callLog.length, 1,
                    "the call must be issued rather than pre-validated away: "
                    + JSON.stringify(fake.callLog));
            compare(flow.lastError, "alias may not contain whitespace");
        }

        // ---- refusals -------------------------------------------------------

        /// **Two different refusals display two different messages.** A flow
        /// that latched the first would pass a single-message assertion.
        function test_two_different_refusals_display_two_different_messages() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));

            fake.createRefusal = "the first distinctive refusal";
            flow.submitIdentity("tester", "");
            compare(flow.lastError, "the first distinctive refusal");

            fake.createRefusal = "a second, entirely different refusal";
            flow.submitIdentity("tester", "");
            compare(flow.lastError, "a second, entirely different refusal",
                    "the second message must be shown");
            verify(flow.lastError.indexOf("first") === -1,
                   "and the first must not be");
        }

        function test_a_success_clears_a_previously_displayed_refusal() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));

            fake.createRefusal = "a refusal to clear";
            flow.submitIdentity("tester", "");
            verify(flow.lastError !== "", "precondition: a refusal is shown");

            fake.createRefusal = "";
            flow.submitIdentity("tester", "");
            compare(flow.lastError, "",
                    "a subsequent successful call must clear the refusal");
        }

        // ---- the start step -------------------------------------------------

        function test_a_started_node_is_reported_only_on_a_success_reply() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "start"));

            verify(flow.submitStart("pw"));
            compare(flow.nodeStarted, true);
            compare(flow.nodeId, fake.startNodeId,
                    "the reported node id must be the one in the reply");
        }

        /// A reply that merely ARRIVED is not a started node. `started:false`
        /// with no error must not be reported as success.
        function test_a_reply_without_started_true_is_not_a_started_node() {
            fake.startStarted = false;
            flow.runPreflight();
            verify(harness.advanceTo(flow, "start"));

            flow.submitStart("pw");
            compare(flow.nodeStarted, false,
                    "success must follow `started:true`, never the call having "
                    + "been issued");
            verify(flow.lastError !== "",
                   "and the flow must say something rather than look started");
        }

        function test_an_error_reply_is_displayed_and_does_not_advance() {
            fake.startRefusal = "the node refused: a distinctive sentence";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "start"));

            flow.submitStart("pw");
            compare(flow.lastError, "the node refused: a distinctive sentence");
            compare(flow.nodeStarted, false);
            compare(flow.step, "start",
                    "the step in force must still be the start step");
        }

        /// The start control is withheld while a start is outstanding, so a
        /// second node is not started over the first.
        function test_the_start_control_is_withheld_while_a_start_is_outstanding() {
            heldFlow.runPreflight();
            verify(harness.advanceTo(heldFlow, "start"));
            compare(heldFlow.canStartNode, true, "precondition");

            verify(heldFlow.submitStart("pw"));
            compare(heldFlow.startPending, true,
                    "the waiting state must be observable");
            compare(heldFlow.canStartNode, false,
                    "the start control must not be offered again");

            verify(fake.deliverHeld());
            compare(heldFlow.startPending, false,
                    "and must be released when the reply lands");
        }

        /// **A successful start withdraws the start control.** The spec makes
        /// start non-reversible through this flow ("a step that has performed
        /// one MUST report what it did when it is returned to, rather than
        /// offering to do it again"), and `startBlockedReason` already names
        /// the contention for the case the PREFLIGHT detected. The same
        /// contention is reachable through this flow's own start button after
        /// its own successful start, which is what this pins.
        ///
        /// The second half is the one that makes the first mean something: a
        /// flow that withdrew the control unconditionally would pass the
        /// `canStartNode === false` assertion while being broken. So a start
        /// that FAILED must leave the control offered, because retrying is the
        /// correct response to a refusal.
        function test_a_successful_start_withdraws_the_start_control() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "start"));
            compare(flow.canStartNode, true, "precondition: start is offered");

            verify(flow.submitStart("pw"));
            compare(flow.nodeStarted, true, "precondition: it started");
            compare(flow.canStartNode, false,
                    "a node this flow started is a node already answering on "
                    + "the socket — starting a second would contend for it");
            verify(flow.startBlockedReason !== "",
                   "and the reason must be stated rather than left as a "
                   + "disabled control with no explanation");

            // The other direction, so the assertion above cannot pass against
            // a flow that simply never offers start twice.
            flow.reset();
            fake.reset();
            fake.startRefusal = "the node refused to start";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "start"));
            flow.submitStart("pw");
            compare(flow.nodeStarted, false, "precondition: it did not start");
            compare(flow.canStartNode, true,
                    "a start that FAILED must leave the control offered — "
                    + "retrying is the correct response to a refusal");
        }

        /// An EMPTY listening list is the expected value and must be rendered
        /// as one, because it is what confirms the outbound-only default.
        function test_an_empty_listening_list_is_carried_rather_than_dropped() {
            fake.startListening = [];
            flow.runPreflight();
            verify(harness.advanceTo(flow, "start"));

            flow.submitStart("pw");
            compare(flow.nodeStarted, true);
            compare(flow.listening.length, 0,
                    "an empty listening array is the state to display, not to "
                    + "omit");

            // And a non-empty one is carried through, so the assertion above
            // cannot pass against a flow that ignores the field entirely.
            flow.reset();
            fake.reset();
            fake.startListening = ["0.0.0.0:8776"];
            flow.runPreflight();
            verify(harness.advanceTo(flow, "start"));
            flow.submitStart("pw");
            compare(flow.listening.length, 1,
                    "a reported address must be carried through");
            compare(flow.listening[0], "0.0.0.0:8776");
        }

        /// **`serving`, not `running`.** A node whose threads have died leaves
        /// `running` true while `serving` goes false.
        function test_a_node_that_stops_serving_is_shown_as_not_serving() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "start"));
            flow.submitStart("pw");
            compare(flow.nodeStarted, true, "precondition: it started");

            fake.serving = false;
            flow.refreshNodeStatus();
            compare(flow.nodeServing, false,
                    "a node reporting running:true with serving:false must not "
                    + "be displayed as serving");

            fake.serving = true;
            flow.refreshNodeStatus();
            compare(flow.nodeServing, true,
                    "and must be shown as serving when it is");
        }

        // ---- the confirm step -----------------------------------------------

        /// The allow line carries the DID that was reported, and the second
        /// assertion checks the FIRST DID is gone — without which a flow that
        /// concatenated both would pass.
        function test_the_allow_line_carries_the_reported_did() {
            fake.createdNodeId = "did:key:z6MkFIRSTDID";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            flow.submitIdentity("tester", "");
            verify(harness.advanceTo(flow, "confirm"));

            verify(flow.allowCommand.indexOf("rad id update --allow") === 0,
                   "an allow line must be displayed, got: "
                   + flow.allowCommand);
            verify(flow.allowCommand.indexOf("did:key:z6MkFIRSTDID") !== -1,
                   "carrying the reported DID, got: " + flow.allowCommand);

            flow.reset();
            fake.reset();
            fake.createdNodeId = "did:key:z6MkSECONDDID";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            flow.submitIdentity("tester", "");
            verify(harness.advanceTo(flow, "confirm"));

            verify(flow.allowCommand.indexOf("did:key:z6MkSECONDDID") !== -1,
                   "the line must carry the second DID");
            verify(flow.allowCommand.indexOf("did:key:z6MkFIRSTDID") === -1,
                   "and must NOT still carry the first");
        }

        /// No DID means no half-formed command on screen. `--allow ` with
        /// nothing after it is a line a user could copy and run.
        function test_no_did_means_no_allow_line() {
            compare(flow.nodeId, "", "precondition: nothing reported yet");
            compare(flow.allowCommand, "",
                    "a placeholder allow line is a command a user can copy and "
                    + "run against nothing");
        }

        // ---- staleness ------------------------------------------------------

        /// **A late reply does not repopulate a step the user has left.**
        /// Only a fake that holds its reply can express this; a synchronous one
        /// settles before the step changes and the requirement cannot fail.
        function test_a_late_reply_does_not_repopulate_a_step_the_user_left() {
            heldFlow.runPreflight();
            verify(harness.advanceTo(heldFlow, "start"));

            verify(heldFlow.submitStart("pw"));
            verify(heldFlow.held !== null || fake.held !== null,
                   "precondition: the reply is being held");

            // The user moves on before the reply lands.
            verify(heldFlow.back());
            compare(heldFlow.step, "network");

            verify(fake.deliverHeld(), "the held reply now arrives");
            compare(heldFlow.nodeStarted, false,
                    "a reply issued from the start step must not repopulate "
                    + "the step now in force");
        }

        /// The other direction: without the step change, the SAME reply does
        /// land. Without this, a flow that dropped every reply would pass the
        /// test above.
        function test_a_reply_arriving_on_the_same_step_does_land() {
            heldFlow.runPreflight();
            verify(harness.advanceTo(heldFlow, "start"));

            verify(heldFlow.submitStart("pw"));
            verify(fake.deliverHeld());
            compare(heldFlow.nodeStarted, true,
                    "a reply arriving with the user still on the step that "
                    + "issued it must be applied");
        }

        // ---- re-entry -------------------------------------------------------
        //
        // A reopened setup lands at the first step with work left, derived from
        // what the backend reports. Every write the flow makes is separately
        // durable — the mode, the identity and the node each land on their own —
        // so there is no half-committed state to resume into, and the backend is
        // therefore the authority on what remains.

        /// **Different backend states resume to different steps.**
        ///
        /// The whole requirement in one test, and the input-dependence rule
        /// applied at the level that matters: a `restart()` that always returned
        /// step 3 would satisfy any single-scenario assertion here. Four
        /// scenarios, four different answers.
        function test_different_backend_states_resume_to_different_steps() {
            var landed = [];

            function raiseAgainst(mode, exists, serving) {
                fake.mode = mode;
                fake.capabilitiesMode = "";
                fake.identityExists = exists;
                fake.identityNodeId = exists ? "did:key:z6MkEXISTING" : "";
                fake.serving = serving;
                flow.restart();
                landed.push(flow.step);
            }

            // Mode not yet embedded: the mode write is the work left.
            raiseAgainst("local", false, false);
            // Embedded, no identity: creating it is.
            raiseAgainst("embedded", false, false);
            // An identity, node not serving: starting it is.
            raiseAgainst("embedded", true, false);
            // An identity and a serving node: nothing is, so confirm.
            raiseAgainst("embedded", true, true);

            compare(landed.join(" "), "embedded identity start confirm",
                    "the landing step must follow the replies, so a flow given "
                    + "different replies lands on different steps");
        }

        /// **The step reached last time does not decide where it reopens.**
        ///
        /// A remembered index is a second opinion, and it is wrong whenever
        /// anything changed between the two showings. So the flow is walked well
        /// past its landing step, lowered, and raised again — and must come back
        /// to where the BACKEND says the work is, not to where the user was.
        function test_the_step_reached_last_time_does_not_decide_where_it_reopens() {
            fake.mode = "embedded";
            fake.identityExists = false;

            flow.restart();
            compare(flow.step, "identity", "precondition: it landed at identity");

            // The user walks on, then closes.
            verify(harness.advanceTo(flow, "network"));
            compare(flow.step, "network");

            // Raised again, against an unchanged backend.
            flow.restart();
            compare(flow.step, "identity",
                    "a second showing must re-derive rather than resume at the "
                    + "step the first was closed on");

            // And with the backend now further along, it lands further along —
            // which is what a remembered index could never do.
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkEXISTING";
            fake.serving = true;
            flow.restart();
            compare(flow.step, "confirm",
                    "an identity created and a node started elsewhere must move "
                    + "the landing step, with nothing here remembering anything");
        }

        /// **The flow waits at preflight rather than resuming from defaults.**
        ///
        /// Every finding has a legitimate falsy value, so a resume that read the
        /// defaults would land every reopening on the same early step whatever
        /// the backend holds. The identity reply is HELD, which is the only way
        /// to express the window at all — a synchronous fake settles before the
        /// next line of test code runs.
        function test_the_flow_waits_at_preflight_rather_than_resuming_from_defaults() {
            fake.mode = "embedded";
            fake.serving = true;
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkEXISTING";
            fake.holdIdentity = true;

            flow.restart();
            compare(flow.preflightDone, false,
                    "precondition: a probe is still outstanding");
            compare(flow.step, "preflight",
                    "the flow must wait at preflight rather than choose a step "
                    + "from replies that have not arrived");

            verify(fake.deliverHeld(), "the withheld reply now arrives");
            compare(flow.step, "confirm",
                    "and only then does it land, on the step the replies chose");
        }

        /// **The resumed step's findings are populated.**
        ///
        /// The spec's scenario, asserted directly: the identity finding carries
        /// the node id at the step the resume chose, and creation is not offered
        /// for an identity that exists. The two fail differently — one is a
        /// display that lost its data, the other a control that would refuse.
        ///
        /// **This test does NOT catch a landing that loops `advance()`**, and
        /// that was verified rather than assumed: the loop left every test in
        /// this file green. The harness is synchronous, so all three gating
        /// replies have already been written by the time the landing runs, and
        /// bumping the epoch afterwards discards nothing. The test that does
        /// catch it is `test_the_landing_does_not_discard_a_reply_still_in_flight`,
        /// which holds the one reply that can still be in flight at that moment.
        /// Recorded here because this is the test a reader would expect to be
        /// the guard, and it is not.
        function test_the_resumed_steps_findings_are_populated() {
            fake.mode = "embedded";
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkDISTINCTIVE";
            fake.serving = false;

            flow.restart();

            compare(flow.step, "start", "precondition: it landed at start");
            compare(flow.identityExists, true,
                    "the identity finding must survive the landing");
            compare(flow.identityNodeId, "did:key:z6MkDISTINCTIVE",
                    "carrying the node id the backend reported");
            compare(flow.preflightDone, true,
                    "and the preflight must still read as answered");
            compare(flow.canCreateIdentity, false,
                    "so creation is not offered for an identity that exists");
        }

        /// **The landing must not invalidate the preflight's own replies**, and
        /// this is the test that can see the difference.
        ///
        /// `test_the_resumed_steps_findings_are_populated` above asserts the
        /// findings survive, and CANNOT fail against a landing that loops
        /// `advance()`: this harness is synchronous, so every gating reply has
        /// already been written by the time the landing runs, and bumping the
        /// epoch afterwards discards nothing. That was verified by mutation, not
        /// assumed — under the loop it stayed green, and the test below was the
        /// only one in this file that reddened.
        ///
        /// The reply that IS still in flight at that moment is the seed list,
        /// because it is the one probe that does not gate `preflightDone`. So it
        /// is held across the landing and delivered afterwards. A landing that
        /// bumped the epoch drops it, and the network step the user is about to
        /// walk to renders no seeds at all — silently, because an empty seed
        /// list is also what a backend reporting no seeds produces.
        ///
        /// **Reverting `landOnFirstUnfinishedStep()` to a loop over `advance()`
        /// turns this test red, and only this one.**
        function test_the_landing_does_not_discard_a_reply_still_in_flight() {
            fake.mode = "embedded";
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkEXISTING";
            fake.serving = false;
            fake.seedItems = [
                { url: "https://seed.one.example", alias: "one" },
                { url: "https://seed.two.example", alias: "two" }
            ];
            fake.holdSeeds = true;

            flow.restart();

            compare(flow.step, "start",
                    "precondition: it landed, while the seed reply was held");
            verify(fake.heldSeeds !== null,
                   "precondition: the seed reply is still in flight");

            verify(fake.deliverHeldSeeds(), "it now arrives");
            compare(flow.seeds.length, 2,
                    "a reply issued by the preflight that lands after the "
                    + "landing must still be applied — the landing moved the "
                    + "step, so a landing that also moved the epoch would have "
                    + "discarded it and left the network step with no seeds");
            compare(flow.seeds[0].alias, "one",
                    "carrying what the backend reported");
        }

        /// A resumed step behaves exactly as one reached by advancing. Walked to
        /// the same step by hand, the flow answers the same questions the same
        /// way — so "resumed" is not a second kind of state.
        function test_a_resumed_step_behaves_as_one_reached_by_advancing() {
            fake.mode = "embedded";
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkEXISTING";
            fake.serving = false;

            flow.restart();
            compare(flow.step, "start", "precondition: resumed to start");
            var resumedCanStart = flow.canStartNode;
            var resumedCanCreate = flow.canCreateIdentity;

            // The same backend, reached by walking instead.
            flow.reset();
            flow.runPreflight();
            verify(harness.advanceTo(flow, "start"));
            compare(flow.canStartNode, resumedCanStart,
                    "a resumed start step must gate a start exactly as a walked "
                    + "one does");
            compare(flow.canCreateIdentity, resumedCanCreate,
                    "and must refuse creation for the same reason");
        }

        /// The resume happens ONCE per showing, not on every later reply.
        ///
        /// `preflightDone` goes true once, but a flow that re-derived its step
        /// whenever the findings moved would yank a user off a step they walked
        /// to — a node that stops serving while the user is reading the confirm
        /// step must not throw them back to start.
        function test_a_later_reply_does_not_move_a_step_the_user_walked_to() {
            fake.mode = "embedded";
            fake.identityExists = false;

            flow.restart();
            compare(flow.step, "identity", "precondition");

            verify(harness.advanceTo(flow, "network"));
            compare(flow.step, "network");

            // A later reading of the node's state lands, as `refreshNodeStatus`
            // does after a start. The step in force must not move.
            flow.refreshNodeStatus();
            compare(flow.step, "network",
                    "a reply arriving after the landing must not re-derive the "
                    + "step the user has since walked to");
        }
    }
}
