import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Theme.js" as Theme

/*
 * Write a comment on an issue.
 *
 * The first affordance in this module that changes anything. Everything else
 * here fails by showing stale or missing data; this one can fail by losing
 * something the user typed, which is a different bar.
 *
 * Three rules follow from that, and each is pinned by a test:
 *
 *  - **It is not shown unless a write could actually succeed.** `canWrite`
 *    comes from `getCapabilities().canWriteLocal`, which is a real probe for a
 *    usable signing key rather than a build flag. A box the user can type into
 *    and not submit is worse than no box, so the check happens before the box
 *    exists rather than at submit time.
 *  - **A failed post keeps the draft.** `body` is cleared only on success.
 *    A transient failure that also wiped the text would make the user retype
 *    it, which is the one outcome worth designing against.
 *  - **A successful post is not assumed to be visible.** It emits `posted()`
 *    and the thread reloads from the backend, rather than appending the
 *    comment locally. Local append would show the right thing whether or not
 *    the write landed — the same "a fake that answers the same for every
 *    input" trap that cost this repo a milestone, wearing different clothes.
 *
 * Extracted from ThreadView rather than written inline for the reason NavState
 * and ListCache were: inside ThreadView the submit/clear/retain logic could
 * only be tested through a stub that reproduced it, which is a copy asserted
 * against itself.
 */
