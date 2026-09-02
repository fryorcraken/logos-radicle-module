import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R

/*
 * Radicle browser.
 *
 * The view holds no Radicle logic: every call is a pass-through to the
 * radicle_ui backend, which forwards to the `radicle` core module. QML's job
 * is navigation and rendering.
 *
 * Two sources, kept visibly distinct because they answer different questions:
 *   Remote — any public repo on a seed node, no local install needed.
 *   Local  — this machine's own node, including private repos.
 */
Item {
    id: root

    implicitWidth: 1000
    implicitHeight: 700

    // ---- backend wiring ---------------------------------------------------

    readonly property var backend: (typeof logos !== "undefined" && logos)
                                   ? logos.module("radicle_ui") : null
    property bool ready: false

    readonly property string capsJson: backend ? backend.capabilities : ""
    property var caps: ({})

    // "remote" | "local"
    property string source: "remote"
    readonly property bool localUsable: !!caps.localAvailable

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
                if (root.ready) nav.reset();
            }
        }
    }

    Component.onCompleted: {
        ready = backend !== null
                && (typeof logos !== "undefined")
                && logos.isViewModuleReady("radicle_ui");
        if (ready) nav.reset();
    }

    /// Single entry point for backend calls, so every view gets the same
    /// source routing and the same error handling.
    function call(method, args, onOk, onFail) {
        if (!backend) return;
        var name = (root.source === "local" ? "local" : "remote") + method;
        if (typeof backend[name] !== "function") {
            nav.error = "unsupported operation: " + name;
            if (onFail) onFail();
            return;
        }
        nav.busy = true;
        nav.error = "";
        logos.watch(backend[name].apply(backend, args), function (text) {
            nav.busy = false;
            var r = R.parse(text);
            if (r.ok) {
                onOk(r.data);
            } else {
                nav.error = r.error;
                if (onFail) onFail();
            }
        }, function (err) {
            nav.busy = false;
            nav.error = String(err);
            if (onFail) onFail();
        });
    }

    /// Neutral calls that exist on the backend without a source prefix.
    function callPlain(method, args, onOk) {
        if (!backend) return;
        logos.watch(backend[method].apply(backend, args), function (text) {
            var r = R.parse(text);
            if (r.ok) onOk(r.data);
        }, function () {});
    }

    /// Open a repository object directly (used for deep links and testing).
    function openRepoExternal(repo) {
        if (repo && repo.rid) nav.openRepo(repo);
    }

    // ---- navigation state -------------------------------------------------

    QtObject {
        id: nav
        property string view: "repos"      // repos | repo
        property string rid: ""
        property var repo: null
        property bool busy: false
        property string error: ""

        function reset() {
            view = "repos";
            rid = "";
            repo = null;
            error = "";
            repoList.reload();
        }

        function openRepo(r) {
            rid = r.rid;
            repo = r;
            view = "repo";
        }

        function back() {
            view = "repos";
            rid = "";
            repo = null;
            error = "";
        }
    }

    // ---- chrome -----------------------------------------------------------

    Rectangle {
        anchors.fill: parent
        color: Theme.bg

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // Top bar: source switch, seed picker, search.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 52
                color: Theme.panel

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.pad
                    anchors.rightMargin: Theme.pad
                    spacing: Theme.gap

                    Label {
                        text: "Radicle"
                        color: Theme.text
                        font.pixelSize: 16
                        font.bold: true
                    }

                    // Source switch. Local is disabled (with a reason) rather
                    // than hidden, so the capability is discoverable.
                    Row {
                        spacing: 0
                        Repeater {
                            model: [
                                { key: "remote", label: "Any repo" },
                                { key: "local",  label: "My node" }
                            ]
                            delegate: Button {
                                required property var modelData
                                text: modelData.label
                                checkable: true
                                checked: root.source === modelData.key
                                enabled: modelData.key === "remote" || root.localUsable
                                ToolTip.visible: hovered && !enabled
                                ToolTip.text: "No local Radicle node detected"
                                onClicked: {
                                    if (root.source === modelData.key) return;
                                    root.source = modelData.key;
                                    nav.reset();
                                }
                                background: Rectangle {
                                    color: parent.checked ? Theme.accent
                                         : (parent.enabled ? Theme.panelAlt : Theme.panel)
                                    radius: Theme.radius
                                    border.color: Theme.border
                                    border.width: 1
                                }
                                contentItem: Text {
                                    text: parent.text
                                    color: parent.checked ? "#0d1117"
                                         : (parent.enabled ? Theme.text : Theme.textDim)
                                    font.pixelSize: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }

                    SeedPicker {
                        visible: root.source === "remote"
                        currentSeed: root.caps.remoteSeed || ""
                        fetchSeeds: function (cb) {
                            root.callPlain("listKnownSeeds", [], cb);
                        }
                        onSeedChosen: function (url) {
                            root.callPlain("setRemoteSeed", [url], function () {
                                nav.reset();
                            });
                        }
                    }

                    Item { Layout.fillWidth: true }

                    TextField {
                        id: searchField
                        visible: nav.view === "repos"
                        Layout.preferredWidth: 240
                        placeholderText: root.source === "local"
                                         ? "Filter your repositories"
                                         : "Search repositories"
                        color: Theme.text
                        background: Rectangle {
                            color: Theme.panelAlt
                            radius: Theme.radius
                            border.color: searchField.activeFocus ? Theme.accent : Theme.border
                            border.width: 1
                        }
                        onAccepted: repoList.reload()
                    }
                }
            }

            // Status strip: busy / error / where you are.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? 26 : 0
                visible: nav.busy || nav.error !== ""
                color: nav.error !== "" ? "#3d1d1d" : Theme.panelAlt

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.pad
                    spacing: Theme.gap
                    Label {
                        text: nav.error !== "" ? nav.error : "Loading…"
                        color: nav.error !== "" ? Theme.bad : Theme.textDim
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
            }

            // Body.
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
            Label {
                anchors.centerIn: parent
                text: "Connecting to the Radicle module…"
                color: Theme.textDim
            }
        }
    }
}
