import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R

// Patches for one repository, filterable by state.
Item {
    id: tab
    property var app: null
    property string rid: ""
    property string status: "open"
    property int page_: 0
    property bool hasMore: false

    readonly property var states: ["open", "merged", "archived", "draft"]

    ListModel { id: items }

    function load() {
        page_ = 0;
        items.clear();
        fetch();
    }

    function fetch() {
        if (!app || rid === "") return;
        app.call("ListPatches", [rid, tab.status, page_, 50], function (data) {
            var list = data.items || [];
            for (var i = 0; i < list.length; i++)
                items.append({ item: list[i] });
            tab.hasMore = !!data.hasMore;
        });
    }

    function colorFor(s) {
        if (s === "open")     return Theme.good;
        if (s === "merged")   return Theme.merged;
        if (s === "draft")    return Theme.textDim;
        if (s === "archived") return Theme.warn;
        return Theme.bad;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // State filter.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            color: Theme.bg
            Row {
                anchors.verticalCenter: parent.verticalCenter
                x: Theme.pad
                spacing: 6
                Repeater {
                    model: tab.states
                    delegate: Button {
                        required property string modelData
                        height: 22
                        checkable: true
                        checked: tab.status === modelData
                        onClicked: { tab.status = modelData; tab.load(); }
                        background: Rectangle {
                            color: parent.checked ? Theme.panelAlt : "transparent"
                            radius: 11
                            border.color: parent.checked ? Theme.border : "transparent"
                            border.width: 1
                        }
                        contentItem: Text {
                            leftPadding: 8
                            rightPadding: 8
                            text: modelData
                            color: parent.checked ? Theme.text : Theme.textDim
                            font.pixelSize: 11
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ListView {
                model: items
                spacing: 1

                delegate: Rectangle {
                    required property var item
                    width: ListView.view.width
                    height: 56
                    color: Theme.bg

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.pad
                        anchors.rightMargin: Theme.pad
                        spacing: Theme.pad

                        Rectangle {
                            Layout.preferredWidth: 8
                            Layout.preferredHeight: 8
                            radius: 4
                            color: tab.colorFor(R.statusOf(item))
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                text: item.title || "(untitled)"
                                color: Theme.text
                                font.pixelSize: 13
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Label {
                                text: R.short(item.id, 7)
                                      + " · " + R.authorName(item.author)
                                      + " · " + R.statusOf(item)
                                color: Theme.textDim
                                font.pixelSize: 10
                            }
                        }
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 1
                        color: Theme.border
                    }
                }

                footer: Item {
                    width: parent ? parent.width : 0
                    height: tab.hasMore ? 44 : 0
                    visible: tab.hasMore
                    Button {
                        anchors.centerIn: parent
                        text: "Load more"
                        onClicked: { tab.page_++; tab.fetch(); }
                    }
                }
            }
        }
    }
}
