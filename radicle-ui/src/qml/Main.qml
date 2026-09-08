import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

/*
 * Radicle browser.
 *
 * The view holds no Radicle logic: every call is a pass-through to the
 * radicle_ui backend (C++/QtRO), which forwards to the `radicle` core module.
 * QML does navigation and rendering only.
 *
 * Two sources, kept visibly distinct because they answer different questions:
 *   Any repo — any public repo on a seed node, no local node needed.
 *   My node  — this machine's own node, including private repos.
 *
 * Layout rule: the top bar, status strip and repo chrome have FIXED heights
 * from Theme, and both screens live in a StackLayout that fills what is left.
 * Nothing below the chrome reflows when a request starts or a screen changes.
 */
Item {
    id: root

    implicitWidth: 1000
    implicitHeight: 700

    // Basecamp sizes the root itself (QQuickWidget + SizeRootObjectToView),
    // and parents it into a *widget* layout, so QML Layout attached properties
    // on the root have no attachee and are inert. Kept only for the case where
    // this view is embedded in a QML layout instead.
    Layout.fillWidth: true
    Layout.fillHeight: true

    // ---- backend wiring ---------------------------------------------------

    readonly property var backend: (typeof logos !== "undefined" && logos)
                                   ? logos.module("radicle_ui") : null
    property bool ready: false

    readonly property string capsJson: backend ? backend.capabilities : ""
    property var caps: ({})

    // Which mode the module is in, and the method routing that follows from it.
    // Both live in SourceState so they can be tested as a unit — inside this
    // file they could only be covered by a stub reproducing them, which is a
    // copy asserted against itself. See SourceState.qml.
    //
    // `mode` is BOUND to capabilities rather than owned here: the backend is
    // the authority on what is in force, and a UI holding its own copy could
    // show a mode the module is not actually in. That is the identity confusion
    // this milestone exists to prevent, one level up.
    readonly property SourceState sourceState: SourceState {
        mode: root.caps.mode || "local"
        localAvailable: root.caps.localAvailable === true
        startableModes: root.caps.startableModes !== undefined
                        ? root.caps.startableModes : []

        // A repo id from one source is meaningless to the other, so the whole
        // navigation stack resets. `nav.reset()` clears state but does NOT
        // refetch — NavState is a pure holder and the caller owns reloading,
        // which is why onBackendReady and setSeed both call reload() alongside
        // it. Omitting the reload here shipped once: the toggle flipped, the
        // screen cleared, and no request was ever issued.
        //
        // The reload is deferred by one event-loop turn, and that is
        // load-bearing rather than defensive. `changed()` fires while the mode
        // write is still in flight, so `root.source` — a binding through
        // `caps.mode` — has NOT settled on the new value yet. A synchronous
        // reload would issue `remoteListRepos` for a switch TO local: the user
        // clicked Local, saw Explore's repositories, and had to toggle away and
        // back before a second reload picked up the source the binding had by
        // then settled on.
        //
        // Same class as the branch-switch bug CLAUDE.md documents ("A binding
        // does not update inside the handler that changed its source"), and
        // the same remedy. Note the deferral now spans a backend round trip
        // rather than one binding evaluation, which makes it MORE necessary
        // rather than less — see reloadWhenModeSettles below.
        onChanged: {
            nav.reset();
            sourceReload.restart();
        }
    }

    /// Runs `repoList.reload()` one turn after the mode actually changes.
    ///
    /// Restarted from two places on purpose. `sourceState.onChanged` covers the
    /// click, and `onSourceChanged` below covers the capabilities reply that
    /// makes the change real — because a mode write is a backend round trip and
    /// the click alone does not tell us the new mode is in force. Restarting a
    /// zero-interval Timer twice costs one extra reload at worst; missing the
    /// second is the empty-list bug that has shipped here before.
    readonly property Timer sourceReload: Timer {
        interval: 0
        repeat: false
        onTriggered: repoList.reload()
    }

    /// Convenience aliases. Views read these rather than reaching through
    /// `sourceState`, so moving the state again does not touch every consumer.
    ///
    /// `source` is the backend METHOD PREFIX ("remote"/"local"), derived from
    /// the mode. `mode` is the persisted choice. They are different things even
    /// though `local` is spelled the same in both — see SourceState.qml.
    readonly property string source: sourceState.current
    readonly property string mode: sourceState.mode
    readonly property bool localAvailable: sourceState.localAvailable

    /// Whether this build can start the mode in force. Read by RepoList to
    /// decide whether to fetch at all — see SourceState.modeStartable for why
    /// that is derived from the startable SET rather than compared against a
    /// mode name.
    readonly property bool modeStartable: sourceState.modeStartable

    /// The capabilities reply confirming a mode change has taken effect. Until
    /// it arrives, `source` still names the OLD surface, so anything fetched is
    /// fetched from the mode the user just left.
    onSourceChanged: {
        nav.reset();
        sourceReload.restart();
    }

    /// Whether a write could actually succeed, and why not when it could not.
    ///
    /// Separate from `localAvailable` on purpose, and the core module's header
    /// states the rule: a profile can exist while its key stays locked, so
    /// gating a compose box on `localAvailable` would offer one that cannot be
    /// submitted. `canWriteLocal` is a real probe for a usable signing key.
    ///
    /// The reason is carried because the absence has to be explained — "no
    /// node" and "node, but locked" prompt different actions, and a missing
    /// button explains neither.
    readonly property bool canWrite: caps.canWriteLocal === true
    readonly property string writeUnavailableReason: caps.writeUnavailableReason || ""

    /// Switch mode, and PERSIST it.
    ///
    /// This is what makes the toggle a real control rather than a decorative
    /// one: the mode is a stored setting, the backend rebuilds its LocalStore
    /// from it, and `getCapabilities()` then reports the new mode, home and
    /// `localAvailable`. `sourceState.mode` is a binding to that reply, so the
    /// segment that lights up is the mode actually in force — never one the UI
    /// merely hoped for.
    ///
    /// A refusal is surfaced rather than swallowed. `callSettings` exists for
    /// exactly this: the message names what was wrong, and a user who clicks a
    /// segment and sees nothing happen has no way to tell "refused" from
    /// "broken".
    function setMode(next) {
        if (!sourceState.select(next)) return;
        callSettings("setSetting", ["mode", next], function (reply) {
            if (reply && reply.error) nav.error = reply.error;
        });
    }

    /// Whether the settings pane is showing. Deliberately NOT part of NavState:
    /// settings overlay the current screen rather than replacing it in the
    /// navigation stack, so closing them returns you to exactly where you were
    /// without a back-stack entry that has nothing to go back to.
    ///
    /// Two ways in — the header's Settings chip and the node identity beside
    /// the toggle — and, since the pane is opaque and covers both of them,
    /// there must be a way OUT that lives inside the pane. There was not, and
    /// it shipped: the panel was a one-way door and the user had to restart the
    /// app. `SettingsPanel.closed()` is that way out; see its Back control.
    property bool settingsOpen: false

    onCapsJsonChanged: {
        var r = R.parse(capsJson);
        if (r.ok) caps = r.data;
    }

    Connections {
        target: (typeof logos !== "undefined" && logos) ? logos : null
        ignoreUnknownSignals: true
        function onViewModuleReadyChanged(moduleName, isReady) {
            if (moduleName === "radicle_ui") {
                root.ready = isReady && root.backend !== null;
                if (root.ready) root.onBackendReady();
            }
        }
    }

    Component.onCompleted: {
        ready = backend !== null
                && (typeof logos !== "undefined")
                && logos.isViewModuleReady("radicle_ui");
        if (ready) onBackendReady();
    }

    /// Everything that needs a live QtRO replica. The seed picker's own load
    /// triggers (Component.onCompleted, onFetchSeedsChanged) all fire before
    /// the replica exists, so its fetch bails out and the dropdown stays empty
    /// forever — it has to be retried from here.
    function onBackendReady() {
        seedPicker.loaded = false;
        seedPicker.reload();
        nav.reset();
        repoList.reload();
    }

    /// Source-routed backend call. `method` is the suffix after remote/local.
    ///
    /// The optional `source` argument overrides `root.source` for one call.
    /// No caller uses it today — the toggle moves every view at once, which is
    /// the point — but it is the seam for a future screen that wants to show
    /// both sources side by side.
    function call(method, args, onOk, onFail, source) {
        if (!backend) return;
        var name = sourceState.methodFor(method, source);
        if (typeof backend[name] !== "function") {
            // No request was started (inflight was never incremented), so
            // this sets the error directly rather than going through fail(),
            // which also decrements the counter.
            nav.error = "unsupported operation: " + name;
            if (onFail) onFail();
            return;
        }
        // Deliberately does NOT clear nav.error on the way in — see
        // NavState.begin()'s doc comment.
        nav.begin();
        logos.watch(backend[name].apply(backend, args), function (text) {
            var r = R.parse(text);
            if (r.ok) {
                nav.succeed();
                onOk(r.data);
            } else {
                nav.fail(r.error);
                if (onFail) onFail();
            }
        }, function (err) {
            nav.fail(String(err));
            if (onFail) onFail();
        });
    }

    /// Switch the remote seed, surfacing a failure instead of silently
    /// keeping the old data under the new seed's name.
    function setSeed(url) {
        if (!backend) return;
        nav.begin();
        logos.watch(backend.setRemoteSeed(url), function (text) {
            var r = R.parse(text);
            if (r.ok) {
                nav.succeed();
                nav.reset();
                repoList.reload();
            } else {
                nav.fail("Cannot use " + url + ": " + r.error);
                // Snap the picker back to the seed actually in use.
                seedPicker.currentSeed = Qt.binding(function () {
                    return root.caps.remoteSeed || "";
                });
                seedPicker.syncSelection();
            }
        }, function (err) {
            nav.fail(String(err));
        });
    }

    /// Source-neutral call (getCapabilities, listKnownSeeds, setRemoteSeed).
    function callPlain(method, args, onOk) {
        if (!backend) return;
        logos.watch(backend[method].apply(backend, args), function (text) {
            var r = R.parse(text);
            if (r.ok) onOk(r.data);
        }, function () {});
    }

    /// Source-neutral call that reports failures to its callback rather than
    /// swallowing them.
    ///
    /// `callPlain` drops errors on purpose — a failed capabilities probe should
    /// not paint the status strip red on every poll. A settings write is the
    /// opposite: the refusal IS the useful result, since it names the path that
    /// was tried or the limit that was exceeded, and a user who typed something
    /// wrong must see why rather than watch the field silently revert.
    function callSettings(method, args, onDone) {
        if (!backend) return;
        logos.watch(backend[method].apply(backend, args), function (text) {
            var r = R.parse(text);
            onDone(r.ok ? r.data : { error: r.error });
        }, function (err) {
            onDone({ error: String(err) });
        });
    }

    // ---- test-observable state -------------------------------------------
    // Read by the UI tests (radicle-ui/tests/ui/*.yaml). Cheap bindings that
    // say what the app believes is true, so assertions do not have to infer it
    // from rendered text.
    readonly property string navView: nav.view
    readonly property bool   navBusy:  nav.busy
    readonly property string navError: nav.error
    readonly property int    repoCount: repoList.count
    readonly property int    seedCount: seedPicker.count
    readonly property int    repoTab:   repoPage.tab
    readonly property int    treeCount: repoPage.treeCount
    readonly property string treeNames: repoPage.treeNames
    readonly property int    commitCount: repoPage.commitCount
    readonly property int    issueCount:  repoPage.issueCount
    readonly property int    patchCount:  repoPage.patchCount
    readonly property string patchStatus: repoPage.patchStatus

    // Which source is selected, and whether the local one is offerable at all.
    // `capsRaw` is the whole capabilities reply verbatim: when the local
    // segment does not appear, the question is always "what did
    // getCapabilities actually say", and reading it out of the app beats
    // guessing from a screenshot.
    readonly property string sourceName:  source
    readonly property bool   hasLocal:    localAvailable
    readonly property string capsRaw:     capsJson

    // Which node, and which identity. Asserted from outside because the
    // failure worth catching is the UI showing one mode while the backend is
    // in another — which a screenshot cannot distinguish from working.
    readonly property string nodeMode:      caps.mode || ""
    readonly property string nodeIdentity:  caps.nodeId || ""
    readonly property string nodeHome:      caps.radHome || ""
    readonly property bool   gitFound:      caps.gitFound === true
    readonly property bool   settingsShown: settingsOpen

    // Sync button: its three idle labels ("Download All" / "Re-sync" /
    // "Update") plus the in-progress percentage are the whole of that
    // feature's user-visible behaviour, so the specs assert on all of them.
    readonly property bool   syncing:         repoPage.syncing
    readonly property real   syncProgress:    repoPage.syncProgress
    readonly property bool   syncedOnce:      repoPage.syncedOnce
    readonly property bool   updateAvailable: repoPage.updateAvailable
    readonly property string syncLabel:       repoPage.syncLabel

    /// See RepoView.sourceTabItem: the sync spec sets the real
    /// `lastSyncedCommit` and calls the real `checkForUpdate()` through this,
    /// rather than through a test-only hook that would fake the outcome.
    readonly property var    sourceTabItem:  repoPage.sourceTabItem

    // File tree and viewer.
    readonly property string treePath:       repoPage.treePath
    readonly property string selectedFile:   repoPage.selectedFile
    readonly property string fileTitle:      repoPage.fileTitle
    readonly property int    fileBodyLength: repoPage.fileBodyLength

    // Branch picker.
    readonly property string repoBranch:        repoPage.branch
    readonly property string repoDefaultBranch: repoPage.defaultBranch
    readonly property int    branchCount:       repoPage.branchCount
    /// True when the picker split the list into this node's branches and other
    /// peers' — only ever the case on the local source, and only for a repo
    /// that has some of each.
    readonly property bool   branchesGrouped:   repoPage.branchesGrouped
    readonly property string branchLabel:       repoPage.branchLabel
    /// See RepoView.branchPickerItem: a ComboBox's popup delegates live in a
    /// separate window and cannot be clicked by objectName, so the branch spec
    /// emits the picker's own `activated` signal instead.
    readonly property var    branchPickerItem:  repoPage.branchPickerItem

    // Detail views. "" when the tabs are showing.
    readonly property string openThread: repoPage.openThread
    readonly property string openCommit: repoPage.openCommit

    /// Whether the comment box is offered. The failure worth asserting on from
    /// outside is the box appearing where it should not — on a seed-hosted
    /// repo, or with no signing key — because that is the one that loses text.
    readonly property bool composerVisible: repoPage.composerVisible

    /// The "New issue" affordance and its form. Same reasoning: the failure
    /// worth catching from outside is the button appearing where its form
    /// could not be submitted.
    readonly property bool canCreateIssue: repoPage.canCreateIssue
    readonly property bool newIssueOpen:   repoPage.newIssueOpen

    /// The open thread's comment count, and the composer itself. Both are for
    /// tests/ui/write.yaml; see ThreadView.qml for why each is needed and what
    /// the count in particular proves. The count is the one assertion that can
    /// distinguish a write that landed from one that only looked like it did.
    readonly property int threadCommentCount: repoPage.threadCommentCount
    readonly property var composerItem: repoPage.composerItem
    readonly property var newIssueFormItem: repoPage.newIssueFormItem

    /// Open a repository object directly (deep links and testing).
    function openRepoExternal(repo) {
        if (repo && repo.rid) nav.openRepo(repo);
    }

    // ---- navigation state -------------------------------------------------
    // See NavState.qml for the counter/error semantics — pulled into its own
    // component so that logic is directly testable, the same way
    // ListCache.qml is tested without a live backend.

    NavState { id: nav }

    // ---- chrome -----------------------------------------------------------

    Rectangle {
        anchors.fill: parent
        color: Theme.bg

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- top bar (fixed height) ----
            Rectangle {
                Layout.fillWidth: true
                // Normally the fixed chrome height — the layout rule above
                // still holds, and nothing reflows as requests come and go.
                //
                // The one thing allowed to grow it is the source toggle's
                // caption, and that is the point rather than an exception: the
                // caption exists BECAUSE the previous design put this text in
                // an overlay anchored past the bottom of a fixed-height bar,
                // where `z` cannot lift it over another parent's later sibling
                // and it rendered as an unreadable sliver. A bar that clips its
                // own explanation would reintroduce exactly that bug, so the
                // bar yields to the text instead. It changes only when the
                // capabilities change, which is not something a user watches
                // happen.
                //
                // `reservedHeight`, NOT `implicitHeight`, and the difference is
                // load-bearing. The toggle's caption shows only in Embedded, so
                // its `implicitHeight` varies by mode; budgeting from that made
                // the bar 44px taller in Embedded and slid the whole body on the
                // click that switched. `reservedHeight` is the caption's budget
                // whether or not it is on screen, so THIS height is constant
                // across modes while the toggle itself stays the size of what it
                // draws — which is what keeps the identity beside it on one line
                // instead of centred 22px lower. See SourceToggle.qml.
                Layout.preferredHeight: Math.max(Theme.barHeight,
                                                 sourceToggle.reservedHeight + Theme.gap)
                color: Theme.surface

                // Pinned to the TOP of the bar and given the control line's own
                // height, rather than filling a bar that is taller than the line.
                //
                // The bar reserves room for the toggle's caption (see
                // `reservedHeight` above), so it is taller than the row of
                // controls in it. A row that filled the bar would centre every
                // item in that larger box, and the caption — which hangs below
                // the toggle — would then be pushed past the bar's bottom edge
                // and clipped, which is the exact bug the caption replaced.
                //
                // Anchoring to the top keeps every control on one line at a
                // fixed y, and leaves the reserved space where the caption
                // actually renders: underneath.
                RowLayout {
                    id: headerRow
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    // Centred within the CHROME budget (Theme.barHeight), not
                    // within the bar — the bar is taller than that whenever the
                    // toggle's caption is budgeted for, and centring in it would
                    // push the control line down as the reservation grew.
                    anchors.topMargin: (Theme.barHeight - height) / 2
                    anchors.leftMargin: Theme.gap
                    anchors.rightMargin: Theme.gap
                    // Exactly the control line. Every item in this row is
                    // rowHeightSm or smaller, so a row of that height centres
                    // them all on one baseline — and the toggle, which is top
                    // aligned and may be taller in Embedded, starts on that same
                    // line and grows downward past the row into the bar's
                    // reserved space rather than displacing anything.
                    height: Theme.rowHeightSm
                    spacing: Theme.gap

                    Text {
                        objectName: "headerTitle"
                        text: "Radicle"
                        color: Theme.text
                        font.pixelSize: Theme.fontXl
                        font.bold: true
                        // The last thing to go, and the only element here that
                        // may go COMPLETELY, because it is the only one that
                        // costs the user nothing: Basecamp's own chrome already
                        // says which module this is, so the word is a courtesy
                        // rather than information. Everything else in this row
                        // is either a control or the answer to a question the
                        // user has.
                        //
                        // Needed because the row's minimums genuinely exceed a
                        // narrow window: title 58 + toggle 226 + identity 120 +
                        // chip 66, plus gaps and margins, is ~542px, so at 480
                        // something has to yield entirely or the chip goes off
                        // the edge — which is the defect this whole change is
                        // about. The toggle cannot shrink (it is three labelled
                        // segments), the chip must not (it is the only way into
                        // Settings), and the identity is already eliding.
                        //
                        // Keyed on the bar's width rather than on a Layout
                        // minimum so the disappearance is a decision with a
                        // threshold, not an overflow — an element that vanishes
                        // because a layout ran out of room is exactly the
                        // silent failure being fixed here.
                        visible: headerRow.width > 520
                        Layout.preferredWidth: visible ? implicitWidth : 0
                        Layout.maximumWidth: visible ? implicitWidth : 0
                    }

                    // ONE control for "what am I browsing" — exactly three
                    // segments, one per mode, and nothing else in it.
                    //
                    // The mode used to be chosen only in Settings while this
                    // bar carried a two-segment `source` toggle AND a separate
                    // "Attached · z6Mko…" badge. Two vocabularies for one
                    // question, side by side, which a user read as a single
                    // control with a dead third segment. The badge is gone, the
                    // vocabularies are one, and the segment IS the mode.
                    SourceToggle {
                        id: sourceToggle
                        objectName: "sourceToggle"
                        // The toggle occupies exactly the control line in the
                        // ROW, and its caption hangs below that line into the
                        // space the bar reserves for it.
                        //
                        // All three constraints are load-bearing together:
                        //
                        //  - `AlignTop` so the item grows downward. A centred
                        //    item that grows pushes its own segment strip
                        //    upwards, off the line the title and identity are on
                        //    — the same misalignment this change fixes, arriving
                        //    in one mode instead of three.
                        //  - `maximumHeight` so the ROW does not grow with it. A
                        //    RowLayout takes its height from its tallest child,
                        //    so without this the Embedded caption made the row
                        //    72px and pushed every OTHER item down to centre in
                        //    it — the misalignment again, with the sign flipped.
                        //  - `preferredHeight` so it still gets the line it
                        //    needs rather than collapsing to nothing.
                        //
                        // The caption drawing outside the row is deliberate and
                        // safe: nothing here sets `clip`, and the bar is sized to
                        // contain it. tst_mode_switch.qml asserts that it lands
                        // inside the bar rather than past its edge.
                        Layout.alignment: Qt.AlignTop
                        Layout.preferredHeight: Theme.rowHeightSm
                        Layout.maximumHeight: Theme.rowHeightSm
                        mode:           root.mode
                        // Passed straight through, `undefined` included, and
                        // that is the point rather than a shortcut. This used
                        // to substitute `[]` for a missing value, which told
                        // the toggle "this build starts nothing" during the
                        // window before the first getCapabilities reply — an
                        // amber border and an unavailable marker on all three
                        // segments, Local included, on every launch. `[]` and
                        // "not yet known" are different claims and the toggle
                        // now distinguishes them; collapsing them here would
                        // put the regression back on this side of the
                        // boundary. See SourceToggle.startableModes.
                        startableModes: root.caps.startableModes
                        modeReason:     root.caps.modeUnavailableReason || ""
                        localAvailable: root.localAvailable
                        pathsProblem:   root.caps.pathsProblem || ""
                        reason: "No Radicle profile on this machine — "
                                + "install Radicle and run `rad auth` to browse local repositories."
                        onModeChosen: function (next) { root.setMode(next); }
                    }

                    // ---- the mode-detail slot -------------------------
                    //
                    // Immediately right of the toggle, showing exactly one
                    // thing at a time: the detail of whichever mode is
                    // selected. One rule a user learns once, instead of a
                    // header whose contents have to be memorised element by
                    // element.
                    //
                    //   Explore  -> which seed is being proxied to
                    //   Local    -> which identity you are operating as
                    //   Embedded -> nothing; there is no node yet, and the
                    //               toggle's own caption already explains that
                    //
                    // `SeedPicker` already worked this way (`visible:` keyed on
                    // the source), so this extends an existing pattern rather
                    // than inventing a parallel one.

                    SeedPicker {
                        id: seedPicker
                        objectName: "seedPicker"
                        // Which seed is proxied to is Explore's detail. Showing
                        // the picker in any other mode would imply it affects
                        // what is on screen, which it does not.
                        visible: root.mode === "explore"
                        currentSeed: root.caps.remoteSeed || ""
                        fetchSeeds: function (cb) {
                            root.callPlain("listKnownSeeds", [], cb);
                        }
                        onSeedChosen: function (url) {
                            // setRemoteSeed validates the seed and reverts to
                            // the previous one if it does not answer. Report
                            // that and put the picker back, rather than leaving
                            // it naming a seed whose data is not on screen —
                            // plenty of preferred seeds run the p2p node
                            // without the HTTP API.
                            root.setSeed(url);
                        }
                    }

                    // Local's detail. Absent — not blank, not a placeholder —
                    // in any other mode, because in Explore you are not
                    // operating as an identity at all and showing one there
                    // would be noise. Same reasoning as the Local segment being
                    // absent rather than disabled when there is no profile.
                    NodeIdentity {
                        id: nodeIdentity
                        objectName: "nodeIdentity"
                        // Two conditions, and they are different questions:
                        // this mode is the one the identity describes, AND
                        // there is an identity to describe. The component
                        // already hides itself for the second (it must, or a
                        // caller could render an empty slot); this adds the
                        // first.
                        visible: root.mode === "local" && nodeIdentity.nodeId !== ""
                        nodeId: root.caps.nodeId || ""
                        // The identity is the element that YIELDS when the
                        // window gets narrow, and it is the right one to pick:
                        // it is the only thing in this row whose content can be
                        // shortened without losing a destination. Clicking it
                        // still copies the whole DID, and Settings shows it in
                        // full — so the cost is legibility at a width where
                        // nothing else would have fit anyway.
                        //
                        // Everything else in the row is a fixed cost the row
                        // must simply carry, so with no yielder the row could
                        // not shrink below ~830px and the Settings chip — now
                        // the ONLY way into Settings, since this element copies
                        // instead of opening it — was pushed off the right edge
                        // entirely. See NodeIdentity.qml.
                        //
                        // The floor is ~14 monospace characters plus the
                        // ellipsis: enough to read `did:key:z6Mk…` and a few
                        // characters of tail. Below that the element would be
                        // saying nothing while still taking room, which is
                        // worse than the honest alternative of it being cut off
                        // — but it never gets there, because the chip's own
                        // minimum stops the row shrinking that far.
                        //
                        // Every Layout constraint is gated on `visible`, and
                        // that gate is not decoration: a RowLayout still
                        // reserves an explicit `Layout.minimumWidth` for a
                        // child that is NOT visible. Ungated, this element held
                        // 120px in Explore — where it is hidden — and the
                        // search field held its own 120px back in Local, so
                        // ~240px of the row was permanently spoken for by two
                        // items that were never both on screen. That alone put
                        // the Settings chip off the edge at 900px in Explore.
                        Layout.minimumWidth: visible ? 120 : 0
                        Layout.preferredWidth: visible ? implicitWidth : 0
                        Layout.maximumWidth: visible ? implicitWidth : 0
                        Layout.fillWidth: visible
                        minimumWidth: 120
                        // Clicking copies; the component does that itself and
                        // confirms it on screen. Nothing is wired here on
                        // purpose — it used to open Settings, and the user
                        // asked for copying instead. Settings is still reached
                        // through the chip at the right of this row, so no
                        // destination was lost.
                    }

                    Item { Layout.fillWidth: true }

                    FilterField {
                        id: searchField
                        // The local surface takes a scope, not a search string
                        // — see RepoList.fetch(). A search box that silently
                        // did nothing would be worse than no search box. Keyed
                        // on the derived method prefix rather than the mode,
                        // because it is the SURFACE that lacks search:
                        // `embedded` would have the same limitation.
                        visible: nav.view === "repos" && root.source === "remote"
                        // The other yielder, for the same reason and with the
                        // same shape as the identity above. In Explore this
                        // 260px field is what runs the row out of width, so a
                        // fix that only budgeted for Local's identity would
                        // leave the Settings chip off screen at ~640px here.
                        //
                        // A text field shrinks gracefully in a way a DID cannot:
                        // it scrolls its own content, so a narrow one still
                        // accepts and displays a query. 120px holds the
                        // placeholder's first words and a typed term.
                        //
                        // Gated on `visible` for the same reason as the
                        // identity: an invisible child still holds its declared
                        // minimum, so an ungated 120px here was being reserved
                        // in Local, where this field is hidden.
                        Layout.preferredWidth: visible ? 260 : 0
                        Layout.minimumWidth: visible ? 120 : 0
                        Layout.maximumWidth: visible ? 260 : 0
                        Layout.fillWidth: visible
                        placeholder: "Search repositories"
                        onAccepted: repoList.reload()
                    }

                    Rectangle {
                        Layout.preferredHeight: Theme.rowHeightSm
                        Layout.preferredWidth: settingsLabel.implicitWidth + Theme.gap * 2
                        // Never yields, and that is the whole point of this
                        // change. `Layout.minimumWidth` equal to the preferred
                        // width makes the chip incompressible, so the row
                        // shrinks its two flexible items instead of pushing
                        // this one past the right edge.
                        //
                        // A RowLayout that cannot fit its minimums OVERFLOWS —
                        // it does not scroll or wrap — and the item that goes
                        // is the last one, which is this. That is how Settings
                        // became unreachable below ~750px: the chip is the only
                        // way in now that the identity copies instead of
                        // opening it, so it is the one element here that must
                        // survive at any width. tst_header_width.qml drives the
                        // width down and asserts exactly that.
                        Layout.minimumWidth: settingsLabel.implicitWidth + Theme.gap * 2
                        radius: Theme.radiusSm
                        color: root.settingsOpen ? Theme.accentSoft : Theme.bg
                        border.width: 1
                        border.color: Theme.border

                        Text {
                            id: settingsLabel
                            anchors.centerIn: parent
                            text: "Settings"
                            color: root.settingsOpen ? Theme.text : Theme.textDim
                            font.pixelSize: Theme.fontSm
                        }

                        MouseArea {
                            objectName: "settingsToggle"
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.settingsOpen = !root.settingsOpen
                        }
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 1
                    color: Theme.border
                }
            }

            // ---- status strip (always present, fixed height) ----
            StatusStrip {
                Layout.fillWidth: true
                busy: nav.busy
                error: nav.error
            }

            // ---- body ----
            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: nav.view === "repos" ? 0 : 1

                RepoList {
                    id: repoList
                    app: root
                    query: searchField.text
                    onRepoActivated: function (r) { nav.openRepo(r); }
                }

                RepoView {
                    id: repoPage
                    app: root
                    rid: nav.rid
                    repo: nav.repo
                    active: nav.view === "repo"
                    onBack: nav.back()
                }
            }
        }

        // Settings overlay the body rather than replacing a StackLayout page:
        // they are orthogonal to where you are in the repository navigation,
        // and putting them in the stack would mean "back" from settings had to
        // decide which screen to restore.
        Rectangle {
            objectName: "settingsPane"
            visible: root.settingsOpen
            anchors.fill: parent
            color: Theme.bg

            SettingsPanel {
                id: settingsPanel
                objectName: "settingsPanel"
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width - Theme.gapLg * 2, 640)
                caps: root.caps
                fetchSettings: function (cb) {
                    root.callPlain("getSettings", [], cb);
                }
                saveSetting: function (key, value, cb) {
                    root.callSettings("setSetting", [key, value], cb);
                }
                // Closing just lowers the overlay. Because settings were never
                // pushed onto the navigation stack, the screen underneath is
                // untouched and the user lands exactly where they were — deep
                // inside a repository if that is where they came from. This is
                // the payoff for keeping `settingsOpen` out of NavState, and it
                // is why closing needs no decision about which screen to
                // restore.
                onClosed: root.settingsOpen = false
            }
        }

        // Pre-connection placeholder.
        Rectangle {
            anchors.fill: parent
            visible: !root.ready
            color: Theme.bg
            Text {
                anchors.centerIn: parent
                text: "Connecting to the Radicle module…"
                color: Theme.textDim
                font.pixelSize: Theme.fontLg
            }
        }
    }
}
