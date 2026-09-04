import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Theme.js" as Theme

/*
 * Open a new issue: title, description, create.
 *
 * The same shape as CommentComposer and for the same reasons — it is a write,
 * so it can fail by losing something the user typed, and it holds *two* fields
 * rather than one, which makes that worse rather than better. All the rules
 * carry over:
 *
 *  - Not offered unless a write could actually succeed (`canWrite`, a real
 *    probe for a signing key, not `localAvailable`).
 *  - A failed create keeps BOTH fields. Losing a written-out issue description
 *    is the worst version of the failure this surface must not have.
 *  - On success the list reloads from the backend rather than having a row
 *    appended locally — an append renders correctly whether or not the write
 *    landed.
 *
 * Field layout follows Radicle Desktop's own "New issue" modal, confirmed by
 * screenshot in docs/M2.2-write-features-proposal.md: a single-line title, a
 * multi-line description, and labels/assignees as separate actions rather than
 * inline fields. This module has neither of those actions yet, so the form is
 * just the two fields — which is exactly the modal's own default state.
 *
 * Not a QML `Dialog`/`Popup`: Basecamp hosts this view inside a QQuickWidget,
 * and a Popup there renders in its own window layer with its own quirks. An
 * in-place panel that the StackLayout switches to behaves identically in the
 * component tests and in Basecamp, which is worth more here than modality.
 */
