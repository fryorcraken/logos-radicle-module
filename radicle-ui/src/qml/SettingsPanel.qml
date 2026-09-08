import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Theme.js" as Theme

/*
 * Module settings: which node, and where git is.
 *
 * Two things here are worth reading before changing them, because both encode
 * a constraint rather than a preference.
 *
 * **The git path applies on restart, not immediately.** Radicle resolves `git`
 * by bare name from six separate spawn sites across the crate and the node,
 * two of which clear the environment down to `PATH` — so the only channel that
 * reaches all of them is the module process's own `PATH`, and writing that is
 * process-global state which is only safe before any thread starts. The
 * setting is therefore validated and stored now and applied at next launch.
 * The UI says so, in the row, because a setting that silently does nothing
 * until some unstated later moment is worse than one that states its terms.
 *
 * **Validation happens when you save, not when something uses it.** A git path
 * is checked by running its `--version`; a bad one is refused here, while the
 * field is still on screen, rather than surfacing much later as a failed push
 * with no obvious cause.
 */
Item {
    id: panel

    /// Injected: getSettings(cb) -> cb(settingsObject).
    property var fetchSettings: null
    /// Injected: saveSetting(key, value, cb) -> cb(replyObject).
    property var saveSetting: null

    /// Live capabilities, for the mode picker's startable/unavailable state
    /// and the git preflight readout.
    property var caps: ({})

    /// The user is done here. The HOST decides what that means — see the
    /// close control below for why this panel does not close itself.
    signal closed()

    property var settings: ({})
    property string lastError: ""
    property bool loaded: false

    // Same two-trigger load as SeedPicker, for the same reason: `fetchSettings`
    // is assigned by the parent and that can happen after this component
    // completes, so loading from Component.onCompleted alone races and usually
    // loses, leaving the panel permanently empty.
    Component.onCompleted: reload()
    onFetchSettingsChanged: reload()

    function reload() {
        if (!fetchSettings || loaded) return;
        loaded = true;
        fetchSettings(function (data) {
            if (data) panel.settings = data;
            else panel.loaded = false;   // allow a retry
        });
    }

    function apply(key, value) {
        if (!saveSetting) return;
        panel.lastError = "";
        saveSetting(key, value, function (reply) {
            if (reply && reply.error) {
                // Surfaced verbatim: these messages name the path that was
                // tried and the limit that was exceeded, which is the whole
                // reason validation happens on write.
                panel.lastError = reply.error;
                return;
            }
            if (reply) panel.settings = reply;
        });
    }

    // Test-observable state, in the same spirit as Main.qml's: assertions
    // should ask the component what it believes rather than infer it from
    // rendered pixels.
    readonly property string currentMode: settings.mode || "local"
    readonly property string currentGitPath: settings.gitPath || ""
    readonly property bool hasError: lastError !== ""

    implicitWidth: 520
    implicitHeight: column.implicitHeight + Theme.gapLg * 2

    // Escape closes it, the reflex every dismissable thing owes a keyboard
    // user. `Keys` needs focus to see anything, so the panel takes it when it
    // becomes visible — otherwise the shortcut exists and never fires, which is
    // the "control that silently does nothing" shape in a keybinding.
    focus: visible
    onVisibleChanged: if (visible) forceActiveFocus()
    Keys.onEscapePressed: function (event) {
        panel.closed();
        event.accepted = true;
    }

    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.margins: Theme.gapLg
        spacing: Theme.gapLg

        // ---- the way out --------------------------------------------------
        //
        // This panel is an OPAQUE OVERLAY over the whole view, and the control
        // that opens it lives in the header underneath. Without this it was a
        // one-way door: the user clicked their node id, landed here, and had to
        // restart Basecamp. It shipped that way.
        //
        // Placed FIRST in the column, not last, and that is the fix rather than
        // a stylistic choice. The panel is anchored to the top of a pane it can
        // grow taller than, so a control at the end of the column sits below
        // the fold on a short window — present, `visible: true`, and
        // unreachable. Top-left is also where a user looks for a way back,
        // matching RepoView, CommitView and ThreadView.
        //
        // Same chrome as those three (`‹  Back`, hover fill, objectName on the
        // MouseArea rather than the Rectangle) so it reads as the same control
        // it already is elsewhere in the app.
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.gap

            Rectangle {
                Layout.preferredWidth: 68
                Layout.preferredHeight: 28
                radius: Theme.radius
                color: backMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                border.color: Theme.border
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "‹  Back"
                    color: Theme.text
                    font.pixelSize: Theme.fontMd
                }

                MouseArea {
                    id: backMouse
                    // On the MouseArea: see RepoView.qml's backButton for why
                    // naming the Rectangle makes which control a click reaches
                    // depend on sibling order.
                    objectName: "settingsBackButton"
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // The panel announces rather than closes itself: the HOST
                    // owns the overlay's visibility, and a panel that hid
                    // itself would leave the host's `settingsOpen` still true —
                    // after which the Settings toggle would need two clicks to
                    // reopen it. Same division as RepoView's `back()`.
                    onClicked: panel.closed()
                }
            }

            Text {
                Layout.fillWidth: true
                text: "Radicle node"
                color: Theme.text
                font.pixelSize: Theme.fontXl
                font.bold: true
            }
        }

        // Who you are, and where that comes from — in full.
        //
        // The header used to carry a separate "Attached · z6Mko…" chip with a
        // hover tooltip holding the whole DID and the resolved home. It looked
        // like a button, did nothing when clicked, and the tooltip was clipped
        // to an unreadable sliver by the fixed-height bar it hung out of.
        //
        // The header now shows the abbreviated identity in its mode-detail slot
        // (NodeIdentity.qml) and that element opens THIS panel, so a user
        // squinting at a truncated DID has somewhere to click. Which is why the
        // whole thing has to be here, in full: this is the destination.
        //
        // Selectable, because the one thing a user actually DOES with a DID is
        // paste it into `rad id update --allow`.
        TextEdit {
            objectName: "identityReadout"
            Layout.fillWidth: true
            readOnly: true
            selectByMouse: true
            wrapMode: Text.WrapAnywhere
            color: Theme.textDim
            font.pixelSize: Theme.fontSm
            font.family: Theme.mono
            // A blank line here would read as a rendering fault rather than as
            // "there is no profile", so the absence is stated.
            text: (panel.caps.nodeId ? panel.caps.nodeId : "No local identity")
                  + "\n"
                  + (panel.caps.radHome ? panel.caps.radHome
                                        : "no Radicle home resolved")
        }

        ModePicker {
            objectName: "modePicker"
            Layout.fillWidth: true
            current: panel.currentMode
            // Consumed straight from capabilities. This used to be DERIVED from
            // `caps.modeStartable`, and that was a real bug rather than a
            // stylistic one: the boolean answers "can the mode in force start?"
            // and the picker needs "which modes can start at all?". In `local` —
            // the default, and where every first-time user is — the boolean is
            // true, so the derivation produced all three modes and the Embedded
            // row carried no caveat whatever. The user selected it, it
            // persisted, and only THEN did a warning appear: a control that
            // silently does nothing, which the design explicitly refuses.
            //
            // The fallback is the conservative one — if capabilities have not
            // arrived yet, claim nothing is startable rather than claiming
            // everything is. An over-cautious caveat on a row that turns out to
            // work is a much cheaper mistake than a missing one on a row that
            // does not.
            startableModes: panel.caps.startableModes !== undefined
                            ? panel.caps.startableModes
                            : []
            unavailableReason: panel.caps.modeUnavailableReason || ""
            onModeChosen: function (mode) { panel.apply("mode", mode); }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Theme.border
        }

        // ---- git --------------------------------------------------------
        Text {
            text: "Git"
            color: Theme.text
            font.pixelSize: Theme.fontLg
            font.bold: true
        }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.textDim
            font.pixelSize: Theme.fontSm
            text: "Radicle runs git to read and write repository storage. "
                + "Leave this blank to find it automatically."
        }

        // What is actually in force right now, resolved. Shown because "which
        // git is being used" is exactly the question a user has when a push
        // fails on a machine with several of them.
        Text {
            objectName: "gitResolved"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.pixelSize: Theme.fontSm
            color: panel.caps.gitFound === false ? Theme.warn : Theme.textDim
            text: panel.caps.gitFound === false
                  ? ("git not found — " + (panel.caps.gitProblem || "no git available")
                     + ". Writing to repositories will not work until this is fixed.")
                  : ("Using " + (panel.caps.gitPath || "git")
                     + (panel.caps.gitVersion ? "  (" + panel.caps.gitVersion + ")" : "")
                     + (panel.caps.gitConfigured ? "  — set below" : "  — found automatically"))
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.gapSm

            TextField {
                id: gitField
                objectName: "gitPathField"
                Layout.fillWidth: true
                placeholderText: "Path to git (blank = find it automatically)"
                text: panel.currentGitPath
                color: Theme.text
                font.pixelSize: Theme.fontMd
                background: Rectangle {
                    radius: Theme.radius
                    color: Theme.bg
                    border.width: 1
                    border.color: gitField.activeFocus ? Theme.accent : Theme.border
                }
                onAccepted: panel.apply("gitPath", text)
            }

            Button {
                objectName: "gitPathSave"
                text: "Save"
                onClicked: panel.apply("gitPath", gitField.text)
                contentItem: Text {
                    text: parent.text
                    color: Theme.text
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: Theme.radius
                    color: parent.down ? Theme.surfaceAlt : Theme.surface
                    border.width: 1
                    border.color: Theme.border
                }
            }
        }

        // The restart-to-apply statement. Not a footnote: without it the user
        // has every reason to believe a saved path is in force, and the one
        // thing worse than a setting that needs a restart is one that needs a
        // restart without saying so.
        Text {
            objectName: "gitRestartNote"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.textDim
            font.pixelSize: Theme.fontXs
            text: "A changed git path is checked immediately but takes effect "
                + "the next time Basecamp starts this module."
        }

        // ---- errors ------------------------------------------------------
        Text {
            objectName: "settingsError"
            visible: panel.hasError
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.bad
            font.pixelSize: Theme.fontSm
            text: panel.lastError
        }
    }
}
