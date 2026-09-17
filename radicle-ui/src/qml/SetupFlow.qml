import QtQuick

/*
 * The embedded node's guided setup, as state rather than as a screen.
 *
 * Which step is in force, what the preflight found, what each finding blocks,
 * and the calls the flow issues. `SetupWizard.qml` renders this; nothing here
 * knows about layout, and that separation is the reason the behaviour is
 * testable at all — see the file header there, and `SourceState.qml` for the
 * same split made for the same reason one milestone earlier.
 *
 * ## The step is an INDEX, and that is load-bearing
 *
 * Six steps in a fixed order, and the requirement is that advancing moves to
 * the next one and never skips. Held as an index into `steps`, that is true by
 * construction: `advance()` can only produce `stepIndex + 1`, and there is no
 * expressible value that jumps two. Held as six booleans, or as a string
 * assigned per step, every transition is its own assignment to get right and
 * "identity went straight to start" becomes a reachable state needing its own
 * test.
 *
 * `canGoBack` and the confirm-step clamp fall out of the same representation
 * rather than being two more conditions.
 *
 * ## Blocking is keyed on the FINDING, never on a step's own memory
 *
 * Each rule reads a preflight finding directly, so a backend that starts
 * reporting the finding as passing lifts the block with nothing else changed.
 * That is a requirement rather than a convenience, and it is why the findings
 * stay four separate values instead of collapsing into one `preflightPassed`.
 *
 * The collapse is the tempting mistake and it has a specific victim: a missing
 * `git` would block identity creation, which spawns no `git` at all. A user on
 * a machine without git could then not create the identity they came to create,
 * for a reason that does not apply to the thing they are doing.
 *
 * ## `exists:false` is not "the home is empty"
 *
 * `getEmbeddedIdentity()` reports `exists:false` for an empty home AND for a
 * half-created one — key material with no finished profile, which a crashed
 * `Profile::init` leaves behind. Nothing in the reply tells them apart, so this
 * flow does not pretend to: the finding says no identity exists, never that the
 * home is empty, and creation is OFFERED so that the backend's refusal — the
 * only surface that names the `keys` path to remove — is what the user sees.
 *
 * ## Why every call carries an epoch
 *
 * A reply to a request issued before the user moved must not repopulate the
 * step now in force. This repo has the same guard hand-written four slightly
 * different ways in CommitsTab, IssuesTab, PatchesTab and ThreadView, and each
 * hand-written copy dropped a different capture. Here it is one counter,
 * incremented by every step change, captured by every call, and checked in
 * every reply — so a new call inherits it rather than re-deriving it.
 */
