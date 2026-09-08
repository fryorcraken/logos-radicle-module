import QtQuick
import QtQuick.Layouts
import QtTest
import "../src/qml" as Ui
import "../src/qml/Theme.js" as Theme

/*
 * Settings must be reachable at every window width.
 *
 * ## The defect, and the two goes it has taken
 *
 * The header is `Radicle [Explore|Local|Embedded]  <mode detail>  [Settings]`,
 * and it originally had NO width management whatever: no elide, no
 * `Layout.minimumWidth`, no wrap, no scroll. `NodeIdentity` refused to elide a
 * ~56-character DID, which alone pins ~411px of hard minimum; with the title,
 * the toggle, the gaps and the chip, the row could not shrink below roughly
 * 830px. A `RowLayout` that cannot shrink does not scroll or wrap — it
 * OVERFLOWS, and the last item goes off the right edge. Measured against a
 * clipping container: the Settings chip had 65.8px on screen at 850, 45.0px at
 * 800, and **0.0px at 750 and below**.
 *
 * Since the identity copies rather than opening Settings, that chip is the ONLY
 * way in — so below ~750px Settings, the mode picker, the git path and the
 * resolved home were all unreachable, with nothing on screen saying so. That is
 * the same class as the one-way-door bug this milestone already fixed in
 * `SettingsPanel`, arriving from a different direction: a destination that
 * exists, is `visible: true`, and cannot be got to.
 *
 * The FIRST fix made the chip incompressible and made two elements yield: the
 * identity elided down to a 120px floor, and the search field shrank 260→120.
 * That was rejected, and — this is the part worth keeping in mind — it did not
 * even work. Driven to 400px, the chip still had **6px of its 65.8px on screen
 * and a real click reached nothing**: a RowLayout whose minimums do not fit
 * overflows regardless of which child is incompressible. Making the chip
 * unshrinkable only decided WHICH pixels were lost.
 *
 * The user asked for the other trade — *"can you instead make it go on the next
 * line?"* — and that is what the header does now. This file pins the
 * requirement that survived both attempts: **Settings is on screen and
 * clickable at every width.**
 *
 * ## Why the tests are shaped this way
 *
 * Every pre-existing layout fixture in this repo is 900-1000px wide and none of
 * them varies the width, which is exactly why the original defect shipped. So
 * these DRIVE the width down across a range and assert at each step.
 *
 * The DID is the REAL 56-character one, not a shortened stand-in. That is not
 * decoration: the whole defect is that the header could not accommodate this
 * string, so a fixture with a short id reproduces nothing.
 *
 * The host `clip`s, deliberately. Without clipping, an item pushed past an edge
 * still reports a sensible `width` and a plausible `x`, and every
 * property-based assertion passes while the user sees nothing — the overflow is
 * invisible to anything that does not compare against the container's bounds.
 * `visibleWidthIn()` measures the INTERSECTION with the container, which is the
 * only number that says what a user can actually hit. `visibleHeightIn()` is
 * the same measurement in the other axis, and it is what makes a WRAPPING
 * header testable at all: a chip on a second line the bar did not grow to hold
 * is exactly as unreachable as one off the right edge, and only a vertical
 * intersection can tell that from a working wrap.
 */
