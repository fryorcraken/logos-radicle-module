import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

/*
 * One repository: source tree, commits, issues and patches.
 *
 * Chrome (header + tab bar) has fixed heights from Theme, so switching tabs
 * changes only the content area — the header never moves.
 */
Item {
    id: page

    // Placed directly in Main.qml's StackLayout. A plain Item has no
    // implicit size, so without these the layout hands it 0x0 and every
    // row draws at y=0 — the whole view collapses onto one line.
    Layout.fillWidth: true
    Layout.fillHeight: true

    property var app: null
    property string rid: ""
    property var repo: null
    /// True while this page is the visible one; gates lazy tab loading.
    property bool active: false

    signal back()

    readonly property var meta: repo ? R.projectMeta(repo) : ({})
    readonly property string defaultBranch: repo ? (R.project(repo).defaultBranch || "") : ""

    /// The branch Source and Commits are currently showing. Starts out bound
    /// to defaultBranch; picking a branch (see BranchPicker below) replaces
    /// that binding with a plain value, and onRidChanged restores it (see
    /// there) so a new repository does not inherit the old one's pick.
    property string branch: defaultBranch

    property int tab: 0
    property var loadedTabs: ({})

    /// When set, the detail view for one issue or patch replaces the tabs.
    property string openThreadId: ""
    property string openThreadKind: "Issues"
    /// When set, the commit detail view replaces the tabs.
    property string openCommitSha: ""

    /// Positions of the detail views in the StackLayout below, named so that
    /// inserting a tab cannot silently point currentIndex at the wrong child.
    readonly property int threadIndex: 4
    readonly property int commitIndex: 5

    /// True while any detail view is covering the tabs.
    readonly property bool showingDetail: openThreadId !== "" || openCommitSha !== ""

    /// Counts the UI tests assert on.
    readonly property int treeCount:   source.entryCount
    readonly property int commitCount: commits.count

    onRidChanged: {
        tab = 0;
        loadedTabs = ({});
        // Re-bind to the new repo's default branch. A plain assignment
        // (branch = defaultBranch) would only copy today's value and leave
        // `branch` a dead literal from then on; Qt.binding restores the live
        // binding declared above, so a repo picked before its own repo
        // object (and therefore defaultBranch) has arrived still ends up on
        // the right branch once it does. Without this, picking a non-default
        // branch on one repository and then opening a different one carried
        // the old repo's branch NAME into the new repo — silently wrong
        // rather than merely stale, since two repos rarely share branch
        // names on purpose.
        branch = Qt.binding(function () { return page.defaultBranch; });
        // Drop every tab's contents up front. Without this, switching repos
        // left the previous repo's commits/issues/patches on screen under the
        // new repo's header until each tab was re-opened.
        openThreadId = "";
        openCommitSha = "";
        source.reset();
        commits.reset();
        issues.reset();
        patches.reset();
        branchPicker.rid = rid;
        maybeLoad();
    }

    onBranchChanged: {
        // Same principle as switching repository, one level down: the
        // previously loaded tree/commits belong to the OLD branch and must
        // not linger on screen — or worse, look current — while the new
        // branch's data is in flight. Only source (tab 0) and commits
        // (tab 1) are branch-scoped — issues and patches are repository-wide
        // COBs with no branch concept — so only their loadedTabs entries are
        // cleared, and only they refetch. Clearing all four would refetch
        // issues/patches for no reason on every branch switch.
        delete loadedTabs[0];
        delete loadedTabs[1];
        source.reset();
        commits.reset();
        maybeLoad();
    }

    // The page can receive a rid before it becomes visible, and `active` can
    // flip before the rid arrives. Load on whichever happens last.
    onActiveChanged: maybeLoad()
    onTabChanged: maybeLoad()

    function maybeLoad() {
        if (active && rid !== "") loadTab(tab);
    }

    // Tabs fetch on first view rather than all at once, so opening a repo
    // costs one request instead of four.
    function loadTab(index) {
        if (rid === "" || loadedTabs[index]) return;
        loadedTabs[index] = true;
        if (index === 0)      source.load();
        else if (index === 1) commits.load();
        else if (index === 2) issues.load();
        else if (index === 3) patches.load();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- header (fixed height) ----
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
                    objectName: "backButton"
                    Layout.preferredWidth: 68
                    Layout.preferredHeight: 28
                    radius: Theme.radius
                    color: backMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                    border.color: Theme.border
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: Theme.animFast } }

                    Text {
                        anchors.centerIn: parent
                        text: "‹  Back"
                        color: Theme.text
                        font.pixelSize: Theme.fontMd
                    }
                    MouseArea {
                        id: backMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.back()
                    }
                }

                Avatar { seed: page.rid; size: 30; Layout.alignment: Qt.AlignVCenter }

                ColumnLayout {
                    spacing: 1
                    Layout.fillWidth: true

                    Text {
                        text: page.repo ? R.repoName(page.repo) : ""
                        color: Theme.text
                        font.pixelSize: Theme.fontLg
                        font.bold: true
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        text: page.rid
                        color: Theme.textFaint
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.mono
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                    }
                }

                // Sync: pull the whole repository into the local cache so
                // browsing afterwards needs no further requests.
                Rectangle {
                    objectName: "syncButton"
                    Layout.preferredWidth: 92
                    Layout.preferredHeight: 26
                    radius: Theme.radius
                    color: syncMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                    border.color: source.syncing ? Theme.accent : Theme.border
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: Theme.animFast } }

                    // Fills left-to-right as files are fetched.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * source.syncProgress
                        radius: Theme.radius
                        visible: source.syncing
                        color: Qt.rgba(0.35, 0.65, 1.0, 0.18)
                    }

                    Text {
                        anchors.centerIn: parent
                        text: source.syncing
                              ? Math.round(source.syncProgress * 100) + "%"
                              : (source.syncedOnce ? "Re-sync" : "Download All")
                        color: source.syncing ? Theme.accent : Theme.text
                        font.pixelSize: Theme.fontMd
                    }

                    MouseArea {
                        id: syncMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: source.syncing ? source.cancelSync() : source.syncAll()
                    }

                    ToolTip.visible: syncMouse.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: source.syncing
                                  ? "Cancel — " + source.syncDone + " of "
                                    + source.syncQueued + " fetched"
                                  : (source.syncedOnce
                                     ? "Re-download every file to refresh the local cache"
                                     : "Download every file so browsing is instant")
                }

                // Branch picker: which branch Source and Commits show.
                BranchPicker {
                    id: branchPicker
                    objectName: "branchPicker"
                    Layout.alignment: Qt.AlignVCenter
                    visible: page.rid !== ""
                    currentBranch: page.branch
                    fetchBranches: function (cb) {
                        if (!page.app || page.rid === "") return;
                        page.app.call("ListBranches", [page.rid], cb);
                    }
                    onBranchChosen: function (name) { page.branch = name; }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.border
            }
        }

        // ---- tabs (fixed height) ----
        SectionTabs {
            Layout.fillWidth: true
            visible: !page.showingDetail
            Layout.preferredHeight: visible ? Theme.tabHeight : 0
            current: page.tab
            tabs: [
                { label: "Source",  count: -1 },
                { label: "Commits", count: -1 },
                { label: "Issues",  count: page.meta.issues  ? page.meta.issues.open  : -1 },
                { label: "Patches", count: page.meta.patches ? page.meta.patches.open : -1 }
            ]
            onPicked: function (i) { page.tab = i; }
        }

        // ---- content ----
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Detail views replace the tab bodies rather than sitting beside
            // them, so the repository header above stays put. The indices are
            // named rather than written as literals: inserting a tab used to
            // silently point the detail view at the wrong child.
            currentIndex: page.openThreadId !== "" ? page.threadIndex
                        : page.openCommitSha !== "" ? page.commitIndex
                        : page.tab

            SourceTab  { id: source;  app: page.app; rid: page.rid; branch: page.branch }

            CommitsTab {
                id: commits
                app: page.app
                rid: page.rid
                branch: page.branch
                onCommitActivated: function (sha) { page.openCommitSha = sha; }
            }

            IssuesTab {
                id: issues
                app: page.app
                rid: page.rid
                onItemActivated: function (id) {
                    page.openThreadKind = "Issues";
                    page.openThreadId = id;
                }
            }

            PatchesTab {
                id: patches
                app: page.app
                rid: page.rid
                onItemActivated: function (id) {
                    page.openThreadKind = "Patches";
                    page.openThreadId = id;
                }
            }

            ThreadView {
                app: page.app
                rid: page.rid
                kind: page.openThreadKind
                itemId: page.openThreadId
                onBack: page.openThreadId = ""
            }

            CommitView {
                app: page.app
                rid: page.rid
                sha: page.openCommitSha
                onBack: page.openCommitSha = ""
            }
        }
    }
}
