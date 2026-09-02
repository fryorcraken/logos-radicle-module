pragma Singleton
import QtQuick

// Local palette. The Logos design system (Logos.Theme) is not available in
// every basecamp build, so these are plain values to keep the module loadable
// everywhere. Dark, matching basecamp's default shell.
QtObject {
    readonly property color bg:          "#0d1117"
    readonly property color panel:       "#161b22"
    readonly property color panelAlt:    "#1c2129"
    readonly property color border:      "#30363d"
    readonly property color text:        "#e6edf3"
    readonly property color textDim:     "#8b949e"
    readonly property color accent:      "#58a6ff"
    readonly property color good:        "#3fb950"
    readonly property color warn:        "#d29922"
    readonly property color bad:         "#f85149"
    readonly property color merged:      "#a371f7"

    readonly property int radius:        6
    readonly property int pad:           12
    readonly property int gap:           8

    readonly property string mono:       "monospace"
}
