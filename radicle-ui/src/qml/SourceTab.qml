import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R

// File tree on the left, README or the selected file on the right.
Item {
    id: tab

    property var app: null
    property string rid: ""
    property string branch: ""

    /// Current directory, "" for the repository root.
    property string path: ""
    property string selectedFile: ""

    ListModel { id: entries }

    function load() {
        path = "";
        selectedFile = "";
        loadTree("");
        loadReadme();
    }

    function loadTree(p) {
        if (!app || rid === "") return;
        app.call("GetTree", [rid, branch, p], function (data) {
            entries.clear();
            tab.path = p;
            var list = data.entries || [];
            // Directories first, then files; each alphabetical.
            list.sort(function (a, b) {
                if (a.kind !== b.kind) return a.kind === "tree" ? -1 : 1;
                return a.name.localeCompare(b.name);
            });
            for (var i = 0; i < list.length; i++)
                entries.append(list[i]);
        });
    }

    function loadReadme() {
        if (!app || rid === "") return;
        app.call("GetReadme", [rid, branch], function (data) {
            viewer.title = data.path || "README";
            viewer.body = data.content || "";
        }, function () {
            // Plenty of repos have no README; that is not an error worth showing.
            viewer.title = "";
            viewer.body = "";
        });
    }

    function openEntry(entry) {
        if (entry.kind === "tree") {
            loadTree(entry.path);
        } else {
            tab.selectedFile = entry.path;
            app.call("GetBlob", [rid, branch, entry.path], function (data) {
                viewer.title = data.path || entry.path;
                viewer.body = data.binary
                            ? "(binary file — " + (data.name || entry.name) + ")"
                            : (data.content || "");
            });
        }
    }

    function goUp() {
        var i = path.lastIndexOf("/");
        loadTree(i < 0 ? "" : path.substring(0, i));
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // --- tree ---------------------------------------------------------
        Rectangle {
            Layout.preferredWidth: 280
            Layout.fillHeight: true
            color: Theme.panel

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    color: Theme.panelAlt
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        spacing: 6
                        Label {
                            text: tab.path === "" ? "/" : "/" + tab.path
                            color: Theme.textDim
                            font.pixelSize: 10
                            font.family: Theme.mono
                            elide: Text.ElideLeft
                            Layout.fillWidth: true
                        }
                    }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    ListView {
                        model: entries
                        spacing: 0

                        header: ItemDelegate {
                            width: parent ? parent.width : 0
                            height: tab.path === "" ? 0 : 26
                            visible: tab.path !== ""
                            onClicked: tab.goUp()
                            background: Rectangle {
                                color: parent.hovered ? Theme.panelAlt : "transparent"
                            }
                            contentItem: Label {
                                leftPadding: 8
                                text: "../"
                                color: Theme.textDim
                                font.pixelSize: 12
                                font.family: Theme.mono
                                verticalAlignment: Text.AlignVCenter
                            }
                        }

                        delegate: ItemDelegate {
                            required property string name
                            required property string kind
                            required property string path

                            width: ListView.view.width
                            height: 26
                            onClicked: tab.openEntry({ name: name, kind: kind, path: path })

                            background: Rectangle {
                                color: tab.selectedFile === path ? Theme.panelAlt
                                     : (parent.hovered ? Theme.panelAlt : "transparent")
                            }
                            contentItem: RowLayout {
                                spacing: 6
                                Label {
                                    leftPadding: 8
                                    text: kind === "tree" ? "▸" : "·"
                                    color: kind === "tree" ? Theme.accent : Theme.textDim
                                    font.pixelSize: 11
                                }
                                Label {
                                    text: name
                                    color: Theme.text
                                    font.pixelSize: 12
                                    font.family: Theme.mono
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                        }
                    }
                }
            }
        }

        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.border }

        // --- file / readme -------------------------------------------------
        FileViewer {
            id: viewer
            Layout.fillWidth: true
            Layout.fillHeight: true
        }
    }
}
