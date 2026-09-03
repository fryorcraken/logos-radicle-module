import QtQuick
import QtQuick.Controls
import "Theme.js" as Theme

/*
 * Repo section tabs (Source / Commits / Issues / Patches).
 *
 * Named SectionTabs, not TabBar: QtQuick.Controls already exports a TabBar and
 * that one wins the name resolution, so a local TabBar.qml is silently ignored.
 *
 * The selected tab carries a full-strength underline, bright text and a bold
 * weight; unselected tabs are dimmed. Previously only the text colour changed,
 * which was too subtle to answer "which am I looking at?".
 */
Item {
    id: control

    /// [{ label, count }]  — count < 0 hides the badge
    property var tabs: []
    property int current: 0

    signal picked(int index)

    implicitHeight: Theme.tabHeight

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.gapXs

        Repeater {
            model: control.tabs

            delegate: Item {
                required property var modelData
                required property int index

                readonly property bool selected: control.current === index

                width: inner.implicitWidth + 28
                height: Theme.tabHeight

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    anchors.bottomMargin: 6
                    radius: Theme.radiusSm
                    color: mouse.containsMouse && !parent.selected
                           ? Theme.surfaceAlt : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.animFast } }
                }

                Row {
                    id: inner
                    anchors.centerIn: parent
                    spacing: Theme.gapSm

                    Text {
                        text: modelData.label
                        font.pixelSize: Theme.fontMd
                        font.bold: parent.parent.selected
                        color: parent.parent.selected ? Theme.text : Theme.textDim
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                        visible: modelData.count !== undefined && modelData.count >= 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: countLabel.implicitWidth + 12
                        height: 16
                        radius: Theme.radiusPill
                        color: parent.parent.parent.selected ? Theme.raised : Theme.surfaceAlt
                        Text {
                            id: countLabel
                            anchors.centerIn: parent
                            text: modelData.count !== undefined ? modelData.count : ""
                            font.pixelSize: Theme.fontXs
                            color: parent.parent.parent.parent.selected
                                   ? Theme.text : Theme.textFaint
                        }
                    }
                }

                // Selection underline.
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.selected ? parent.width - 8 : 0
                    height: 2
                    radius: 1
                    color: Theme.accent
                    Behavior on width { NumberAnimation { duration: Theme.animMed
                                                          easing.type: Easing.OutCubic } }
                }

                MouseArea {
                    id: mouse
                    // Named here, not on the delegate: UI tests select by
                    // objectName AND clickability, and the delegate Item is
                    // not clickable — only one element matched instead of four.
                    objectName: "sectionTab"
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: control.picked(index)
                }
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
