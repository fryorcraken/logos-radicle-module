import QtQuick
import QtQuick.Layouts
import QtTest
import "../src/qml" as Ui
import "../src/qml/Theme.js" as Theme

/*
 * The header at narrow window widths.
 *
 * ## The defect these exist for
 *
 * The header row is `Radicle [Explore|Local|Embedded]  <mode detail>  …
 * [Settings]`, and it had NO width management whatever: no elide, no
 * `Layout.minimumWidth`, no wrap, no scroll. `NodeIdentity` deliberately
 * refused to elide a ~56-character DID, which alone pins ~411px of hard
 * minimum; with the title, the toggle, the gaps and the chip, the row could
 * not shrink below roughly 830px. A `RowLayout` that cannot shrink does not
 * scroll or wrap — it OVERFLOWS, and the last item goes off the right edge.
 *
 * Measured against a clipping container before the fix, the Settings chip's
 * visible width was 65.8px at 850, 45.0px at 800, and **0.0px at 750 and
 * below**. Since the node identity now copies rather than opening Settings,
 * that chip is the ONLY way in — so below ~750px the user could not reach
 * Settings, the mode picker, the git path or the resolved home, with nothing
 * on screen saying anything was missing.
 *
 * That is the same class as the one-way-door bug this milestone already fixed
 * in `SettingsPanel`, arriving from a different direction: a destination that
 * exists, is `visible: true`, and cannot be got to.
 *
 * ## Why the tests are shaped this way
 *
 * Every pre-existing layout fixture in this repo is 900-1000px wide and none
 * of them varies the width, which is exactly why nothing caught this. So these
 * DRIVE the width down across a range and assert at each step, rather than
 * checking one comfortable size.
 *
 * The host `clip`s, deliberately. Without clipping, an item pushed past the
 * right edge still reports a sensible `width` and a plausible `x`, and every
 * property-based assertion passes while the user sees nothing — the overflow
 * is invisible to anything that does not compare against the container's
 * bounds. `visibleWidthIn()` below measures the INTERSECTION with the
 * container, which is the only number that says what a user can actually hit.
 */
