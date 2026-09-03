import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R

Item {
    id: tab
    property var app: null
    property string rid: ""
    property string branch: ""
    property int page_: 0
    property bool hasMore: false
    property bool loading: false
    property bool loadedOnce: false

    ListModel { id: commits }

    /// Commits currently listed — read by the UI tests.
    readonly property int count: commits.count

    function load() {
        page_ = 0; commits.clear(); loadedOnce = false; fetch();
    }

    function fetch() {
        if (!app || rid === "") return;
        tab.loading = true;
        app.call("ListCommits", [rid, branch, page_, 50], function (data) {
            tab.loading = false; tab.loadedOnce = true;
            var items = data.items || [];
            for (var i = 0; i < items.length; i++)
                commits.append({ c: items[i] });
            tab.hasMore = !!data.hasMore;
        }, function () { tab.loading = false; tab.loadedOnce = true; });
    }

    ListView {
        id: list
        anchors.fill: parent
        model: commits
        clip: true
        spacing: 0
        cacheBuffer: Theme.rowHeight * 12
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
            required property var c
            width: list.width
            height: Theme.rowHeight
            color: rowMouse.containsMouse ? Theme.surfaceAlt : Theme.bg
            Behavior on color { ColorAnimation { duration: Theme.animFast } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.gap
                spacing: Theme.gap

                Avatar {
                    seed: c.author ? (c.author.email || c.author.name || "") : ""
                    size: 26
                    Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: c.summary || ""
                        color: Theme.text
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        text: R.authorName(c.author)
                              + " · " + R.when(c.committer ? c.committer.time : 0)
                        color: Theme.textFaint
                        font.pixelSize: Theme.fontXs
                        elide: Text.ElideRight
                        Layout.fillWidth: true
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
                        text: R.short(c.id, 7)
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

            MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true }
        }

        footer: Item {
            width: list.width
            height: tab.hasMore ? 52 : 0
            visible: tab.hasMore
            Button {
                anchors.centerIn: parent
                text: "Load more"
                onClicked: { tab.page_++; tab.fetch(); }
                background: Rectangle {
                    implicitWidth: 110; implicitHeight: 28
                    radius: Theme.radius
                    color: parent.hovered ? Theme.surfaceAlt : Theme.surface
                    border.color: Theme.border; border.width: 1
                }
                contentItem: Text {
                    text: parent.text; color: Theme.text
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: commits.count === 0 && tab.loadedOnce && !tab.loading
        text: "No commits"
        color: Theme.textDim
        font.pixelSize: Theme.fontLg
    }
}
