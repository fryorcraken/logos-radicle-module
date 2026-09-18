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
    /// setSetting(key, value, cb) -> cb(settingsObject|{error})
    property var saveSetting: null

    // **No `startNode` here, and its absence is the requirement.** This flow
    // sets a node up and then ends; starting is the Embedded surface's, every
    // time the mode is opened. Not holding the function is what makes "the
    // setup MUST NOT issue startNode, in any step, for any reason" a property
    // of this object rather than of what the screen happens to draw — there is
    // nothing here to call.

    // ---- the step in force -----------------------------------------------

    /// **Four steps, and it was six.** Start and confirm are gone, and neither
    /// became a step of anything else:
    ///
    ///  - **Start** moved to the Embedded surface (`embedded-state`), because
    ///    starting is not something done once at setup time. It is what the mode
    ///    does whenever it is opened, for the life of the mode, so a flow a user
    ///    walks once is the wrong shape for it. The screen it left behind was
    ///    also wrong in its own right: it rendered an amber "a node is already
    ///    answering on the resolved socket" above its own green "Running as
    ///    did:key:…", warning about the node it had just started.
    ///  - **Confirm** was deleted. Its DID is in the header, where it is wanted
    ///    at arbitrary later moments and mostly when this flow is long closed;
    ///    its allow-is-not-enough sentence went to the embedded step, which is
    ///    now the only place the flow states the separateness; and what remained
    ///    was a screen whose only act was to be dismissed.
    readonly property var steps: ["preflight", "embedded", "identity",
                                  "network"]

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

    /// Whether the identity that exists was created by a `createEmbeddedIdentity`
    /// call made from THIS showing.
    ///
    /// Set only by that call's reply, cleared by `reset()`. It is the one fact
    /// in this flow that a backend reply cannot supply: `getEmbeddedIdentity()`
    /// reports that an identity exists and says nothing about who made it, and
    /// "this showing made it" is a fact about this showing.
    ///
    /// Held as a separate flag rather than as a third value of `identityExists`
    /// because the two answer different questions — "is there one" gates the
    /// creation call, "did we make it" decides what is reported — and folding
    /// them would put a display concern inside the gate.
    property bool identityCreatedHere: false

    /// Which of the identity step's THREE states is in force.
    ///
    /// `"none"` | `"created"` | `"present"`, derived rather than assigned. One
    /// string rather than two booleans the view reads separately, because the
    /// spec's hard requirement is that "created" and "already there" are never
    /// rendered the same way and that "created" and "refused" are never on
    /// screen together — and a single value with three cases makes rendering two
    /// of them at once unrepresentable rather than merely discouraged. That is
    /// the defect the user photographed: a green "Created: <DID>" above an amber
    /// "an identity already exists … creating a second is refused".
    readonly property string identityState:
        !identityExists ? "none" : (identityCreatedHere ? "created" : "present")

    /// Whether a node is answering on the resolved socket, from
    /// getNodeStatus().serving.
    ///
    /// **A finding now, and nothing more.** It used to gate the start step, and
    /// was written by every reading of the node's state so a node this flow
    /// started would withdraw its own start control. With no start step there is
    /// nothing for it to gate: this flow starts nothing, so a socket in use
    /// stops none of its work. It is still REPORTED, because it tells the user
    /// something else is using the socket this node would want.
    ///
    /// That is also why the contention sentence went with the step. Rendered
    /// here it could only ever describe a node somebody else started — this flow
    /// cannot start one — but it was the wording that, on the start step,
    /// warned about the node the wizard had just started. The surface that can
    /// tell those apart is the one that does the starting; see
    /// `EmbeddedState.foundForeignNode`.
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
    ///
    /// **`startableModes` and `modeUnavailableReason` are deliberately NOT held
    /// here.** This flow sets up one mode, so it has no unstartable alternative
    /// to caption, and the spec forbids it annotating one whatever that array
    /// reports. Not reading the array is what makes that structural rather than
    /// a rendering choice: there is no value here to caption FROM, so a future
    /// edit cannot reintroduce the annotation without first reintroducing the
    /// property. The array remains the header toggle's and the settings panel's
    /// business — see `ModePicker.qml`, which still consumes it and still must.
    property string modeInForce: ""

    /// The seeds listKnownSeeds() reported.
    property var seeds: []

    /// The most recent backend refusal, verbatim. One string rather than one
    /// per step: only the step in force can have issued the call that produced
    /// it, and a success clears it.
    property string lastError: ""

    // ---- blocking ---------------------------------------------------------
    //
    // Each reads a finding. Nothing here reads "did the preflight pass".

    /// Whether the CREATION CALL may be issued.
    ///
    /// An unresolvable home has nowhere to write; an occupied one is refused by
    /// createEmbeddedIdentity regardless. A HALF-CREATED home is deliberately
    /// not blocked — see the header.
    ///
    /// **This is not the forward control's gate**, and keeping the two apart is
    /// the whole shape of the identity step. `canAdvanceIdentity` below is what
    /// the control reads. The spec splits them because the two blocks it names
    /// block different things: an unresolvable home blocks the STEP (there is no
    /// identity and no way to make one), while an occupied home blocks only the
    /// CALL (the step's work is already done, so the control advances). Collapsed
    /// into one property, an occupied home would strand the user on a step whose
    /// only act is complete.
    readonly property bool canCreateIdentity:
        homeResolved && !identityExists

    /// Whether the identity step's ONE forward control is offered.
    ///
    /// Either there is an identity — the step's work is done, so the control
    /// advances — or creation is possible. When neither holds, the control can
    /// neither create nor advance past work that was not done, so it is withheld
    /// and `createBlockedReason` says why.
    readonly property bool canAdvanceIdentity:
        identityExists || canCreateIdentity

    /// What the forward control will DO, as the label must say.
    ///
    /// Derived rather than chosen by the view, so "the label names the act" is a
    /// property of the state the act is decided from. A label naming creation on
    /// a step that will only advance states an act that will not happen, which
    /// the spec calls the same defect as a control that does the wrong thing.
    readonly property string identityActionLabel:
        identityExists ? "Continue" : "Create identity and continue"

    /// Why creation is unavailable, or "" when it is.
    ///
    /// Note what is NOT in here any more: an identity that already exists. That
    /// sentence was factually correct and read as a failure to a user who had
    /// simply already done this — it explained an attempt nobody made. The
    /// "already there" state is now reported by the step as the success it is
    /// (`identityState === "present"`), and this string is reserved for the one
    /// case that genuinely blocks: nowhere to write.
    readonly property string createBlockedReason: {
        if (identityExists) return "";
        if (!homeResolved)
            return problemFor(identityProblem, pathsProblem,
                              "No Radicle home could be resolved to write into.");
        return "";
    }

    // **No `canStartNode` and no `startBlockedReason`.** Both were the start
    // step's, and neither has anything left to gate: a missing `git` makes the
    // NODE unable to fetch, which is reported as a finding and blocks nothing
    // here, and a node already on the socket stops none of this flow's work.
    //
    // Removing them rather than leaving them unread is what stops the start
    // step growing back: a step that wanted to gate on either would have to
    // reintroduce the property first, which is a visible act.

    /// Only Embedded continues past the embedded step: the two steps after it
    /// are about a node no other mode runs. Read from capabilities rather than
    /// from what the flow asked for.
    readonly property bool modeIsEmbedded: modeInForce === "embedded"

    /// Whether the embedded step offers its confirm control.
    ///
    /// Withheld once Embedded is in force, because the backend has already
    /// answered the question the control asks. Unlike identity creation and
    /// node start this is idempotent, so withholding it is about not asking
    /// twice rather than about preventing a second act — which is why the
    /// STATEMENT of what Embedded means stays on screen either way.
    readonly property bool canConfirmEmbedded: !modeIsEmbedded

    /// Whether advancing from the step in force is permitted.
    ///
    /// One function rather than a per-step property, because "may I advance"
    /// is one question asked at one control, and the answer differs only by
    /// which step is in force.
    readonly property bool canAdvance: {
        if (stepIndex >= steps.length - 1) return false;
        if (step === "embedded") return modeIsEmbedded;
        return true;
    }

    /// Whether the step in force is the last one, whose forward control ENDS
    /// the setup rather than moving to a further step.
    ///
    /// Derived from the index rather than from naming `network`, so the last
    /// step is whatever `steps` ends with. That matters because this list has
    /// just lost two entries: a rule naming the step would have gone on naming
    /// `confirm` and the flow would have had no way out at all.
    ///
    /// The setup deliberately has no terminal screen whose only act is to be
    /// dismissed. A step that states what already happened and offers one
    /// control that closes it asks the user for an act that changes nothing —
    /// and the facts such a screen would carry are each better placed where they
    /// are wanted: the DID in the header, the node's state on the surface the
    /// user returns to.
    readonly property bool onLastStep: stepIndex === steps.length - 1

    /// Why advancing is refused, or "" when it is not.
    ///
    /// Note what this does NOT say: it does not offer an alternative. A user
    /// who does not want Embedded leaves through the control that closes the
    /// flow, which every step offers — the flow sets up one mode and has no
    /// second answer to give.
    readonly property string advanceBlockedReason:
        (step === "embedded" && !modeIsEmbedded)
            ? "Embedded is not yet in force. Confirm it to continue, or close "
            + "this setup to stay in "
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

    /// Ask the backend everything the preflight needs. Writes nothing: no
    /// createEmbeddedIdentity, no startNode, no setSetting is reachable from
    /// here, which is a property of this function's body rather than a promise.
    ///
    /// ## Three counts that are deliberately not the same number
    ///
    /// This function issues **four calls**; the preflight reports **four
    /// findings**; and **three answers** make `preflightDone` true. None of
    /// those fours is the other four, and the three is not a subset of either:
    ///
    ///  - the four calls are `getCapabilities`, `getEmbeddedIdentity`,
    ///    `getNodeStatus` and `listKnownSeeds`;
    ///  - the four findings are git, identity, node socket and home — and the
    ///    home finding has no call of its own, because it is derived from
    ///    `pathsProblem` (capabilities) and `home` (identity);
    ///  - `listKnownSeeds` populates the network step's seed list, which is not
    ///    a finding and gates nothing, so it is the one call that does NOT mark
    ///    an answer. Three gating calls, therefore, not four.
    ///
    /// Which of the three has answered is tracked as three named booleans
    /// rather than a counter compared against a literal, so adding or removing
    /// a probe cannot leave a threshold behind to be updated separately.
    function runPreflight() {
        var issuedAt = epoch;
        preflightDone = false;
        capabilitiesAnswered = false;
        identityAnswered = false;
        nodeStatusAnswered = false;

        if (fetchCapabilities) {
            fetchCapabilities(function (caps) {
                if (!isCurrent(issuedAt) || !caps) return;
                flow.applyCapabilities(caps);
                flow.capabilitiesAnswered = true;
            });
        }

        if (fetchIdentity) {
            fetchIdentity(function (reply) {
                if (!isCurrent(issuedAt) || !reply) return;
                flow.identityExists = reply.exists === true;
                flow.identityNodeId = reply.nodeId || "";
                flow.identityProblem = reply.problem || "";
                flow.embeddedHome = reply.home || "";
                flow.identityAnswered = true;
            });
        }

        if (fetchNodeStatus) {
            fetchNodeStatus(function (reply) {
                if (!isCurrent(issuedAt) || !reply) return;
                flow.alreadyServing = reply.serving === true;
                flow.nodeStatusAnswered = true;
            });
        }

        // The one call that marks no answer: the seed list is the network
        // step's data, not a finding, and gates nothing. See the header.
        if (fetchSeeds) {
            fetchSeeds(function (reply) {
                if (!isCurrent(issuedAt) || !reply) return;
                flow.seeds = reply.items || [];
            });
        }
    }

    /// Which preflight probes have answered — one named flag per gating call.
    ///
    /// Tracked rather than inferred from the findings themselves: every finding
    /// has a legitimate falsy value, so "gitFound is false" cannot distinguish
    /// "git is missing" from "nobody has asked yet". That distinction is the
    /// whole reason `preflightDone` exists — a UI that read the defaults as
    /// answers would report four failures before issuing a single call.
    ///
    /// **Three flags rather than a counter compared against `3`.** The literal
    /// was several lines from the calls that determined it, so a fifth probe,
    /// or a probe made optional, would have left the threshold to be found and
    /// updated separately — and getting it wrong fires `preflightDone` early
    /// (reporting an unasked question as answered) or never. As a conjunction
    /// of named flags, adding a probe means adding a flag the conjunction will
    /// not be satisfied without, and removing one means deleting a name the
    /// compiler-equivalent — an unresolved property reference — complains
    /// about. The invariant holds by construction instead of by arithmetic.
    property bool capabilitiesAnswered: false
    property bool identityAnswered: false
    property bool nodeStatusAnswered: false

    /// True once every gating probe has answered. `listKnownSeeds` is
    /// deliberately absent: it feeds the network step's seed list, which is not
    /// a finding and blocks nothing.
    readonly property bool allProbesAnswered:
        capabilitiesAnswered && identityAnswered && nodeStatusAnswered

    onAllProbesAnsweredChanged: {
        if (allProbesAnswered) {
            preflightDone = true;
            if (resumeWanted) {
                resumeWanted = false;
                landOnFirstUnfinishedStep();
            }
        }
    }

    // ---- re-entry ---------------------------------------------------------
    //
    // A showing that was asked to RESUME lands at the first step whose work the
    // backend reports as not yet done, rather than at step 0 or at the step the
    // previous showing was closed on.

    /// Whether this showing is waiting for the preflight so it can resume.
    ///
    /// Set by `restart()` and cleared by the landing, so the resume happens once
    /// per showing. Held rather than inferred, because "the preflight has
    /// answered" is true for every later refresh too, and a flow that re-derived
    /// the step on each of them would yank a user off a step they walked to.
    property bool resumeWanted: false

    /// Begin a showing: preflight, then land on the first step with work left.
    ///
    /// **This is what a host calls when it raises the setup**, in place of
    /// `reset()` + `runPreflight()`. The two are kept apart because `reset()` is
    /// "forget everything" and this is "ask the backend where we are", and only
    /// the second is correct for a flow whose every write is separately durable.
    function restart() {
        reset();
        resumeWanted = true;
        runPreflight();
    }

    /// The index of the first step whose work the backend has not reported done.
    ///
    /// Derived from the preflight replies, in the order the spec states:
    ///
    ///   mode not `embedded`                      -> embedded
    ///   mode `embedded`, no identity             -> identity
    ///   mode `embedded`, an identity exists      -> network
    ///
    /// A pure function of two reply-derived values, so a flow given different
    /// replies answers differently — which is what makes "it derived the resume
    /// point" distinguishable from "it always returned the last step".
    ///
    /// **`alreadyServing` is deliberately NOT read here, and it once was.** It
    /// chose between the start and confirm steps, and both are gone: this flow
    /// neither starts nor stops a node, so whether one is running says nothing
    /// about which of its steps still has work. A resume that landed differently
    /// for a running node than for a stopped one would be reporting the node's
    /// state through the step it chose, which is `embedded-state`'s job.
    ///
    /// The network step is the landing for an existing identity because it is
    /// the last and has no work the backend can report as done. The identity
    /// step is deliberately NOT it: its forward control advances rather than
    /// creating when an identity is already there, but that is about what the
    /// step does when a user REACHES it — by going back, or with an identity
    /// that appeared between the preflight and the step — and a resume landing
    /// there would present a step whose only act is already done as the first
    /// step with work left.
    readonly property int resumeIndex: {
        if (!modeIsEmbedded) return steps.indexOf("embedded");
        if (!identityExists) return steps.indexOf("identity");
        return steps.indexOf("network");
    }

    /// Put `resumeIndex` in force, **as a single assignment**.
    ///
    /// **Not by looping `advance()`, and that is the whole of this function.**
    /// Every step change bumps `epoch`, and the preflight replies that decided
    /// where this is going were issued under the epoch the preflight ran at.
    /// Advancing step by step moves the epoch past them, so
    /// the findings that chose the destination are discarded on arrival: the
    /// resumed step renders an unpopulated identity finding and offers creation
    /// for an identity that exists. Assigning once leaves the epoch where the
    /// replies were issued, so everything they populated is still in force.
    ///
    /// It also cannot be expressed as an advance at all: `canAdvance` refuses to
    /// leave the embedded step until capabilities report `embedded`, which is
    /// correct for a user's control and wrong for a move the backend itself
    /// chose.
    ///
    /// `stepMoved()` is emitted so a view can react, but `epoch` is deliberately
    /// NOT bumped: no call was issued under a step this move invalidates, and
    /// bumping would drop the preflight's own replies if any are still in
    /// flight — the seed list in particular, which does not gate the landing.
    function landOnFirstUnfinishedStep() {
        stepIndex = resumeIndex;
        stepMoved();
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

    // ---- the embedded step -------------------------------------------------

    /// Put Embedded in force.
    ///
    /// **Takes no mode argument, and that is the point.** Its predecessor was
    /// `chooseMode(mode)`, which could express `explore` and `local` — and a
    /// picker offering all three is what the wizard shipped as its second step,
    /// inside a flow whose next four steps are about a node neither of the
    /// other two runs. With no parameter there is no second answer to express:
    /// the only write reachable from this flow is `mode=embedded`, so the
    /// spec's "MUST NOT offer explore or local" holds in the state object and
    /// not only in what the screen happens to draw.
    ///
    /// **Called by a control, never by arriving at the step.** A mode written
    /// on arrival would put a module into Embedded because someone opened a
    /// screen, and would leave the separate-identity consequence something the
    /// user was shown rather than something they answered. Nothing in this file
    /// calls it; `back()` and `advance()` cannot reach it.
    ///
    /// Does NOT record the flow's own copy of the result: `modeInForce` is
    /// refreshed from capabilities, so the flow reports what is in force rather
    /// than what it asked for. A refused write therefore leaves the mode and
    /// the step exactly where they were, with the refusal on screen.
    function confirmEmbedded() {
        if (!saveSetting) return false;
        var issuedAt = epoch;
        lastError = "";
        saveSetting("mode", "embedded", function (reply) {
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
        return true;
    }

    /// Everything a `getCapabilities()` reply says, written to the properties
    /// that hold it.
    ///
    /// One function rather than the same assignments at each call site.
    /// Both callers — the preflight and `refreshCapabilities` — need exactly
    /// this mapping, and a hand-written second copy is the shape CLAUDE.md
    /// names as this repo's standing defect: the `wantRid`/`syncEpoch` guard
    /// was written out four slightly different times and dropped a different
    /// field each time. A third caller now inherits the mapping instead of
    /// re-deriving it.
    ///
    /// **No `nodeId` any more.** It existed for the confirm step, and
    /// capabilities were its last fallback behind `createEmbeddedIdentity` and
    /// `startNode`. The identity step reads `identityNodeId`, which comes from
    /// the two replies that describe the embedded home specifically —
    /// `getEmbeddedIdentity()` and the creation — and never from capabilities,
    /// which report the mode in force and would be a different home's DID in any
    /// other mode.
    function applyCapabilities(caps) {
        gitFound = caps.gitFound === true;
        gitProblem = caps.gitProblem || "";
        pathsProblem = caps.pathsProblem || "";
        modeInForce = caps.mode || "";
    }

    function refreshCapabilities() {
        if (!fetchCapabilities) return;
        var issuedAt = epoch;
        fetchCapabilities(function (caps) {
            if (!isCurrent(issuedAt) || !caps) return;
            flow.applyCapabilities(caps);
        });
    }

    // ---- the identity step ------------------------------------------------

    /// The identity step's ONE forward control.
    ///
    /// **This is what the button calls**, and it is one function because it is
    /// one act: leaving the identity step. Whether that act includes a creation
    /// call is decided here from what the backend reported, not by the user
    /// answering a second question whose only permitted answer is yes.
    ///
    /// With no identity, it creates and — on a reply reporting one created —
    /// advances **in the same act**, with no further invocation. The advance is
    /// inside the reply handler rather than after the call, because a reply is
    /// the only thing that can say creation succeeded; advancing after issuing
    /// the call would leave a refused creation on the network step.
    ///
    /// With an identity already there, it advances and issues **no call**. The
    /// backend refuses an occupied home, so a second creation call has no
    /// outcome but a refusal the user did not ask for — which is exactly the
    /// amber sentence the two-control version rendered beside a green success.
    ///
    /// Returns whether the act was performed, so a caller can tell "refused,
    /// nothing happened" from "done".
    function submitIdentityStep(alias, passphrase) {
        if (!canAdvanceIdentity) return false;
        if (identityExists) return advance();
        return submitIdentity(alias, passphrase);
    }

    /// Create the identity, passing the alias through exactly as typed.
    ///
    /// No pre-validation of the alias, deliberately: the backend passes the
    /// `radicle` crate's own statement of the rule back as its refusal, and a
    /// second rule here would drift from it — presenting as the wizard
    /// rejecting an alias the backend would have accepted, with nothing on
    /// screen saying which layer refused.
    ///
    /// **Kept as its own function rather than folded into
    /// `submitIdentityStep`.** Creating the identity and leaving the step are
    /// two jobs that happen to compose: this one owns the call, its arguments
    /// and its refusal, and the caller above owns the decision about which act
    /// to perform. It is also the entry point the passphrase-lifetime tests
    /// drive directly, because they are about what reaches the backend rather
    /// than about navigation.
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
            // The one fact no later reply can supply: THIS showing made it. It
            // is what keeps "created" and "was already there" two renderings
            // rather than one.
            flow.identityCreatedHere = reply.created === true;
            if (reply.home) flow.embeddedHome = reply.home;
            // Created and advanced in one act. Guarded on the created flag
            // rather than on the call having returned, so a reply that is not a
            // success leaves the user on the step with the refusal on screen.
            if (flow.identityExists && flow.step === "identity") flow.advance();
        });
        return true;
    }

    // **No start and no confirm.** `submitStart`, `refreshNodeStatus` and
    // `allowCommand` were theirs and are gone with them, along with the
    // `nodeId` that only the confirm step read — the identity step has its own
    // `identityNodeId`, and the header now shows the DID that a confirm screen
    // used to show once and then be dismissed.
    //
    // The absence of a start path is a requirement rather than a consequence of
    // deleting a screen: with no `startNode` property and no function that
    // could call one, "this flow MUST NOT issue startNode, in any step, for any
    // reason" holds structurally.

    // ---- reset ------------------------------------------------------------

    /// Back to the beginning, for a flow that is shown again.
    ///
    /// Bumps the epoch, so anything still in flight from the previous showing
    /// cannot land in the fresh one.
    function reset() {
        stepIndex = 0;
        epoch = epoch + 1;
        // A pending resume belongs to the showing being discarded. `restart()`
        // re-arms it after calling this, so the flag is per-showing rather than
        // surviving one.
        resumeWanted = false;
        preflightDone = false;
        capabilitiesAnswered = false;
        identityAnswered = false;
        nodeStatusAnswered = false;
        gitFound = false;
        gitProblem = "";
        identityExists = false;
        identityNodeId = "";
        identityProblem = "";
        // Per-showing by construction: "this showing created it" cannot outlive
        // the showing, and a resumed flow that found an identity must report it
        // as already there rather than as one it made.
        identityCreatedHere = false;
        alreadyServing = false;
        embeddedHome = "";
        pathsProblem = "";
        modeInForce = "";
        seeds = [];
        lastError = "";
        stepMoved();
    }
}