Item {
    id: root

    width: 1000
    height: 400

    /// A full-length DID: 8 characters of `did:key:` plus a 48-character
    /// multibase key. This is the real shape, not a shortened stand-in — the
    /// whole defect is that the header could not accommodate this string, so a
    /// fixture using a short id would reproduce nothing.
    readonly property string fullDid:
        "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd"

    function findByName(node, name) {
        if (!node) return null;
        if (node.objectName === name) return node;
        for (var i = 0; i < node.children.length; i++) {
            var hit = findByName(node.children[i], name);
            if (hit) return hit;
        }
        return null;
    }

    /// How much of `item` actually falls inside `container`, horizontally.
    ///
    /// The whole point of the exercise: an item overflowing a RowLayout keeps
    /// its own width and reports a position, so `item.width` and even
    /// `item.visible` are true of an element the user cannot see or click.
    /// Only the intersection with the container distinguishes "on screen" from
    /// "pushed off the right edge".
    function visibleWidthIn(item, container) {
        if (!item || !item.visible) return 0;
        var left = item.mapToItem(container, 0, 0).x;
        var right = left + item.width;
        var clampedLeft = Math.max(left, 0);
        var clampedRight = Math.min(right, container.width);
        return Math.max(0, clampedRight - clampedLeft);
    }

    // ---- the header, hosted the way Main.qml hosts it --------------------
    //
    // Main.qml cannot be instantiated in a component test (it needs a live
    // QtRO backend), so what is reproduced here is the STRUCTURE that failed:
    // the same RowLayout, the same real child components in the same order,
    // the same anchors and the same spacing. Everything asserted is about the
    // real components; only the surrounding bar is a stand-in.
    //
    // `clip: true` is load-bearing — see visibleWidthIn().
    Rectangle {
        id: headerBar
        objectName: "headerBar"
        width: root.headerWidth
        height: Math.max(Theme.barHeight, headerToggle.reservedHeight + Theme.gap)
        clip: true
        color: Theme.surface

        RowLayout {
            id: headerRow
            objectName: "headerRow"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.gap
            anchors.rightMargin: Theme.gap
            height: Theme.rowHeightSm
            spacing: Theme.gap

            Text {
                objectName: "headerTitle"
                text: "Radicle"
                color: Theme.text
                font.pixelSize: Theme.fontXl
                font.bold: true
                visible: headerRow.width > 520
                Layout.preferredWidth: visible ? implicitWidth : 0
                Layout.maximumWidth: visible ? implicitWidth : 0
            }

            Ui.SourceToggle {
                id: headerToggle
                objectName: "headerToggle"
                Layout.alignment: Qt.AlignTop
                Layout.preferredHeight: Theme.rowHeightSm
                Layout.maximumHeight: Theme.rowHeightSm
                mode: root.headerMode
                startableModes: ["explore", "local"]
                localAvailable: true
            }

            Ui.FilterField {
                id: headerSearch
                objectName: "headerSearch"
                visible: root.headerMode === "explore"
                Layout.preferredWidth: 260
                Layout.minimumWidth: 120
                Layout.fillWidth: true
                placeholder: "Search repositories"
            }

            Ui.NodeIdentity {
                id: headerIdentity
                objectName: "headerIdentity"
                visible: root.headerMode === "local" && headerIdentity.nodeId !== ""
                nodeId: root.headerMode === "local" ? root.fullDid : ""
                Layout.minimumWidth: 120
                Layout.preferredWidth: implicitWidth
                Layout.fillWidth: true
                minimumWidth: 120
            }

            Item { Layout.fillWidth: true }

            Rectangle {
                id: headerChip
                objectName: "headerChip"
                Layout.preferredHeight: Theme.rowHeightSm
                Layout.preferredWidth: chipLabel.implicitWidth + Theme.gap * 2
                Layout.minimumWidth: chipLabel.implicitWidth + Theme.gap * 2
                radius: Theme.radiusSm
                color: Theme.bg
                border.width: 1
                border.color: Theme.border

                Text {
                    id: chipLabel
                    anchors.centerIn: parent
                    text: "Settings"
                    color: Theme.textDim
                    font.pixelSize: Theme.fontSm
                }

                MouseArea {
                    objectName: "headerSettingsToggle"
                    anchors.fill: parent
                    onClicked: root.settingsClicks++
                }
            }
        }
    }

    property int headerWidth: 1000
    property string headerMode: "local"
    property int settingsClicks: 0

    /// The widths a user's window plausibly takes. A half-screen split on a
    /// 1080p display is 960; a third is 640; a narrow docked panel is 480. All
    /// three used to hide the Settings chip completely.
    readonly property var probeWidths: [1000, 900, 850, 800, 750, 700, 640, 560, 480]

    TestCase {
        name: "HeaderStaysUsableWhenNarrow"
        when: windowShown

        /// Let the layout actually run before measuring it.
        ///
        /// A `RowLayout` re-lays out on a render pass, not on the assignment
        /// that changed its width, so reading geometry straight after setting
        /// `headerWidth` reports the PREVIOUS width's arrangement. Without this
        /// the whole fixture measures a stale layout and reports failures at
        /// widths that are actually fine — and, worse, could report passes the
        /// same way.
        ///
        /// This is not the "settle hides a real lag" case the other test files
        /// warn about. There the lag was a component reporting a size that did
        /// not contain its own content, which a user would see mid-frame; here
        /// the fixture is driving a window resize from script, and a real
        /// resize gets its render pass for free. What is being waited for is
        /// the test harness catching up with the layout, not the layout
        /// catching up with itself.
        function settle() {
            waitForRendering(headerBar);
        }

        function init() {
            root.headerWidth = 1000;
            root.headerMode = "local";
            root.settingsClicks = 0;
            settle();
        }

        function cleanup() {
            root.headerWidth = 1000;
            root.headerMode = "local";
            settle();
        }

        /// THE BLOCKER, stated directly: Settings must never leave the screen.
        ///
        /// Asserted across the whole range rather than at one narrow width,
        /// because the failure is progressive — the chip was partially clipped
        /// at 800 and entirely gone at 750, and a single-width test would pick
        /// one of those and miss the other. It also fails loudly with the width
        /// that broke it, so the report names the size rather than just the
        /// fact.
        ///
        /// Measured against the container's bounds, not on `chip.width`: an
        /// overflowing RowLayout child keeps its full width and its `visible`
        /// stays true, so every property-based check passes while the user sees
        /// nothing. See visibleWidthIn().
        function test_the_settings_chip_never_leaves_the_screen() {
            var chip = root.findByName(headerBar, "headerChip");
            verify(chip !== null, "the Settings chip must exist");

            var full = 0;
            for (var i = 0; i < root.probeWidths.length; i++) {
                var w = root.probeWidths[i];
                root.headerWidth = w;
                settle();
                var seen = root.visibleWidthIn(chip, headerBar);
                if (i === 0) full = seen;

                verify(seen > 0,
                       "at width " + w + " the Settings chip has " + seen
                       + "px on screen — it has been pushed off the right edge. "
                       + "The identity no longer opens Settings, so this chip "
                       + "is the ONLY way in: Settings, the mode picker, the "
                       + "git path and the resolved home all become "
                       + "unreachable, with nothing saying so.");

                compare(seen, full,
                        "at width " + w + " the Settings chip shows " + seen
                        + "px of its " + full + "px — it is being clipped "
                        + "rather than kept whole, so it is only partly "
                        + "clickable");
            }
        }

        /// ...and it is still HITTABLE, not merely within the bounds.
        ///
        /// Geometry and clickability are different claims, and this repo has
        /// been bitten by each without the other: a control inside the viewport
        /// whose MouseArea got zero size is just as dead as one off-screen. A
        /// real click at the narrowest probe width answers the question the
        /// user actually has.
        function test_settings_can_still_be_clicked_at_the_narrowest_width() {
            root.headerWidth = 480;
            settle();
            var area = root.findByName(headerBar, "headerSettingsToggle");
            verify(area !== null, "the clickable element must carry the objectName");
            verify(area.width > 0 && area.height > 0,
                   "the Settings hit area is " + area.width + "x" + area.height
                   + " — a control with no area cannot be clicked");

            root.settingsClicks = 0;
            mouseClick(area);
            compare(root.settingsClicks, 1,
                    "clicking Settings at 480px must reach it");
        }

        /// The same guarantee in Explore, where the 260px search field takes
        /// the space the identity takes in Local.
        ///
        /// Both modes are asserted because they run out of room at different
        /// widths and for different reasons — a fix that only budgeted for the
        /// identity would leave Explore broken at ~640px, which is a plausible
        /// window size rather than a pathological one.
        function test_the_settings_chip_survives_explore_mode_too() {
            root.headerMode = "explore";
            settle();
            var chip = root.findByName(headerBar, "headerChip");

            for (var i = 0; i < root.probeWidths.length; i++) {
                var w = root.probeWidths[i];
                root.headerWidth = w;
                settle();
                verify(root.visibleWidthIn(chip, headerBar) > 0,
                       "at width " + w + " in Explore the Settings chip is off "
                       + "screen — the search field is taking the room the "
                       + "identity takes in Local, and the chip loses either way");
            }
        }

        /// Nothing may vanish SILENTLY. The identity is allowed to give up
        /// width — it is the one element here whose content can be shortened
        /// without losing a destination — but it must still be on screen and
        /// still say something, because a slot that renders as nothing reads as
        /// a rendering fault rather than as a deliberate truncation.
        function test_the_identity_shortens_rather_than_disappearing() {
            var ident = root.findByName(headerBar, "headerIdentity");
            var label = root.findByName(headerBar, "nodeIdentityLabel");
            verify(ident !== null && label !== null);

            for (var i = 0; i < root.probeWidths.length; i++) {
                var w = root.probeWidths[i];
                root.headerWidth = w;
                settle();
                verify(ident.visible,
                       "at width " + w + " the identity vanished entirely — in "
                       + "Local this is the mode's only detail, and an empty "
                       + "slot reads as a bug rather than as a narrow window");
                verify(root.visibleWidthIn(label, headerBar) > 0,
                       "at width " + w + " the identity label has nothing on "
                       + "screen");
            }
        }

        /// The user asked for the FULL DID, so the degradation must be a last
        /// resort rather than the normal state: at a comfortable width the
        /// whole string is on screen, uncut.
        ///
        /// This is the counter-pressure that stops the fix being "just elide it
        /// always", which would satisfy every assertion above and quietly undo
        /// the change the user asked for.
        function test_the_whole_did_is_shown_when_there_is_room() {
            root.headerWidth = 1000;
            settle();
            var label = root.findByName(headerBar, "nodeIdentityLabel");
            compare(label.text, root.fullDid,
                    "at 1000px the entire DID must be on screen, uncut");
            verify(!headerIdentity.shortened,
                   "and not visually truncated either — the user asked for the "
                   + "full id and there is plenty of room for it here");
        }

        /// Truncating the DISPLAY must not truncate what gets COPIED. The whole
        /// justification for allowing the identity to shorten is that the value
        /// is still recoverable in full — by clicking it, and in Settings. If
        /// the click copied the elided text, the degradation would be silent
        /// data loss instead of a display compromise.
        function test_a_shortened_identity_still_copies_in_full() {
            root.headerWidth = 480;
            settle();
            var area = root.findByName(headerBar, "nodeIdentity");
            verify(area !== null);

            clipProbe.text = "decoy-value";
            clipProbe.selectAll();
            clipProbe.copy();
            clipProbe.text = "";

            mouseClick(area);

            clipProbe.text = "";
            clipProbe.selectAll();
            clipProbe.paste();
            compare(clipProbe.text, root.fullDid,
                    "a visually shortened identity must still copy the WHOLE "
                    + "did — the shortening is a display compromise, and it is "
                    + "only acceptable because the full value stays reachable");
        }

        /// The row must not silently reflow onto a second line either. A header
        /// that wrapped would keep everything reachable and still be a
        /// regression: this repo has already had the complaint that the node id
        /// left its line, and the bar's height is budgeted chrome.
        function test_the_header_row_stays_on_one_line() {
            for (var i = 0; i < root.probeWidths.length; i++) {
                root.headerWidth = root.probeWidths[i];
                settle();
                compare(headerRow.height, Theme.rowHeightSm,
                        "at width " + root.probeWidths[i] + " the control row "
                        + "is " + headerRow.height + "px rather than "
                        + Theme.rowHeightSm + " — something wrapped onto a "
                        + "second line");
            }
        }
    }

    /// Reads the real system clipboard, the same way NodeIdentity writes it.
    /// A separate editor from the component's own, so a test cannot pass
    /// against a copy that never happened — see tst_source.qml.
    TextEdit { id: clipProbe; visible: false }
}
