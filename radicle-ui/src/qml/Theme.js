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
