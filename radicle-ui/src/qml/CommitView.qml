import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

/*
 * One commit: its message, author, and the diff.
 *
 * The seed returns `diff.files[]`, each carrying `path`, `status` and `hunks[]`
 * of typed lines (`addition`, `deletion`, `context`) with old/new line numbers.
 * Rendering is plain monospace with a coloured gutter — the seed sends raw
 * text, not the pre-tokenized lines Radicle Desktop gets from its Rust
 * backend, so a half-working highlighter would be worse than none.
 */
Item {
    id: view

    property var app: null
    property string rid: ""
    property string sha: ""

    property var data: null
    property bool loading: false
    property bool loadedOnce: false

    signal back()

    onShaChanged: load()

    function load() {
        data = null;
        loadedOnce = false;
        if (!app || rid === "" || sha === "") return;

        loading = true;
        var wantSha = sha;
        var wantRid = rid;
        app.call("GetCommit", [rid, sha], function (d) {
            // Same guard as every other loader: drop a reply for a commit or
            // repository the user has already navigated away from.
            if (view.sha !== wantSha || view.rid !== wantRid) return;
            view.loading = false;
            view.loadedOnce = true;
            view.data = d;
        }, function () {
            if (view.sha !== wantSha || view.rid !== wantRid) return;
            view.loading = false;
            view.loadedOnce = true;
        });
    }

    readonly property var commit: data && data.commit ? data.commit : null
    readonly property var files: data && data.diff && data.diff.files
                                 ? data.diff.files : []
    readonly property var stats: data && data.diff && data.diff.stats
                                 ? data.diff.stats : null

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- header (fixed height, so it does not move as the diff loads) ----
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.headerHeight
            color: Theme.surface

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.gap
                spacing: Theme.gap

                Rectangle {
                    objectName: "commitBackButton"
                    Layout.preferredWidth: 68
                    Layout.preferredHeight: 28
                    radius: Theme.radius
                    color: backMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                    border.color: Theme.border
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "‹  Back"
                        color: Theme.text
                        font.pixelSize: Theme.fontMd
                    }
                    MouseArea {
                        id: backMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: view.back()
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: view.commit ? (view.commit.summary || "") : ""
                        color: Theme.text
                        font.pixelSize: Theme.fontLg
                        font.bold: true
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        text: view.commit
                              ? R.authorName(view.commit.author) + " · "
                                + R.when(view.commit.committer ? view.commit.committer.time : 0)
                              : ""
                        color: Theme.textFaint
                        font.pixelSize: Theme.fontXs
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }

                // Insertions and deletions, when the seed reports them.
                Row {
                    spacing: Theme.gapSm
                    visible: view.stats !== null
                    Layout.alignment: Qt.AlignVCenter
                    Text {
                        text: view.stats ? "+" + (view.stats.insertions || 0) : ""
                        color: Theme.good
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.mono
                    }
                    Text {
                        text: view.stats ? "−" + (view.stats.deletions || 0) : ""
                        color: Theme.bad
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.mono
                    }
                }

                Rectangle {
                    Layout.preferredWidth: shaText.implicitWidth + 16
                    Layout.preferredHeight: 20
                    radius: Theme.radiusSm
                    color: Theme.surfaceAlt
                    Text {
                        id: shaText
                        anchors.centerIn: parent
                        text: R.short(view.sha, 7)
                        color: Theme.accent
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.mono
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.border
            }
        }

        // ---- diff ----
        ListView {
            id: fileList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 0
            model: view.files
            cacheBuffer: 4000
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            // One file, with its hunks flattened into lines.
            delegate: Column {
                required property var modelData
                width: fileList.width

                // File header.
                Rectangle {
                    width: parent.width
                    height: Theme.rowHeightSm
                    color: Theme.surfaceAlt

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.gap
                        spacing: Theme.gapSm

                        Text {
                            text: modelData.path || ""
                            color: Theme.text
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.mono
                        }
                        Text {
                            text: modelData.status || ""
                            color: modelData.status === "added" ? Theme.good
                                 : modelData.status === "deleted" ? Theme.bad
                                 : Theme.textFaint
                            font.pixelSize: Theme.fontXs
                        }
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width; height: 1
                        color: Theme.border
                    }
                }

                // Hunks.
                Repeater {
                    model: (modelData.diff && modelData.diff.hunks)
                           ? modelData.diff.hunks : []

                    delegate: Column {
                        required property var modelData
                        width: fileList.width

                        Rectangle {
                            width: parent.width
                            height: 20
                            color: Theme.bg
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                x: Theme.gap
                                text: (modelData.header || "").replace(/\n$/, "")
                                color: Theme.accent
                                font.pixelSize: Theme.fontXs
                                font.family: Theme.mono
                            }
                        }

                        Repeater {
                            model: modelData.lines || []

                            delegate: Rectangle {
                                required property var modelData
                                width: fileList.width
                                height: 18

                                readonly property bool added: modelData.type === "addition"
                                readonly property bool removed: modelData.type === "deletion"

                                color: added   ? Qt.rgba(0.25, 0.73, 0.31, 0.10)
                                     : removed ? Qt.rgba(0.97, 0.32, 0.29, 0.10)
                                     : Theme.bg

                                Row {
                                    anchors.fill: parent
                                    spacing: 0

                                    // Line numbers, fixed width so the code
                                    // column starts at the same x on every row.
                                    Text {
                                        width: 44
                                        height: parent.height
                                        text: modelData.lineNoOld !== undefined
                                              ? modelData.lineNoOld : ""
                                        color: Theme.textFaint
                                        font.pixelSize: Theme.fontXs
                                        font.family: Theme.mono
                                        horizontalAlignment: Text.AlignRight
                                        verticalAlignment: Text.AlignVCenter
                                        rightPadding: 6
                                    }
                                    Text {
                                        width: 44
                                        height: parent.height
                                        text: modelData.lineNoNew !== undefined
                                              ? modelData.lineNoNew : ""
                                        color: Theme.textFaint
                                        font.pixelSize: Theme.fontXs
                                        font.family: Theme.mono
                                        horizontalAlignment: Text.AlignRight
                                        verticalAlignment: Text.AlignVCenter
                                        rightPadding: 6
                                    }
                                    Text {
                                        width: 14
                                        height: parent.height
                                        text: added ? "+" : removed ? "−" : " "
                                        color: added ? Theme.good
                                             : removed ? Theme.bad : Theme.textFaint
                                        font.pixelSize: Theme.fontSm
                                        font.family: Theme.mono
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    Text {
                                        width: parent.width - 102
                                        height: parent.height
                                        text: (modelData.line || "").replace(/\n$/, "")
                                        color: Theme.text
                                        font.pixelSize: Theme.fontSm
                                        font.family: Theme.mono
                                        verticalAlignment: Text.AlignVCenter
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    LoadingState {
        anchors.fill: parent
        loading: view.loading
        loaded: view.loadedOnce
        count: view.files.length
        emptyText: view.loadedOnce && view.data ? "No changes in this commit"
                                                : "Could not load this commit"
        loadingText: "Loading commit…"
    }
}
