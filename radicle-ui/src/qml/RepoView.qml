import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R

// One repository: source tree, commits, issues and patches.
Item {
    id: page

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

    onRidChanged: {
        tab = 0;
        loadedTabs = ({});
        maybeLoad();
    }

    // The page can receive a rid before it becomes visible, and `active`
    // can flip before the rid arrives. Load on whichever happens last.
    onActiveChanged: maybeLoad()

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

    onTabChanged: maybeLoad()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            color: Theme.panel

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.pad
                anchors.rightMargin: Theme.pad
                spacing: Theme.pad

                Button {
                    text: "‹ Back"
                    onClicked: page.back()
                    background: Rectangle {
                        color: parent.hovered ? Theme.panelAlt : "transparent"
                        radius: Theme.radius
                        border.color: Theme.border
                        border.width: 1
                    }
                    contentItem: Text {
                        text: parent.text
                        color: Theme.text
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                ColumnLayout {
                    spacing: 1
                    Label {
                        text: page.repo ? R.repoName(page.repo) : ""
                        color: Theme.text
                        font.pixelSize: 15
                        font.bold: true
                    }
                    Label {
                        text: page.rid
                        color: Theme.textDim
                        font.pixelSize: 10
                        font.family: Theme.mono
                    }
                }

                Item { Layout.fillWidth: true }

                Label {
                    visible: page.defaultBranch !== ""
                    text: page.defaultBranch
                    color: Theme.textDim
                    font.pixelSize: 11
                    font.family: Theme.mono
                }
            }
        }

        // Tab bar.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            color: Theme.bg

            Row {
                anchors.fill: parent
                anchors.leftMargin: Theme.pad
                spacing: 4

                Repeater {
                    model: [
                        { label: "Source" },
                        { label: "Commits" },
                        { label: "Issues",  count: page.meta.issues  ? page.meta.issues.open  : -1 },
                        { label: "Patches", count: page.meta.patches ? page.meta.patches.open : -1 }
                    ]
                    delegate: Button {
                        required property var modelData
                        required property int index
                        height: 36
                        checkable: true
                        checked: page.tab === index
                        onClicked: page.tab = index
                        background: Rectangle {
                            color: "transparent"
                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                height: 2
                                color: parent.parent.checked ? Theme.accent : "transparent"
                            }
                        }
                        contentItem: Text {
                            text: modelData.label
                                  + (modelData.count >= 0 ? "  " + modelData.count : "")
                            color: parent.checked ? Theme.text : Theme.textDim
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Theme.border
            }
        }

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
