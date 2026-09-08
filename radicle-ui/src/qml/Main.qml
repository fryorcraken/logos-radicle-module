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
    readonly property bool   modeStartable: caps.modeStartable !== false
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
                Layout.preferredHeight: Math.max(Theme.barHeight,
                                                 sourceToggle.implicitHeight + Theme.gap)
                color: Theme.surface

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.gap
                    anchors.rightMargin: Theme.gap
                    spacing: Theme.gap

                    Text {
                        text: "Radicle"
                        color: Theme.text
                        font.pixelSize: Theme.fontXl
                        font.bold: true
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
                        mode:           root.mode
                        startableModes: root.caps.startableModes !== undefined
                                        ? root.caps.startableModes : []
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
                        // The obvious destination for someone squinting at a
                        // truncated DID: Settings holds it in full, alongside
                        // the resolved home.
                        onActivated: root.settingsOpen = true
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
                        Layout.preferredWidth: 260
                        placeholder: "Search repositories"
                        onAccepted: repoList.reload()
                    }

                    Rectangle {
                        Layout.preferredHeight: Theme.rowHeightSm
                        Layout.preferredWidth: settingsLabel.implicitWidth + Theme.gap * 2
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
