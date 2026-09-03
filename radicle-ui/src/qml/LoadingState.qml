import QtQuick
import "Theme.js" as Theme

/*
 * Centred loading / empty placeholder for a list or pane.
 *
 * The two states are deliberately distinct. A list that is still fetching and
 * a list that came back with nothing look identical if both are blank, and a
 * blank screen reads as "broken" rather than "working" — which is exactly how
 * the issues tab looked while it loaded.
 */
Item {
    id: control

    /// True while a request is in flight.
    property bool loading: false
    /// True once at least one request has completed.
    property bool loaded: false
    /// Number of rows currently held.
    property int count: 0
    /// Shown when a completed request returned nothing.
    property string emptyText: "Nothing here"
    /// Shown while loading.
    property string loadingText: "Loading…"

    // Only occupy the view when there is nothing to show behind it. Sizing is
    // left to the parent: this is used both anchored (over a plain Item) and
    // as a layout child, and anchors.fill conflicts with the latter.
    visible: count === 0

    Column {
        anchors.centerIn: parent
        spacing: Theme.gap
        visible: control.loading

        // Three dots pulsing in sequence — cheap, and reads as activity
        // without pulling in a spinner asset the QML sandbox would block.
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.gapSm

            Repeater {
                model: 3
                delegate: Rectangle {
                    required property int index
                    width: 7; height: 7; radius: 3.5
                    color: Theme.accent

                    SequentialAnimation on opacity {
                        running: control.loading
                        loops: Animation.Infinite
                        PauseAnimation { duration: index * 160 }
                        NumberAnimation { to: 1.0; duration: 320; easing.type: Easing.InOutQuad }
                        NumberAnimation { to: 0.25; duration: 320; easing.type: Easing.InOutQuad }
                        PauseAnimation { duration: (2 - index) * 160 }
                    }
                }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: control.loadingText
            color: Theme.textDim
            font.pixelSize: Theme.fontMd
        }
    }

    Text {
        anchors.centerIn: parent
        // Only after a request has actually completed, so this never flashes
        // over a list that is still on its way.
        visible: !control.loading && control.loaded
        text: control.emptyText
        color: Theme.textFaint
        font.pixelSize: Theme.fontLg
    }
}
