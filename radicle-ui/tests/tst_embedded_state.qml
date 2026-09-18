import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * The seven Embedded states, derived from what the backend reports.
 *
 * ## Why this is a state test and not a view test
 *
 * Every rule here is a question about VALUES — which state, which sentence,
 * which action, whether there is a node to ask — so it is asked of the
 * `QtObject` directly. `tst_embedded_panel.qml` covers the other half: that the
 * panel actually renders what this decides, and that `RepoList` fetches or
 * declines accordingly. A state that derives correctly and never renders is the
 * blank pane this whole capability exists to remove, so both halves are needed.
 *
 * ## The fixture is the inputs, and they are all independent
 *
 * There is no fake here to answer the same thing for every input: the inputs ARE
 * the test, each set explicitly. What the input-dependence rule buys instead is
 * that every assertion below moves ONE field and reads a DIFFERENT answer out —
 * so a derivation stuck on a constant fails, where a single-scenario assertion
 * would not notice.
 */
Item {
    id: root
    width: 400
    height: 300

    Ui.EmbeddedState { id: st }

    TestCase {
        name: "EmbeddedStateDerivation"
        when: windowShown

        /// A workable home with an identity and a stopped node — the baseline
        /// every test departs from by moving one field.
        ///
        /// **Hosted-ness is part of the baseline, and it is what this module
        /// actually hosts**: the requests that open the setup and start the node
        /// both reach `Main.qml`; the request that RESTARTS one reaches nobody,
        /// because a restart is two calls whose refusals are different sentences
        /// and nothing sequences the pair. Tests about the hosted-ness rule
        /// itself move these.
        ///
        /// **`encrypted:true` is the baseline deliberately**, although an
        /// unencrypted key is the commoner case. It is the value that makes the
        /// stopped state INERT — no start is issued, nothing is asked for — so
        /// every test below departs from a state that does nothing by itself,
        /// and the tests that are about starting by itself arm it explicitly.
        /// The opposite baseline would have every unrelated test silently
        /// sitting in a state that wants a start.
        function init() {
            st.pathsProblem = "";
            st.home = "/home/u/.local/share/basecamp/embedded-home";
            st.identityExists = true;
            st.encrypted = true;
            st.running = false;
            st.serving = false;
            st.startPending = false;
            st.startError = "";
            st.startSucceeded = false;
            st.setupHosted = true;
            st.startHosted = false;
            st.restartHosted = false;
        }

        // ---- the ordering -------------------------------------------------

        /// **The table is read top to bottom and the first match wins**, which
        /// is only observable where two conditions hold at once. Each leg below
        /// holds a LOWER condition true throughout and moves a HIGHER one, so a
        /// derivation that ordered them the other way answers differently.
        function test_the_most_fundamental_obstacle_is_the_one_rendered() {
            // A refusal recorded, and a stopped node, so `startFailed` holds.
            st.startError = "the node control socket is already in use";
            compare(st.current, "startFailed", "precondition");

            // Now the home stops resolving. `startFailed` is still true.
            st.pathsProblem = "the node control socket path is too long: 131 "
                            + "bytes exceeds the 108-byte cap";
            compare(st.current, "blocked",
                    "a start refused in a home that cannot be written to must "
                    + "render the home problem, not the refusal — retrying a "
                    + "start that cannot succeed is what the ordering prevents");
            verify(st.sentence.indexOf("108-byte cap") !== -1,
                   "and the pathsProblem sentence verbatim, got: " + st.sentence);
            compare(st.actionKind, "",
                    "with no action NAMED at all — a blocked home offers "
                    + "nothing that would write, because nothing could succeed");
            verify(!st.actionEnabled,
                   "and so nothing enabled either");

            // And back: the refusal is what is rendered once the home resolves.
            st.pathsProblem = "";
            compare(st.current, "startFailed",
                    "with the home resolving again the refusal is the obstacle");
            verify(st.sentence.indexOf("already in use") !== -1,
                   "rendered verbatim, got: " + st.sentence);
            // NAMED, not enabled. The start action reaches no host in this
            // version — see `init()` — so the requirement here is that the
            // ordering put a startable obstacle back in force, which is what
            // `actionKind` reports. Asserting `actionEnabled` would be asserting
            // the hosting rule in a test about the ordering, and would now be
            // false for a reason this test is not about.
            compare(st.actionKind, "start",
                    "and the start is the act named again");
        }

        /// `blocked` has two causes that fail differently, and both must reach
        /// it: no home at all, and a home whose socket path is unusable.
        function test_a_home_that_does_not_resolve_is_blocked_either_way() {
            st.home = "";
            compare(st.current, "blocked", "an empty home has nowhere to write");

            st.home = "/some/home";
            st.pathsProblem = "socket path exceeds the cap";
            compare(st.current, "blocked",
                    "and so does a home whose socket path is unusable");

            st.pathsProblem = "";
            compare(st.current, "stopped",
                    "with both resolved it is the node's state that decides");
        }

        /// `noIdentity` sits above every node state, because a node cannot be
        /// running in a home that holds no identity — and if the backend says
        /// otherwise, the identity is the thing to fix.
        function test_no_identity_outranks_every_node_state() {
            st.identityExists = false;
            st.running = true;
            st.serving = true;
            compare(st.current, "noIdentity",
                    "a home with no identity is that, whatever a node reports");

            st.identityExists = true;
            compare(st.current, "runningEmpty",
                    "and with one, the node's own report decides");
        }

        // ---- the states differ, one from another --------------------------

        /// **Each state carries its own sentence and its own action.** The
        /// assertion that matters is that they DIFFER: one banner with one
        /// button would satisfy "a sentence is rendered" in every state.
        function test_each_state_says_something_different() {
            var seen = {};
            var order = [];

            function record(name) {
                compare(st.current, name, "precondition for " + name);
                verify(st.sentence !== "", name + " must say something");
                verify(seen[st.sentence] === undefined,
                       name + " repeats the sentence already used by "
                       + seen[st.sentence] + ": " + st.sentence);
                seen[st.sentence] = name;
                order.push(name + "/" + st.actionKind);
            }

            st.pathsProblem = "nowhere to write";
            record("blocked");

            st.pathsProblem = "";
            st.identityExists = false;
            record("noIdentity");

            st.identityExists = true;
            record("stopped");

            st.running = true;
            st.startPending = true;
            record("starting");

            st.startPending = false;
            st.startError = "wrong passphrase";
            record("startFailed");

            st.startError = "";
            record("notServing");

            st.serving = true;
            record("runningEmpty");

            compare(order.join(" "),
                    "blocked/ noIdentity/setup stopped/start starting/ "
                    + "startFailed/start notServing/restart runningEmpty/",
                    "each state's action must be its own");
        }

        /// A stopped node and a home with no identity offer DIFFERENT next
        /// acts: one opens the setup, the other starts the node. A shared
        /// "Fix it" would pass a test that only asked whether an action existed.
        function test_a_stopped_node_and_no_identity_are_different_states() {
            st.identityExists = false;
            compare(st.actionKind, "setup",
                    "a home with no identity offers the guided setup");
            var noIdentitySentence = st.sentence;

            st.identityExists = true;
            compare(st.actionKind, "start",
                    "a stopped node offers a start");
            verify(st.sentence !== noIdentitySentence,
                   "and says something different: " + st.sentence);
        }

        /// A blocked home offers NOTHING that would write, because nothing
        /// could succeed. Both the setup and the start must be unreachable.
        ///
        /// **The control leg moves to the no-identity state, and that is the
        /// restrengthening.** It used to clear `pathsProblem` and leave the
        /// stopped node in place, asserting `actionEnabled` — which was a real
        /// check while every named action was enabled, and became one nothing
        /// could fail the moment start stopped being hosted: a derivation
        /// returning `false` for every input would have passed both halves. The
        /// setup action IS hosted, so `exists:false` restores a leg that
        /// genuinely discriminates.
        function test_a_blocked_home_offers_no_action_that_would_write() {
            st.pathsProblem = "the embedded home cannot be created";
            compare(st.actionKind, "",
                    "no act is offered at all");
            verify(!st.actionEnabled,
                   "and nothing is enabled to take");

            st.pathsProblem = "";
            st.identityExists = false;
            compare(st.actionKind, "setup",
                    "control: a resolving home names an act");
            verify(st.actionEnabled,
                   "control: and a HOSTED act is enabled, so this assertion is "
                   + "not one that holds for every input");
        }

        /// **A blocked home claims no unavailability either.** The note is about
        /// an act that is named but unreachable; a blocked home names no act at
        /// all, so the sentence "starting the node is not yet available from
        /// here" would be answering a question nobody asked — and pointing at a
        /// passphrase when the real obstacle is that the home does not resolve.
        ///
        /// This is the term review found unguarded: dropping `actionKind !== ""`
        /// from `actionUnavailableNote` reddened nothing before this test
        /// existed, because every other test that reaches the note has an act
        /// named. The control leg is what makes it discriminate — the note DOES
        /// appear for a named-but-unhosted act.
        function test_a_blocked_home_claims_no_unavailability() {
            st.pathsProblem = "the embedded home cannot be created";
            compare(st.actionKind, "", "precondition: no act is named");
            compare(st.actionUnavailableNote, "",
                    "a blocked home must not claim that STARTING is what is "
                    + "unavailable: no act is offered, and the obstacle is the "
                    + "home rather than the passphrase");

            // Control: a named act that nothing hosts DOES state its
            // unavailability, so this is not satisfied by a note that is always
            // empty.
            st.pathsProblem = "";
            st.identityExists = true;
            st.running = false;
            st.serving = false;
            st.startHosted = false;
            compare(st.actionKind, "start",
                    "control: an act is named");
            verify(st.actionUnavailableNote !== "",
                   "control: a named but unhosted act states why it cannot be "
                   + "taken");
        }

        // ---- starting versus not serving ----------------------------------

        /// **The same two reported fields render two different states.** A
        /// `getNodeStatus()` poll taken during startup reports `running:true`
        /// with `serving:false`, which is exactly what a node whose threads have
        /// died reports. Only `startPending` separates them, and only the view
        /// holds it.
        function test_the_same_reported_fields_render_two_states() {
            st.running = true;
            st.serving = false;

            st.startPending = true;
            compare(st.current, "starting");
            var startingSentence = st.sentence;
            verify(startingSentence.toLowerCase().indexOf("starting") !== -1,
                   "starting must say so, got: " + startingSentence);

            st.startPending = false;
            compare(st.current, "notServing");
            verify(st.sentence !== startingSentence,
                   "and the two must differ");
            verify(st.sentence.indexOf("stopped answering") !== -1,
                   "not serving must say the node has stopped answering, got: "
                   + st.sentence);
            verify(st.sentence.indexOf("still loaded") !== -1,
                   "and that it is still loaded, got: " + st.sentence);
        }

        /// A node that has stopped serving is reported as NEITHER running nor
        /// stopped. Both are false in a way the user pays for — one sends them
        /// hunting a network fault, the other invites a start that will refuse.
        function test_a_non_serving_node_reads_as_neither_running_nor_stopped() {
            st.running = true;
            st.serving = false;
            var notServing = st.sentence;

            st.serving = true;
            verify(st.sentence !== notServing,
                   "a serving node must not read the same as one that has "
                   + "stopped serving");

            st.running = false;
            st.serving = false;
            verify(st.sentence !== notServing,
                   "and neither must a stopped one");
        }

        /// The offered act restarts rather than starts, because a bare start
        /// would be refused: the runtime is still loaded and still holds the
        /// socket.
        function test_the_offered_action_restarts_rather_than_starts() {
            st.running = true;
            st.serving = false;
            compare(st.actionKind, "restart");

            st.running = false;
            compare(st.actionKind, "start",
                    "a genuinely stopped node offers a plain start");
        }

        /// An outstanding start withholds the start action, so a second node is
        /// not started over the first.
        ///
        /// Asserted on the act NAMED, because that is the spec's scenario and
        /// because it holds "independently of whether that action can be carried
        /// out at all" — it is a property of the state, and it must already be
        /// true on the day a surface able to start a node exists.
        function test_no_action_is_named_while_a_start_is_outstanding() {
            st.startPending = true;
            compare(st.current, "stopped",
                    "the backend's report wins over what this view awaits");

            st.running = true;
            compare(st.current, "starting");
            compare(st.actionKind, "",
                    "the starting state names no act, so a second node cannot "
                    + "be started over the first");

            st.startError = "the passphrase did not unlock the key";
            st.startPending = false;
            compare(st.actionKind, "start",
                    "control: answered, the act is named again");
        }

        /// **The `!startPending` term in `actionEnabled`, proven.**
        ///
        /// A separate test because it needs `startHosted` armed: with start
        /// unhosted every start action is disabled anyway, so deleting the term
        /// would redden nothing and the guard would be unprotected. Arming the
        /// flag makes the term the only thing withholding the control — which is
        /// the state this module will be in the day the settings surface hosts
        /// a start, and is exactly when the guard has to still be there.
        ///
        /// The `stopped` leg is the one a state-folded version would fail:
        /// `startPending` is read directly rather than through `current`, so the
        /// control is withheld in the window where the node still reports
        /// `running:false` as well as once it reports `running:true`.
        function test_an_outstanding_start_withholds_a_hosted_start_control() {
            st.startHosted = true;
            // An encrypted key, so `stopped` names a start rather than being
            // the state this surface starts by itself — the control is the
            // subject here, and the unencrypted state deliberately has none.
            st.encrypted = true;

            st.startPending = true;
            compare(st.current, "stopped",
                    "precondition: the backend has not caught up yet");
            verify(!st.actionEnabled,
                   "a hosted start must still be withheld in the stopped window");

            st.running = true;
            compare(st.current, "starting");
            verify(!st.actionEnabled,
                   "as it must once the node reports running too");

            // The control leg goes back to `stopped` rather than clearing
            // `startPending` where it stands: with `running:true` that would be
            // `notServing`, whose act is a RESTART and is deliberately unhosted,
            // so the assertion would fail for a reason this test is not about.
            st.running = false;
            st.startPending = false;
            compare(st.current, "stopped", "control precondition");
            verify(st.actionEnabled,
                   "control: with no start outstanding a HOSTED action returns");
        }

        // ---- refusals ------------------------------------------------------

        /// **A refusal is displayed as the backend worded it.** The module's
        /// refusals name the socket in use, the passphrase that did not unlock
        /// the key and the home in the way; a summary drops each of those. Two
        /// different refusals must produce two different sentences, and the
        /// first must be gone.
        function test_two_refusals_display_two_different_messages() {
            st.startError = "the passphrase did not unlock keys/radicle";
            compare(st.current, "startFailed");
            compare(st.sentence, st.startError,
                    "displayed verbatim, not summarised");
            // The act is NAMED, so the state does not read as terminal. It is
            // not enabled — no surface can carry out a start yet — and the
            // requirement is about the naming, which is what stops a refusal
            // rendering as a dead end.
            compare(st.actionKind, "start", "and the retry is named");

            st.startError = "another node is bound to /run/u/radicle/control";
            compare(st.sentence, st.startError,
                    "the second refusal must be what is shown");
            verify(st.sentence.indexOf("passphrase") === -1,
                   "and the first must be gone: " + st.sentence);
        }

        /// A success clears the displayed refusal. Held as the reply's own
        /// value, so this is the backend answering rather than the view
        /// forgetting.
        function test_a_success_clears_a_displayed_refusal() {
            st.startError = "the passphrase did not unlock keys/radicle";
            compare(st.current, "startFailed", "precondition");

            // A successful start: the refusal is cleared by the reply, and the
            // node reports itself serving.
            st.startError = "";
            st.running = true;
            st.serving = true;

            compare(st.current, "runningEmpty");
            verify(st.sentence.indexOf("passphrase") === -1,
                   "no refusal may remain on screen: " + st.sentence);
        }

        /// A refused start is rendered as neither a running node nor as
        /// `starting`.
        function test_a_refused_start_is_neither_running_nor_starting() {
            st.startError = "refused";
            verify(st.current !== "starting",
                   "a refusal is not a start in progress");
            verify(st.current !== "runningEmpty" && st.current !== "notServing",
                   "nor a node that is loaded, got: " + st.current);
        }

        // ---- which states have a node to ask ------------------------------

        /// **The fetch guard, at the layer that decides it.** Four states have
        /// no node to ask; three do. `startFailed` is in the first group for the
        /// same reason `stopped` is — a start that was refused left no node
        /// loaded.
        function test_which_states_have_a_node_to_ask() {
            var answers = [];

            function ask(label) {
                answers.push(label + ":" + (st.hasNodeToAsk ? "yes" : "no"));
            }

            st.pathsProblem = "nowhere";
            ask("blocked");

            st.pathsProblem = "";
            st.identityExists = false;
            ask("noIdentity");

            st.identityExists = true;
            ask("stopped");

            st.startError = "refused";
            ask("startFailed");

            st.startError = "";
            st.running = true;
            st.startPending = true;
            ask("starting");

            st.startPending = false;
            ask("notServing");

            st.serving = true;
            ask("runningEmpty");

            compare(answers.join(" "),
                    "blocked:no noIdentity:no stopped:no startFailed:no "
                    + "starting:yes notServing:yes runningEmpty:yes",
                    "a node that is loaded can be asked; one that does not "
                    + "exist cannot. A node that has stopped SERVING still "
                    + "answers reads, because reads never touch the daemon");
        }

        /// **The guard is not keyed on startability.** There is no startable set
        /// in this component at all — which is what makes that structural rather
        /// than a claim: `embedded` is startable, so a guard reading a startable
        /// set would answer `yes` for every row above.
        function test_the_state_follows_a_later_reply_rather_than_the_first() {
            compare(st.current, "stopped", "precondition");

            st.running = true;
            st.serving = true;
            compare(st.current, "runningEmpty",
                    "a later reply must move the state");

            st.running = false;
            st.serving = false;
            compare(st.current, "stopped",
                    "and move it back — a stored state would not, which is why "
                    + "nothing here stores one");
        }

        // ---- only an action something can carry out is enabled ------------

        /// **An unhosted action is named but not enabled, and says why.**
        ///
        /// The two halves are a single requirement: naming without enabling is
        /// what keeps the state from reading as one with nothing to say, and the
        /// sentence is what keeps the disabled control from reading as a module
        /// that is merely broken.
        ///
        /// The second leg is the discriminator. Both states are asked the same
        /// three questions and answer differently in each, so a derivation
        /// stuck on either answer fails.
        function test_an_unhosted_action_is_named_but_not_enabled_and_says_so() {
            // stopped: the act is a start, which reaches nobody.
            compare(st.current, "stopped", "precondition");
            compare(st.actionKind, "start", "the act must still be NAMED");
            verify(!st.actionEnabled, "but it must not be enabled");
            verify(st.actionUnavailableNote.indexOf("not yet available from here")
                   !== -1,
                   "and must say starting is not yet available from here, got: "
                   + st.actionUnavailableNote);
            // Neither of the two other things it could have said. A user told a
            // start FAILED goes looking for a cause that does not exist; one
            // told the node CANNOT be started stops looking for the command
            // line and for the settings surface that will host this.
            verify(st.actionUnavailableNote.indexOf("failed") === -1,
                   "never that a start failed — none was attempted: "
                   + st.actionUnavailableNote);
            verify(st.actionUnavailableNote.indexOf("cannot be started") === -1,
                   "nor that the node cannot be started at all: "
                   + st.actionUnavailableNote);

            // noIdentity: the act is the setup, which does reach a host.
            st.identityExists = false;
            compare(st.actionKind, "setup");
            verify(st.actionEnabled, "a hosted act must be enabled");
            compare(st.actionUnavailableNote, "",
                    "and must say nothing about being unavailable");
        }

        /// **Hosting is what enables it**, with nothing else changed.
        ///
        /// One field moves and the answer moves with it, which is what makes
        /// "keyed on whether the request is hosted" a property of the derivation
        /// rather than a claim. A component hard-coding which states are enabled
        /// would answer identically for both halves.
        function test_hosting_an_action_is_what_enables_it() {
            compare(st.current, "stopped", "precondition");
            compare(st.startHosted, false,
                    "precondition: the start request reaches nobody");
            verify(!st.actionEnabled, "so the named action is not enabled");

            st.startHosted = true;
            verify(st.actionEnabled,
                   "and hosting it enables it, with nothing else changed");
            compare(st.actionUnavailableNote, "",
                    "and the unavailability sentence goes with it");
        }

        /// The note is silent while a start is outstanding: the action is then
        /// withheld because this view is waiting for a reply, which the
        /// `starting` sentence already says. "Not yet available" over it would
        /// be false — and would be the one wording a user could not act on.
        function test_no_unavailability_is_claimed_while_a_start_is_outstanding() {
            st.running = true;
            st.startPending = true;
            compare(st.current, "starting", "precondition");
            compare(st.actionUnavailableNote, "",
                    "a state that is waiting is not a state that is unhosted");

            st.startPending = false;
            compare(st.current, "notServing");
            verify(st.actionUnavailableNote !== "",
                   "control: with nothing outstanding the unhosted restart does "
                   + "explain itself");
        }

        // ---- starting by itself, or asking for a passphrase ----------------

        /// **A stopped node with an unencrypted key wants its start issued**,
        /// with no action taken by the user.
        ///
        /// `wantsAutoStart` is the DECISION, held here where it is a question
        /// about values; `RepoList` owns the issuing. Splitting them is what
        /// makes "started by itself" assertable without a backend — see
        /// `tst_embedded_panel.qml` for the other half, which proves exactly one
        /// call goes out.
        ///
        /// The discriminator is `encrypted`, moved with EVERYTHING ELSE HELD:
        /// the same node status must answer differently, or the derivation could
        /// be reading the node's state and calling it an answer about the key.
        function test_an_unencrypted_stopped_node_wants_a_start() {
            st.encrypted = false;
            compare(st.current, "stopped", "precondition");
            verify(st.wantsAutoStart,
                   "an unencrypted key can be started with no secret, so the "
                   + "module presses the control the user would have pressed");

            st.encrypted = true;
            verify(!st.wantsAutoStart,
                   "and an encrypted one cannot: there is no passphrase to "
                   + "start it with, and the same node status must answer "
                   + "differently on this field alone");
        }

        /// The autostart happens in `stopped` and NOWHERE ELSE.
        ///
        /// Each row is reached with `encrypted:false` — the value that would
        /// make an over-eager derivation say yes — so a `wantsAutoStart` keyed
        /// on the key alone answers `yes` for every one of them.
        function test_no_autostart_outside_the_stopped_state() {
            st.encrypted = false;
            var answers = [];

            function ask(label) {
                answers.push(label + ":" + (st.wantsAutoStart ? "yes" : "no"));
            }

            st.pathsProblem = "nowhere to write";
            ask("blocked");

            st.pathsProblem = "";
            st.identityExists = false;
            ask("noIdentity");

            st.identityExists = true;
            ask("stopped");

            st.startPending = true;
            st.running = true;
            ask("starting");

            st.startPending = false;
            st.startError = "the node control socket is already in use";
            ask("startFailed");

            st.startError = "";
            ask("notServing");

            st.serving = true;
            ask("runningEmpty");

            compare(answers.join(" "),
                    "blocked:no noIdentity:no stopped:yes starting:no "
                    + "startFailed:no notServing:no runningEmpty:no",
                    "in blocked and noIdentity there is nothing to start; in "
                    + "notServing the runtime is still loaded and a bare start "
                    + "would be refused; in startFailed a start has already "
                    + "been tried and answered, and retrying unasked would loop "
                    + "against a backend that refuses every time");
        }

        /// **A stopped node with an ENCRYPTED key asks, rather than starting.**
        ///
        /// The prompt is a property of the identity's own nature, so it is
        /// derived from `encrypted` and not from a start having failed — which
        /// would make it a consequence of an error rather than of the key.
        function test_an_encrypted_stopped_node_asks_for_its_passphrase() {
            st.encrypted = true;
            compare(st.current, "stopped", "precondition");
            verify(st.wantsPassphrase,
                   "an encrypted key must be asked for");
            verify(!st.wantsAutoStart,
                   "and must not be started unasked, because there is no "
                   + "passphrase to start it with");

            st.encrypted = false;
            verify(!st.wantsPassphrase,
                   "an unencrypted one has nothing to ask for");
        }

        /// The prompt is not a consequence of a failed start.
        ///
        /// Both legs hold `encrypted` fixed and move the refusal, so a
        /// derivation reading `startError` answers differently in one of them.
        function test_the_passphrase_prompt_does_not_follow_a_failed_start() {
            st.encrypted = false;
            st.startError = "the node did not start";
            compare(st.current, "startFailed", "precondition");
            verify(!st.wantsPassphrase,
                   "a failed start on an UNENCRYPTED key asks for nothing — "
                   + "the prompt follows the identity, not the error");

            st.encrypted = true;
            verify(st.wantsPassphrase,
                   "while an encrypted key is asked for even here, so a retry "
                   + "can carry a corrected passphrase");
        }

        // ---- a node this module started is not one in the way --------------

        /// **The defect the setup flow shipped, at the layer that decides it.**
        ///
        /// Step 5 rendered an amber "a node is already answering on the resolved
        /// socket" directly above its own green "Running as did:key:…". Both
        /// were derived from true readings; together they described a conflict
        /// that did not exist, because the node warned about was the one the
        /// module had just started.
        ///
        /// The two are told apart by whether a `startNode` THIS SURFACE issued
        /// was answered with a success — the one fact the node status cannot
        /// carry, since it reports the same fields either way. Both legs below
        /// report `serving:true`; only `startSucceeded` differs.
        function test_a_node_this_surface_started_is_not_reported_as_contention() {
            st.encrypted = false;
            st.startSucceeded = true;
            st.running = true;
            st.serving = true;

            compare(st.current, "runningEmpty", "precondition");
            verify(!st.foundForeignNode,
                   "a node this surface started is the outcome the user wanted, "
                   + "not something in the way");
            verify(st.sentence.indexOf("already answering") === -1,
                   "so nothing may say a node is already answering: "
                   + st.sentence);
            verify(st.sentence.indexOf("contend") === -1,
                   "nor that starting a second would contend for the socket: "
                   + st.sentence);
        }

        /// A node the surface did NOT start is still reported as found, because
        /// that one genuinely is somebody else's and a start against it will be
        /// refused.
        function test_a_node_the_surface_did_not_start_is_still_reported() {
            st.encrypted = true;
            st.startSucceeded = false;
            st.running = true;
            st.serving = true;

            verify(st.foundForeignNode,
                   "with no start ever issued by this surface, a serving node "
                   + "is somebody else's");
            verify(st.sentence.indexOf("already answering") !== -1,
                   "and must be reported as such, got: " + st.sentence);

            st.startSucceeded = true;
            verify(!st.foundForeignNode,
                   "control: the identical node status reads differently once "
                   + "this surface's own start succeeded — which is the fact "
                   + "the status cannot carry");
        }

        // ---- start is hosted; restart is not -------------------------------

        /// **Start and restart are hosted SEPARATELY**, and that split is the
        /// change. They shared one flag while both were unhosted for one shared
        /// reason — neither could ask for a passphrase. That reason is gone for
        /// start: `encrypted` says whether one is needed, and this surface asks.
        /// It survives for restart, which is two calls whose refusals are
        /// different sentences and which nothing here sequences.
        ///
        /// One flag would now make hosting start silently enable a restart that
        /// reaches nobody — the dead-end this capability exists to remove.
        function test_start_and_restart_are_hosted_independently() {
            st.startHosted = true;
            st.restartHosted = false;

            st.encrypted = true;
            compare(st.current, "stopped", "precondition");
            compare(st.actionKind, "start");
            verify(st.actionEnabled,
                   "a hosted start is enabled");

            st.running = true;
            compare(st.current, "notServing", "precondition");
            compare(st.actionKind, "restart");
            verify(!st.actionEnabled,
                   "while an unhosted restart is not — one flag for both would "
                   + "have enabled it here");
            verify(st.actionUnavailableNote.indexOf("not yet available from here")
                   !== -1,
                   "and it says why, got: " + st.actionUnavailableNote);

            st.restartHosted = true;
            verify(st.actionEnabled,
                   "control: hosting the restart is what enables it, with "
                   + "nothing else changed");
        }

        /// The restart note names RESTARTING rather than starting, now that the
        /// two are different questions with different answers.
        function test_the_unavailable_note_names_the_act_that_is_unavailable() {
            st.startHosted = true;
            st.restartHosted = false;
            st.running = true;
            compare(st.current, "notServing", "precondition");
            verify(st.actionUnavailableNote.toLowerCase().indexOf("restart")
                   !== -1,
                   "the note must name restarting, which is the act that is "
                   + "unavailable, got: " + st.actionUnavailableNote);
            verify(st.actionUnavailableNote.indexOf("failed") === -1,
                   "never that it failed — none was attempted: "
                   + st.actionUnavailableNote);
            verify(st.actionUnavailableNote.indexOf("cannot be restarted") === -1,
                   "nor that the node cannot be restarted at all: "
                   + st.actionUnavailableNote);
        }
    }
}
