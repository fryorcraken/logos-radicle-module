import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Theme.js" as Theme

/*
 * The embedded node's guided setup, rendered.
 *
 * Six steps — preflight, embedded, identity, network, start, confirm — over
 * module methods that already exist. This file is the SCREEN; `SetupFlow.qml`
 * beside it is the state, the blocking rules and the calls. Read that first:
 * every "why" about ordering, gating and staleness is there, and nothing here
 * decides any of it.
 *
 * ## What this screen is for
 *
 * Embedded mode is selectable without it, and chosen cold it does nothing a
 * user can account for: the mode persists, the home repoints, `localAvailable`
 * goes false, and everything after that is separate methods with no order and
 * no screen naming the consequences.
 *
 * Three of those consequences are decisions the user owes an answer to, and
 * each is cheapest to state where the choice is made rather than discovered
 * afterwards. This screen exists to state them at those three moments:
 *
 *  - **the passphrase trade**, at the identity step, where the control is;
 *  - **that this is a NEW identity**, at the embedded step BEFORE anything is
 *    created, and again at confirm with the DID that now exists;
 *  - **that the node accepts no inbound connections**, at the network step, as
 *    the setting in force rather than as a choice.
 *
 * ## Why the trade statements are not conditional on the control
 *
 * The passphrase statement is visible for BOTH settings of its switch. A
 * statement that vanishes when the control is turned off tells the user least
 * at the moment they choose the riskier option, and a statement naming only the
 * security benefit is a recommendation rather than a trade — the user cannot
 * weigh one side.
 *
 * ## Why the network step has no inbound control
 *
 * Nothing persists a listen address: the settings store is fixed at five keys
 * and none describes `listen`. A toggle here would record nothing and the node
 * would keep binding no port, which is worse than no control at all. So the
 * step states the default, states its consequence, and states that enabling
 * inbound is not available HERE — the absence is named rather than left looking
 * like an oversight. The opt-in belongs to the configuration panel, which is
 * the surface that introduces a channel for persisting it.
 */
