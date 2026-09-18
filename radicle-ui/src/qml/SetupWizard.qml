import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Theme.js" as Theme

/*
 * The embedded node's guided setup, rendered.
 *
 * Four steps — preflight, embedded, identity, network — over module methods
 * that already exist. This file is the SCREEN; `SetupFlow.qml` beside it is the
 * state, the blocking rules and the calls. Read that first: every "why" about
 * ordering, gating and staleness is there, and nothing here decides any of it.
 *
 * ## It sets a node up and then ends
 *
 * It does not start the node and does not display the DID. Both were steps of
 * this flow and both are now elsewhere, for the same reason: neither is a thing
 * done once at setup time. Starting is what the mode does whenever it is
 * opened, so a flow is the wrong shape for it — the Embedded surface owns it.
 * The DID is wanted at arbitrary later moments and mostly when this flow is
 * long closed, so a screen that shows it once and is dismissed is the worst
 * place to keep it — the header owns it.
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
 *  - **the passphrase trade**, at the identity step, where the control is — and
 *    it now also states what the choice decides about every LATER opening of
 *    Embedded, which is the consequence the user actually lives with;
 *  - **that this is a NEW identity**, at the embedded step, BEFORE anything is
 *    created, in full. It used to be split between that step and a terminal
 *    screen that restated it with the DID; that screen is gone, and a
 *    consequence stated in half is one a user acts on without;
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
    /// The identity step's ONE forward control, and which of the three states
    /// decides what it does. Two observables because they answer two questions:
    /// "is the way out offered" and "what will it do".
    readonly property bool identityForwardEnabled: setupFlow.canAdvanceIdentity
    readonly property string identityState: setupFlow.identityState
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
    /// **The passphrase field is cleared here**, which is the outer of two
    /// clearings and the one that covers an ABANDONED showing.
    /// `setupFlow.restart()` resets every flow property, but the field lives in
    /// the view, so `reset()` cannot reach it. Without this, a passphrase typed
    /// into a showing the user closed part way outlives that showing — the
    /// overlay is never destroyed — and sits readable in a live object for the
    /// rest of the module's life. This repo's dev Basecamp ships the QML
    /// inspector compiled in, which reads live object properties, so "resident"
    /// means "readable".
    ///
    /// The switch goes back to its default with it: leaving it checked over a
    /// cleared field would submit a creation whose passphrase is silently empty
    /// — an unencrypted key the user believed they had sealed, which is the one
    /// outcome here that cannot be undone.
    ///
    /// Deleting either line turns
    /// `test_a_passphrase_does_not_outlive_an_abandoned_showing` red.
    function show() {
        passphraseField.text = "";
        passphraseSwitch.checked = true;
        setupFlow.restart();
    }

    // The passphrase the identity step takes. **It has exactly one consumer
    // now** — `createEmbeddedIdentity` — because this flow starts no node, so
    // there is no second call with a use for it.
    //
    // Read from the field rather than stored separately, so there is one copy.
    readonly property string passphrase:
        passphraseSwitch.checked ? passphraseField.text : ""

    // Cleared once the creation it was taken for has been ANSWERED, which is
    // the inner of the two clearings and makes the ordinary lifetime exactly
    // one call rather than one showing.
    //
    // Keyed on `identityCreatedHere` — set only by a reply reporting the
    // identity created — rather than done in the button's handler, because the
    // handler runs before the reply and clearing there would destroy the
    // passphrase a retry needs after a refused creation.
    //
    // It has to be explicit because the field is never destroyed: StackLayout
    // instantiates every child eagerly, so nothing goes away when the step
    // changes.
    Connections {
        target: setupFlow
        function onIdentityCreatedHereChanged() {
            if (setupFlow.identityCreatedHere) passphraseField.text = "";
        }
    }

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

                    // What FOLLOWS from that separateness, and **this step is
                    // now the only place the flow says it.** The deleted
                    // confirm step carried half of it, beside the DID; a
                    // consequence stated in half is one a user acts on without.
                    //
                    // Said here rather than after creation on its own terms
                    // too: a statement made only once the identity exists is
                    // made after the decision it informs.
                    Text {
                        objectName: "embeddedConsequence"
                        width: body.width
                        text: "So the repositories in your existing Radicle "
                            + "home are not in this node's storage, and a "
                            + "private repository reaches this node only once "
                            + "a delegate authorises this DID."
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
                //
                // THREE states, told apart, and ONE control out.
                //
                // What this replaces was photographed by the user: a green
                // "Created: did:key:z6Mkv…" above an amber "An identity already
                // exists in this home … Creating a second one is refused", a
                // filled passphrase field with the encrypt switch off, and two
                // buttons — "Create identity" and "Next". Every one of those is
                // a consequence of the step rendering "there is an identity"
                // without asking WHERE it came from, and of offering creation
                // and advancing as separate acts.
                //
                // So the three states are `setupFlow.identityState`, one value
                // with three cases, and each renders exactly one statement. Two
                // of them cannot be on screen at once, which is the point of it
                // being one value rather than two booleans.
                Column {
                    spacing: Theme.gapSm

                    Text {
                        objectName: "identityIntro"
                        visible: setupFlow.identityState === "none"
                        width: body.width
                        text: "Create the identity this node operates as."
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    // ---- which home ------------------------------------------
                    //
                    // A DID names the identity and says NOTHING about where it
                    // lives. The embedded home is derived from the Basecamp
                    // profile's data directory — a path the user did not choose
                    // and cannot guess — so a step reporting only a DID leaves
                    // them unable to find, back up or inspect what was created,
                    // or to tell it from their own ~/.radicle.
                    //
                    // Displayed in ALL THREE states, because "which home is
                    // this" is the same question before and after creation.
                    Text {
                        objectName: "identityHome"
                        width: body.width
                        text: setupFlow.embeddedHome !== ""
                              ? "This node's Radicle home: "
                                + setupFlow.embeddedHome
                              // An empty `home` is not an empty path to print.
                              // The backend's own sentence names what was tried,
                              // and is preferred over this wording.
                              : "No Radicle home could be resolved to write "
                                + "into. " + setupFlow.problemFor(
                                    setupFlow.identityProblem,
                                    setupFlow.pathsProblem, "")
                        color: setupFlow.embeddedHome !== ""
                               ? Theme.textDim : Theme.bad
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WrapAnywhere
                    }

                    // ---- state 2: created in THIS showing ---------------------
                    Text {
                        objectName: "identityCreated"
                        visible: setupFlow.identityState === "created"
                        width: body.width
                        text: "Created: " + setupFlow.identityNodeId
                        color: Theme.good
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.mono
                        wrapMode: Text.WrapAnywhere
                    }

                    // ---- state 3: already there on arrival --------------------
                    //
                    // A SUCCESS, not a failure. A user who already holds an
                    // identity has succeeded at this step; the old rendering
                    // told them creation was refused, which describes an attempt
                    // nobody made. The note below says why creation is not
                    // offered — as a note, in the ordinary text colour, never on
                    // the refusal surface, which is reserved for a refusal the
                    // backend returned to this showing.
                    Text {
                        objectName: "identityAlreadyThere"
                        visible: setupFlow.identityState === "present"
                        width: body.width
                        text: "An identity is already set up here: "
                              + setupFlow.identityNodeId
                        color: Theme.good
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.mono
                        wrapMode: Text.WrapAnywhere
                    }

                    Text {
                        objectName: "identityAlreadyThereNote"
                        visible: setupFlow.identityState === "present"
                        width: body.width
                        text: "Nothing to create — this step is done. A second "
                            + "identity in the same home is refused rather than "
                            + "overwriting the first."
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    // ---- state 1's controls ----------------------------------
                    //
                    // The alias, the switch, the trade and the field all belong
                    // to the no-identity state, because it is the only one in
                    // which this step submits either. Where an identity exists
                    // its key was sealed, or not, when it was created, and this
                    // flow cannot change that — so stating the trade there would
                    // describe a decision that is not the user's to take.
                    Text {
                        objectName: "identityAliasLabel"
                        visible: setupFlow.identityState === "none"
                        text: "Alias"
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                    }

                    TextField {
                        id: aliasField
                        objectName: "identityAlias"
                        width: body.width
                        visible: setupFlow.identityState === "none"
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
                        objectName: "identityPassphraseRow"
                        visible: setupFlow.identityState === "none"
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
                    //
                    // **The second sentence is what this choice now decides**,
                    // and it was not stated at all while the flow started the
                    // node itself. The choice made here is no longer about one
                    // start the user is about to ask for; it is about every
                    // subsequent opening of Embedded, for the life of the mode.
                    // An unencrypted key means the node starts by itself when
                    // the mode is opened; an encrypted one means a passphrase
                    // is asked for each time. That is the consequence the user
                    // lives with, and it is chosen here and nowhere else.
                    Text {
                        objectName: "passphraseTrade"
                        visible: setupFlow.identityState === "none"
                        width: body.width
                        text: "With a passphrase, the node must be unlocked "
                            + "every time it starts — it is handed an "
                            + "already-decrypted key when it is built, so one "
                            + "cannot be supplied later. Without a passphrase, "
                            + "the node starts with no prompt, at the cost of "
                            + "a secret stored in plaintext on disk.\n\n"
                            + "This decides what happens every time you open "
                            + "Embedded from now on: an unencrypted key lets "
                            + "the node start without a prompt, and an "
                            + "encrypted one is asked for each time."
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                    }

                    TextField {
                        id: passphraseField
                        objectName: "identityPassphrase"
                        width: body.width
                        visible: setupFlow.identityState === "none"
                                 && passphraseSwitch.checked
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

                    // ---- the ONE forward control -----------------------------
                    //
                    // Creating the identity IS how this step is left, so there
                    // is no second control asking a question whose only
                    // permitted answer is yes. The label comes from the flow, so
                    // it names the act that will actually be performed.
                    Button {
                        objectName: "identityForward"
                        text: setupFlow.identityActionLabel
                        enabled: setupFlow.canAdvanceIdentity
                        onClicked: setupFlow.submitIdentityStep(
                                       aliasField.text, wizard.passphrase)
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

                // **No step 5 and no step 6.** Start moved to the Embedded
                // surface and confirm was deleted; `SetupFlow.steps` carries
                // the reasoning. What stood here is worth recording, because
                // both screens were defects rather than merely redundant:
                //
                //  - the START step rendered an amber "a node is already
                //    answering on the resolved socket. Starting a second one
                //    would contend for it" directly above its own green
                //    "Running as did:key:…" and "The control socket is
                //    answering." Both were derived from true readings, and the
                //    node warned about was the one this wizard had just
                //    started. Only a surface that knows whether IT started the
                //    node can tell those apart — see
                //    `EmbeddedState.foundForeignNode`.
                //  - the CONFIRM step's only act was to be dismissed. Its DID
                //    is in the header now, always reachable rather than shown
                //    once; its allow line went with it; and its
                //    separate-identity statement moved UP to the embedded step,
                //    where it is made before the decision it informs rather
                //    than after.
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

                // **Absent on the identity step**, which offers its own single
                // forward control instead. Two buttons that both move forward is
                // exactly what the user photographed — "Create identity" beside
                // "Next" — and it makes it possible to advance past a step whose
                // work was never done. Hidden rather than disabled: a disabled
                // Next beside an enabled "Create identity and continue" would
                // still read as two ways out, one of them broken.
                //
                // **On the LAST step it finishes rather than advancing**, and
                // is the same control rather than a second one beside it: the
                // forward control is where a user's hand already is, and a
                // separate Finish would be two ways out of one step. It issues
                // NO call — the steps made every write this flow makes, and
                // ending is the surface coming down. What the user sees
                // afterwards is the Embedded surface, which reports the node's
                // state and starts it where it can.
                Button {
                    objectName: "wizardNext"
                    visible: setupFlow.step !== "identity"
                    text: setupFlow.onLastStep ? "Finish" : "Next"
                    enabled: setupFlow.onLastStep || setupFlow.canAdvance
                    onClicked: {
                        if (setupFlow.onLastStep) wizard.closed();
                        else setupFlow.advance();
                    }
                }

                Button {
                    objectName: "wizardClose"
                    // Always "Cancel" now. It read "Done" on the confirm step,
                    // which is gone — and on the last step the forward control
                    // is what finishes, so a second button reading "Done" beside
                    // it would be two ways out with one of them the giving-up
                    // one, spelled as if it were the finishing one.
                    text: "Cancel"
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
