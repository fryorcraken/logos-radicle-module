import QtQuick

/*
 * Thin strip under the top bar for loading / error state.
 *
 * Deliberately ALWAYS occupies its height rather than appearing and vanishing:
 * a strip that collapses shifts every view below it each time a request starts
 * or finishes, which was a large part of why navigation felt jumpy.
 */
Rectangle {
    id: strip

    property bool busy: false
    property string error: ""

    implicitHeight: Theme.statusHeight
    color: error !== "" ? Qt.rgba(0.97, 0.32, 0.29, 0.12) : Theme.bg

    Behavior on color { ColorAnimation { duration: Theme.animFast } }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.gap
        anchors.right: parent.right
        anchors.rightMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.gapSm

        // Indeterminate activity dot — cheaper than a spinner and enough signal.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 6; height: 6; radius: 3
            visible: strip.busy && strip.error === ""
            color: Theme.accent
            SequentialAnimation on opacity {
                running: strip.busy && strip.error === ""
                loops: Animation.Infinite
                NumberAnimation { to: 0.25; duration: 500; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0;  duration: 500; easing.type: Easing.InOutQuad }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 20
            elide: Text.ElideRight
            text: strip.error !== "" ? strip.error
                                     : (strip.busy ? "Loading…" : "")
            color: strip.error !== "" ? Theme.bad : Theme.textDim
            font.pixelSize: Theme.fontSm
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width; height: 1
        color: Theme.border
    }
}