QtObject {
    id: flow

    // ---- injected backend ------------------------------------------------
    //
    // Function properties rather than a backend object, the same injection
    // SettingsPanel uses: it is what lets a component test drive this with a
    // fake that returns input-dependent data and holds its replies, without a
    // QtRO replica anywhere in sight.

    /// getCapabilities(cb) -> cb(capsObject)
    property var fetchCapabilities: null
    /// getEmbeddedIdentity(cb) -> cb(replyObject)
    property var fetchIdentity: null
    /// getNodeStatus(cb) -> cb(replyObject)
    property var fetchNodeStatus: null
    /// listKnownSeeds(cb) -> cb({items:[…]})
    property var fetchSeeds: null
    /// createEmbeddedIdentity(alias, passphrase, cb) -> cb(replyObject)
    property var createIdentity: null
    /// startNode(passphrase, cb) -> cb(replyObject)
    property var startNode: null
    /// setSetting(key, value, cb) -> cb(settingsObject|{error})
    property var saveSetting: null

    // ---- the step in force -----------------------------------------------

    readonly property var steps: ["preflight", "mode", "identity",
                                  "network", "start", "confirm"]

    /// Which step is in force, as an index. See the header for why an index.
    property int stepIndex: 0

    readonly property string step: steps[stepIndex]

    readonly property bool canGoBack: stepIndex > 0

    // ---- the four preflight findings -------------------------------------
    //
    // Four values, not one verdict. Each is reported separately and each blocks
    // only what it actually makes impossible.

    /// Whether the preflight has finished asking. Until it has, nothing
    /// downstream should read the findings as answers — they are defaults.
    ///
    /// NO SPEC: the spec requires four findings each reported as its own
    /// outcome, but does not say what a finding shows BEFORE its probe has
    /// answered. Every finding has a legitimate falsy value, so rendering the
    /// defaults would report four failures before a single call was issued.
    /// This flow therefore names the unanswered state ("checking…") rather than
    /// letting it read as failure. Chosen, not specified.
    property bool preflightDone: false

    /// From getCapabilities().gitFound.
    property bool gitFound: false
    /// The backend's own sentence. Displayed verbatim; see `problemFor`.
    property string gitProblem: ""

    /// From getEmbeddedIdentity().exists. False covers BOTH an empty home and
    /// a half-created one — see the header.
    property bool identityExists: false
    /// The identity's DID when one exists, "" otherwise.
    property string identityNodeId: ""
    /// getEmbeddedIdentity().problem, verbatim.
    property string identityProblem: ""

    /// From getNodeStatus().serving — a node already answering on the socket.
    property bool alreadyServing: false

    /// Whether a home could be resolved to write into at all: a non-empty
    /// `home` from getEmbeddedIdentity AND an empty `pathsProblem`. Two
    /// sources because they fail differently — no home at all, versus a home
    /// whose socket path blows the 108-byte sun_path cap.
    property string embeddedHome: ""
    property string pathsProblem: ""
    readonly property bool homeResolved: embeddedHome !== "" && pathsProblem === ""

    // ---- what the backend says is in force --------------------------------
    //
    // Read from replies, never inferred from a call having been issued.

    /// getCapabilities().mode.
    property string modeInForce: ""
    /// getCapabilities().startableModes.
    property var startableModes: []
    /// getCapabilities().modeUnavailableReason.
    property string modeUnavailableReason: ""

    /// The seeds listKnownSeeds() reported.
    property var seeds: []

    /// Whether the node has been reported started, from a `started:true` reply
    /// — never from the start call having been made.
    property bool nodeStarted: false
    /// The addresses the node reports binding. EMPTY IS THE EXPECTED VALUE and
    /// is displayed as such: it is what confirms the outbound-only default.
    property var listening: []
    /// getNodeStatus().serving after a start, which is the field that notices a
    /// node whose threads have died while `running` stays true.
    property bool nodeServing: false
    /// The DID to show at confirm: whatever createEmbeddedIdentity reported,
    /// falling back to what the node reported and then to capabilities.
    property string nodeId: ""

    /// True between issuing a start and its reply. Withholds the control so a
    /// second node cannot be started over the first.
    property bool startPending: false

    /// The most recent backend refusal, verbatim. One string rather than one
    /// per step: only the step in force can have issued the call that produced
    /// it, and a success clears it.
    property string lastError: ""

    // ---- blocking ---------------------------------------------------------
    //
    // Each reads a finding. Nothing here reads "did the preflight pass".

    /// An unresolvable home has nowhere to write; an occupied one is refused by
    /// createEmbeddedIdentity regardless. A HALF-CREATED home is deliberately
    /// not blocked — see the header.
    readonly property bool canCreateIdentity:
        homeResolved && !identityExists

    /// Why creation is unavailable, or "" when it is. Stated rather than left
    /// as a disabled control with no reason.
    readonly property string createBlockedReason: {
        if (identityExists)
            return "An identity already exists in this home"
                 + (identityNodeId !== "" ? " (" + identityNodeId + ")" : "")
                 + ". Creating a second one is refused, never an overwrite.";
        if (!homeResolved)
            return problemFor(identityProblem, pathsProblem,
                              "No Radicle home could be resolved to write into.");
        return "";
    }

    /// `git` is needed to start a node and NOT to create an identity, which is
    /// why this is a separate rule rather than a shared preflight verdict.
    readonly property bool canStartNode:
        gitFound && !alreadyServing && !startPending

    readonly property string startBlockedReason: {
        if (!gitFound)
            return problemFor(gitProblem,
                              "No git executable could be resolved. Radicle "
                            + "spawns git to read and write storage, so the "
                            + "node cannot start without it.");
        if (alreadyServing)
            return "A node is already answering on the resolved socket. "
                 + "Starting a second one would contend for it.";
        return "";
    }

    /// Only Embedded continues past the mode step: the four steps after it are
    /// about a node no other mode runs. Read from capabilities rather than from
    /// what the flow asked for.
    readonly property bool modeIsEmbedded: modeInForce === "embedded"

    /// Whether advancing from the step in force is permitted.
    ///
    /// One function rather than a per-step property, because "may I advance"
    /// is one question asked at one control, and the answer differs only by
    /// which step is in force.
    readonly property bool canAdvance: {
        if (stepIndex >= steps.length - 1) return false;
        if (step === "mode") return modeIsEmbedded;
        return true;
    }

    /// Why advancing is refused, or "" when it is not.
    readonly property string advanceBlockedReason:
        (step === "mode" && !modeIsEmbedded)
            ? "Embedded is the mode the remaining steps set up. Choose it to "
            + "continue, or close this setup to stay in "
            + (modeInForce !== "" ? modeInForce : "the current mode") + "."
            : ""

    // ---- staleness --------------------------------------------------------

    /// Incremented by every step change. Captured by every call, checked by
    /// every reply. See the header.
    property int epoch: 0

    /// Whether a reply issued at `issuedAt` is still wanted.
    function isCurrent(issuedAt) {
        return issuedAt === epoch;
    }

    // ---- navigation -------------------------------------------------------

    /// Emitted when the step in force moves.
    ///
    /// **Named `stepMoved`, not `stepChanged`.** `step` is a property, so QML
    /// already generates a `stepChanged` signal for it, and declaring one by
    /// that name is a compile error — "Duplicate signal name: invalid override
    /// of property change signal". `qmlformat` parses the file happily and says
    /// nothing, so this is caught only by actually loading the type. Same
    /// family as the `on*`-prefixed property trap this repo has hit before.
    signal stepMoved()

    function advance() {
        if (!canAdvance) return false;
        stepIndex = stepIndex + 1;
        epoch = epoch + 1;
        stepMoved();
        return true;
    }

    function back() {
        if (!canGoBack) return false;
        stepIndex = stepIndex - 1;
        epoch = epoch + 1;
        stepMoved();
        return true;
    }

    // ---- the preflight ----------------------------------------------------

    /// Ask all four questions. Writes nothing: no createEmbeddedIdentity, no
    /// startNode, no setSetting is reachable from here, which is a property of
    /// this function's body rather than a promise.
    function runPreflight() {
        var issuedAt = epoch;
        preflightDone = false;

        if (fetchCapabilities) {
            fetchCapabilities(function (caps) {
                if (!isCurrent(issuedAt) || !caps) return;
                flow.gitFound = caps.gitFound === true;
                flow.gitProblem = caps.gitProblem || "";
                flow.pathsProblem = caps.pathsProblem || "";
                flow.modeInForce = caps.mode || "";
                flow.startableModes = caps.startableModes || [];
                flow.modeUnavailableReason = caps.modeUnavailableReason || "";
                if (flow.nodeId === "") flow.nodeId = caps.nodeId || "";
                flow.notePreflightAnswer();
            });
        }

        if (fetchIdentity) {
            fetchIdentity(function (reply) {
                if (!isCurrent(issuedAt) || !reply) return;
                flow.identityExists = reply.exists === true;
                flow.identityNodeId = reply.nodeId || "";
                flow.identityProblem = reply.problem || "";
                flow.embeddedHome = reply.home || "";
                if (flow.identityExists && flow.nodeId === "")
                    flow.nodeId = reply.nodeId || "";
                flow.notePreflightAnswer();
            });
        }

        if (fetchNodeStatus) {
            fetchNodeStatus(function (reply) {
                if (!isCurrent(issuedAt) || !reply) return;
                flow.alreadyServing = reply.serving === true;
                flow.notePreflightAnswer();
            });
        }

        if (fetchSeeds) {
            fetchSeeds(function (reply) {
                if (!isCurrent(issuedAt) || !reply) return;
                flow.seeds = reply.items || [];
            });
        }
    }

    /// How many of the three preflight probes have answered.
    ///
    /// Counted rather than inferred from the values themselves: every finding
    /// has a legitimate falsy value, so "gitFound is false" cannot distinguish
    /// "git is missing" from "nobody has asked yet". That distinction is the
    /// whole reason `preflightDone` exists — a UI that read the defaults as
    /// answers would report four failures before issuing a single call.
    property int preflightAnswers: 0

    function notePreflightAnswer() {
        preflightAnswers = preflightAnswers + 1;
        if (preflightAnswers >= 3) preflightDone = true;
    }

    /// The first non-empty sentence, falling back to the flow's own wording.
    ///
    /// The backend's sentences name the path that was tried and the limit that
    /// was exceeded, so they are preferred over anything written here — a
    /// generic replacement throws away the only actionable part. Variadic so a
    /// caller can offer several candidates in priority order.
    function problemFor() {
        for (var i = 0; i < arguments.length; i++) {
            var s = arguments[i];
            if (s !== undefined && s !== null && String(s) !== "")
                return String(s);
        }
        return "";
    }

    // ---- the mode step ----------------------------------------------------

    /// Persist a mode. Does NOT record the flow's own copy: `modeInForce` is
    /// refreshed from capabilities, so the flow shows what is in force rather
    /// than what it asked for. A refused write therefore leaves the step where
    /// it was, with the refusal on screen.
    function chooseMode(mode) {
        if (!saveSetting) return;
        var issuedAt = epoch;
        lastError = "";
        saveSetting("mode", mode, function (reply) {
            if (!isCurrent(issuedAt)) return;
            if (reply && reply.error) {
                flow.lastError = reply.error;
                return;
            }
            // Re-read capabilities rather than trusting the settings echo:
            // `mode` in force is capabilities' answer, and the spec requires
            // the flow keep no second opinion.
            flow.refreshCapabilities();
        });
    }

    function refreshCapabilities() {
        if (!fetchCapabilities) return;
        var issuedAt = epoch;
        fetchCapabilities(function (caps) {
            if (!isCurrent(issuedAt) || !caps) return;
            flow.modeInForce = caps.mode || "";
            flow.startableModes = caps.startableModes || [];
            flow.modeUnavailableReason = caps.modeUnavailableReason || "";
            flow.gitFound = caps.gitFound === true;
            flow.gitProblem = caps.gitProblem || "";
            flow.pathsProblem = caps.pathsProblem || "";
            if (flow.nodeId === "") flow.nodeId = caps.nodeId || "";
        });
    }

    // ---- the identity step ------------------------------------------------

    /// Create the identity, passing the alias through exactly as typed.
    ///
    /// No pre-validation of the alias, deliberately: the backend passes the
    /// `radicle` crate's own statement of the rule back as its refusal, and a
    /// second rule here would drift from it — presenting as the wizard
    /// rejecting an alias the backend would have accepted, with nothing on
    /// screen saying which layer refused.
    function submitIdentity(alias, passphrase) {
        if (!createIdentity || !canCreateIdentity) return false;
        var issuedAt = epoch;
        lastError = "";
        createIdentity(alias, passphrase, function (reply) {
            if (!isCurrent(issuedAt)) return;
            if (!reply || reply.error) {
                // The refusal is the useful result: it names the home in the
                // way, or the `keys` path to remove for a half-created home.
                flow.lastError = (reply && reply.error)
                                 ? reply.error : "identity creation failed";
                return;
            }
            flow.identityExists = reply.created === true;
            flow.identityNodeId = reply.nodeId || "";
            if (reply.nodeId) flow.nodeId = reply.nodeId;
            if (reply.home) flow.embeddedHome = reply.home;
        });
        return true;
    }

    // ---- the start step ---------------------------------------------------

    /// Start the node, reporting success only on `started:true`.
    ///
    /// The passphrase is the one the identity step took: the node is handed an
    /// already-decrypted signing key when it is built, so there is no later
    /// point at which one could be supplied.
    function submitStart(passphrase) {
        if (!startNode || !canStartNode) return false;
        var issuedAt = epoch;
        lastError = "";
        startPending = true;
        startNode(passphrase, function (reply) {
            if (!isCurrent(issuedAt)) {
                flow.startPending = false;
                return;
            }
            flow.startPending = false;
            if (!reply || reply.error) {
                flow.lastError = (reply && reply.error)
                                 ? reply.error : "the node did not start";
                flow.nodeStarted = false;
                return;
            }
            // Only a `started:true` reply counts. A reply that merely arrived
            // is not a started node.
            flow.nodeStarted = reply.started === true;
            if (!flow.nodeStarted) {
                flow.lastError = "the node did not report itself started";
                return;
            }
            flow.listening = reply.listening || [];
            if (reply.nodeId) flow.nodeId = reply.nodeId;
            // A started node is serving by the backend's own contract —
            // startNode returns only once the control socket answers — but the
            // flow still asks, because `serving` is the field that notices a
            // node whose threads die afterwards.
            flow.nodeServing = true;
            flow.refreshNodeStatus();
        });
        return true;
    }

    /// Re-read what the node is doing.
    ///
    /// Reads `serving`, not `running`: a node whose threads have died leaves
    /// `running` true indefinitely while `serving` goes false, and that is the
    /// state a user cannot otherwise account for. The Rust panic guard reaches
    /// the FFI boundary, not the threads a running node spawns.
    function refreshNodeStatus() {
        if (!fetchNodeStatus) return;
        var issuedAt = epoch;
        fetchNodeStatus(function (reply) {
            if (!isCurrent(issuedAt) || !reply) return;
            flow.nodeServing = reply.serving === true;
        });
    }

    // ---- the confirm step -------------------------------------------------

    /// The command a delegate runs elsewhere to authorise this node.
    ///
    /// Carries the DID that actually exists rather than a placeholder, so the
    /// line as displayed is the line to run. "" when there is no DID yet,
    /// which is what keeps a `--allow ` with nothing after it off the screen.
    readonly property string allowCommand:
        nodeId !== "" ? "rad id update --allow " + nodeId : ""

    // ---- reset ------------------------------------------------------------

    /// Back to the beginning, for a flow that is shown again.
    ///
    /// Bumps the epoch, so anything still in flight from the previous showing
    /// cannot land in the fresh one.
    function reset() {
        stepIndex = 0;
        epoch = epoch + 1;
        preflightDone = false;
        preflightAnswers = 0;
        gitFound = false;
        gitProblem = "";
        identityExists = false;
        identityNodeId = "";
        identityProblem = "";
        alreadyServing = false;
        embeddedHome = "";
        pathsProblem = "";
        modeInForce = "";
        startableModes = [];
        modeUnavailableReason = "";
        seeds = [];
        nodeStarted = false;
        listening = [];
        nodeServing = false;
        nodeId = "";
        startPending = false;
        lastError = "";
        stepMoved();
    }
}
