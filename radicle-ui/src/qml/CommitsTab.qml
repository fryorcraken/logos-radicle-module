import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

Item {
    id: tab

    // A StackLayout child: must fill, or it is sized 0x0.
    Layout.fillWidth: true
    Layout.fillHeight: true
    property var app: null
    property string rid: ""
    property string branch: ""
    property int page_: 0
    property bool hasMore: false
    property bool loading: false
    property bool loadedOnce: false

    /// Emitted when a row is activated, so RepoView can open the commit view.
    signal commitActivated(string sha)

    ListModel { id: commits }

    /// Commits currently listed — read by the UI tests.
    readonly property int count: commits.count

    /// Clear without fetching — used when the repository changes.
    function reset() {
        page_ = 0; commits.clear(); loadedOnce = false; hasMore = false; loading = false;
    }

    function load() {
        reset(); fetch();
    }

    function fetch() {
        if (!app || rid === "") return;
        var wantRid = rid, wantBranch = branch;
        tab.loading = true;
        app.call("ListCommits", [rid, branch, page_, 50], function (data) {
            // Drop a reply for a repo or branch the user has already left —
            // otherwise it would populate the new repo's list and flip
            // loading/hasMore for a repo that is no longer showing.
            if (tab.rid !== wantRid || tab.branch !== wantBranch) return;
            tab.loading = false; tab.loadedOnce = true;
            var items = data.items || [];
            for (var i = 0; i < items.length; i++)
                commits.append({ c: items[i] });
            tab.hasMore = !!data.hasMore;
        }, function () {
            if (tab.rid !== wantRid || tab.branch !== wantBranch) return;
            tab.loading = false; tab.loadedOnce = true;
        });
    }

    ListView {
        id: list
        anchors.fill: parent
        model: commits
        clip: true
        spacing: 0
        cacheBuffer: Theme.rowHeight * 12
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
            required property var c
            width: list.width
            height: Theme.rowHeight
            color: rowMouse.containsMouse ? Theme.surfaceAlt : Theme.bg
            Behavior on color { ColorAnimation { duration: Theme.animFast } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.gap
                spacing: Theme.gap

                Avatar {
                    seed: c.author ? (c.author.email || c.author.name || "") : ""
                    size: 26
                    Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: c.summary || ""
                        color: Theme.text
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        text: R.authorName(c.author)
                              + " · " + R.when(c.committer ? c.committer.time : 0)
                        color: Theme.textFaint
                        font.pixelSize: Theme.fontXs
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }

                Rectangle {
                    Layout.preferredWidth: shaText.implicitWidth + 16
                    Layout.preferredHeight: 20
                    radius: Theme.radiusSm
                    color: Theme.surfaceAlt
                    Text {
                        id: shaText
                        anchors.centerIn: parent
                        text: R.short(c.id, 7)
                        color: Theme.accent
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.mono
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.border
            }

            // Matches IssuesTab's delegate order (content, then MouseArea).
            // The actual click-dead bug was in the test, not z-order: see
            // tst_clicks.qml — mouseClick cannot reach an invisible item.
            MouseArea {
                id: rowMouse
                objectName: "commitRow"
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tab.commitActivated(c.id)
            }
        }

        footer: Item {
            width: list.width
            height: tab.hasMore ? 52 : 0
            visible: tab.hasMore
            Button {
                anchors.centerIn: parent
                text: "Load more"
                onClicked: { tab.page_++; tab.fetch(); }
                background: Rectangle {
                    implicitWidth: 110; implicitHeight: 28
                    radius: Theme.radius
                    color: parent.hovered ? Theme.surfaceAlt : Theme.surface
                    border.color: Theme.border; border.width: 1
                }
                contentItem: Text {
                    text: parent.text; color: Theme.text
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    LoadingState {
        anchors.fill: parent
        loading: tab.loading
        loaded: tab.loadedOnce
        count: commits.count
        emptyText: "No commits"
        loadingText: "Loading commits…"
    }
}