Item {
    id: root

    width: 1400
    height: 500

    /// A full-length DID: 8 characters of `did:key:` plus a 48-character
    /// multibase key — the user's real one. The whole defect is about this
    /// string's length, so a shortened stand-in would prove nothing.
    readonly property string fullDid:
        "did:key:z6MkowunyxpkcgCx2DdndJwebjcpk5pEnhaDE8JH3MbLnDBe"

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
    /// An item overflowing a layout keeps its own width and reports a position,
    /// so `item.width` and even `item.visible` are true of an element the user
    /// cannot see or click. Only the intersection with the container
    /// distinguishes "on screen" from "pushed off the edge".
    function visibleWidthIn(item, container) {
        if (!item || !item.visible) return 0;
        var left = item.mapToItem(container, 0, 0).x;
        var right = left + item.width;
        return Math.max(0, Math.min(right, container.width) - Math.max(left, 0));
    }

    /// The same in the vertical axis — the measurement a wrapping header needs.
    ///
    /// Wrapping trades a horizontal overflow for a vertical one whenever the
    /// container does not grow to hold the line it just created, and that
    /// failure is invisible to every horizontal assertion in this file.
    function visibleHeightIn(item, container) {
        if (!item || !item.visible) return 0;
        var top = item.mapToItem(container, 0, 0).y;
        var bottom = top + item.height;
        return Math.max(0, Math.min(bottom, container.height) - Math.max(top, 0));
    }

    /// The y of an item's centre within `container` — how lines are told apart.
    function centreYIn(item, container) {
        return item.mapToItem(container, 0, item.height / 2).y;
    }

    // ---- the header, hosted the way Main.qml hosts it --------------------
    //
    // Main.qml cannot be instantiated in a component test (it needs a live QtRO
    // backend), so what is reproduced here is the STRUCTURE: the same Flow, the
    // same real child components in the same order, the same margins and
    // spacing, and the same bar-height arithmetic. Everything asserted is about
    // the real components; only the surrounding bar is a stand-in.
    //
    // `clip: true` is load-bearing — see visibleWidthIn()/visibleHeightIn().
    Rectangle {
        id: headerBar
        objectName: "headerBar"
        width: root.headerWidth
        // Exactly Main.qml's arithmetic: where the flow starts, plus its own
        // height, plus the toggle's caption overhang, floored at the chrome
        // height. `captionReserve` rather than `reservedHeight` because the
        // flow's height already contains the segment strip — see
        // SourceToggle.qml.
        height: Math.max(Theme.barHeight,
                         headerFlow.y + headerFlow.height + Theme.gap
                         + headerToggle.captionReserve)
        clip: true
        color: Theme.surface

        Flow {
            id: headerFlow
            objectName: "headerFlow"
            x: Theme.gap
            y: (Theme.barHeight - Theme.rowHeightSm) / 2
            width: parent.width - Theme.gap * 2
            spacing: Theme.gap

            Text {
                objectName: "headerTitle"
                text: "Radicle"
                color: Theme.text
                font.pixelSize: Theme.fontXl
                font.bold: true
                height: Theme.rowHeightSm
                verticalAlignment: Text.AlignVCenter
            }

            Ui.SourceToggle {
                id: headerToggle
                objectName: "headerToggle"
                height: Theme.rowHeightSm
                mode: root.headerMode
                startableModes: ["explore", "local"]
                localAvailable: true
            }

            Ui.FilterField {
                id: headerSearch
                objectName: "headerSearch"
                visible: root.headerMode === "explore"
                width: 260
                placeholder: "Search repositories"
            }

            Ui.NodeIdentity {
                id: headerIdentity
                objectName: "headerIdentity"
                visible: root.headerMode === "local" && headerIdentity.nodeId !== ""
                nodeId: root.headerMode === "local" ? root.fullDid : ""
            }

            Rectangle {
                id: headerChip
                objectName: "headerChip"
                width: chipLabel.implicitWidth + Theme.gap * 2
                height: Theme.rowHeightSm
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

    /// Stands in for the body below the header — the thing that must move down
    /// rather than be overlapped when the header grows a line.
    ///
    /// Positioned exactly as Main.qml's ColumnLayout positions the status
    /// strip: immediately under the bar, at whatever height the bar settles on.
    /// If the bar's height stops accounting for a wrapped line, the second line
    /// is drawn over the body — and no horizontal assertion here would notice.
    Rectangle {
        id: bodyBelow
        objectName: "bodyBelow"
        y: headerBar.height
        width: headerBar.width
        height: 60
        color: Theme.bg
    }

    property int headerWidth: 1400
    property string headerMode: "local"
    property int settingsClicks: 0

    /// The widths a user's window plausibly takes, widest first. 1200 is a
    /// comfortable window; 900 a half-screen split on 1080p; 630 the width the
    /// user screenshotted; 400 a narrow docked panel. All of 750 and below used
    /// to put the Settings chip entirely off screen.
    readonly property var probeWidths: [1200, 1000, 900, 700, 630, 500, 400]

    TestCase {
        name: "SettingsStaysReachableWhenNarrow"
        when: windowShown

        /// Let the layout actually run before measuring it.
        ///
        /// A `Flow` re-lays out on a render pass, not on the assignment that
        /// changed its width, so reading geometry straight after setting
        /// `headerWidth` reports the PREVIOUS width's arrangement. Without this
        /// the whole fixture measures a stale layout and reports failures at
        /// widths that are fine — and, worse, could report passes the same way.
        ///
        /// This is not the "settle hides a real lag" case other files here warn
        /// about. There the lag was a component reporting a size that did not
        /// contain its own content, which a user would see mid-frame; here the
        /// fixture drives a window resize from script, and a real resize gets
        /// its render pass for free. What is waited for is the test harness
        /// catching up with the layout, not the layout catching up with itself.
        function settle() {
            waitForRendering(headerBar);
        }

        function init() {
            root.headerWidth = 1400;
            root.headerMode = "local";
            root.settingsClicks = 0;
            settle();
        }

        function cleanup() {
            root.headerWidth = 1400;
            root.headerMode = "local";
            settle();
        }

        /// THE BLOCKER, and the whole point of this file: Settings must never
        /// leave the screen, in either axis.
        ///
        /// The vertical half is the new one, and it is what makes wrapping a
        /// real fix rather than a relocation of the same bug. A chip that has
        /// wrapped onto a line the bar did not grow to hold is exactly as
        /// unreachable as one past the right edge, while every horizontal
        /// assertion stays green.
        ///
        /// Asserted across the whole range rather than at one narrow width,
        /// because the failure is progressive — the chip was partly clipped at
        /// 800 and entirely gone at 750, and a single-width test would pick one
        /// of those and miss the other. It fails loudly with the width that
        /// broke it, so the report names the size rather than just the fact.
        function test_the_settings_chip_never_leaves_the_screen() {
            var chip = root.findByName(headerBar, "headerChip");
            verify(chip !== null, "the Settings chip must exist");

            for (var i = 0; i < root.probeWidths.length; i++) {
                var w = root.probeWidths[i];
                root.headerWidth = w;
                settle();

                compare(root.visibleWidthIn(chip, headerBar), chip.width,
                        "at width " + w + " the Settings chip shows "
                        + root.visibleWidthIn(chip, headerBar) + "px of its "
                        + chip.width + "px horizontally — it is clipped or off "
                        + "the right edge. The identity copies rather than "
                        + "opening Settings, so this chip is the ONLY way in: "
                        + "Settings, the mode picker, the git path and the "
                        + "resolved home all become unreachable, with nothing "
                        + "on screen saying so.");

                compare(root.visibleHeightIn(chip, headerBar), chip.height,
                        "at width " + w + " the Settings chip shows "
                        + root.visibleHeightIn(chip, headerBar) + "px of its "
                        + chip.height + "px vertically — it wrapped onto a line "
                        + "the bar did not grow to hold, which is the same "
                        + "unreachability in the other axis");
            }
        }

        /// ...and it is still HITTABLE, not merely within the bounds, at EVERY
        /// probe width.
        ///
        /// Geometry and clickability are different claims and this repo has
        /// been bitten by each without the other: a control inside the viewport
        /// whose MouseArea got zero size is just as dead as one off-screen, and
        /// a 22px offset between a control's hit area and its painted segments
        /// once made the mode toggle silently do nothing while looking correct.
        ///
        /// So this issues a REAL click and asserts the effect, rather than
        /// checking `visible` — and it does so at every width rather than only
        /// the narrowest, because wrapping MOVES the chip and a hit area that
        /// stopped coinciding with the paint would do so at whichever width the
        /// wrap happens.
        function test_settings_is_clickable_at_every_width() {
            var area = root.findByName(headerBar, "headerSettingsToggle");
            var chip = root.findByName(headerBar, "headerChip");
            verify(area !== null, "the clickable element must carry the objectName");

            for (var i = 0; i < root.probeWidths.length; i++) {
                var w = root.probeWidths[i];
                root.headerWidth = w;
                settle();

                verify(area.width > 0 && area.height > 0,
                       "at width " + w + " the Settings hit area is "
                       + area.width + "x" + area.height
                       + " — a control with no area cannot be clicked");

                // The hit area must coincide with what is PAINTED — the
                // click-offset defect, stated directly.
                var chipAt = chip.mapToItem(headerBar, 0, 0);
                var areaAt = area.mapToItem(headerBar, 0, 0);
                fuzzyCompare(areaAt.x, chipAt.x, 1,
                             "at width " + w + " the Settings hit area starts at "
                             + "x=" + areaAt.x + " but the chip is painted at x="
                             + chipAt.x + " — clicks land beside what the user "
                             + "aims at");
                fuzzyCompare(areaAt.y, chipAt.y, 1,
                             "at width " + w + " the Settings hit area starts at "
                             + "y=" + areaAt.y + " but the chip is painted at y="
                             + chipAt.y + " — clicks land above or below what "
                             + "the user aims at");

                root.settingsClicks = 0;
                mouseClick(area);
                compare(root.settingsClicks, 1,
                        "clicking Settings at " + w + "px must reach it — this "
                        + "is the user-visible requirement, and neither the "
                        + "original header nor the incompressible-chip fix met "
                        + "it here");
            }
        }

        /// The same guarantee in Explore, where the 260px search field takes the
        /// room the identity takes in Local.
        ///
        /// Both modes are asserted because they run out of room at different
        /// widths and for different reasons — a fix that only budgeted for the
        /// identity would leave Explore broken, which is exactly how the search
        /// field came to shrink 260→120 in the first place.
        function test_settings_is_reachable_in_explore_mode_too() {
            root.headerMode = "explore";
            settle();
            var chip = root.findByName(headerBar, "headerChip");
            var area = root.findByName(headerBar, "headerSettingsToggle");

            for (var i = 0; i < root.probeWidths.length; i++) {
                var w = root.probeWidths[i];
                root.headerWidth = w;
                settle();

                compare(root.visibleWidthIn(chip, headerBar), chip.width,
                        "at width " + w + " in Explore the Settings chip is off "
                        + "screen — the search field is taking the room the "
                        + "identity takes in Local, and the chip loses either "
                        + "way");
                compare(root.visibleHeightIn(chip, headerBar), chip.height,
                        "at width " + w + " in Explore the Settings chip wrapped "
                        + "below the bar's bottom edge");

                root.settingsClicks = 0;
                mouseClick(area);
                compare(root.settingsClicks, 1,
                        "clicking Settings at " + w + "px in Explore must reach it");
            }
        }

        /// HOW it stays reachable: the header wraps rather than squeezing.
        ///
        /// Not a separate feature from the test above — it is the mechanism the
        /// user asked for, and asserting it stops a future change from
        /// satisfying "Settings is clickable" by going back to eliding the
        /// identity and shrinking the search field. Two items on visibly
        /// different `y` is the only direct evidence the row took a second line.
        function test_the_header_wraps_onto_a_second_line_when_narrow() {
            root.headerWidth = 400;
            settle();

            var toggle = root.findByName(headerBar, "headerToggle");
            var chip = root.findByName(headerBar, "headerChip");
            var toggleY = root.centreYIn(toggle, headerBar);
            var chipY = root.centreYIn(chip, headerBar);

            verify(chipY > toggleY + Theme.rowHeightSm / 2,
                   "at 400px the toggle's centre is at y=" + toggleY
                   + " and the Settings chip's at y=" + chipY
                   + " — they are on the SAME line, so the header did not wrap. "
                   + "Everything is being squeezed onto one line instead, which "
                   + "is the behaviour the user rejected.");
        }

        /// ...and wrapping is a LAST resort, not the normal state.
        ///
        /// The counter-pressure to the test above, and what makes the pair a
        /// specification rather than two observations: a Flow given a tiny width
        /// would satisfy "it wraps" by putting every item on its own line at
        /// every width. At a comfortable width the header is one line, exactly
        /// as it is today.
        function test_a_comfortable_width_stays_on_one_line() {
            root.headerWidth = 1200;
            settle();

            var names = ["headerTitle", "headerToggle", "headerIdentity",
                         "headerChip"];
            var first = root.centreYIn(root.findByName(headerBar, names[0]),
                                       headerBar);
            for (var i = 1; i < names.length; i++) {
                fuzzyCompare(root.centreYIn(root.findByName(headerBar, names[i]),
                                            headerBar),
                             first, 2,
                             "at 1200px " + names[i] + " is on a different line "
                             + "from the title — wrapping must be a last resort, "
                             + "and there is room for everything here");
            }
        }

        /// The body below the header must MOVE DOWN when the header grows, not
        /// be overlapped by it.
        ///
        /// The reason the previous fix squeezed instead of wrapping was that the
        /// bar's height was fixed chrome. Now that it can grow, the hazard
        /// moves: a bar that wraps its content but keeps its old height draws
        /// the second line over whatever is underneath — and a Settings chip
        /// painted on top of the status strip satisfies every "on screen"
        /// assertion above while being visually broken.
        function test_the_body_below_is_not_overlapped_when_the_header_grows() {
            for (var i = 0; i < root.probeWidths.length; i++) {
                var w = root.probeWidths[i];
                root.headerWidth = w;
                settle();

                var chip = root.findByName(headerBar, "headerChip");
                var chipBottom = chip.mapToItem(root, 0, chip.height).y;
                verify(chipBottom <= bodyBelow.y + 1,
                       "at width " + w + " the Settings chip's bottom is at y="
                       + chipBottom + " but the body below the header starts at "
                       + "y=" + bodyBelow.y + " — the header grew its content "
                       + "without growing itself, so the second line is drawn "
                       + "over the body");

                verify(headerFlow.y + headerFlow.height <= headerBar.height + 1,
                       "at width " + w + " the header's content ends at y="
                       + (headerFlow.y + headerFlow.height) + " inside a "
                       + headerBar.height + "px bar — it is being clipped");
            }
        }

        /// The identity is no longer truncated to buy the chip its room.
        ///
        /// Kept in this narrowed file because it is the direct evidence that
        /// Settings stays reachable BY WRAPPING rather than by the squeeze the
        /// user rejected — the previous fix bought the chip's space out of this
        /// element's legibility, and passed every reachability assertion while
        /// doing it.
        ///
        /// `shortened` is NodeIdentity's own report of whether its label is
        /// rendering less than the whole id; asserting on `label.text` alone
        /// cannot see it, because an eliding `Text` keeps its full `text` and
        /// merely draws less. 630 is in the range on purpose: that is the width
        /// the user screenshotted with the DID cut in half.
        function test_the_identity_is_not_truncated_to_make_room() {
            var ident = root.findByName(headerBar, "headerIdentity");
            var label = root.findByName(headerBar, "nodeIdentityLabel");
            verify(ident !== null && label !== null);

            for (var i = 0; i < root.probeWidths.length; i++) {
                var w = root.probeWidths[i];
                root.headerWidth = w;
                settle();

                compare(label.text, root.fullDid,
                        "at width " + w + " the identity's text is not the whole DID");
                verify(!ident.shortened,
                       "at width " + w + " the identity is visually truncated — "
                       + "it should have wrapped onto its own line and been "
                       + "shown WHOLE. That is the trade the user asked for, in "
                       + "place of the elide this replaces.");
            }
        }

        /// Clicking the identity still copies the WHOLE did.
        ///
        /// Nothing elides today, so this is cheap insurance rather than a live
        /// concern — and it is what would make any future reintroduction of
        /// shortening safe rather than silent data loss.
        function test_the_identity_copies_in_full_at_the_narrowest_width() {
            root.headerWidth = 400;
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
                    "clicking the identity must copy the WHOLE did at any width");
        }

        /// The title no longer disappears to make room either.
        ///
        /// The previous fix gave it `visible: headerRow.width > 520`, so it
        /// vanished at exactly the widths a user is most likely to be in. With
        /// wrapping there is nothing to buy by dropping it: a word that does not
        /// fit on line one goes to line two like everything else.
        function test_the_title_never_disappears() {
            var title = root.findByName(headerBar, "headerTitle");
            for (var i = 0; i < root.probeWidths.length; i++) {
                var w = root.probeWidths[i];
                root.headerWidth = w;
                settle();
                verify(title.visible,
                       "at width " + w + " the title vanished — with a wrapping "
                       + "header nothing needs to be dropped to make room");
                verify(root.visibleWidthIn(title, headerBar) > 0,
                       "at width " + w + " the title has nothing on screen");
            }
        }
    }

    /// Reads the real system clipboard, the same way NodeIdentity writes it.
    /// A separate editor from the component's own, so a test cannot pass
    /// against a copy that never happened — see tst_source.qml.
    TextEdit { id: clipProbe; visible: false }
}
