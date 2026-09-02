import QtQuick
import QtQuick.Controls

// Plain monospace file viewer.
//
// No syntax highlighting: Radicle Desktop gets pre-tokenized lines from its
// Rust backend, but the seed API returns raw text. Rendering it honestly as
// plain text beats a half-working highlighter.
Rectangle {
    id: viewer

    property string title: ""
    property string body: ""

    color: Theme.bg

    Column {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            width: parent.width
            height: viewer.title === "" ? 0 : 28
            visible: viewer.title !== ""
            color: Theme.panelAlt
            Label {
                anchors.verticalCenter: parent.verticalCenter
                x: Theme.pad
                text: viewer.title
                color: Theme.textDim
                font.pixelSize: 11
                font.family: Theme.mono
            }
        }

        ScrollView {
            width: parent.width
            height: parent.height - (viewer.title === "" ? 0 : 28)
            clip: true

            TextArea {
                text: viewer.body
                readOnly: true
                selectByMouse: true
                wrapMode: TextArea.NoWrap
                color: Theme.text
                font.family: Theme.mono
                font.pixelSize: 12
                background: null
            }
        }
    }

    Label {
        anchors.centerIn: parent
        visible: viewer.body === ""
        text: "Select a file"
        color: Theme.textDim
    }
}
