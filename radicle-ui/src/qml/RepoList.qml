import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

/*
 * Repository browser. Under "Any repo" this searches every repo the seed
 * replicates; under "My node" it lists this machine's own repos, private ones
 * included.
 */
Item {
    id: page

    // Placed directly in Main.qml's StackLayout. A plain Item has no
    // implicit size, so without these the layout hands it 0x0 and every
    // row draws at y=0 — the whole view collapses onto one line.
    Layout.fillWidth: true
    Layout.fillHeight: true

    /// Injected by Main.qml: owns backend call routing and source selection.
    property var app: null

    property string query: ""
    property int page_: 0
    property bool hasMore: false
    property bool loading: false
    property bool loadedOnce: false

    signal repoActivated(var repo)

    /// Rows currently listed — read by the UI tests.
    readonly property int count: repos.count

    ListModel { id: repos }

    function reload() {
        page_ = 0;
        repos.clear();
        loadedOnce = false;
        fetch();
    }

    function fetch() {
        if (!app) return;
        // The first argument means different things per source: a search
        // `query` for the seed, a `scope` ("all"|"delegate"|"private"|
        // "seeded") for the local node. Passing the search box's text as a
        // scope would silently narrow to nothing, so local browsing always
        // asks for "all" and the search field is hidden for it.
        var first = (app.source === "local") ? "all" : page.query;
        var args = [first, page_, 50];
        page.loading = true;
        app.call("ListRepos", args, function (data) {
            page.loading = false;
            page.loadedOnce = true;
            var items = data.items || [];
            for (var i = 0; i < items.length; i++)
                repos.append({ repo: items[i] });
            page.hasMore = !!data.hasMore;
        }, function () {
            page.loading = false;
            page.loadedOnce = true;
        });
    }

    ListView {
        id: list
        anchors.fill: parent
        model: repos
        clip: true
        spacing: 0
        // Keep rows alive around the viewport so scrolling does not re-create
        // (and visibly re-lay-out) delegates constantly.
        cacheBuffer: Theme.rowHeight * 12
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
            required property var repo
            required property int index

            objectName: "repoRow"
            width: list.width
            height: Theme.rowHeight
            color: mouse.containsMouse ? Theme.surfaceAlt : Theme.bg
            Behavior on color { ColorAnimation { duration: Theme.animFast } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.gap
                spacing: Theme.gap

                Avatar {
                    seed: repo.rid
                    size: 32
                    Layout.alignment: Qt.AlignVCenter
                }

                // Name + description. Takes all the slack so the stat columns
                // that follow are pushed to a consistent right-hand edge.
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                        spacing: Theme.gapSm
                        Layout.fillWidth: true

                        Text {
                            text: R.repoName(repo)
                            color: Theme.text
                            font.pixelSize: Theme.fontLg
                            font.bold: true
                            elide: Text.ElideRight
                            Layout.maximumWidth: 320
                        }

                        StatusBadge {
                            status: (repo.visibility && repo.visibility.type === "private")
                                    ? "private" : ""
                        }

                        Item { Layout.fillWidth: true }
                    }

                    Text {
                        text: R.repoDescription(repo)
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        visible: text !== ""
                    }
                }

                // Stat columns. Each occupies a FIXED width and is always
                // present (an absent value renders as a dash), so the three
                // columns land on the same x on every row and read as a table.
                // Sizing them to content, or hiding empty ones, made every row
                // place them differently.
                Repeater {
                    model: [
                        { label: "issues",  value: R.projectMeta(repo).issues
                                                   ? R.projectMeta(repo).issues.open : -1 },
                        { label: "patches", value: R.projectMeta(repo).patches
                                                   ? R.projectMeta(repo).patches.open : -1 },
                        { label: "seeds",   value: repo.seeding !== undefined
                                                   ? repo.seeding : -1 }
                    ]
                    delegate: ColumnLayout {
                        required property var modelData
                        spacing: 0
                        Layout.preferredWidth: Theme.statColumn
                        Layout.minimumWidth: Theme.statColumn
                        Layout.maximumWidth: Theme.statColumn
                        Layout.alignment: Qt.AlignVCenter

                        Text {
                            text: modelData.value >= 0 ? modelData.value : "–"
                            color: modelData.value > 0 ? Theme.text : Theme.textFaint
                            font.pixelSize: Theme.fontMd
                            horizontalAlignment: Text.AlignRight
                            Layout.fillWidth: true
                        }
                        Text {
                            text: modelData.label
                            color: Theme.textFaint
                            font.pixelSize: Theme.fontXs
                            horizontalAlignment: Text.AlignRight
                            Layout.fillWidth: true
                        }
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.border
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: page.repoActivated(repo)
            }
        }

        footer: Item {
            width: list.width
            height: page.hasMore ? 52 : 0
            visible: page.hasMore
            Button {
                anchors.centerIn: parent
                text: "Load more"
                onClicked: { page.page_++; page.fetch(); }
                background: Rectangle {
                    implicitWidth: 110; implicitHeight: 28
                    radius: Theme.radius
                    color: parent.hovered ? Theme.surfaceAlt : Theme.surface
                    border.color: Theme.border
                    border.width: 1
                }
                contentItem: Text {
                    text: parent.text
                    color: Theme.text
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    LoadingState {
        anchors.fill: parent
        loading: page.loading
        loaded: page.loadedOnce
        count: repos.count
        emptyText: "No repositories matched"
        loadingText: "Loading repositories…"
    }
}