Item {
    id: wizard

    /// The state. Exposed so a host can wire the injected call functions and a
    /// test can drive the flow without reaching through the scene graph.
    property alias flow: setupFlow

    /// The user is done, or gave up. The HOST decides what that means — this
    /// screen does not close itself, the same rule SettingsPanel follows.
    ///
    /// The requirement is explicit that the surface reports and the module that
    /// raised it lowers it: a surface that closed itself would leave whatever
    /// raised it still believing the surface is up. `Main.qml` is the host — see
    /// its `setupPane`.
    signal closed()

    implicitWidth: 560
    implicitHeight: body.implicitHeight + Theme.gapLg * 2

    // ---- test-observable state -------------------------------------------
    // Assertions should ask the screen what it believes rather than infer it
    // from rendered pixels — Main.qml and SettingsPanel do the same.
    readonly property string currentStep: setupFlow.step
    readonly property bool backEnabled: setupFlow.canGoBack
    readonly property bool advanceEnabled: setupFlow.canAdvance
    readonly property bool confirmEmbeddedEnabled: setupFlow.canConfirmEmbedded
    readonly property bool createEnabled: setupFlow.canCreateIdentity
    readonly property bool startEnabled: setupFlow.canStartNode
    readonly property string errorShown: setupFlow.lastError

    SetupFlow {
        id: setupFlow
    }

    /// Begin a showing.
    ///
    /// **Called by the host each time it raises this, not once at
    /// instantiation.** The overlay hosting it is not destroyed when it is
    /// lowered — `Main.qml` keeps one instance and toggles `visible` — so
    /// `Component.onCompleted` fires exactly once, for the first showing only.
    /// A second showing driven by it would resume nothing, re-run no preflight,
    /// and sit on whatever step the previous user left behind, which is
    /// precisely the remembered-index second opinion the requirement forbids.
    ///
    /// `restart()` rather than `runPreflight()`: the landing step is derived
    /// from the replies this preflight is about to collect.
    ///
    /// **The passphrase field is cleared here, and this is the only place it
    /// can be.** `setupFlow.restart()` resets every flow property, but the
    /// field lives in the view, so `reset()` cannot reach it. Without this, a
    /// passphrase typed into a showing the user abandoned before starting the
    /// node outlives that showing — the overlay is never destroyed — and the
    /// next showing resumes at the start step holding it, handing a stale
    /// secret to `startNode()` with no re-entry by the user.
    ///
    /// **Here rather than in the start button's `onClicked`**: that handler
    /// runs before the reply, so clearing there would destroy the passphrase a
    /// retry needs after a refusal
    /// (`test_a_refused_start_keeps_the_passphrase_for_the_retry`). Keying on
    /// the showing instead makes the lifetime exactly one showing, which covers
    /// the abandoned case the `nodeStarted` clearing below cannot see.
    ///
    /// The switch goes back to its default with it: leaving it checked over a
    /// cleared field would offer a start whose passphrase is silently empty.
    ///
    /// Deleting either line turns
    /// `test_a_passphrase_does_not_outlive_an_abandoned_showing` red.
    function show() {
        passphraseField.text = "";
        passphraseSwitch.checked = true;
        setupFlow.restart();
    }

    // The passphrase the identity step took, held here because the START step
    // needs it: the node is handed an already-decrypted signing key when it is
    // built, so there is no later point at which one could be supplied.
    //
    // Read from the field rather than stored separately, so there is one copy.
    readonly property string passphrase:
        passphraseSwitch.checked ? passphraseField.text : ""

    ScrollView {
        id: scroller
        anchors.fill: parent
        anchors.margins: Theme.gapLg
        clip: true
        contentWidth: availableWidth

        Column {
            id: body
            width: scroller.availableWidth
            spacing: Theme.gap

            // ---- header ---------------------------------------------------

            Row {
                width: body.width
                spacing: Theme.gapSm

                Text {
                    objectName: "wizardTitle"
                    text: "Set up an embedded node"
                    color: Theme.text
                    font.pixelSize: Theme.fontXl
                    font.bold: true
                }
            }

            /// Which step, of how many. A wizard that does not say where you
            /// are in it is a sequence of unexplained screens.
            Text {
                objectName: "wizardStepLabel"
                width: body.width
                text: "Step " + (setupFlow.stepIndex + 1) + " of "
                      + setupFlow.steps.length + " — " + setupFlow.step
                color: Theme.textDim
                font.pixelSize: Theme.fontSm
            }

            // ---- the backend's refusal, wherever it came from --------------
            //
            // Shown verbatim. The module's refusals name the home that was in
            // the way, the path to remove, the value that was tried and the
            // limit that was exceeded — which is the whole reason validation
            // happens on write. Replacing one with this screen's own wording
            // throws away the only actionable part.
            Rectangle {
                objectName: "wizardError"
                visible: setupFlow.lastError !== ""
                width: body.width
                height: errorText.implicitHeight + Theme.gapSm * 2
                radius: Theme.radiusSm
                color: Theme.surfaceAlt
                border.width: 1
                border.color: Theme.bad

                Text {
                    id: errorText
                    objectName: "wizardErrorText"
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.gapSm
                    anchors.rightMargin: Theme.gapSm
                    text: setupFlow.lastError
                    color: Theme.bad
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                }
            }

            // ---- the steps ------------------------------------------------

            StackLayout {
                width: body.width
                height: currentIndex >= 0 ? implicitHeight : 0
                currentIndex: setupFlow.stepIndex

                // ---- 1. preflight -------------------------------------------
                //
                // Four findings, each its own outcome. NOT one pass/fail: a
                // user has to see WHICH one failed, and each blocks only what
                // it actually makes impossible.
                Column {
                    id: preflightStep
                    spacing: Theme.gapSm

                    Text {
                        width: body.width
                        text: "Checking what is already here. Nothing is "
                            + "written or started by these checks."
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    Finding {
                        objectName: "findingGit"
                        width: body.width
                        label: "git"
                        answered: setupFlow.preflightDone
                        ok: setupFlow.gitFound
                        okText: "A git executable resolves."
                        // The backend's sentence names the path that was tried;
                        // the fallback has to stand on its own because it is
                        // what shows when the backend supplied nothing.
                        failText: setupFlow.problemFor(
                            setupFlow.gitProblem,
                            "No git executable could be resolved. Radicle "
                          + "spawns git to read and write storage.")
                    }

                    Finding {
                        objectName: "findingIdentity"
                        width: body.width
                        label: "identity"
                        answered: setupFlow.preflightDone
                        // Not a failure either way — this reports WHAT IS
                        // THERE. An existing identity blocks creation, which
                        // the identity step says; it is not a broken preflight.
                        neutral: true
                        // The wording is deliberate: "no identity exists",
                        // never "the home is empty". getEmbeddedIdentity
                        // reports exists:false for a half-created home too, and
                        // telling a user it is empty sends them looking for a
                        // different problem when creation is then refused for a
                        // keys path that is demonstrably there.
                        okText: setupFlow.identityExists
                                ? "An identity already exists here: "
                                  + setupFlow.identityNodeId
                                : "No identity exists here yet."
                        failText: setupFlow.identityProblem
                    }

                    Finding {
                        objectName: "findingNode"
                        width: body.width
                        label: "node socket"
                        answered: setupFlow.preflightDone
                        ok: !setupFlow.alreadyServing
                        okText: "No node is answering on the resolved socket."
                        failText: "A node is already answering on the resolved "
                                + "socket. Starting a second one would contend "
                                + "for it."
                    }

                    Finding {
                        objectName: "findingHome"
                        width: body.width
                        label: "home"
                        answered: setupFlow.preflightDone
                        ok: setupFlow.homeResolved
                        okText: "A home can be written to: "
                                + setupFlow.embeddedHome
                        failText: setupFlow.problemFor(
                            setupFlow.pathsProblem,
                            setupFlow.identityProblem,
                            "No Radicle home could be resolved to write into.")
                    }
                }

                // ---- 2. embedded ---------------------------------------------
                //
                // A CONFIRMATION, not a pick. This flow sets up Embedded and
                // nothing else, so there is no `ModePicker` here and no list of
                // three: Explore and Local need no setup at all, and offering
                // them inside a flow whose next four steps are about a node
                // neither of them runs is a choice with one permitted answer.
                //
                // Nor is any mode annotated as unstartable. The wizard's second
                // step used to render every row of a `ModePicker` captioned
                // "This version cannot start this mode yet" — `startableModes`
                // arrives empty and is populated only once `getCapabilities()`
                // replies, so in the window before that every mode reads as
                // broken. That default is right FOR ModePicker (a forgotten
                // wiring over-annotates, which is visible) and it is why this
                // step reads no such array at all: a flow setting up one mode
                // has no unstartable alternative to caption.
                Column {
                    spacing: Theme.gapSm

                    // The statement the whole step exists for, and it is made
                    // BEFORE any identity is created — a consequence stated only
                    // at confirm is stated after the decision it informs.
                    Text {
                        objectName: "embeddedExplains"
                        width: body.width
                        text: "Embedded means this module keeps its own Radicle "
                            + "home and runs the node itself. The node operates "
                            + "as a new identity this module creates — separate "
                            + "from any Radicle node you already run and from "
                            + "any identity you already hold."
                        color: Theme.text
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    // What is in force, from getCapabilities().mode — never
                    // from what this flow asked for.
                    Text {
                        objectName: "embeddedInForce"
                        visible: setupFlow.modeIsEmbedded
                        width: body.width
                        text: "Embedded is in force."
                        color: Theme.good
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    // The explicit act. Arriving at this step writes nothing:
                    // a mode written on arrival would put a module into
                    // Embedded because someone opened a screen.
                    Button {
                        objectName: "embeddedConfirm"
                        text: "Use Embedded mode"
                        enabled: setupFlow.canConfirmEmbedded
                        onClicked: setupFlow.confirmEmbedded()
                    }

                    Text {
                        objectName: "embeddedAdvanceBlocked"
                        visible: setupFlow.advanceBlockedReason !== ""
                        width: body.width
                        text: setupFlow.advanceBlockedReason
                        color: Theme.warn
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }
                }

                // ---- 3. identity ---------------------------------------------
                Column {
                    spacing: Theme.gapSm

                    Text {
                        width: body.width
                        text: "Create the identity this node operates as."
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    // Returning to a step that already acted reports what it
                    // did rather than offering to do it again. Identity
                    // creation is not reversible through this flow.
                    Text {
                        objectName: "identityCreated"
                        visible: setupFlow.identityExists
                                 && setupFlow.identityNodeId !== ""
                        width: body.width
                        text: "Created: " + setupFlow.identityNodeId
                        color: Theme.good
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.mono
                        wrapMode: Text.WrapAnywhere
                    }

                    Text {
                        text: "Alias"
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                    }

                    TextField {
                        id: aliasField
                        objectName: "identityAlias"
                        width: body.width
                        enabled: setupFlow.canCreateIdentity
                        placeholderText: "how this node names itself"
                        // No pre-validation, deliberately. The backend passes
                        // the radicle crate's own statement of the alias rule
                        // back as its refusal, and a second rule here would
                        // drift from it — presenting as this screen rejecting
                        // an alias the backend would have accepted, with
                        // nothing saying which layer refused.
                    }

                    // ---- the passphrase trade --------------------------------
                    //
                    // Default ON: leaving the control alone must produce the
                    // safer outcome.
                    Row {
                        spacing: Theme.gapSm

                        Switch {
                            id: passphraseSwitch
                            objectName: "identityPassphraseSwitch"
                            checked: true
                            enabled: setupFlow.canCreateIdentity
                        }

                        Text {
                            anchors.verticalCenter: passphraseSwitch.verticalCenter
                            text: "Encrypt the key with a passphrase"
                            color: Theme.text
                            font.pixelSize: Theme.fontSm
                        }
                    }

                    // BOTH halves, and visible for BOTH settings of the switch.
                    // See the file header for why neither is conditional.
                    Text {
                        objectName: "passphraseTrade"
                        width: body.width
                        text: "With a passphrase, the node must be unlocked "
                            + "every time it starts — it is handed an "
                            + "already-decrypted key when it is built, so one "
                            + "cannot be supplied later. Without a passphrase, "
                            + "the node starts with no prompt, at the cost of "
                            + "a secret stored in plaintext on disk."
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    TextField {
                        id: passphraseField
                        objectName: "identityPassphrase"
                        width: body.width
                        visible: passphraseSwitch.checked
                        enabled: setupFlow.canCreateIdentity
                        echoMode: TextInput.Password
                        placeholderText: "passphrase"
                    }

                    Text {
                        objectName: "identityBlocked"
                        visible: setupFlow.createBlockedReason !== ""
                        width: body.width
                        text: setupFlow.createBlockedReason
                        color: Theme.warn
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    Button {
                        objectName: "identityCreate"
                        text: "Create identity"
                        enabled: setupFlow.canCreateIdentity
                        onClicked: setupFlow.submitIdentity(aliasField.text,
                                                            wizard.passphrase)
                    }
                }

                // ---- 4. network ----------------------------------------------
                Column {
                    spacing: Theme.gapSm

                    // The setting IN FORCE, not a recommendation and not a
                    // choice about to be made.
                    Text {
                        objectName: "networkInbound"
                        width: body.width
                        text: "This node accepts no inbound connections. It "
                            + "can fetch from peers and announce to them, but "
                            + "peers cannot fetch from this node."
                        color: Theme.text
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    // The absence is STATED. A control that silently recorded
                    // nothing would be worse than none, and an unexplained gap
                    // reads as an oversight.
                    Text {
                        objectName: "networkInboundUnavailable"
                        width: body.width
                        text: "Enabling inbound connections is not available "
                            + "in this setup. It needs a listen address to be "
                            + "persisted, which this flow has no way to do."
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        text: "Seeds this node can fetch from"
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                    }

                    // A node that cannot be fetched from can still fetch, which
                    // is what makes the seed list matter more here than it
                    // would with inbound on.
                    Repeater {
                        objectName: "networkSeeds"
                        model: setupFlow.seeds

                        Text {
                            required property var modelData
                            objectName: "networkSeed"
                            width: body.width
                            text: (modelData.alias ? modelData.alias + " — " : "")
                                  + modelData.url
                            color: Theme.text
                            font.pixelSize: Theme.fontSm
                            wrapMode: Text.WrapAnywhere
                        }
                    }
                }

                // ---- 5. start ------------------------------------------------
                Column {
                    spacing: Theme.gapSm

                    Text {
                        objectName: "startWaiting"
                        visible: setupFlow.startPending
                        width: body.width
                        text: "Starting the node — waiting for its control "
                            + "socket to answer…"
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        objectName: "startBlocked"
                        visible: setupFlow.startBlockedReason !== ""
                        width: body.width
                        text: setupFlow.startBlockedReason
                        color: Theme.warn
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    Button {
                        objectName: "startNode"
                        text: "Start the node"
                        enabled: setupFlow.canStartNode
                        onClicked: setupFlow.submitStart(wizard.passphrase)
                    }

                    // The passphrase is cleared once the node has started,
                    // which is the moment both calls that need it have been
                    // made — createEmbeddedIdentity at the identity step and
                    // startNode here.
                    //
                    // It has to be cleared explicitly because the field is
                    // never destroyed: StackLayout instantiates every child
                    // eagerly, so nothing goes away when the step changes and
                    // a plaintext secret would stay resident for the rest of
                    // the wizard's life. This repo's dev Basecamp ships the
                    // QML inspector compiled in, which reads live object
                    // properties — so "resident" means readable.
                    //
                    // Keyed on `nodeStarted` rather than done inside the click
                    // handler: the handler runs before the reply, and clearing
                    // there would destroy the passphrase a retry needs after a
                    // refusal.
                    Connections {
                        target: setupFlow
                        function onNodeStartedChanged() {
                            if (setupFlow.nodeStarted)
                                passphraseField.text = "";
                        }
                    }

                    Text {
                        objectName: "startedNodeId"
                        visible: setupFlow.nodeStarted
                        width: body.width
                        text: "Running as " + setupFlow.nodeId
                        color: Theme.good
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.mono
                        wrapMode: Text.WrapAnywhere
                    }

                    // EMPTY is the expected value and is displayed as such: it
                    // is what confirms the outbound-only default the network
                    // step described. Omitting it when empty would hide exactly
                    // the case worth showing.
                    Text {
                        objectName: "startListening"
                        visible: setupFlow.nodeStarted
                        width: body.width
                        text: setupFlow.listening.length === 0
                              ? "Listening on no address — peers cannot fetch "
                                + "from this node."
                              : "Listening on "
                                + setupFlow.listening.join(", ")
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    // `serving`, not `running`: a node whose threads have died
                    // leaves `running` true while `serving` goes false, and
                    // that is the state a user cannot otherwise account for.
                    Text {
                        objectName: "startServing"
                        visible: setupFlow.nodeStarted
                        width: body.width
                        text: setupFlow.nodeServing
                              ? "The control socket is answering."
                              : "The node is not answering its control socket."
                        color: setupFlow.nodeServing ? Theme.good : Theme.bad
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }
                }

                // ---- 6. confirm ----------------------------------------------
                Column {
                    spacing: Theme.gapSm

                    // Restated, not stated for the first time: the embedded
                    // step said it before anything was created, and this says
                    // it again with the DID that now exists.
                    Text {
                        objectName: "confirmSeparateIdentity"
                        width: body.width
                        text: "This is a new identity, separate from any "
                            + "Radicle node you already run. The repositories "
                            + "in your existing home are not in this node's "
                            + "storage, and a private repository reaches this "
                            + "node only once a delegate authorises this DID."
                        color: Theme.text
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        objectName: "confirmNodeId"
                        visible: setupFlow.nodeId !== ""
                        width: body.width
                        text: setupFlow.nodeId
                        color: Theme.text
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.mono
                        wrapMode: Text.WrapAnywhere
                    }

                    CopyableCommand {
                        objectName: "confirmAllowCommand"
                        width: body.width
                        caption: "A delegate runs this on a repository to let "
                               + "this node fetch it:"
                        // The DID that was reported, never a placeholder — so
                        // the line as shown is the line to run.
                        command: setupFlow.allowCommand
                    }
                }
            }

            // ---- navigation -----------------------------------------------

            Row {
                width: body.width
                spacing: Theme.gapSm

                Button {
                    objectName: "wizardBack"
                    text: "Back"
                    enabled: setupFlow.canGoBack
                    onClicked: setupFlow.back()
                }

                Button {
                    objectName: "wizardNext"
                    text: "Next"
                    enabled: setupFlow.canAdvance
                    onClicked: setupFlow.advance()
                }

                Button {
                    objectName: "wizardClose"
                    text: setupFlow.step === "confirm" ? "Done" : "Cancel"
                    onClicked: wizard.closed()
                }
            }
        }
    }

    /// One preflight finding, as its own outcome.
    ///
    /// An inline component rather than a file of its own: it is four lines of
    /// rendering used in exactly one place, and a separate file would put the
    /// wording further from the step that owns it. Should a second screen ever
    /// report findings, that is the moment to promote it — not before.
    component Finding: Column {
        property string label: ""
        property bool answered: false
        property bool ok: false
        /// A finding that reports WHAT IS THERE rather than pass/fail. The
        /// identity finding is one: an existing identity is not a broken
        /// preflight, it is a fact that blocks one later step.
        ///
        /// Neutral governs how the outcome is COLOURED, not whether a failure
        /// can be reported. A neutral finding whose probe supplied a problem
        /// sentence still shows it: `neutral` means "no identity yet is not a
        /// failure", never "this probe cannot fail". Folding the two together
        /// is what made a real `getEmbeddedIdentity().problem` unreachable —
        /// the spec requires a backend sentence be displayed verbatim, and a
        /// permissions error reading the identity store is exactly such a
        /// sentence.
        property bool neutral: false
        property string okText: ""
        property string failText: ""

        /// Whether this finding has something to report as failed. A neutral
        /// finding fails only when it was given a sentence to show; a
        /// pass/fail one fails whenever `ok` is false.
        readonly property bool failed:
            neutral ? failText !== "" : !ok

        spacing: 0

        Text {
            objectName: "findingLabel"
            text: parent.label
            color: Theme.textDim
            font.pixelSize: Theme.fontXs
            font.bold: true
        }

        Text {
            objectName: "findingOutcome"
            width: parent.width
            // Until the preflight has answered, this says so rather than
            // rendering a default as a result: every finding has a legitimate
            // falsy value, so an unanswered probe is indistinguishable from a
            // failed one unless it is named.
            text: !parent.answered
                  ? "checking…"
                  : (parent.failed ? parent.failText : parent.okText)
            color: !parent.answered ? Theme.textFaint
                   : (parent.failed ? Theme.bad
                      : (parent.neutral ? Theme.text : Theme.good))
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }
    }
}
