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
        function init() {
            st.pathsProblem = "";
            st.home = "/home/u/.local/share/basecamp/embedded-home";
            st.identityExists = true;
            st.running = false;
            st.serving = false;
            st.startPending = false;
            st.startError = "";
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
            verify(!st.actionEnabled,
                   "with no action that would write");

            // And back: the refusal is what is rendered once the home resolves.
            st.pathsProblem = "";
            compare(st.current, "startFailed",
                    "with the home resolving again the refusal is the obstacle");
            verify(st.sentence.indexOf("already in use") !== -1,
                   "rendered verbatim, got: " + st.sentence);
            verify(st.actionEnabled, "and the start is offered again");
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
        function test_a_blocked_home_offers_no_action_that_would_write() {
            st.pathsProblem = "the embedded home cannot be created";
            compare(st.actionKind, "",
                    "no act is offered at all");
            verify(!st.actionEnabled,
                   "and nothing is enabled to take");

            // Proven to discriminate: with the problem cleared the same fixture
            // offers a real act, so this is not true of every input.
            st.pathsProblem = "";
            verify(st.actionEnabled,
                   "control: a resolving home DOES offer an action");
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

        /// An outstanding start withholds the start control, so a second node
        /// is not started over the first — and it does so whatever the node is
        /// currently reporting, including the window where it still says
        /// `running:false` and the state is therefore `stopped`.
        function test_the_start_action_is_withheld_while_a_start_is_outstanding() {
            st.startPending = true;
            compare(st.current, "stopped",
                    "the backend's report wins over what this view awaits");
            verify(!st.actionEnabled,
                   "and the start must still be withheld");

            st.running = true;
            compare(st.current, "starting");
            verify(!st.actionEnabled,
                   "as it must once the node reports running too");

            st.startPending = false;
            verify(st.actionEnabled,
                   "control: with no start outstanding the action returns");
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
            verify(st.actionEnabled, "and the retry is offered");

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
    }
}
