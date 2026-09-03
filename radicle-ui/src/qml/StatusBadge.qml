import QtQuick
import "Theme.js" as Theme

/// Coloured pill for an issue/patch state (open, closed, merged, draft…).
/// Colour AND text, never colour alone.
Rectangle {
    id: badge

    property string status: ""

    readonly property color tone: {
        if (status === "open")     return Theme.good;
        if (status === "merged")   return Theme.merged;
        if (status === "draft")    return Theme.textFaint;
        if (status === "archived") return Theme.warn;
        if (status === "closed")   return Theme.bad;
        return Theme.textDim;
    }

    visible: status !== ""
    implicitWidth: label.implicitWidth + 16
    implicitHeight: 18
    radius: Theme.radiusPill
    color: Qt.rgba(tone.r, tone.g, tone.b, 0.15)
    border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.45)
    border.width: 1

    Text {
        id: label
        anchors.centerIn: parent
        text: badge.status
        font.pixelSize: Theme.fontXs
        font.bold: true
        color: badge.tone
    }
}