Item {
    id: composer

    property var app: null
    property string rid: ""
    property string itemId: ""

    /// Whether a write is possible at all. False hides the whole control.
    property bool canWrite: false
    /// Why not, shown in place of the box. Empty means say nothing.
    property string unavailableReason: ""

    /// True from submit until the reply lands. The button and field lock, so
    /// a double-click cannot post twice.
    property bool posting: false
    /// Set when a post fails, cleared when the next one starts.
    property string error: ""

    /// Set when the last post SUCCEEDED but the node had not announced it yet.
    ///
    /// This is not an error and must never be shown as one — the comment is
    /// signed and in local storage, and the node announces on next start. But
    /// it is not yet visible to anyone else, and saying nothing would let the
    /// user believe it had propagated. So it gets its own state, in
    /// `Theme.warn` rather than `Theme.bad`, cleared when the next post starts.
    property string queuedNotice: ""

    /// The draft. Deliberately not cleared except on success.
    property alias body: field.text

    readonly property bool canSubmit: canWrite && !posting
                                      && field.text.trim().length > 0
                                      && rid !== "" && itemId !== ""

    /// A comment landed. The thread reloads; the composer does not append.
    signal posted()

    implicitHeight: layout.implicitHeight + Theme.gap * 2

    /// Clear everything. Called when the thread being viewed changes, so a
    /// draft written against one issue cannot be posted to another.
    function reset() {
        field.text = "";
        error = "";
        queuedNotice = "";
        posting = false;
    }

    function submit() {
        if (!canSubmit) return;

        posting = true;
        error = "";
        queuedNotice = "";

        // Captured before the async call, matching the guard convention every
        // loader here uses. Without it, a reply arriving after the user backed
        // out and opened a different issue would clear that issue's draft.
        var wantRid = rid;
        var wantId = itemId;
        var sent = field.text;

        app.call("CommentOnIssue", [rid, itemId, sent], function (data) {
            if (composer.rid !== wantRid || composer.itemId !== wantId) return;
            composer.posting = false;

            // A write that succeeded but has not been announced yet is an
            // ordinary state — the node announces on next start — so it is not
            // reported as a failure. Saying "failed" here would make the user
            // post the same comment again.
            //
            // But it is not nothing either: the comment exists locally and
            // nobody else can see it yet. Reporting only success would let the
            // user believe it had propagated, so it gets its own notice.
            // `announced` is checked with `=== false` rather than for
            // falsiness: a reply from an older backend that omits the field
            // must read as "no claim made", not as "not announced".
            if (data && data.announced === false) {
                composer.queuedNotice =
                    "Saved locally, not yet announced — "
                    + (data.announceError || "the local node did not confirm");
            }

            composer.body = "";
            composer.posted();
        }, function () {
            if (composer.rid !== wantRid || composer.itemId !== wantId) return;
            composer.posting = false;
            // The draft survives. Retyping a lost comment is the failure this
            // whole control is shaped to avoid.
            //
            // `call()`'s failure callback takes no argument — the message goes
            // to nav.error, which the status strip already shows — so this
            // says only that the post did not happen, and leaves the specific
            // reason to the strip rather than paraphrasing it wrongly.
            composer.error = "Could not post the comment";
        }, "local");
    }

    ColumnLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: Theme.gap
        spacing: Theme.gapSm

        // ---- the reason a write is impossible, when it is ----
        Text {
            objectName: "composerUnavailable"
            visible: !composer.canWrite && composer.unavailableReason !== ""
            text: composer.unavailableReason
            color: Theme.textFaint
            font.pixelSize: Theme.fontSm
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        // ---- the box itself ----
        Rectangle {
            visible: composer.canWrite
            Layout.fillWidth: true
            Layout.preferredHeight: 72
            color: Theme.surfaceAlt
            border.color: field.activeFocus ? Theme.accent : Theme.border
            border.width: 1
            radius: Theme.radius

            ScrollView {
                anchors.fill: parent
                anchors.margins: Theme.gapSm
                clip: true

                TextArea {
                    id: field
                    objectName: "commentField"
                    enabled: !composer.posting
                    placeholderText: "Leave a comment"
                    color: Theme.text
                    placeholderTextColor: Theme.textFaint
                    font.pixelSize: Theme.fontMd
                    wrapMode: TextArea.Wrap
                    background: null
                    selectByMouse: true
                }
            }
        }

        RowLayout {
            visible: composer.canWrite
            Layout.fillWidth: true
            spacing: Theme.gapSm

            Text {
                objectName: "composerError"
                visible: composer.error !== ""
                text: composer.error
                color: Theme.bad
                font.pixelSize: Theme.fontSm
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            // A comment that is signed and stored but not yet announced.
            // Theme.warn, not Theme.bad: nothing went wrong and there is
            // nothing to retry — the node announces on next start. The point
            // is only that the user should not assume it has propagated.
            //
            // Mutually exclusive with the error above by construction: submit()
            // clears both on the way in, and exactly one of the two callbacks
            // sets one of them.
            Text {
                objectName: "composerQueuedNotice"
                visible: composer.queuedNotice !== ""
                text: composer.queuedNotice
                color: Theme.warn
                font.pixelSize: Theme.fontSm
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Item {
                visible: composer.error === "" && composer.queuedNotice === ""
                Layout.fillWidth: true
            }

            Rectangle {
                Layout.preferredWidth: 96
                Layout.preferredHeight: 28
                radius: Theme.radius
                // Disabled is a colour change, not a hidden button: the user
                // should see the action exists and why it is not yet available.
                color: composer.canSubmit
                       ? (submitMouse.containsMouse ? Theme.accent : Theme.accentSoft)
                       : Theme.raised
                border.color: composer.canSubmit ? "transparent" : Theme.border
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: composer.posting ? "Posting…" : "Comment"
                    color: composer.canSubmit ? Theme.textOnAccent : Theme.textFaint
                    font.pixelSize: Theme.fontMd
                    font.bold: composer.canSubmit
                }

                MouseArea {
                    id: submitMouse
                    // On the MouseArea, not the Rectangle: see RepoView's
                    // backButton for why naming the parent makes which control
                    // a click reaches depend on sibling order.
                    objectName: "commentSubmit"
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: composer.canSubmit
                    cursorShape: composer.canSubmit ? Qt.PointingHandCursor
                                                    : Qt.ArrowCursor
                    onClicked: composer.submit()
                }
            }
        }
    }
}
