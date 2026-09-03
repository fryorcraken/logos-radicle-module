import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R

/*
 * File tree on the left, README or the selected file on the right.
 *
 * Two things keep this from jumping the way it used to:
 *  - The sidebar is a FIXED width and rows are a FIXED height, so the tree
 *    does not resize itself as names or directory depth change.
 *  - Blob contents are cached and directories are prefetched on hover, so
 *    clicking a file usually paints from cache with no intermediate
 *    empty-then-fill flash.
 */
Item {
    id: tab

    property var app: null
    property string rid: ""
    property string branch: ""

    /// Current directory, "" for the repository root.
    property string path: ""
    property string selectedFile: ""

    /// path -> content, so revisiting a file is instant.
    property var blobCache: ({})
    /// path -> entries array, so going back up a directory is instant.
    property var treeCache: ({})

    ListModel { id: entries }

    /// Entries in the current directory — read by the UI tests.
    readonly property int entryCount: entries.count

    function load() {
        path = "";
        selectedFile = "";
        blobCache = ({});
        treeCache = ({});
        loadTree("");
        loadReadme();
    }

    function applyEntries(list) {
        entries.clear();
        // Directories first, then files; each alphabetical.
        var sorted = list.slice().sort(function (a, b) {
            if (a.kind !== b.kind) return a.kind === "tree" ? -1 : 1;
            return a.name.localeCompare(b.name);
        });
        for (var i = 0; i < sorted.length; i++)
            entries.append(sorted[i]);
    }

    function loadTree(p) {
        if (!app || rid === "") return;

        if (treeCache[p] !== undefined) {
            tab.path = p;
            applyEntries(treeCache[p]);
            return;
        }
        app.call("GetTree", [rid, branch, p], function (data) {
            var list = data.entries || [];
            treeCache[p] = list;
            tab.path = p;
            applyEntries(list);
        });
    }

    function loadReadme() {
        if (!app || rid === "") return;
        app.call("GetReadme", [rid, branch], function (data) {
            viewer.title = data.path || "README";
            viewer.body = data.content || "";
        }, function () {
            // Plenty of repos have no README; not an error worth showing.
            viewer.title = "";
            viewer.body = "";
        });
    }

    function openEntry(entry) {
        if (entry.kind === "tree") {
            loadTree(entry.path);
            return;
        }

        tab.selectedFile = entry.path;

        var cached = blobCache[entry.path];
        if (cached !== undefined) {
            viewer.title = entry.path;
            viewer.body = cached;
            return;
        }

        app.call("GetBlob", [rid, branch, entry.path], function (data) {
            var body = data.binary
                     ? "(binary file — " + (data.name || entry.name) + ")"
                     : (data.content || "");
            blobCache[entry.path] = body;
            // Only paint if this is still the file the user wants; a slow
            // reply for an earlier click must not overwrite a later one.
            if (tab.selectedFile === entry.path) {
                viewer.title = entry.path;
                viewer.body = body;
            }
        });
    }

    /// Warm the cache for a row the pointer is resting on, so the click that
    /// usually follows paints immediately.
    function prefetch(entry) {
        if (!app || rid === "" || entry.kind === "tree") return;
        if (blobCache[entry.path] !== undefined) return;
        app.call("GetBlob", [rid, branch, entry.path], function (data) {
            blobCache[entry.path] = data.binary
                ? "(binary file — " + (data.name || entry.name) + ")"
                : (data.content || "");
        }, function () {});
    }

    function goUp() {
        var i = path.lastIndexOf("/");
        loadTree(i < 0 ? "" : path.substring(0, i));
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---- tree (fixed width) ----
        Rectangle {
            Layout.preferredWidth: Theme.sidebarWidth
            Layout.minimumWidth: Theme.sidebarWidth
            Layout.maximumWidth: Theme.sidebarWidth
            Layout.fillHeight: true
            color: Theme.surface

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // Breadcrumb (fixed height).
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.rowHeightSm
                    color: Theme.surfaceAlt
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.gapSm
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.gapSm
                        text: tab.path === "" ? "/" : "/" + tab.path
                        color: Theme.textDim
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.mono
                        elide: Text.ElideLeft
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width; height: 1
                        color: Theme.border
                    }
                }

                ListView {
                    id: treeList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: entries
                    clip: true
                    spacing: 0
                    cacheBuffer: Theme.rowHeightSm * 40
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    header: Item {
                        width: treeList.width
                        height: tab.path === "" ? 0 : Theme.rowHeightSm
                        visible: tab.path !== ""
                        Rectangle {
                            anchors.fill: parent
                            color: upMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.gapSm
                            text: "../"
                            color: Theme.textDim
                            font.pixelSize: Theme.fontMd
                            font.family: Theme.mono
                        }
                        MouseArea {
                            id: upMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tab.goUp()
                        }
                    }

                    delegate: Rectangle {
                        required property string name
                        required property string kind
                        required property string path

                        readonly property bool selected: tab.selectedFile === path

                        width: treeList.width
                        height: Theme.rowHeightSm
                        color: selected ? Theme.raised
                             : (rowMouse.containsMouse ? Theme.surfaceAlt : "transparent")
                        Behavior on color { ColorAnimation { duration: Theme.animFast } }

                        // Selection marker on the left edge.
                        Rectangle {
                            anchors.left: parent.left
                            width: 2
                            height: parent.height
                            color: parent.selected ? Theme.accent : "transparent"
                        }

                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.gapSm
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.gapSm
                            spacing: Theme.gapSm

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 10
                                text: kind === "tree" ? "▸" : "·"
                                color: kind === "tree" ? Theme.accent : Theme.textFaint
                                font.pixelSize: Theme.fontSm
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 26
                                text: name
                                color: parent.parent.selected ? Theme.text : Theme.textDim
                                font.pixelSize: Theme.fontMd
                                font.family: Theme.mono
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tab.openEntry({ name: name, kind: kind, path: path })
                            onEntered: prefetchTimer.restart()
                            onExited: prefetchTimer.stop()

                            Timer {
                                id: prefetchTimer
                                interval: 220     // don't fetch on a passing cursor
                                onTriggered: tab.prefetch({ name: rowMouse.parent.name,
                                                            kind: rowMouse.parent.kind,
                                                            path: rowMouse.parent.path })
                            }
                        }
                    }
                }
            }
        }

        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.border }

        // ---- file / readme ----
        FileViewer {
            id: viewer
            Layout.fillWidth: true
            Layout.fillHeight: true
        }
    }
}
