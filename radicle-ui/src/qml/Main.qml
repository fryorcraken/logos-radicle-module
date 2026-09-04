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
    function setSource(next) {
        if (next === source) return;
        if (next === "local" && !localAvailable) return;
        source = next;
        nav.reset();
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
            nav.error = "unsupported operation: " + name;
            if (onFail) onFail();
            return;
        }
        // Deliberately does NOT clear nav.error on the way in. Clearing on
        // every request start meant a later request erased an earlier one's
        // error, so during a sync — dozens of parallel fetches — an error was
        // effectively unobservable. Errors clear on success, and on navigation.
        nav.inflight++;
        logos.watch(backend[name].apply(backend, args), function (text) {
            nav.inflight--;
            var r = R.parse(text);
            if (r.ok) {
                nav.error = "";
                onOk(r.data);
            } else {
                nav.error = r.error;
                if (onFail) onFail();
            }
        }, function (err) {
            nav.inflight--;
            nav.error = String(err);
            if (onFail) onFail();
        });
    }

    /// Switch the remote seed, surfacing a failure instead of silently
    /// keeping the old data under the new seed's name.
    function setSeed(url) {
        if (!backend) return;
        nav.inflight++;
        logos.watch(backend.setRemoteSeed(url), function (text) {
            nav.inflight--;
            var r = R.parse(text);
            if (r.ok) {
                nav.reset();
            } else {
                nav.error = "Cannot use " + url + ": " + r.error;
                // Snap the picker back to the seed actually in use.
                seedPicker.currentSeed = Qt.binding(function () {
                    return root.caps.remoteSeed || "";
                });
                seedPicker.syncSelection();
            }
        }, function (err) {
            nav.inflight--;
            nav.error = String(err);
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

    /// Open a repository object directly (deep links and testing).
    function openRepoExternal(repo) {
        if (repo && repo.rid) nav.openRepo(repo);
    }

    // ---- navigation state -------------------------------------------------

    QtObject {
        id: nav
        property string view: "repos"      // repos | repo
        property string rid: ""
        property var repo: null
        // A counter, not a flag. Concurrent requests are the norm here —
        // SourceTab.load() fires two, syncAll() fires dozens — and with a
        // boolean the first reply to land cleared the strip while the rest
        // were still in flight.
        property int inflight: 0
        readonly property bool busy: inflight > 0
        property string error: ""

        function reset() {
            view = "repos"; rid = ""; repo = null; error = ""; inflight = 0;
            repoList.reload();
        }
        function openRepo(r) {
            rid = r.rid; repo = r; view = "repo";
        }
        function back() {
            view = "repos"; rid = ""; repo = null; error = "";
        }
    }

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
