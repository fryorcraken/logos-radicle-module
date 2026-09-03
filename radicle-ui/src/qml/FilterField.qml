import QtQuick
import QtQuick.Controls
import "Theme.js" as Theme

/// Themed text input. Wrapped so every field looks the same and the focus
/// ring is consistent.
///
/// Named FilterField, not SearchField: QtQuick.Controls ships a SearchField in
/// recent versions and it wins name resolution, silently shadowing a local file
/// of that name.
TextField {
    id: field

    property string placeholder: ""

    placeholderText: placeholder
    color: Theme.text
    placeholderTextColor: Theme.textFaint
    font.pixelSize: Theme.fontMd
    leftPadding: Theme.gapSm
    rightPadding: Theme.gapSm
    implicitHeight: 30

    background: Rectangle {
        radius: Theme.radius
        color: Theme.bg
        border.color: field.activeFocus ? Theme.accent : Theme.border
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: Theme.animFast } }
    }
}
