import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

/*
 * One issue or patch: its title, state, author, and the whole discussion.
 *
 * Issues and patches share this view because the seed returns the same shape
 * for both — a `discussion` array of comments, each with an author and a body.
 * A patch additionally carries `revisions`, summarised at the foot.
 */
Item {
    id: view

    property var app: null
    property string rid: ""
    /// "Issues" or "Patches". Only used for wording and for picking the
    /// backend method — see `method` below, which is explicit rather than
    /// derived: stripping a trailing "s" turns Patches into "GetPatche".
    property string kind: "Issues"
    readonly property string method: kind === "Patches" ? "GetPatch" : "GetIssue"
    property string itemId: ""

    property var item: null
    property bool loading: false
    property bool loadedOnce: false

    /// Whether this machine can sign a write right now, and why not. Both come
    /// straight from `getCapabilities()` — see `radicle_impl.h`, which states
    /// the rule that write affordances gate on `canWriteLocal` rather than on
    /// `localAvailable`.
    property bool canWrite: false
    property string writeUnavailableReason: ""

    /// Commenting is offered only for issues, and only while browsing the
    /// local source.
    ///
    /// The source check is not defensive duplication of the backend's own
    /// refusal: a repository open from a seed may not exist in local storage
    /// at all, so the write could not be aimed at anything. Showing a box that
    /// would fail for a reason the user cannot act on is worse than showing
    /// none.
    ///
    /// Patches are excluded because a patch comment belongs to a *revision*,
    /// and `getPatch` does not serialize revision threads today — so a patch
    /// comment would have nowhere to appear after it was posted. Read support
    /// comes first; see docs/M2.2-write-actions-design.md.
    readonly property bool commentable: kind === "Issues"
                                        && app !== null
                                        && app.source === "local"

    signal back()

    onItemIdChanged: {
        // A draft belongs to the issue it was written against. Clearing it
        // here means backing out and opening a different issue cannot post one
        // issue's text onto another.
        composer.reset();
        load();
    }

    function load() {
        item = null;
        loadedOnce = false;
        if (!app || rid === "" || itemId === "") return;

        loading = true;
        var wantId = itemId;
        var wantRid = rid;
        app.call(view.method, [rid, itemId], function (data) {
            // Drop a reply for something the user has already navigated away
            // from — the same guard every other loader here uses. Both halves
            // matter: without the rid check, switching repository mid-load
            // paints the old repository's issue under the new one's header.
            if (view.itemId !== wantId || view.rid !== wantRid) return;
            view.loading = false;
            view.loadedOnce = true;
            view.item = data;
        }, function () {
            if (view.itemId !== wantId || view.rid !== wantRid) return;
            view.loading = false;
            view.loadedOnce = true;
        });
    }

    readonly property var discussion: item && item.discussion ? item.discussion : []
    readonly property var revisions: item && item.revisions ? item.revisions : []

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- header (fixed height, so it does not move as content loads) ----
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.headerHeight
            color: Theme.surface

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.gap
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
                        // On the MouseArea: see RepoView.qml's backButton for
                        // why naming the Rectangle makes which control a click
                        // reaches depend on sibling order.
                        objectName: "threadBackButton"
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: view.back()
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: view.item ? (view.item.title || "(untitled)") : ""
                        color: Theme.text
                        font.pixelSize: Theme.fontLg
                        font.bold: true
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        text: view.item
                              ? R.short(view.item.id, 7) + " · " + R.authorName(view.item.author)
                              : ""
                        color: Theme.textFaint
                        font.pixelSize: Theme.fontXs
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }

                StatusBadge {
                    status: view.item ? R.statusOf(view.item) : ""
                    Layout.alignment: Qt.AlignVCenter
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.border
            }
        }

        // ---- discussion ----
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 0
            model: view.discussion
            cacheBuffer: 2000
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
                required property var modelData
                width: list.width
                implicitHeight: commentBody.implicitHeight + 52
                color: Theme.bg

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.gap
                    spacing: Theme.gapSm

                    RowLayout {
                        spacing: Theme.gapSm
                        Avatar {
                            seed: modelData.author ? (modelData.author.id || "") : ""
                            size: 22
                        }
                        Text {
                            text: R.authorName(modelData.author)
                            color: Theme.text
                            font.pixelSize: Theme.fontMd
                            font.bold: true
                        }
                        Text {
                            text: R.when(modelData.timestamp)
                            color: Theme.textFaint
                            font.pixelSize: Theme.fontXs
                        }
                        Item { Layout.fillWidth: true }
                    }

                    Text {
                        id: commentBody
                        text: modelData.body || ""
                        color: Theme.textDim
                        font.pixelSize: Theme.fontMd
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 1
                    color: Theme.border
                }
            }

            // Patch revisions, listed after the discussion.
            footer: Column {
                width: list.width
                visible: view.revisions.length > 0
                spacing: 0

                Rectangle {
                    width: parent.width
                    height: Theme.rowHeightSm
                    color: Theme.surfaceAlt
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: Theme.gap
                        text: view.revisions.length + " revision"
                              + (view.revisions.length === 1 ? "" : "s")
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                    }
                }

                Repeater {
                    model: view.revisions
                    delegate: Rectangle {
                        required property var modelData
                        width: list.width
                        height: Theme.rowHeightSm
                        color: Theme.bg
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            x: Theme.gap
                            text: R.short(modelData.id, 7) + " · "
                                  + R.authorName(modelData.author)
                            color: Theme.textFaint
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.mono
                        }
                    }
                }
            }
        }

        // ---- compose ----
        // Below the thread, where a reply goes, and outside the ListView so it
        // does not scroll away from the user mid-sentence.
        Rectangle {
            objectName: "commentComposerPanel"
            Layout.fillWidth: true
            Layout.preferredHeight: composer.implicitHeight
            // Deliberately NOT gated on `loadedOnce` or `item`. `load()` clears
            // both on the way in, so a reload after a successful post would
            // hide this panel and take the composer's state with it — exactly
            // during the reload the post itself triggered. Keying on the
            // itemId alone keeps the control present across its own refresh.
            visible: view.commentable && view.itemId !== ""
            color: Theme.surface

            Rectangle {
                anchors.top: parent.top
                width: parent.width; height: 1
                color: Theme.border
            }

            CommentComposer {
                id: composer
                objectName: "commentComposer"
                anchors.fill: parent
                app: view.app
                rid: view.rid
                itemId: view.itemId
                canWrite: view.canWrite
                unavailableReason: view.writeUnavailableReason

                // Reload rather than append. Appending would render the right
                // thing whether or not the write actually landed, which is the
                // same failure as a fake that answers the same for every input.
                onPosted: view.load()
            }
        }
    }

    LoadingState {
        anchors.fill: parent
        loading: view.loading
        loaded: view.loadedOnce
        count: view.item ? 1 : 0
        emptyText: "Could not load this " + (view.kind === "Issues" ? "issue" : "patch")
        loadingText: "Loading " + (view.kind === "Issues" ? "issue" : "patch") + "…"
    }
}
