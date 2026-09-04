import QtQuick
import QtQuick.Layouts
import "Theme.js" as Theme

/**
 * Switch between the sources a repository can be browsed from.
 *
 * They are kept visibly distinct rather than merged behind one "repos" list,
 * because they answer different questions: "Explore" reaches out to a seed
 * node and shows public repositories it replicates, needing the network;
 * "Local" shows what is on this machine, including private repositories, and
 * works offline. Hiding which one you are looking at would hide exactly the
 * thing a user cares about.
 *
 * The LABEL and the KEY are deliberately separate. "Explore" is what the user
 * reads; `"remote"` is the backend method prefix (`remoteListRepos`), fixed by
 * `radicle_impl.h`'s API. Renaming the label is a UI decision; renaming the
 * key would be an API change.
 *
 * `model` is a list so a further source — an embedded node, say — is one entry
 * rather than a new branch.
 *
 * When there is no local profile the local segment is not shown at all, rather
 * than shown disabled — a control that can only produce an error reads as a
 * broken feature. `reason` explains the absence on hover instead.
 */
Rectangle {
    id: toggle

    /// "remote" | "local" — the currently selected source.
    property string current: "remote"
    /// Whether a local Radicle profile was found on this machine.
    property bool localAvailable: false
    /// Why local browsing is unavailable, shown as a tooltip when it is.
    property string reason: ""

    signal sourceChosen(string source)

    implicitWidth: row.implicitWidth + Theme.gapXs * 2
    implicitHeight: Theme.rowHeightSm
    radius: Theme.radiusSm
    color: Theme.bg
    border.width: 1
    border.color: Theme.border

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 2

        Repeater {
            model: toggle.localAvailable
                   ? [{ key: "remote", label: "Explore" },
                      { key: "local",  label: "Local" }]
                   // With no local node there is nothing to switch between, so
                   // the control collapses to a single label naming what you
                   // are looking at.
                   : [{ key: "remote", label: "Explore" }]

            // The MouseArea, not this Rectangle, is what a sitometres spec
            // clicks — naming the wrapper matches an element that is not
            // clickable. Hence objectName on the MouseArea below.
            Rectangle {
                required property var modelData

                readonly property bool selected: toggle.current === modelData.key

                implicitWidth: label.implicitWidth + Theme.gap * 2
                implicitHeight: Theme.rowHeightSm - 6
                radius: Theme.radiusSm - 1
                color: selected ? Theme.accentSoft : "transparent"

                Text {
                    id: label
                    anchors.centerIn: parent
                    text: parent.modelData.label
                    color: parent.selected ? Theme.text : Theme.textDim
                    font.pixelSize: Theme.fontSm
                    font.bold: parent.selected
                }

                MouseArea {
                    objectName: "sourceToggle_" + parent.modelData.key
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: toggle.sourceChosen(parent.modelData.key)
                }
            }
        }
    }

    // Only meaningful when the local segment is absent; otherwise there is
    // nothing to explain.
    HoverHandler {
        id: hover
        enabled: !toggle.localAvailable && toggle.reason !== ""
    }

    Rectangle {
        visible: hover.hovered
        anchors.top: parent.bottom
        anchors.topMargin: Theme.gapXs
        anchors.left: parent.left
        width: tip.implicitWidth + Theme.gap
        height: tip.implicitHeight + Theme.gapSm
        color: Theme.raised
        border.width: 1
        border.color: Theme.border
        radius: Theme.radiusSm
        z: 100

        Text {
            id: tip
            anchors.centerIn: parent
            text: toggle.reason
            color: Theme.textDim
            font.pixelSize: Theme.fontXs
        }
    }
}
