import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

// Issues for one repository, filterable by state.
Item {
    id: tab

    // A StackLayout child: must fill, or it is sized 0x0.
    Layout.fillWidth: true
    Layout.fillHeight: true
    property var app: null
    property string rid: ""
    property string status: "open"
    property int page_: 0
    property bool hasMore: false
    property bool loading: false
    property bool loadedOnce: false

    readonly property var states: ["open", "closed"]

    ListModel { id: items }

    /// Clear without fetching — used when the repository changes.
    function reset() {
        page_ = 0; items.clear(); loadedOnce = false; hasMore = false; loading = false;
    }

    function load() {
        reset(); fetch();
    }

    function fetch() {
        if (!app || rid === "") return;
        tab.loading = true;
        app.call("ListIssues", [rid, tab.status, page_, 50], function (data) {
            tab.loading = false; tab.loadedOnce = true;
            var list = data.items || [];
            for (var i = 0; i < list.length; i++)
                items.append({ item: list[i] });
            tab.hasMore = !!data.hasMore;
        }, function () { tab.loading = false; tab.loadedOnce = true; });
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        FilterChips {
            Layout.fillWidth: true
            states: tab.states
            current: tab.status
            onPicked: function (s) { tab.status = s; tab.load(); }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: items
            clip: true
            spacing: 0
            cacheBuffer: Theme.rowHeight * 12
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
                required property var item
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
                        seed: item.author ? (item.author.id || "") : ""
                        size: 26
                        Layout.alignment: Qt.AlignVCenter
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            text: item.title || "(untitled)"
                            color: Theme.text
                            font.pixelSize: Theme.fontMd
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Text {
                            text: R.short(item.id, 7) + " · " + R.authorName(item.author)
                            color: Theme.textFaint
                            font.pixelSize: Theme.fontXs
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }

                    StatusBadge {
                        status: R.statusOf(item)
                        Layout.alignment: Qt.AlignVCenter
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
    }

    Text {
        anchors.centerIn: parent
        visible: items.count === 0 && tab.loadedOnce && !tab.loading
        text: "No issues"
        color: Theme.textDim
        font.pixelSize: Theme.fontLg
    }
}
