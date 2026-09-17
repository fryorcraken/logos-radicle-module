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

        function reset() {
            callLog = [];
            held = null;
        }

        function capabilities(cb) {
            callLog.push("getCapabilities");
            cb({
                mode: mode,
                startableModes: startableModes,
                modeUnavailableReason: "",
                gitFound: gitFound,
                gitProblem: gitProblem,
                pathsProblem: pathsProblem,
                nodeId: identityExists ? identityNodeId : ""
            });
        }

        function identity(cb) {
            callLog.push("getEmbeddedIdentity");
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

        function seeds(cb) {
            callLog.push("listKnownSeeds");
            cb({ items: seedItems });
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

        /// **Before capabilities have answered, the mode step does not
        /// advance.** Found by two tests of this file failing: they walked the
        /// sequence without running the preflight, and stalled at mode because
        /// `modeInForce` was still "".
        ///
        /// That is the flow being right — "advancing past the mode step MUST
        /// require that the mode in force is embedded", and an unanswered
        /// backend has not reported embedded. Pinned deliberately, because the
        /// tempting "fix" is to treat an empty mode as permission to continue,
        /// which would let the four node steps run against a module in explore.
        function test_an_unanswered_mode_does_not_advance() {
            compare(flow.modeInForce, "",
                    "precondition: capabilities have not answered");
            verify(flow.advance(), "preflight -> mode is always permitted");
            compare(flow.step, "mode");
            compare(flow.canAdvance, false,
                    "an unknown mode in force must not continue into the four "
                    + "steps that are about an embedded node");
        }

        /// Both halves matter: the sequence is walked in order AND a sixth
        /// advance is a no-op. Without the second, a flow that ran off the end
        /// of the array would pass — `steps[6]` is undefined, which is not a
        /// step but is also not obviously wrong from one assertion.
        function test_advancing_walks_the_sequence_without_skipping() {
            // The preflight has to have answered, because the mode step will
            // not advance until capabilities report `embedded` in force — the
            // scenario's default. Without this the walk stalls at mode, which
            // is the flow being right rather than the walk being wrong.
            flow.runPreflight();
            var want = ["mode", "identity", "network", "start", "confirm"];
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
            compare(flow.step, "mode");
        }

        /// Returning to a step that already acted must report what it did
        /// rather than offer to do it again. Identity creation is not
        /// reversible through this flow.
        function test_returning_to_a_step_that_acted_does_not_offer_to_act_again() {
            flow.runPreflight();
            verify(harness.advanceTo(flow, "identity"));
            verify(flow.canCreateIdentity, "precondition: creation is offered");

            verify(flow.submitIdentity("tester", "pw"));
            compare(flow.identityExists, true, "precondition: it was created");

            verify(flow.advance());
            verify(flow.back());
            compare(flow.step, "identity");
            compare(flow.canCreateIdentity, false,
                    "an identity that exists must not be offered creation "
                    + "again — createEmbeddedIdentity refuses an occupied home");
            compare(flow.identityNodeId, fake.createdNodeId,
                    "and the created node id must still be displayed");
        }

        // ---- the preflight --------------------------------------------------

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

        function test_an_occupied_home_blocks_identity_creation() {
            fake.identityExists = true;
            fake.identityNodeId = "did:key:z6MkOCCUPIED";
            flow.runPreflight();

            compare(flow.canCreateIdentity, false);
            verify(flow.createBlockedReason.indexOf("already exists") !== -1,
                   "the reason must state that an identity already exists, "
                   + "got: " + flow.createBlockedReason);
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

        // ---- the mode step --------------------------------------------------

        function test_only_embedded_continues_the_flow() {
            fake.mode = "local";
            flow.runPreflight();
            verify(harness.advanceTo(flow, "mode"));
            compare(flow.modeInForce, "local", "precondition");
            compare(flow.canAdvance, false,
                    "the four steps after mode are about a node no other mode "
                    + "runs");
            verify(flow.advanceBlockedReason !== "",
                   "and the refusal must be stated rather than left as a "
                   + "disabled control");

            fake.mode = "embedded";
            flow.refreshCapabilities();
            compare(flow.modeInForce, "embedded");
            compare(flow.canAdvance, true,
                    "Embedded must continue the flow");
        }

        /// The mode in force comes from capabilities, never from what the flow
        /// asked for — so a refused write leaves the mode where it was.
        function test_a_refused_mode_write_does_not_move_the_mode_in_force() {
            fake.mode = "local";
            flow.runPreflight();
            fake.settingRefusal = "unknown mode 'turbo'";

            flow.chooseMode("turbo");
            compare(flow.lastError, "unknown mode 'turbo'",
                    "the refusal must be displayed");
            compare(flow.modeInForce, "local",
                    "and the mode in force must not have moved");
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
    }
}
