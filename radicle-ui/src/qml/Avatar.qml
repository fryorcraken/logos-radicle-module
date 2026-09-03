import QtQuick
import "Radicle.js" as R

/// Identicon-style square. Rendered locally from the id — the QML sandbox
/// blocks remote images, so there are no avatar URLs to fetch.
Rectangle {
    id: avatar

    property string seed: ""
    property int size: 34

    implicitWidth: size
    implicitHeight: size
    radius: Theme.radiusSm
    color: R.tint(seed)

    Text {
        anchors.centerIn: parent
        text: R.initial(avatar.seed)
        font.pixelSize: Math.round(avatar.size * 0.45)
        font.bold: true
        color: Theme.textOnAccent
    }
}
