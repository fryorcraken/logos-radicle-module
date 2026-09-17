import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * What only the rendered wizard can answer: the three consequences it must
 * STATE, and the copy that must actually reach the clipboard.
 *
 * ## Why this is a separate file from tst_setup_wizard.qml
 *
 * That file drives `SetupFlow`, where the ordering, blocking and staleness
 * rules live. The requirements here are about text being on screen and a
 * clipboard round trip completing — neither of which a state object can be
 * asked about, and both of which are exactly the kind of thing that quietly
 * stops being true when someone rewords a paragraph.
 *
 * ## The assertions are on SUBSTANCE, not on wording
 *
 * Each checks for the load-bearing clause rather than a whole sentence, so a
 * copy edit does not turn a gate red for no reason — but the clause chosen is
 * the one the requirement is about. "unlock" and "plaintext" are the two halves
 * of the passphrase trade; "cannot fetch" is the consequence that decides
 * whether the outbound-only default is acceptable. Asserting on the full
 * paragraph would be brittle; asserting the text is merely non-empty would pass
 * against a paragraph saying nothing of the sort.
 */
Item {
    id: harness
    width: 700
    height: 1000

    QtObject {
        id: fake

        property bool identityExists: false
        property string nodeId: ""
        property var seedItems: [
            { url: "https://seed.radicle.xyz", alias: "radicle", source: "builtin" },
            { url: "https://seed.example.org", alias: "example", source: "builtin" }
        ]

        function capabilities(cb) {
            cb({ mode: "embedded",
                 startableModes: ["explore", "local", "embedded"],
                 modeUnavailableReason: "",
                 gitFound: true, gitProblem: "", pathsProblem: "",
                 nodeId: nodeId });
        }
        function identity(cb) {
            cb({ home: "/home/u/.local/share/basecamp/radicle",
                 exists: identityExists, nodeId: nodeId, problem: "" });
        }
        function nodeStatus(cb) {
            cb({ running: false, serving: false, home: "", socket: "",
                 reason: "" });
        }
        function seeds(cb) { cb({ items: seedItems }); }
        function create(a, p, cb) {
            cb({ created: true, nodeId: "did:key:z6MkMADE", home: "",
                 alias: a, encrypted: p !== "" });
        }
        function start(p, cb) {
            cb({ started: true, home: "", socket: "",
                 nodeId: "did:key:z6MkRUNNING", listening: [] });
        }
        function setting(k, v, cb) {
            cb({ mode: v, radHome: "", radSocket: "", gitPath: "",
                 remoteSeed: "" });
        }
    }

    Ui.SetupWizard {
        id: wizard
        width: 640
        height: 900
    }

    /// Depth-first search by objectName. Needed because this repo puts the
    /// objectName on the clickable element rather than on its wrapper, so the
    /// target is rarely a direct child.
    function findByName(node, name) {
        if (!node) return null;
        if (node.objectName === name) return node;
        for (var i = 0; i < node.children.length; i++) {
            var hit = harness.findByName(node.children[i], name);
            if (hit) return hit;
        }
        return null;
    }

    function textOf(name) {
        var n = harness.findByName(wizard, name);
        return n ? String(n.text) : "";
    }

    TestCase {
        name: "SetupWizardView"
        when: windowShown

        function init() {
            fake.identityExists = false;
            fake.nodeId = "";
            wizard.flow.fetchCapabilities = function (cb) { fake.capabilities(cb); };
            wizard.flow.fetchIdentity = function (cb) { fake.identity(cb); };
            wizard.flow.fetchNodeStatus = function (cb) { fake.nodeStatus(cb); };
            wizard.flow.fetchSeeds = function (cb) { fake.seeds(cb); };
            wizard.flow.createIdentity = function (a, p, cb) { fake.create(a, p, cb); };
            wizard.flow.startNode = function (p, cb) { fake.start(p, cb); };
            wizard.flow.saveSetting = function (k, v, cb) { fake.setting(k, v, cb); };
            wizard.flow.reset();
            wizard.flow.runPreflight();
        }

        function goTo(stepName) {
            for (var i = 0; i < 10 && wizard.flow.step !== stepName; i++) {
                if (!wizard.flow.advance()) break;
            }
            compare(wizard.flow.step, stepName,
                    "precondition: the flow must reach the " + stepName
                    + " step");
        }

        // ---- unspecified behaviour, made visible ----------------------------

        /// NO SPEC: the spec does not say what a preflight finding shows before
        /// its probe has answered; this names the unanswered state rather than
        /// rendering a default as a result.
        ///
        /// It matters because every finding has a legitimate falsy value: a
        /// flow that showed the defaults would report four failures — a missing
        /// git, an unresolvable home — before issuing a single call, and a user
        /// would act on a diagnosis of nothing.
        function test_an_unanswered_finding_is_not_reported_as_a_failure() {
            wizard.flow.reset();     // back to before the preflight answered
            compare(wizard.flow.preflightDone, false, "precondition");

            var outcome = "";
            var node = harness.findByName(wizard, "findingGit");
            for (var i = 0; node && i < node.children.length; i++)
                if (node.children[i].objectName === "findingOutcome")
                    outcome = String(node.children[i].text).toLowerCase();

            verify(outcome.indexOf("checking") !== -1,
                   "an unanswered probe must be named as unanswered rather "
                   + "than rendered as a failed finding, got: " + outcome);
        }

        // ---- the mode step's identity consequence ---------------------------

        /// The separateness statement must be visible at the MODE step, before
        /// anything is created — a statement made only after the identity
        /// exists is made after the decision it informs.
        ///
        /// Asserted through the real `ModePicker`, which is where the wording
        /// lives, so a change there cannot silently remove the consequence the
        /// wizard relies on it to state.
        function test_the_mode_step_states_the_separate_identity_consequence() {
            goTo("mode");

            var picker = harness.findByName(wizard, "wizardModePicker");
            verify(picker !== null, "the mode step must offer the modes");

            var embedded = null;
            for (var i = 0; i < picker.modes.length; i++)
                if (picker.modes[i].key === "embedded")
                    embedded = picker.modes[i];
            verify(embedded !== null, "embedded must be among the modes");

            var blurb = String(embedded.blurb).toLowerCase();
            verify(blurb.indexOf("separate identity") !== -1,
                   "the embedded option must state that it is a separate "
                   + "identity, got: " + embedded.blurb);

            var localBlurb = "";
            for (var j = 0; j < picker.modes.length; j++)
                if (picker.modes[j].key === "local")
                    localBlurb = String(picker.modes[j].blurb).toLowerCase();
            verify(localBlurb.indexOf("separate identity") === -1,
                   "and the local option must NOT make that statement — it is "
                   + "the user's own identity");
        }

        // ---- the identity step's passphrase trade ---------------------------

        /// A passphrase is the ARRIVING default: leaving the control alone must
        /// produce the safer outcome.
        function test_a_passphrase_is_the_arriving_default() {
            goTo("identity");
            var sw = harness.findByName(wizard, "identityPassphraseSwitch");
            verify(sw !== null, "the passphrase control must be present");
            compare(sw.checked, true,
                    "the control must arrive in the state that sets a "
                    + "passphrase");
        }

        /// **Both halves of the trade, before the control is touched.** One
        /// half alone is a recommendation the user cannot weigh.
        function test_both_halves_of_the_trade_are_stated_before_the_choice() {
            goTo("identity");
            var trade = harness.textOf("passphraseTrade").toLowerCase();

            verify(trade.indexOf("unlock") !== -1,
                   "the cost half — an unlock every time the node starts — "
                   + "must be stated, got: " + trade);
            verify(trade.indexOf("plaintext") !== -1,
                   "the benefit half — an unencrypted key is a secret in "
                   + "plaintext — must be stated, got: " + trade);
        }

        /// And the statement STAYS when the passphrase is turned off, which is
        /// the moment the user most needs to see what they gave up.
        function test_the_trade_stays_stated_when_the_passphrase_is_turned_off() {
            goTo("identity");
            var sw = harness.findByName(wizard, "identityPassphraseSwitch");
            sw.checked = false;

            var node = harness.findByName(wizard, "passphraseTrade");
            verify(node !== null && node.visible,
                   "the trade must still be on screen with the passphrase off");

            var trade = String(node.text).toLowerCase();
            verify(trade.indexOf("unlock") !== -1
                   && trade.indexOf("plaintext") !== -1,
                   "and must still state both halves, got: " + trade);
        }

        // ---- the network step -----------------------------------------------

        /// The default AND its consequence. "No listen address" alone does not
        /// let a user derive "another machine cannot clone from this one", and
        /// the second sentence is the one that decides whether the default is
        /// acceptable to them.
        function test_the_outbound_only_default_and_its_consequence_are_stated() {
            goTo("network");
            var t = harness.textOf("networkInbound").toLowerCase();

            verify(t.indexOf("no inbound") !== -1,
                   "the step must state that the node accepts no inbound "
                   + "connections, got: " + t);
            verify(t.indexOf("cannot fetch from this node") !== -1,
                   "and must state the consequence — peers cannot fetch from "
                   + "this node, got: " + t);
        }

        /// No inbound control, and the absence STATED rather than left looking
        /// like an oversight.
        function test_no_inbound_control_is_offered_and_the_absence_is_stated() {
            goTo("network");

            compare(harness.findByName(wizard, "networkInboundToggle"), null,
                    "no control enabling inbound connections must be present: "
                    + "nothing persists a listen address, so it would record "
                    + "nothing");

            var t = harness.textOf("networkInboundUnavailable").toLowerCase();
            verify(t.indexOf("not available") !== -1,
                   "the absence must be stated, got: " + t);
        }

        /// **The reported seeds are the ones offered**, and a different reply
        /// yields a different list — so this cannot pass against a hardcoded
        /// one.
        function test_the_reported_seeds_are_the_ones_offered() {
            goTo("network");
            var rep = harness.findByName(wizard, "networkSeeds");
            verify(rep !== null, "the seed list must be present");
            compare(rep.count, 2, "both reported seeds must be offered");

            fake.seedItems = [
                { url: "https://only.example", alias: "only", source: "builtin" }
            ];
            wizard.flow.runPreflight();
            compare(rep.count, 1,
                    "exactly the seeds the reply named must be offered — a "
                    + "count that did not move would mean the list is not read "
                    + "from listKnownSeeds at all");
        }

        // ---- the start step -------------------------------------------------

        /// An empty `listening` is DISPLAYED, not omitted: it is the state that
        /// confirms the outbound-only default.
        function test_an_empty_listening_list_is_displayed_rather_than_omitted() {
            goTo("start");
            wizard.flow.submitStart("");
            compare(wizard.flow.nodeStarted, true, "precondition: it started");

            var node = harness.findByName(wizard, "startListening");
            verify(node !== null && node.visible,
                   "the listening state must be on screen");
            var t = String(node.text).toLowerCase();
            verify(t.indexOf("no address") !== -1,
                   "an empty listening list must be stated as listening on no "
                   + "address, got: " + t);
        }

        // ---- the confirm step -----------------------------------------------

        function test_the_confirm_step_restates_the_consequence_with_its_effect() {
            goTo("confirm");
            var t = harness.textOf("confirmSeparateIdentity").toLowerCase();

            verify(t.indexOf("new identity") !== -1,
                   "the confirm step must state that this is a new identity, "
                   + "got: " + t);
            verify(t.indexOf("delegate authorises") !== -1
                   || t.indexOf("delegate authorizes") !== -1,
                   "and that a private repository reaches this node only once "
                   + "a delegate authorises this DID, got: " + t);
        }

        /// **Copying puts the allow line on the clipboard**, verified by
        /// reading the clipboard back rather than by trusting that `copy()`
        /// was called. `TextEdit.copy()` reports failure through no channel, so
        /// the call having been made proves nothing.
        function test_copying_puts_the_allow_line_on_the_clipboard() {
            goTo("identity");
            wizard.flow.submitIdentity("tester", "");
            goTo("confirm");

            var cmd = harness.findByName(wizard, "confirmAllowCommand");
            verify(cmd !== null, "the allow line must be present");
            verify(cmd.command.indexOf("did:key:z6MkMADE") !== -1,
                   "carrying the created DID, got: " + cmd.command);

            cmd.clearConfirmation();
            var copied = cmd.copyToClipboard();
            verify(copied,
                   "the copy must be reported only after the clipboard was "
                   + "verified to hold the line");
            verify(cmd.clipboardHolds(cmd.command),
                   "the clipboard must actually hold the allow line");
        }

        /// The negative control for the assertion above: `clipboardHolds` must
        /// be able to say NO. Without this, a verifier stuck at true would make
        /// the copy test pass while proving nothing — the same shape as a fake
        /// returning identical data for every input.
        function test_the_clipboard_check_can_fail() {
            goTo("confirm");
            var cmd = harness.findByName(wizard, "confirmAllowCommand");
            verify(cmd !== null);

            cmd.copyToClipboard();
            verify(!cmd.clipboardHolds("something that was never copied"),
                   "clipboardHolds must return false for text the clipboard "
                   + "does not hold, or the copy assertion proves nothing");
        }

        // ---- the refusal surface --------------------------------------------

        /// A refusal is rendered where a user can see it, not merely held in
        /// the state object.
        function test_a_refusal_is_rendered() {
            goTo("identity");
            wizard.flow.createIdentity = function (a, p, cb) {
                cb({ error: "a distinctive rendered refusal" });
            };
            wizard.flow.submitIdentity("tester", "");

            var box = harness.findByName(wizard, "wizardError");
            verify(box !== null && box.visible,
                   "the refusal must be on screen");
            compare(harness.textOf("wizardErrorText"),
                    "a distinctive rendered refusal",
                    "shown as the backend worded it");
        }
    }
}
