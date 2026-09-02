import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R

Item {
    id: tab
    property var app: null
    property string rid: ""
    property string branch: ""
    property int page_: 0
    property bool hasMore: false

    ListModel { id: commits }

    function load() {
        page_ = 0;
        commits.clear();
        fetch();
    }

    function fetch() {
        if (!app || rid === "") return;
        app.call("ListCommits", [rid, branch, page_, 50], function (data) {
            var items = data.items || [];
            for (var i = 0; i < items.length; i++)
                commits.append({ c: items[i] });
            tab.hasMore = !!data.hasMore;
        });
    }

    ScrollView {
        anchors.fill: parent
        clip: true

        ListView {
            model: commits
            spacing: 1

            delegate: Rectangle {
                required property var c
                width: ListView.view.width
                height: 54
                color: Theme.bg

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.pad
                    anchors.rightMargin: Theme.pad
                    spacing: Theme.pad

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Label {
                            text: c.summary || ""
                            color: Theme.text
                            font.pixelSize: 13
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Label {
                            text: R.authorName(c.author)
                                  + " · " + R.when(c.committer ? c.committer.time : 0)
                            color: Theme.textDim
                            font.pixelSize: 10
                        }
                    }

                    Label {
                        text: R.short(c.id, 7)
                        color: Theme.accent
                        font.pixelSize: 11
                        font.family: Theme.mono
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: Theme.border
                }
            }

            footer: Item {
                width: parent ? parent.width : 0
                height: tab.hasMore ? 44 : 0
                visible: tab.hasMore
                Button {
                    anchors.centerIn: parent
                    text: "Load more"
                    onClicked: { tab.page_++; tab.fetch(); }
                }
            }
        }
    }
}
