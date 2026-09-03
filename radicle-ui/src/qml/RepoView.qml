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

    property int tab: 0
    property var loadedTabs: ({})

    /// Counts the UI tests assert on.
    readonly property int treeCount:   source.entryCount
    readonly property int commitCount: commits.count

    onRidChanged: {
        tab = 0;
        loadedTabs = ({});
        // Drop every tab's contents up front. Without this, switching repos
        // left the previous repo's commits/issues/patches on screen under the
        // new repo's header until each tab was re-opened.
        source.reset();
        commits.reset();
        issues.reset();
        patches.reset();
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

                // Branch chip.
                Rectangle {
                    visible: page.defaultBranch !== ""
                    Layout.preferredWidth: branchText.implicitWidth + 20
                    Layout.preferredHeight: 22
                    radius: Theme.radiusPill
                    color: Theme.surfaceAlt
                    border.color: Theme.border
                    border.width: 1
                    Text {
                        id: branchText
                        anchors.centerIn: parent
                        text: page.defaultBranch
                        color: Theme.textDim
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
        }

        // ---- tabs (fixed height) ----
        SectionTabs {
            Layout.fillWidth: true
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
            currentIndex: page.tab

            SourceTab  { id: source;  app: page.app; rid: page.rid; branch: page.defaultBranch }
            CommitsTab { id: commits; app: page.app; rid: page.rid; branch: page.defaultBranch }
            IssuesTab  { id: issues;  app: page.app; rid: page.rid }
            PatchesTab { id: patches; app: page.app; rid: page.rid }
        }
    }
}
