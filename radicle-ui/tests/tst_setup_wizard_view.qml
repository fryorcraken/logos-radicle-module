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

        /// The mode `getCapabilities()` reports. Settable so a test can put the
        /// flow in `local` and watch the embedded step's control move it —
        /// the default is `embedded` so the other steps' tests can walk past it.
        property string mode: "embedded"

        /// Reported as startable throughout, and deliberately all three: this
        /// is the scenario the wizard shipped wrong, and the requirement is
        /// that the embedded step offers nothing extra whatever it says.
        property var startableModes: ["explore", "local", "embedded"]

        property var seedItems: [
            { url: "https://seed.radicle.xyz", alias: "radicle", source: "builtin" },
            { url: "https://seed.example.org", alias: "example", source: "builtin" }
        ]

        function capabilities(cb) {
            cb({ mode: mode,
                 startableModes: startableModes,
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

    /// Every visible string the scene graph holds, concatenated.
    ///
    /// Needed for the requirements phrased as an ABSENCE — "no text MUST be
    /// displayed stating that a mode cannot be started". An objectName check
    /// cannot express that: it catches the caption coming back as
    /// `modeUnavailable_*`, and misses a hand-written second copy of the same
    /// sentence under any other name. Walking for the string catches both.
    ///
    /// It is also what makes "what is displayed MUST be unchanged" assertable
    /// between two startable sets, which is the scenario's own wording.
    ///
    /// `visible` is checked per node rather than only on the leaf, because a
    /// Text inside a hidden Column reports `visible` false — Qt propagates it
    /// — but a Text inside a StackLayout's non-current child does too, which is
    /// what keeps the other five steps out of this.
    function visibleTextUnder(node) {
        if (!node || node.visible === false) return "";
        var out = (node.text !== undefined && String(node.text) !== "")
                  ? String(node.text) + "\n" : "";
        for (var i = 0; i < node.children.length; i++)
            out += harness.visibleTextUnder(node.children[i]);
        return out;
    }

    /// The outcome line a named `Finding` renders — the text a user reads,
    /// not the property it was computed from. Findings are an inline component
    /// whose two `Text` children share one objectName each, so this walks to
    /// the outcome rather than the label.
    function outcomeOf(findingName) {
        var node = harness.findByName(wizard, findingName);
        for (var i = 0; node && i < node.children.length; i++)
            if (node.children[i].objectName === "findingOutcome")
                return String(node.children[i].text);
        return "";
    }

    TestCase {
        name: "SetupWizardView"
        when: windowShown

        function init() {
            fake.identityExists = false;
            fake.nodeId = "";
            fake.mode = "embedded";
            fake.startableModes = ["explore", "local", "embedded"];
            fake.seedItems = [
                { url: "https://seed.radicle.xyz", alias: "radicle",
                  source: "builtin" },
                { url: "https://seed.example.org", alias: "example",
                  source: "builtin" }
            ];
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

        /// **A neutral finding still shows a backend sentence.** The spec
        /// requires that where the backend supplied one — `gitProblem`,
        /// `pathsProblem` or `getEmbeddedIdentity().problem` — it is displayed
        /// verbatim. The identity finding is rendered `neutral` because "no
        /// identity yet" is not a failure, and an outcome expression that read
        /// `neutral || ok ? okText : failText` made its `failText` permanently
        /// unreachable — swallowing a real diagnostic such as a permissions
        /// error reading the identity store.
        ///
        /// The second half is what stops this passing against a finding that
        /// shows `failText` unconditionally: with no problem sentence, the
        /// ordinary "no identity exists here yet" wording must still be what
        /// is shown.
        function test_a_neutral_finding_still_shows_a_backend_problem() {
            var sentence = "cannot read the identity store: permission denied";
            wizard.flow.reset();
            wizard.flow.fetchIdentity = function (cb) {
                cb({ home: "/home/u/.local/share/basecamp/radicle",
                     exists: false, nodeId: "", problem: sentence });
            };
            wizard.flow.runPreflight();
            compare(wizard.flow.preflightDone, true, "precondition");
            compare(wizard.flow.identityProblem, sentence,
                    "precondition: the flow holds the backend's sentence");

            var shown = harness.outcomeOf("findingIdentity");
            compare(shown, sentence,
                    "a backend sentence must be displayed verbatim rather than "
                    + "swallowed by the finding's neutral styling");

            // Without a problem sentence the ordinary wording is what shows —
            // so the assertion above cannot pass against a finding stuck on
            // failText.
            wizard.flow.reset();
            wizard.flow.fetchIdentity = function (cb) { fake.identity(cb); };
            wizard.flow.runPreflight();
            var ordinary = harness.outcomeOf("findingIdentity").toLowerCase();
            verify(ordinary.indexOf("no identity exists") !== -1,
                   "an empty home with no problem must still read as no "
                   + "identity yet, got: " + ordinary);
        }

        // ---- the embedded step ----------------------------------------------

        /// **The separateness statement is asserted AS RENDERED.** This is the
        /// lesson kept from the version of this test that read
        /// `ModePicker.modes[i].blurb`: the data array a row is built from
        /// stays correct however the row is drawn, so review proved the gap by
        /// blanking the rendered `Text` to `""` and watching every view test —
        /// including that one — stay green. A statement the spec requires the
        /// user to SEE had no gate that could notice it vanishing.
        ///
        /// So this walks the scene graph to the `Text` and reads `text` off it.
        /// Deleting the `Text`, setting `visible: false` or blanking its string
        /// all redden this.
        ///
        /// It is the repo's "a fake returning the same thing for every input"
        /// lesson in a second form: an assertion read off the INPUT rather than
        /// the output cannot distinguish "rendered" from "never rendered".
        function test_the_embedded_step_states_the_separate_identity_consequence() {
            goTo("embedded");

            var node = harness.findByName(wizard, "embeddedExplains");
            verify(node !== null && node.visible,
                   "the statement must be on screen");

            var t = String(node.text).toLowerCase();
            verify(t.indexOf("runs the node itself") !== -1
                   || t.indexOf("runs the node") !== -1,
                   "the step must state that this module runs a node of its "
                   + "own, got: " + node.text);
            verify(t.indexOf("new identity") !== -1,
                   "and that the node operates as a new identity, got: "
                   + node.text);
            verify(t.indexOf("separate from any radicle node you already run")
                   !== -1,
                   "separate from any node the user already runs, got: "
                   + node.text);
        }

        /// The statement precedes any identity write: it is on screen at the
        /// embedded step, and `createEmbeddedIdentity` has not been called.
        function test_the_separateness_statement_precedes_any_identity_write() {
            var created = 0;
            wizard.flow.createIdentity = function (a, p, cb) {
                created = created + 1;
                fake.create(a, p, cb);
            };

            goTo("embedded");
            var node = harness.findByName(wizard, "embeddedExplains");
            verify(node !== null && node.visible,
                   "the statement must be visible at this step");
            compare(created, 0,
                    "and no identity must have been created by the time it is "
                    + "stated");
        }

        /// **No other mode is offered, whatever the startable set reports.**
        /// The fake reports all three as startable throughout, which is the
        /// scenario the wizard actually shipped wrong: a `ModePicker` offering
        /// Explore, Local and Embedded, each captioned "This version cannot
        /// start this mode yet".
        ///
        /// The picker's objectNames are the ones asserted absent because they
        /// are what the wizard used to render — `wizardModePicker` reappearing
        /// is precisely the regression, and `modeUnavailable_*` reappearing is
        /// the caption. The generic sentence is checked against the whole
        /// step's rendered text as well, so a hand-written second copy of the
        /// caption would be caught too.
        function test_no_other_mode_is_offered_whatever_the_startable_set_says() {
            goTo("embedded");

            compare(harness.findByName(wizard, "wizardModePicker"), null,
                    "the step must not present the modes as a set to pick from");
            compare(harness.findByName(wizard, "modePick_explore"), null,
                    "no control selecting explore must be present");
            compare(harness.findByName(wizard, "modePick_local"), null,
                    "no control selecting local must be present");
            compare(harness.findByName(wizard, "modeUnavailable_embedded"),
                    null,
                    "and no mode must be annotated as unstartable");

            var shown = harness.visibleTextUnder(wizard).toLowerCase();
            verify(shown.indexOf("cannot start this mode") === -1,
                   "no text stating a mode cannot be started, got: " + shown);

            // The same step told a startable set of `embedded` alone must show
            // exactly the same thing — without this the assertions above could
            // pass against a step that reads the array and happens to caption
            // nothing for this particular value.
            var withAll = harness.visibleTextUnder(wizard);
            wizard.flow.fetchCapabilities = function (cb) {
                cb({ mode: "embedded", startableModes: ["embedded"],
                     modeUnavailableReason: "", gitFound: true,
                     gitProblem: "", pathsProblem: "", nodeId: fake.nodeId });
            };
            wizard.flow.refreshCapabilities();
            compare(harness.visibleTextUnder(wizard), withAll,
                    "what is displayed must be unchanged by the startable set");
        }

        /// **The control is what puts Embedded in force**, and arriving does
        /// not. Driven through the rendered Button rather than through the flow
        /// function, because the requirement is that the step OFFERS a control
        /// the user performs.
        function test_the_rendered_control_puts_embedded_in_force() {
            var writes = [];
            wizard.flow.saveSetting = function (k, v, cb) {
                writes.push(k + "=" + v);
                fake.mode = v;
                fake.setting(k, v, cb);
            };
            fake.mode = "local";
            wizard.flow.reset();
            wizard.flow.runPreflight();

            goTo("embedded");
            compare(writes.length, 0,
                    "arriving at the step must write nothing, got: "
                    + JSON.stringify(writes));

            var btn = harness.findByName(wizard, "embeddedConfirm");
            verify(btn !== null && btn.visible,
                   "the step must offer a control that puts Embedded in force");
            compare(btn.enabled, true,
                    "which must be enabled while Embedded is not in force");

            btn.clicked();
            compare(writes.length, 1, "exactly one write, got: "
                    + JSON.stringify(writes));
            compare(writes[0], "mode=embedded");
            compare(wizard.flow.modeInForce, "embedded");
            compare(btn.enabled, false,
                    "and the control must not be re-offered once the backend "
                    + "reports Embedded in force");

            // The statement stays displayed either way — the step is not
            // finished with saying what Embedded means once it is chosen.
            var node = harness.findByName(wizard, "embeddedExplains");
            verify(node !== null && node.visible
                   && String(node.text).toLowerCase()
                          .indexOf("new identity") !== -1,
                   "the new-identity statement must stay on screen");
        }

        // ---- the identity step's passphrase trade ---------------------------

        /// A passphrase is the ARRIVING default: leaving the control alone must
        /// produce the safer outcome.
        ///
        /// **Pinned to the no-identity state explicitly**, rather than relying
        /// on the fixture's default. The passphrase choice now exists only in
        /// that state — an existing key's encryption was decided when it was
        /// created and is not this flow's to change — so a test that did not say
        /// which state it was asserting about would silently start asserting
        /// about a control that is correctly absent.
        function test_a_passphrase_is_the_arriving_default() {
            fake.identityExists = false;
            wizard.flow.reset();
            wizard.flow.runPreflight();
            goTo("identity");
            compare(wizard.flow.identityState, "none", "precondition");

            var sw = harness.findByName(wizard, "identityPassphraseSwitch");
            verify(sw !== null, "the passphrase control must be present");
            compare(sw.checked, true,
                    "the control must arrive in the state that sets a "
                    + "passphrase");
        }

        /// **An identity that already exists offers no passphrase choice.**
        /// Its key was sealed, or not, when it was created; stating a trade the
        /// user can no longer make describes a decision that is not theirs.
        ///
        /// The second half is what makes the first discriminate: with no
        /// identity the control must be there. Without it, a step that never
        /// rendered the switch at all would pass.
        function test_an_existing_identity_offers_no_passphrase_choice() {
            fake.identityExists = true;
            fake.nodeId = "did:key:z6MkWASHERE";
            wizard.flow.reset();
            wizard.flow.runPreflight();
            goTo("identity");
            compare(wizard.flow.identityState, "present", "precondition");

            var sw = harness.findByName(wizard, "identityPassphraseSwitch");
            verify(sw === null || !sw.visible,
                   "no control choosing whether to set a passphrase must be "
                   + "present where the choice no longer exists");
            var trade = harness.findByName(wizard, "passphraseTrade");
            verify(trade === null || !trade.visible,
                   "nor the statement of a trade the user cannot make");

            fake.identityExists = false;
            fake.nodeId = "";
            wizard.flow.reset();
            wizard.flow.runPreflight();
            goTo("identity");
            var sw2 = harness.findByName(wizard, "identityPassphraseSwitch");
            verify(sw2 !== null && sw2.visible,
                   "and it MUST be present where the choice does exist");
        }

        // ---- the identity step's one control, three states and home ---------

        /// **One forward control, and only one.** The defect this replaces was
        /// "Create identity" beside "Next" — two ways out of a step with one
        /// act, one of which could leave it with the work undone.
        ///
        /// Driven through the rendered Button rather than the flow function,
        /// because the requirement is about what the step OFFERS.
        function test_the_identity_step_offers_exactly_one_forward_control() {
            goTo("identity");

            var next = harness.findByName(wizard, "wizardNext");
            verify(next === null || !next.visible,
                   "the generic Next must not be a second way forward on a "
                   + "step whose forward control is its own");

            var btn = harness.findByName(wizard, "identityForward");
            verify(btn !== null && btn.visible,
                   "the step must offer its forward control");
            compare(btn.enabled, true, "enabled, with a resolvable home");

            btn.clicked();
            compare(wizard.flow.step, "network",
                    "one click must both create and leave the step");
            compare(wizard.flow.identityState, "created",
                    "having created the identity");

            // And the generic Next is back on the step after it — so the
            // absence above is keyed on the step rather than being a deletion.
            var nextAgain = harness.findByName(wizard, "wizardNext");
            verify(nextAgain !== null && nextAgain.visible,
                   "the generic Next must still serve the other steps");
        }

        /// **The control's rendered label names the act it will perform.**
        /// Asserted off the Button's own `text`, not off the flow property it
        /// binds to: a label read from the input cannot distinguish "rendered"
        /// from "never rendered", which is this repo's standing lesson.
        function test_the_rendered_label_names_the_act() {
            goTo("identity");
            var btn = harness.findByName(wizard, "identityForward");
            var withNone = String(btn.text).toLowerCase();
            verify(withNone.indexOf("create") !== -1,
                   "with no identity the button must name creating one, got: "
                   + btn.text);

            fake.identityExists = true;
            fake.nodeId = "did:key:z6MkWASHERE";
            wizard.flow.reset();
            wizard.flow.runPreflight();
            goTo("identity");
            var withOne = String(btn.text).toLowerCase();
            verify(withOne.indexOf("create") === -1,
                   "with one already there it must NOT, got: " + btn.text);
            verify(withOne.indexOf("continue") !== -1,
                   "and must name continuing, got: " + btn.text);
        }

        /// **The three states render differently**, and the second and third
        /// are never the same rendering. A user who already holds an identity
        /// has succeeded at this step; telling them creation was refused
        /// describes an attempt nobody made.
        ///
        /// Asserted on what is VISIBLE, walked from the scene graph, because
        /// "these two states look the same" is a statement about the screen.
        function test_the_identity_step_renders_its_three_states_apart() {
            goTo("identity");
            verify(harness.findByName(wizard, "identityCreated") === null
                   || !harness.findByName(wizard, "identityCreated").visible,
                   "with no identity, nothing may claim one was created");
            verify(harness.findByName(wizard, "identityAlreadyThere") === null
                   || !harness.findByName(wizard,
                                          "identityAlreadyThere").visible,
                   "nor that one was already there");

            harness.findByName(wizard, "identityForward").clicked();
            wizard.flow.back();
            compare(wizard.flow.step, "identity");

            var made = harness.findByName(wizard, "identityCreated");
            verify(made !== null && made.visible,
                   "an identity this showing created must be reported as "
                   + "created");
            verify(String(made.text).indexOf("did:key:z6MkMADE") !== -1,
                   "carrying its node id, got: " + made.text);
            var there = harness.findByName(wizard, "identityAlreadyThere");
            verify(there === null || !there.visible,
                   "and must NOT also be reported as having been already there");

            // A fresh showing over a backend that already holds one.
            fake.identityExists = true;
            fake.nodeId = "did:key:z6MkWASHERE";
            wizard.flow.reset();
            wizard.flow.runPreflight();
            goTo("identity");

            var there2 = harness.findByName(wizard, "identityAlreadyThere");
            verify(there2 !== null && there2.visible,
                   "an identity found on arrival must be reported as already "
                   + "present");
            verify(String(there2.text).indexOf("did:key:z6MkWASHERE") !== -1,
                   "carrying its node id, got: " + there2.text);
            var made2 = harness.findByName(wizard, "identityCreated");
            verify(made2 === null || !made2.visible,
                   "and must NOT be reported as created by this showing — the "
                   + "two states must not render the same way");
        }

        /// **An identity already there is not rendered as a failure**, and in
        /// particular the refusal surface stays empty: it is reserved for a
        /// refusal the backend returned to this showing.
        function test_an_identity_already_there_renders_no_refusal() {
            fake.identityExists = true;
            fake.nodeId = "did:key:z6MkWASHERE";
            wizard.flow.reset();
            wizard.flow.runPreflight();
            goTo("identity");

            var box = harness.findByName(wizard, "wizardError");
            verify(box === null || !box.visible,
                   "no refusal box for an attempt nobody made");
            var blocked = harness.findByName(wizard, "identityBlocked");
            verify(blocked === null || !blocked.visible,
                   "and no statement that creating one is refused");

            var shown = harness.visibleTextUnder(wizard).toLowerCase();
            verify(shown.indexOf("refused, never an overwrite") === -1,
                   "the sentence that read as a failure must be gone, got: "
                   + shown);
        }

        /// **Created and refused are never on screen together.**
        function test_created_and_refused_are_never_on_screen_together() {
            goTo("identity");
            harness.findByName(wizard, "identityForward").clicked();
            wizard.flow.back();

            var made = harness.findByName(wizard, "identityCreated");
            verify(made !== null && made.visible, "precondition: created");
            var box = harness.findByName(wizard, "wizardError");
            verify(box === null || !box.visible,
                   "a created identity must not be shown beside a refusal");
            var blocked = harness.findByName(wizard, "identityBlocked");
            verify(blocked === null || !blocked.visible,
                   "nor beside a statement that creating one is refused");
        }

        /// **The home the step writes to is displayed**, and it is the one the
        /// backend reported — so a step told a different home shows a different
        /// path. A DID says nothing about where the identity lives, and the
        /// embedded home is derived from the Basecamp profile's data directory,
        /// so it is not a path a user can guess.
        function test_the_reported_home_is_the_path_displayed() {
            var first = "/home/u/.local/share/basecamp/radicle";
            goTo("identity");
            var node = harness.findByName(wizard, "identityHome");
            verify(node !== null && node.visible,
                   "the home must be on screen");
            verify(String(node.text).indexOf(first) !== -1,
                   "showing the reported path, got: " + node.text);

            var second = "/var/lib/other/profile/radicle-home";
            wizard.flow.reset();
            wizard.flow.fetchIdentity = function (cb) {
                cb({ home: second, exists: false, nodeId: "", problem: "" });
            };
            wizard.flow.runPreflight();
            goTo("identity");
            verify(String(node.text).indexOf(second) !== -1,
                   "a different reported home must display differently, got: "
                   + node.text);
            verify(String(node.text).indexOf(first) === -1,
                   "and the first must be gone, got: " + node.text);
        }

        /// **The home is stated in all three states**, because "which home is
        /// this" is the same question before and after creation.
        function test_the_home_is_stated_in_all_three_states() {
            var home = "/home/u/.local/share/basecamp/radicle";
            goTo("identity");
            var node = harness.findByName(wizard, "identityHome");
            compare(wizard.flow.identityState, "none", "precondition");
            verify(node.visible && String(node.text).indexOf(home) !== -1,
                   "state 1, got: " + node.text);

            harness.findByName(wizard, "identityForward").clicked();
            wizard.flow.back();
            compare(wizard.flow.identityState, "created", "precondition");
            verify(node.visible && String(node.text).indexOf(home) !== -1,
                   "state 2, got: " + node.text);

            fake.identityExists = true;
            fake.nodeId = "did:key:z6MkWASHERE";
            wizard.flow.reset();
            wizard.flow.runPreflight();
            goTo("identity");
            compare(wizard.flow.identityState, "present", "precondition");
            verify(node.visible && String(node.text).indexOf(home) !== -1,
                   "state 3, got: " + node.text);
        }

        /// **An unresolvable home is STATED rather than rendered as an empty
        /// path**, with the backend's own sentence — which names what was tried
        /// — shown with it.
        function test_an_unresolvable_home_is_stated_not_shown_empty() {
            var sentence = "the profile data dir exceeds the 108-byte cap";
            wizard.flow.reset();
            wizard.flow.fetchIdentity = function (cb) {
                cb({ home: "", exists: false, nodeId: "", problem: sentence });
            };
            wizard.flow.runPreflight();
            wizard.flow.stepIndex = wizard.flow.steps.indexOf("identity");

            var node = harness.findByName(wizard, "identityHome");
            verify(node !== null && node.visible,
                   "the step must still say something about the home");
            var t = String(node.text);
            verify(t.toLowerCase().indexOf("no radicle home") !== -1,
                   "stating that none could be resolved, got: " + t);
            verify(t.indexOf(sentence) !== -1,
                   "with the backend's own sentence, got: " + t);
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

        /// **The passphrase does not outlive the calls that consume it.**
        ///
        /// `passphraseField` lives in a `StackLayout` child, and a StackLayout
        /// instantiates every child eagerly — nothing is destroyed when the
        /// step changes. So a plaintext passphrase left in `text` stays
        /// resident for the rest of the wizard's life, readable through the QML
        /// inspector that this repo's dev Basecamp ships with compiled in.
        ///
        /// Both consumers have run by the time the start step reports a started
        /// node: `createEmbeddedIdentity` at identity, `startNode` at start.
        /// That is the moment there is nothing left to hold it for.
        function test_the_passphrase_does_not_outlive_the_calls_that_use_it() {
            goTo("identity");
            var field = harness.findByName(wizard, "identityPassphrase");
            verify(field !== null, "the passphrase control must be present");

            field.text = "correct horse battery";
            wizard.flow.submitIdentity("tester", wizard.passphrase);
            compare(wizard.flow.identityExists, true,
                    "precondition: the identity was created");

            goTo("start");
            // Read it back before the start call, so this test proves the
            // clearing happens at start rather than that the field was never
            // filled.
            compare(String(field.text), "correct horse battery",
                    "precondition: the start step still has the passphrase to "
                    + "hand to startNode");

            wizard.flow.submitStart(wizard.passphrase);
            compare(wizard.flow.nodeStarted, true,
                    "precondition: the node started");

            compare(String(field.text), "",
                    "the plaintext passphrase must not stay resident once both "
                    + "calls that need it have been made");
        }

        /// **A passphrase does not outlive the showing it was typed into.**
        ///
        /// The clearing above is keyed on `nodeStarted`, which covers only the
        /// showing that runs to completion. This is the abandoned one: the user
        /// types a passphrase, creates the identity — which consumes it once —
        /// and then closes the wizard WITHOUT starting the node. `SetupWizard`
        /// is a single instance the host toggles `visible` on, never destroyed,
        /// and `SetupFlow.reset()` cannot reach a `TextField` that lives in the
        /// view. So without a clear at `show()`, the next showing resumes at the
        /// start step holding the earlier session's plaintext passphrase and
        /// hands it to `startNode()` with no re-entry by the user.
        ///
        /// Asserted on the field rather than on `wizard.passphrase`, because
        /// the property is a live binding through `passphraseSwitch.checked` —
        /// reading "" from it would also be true of a switch merely toggled off,
        /// while the secret stayed resident in `text` for the inspector to read.
        function test_a_passphrase_does_not_outlive_an_abandoned_showing() {
            wizard.show();
            goTo("identity");
            var field = harness.findByName(wizard, "identityPassphrase");
            verify(field !== null, "the passphrase control must be present");

            field.text = "correct horse battery";
            wizard.flow.submitIdentity("tester", wizard.passphrase);
            compare(wizard.flow.identityExists, true,
                    "precondition: the identity was created");
            compare(String(field.text), "correct horse battery",
                    "precondition: creating an identity does not itself clear "
                    + "the field — the start step still needs it");

            // The abandonment: the host lowers the wizard without a start
            // having been made. `nodeStarted` is still false, so the existing
            // clearing has not run.
            compare(wizard.flow.nodeStarted, false,
                    "precondition: this showing is abandoned before any start");

            // A later showing. `identityExists` is now true, so the flow
            // resumes past identity — at the very step whose control would
            // hand the passphrase to startNode().
            fake.identityExists = true;
            wizard.show();
            compare(wizard.flow.step, "start",
                    "precondition: the reopened flow resumes at the start step");

            compare(String(field.text), "",
                    "a passphrase typed in an abandoned showing must not be "
                    + "carried into a later one and resubmitted as if freshly "
                    + "entered");
        }

        /// The other half of the same rule: clearing per showing must NOT break
        /// the retry a refused start depends on. `submitStart` failing leaves
        /// the user on the start step within ONE showing, and the passphrase
        /// they typed has to survive that — which is why the clear is at
        /// `show()` and not in the start button's `onClicked`.
        function test_a_refused_start_keeps_the_passphrase_for_the_retry() {
            wizard.show();
            goTo("identity");
            var field = harness.findByName(wizard, "identityPassphrase");
            field.text = "correct horse battery";
            wizard.flow.submitIdentity("tester", wizard.passphrase);

            goTo("start");
            wizard.flow.startNode = function (p, cb) {
                cb({ error: "the key could not be unlocked" });
            };
            wizard.flow.submitStart(wizard.passphrase);
            compare(wizard.flow.nodeStarted, false,
                    "precondition: the start was refused");

            compare(String(field.text), "correct horse battery",
                    "a refusal must leave the passphrase in place, so the retry "
                    + "does not make the user retype it");
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
