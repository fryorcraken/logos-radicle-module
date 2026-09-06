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

    /// Modes this build can actually start. Anything not listed is offered but
    /// annotated as unavailable.
    ///
    /// **This must come from `getCapabilities().startableModes`, never from
    /// `modeStartable`.** The latter is a fact about the mode in force; this is
    /// a fact about the build, and one cannot be derived from the other. A
    /// caller that tried shipped a picker which, in the default Attach state,
    /// offered Embedded with no caveat at all — see SettingsPanel.qml.
    ///
    /// The default is deliberately conservative rather than "the two that work
    /// today": a caller that forgets to wire this gets over-annotation, which
    /// is visible, instead of under-annotation, which is exactly the bug.
    property var startableModes: []

    /// Why the non-startable modes are not startable, from getCapabilities().
    ///
    /// Empty is normal and expected: `modeUnavailableReason` is populated only
    /// when the mode IN FORCE cannot start, so in the default state there is no
    /// sentence to show and the row falls back to its own generic wording. That
    /// fallback is why the note is still honest before anything is selected.
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

                // The honesty requirement: a mode that cannot run says so here,
                // in the row, BEFORE it is chosen — not discovered afterwards
                // as "nothing happened".
                //
                // Note this is keyed on `startable`, a per-row fact, and not on
                // whether this row is the selected one. That is the whole fix:
                // a user has to be able to see the caveat while deciding.
                Text {
                    objectName: "modeUnavailable_" + parent.parent.modelData.key
                    visible: !parent.parent.startable
                    width: content.width
                    // The specific sentence from capabilities is only populated
                    // for the mode in force, so the generic wording is what the
                    // common case — an unstartable mode nobody has selected —
                    // actually shows. It has to stand on its own for that
                    // reason, rather than being a placeholder.
                    text: picker.unavailableReason !== ""
                          ? picker.unavailableReason
                          : "This version cannot start this mode yet — choosing "
                            + "it will not start a node."
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
