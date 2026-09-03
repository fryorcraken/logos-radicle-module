pragma Singleton
import QtQuick

/*
 * Design tokens for the Radicle module.
 *
 * Everything visual comes from here so the UI reads as one system rather than
 * a pile of ad-hoc literals. The Logos design system (Logos.Theme) is not
 * available in every basecamp build, so these are plain values — the module
 * stays loadable everywhere.
 *
 * The FIXED SIZES below matter as much as the colours: the layout jumped
 * between screens because every view sized itself from its own content. Chrome
 * heights are pinned here so the header, tab bar and status strip occupy the
 * same pixels on every screen, and only the content area below them changes.
 */
QtObject {
    // ---- surfaces (darkest → lightest) --------------------------------
    readonly property color bg:        "#0d1117"   // page
    readonly property color surface:   "#161b22"   // panels, header
    readonly property color surfaceAlt:"#1c2129"   // hover, inset rows
    readonly property color raised:    "#242b35"   // selected rows, chips

    // ---- lines --------------------------------------------------------
    readonly property color border:      "#30363d"
    readonly property color borderStrong:"#3d444d"

    // ---- text ---------------------------------------------------------
    readonly property color text:      "#e6edf3"
    readonly property color textDim:   "#8b949e"
    readonly property color textFaint: "#6e7681"
    readonly property color textOnAccent: "#0d1117"   // NB: cannot be named `onAccent` — QML reads on* as a signal handler

    // ---- accents ------------------------------------------------------
    readonly property color accent:      "#58a6ff"
    readonly property color accentSoft:  "#1f6feb"
    readonly property color good:        "#3fb950"   // open
    readonly property color merged:      "#a371f7"   // merged
    readonly property color warn:        "#d29922"   // draft / archived / private
    readonly property color bad:         "#f85149"   // closed / error

    // ---- typography ---------------------------------------------------
    readonly property string mono: "monospace"
    readonly property int fontXs: 10
    readonly property int fontSm: 11
    readonly property int fontMd: 12
    readonly property int fontLg: 14
    readonly property int fontXl: 16

    // ---- spacing ------------------------------------------------------
    readonly property int gapXs: 4
    readonly property int gapSm: 8
    readonly property int gap:   12
    readonly property int gapLg: 16

    readonly property int radiusSm: 4
    readonly property int radius:   6
    readonly property int radiusPill: 999

    // ---- fixed chrome heights -----------------------------------------
    // Pinned so panels do not move as content loads or screens change.
    readonly property int barHeight:     52   // top bar
    readonly property int headerHeight:  60   // repo header
    readonly property int tabHeight:     38   // tab strip
    readonly property int statusHeight:  24   // status strip (always present)
    readonly property int rowHeight:     56   // list rows
    readonly property int rowHeightSm:   28   // tree rows
    readonly property int sidebarWidth: 300

    readonly property int animFast: 120
    readonly property int animMed:  180
}
