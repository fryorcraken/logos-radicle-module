import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Theme.js" as Theme

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
    /// While true the pane shows a loading state instead of `body`. Without
    /// this a click on a new file left the PREVIOUS file's text on screen
    /// until the reply arrived, which reads as "this is that file".
    property bool loading: false

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
                visible: !viewer.loading
                text: viewer.loading ? "" : viewer.body
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

    // Same treatment as the repository and file lists: pulsing dots while a
    // request is in flight, and a distinct message once one has completed with
    // nothing to show. A bare "Loading…" here read as a different, lesser kind
    // of waiting than everywhere else in the app.
    LoadingState {
        anchors.fill: parent
        loading: viewer.loading
        // A file pane has no "loaded but empty" state to report: before a
        // selection there is simply nothing to show, which the emptyText
        // covers.
        loaded: true
        count: viewer.body === "" ? 0 : 1
        emptyText: "Select a file"
        loadingText: "Loading file…"
    }
}
