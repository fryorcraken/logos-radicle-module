import QtQuick
import "Theme.js" as Theme

/*
 * A shell command shown ready to copy, with the copy CHECKED rather than
 * assumed.
 *
 * ## Why this is not NodeIdentity
 *
 * `NodeIdentity.qml` copies a bare DID and is a header element with elision
 * rules, a hover underline and a reserved-width confirmation; this is a command
 * line in a wizard body. Different payload, different chrome. What is worth
 * keeping from it is the one thing that is easy to drop, and did not exist in
 * this repo's first two attempts at a copy control: **proof that the copy
 * landed**.
 *
 * ## Why the copy is verified, and why two editors
 *
 * `TextEdit.copy()` returns nothing and reports failure through no channel at
 * all. A control that restarts a confirmation timer on the next line therefore
 * says "Copied" whether or not anything reached the clipboard — and that is not
 * theoretical: the offscreen Qt platform plugin every test here runs under
 * always provides a clipboard, so a broken copy stays green in CI and fails
 * silently in front of a user on a Wayland bundle without one. A reviewer
 * proved the point by deleting the `copy()` call from the earlier version and
 * watching it go on confirming.
 *
 * So the effect is checked by pasting it back. The verifier is a SEPARATE
 * editor from the one copied out of, and that separation is the whole
 * mechanism: `clip.text` is assigned before the copy is attempted, so reading
 * the check back out of `clip` would compare the text against itself — green
 * in exactly the case this exists to catch.
 *
 * ## Why the command is a property rather than the label's text
 *
 * What is copied is `command`, never what is rendered. The label may wrap or be
 * styled; a user pasting what they saw must get what the command is.
 */
Item {
    id: root

    /// The command to show and copy. "" means there is nothing to show yet,
    /// and this occupies no space — which is what keeps a half-formed command
    /// with a missing argument off the screen.
    property string command: ""

    /// A short line above the command saying what it is for.
    property string caption: ""

    readonly property int confirmMs: 1600

    /// Whether the confirmation is on screen right now.
    ///
    /// Read off the item rather than off the timer: the failure worth catching
    /// is a confirmation that is running and not rendered, and a property
    /// reading the timer would report success in exactly that case.
    readonly property bool confirmShown: confirmText.visible

    /// Emitted after the command has been copied AND the clipboard verified to
    /// hold it. Never emitted on an unverified copy.
    signal copied()

    visible: command !== ""
    implicitHeight: visible ? layout.implicitHeight : 0
    implicitWidth: 320

    /// Put the command on the clipboard, confirming only if it arrived.
    function copyToClipboard() {
        if (command === "") return false;
        clip.text = command;
        clip.selectAll();
        clip.copy();
        // Deselect so a stray focus event cannot overwrite what was copied.
        clip.deselect();

        if (!clipboardHolds(command)) return false;

        confirmTimer.restart();
        root.copied();
        return true;
    }

    /// Whether the system clipboard currently holds exactly `expected`.
    ///
    /// The only way to observe a clipboard from sandboxed QML is to paste from
    /// it. Leaves nothing behind: the scratch text is cleared either way, so
    /// this never becomes a second copy of the command sitting in the scene.
    function clipboardHolds(expected) {
        verifier.text = "";
        verifier.selectAll();
        verifier.paste();
        var got = verifier.text;
        verifier.text = "";
        return got === expected;
    }

    /// Take the confirmation down immediately.
    ///
    /// Time-based state leaks between tests: one test's 1.6s timer is still
    /// running when the next starts. A caller clearing it explicitly beats a
    /// test sleeping.
    function clearConfirmation() {
        confirmTimer.stop();
    }

    /// The clipboard handle. Never shown, never focusable, never in the layout.
    TextEdit {
        id: clip
        objectName: "copyableClipboard"
        visible: false
        activeFocusOnPress: false
        readOnly: true
    }

    /// A SEPARATE editor used only to read the clipboard back. Writable,
    /// because `paste()` is a no-op on a read-only editor. See the header for
    /// why it cannot be the same editor as `clip`.
    TextEdit {
        id: verifier
        objectName: "copyableClipboardVerifier"
        visible: false
        activeFocusOnPress: false
    }

    Timer {
        id: confirmTimer
        interval: root.confirmMs
        repeat: false
    }

    Column {
        id: layout
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Theme.gapXs

        Text {
            objectName: "copyableCaption"
            visible: root.caption !== ""
            width: layout.width
            text: root.caption
            color: Theme.textDim
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        Rectangle {
            width: layout.width
            height: commandRow.implicitHeight + Theme.gapSm * 2
            radius: Theme.radiusSm
            color: Theme.surfaceAlt
            border.width: 1
            border.color: Theme.border

            Row {
                id: commandRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.gapSm
                anchors.rightMargin: Theme.gapSm
                spacing: Theme.gapSm

                Text {
                    id: commandLabel
                    objectName: "copyableCommand"
                    width: commandRow.width - copyLabel.width
                           - confirmText.width - commandRow.spacing * 2
                    // Monospace and wrapping rather than eliding: a command cut
                    // short reads as a complete command that does something
                    // else, which is worse than a wrapped one.
                    text: root.command
                    color: Theme.text
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.mono
                    wrapMode: Text.WrapAnywhere
                }

                Text {
                    id: confirmText
                    objectName: "copyableCopied"
                    anchors.verticalCenter: commandLabel.verticalCenter
                    visible: confirmTimer.running
                    text: "Copied"
                    color: Theme.good
                    font.pixelSize: Theme.fontXs
                }

                Text {
                    id: copyLabel
                    anchors.verticalCenter: commandLabel.verticalCenter
                    text: "Copy"
                    color: Theme.accent
                    font.pixelSize: Theme.fontXs
                }
            }

            // objectName on the MouseArea, not the Rectangle: a spec clicks
            // what is clickable, and naming the wrapper matches an element that
            // cannot receive the click. This repo has shipped that bug before.
            MouseArea {
                objectName: "copyableCopyButton"
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.copyToClipboard()
            }
        }
    }
}
