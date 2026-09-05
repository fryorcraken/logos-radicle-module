.pragma library

/*
 * Design tokens.
 *
 * A .pragma library rather than a QML singleton on purpose.
 *
 * The module builder generates its own `qmldir` (`module com.logos.module.<name>`)
 * which replaces any hand-written one, so a `singleton Theme 1.0 Theme.qml`
 * line does not survive packaging. Basecamp also puts the install dir on the
 * import path, making the same directory both a named-import root and an
 * implicit one — an ambiguity that resolved standalone but not in Basecamp.
 * Either way `Theme` came out undefined, every
 * `Layout.preferredHeight: Theme.barHeight` became undefined, every row got
 * zero height, and the whole view collapsed onto one line with no error logged
 * anywhere. A .js import resolves by relative path and cannot fail that way.
 *
 * Basecamp does ship an official `Logos.Theme` QML module (from
 * logos-design-system, allowlisted by its QML sandbox) which would be the
 * better long-term home for these tokens.
 *
 * The FIXED SIZES matter as much as the colours: chrome heights are pinned so
 * the header, tab bar and status strip occupy the same pixels on every screen,
 * and only the content area changes.
 */

var bg = "#0d1117";
var surface = "#161b22";
var surfaceAlt = "#1c2129";
var raised = "#242b35";
var border = "#30363d";
var borderStrong = "#3d444d";
var text = "#e6edf3";
var textDim = "#8b949e";
var textFaint = "#6e7681";
var textOnAccent = "#0d1117";
var accent = "#58a6ff";
var accentSoft = "#1f6feb";
var good = "#3fb950";
var merged = "#a371f7";
var warn = "#d29922";
var bad = "#f85149";
var mono = "monospace";
var fontXs = 10;
var fontSm = 11;
var fontMd = 12;
var fontLg = 14;
var fontXl = 16;
var gapXs = 4;
var gapSm = 8;
var gap = 12;
var gapLg = 16;
var radiusSm = 4;
var radius = 6;
var radiusPill = 999;
var barHeight = 52;
var headerHeight = 60;
var tabHeight = 38;
var statusHeight = 24;
var rowHeight = 56;
var rowHeightSm = 28;
var sidebarWidth = 300;
var animFast = 120;
var animMed = 180;

// Repo-list column widths. The stat columns are fixed and right-aligned so
// they line up down the page: sizing them to their own content made each row
// place them differently, which read as a jitter rather than a table.
var statColumn = 72;
var statGap = 8;

// Branch picker.
//
// `pickerWidth` is FIXED, deliberately, and that is the outcome of getting it
// wrong three times. An earlier version measured the widest label and sized
// the popup to it; because every row carried a `<nid>…/` prefix, the measured
// width ballooned to ~480px against a 140px control and read as a floating
// panel rather than that control's menu. Hoisting the node id into a section
// header — one occurrence per peer instead of one per row — removed the
// content that demanded the width. A stable, predictable panel is worth more
// than a snugly-fitted one; long names elide and the filter field is the
// escape hatch.
var pickerWidth = 300;
var pickerMaxHeight = 380;
var pickerTrigger = 180;   // the closed chip
// Denser than rowHeightSm (28), which is loose for a list that can hold 84
// branches across 5 peers.
var rowHeightXs = 22;
// Only worth offering a filter field when scanning is actually hard. Below
// this the box is furniture — it applies to both sources, so a 2-branch local
// repo and a 5-branch seed repo both get a plain list.
var pickerSearchThreshold = 8;

// Peer identity colours. Indexed by a hash of the FULL node id, never the
// abbreviated label: two peers can share a `gFq6z5…` prefix, and giving them
// one colour would undo the only thing telling them apart at a glance.
var peerDots = ["#58a6ff", "#3fb950", "#d29922", "#a371f7",
                "#f85149", "#39c5cf", "#db6d28", "#8b949e"];

/// Stable colour for a peer, derived from its node id.
function peerColor(nid) {
    var h = 0;
    for (var i = 0; i < nid.length; i++)
        h = ((h << 5) - h + nid.charCodeAt(i)) | 0;
    return peerDots[Math.abs(h) % peerDots.length];
}
