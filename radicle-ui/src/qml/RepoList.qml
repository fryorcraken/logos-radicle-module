import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R

// Repository browser. Under the remote source this searches every repo the
// seed replicates; under the local source it lists this machine's own repos,
// private ones included.
Item {
    id: page

    property string query: ""
    property int page_: 0
    property bool hasMore: false
    property bool loading: false

    signal repoActivated(var repo)

    /// Injected by Main.qml: owns backend call routing and source selection.
    property var app: null

    ListModel { id: repos }

    function reload() {
        page_ = 0;
        repos.clear();
        fetch();
    }

    function fetch() {
        if (!app) return;
        // Remote takes a search query; local takes a scope. Same shape back.
        var args = app.source === "local"
                 ? ["all", page_, 50]
                 : [page.query, page_, 50];
        page.loading = true;
        app.call("ListRepos", args, function (data) {
            page.loading = false;
            var items = data.items || [];
            for (var i = 0; i < items.length; i++)
                repos.append({ repo: items[i] });
            page.hasMore = !!data.hasMore;
        }, function () {
            page.loading = false;
        });
    }

    ScrollView {
        anchors.fill: parent
        clip: true

        ListView {
            id: list
            model: repos
            spacing: 1

            delegate: ItemDelegate {
                required property var repo
                required property int index

                width: list.width
                height: 68

                onClicked: page.repoActivated(repo)

                background: Rectangle {
                    color: parent.hovered ? Theme.panelAlt : Theme.bg
                }

                contentItem: RowLayout {
                    spacing: Theme.pad

                    // Local identicon — the QML sandbox blocks remote images.
                    Rectangle {
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        radius: Theme.radius
                        color: R.tint(repo.rid)
                        Label {
                            anchors.centerIn: parent
                            text: R.initial(R.repoName(repo))
                            color: "#0d1117"
                            font.bold: true
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        RowLayout {
                            spacing: Theme.gap
                            Label {
                                text: R.repoName(repo)
                                color: Theme.text
                                font.pixelSize: 14
                                font.bold: true
                            }
                            Rectangle {
                                visible: repo.visibility && repo.visibility.type === "private"
                                color: Theme.warn
                                radius: 3
                                implicitWidth: privateLabel.width + 8
                                implicitHeight: 15
                                Label {
                                    id: privateLabel
                                    anchors.centerIn: parent
                                    text: "private"
                                    color: "#0d1117"
                                    font.pixelSize: 9
                                    font.bold: true
                                }
                            }
                        }

                        Label {
                            text: R.repoDescription(repo)
                            color: Theme.textDim
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            visible: text !== ""
                        }

                        RowLayout {
                            spacing: Theme.pad
                            Label {
                                text: R.short(repo.rid, 12)
                                color: Theme.textDim
                                font.pixelSize: 10
                                font.family: Theme.mono
                            }
                            Label {
                                readonly property var m: R.projectMeta(repo)
                                visible: m.issues !== undefined
                                text: (m.issues ? m.issues.open : 0) + " issues"
                                color: Theme.textDim
                                font.pixelSize: 10
                            }
                            Label {
                                readonly property var m: R.projectMeta(repo)
                                visible: m.patches !== undefined
                                text: (m.patches ? m.patches.open : 0) + " patches"
                                color: Theme.textDim
                                font.pixelSize: 10
                            }
                            Label {
                                visible: repo.seeding !== undefined
                                text: repo.seeding + " seeding"
                                color: Theme.textDim
                                font.pixelSize: 10
                            }
                        }
                    }
                }
            }

            // Paging: one more page when the user reaches the end.
            footer: Item {
                width: list.width
                height: page.hasMore ? 44 : 0
                visible: page.hasMore
                Button {
                    anchors.centerIn: parent
                    text: "Load more"
                    onClicked: { page.page_++; page.fetch(); }
                }
            }
        }
    }

    // Empty state, distinct from "still loading".
    Label {
        anchors.centerIn: parent
        visible: repos.count === 0 && !page.loading
        text: (page.app && page.app.source === "local")
              ? "No local repositories found"
              : "No repositories matched"
        color: Theme.textDim
    }
}
