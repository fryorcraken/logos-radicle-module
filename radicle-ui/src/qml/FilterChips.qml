import QtQuick
import "Theme.js" as Theme

/*
 * State filter row (open / closed, or open / merged / archived / draft).
 *
 * The active chip gets a filled tint of its own status colour plus a border,
 * so "which filter am I on?" is answerable without reading carefully.
 */
Item {
    id: control

    property var states: []
    property string current: ""

    signal picked(string state)

    implicitHeight: 34

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.gapSm

        Repeater {
            model: control.states

            delegate: Rectangle {
                required property string modelData

                readonly property bool selected: control.current === modelData
                readonly property color tone: {
                    if (modelData === "open")     return Theme.good;
                    if (modelData === "merged")   return Theme.merged;
                    if (modelData === "draft")    return Theme.textFaint;
                    if (modelData === "archived") return Theme.warn;
                    if (modelData === "closed")   return Theme.bad;
                    return Theme.textDim;
                }

                width: chipText.implicitWidth + 22
                height: 22
                radius: Theme.radiusPill

                color: selected ? Qt.rgba(tone.r, tone.g, tone.b, 0.18)
                     : (chipMouse.containsMouse ? Theme.surfaceAlt : "transparent")
                border.color: selected ? Qt.rgba(tone.r, tone.g, tone.b, 0.55)
                                       : Theme.border
                border.width: 1
                Behavior on color { ColorAnimation { duration: Theme.animFast } }

                Text {
                    id: chipText
                    anchors.centerIn: parent
                    text: modelData
                    font.pixelSize: Theme.fontSm
                    font.bold: parent.selected
                    color: parent.selected ? parent.tone : Theme.textDim
                }

                MouseArea {
                    id: chipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: control.picked(modelData)
                }
            }
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width; height: 1
        color: Theme.border
    }
}
