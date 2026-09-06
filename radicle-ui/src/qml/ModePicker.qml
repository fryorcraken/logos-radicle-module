import QtQuick
import QtQuick.Controls
import "Theme.js" as Theme

/*
 * Which Radicle node this module uses: one you already run, one it will run
 * itself, or none at all.
 *
 * Unlike SourceToggle, every mode is OFFERED even when it cannot currently be
 * started — and that is a deliberate difference rather than an inconsistency.
 * SourceToggle hides the local segment when there is no profile because there
 * is genuinely nothing to switch to: picking it could only produce an error.
 * Here, choosing Embedded is a real, persisted decision that survives a
 * restart; what is missing is only the daemon that Phase 2 adds. Hiding it
 * would misrepresent the module as never intending to support it, and
 * disabling it silently would leave a user wondering what the greyed row is
 * for.
 *
 * So Embedded is selectable, and the consequence is stated in the row itself
 * rather than discovered afterwards. The rule this follows is the same one in
 * both cases: never offer a control whose effect the user cannot predict.
 *
 * The KEY is the API contract (`attach`/`embedded`/`seedOnly`, fixed by
 * radicle_impl.h); the LABEL and blurb are UI decisions.
 */
Column {
    id: picker

    /// The currently persisted mode.
    property string current: "attach"
    /// Modes this build can actually start. Anything not listed is offered
    /// but annotated as unavailable.
    property var startableModes: ["attach", "seedOnly"]
    /// Why the non-startable modes are not startable, from getCapabilities().
    property string unavailableReason: ""

    signal modeChosen(string mode)

    spacing: Theme.gapSm

    readonly property var modes: [
        {
            key: "attach",
            label: "Use my Radicle node",
            blurb: "Read the profile already on this machine. Your existing "
                 + "identity and repositories, including private ones."
        },
        {
            key: "embedded",
            label: "Run a node inside Basecamp",
            blurb: "Basecamp keeps its own Radicle home and runs the node for "
                 + "you. This creates a SEPARATE identity from any node you "
                 + "already run — a new machine joining your network, not the "
                 + "same one."
        },
        {
            key: "seedOnly",
            label: "Browse a seed only",
            blurb: "No local node at all. Public repositories over the "
                 + "network, read-only."
        }
    ]

    function isStartable(key) {
        for (var i = 0; i < startableModes.length; i++)
            if (startableModes[i] === key) return true;
        return false;
    }

    Repeater {
        model: picker.modes

        Rectangle {
            required property var modelData

            readonly property bool selected: picker.current === modelData.key
            readonly property bool startable: picker.isStartable(modelData.key)

            width: picker.width
            height: content.implicitHeight + Theme.gap * 2
            radius: Theme.radius
            color: selected ? Theme.surfaceAlt : Theme.surface
            border.width: 1
            border.color: selected ? Theme.accent : Theme.border

            Column {
                id: content
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.gap
                spacing: Theme.gapXs

                Text {
                    text: parent.parent.modelData.label
                    color: Theme.text
                    font.pixelSize: Theme.fontLg
                    font.bold: parent.parent.selected
                }

                Text {
                    width: content.width
                    text: parent.parent.modelData.blurb
                    color: Theme.textDim
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                }

                // The honesty requirement: a mode that is chosen but cannot
                // run says so here, in the row, rather than being discovered
                // as "nothing happened" after selecting it.
                Text {
                    objectName: "modeUnavailable_" + parent.parent.modelData.key
                    visible: !parent.parent.startable
                    width: content.width
                    text: picker.unavailableReason !== ""
                          ? picker.unavailableReason
                          : "Not available in this version yet."
                    color: Theme.warn
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                }
            }

            // objectName goes on the MouseArea, not the Rectangle: a spec
            // clicks what is clickable, and naming the wrapper matches an
            // element that cannot receive the click. This repo has shipped
            // that bug before.
            MouseArea {
                objectName: "modePick_" + parent.modelData.key
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (parent.modelData.key !== picker.current)
                        picker.modeChosen(parent.modelData.key);
                }
            }
        }
    }
}