Item {
    id: form

    property var app: null
    property string rid: ""

    /// Whether a write is possible at all. False hides the form's controls.
    property bool canWrite: false
    /// Why not, shown in place of them.
    property string unavailableReason: ""

    /// True from submit until the reply lands. Fields and button lock, so a
    /// double-click cannot open the same issue twice — which, unlike a double
    /// comment, leaves two separate issues someone has to close.
    property bool creating: false
    /// Set when a create fails, cleared when the next one starts.
    property string error: ""

    /// Set when the last create SUCCEEDED but the node had not announced it.
    /// Not an error — the issue exists and is signed; it is simply not visible
    /// to anyone else yet. See CommentComposer for the same distinction.
    property string queuedNotice: ""

    /// The draft. Neither is cleared except on success.
    property alias title: titleField.text
    property alias description: bodyField.text

    readonly property bool canSubmit: canWrite && !creating
                                      && titleField.text.trim().length > 0
                                      && bodyField.text.trim().length > 0
                                      && rid !== ""

    /// An issue was created. Carries its id so a caller can open it.
    signal created(string id)
    /// The user backed out without creating anything.
    signal cancelled()

    function reset() {
        titleField.text = "";
        bodyField.text = "";
        error = "";
        queuedNotice = "";
        creating = false;
    }

    function submit() {
        if (!canSubmit) return;

        creating = true;
        error = "";
        queuedNotice = "";

        // Captured before the async call, matching every loader here. Without
        // it, a reply arriving after the user switched repository would report
        // an issue created in one repo as belonging to another.
        var wantRid = rid;

        app.call("CreateIssue", [rid, titleField.text, bodyField.text],
                 function (data) {
            if (form.rid !== wantRid) return;
            form.creating = false;

            // A create that succeeded but was not announced is an ordinary
            // state, not a failure — see CommentComposer. `=== false` rather
            // than falsiness: an older backend omitting the field means "no
            // claim made", not "not announced".
            if (data && data.announced === false) {
                form.queuedNotice =
                    "Saved locally, not yet announced — "
                    + (data.announceError || "the local node did not confirm");
            }

            form.title = "";
            form.description = "";
            form.created(data && data.id ? String(data.id) : "");
        }, function () {
            if (form.rid !== wantRid) return;
            form.creating = false;
            // Both fields survive. A written-out description is the most
            // expensive thing this UI could throw away.
            form.error = "Could not create the issue";
        }, "local");
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.gapLg
            spacing: Theme.gap

            // ---- header ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap

                Rectangle {
                    Layout.preferredWidth: 68
                    Layout.preferredHeight: 28
                    radius: Theme.radius
                    color: cancelMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                    border.color: Theme.border
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "‹  Back"
                        color: Theme.text
                        font.pixelSize: Theme.fontMd
                    }
                    MouseArea {
                        id: cancelMouse
                        // On the MouseArea, not the Rectangle — see RepoView's
                        // backButton for why.
                        objectName: "newIssueCancel"
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: form.cancelled()
                    }
                }

                Text {
                    text: "New issue"
                    color: Theme.text
                    font.pixelSize: Theme.fontLg
                    font.bold: true
                    Layout.fillWidth: true
                }
            }

            // ---- why not, when a write is impossible ----
            Text {
                objectName: "newIssueUnavailable"
                visible: !form.canWrite && form.unavailableReason !== ""
                text: form.unavailableReason
                color: Theme.textFaint
                font.pixelSize: Theme.fontSm
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            // ---- title ----
            Rectangle {
                visible: form.canWrite
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                color: Theme.surfaceAlt
                border.color: titleField.activeFocus ? Theme.accent : Theme.border
                border.width: 1
                radius: Theme.radius

                TextField {
                    id: titleField
                    objectName: "newIssueTitle"
                    anchors.fill: parent
                    anchors.leftMargin: Theme.gapSm
                    anchors.rightMargin: Theme.gapSm
                    enabled: !form.creating
                    placeholderText: "Title"
                    color: Theme.text
                    placeholderTextColor: Theme.textFaint
                    font.pixelSize: Theme.fontMd
                    background: null
                    selectByMouse: true
                    // Enter moves to the description rather than submitting: a
                    // title is one line and the description is required, so
                    // submitting from here could never succeed.
                    onAccepted: bodyField.forceActiveFocus()
                }
            }

            // ---- description ----
            Rectangle {
                visible: form.canWrite
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 120
                color: Theme.surfaceAlt
                border.color: bodyField.activeFocus ? Theme.accent : Theme.border
                border.width: 1
                radius: Theme.radius

                ScrollView {
                    anchors.fill: parent
                    anchors.margins: Theme.gapSm
                    clip: true

                    TextArea {
                        id: bodyField
                        objectName: "newIssueDescription"
                        enabled: !form.creating
                        placeholderText: "Description — Markdown is supported"
                        color: Theme.text
                        placeholderTextColor: Theme.textFaint
                        font.pixelSize: Theme.fontMd
                        wrapMode: TextArea.Wrap
                        background: null
                        selectByMouse: true
                    }
                }
            }

            // ---- submit ----
            RowLayout {
                visible: form.canWrite
                Layout.fillWidth: true
                spacing: Theme.gapSm

                Text {
                    objectName: "newIssueError"
                    visible: form.error !== ""
                    text: form.error
                    color: Theme.bad
                    font.pixelSize: Theme.fontSm
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                // Theme.warn, not Theme.bad: nothing went wrong and there is
                // nothing to retry.
                Text {
                    objectName: "newIssueQueuedNotice"
                    visible: form.queuedNotice !== ""
                    text: form.queuedNotice
                    color: Theme.warn
                    font.pixelSize: Theme.fontSm
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                Item {
                    visible: form.error === "" && form.queuedNotice === ""
                    Layout.fillWidth: true
                }

                Rectangle {
                    Layout.preferredWidth: 110
                    Layout.preferredHeight: 28
                    radius: Theme.radius
                    color: form.canSubmit
                           ? (submitMouse.containsMouse ? Theme.accent : Theme.accentSoft)
                           : Theme.raised
                    border.color: form.canSubmit ? "transparent" : Theme.border
                    border.width: 1

                    Text {
                        anchors.centerIn: parent
                        text: form.creating ? "Creating…" : "Create issue"
                        color: form.canSubmit ? Theme.textOnAccent : Theme.textFaint
                        font.pixelSize: Theme.fontMd
                        font.bold: form.canSubmit
                    }

                    MouseArea {
                        id: submitMouse
                        objectName: "newIssueSubmit"
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: form.canSubmit
                        cursorShape: form.canSubmit ? Qt.PointingHandCursor
                                                    : Qt.ArrowCursor
                        onClicked: form.submit()
                    }
                }
            }
        }
    }
}
