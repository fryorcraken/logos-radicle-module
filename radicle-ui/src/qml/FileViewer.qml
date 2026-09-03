import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/*
 * Plain monospace file viewer.
 *
 * No syntax highlighting: Radicle Desktop gets pre-tokenized lines from its
 * Rust backend, but the seed API returns raw text. Rendering it honestly as
 * plain text beats a half-working highlighter.
 */
Rectangle {
    id: viewer

    property string title: ""
    property string body: ""

    color: Theme.bg

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Filename bar — always present so the text below never shifts.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.rowHeightSm
            color: Theme.surfaceAlt

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.gap
                anchors.right: parent.right
                anchors.rightMargin: Theme.gap
                text: viewer.title
                color: Theme.textDim
                font.pixelSize: Theme.fontSm
                font.family: Theme.mono
                elide: Text.ElideMiddle
            }
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.border
            }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            TextArea {
                text: viewer.body
                readOnly: true
                selectByMouse: true
                wrapMode: TextArea.NoWrap
                color: Theme.text
                font.family: Theme.mono
                font.pixelSize: Theme.fontMd
                leftPadding: Theme.gap
                topPadding: Theme.gapSm
                background: null
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: viewer.body === ""
        text: "Select a file"
        color: Theme.textFaint
        font.pixelSize: Theme.fontLg
    }
}
