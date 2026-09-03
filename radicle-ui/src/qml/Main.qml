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

    // Only the remote (seed-node) source exists. Local-node browsing needs a
    // backend that is not written yet, and a disabled control for it was a
    // placeholder that looked like a broken feature.
    readonly property string source: "remote"

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
    /// `source` defaults to "remote" — every call site today browses via a
    /// seed node. Threading it through now, ahead of any caller actually
    /// needing "local", is cheaper than retrofitting a source parameter
    /// across every call site once M2 adds local-node browsing.
    function call(method, args, onOk, onFail, source) {
        if (!backend) return;
        var name = (source || "remote") + method;
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

                    SeedPicker {
                        id: seedPicker
                        objectName: "seedPicker"
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
                        visible: nav.view === "repos"
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
