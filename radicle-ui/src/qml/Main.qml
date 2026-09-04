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

    // Which source every browsing call goes to: "remote" (a seed node over
    // HTTPS) or "local" (this machine's ~/.radicle, read in-process).
    //
    // One property rather than a parameter at each of the fourteen call sites.
    // The two sources answer different questions — a seed sees only public
    // repos it replicates, the local node sees your private ones and works
    // offline — but they return identical JSON, so every view renders either
    // without branching. That is the contract radicle_impl.h states, and it is
    // what lets this be a single switch instead of a second set of views.
    property string source: "remote"

    /// True when this machine has a Radicle profile to browse. Drives whether
    /// the source toggle appears at all: offering "Local" to someone with no
    /// node would be a control that can only produce an error.
    readonly property bool localAvailable: caps.localAvailable === true

    /// Switch source and start over. A repo id from one source is meaningless
    /// to the other — the seed's repos are not the local node's — so the whole
    /// navigation stack resets rather than trying to carry the current screen
    /// across.
    ///
    /// `nav.reset()` clears navigation state but does NOT refetch: NavState is
    /// a pure state holder and the caller owns reloading, which is why
    /// `onBackendReady` and `setSeed` both call `repoList.reload()` alongside
    /// it. Omitting it here left the list showing the previous source's
    /// repositories — or, switching to local first, nothing at all, because
    /// no local request was ever issued.
    function setSource(next) {
        if (next === source) return;
        if (next === "local" && !localAvailable) return;
        source = next;
        nav.reset();
        repoList.reload();
    }

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
        var name = (source || root.source) + method;
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
    readonly property string branchLabel:       repoPage.branchLabel
    /// See RepoView.branchPickerItem: a ComboBox's popup delegates live in a
    /// separate window and cannot be clicked by objectName, so the branch spec
    /// emits the picker's own `activated` signal instead.
    readonly property var    branchPickerItem:  repoPage.branchPickerItem

    // Detail views. "" when the tabs are showing.
    readonly property string openThread: repoPage.openThread
    readonly property string openCommit: repoPage.openCommit

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
                Layout.preferredHeight: Theme.barHeight
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

                    SourceToggle {
                        id: sourceToggle
                        objectName: "sourceToggle"
                        current: root.source
                        localAvailable: root.localAvailable
                        reason: "No Radicle profile on this machine — "
                                + "install Radicle and run `rad auth` to browse local repositories"
                        onSourceChosen: function (next) { root.setSource(next); }
                    }

                    SeedPicker {
                        id: seedPicker
                        objectName: "seedPicker"
                        // Which seed is proxied to is a remote-source concern;
                        // showing the picker while browsing local storage would
                        // imply it affects what is on screen, which it does not.
                        visible: root.source === "remote"
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

                    Item { Layout.fillWidth: true }

                    FilterField {
                        id: searchField
                        // Local listing takes a scope, not a search string —
                        // see RepoList.fetch(). A search box that silently did
                        // nothing would be worse than no search box.
                        visible: nav.view === "repos" && root.source === "remote"
                        Layout.preferredWidth: 260
                        placeholder: "Search repositories"
                        onAccepted: repoList.reload()
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
