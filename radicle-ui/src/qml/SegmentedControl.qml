import QtQuick
import QtQuick.Controls

/*
 * Source switch ("Any repo" / "My node").
 *
 * Which source you are on changes what you can see (public vs private) and
 * what you can do, so the selected segment is marked three ways over — filled
 * accent background, inverted text, and a raised track — rather than relying
 * on a checked state that reads as ambiguous at a glance.
 */
Item {
    id: control

    /// [{ key, label, enabled, disabledReason }]
    property var options: []
    property string current: ""

    signal picked(string key)

    implicitWidth: row.implicitWidth + 6
    implicitHeight: 30

    Rectangle {
        anchors.fill: parent
        radius: Theme.radius
        color: Theme.bg
        border.color: Theme.border
        border.width: 1
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 2
        padding: 3

        Repeater {
            model: control.options

            delegate: Rectangle {
                required property var modelData

                readonly property bool selected: control.current === modelData.key
                readonly property bool usable: modelData.enabled === undefined
                                               || modelData.enabled

                width: label.implicitWidth + 24
                height: 24
                radius: Theme.radiusSm

                color: selected ? Theme.accent
                     : (mouse.containsMouse && usable ? Theme.surfaceAlt : "transparent")

                Behavior on color { ColorAnimation { duration: Theme.animFast } }

                Text {
                    id: label
                    anchors.centerIn: parent
                    text: modelData.label
                    font.pixelSize: Theme.fontMd
                    font.bold: parent.selected
                    color: parent.selected ? Theme.textOnAccent
                         : (parent.usable ? Theme.text : Theme.textFaint)
                }

                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: parent.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: if (parent.usable && !parent.selected)
                                   control.picked(modelData.key)
                }

                ToolTip.visible: mouse.containsMouse && !usable
                                 && modelData.disabledReason !== undefined
                ToolTip.text: modelData.disabledReason || ""
                ToolTip.delay: 300
            }
        }
    }
}
