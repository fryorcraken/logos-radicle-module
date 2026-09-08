import QtQuick
import QtQuick.Layouts
import QtTest
import "../src/qml" as Ui
import "../src/qml/Theme.js" as Theme

/*
 * Switching mode, end to end, against a backend that replies LATER.
 *
 * ## Why this file exists when tst_source.qml already covers the toggle
 *
 * tst_source.qml drives `SourceState.select()` directly and then assigns
 * `sourceState.mode` by hand to stand in for the capabilities reply. That
 * pins the routing, and it is why the routing is correct. What it cannot see
 * is the wiring BETWEEN the click and that assignment — `Main.setMode()`,
 * which is the function the user's click actually enters, and which decides
 * whether a write is issued at all.
 *
 * The whole control shipped with its primary action broken while 317 tests
 * passed, because no test ever went click -> setMode -> write -> reply ->
 * segment. Every layer was covered; the joins were not. So this file hosts
 * the REAL SourceToggle inside a REAL header row, clicks it with a real
 * mouse event, and runs the reply through a fake that answers on a later
 * turn — the `deferredApp` shape tst_repo_switch.qml and tst_sync_epoch.qml
 * already use, and for the same reason: a synchronous fake structurally
 * cannot produce the window where the write is in flight and `mode` has not
 * settled, which is precisely the window this control lives in.
 *
 * ## The invariant, stated once
 *
 * A click on a segment must end with that mode in force, EVERY time,
 * including the second and third time, and including a click that arrives
 * while a previous write is still in flight. "Every time" is the part that
 * broke: the first switch worked and the ones after it did not.
 */
Item {
    id: harness

    width: 1000
    height: 400

    // ------------------------------------------------------------------
    // A backend that replies on a later turn.
    //
    // `setSetting` does not answer immediately: the reply is queued and
    // delivered by `deliver()`. That is what makes this a round trip rather
    // than a function call, and it is the only way to reproduce a second
    // click landing before the first reply.
    // ------------------------------------------------------------------
    QtObject {
        id: backend

        /// What the module has actually persisted. The single source of
        /// truth the fake answers from, so a write that never arrives is
        /// visible as a mode that never changes — rather than being masked
        /// by a fake that echoes whatever it was asked for.
        property string storedMode: "local"

        /// Writes that have been issued but not yet answered.
        property var queue: []

        /// Every write this backend was asked to make, in order. Asserted on
        /// directly: "the segment did not move" and "no write was issued"
        /// are different faults with different fixes, and a test that only
        /// watched the segment could not tell them apart.
        property var writeLog: []

        function setSetting(key, value, cb) {
            writeLog.push(key + "=" + value);
            queue.push({ key: key, value: value, cb: cb });
        }

        /// Answer the oldest outstanding write, applying it the way the real
        /// module does: persist, then republish capabilities.
        function deliver() {
            if (queue.length === 0) return false;
            var w = queue.shift();
            if (w.key === "mode") storedMode = w.value;
            // The real backend refreshes capabilities inside setSetting, so
            // the reply and the new capabilities land together.
            harness.publishCapabilities();
            w.cb({ mode: storedMode });
            return true;
        }

        function pending() { return queue.length; }
    }

    /// Whether the settings overlay is up, as Main.qml holds it.
    property bool settingsOpen: false

    /// A REAL-LENGTH did — `did:key:` plus a 48-character z-base-58 key, which
    /// is what `rad self` prints and what the backend actually returns.
    ///
    /// The length is the point, not the value. The header now shows the whole
    /// identity rather than a 14-character head, so it is roughly four times
    /// wider than it was; a fixture carrying a SHORT id would let every layout
    /// assertion below pass while the real thing wrapped the header onto a
    /// second line. This file's fake was 51 characters, and 5 short is enough
    /// to matter at a fixed monospace measure.
    readonly property string fullDid:
        "did:key:z6MkowunyxpkcgCx2DdndJwebjcpk5pEnhaDE8JH3MbLnDBe"

    /// Push the backend's current state into `caps`, the way
    /// `onCapsJsonChanged` does in Main.qml — a whole new object, because a
    /// mutated `var` does not re-evaluate the bindings that read it.
    function publishCapabilities() {
        caps = {
            mode: backend.storedMode,
            localAvailable: backend.storedMode === "local",
            startableModes: ["explore", "local"],
            nodeId: backend.storedMode === "local"
                    ? harness.fullDid : ""
        };
    }

    // ------------------------------------------------------------------
    // Main.qml's own state, reproduced in the shape that file has it.
    // ------------------------------------------------------------------
    property var caps: ({ mode: "local", localAvailable: true,
                          startableModes: ["explore", "local"],
                          nodeId: harness.fullDid })

    readonly property Ui.SourceState sourceState: Ui.SourceState {
        mode: harness.caps.mode || "local"
        localAvailable: harness.caps.localAvailable === true
        onChanged: {
            harness.reloads++;
            sourceReload.restart();
        }
    }

    readonly property string source: sourceState.current
    readonly property string mode: sourceState.mode

    onSourceChanged: sourceReload.restart()

    property int reloads: 0
    property int fetches: 0
    property string fetchedWith: ""

    readonly property Timer sourceReload: Timer {
        interval: 0
        repeat: false
        onTriggered: {
            harness.fetches++;
            harness.fetchedWith = harness.source + "ListRepos";
        }
    }

    property string lastError: ""

    /// Main.qml's setMode(), reproduced. This is the function under test.
    function setMode(next) {
        if (!sourceState.select(next)) return;
        backend.setSetting("mode", next, function (reply) {
            if (reply && reply.error) harness.lastError = reply.error;
        });
    }

    // ------------------------------------------------------------------
    // The header, hosted the way Main.qml hosts it.
    // ------------------------------------------------------------------
    Rectangle {
        id: bar
        width: harness.width
        // Main.qml's own arithmetic, verbatim — including the property it
        // budgets from. Reading `implicitHeight` here instead would make this
        // fixture disagree with the app about the one number under test.
        height: Math.max(Theme.barHeight, toggle.reservedHeight + Theme.gap)

        RowLayout {
            id: headerRow
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: (Theme.barHeight - height) / 2
            anchors.leftMargin: Theme.gap
            anchors.rightMargin: Theme.gap
            height: Theme.rowHeightSm
            spacing: Theme.gap

            Text {
                id: title
                objectName: "headerTitle"
                text: "Radicle"
                font.pixelSize: Theme.fontXl
                font.bold: true
            }

            Ui.SourceToggle {
                id: toggle
                objectName: "sourceToggle"
                Layout.alignment: Qt.AlignTop
                Layout.preferredHeight: Theme.rowHeightSm
                Layout.maximumHeight: Theme.rowHeightSm
                mode: harness.mode
                startableModes: harness.caps.startableModes !== undefined
                                ? harness.caps.startableModes : []
                localAvailable: harness.caps.localAvailable === true
                onModeChosen: function (next) { harness.setMode(next); }
            }

            Ui.NodeIdentity {
                id: identity
                objectName: "nodeIdentity"
                visible: harness.mode === "local" && identity.nodeId !== ""
                nodeId: harness.caps.nodeId || ""
            }

            Item { Layout.fillWidth: true }

            // Main.qml's Settings chip, including its MouseArea.
            //
            // The MouseArea is not decoration in this fixture. The identity
            // beside the toggle used to open Settings too, and it now copies
            // instead — so this chip is the ONLY way in, and "still reachable"
            // has to be an assertion rather than a claim. A bare Rectangle here
            // would have made that untestable.
            Rectangle {
                id: settingsChip
                objectName: "settingsChip"
                Layout.preferredWidth: 70
                Layout.preferredHeight: Theme.rowHeightSm

                MouseArea {
                    objectName: "settingsToggle"
                    anchors.fill: parent
                    onClicked: harness.settingsOpen = !harness.settingsOpen
                }
            }
        }
    }

    function findByName(node, name) {
        if (!node) return null;
        if (node.objectName === name) return node;
        for (var i = 0; i < node.children.length; i++) {
            var hit = findByName(node.children[i], name);
            if (hit) return hit;
        }
        return null;
    }

    /// Click a segment the way a user does — a real mouse event on the
    /// MouseArea, not a call to modeChosen(). A control whose handler was
    /// disconnected would still pass a signal-emitting test.
    function clickSegment(key) {
        var seg = findByName(toggle, "sourceToggle_" + key);
        verify(seg !== null, "no segment for " + key);
        mouseClick(seg);
    }

    // ==================================================================
    TestCase {
        name: "ModeSwitching"
        when: windowShown

        function init() {
            backend.storedMode = "local";
            backend.queue = [];
            backend.writeLog = [];
            harness.publishCapabilities();
            harness.reloads = 0;
            harness.fetches = 0;
            harness.fetchedWith = "";
            harness.lastError = "";
        }

        function clickSegment(key) {
            var seg = harness.findByName(toggle, "sourceToggle_" + key);
            verify(seg !== null, "no segment for " + key);
            mouseClick(seg);
        }

        /// The baseline: one click, one write, one settled mode.
        function test_clicking_a_segment_persists_that_mode() {
            compare(harness.mode, "local", "precondition");

            clickSegment("explore");
            compare(backend.writeLog.length, 1,
                    "the click must issue a write, got: "
                    + JSON.stringify(backend.writeLog));
            compare(backend.writeLog[0], "mode=explore");

            backend.deliver();
            compare(harness.mode, "explore",
                    "the segment must follow the mode actually in force");
        }

        /// **The reported bug.** "clicking back and forth between explore and
        /// local fails" — the first switch worked and the next did not.
        ///
        /// Four switches, alternating, each one delivered before the next
        /// click. A control that only worked once passes the test above and
        /// fails here on step 1.
        function test_switching_back_and_forth_works_every_time() {
            var want = ["explore", "local", "explore", "local"];
            for (var i = 0; i < want.length; i++) {
                clickSegment(want[i]);
                verify(backend.pending() > 0,
                       "step " + i + ": clicking " + want[i]
                       + " issued no write at all — the mode is stuck at "
                       + harness.mode + " and the control is inert. Writes so "
                       + "far: " + JSON.stringify(backend.writeLog));
                backend.deliver();
                compare(harness.mode, want[i],
                        "step " + i + ": clicked " + want[i]
                        + " but the mode in force is " + harness.mode);
            }
            compare(backend.writeLog.length, 4,
                    "every click must have written: "
                    + JSON.stringify(backend.writeLog));
        }

        /// All three modes, in a cycle, twice round. Explore and Local both
        /// derive a method prefix; Embedded shares Local's. A switch that
        /// only fired when the PREFIX changed would pass the two-mode test
        /// above and drop every local<->embedded move.
        function test_every_mode_can_be_reached_repeatedly() {
            var want = ["explore", "local", "embedded",
                        "explore", "local", "embedded"];
            for (var i = 0; i < want.length; i++) {
                clickSegment(want[i]);
                backend.deliver();
                compare(harness.mode, want[i],
                        "step " + i + ": clicked " + want[i]
                        + " but the mode in force is " + harness.mode);
            }
        }

        /// A click that lands while the previous write is still in flight.
        ///
        /// This is the case a synchronous fake cannot produce, and the one a
        /// real user produces constantly by clicking twice. The second click
        /// must not be swallowed: whatever the user clicked LAST is the mode
        /// that must end up in force.
        function test_a_click_during_an_in_flight_write_is_not_lost() {
            clickSegment("explore");
            compare(backend.pending(), 1, "the first write is in flight");

            clickSegment("embedded");
            verify(backend.writeLog.length === 2,
                   "the second click was swallowed while the first write was "
                   + "in flight — writes: " + JSON.stringify(backend.writeLog));

            // Both replies land, in order.
            backend.deliver();
            backend.deliver();
            compare(harness.mode, "embedded",
                    "the LAST mode the user clicked must be the one in force");
        }

        /// The mode the user is already in is a no-op, and must stay one —
        /// otherwise every click writes, and the "did anything change"
        /// question the reload depends on has no answer.
        function test_clicking_the_current_mode_writes_nothing() {
            compare(harness.mode, "local");
            clickSegment("local");
            compare(backend.writeLog.length, 0,
                    "re-selecting the mode in force must not write: "
                    + JSON.stringify(backend.writeLog));
        }

        /// ...and that no-op must not wedge the control. After clicking the
        /// mode you are already in, the next real switch must still work.
        function test_a_no_op_click_does_not_wedge_the_control() {
            clickSegment("local");
            clickSegment("explore");
            verify(backend.pending() > 0,
                   "a real switch after a no-op click issued no write");
            backend.deliver();
            compare(harness.mode, "explore");
        }

        /// The reload must follow the mode to the NEW surface, on every
        /// switch rather than only the first. Input-dependent: the value
        /// recorded names the surface, so a reload that fired against the old
        /// one is visible rather than merely absent.
        function test_each_switch_reloads_from_the_new_surface() {
            clickSegment("explore");
            backend.deliver();
            tryCompare(harness, "fetchedWith", "remoteListRepos", 1000,
                       "switching to Explore must refetch from the seed");

            clickSegment("local");
            backend.deliver();
            tryCompare(harness, "fetchedWith", "localListRepos", 1000,
                       "and switching back must refetch from the node");
        }
    }

    // ==================================================================
    // The header is ONE line.
    //
    // The user's report: "node id is not on the same line anymore". The
    // identity used to sit immediately right of the toggle and now renders
    // below it, because the toggle reserves caption space it is not using
    // and the row centres the taller box.
    //
    // Asserted on vertical position rather than on `visible`: a test that
    // only checked the identity was shown passes just as happily while it is
    // wrapped onto a second line, which is exactly what shipped.
    // ==================================================================
    TestCase {
        name: "HeaderIsOneLine"
        when: windowShown

        function init() {
            backend.storedMode = "local";
            backend.queue = [];
            backend.writeLog = [];
            harness.publishCapabilities();
            settle();
        }

        /// Let the row finish its polish before measuring.
        ///
        /// Unlike the toggle's own height — which is arithmetic, and where a
        /// wait would be hiding a real one-frame lag — the position of an item
        /// INSIDE a RowLayout is decided by the layout engine on its next
        /// polish pass by design. Measuring before that reads the previous
        /// pass's coordinates, and this file did exactly that: the same
        /// assertion returned y=20 in one run and y=26 in another. That is the
        /// test being wrong about when to look, not the layout being unstable.
        function settle() {
            waitForRendering(bar);
        }

        /// The centre of the visible control and the centre of the identity
        /// must coincide. Centres rather than tops, because the two items
        /// are different heights and a shared top edge is not what "on the
        /// same line" means to a reader.
        function test_the_identity_sits_on_the_toggles_line() {
            verify(identity.visible, "precondition: Local shows the identity");

            var seg = harness.findByName(toggle, "sourceToggle_local");
            var segCentre = seg.mapToItem(bar, 0, seg.height / 2).y;
            var idCentre = identity.mapToItem(bar, 0, identity.height / 2).y;

            verify(Math.abs(segCentre - idCentre) <= 2,
                   "the toggle's segments are centred at y=" + segCentre
                   + " but the node id at y=" + idCentre + " — a "
                   + Math.abs(segCentre - idCentre) + "px drop, so the "
                   + "identity is rendering on a second line below the "
                   + "toggle instead of beside it");
        }

        /// The same for the title, which is the other thing on that line.
        /// Included because "Radicle", the toggle and the identity are one
        /// visual row and any one of the three drifting is the same defect.
        function test_the_title_and_the_toggle_share_a_line() {
            var seg = harness.findByName(toggle, "sourceToggle_local");
            var segCentre = seg.mapToItem(bar, 0, seg.height / 2).y;
            var titleCentre = title.mapToItem(bar, 0, title.height / 2).y;

            verify(Math.abs(segCentre - titleCentre) <= 2,
                   "the toggle's segments are centred at y=" + segCentre
                   + " but the title at y=" + titleCentre + " — they are not "
                   + "on the same line");
        }

        /// In every mode, so a header that happens to line up in one state
        /// is not mistaken for one that lines up.
        function test_the_line_holds_in_every_mode() {
            var modes = ["explore", "local", "embedded"];
            for (var i = 0; i < modes.length; i++) {
                backend.storedMode = modes[i];
                harness.publishCapabilities();
                settle();

                var seg = harness.findByName(toggle, "sourceToggle_local");
                var segCentre = seg.mapToItem(bar, 0, seg.height / 2).y;
                var titleCentre = title.mapToItem(bar, 0, title.height / 2).y;
                verify(Math.abs(segCentre - titleCentre) <= 2,
                       "in " + modes[i] + " the toggle is centred at y="
                       + segCentre + " and the title at y=" + titleCentre);
            }
        }

        /// The mechanism, asserted directly: the CONTROL is the height of what
        /// it draws, in the modes that draw no caption.
        ///
        /// This is the assertion that says WHY the line broke, where the ones
        /// above say that it broke. The toggle reserved its caption's space in
        /// its own `implicitHeight`, so it reported 72px while rendering 28px
        /// of content at the top of that box — and a row centres what it is
        /// given, which dropped everything beside it onto another line.
        ///
        /// Note this cannot be satisfied by removing the reservation
        /// altogether: the bar test below still requires the budget to exist.
        /// The two together pin the split — budget on the container, size on
        /// the control — rather than either one alone.
        function test_the_control_is_the_height_of_what_it_draws() {
            var modes = ["explore", "local"];
            for (var i = 0; i < modes.length; i++) {
                backend.storedMode = modes[i];
                harness.publishCapabilities();
                settle();

                var note = harness.findByName(toggle, "sourceToggleNote");
                verify(!note.visible,
                       "precondition: " + modes[i] + " draws no caption");
                compare(toggle.implicitHeight, Theme.rowHeightSm,
                        "in " + modes[i] + " the toggle draws only its "
                        + Theme.rowHeightSm + "px segment strip but reports "
                        + toggle.implicitHeight + "px — the row will centre it "
                        + "against that empty space and everything beside it "
                        + "will leave its line");
            }
        }

        /// ...and the BAR is nonetheless the same height in every mode, so the
        /// body below it never slides on the click that switched modes.
        ///
        /// The pair is the point. Making the control shrink is only correct as
        /// long as the container still budgets for the caption; a fix that
        /// dropped the reservation entirely would pass the test above and
        /// reintroduce the 44px header jump this control already shipped once.
        function test_the_bar_does_not_change_height_between_modes() {
            var modes = ["explore", "local", "embedded"];
            var seen = [];
            for (var i = 0; i < modes.length; i++) {
                backend.storedMode = modes[i];
                harness.publishCapabilities();
                settle();
                seen.push(bar.height);
            }
            for (var j = 1; j < seen.length; j++) {
                compare(seen[j], seen[0],
                        "the bar is " + seen[j] + "px in " + modes[j]
                        + " but " + seen[0] + "px in " + modes[0]
                        + " — the header jumps when the mode changes");
            }
        }

        /// **Settings must still be reachable.** The identity beside the toggle
        /// was one of two ways in and now copies instead, so this chip is the
        /// only remaining entrance — and an entrance that stopped working would
        /// leave the mode picker, the resolved home and the git path
        /// unreachable, with nothing on screen saying so.
        ///
        /// A real click, and asserted in both directions: a chip that latched
        /// open would be just as broken as one that never opened.
        function test_the_settings_chip_still_opens_settings() {
            harness.settingsOpen = false;

            var chip = harness.findByName(settingsChip, "settingsToggle");
            verify(chip !== null,
                   "the header has no Settings control — with the identity no "
                   + "longer opening the panel, there is now no way in at all");
            mouseClick(chip);
            compare(harness.settingsOpen, true,
                    "clicking the Settings chip must open Settings");

            mouseClick(chip);
            compare(harness.settingsOpen, false,
                    "and clicking it again must close them");
        }

        /// Clicking the IDENTITY must not open Settings, in the assembled
        /// header rather than only in the isolated component. The two live side
        /// by side on one row, so "the click landed on the other element" is a
        /// real failure mode that a component test cannot see.
        function test_clicking_the_identity_in_the_header_does_not_open_settings() {
            backend.storedMode = "local";
            harness.publishCapabilities();
            settle();
            harness.settingsOpen = false;

            verify(identity.visible, "precondition: the identity is on screen");
            mouseClick(harness.findByName(identity, "nodeIdentity"));
            compare(harness.settingsOpen, false,
                    "clicking the identity opened Settings — it is a copy "
                    + "button now");
        }

        /// The identity in this header is the FULL did, not a head.
        ///
        /// Asserted here, in the real row, as well as in tst_source.qml's
        /// isolated component: the component test proves the label renders the
        /// whole string, and this proves the header actually hands it one and
        /// nothing between truncates or elides it.
        function test_the_header_shows_the_whole_identity() {
            backend.storedMode = "local";
            harness.publishCapabilities();
            settle();

            var lbl = harness.findByName(identity, "nodeIdentityLabel");
            verify(lbl !== null && lbl.visible, "the identity must be on screen");
            compare(lbl.text, harness.fullDid,
                    "the header must show the whole did, got: " + lbl.text);
            verify(lbl.text.indexOf("…") === -1,
                   "and must not elide it, got: " + lbl.text);
        }

        /// The full did must not push the identity off the toggle's line.
        ///
        /// This is `test_the_identity_sits_on_the_toggles_line` again with the
        /// thing that actually threatens it: a ~56-character monospace string
        /// where a 15-character one used to be. The header regressed onto two
        /// lines once already and the user reported it; a width change of this
        /// size is exactly the input that would do it again.
        function test_a_full_length_identity_stays_on_the_toggles_line() {
            backend.storedMode = "local";
            harness.publishCapabilities();
            settle();

            var lbl = harness.findByName(identity, "nodeIdentityLabel");
            compare(lbl.text, harness.fullDid, "precondition: the full did");

            var seg = harness.findByName(toggle, "sourceToggle_local");
            var segCentre = seg.mapToItem(bar, 0, seg.height / 2).y;
            var idCentre = identity.mapToItem(bar, 0, identity.height / 2).y;

            verify(Math.abs(segCentre - idCentre) <= 2,
                   "with a full-length did the toggle is centred at y="
                   + segCentre + " and the identity at y=" + idCentre
                   + " — a " + Math.abs(segCentre - idCentre) + "px drop, so "
                   + "the identity has wrapped onto a second line");
        }

        /// ...and does not grow the bar either. A wider identity must be
        /// absorbed by the row's flexible spacer, not by the header getting
        /// taller — the 44px jump this file already guards against, arriving
        /// from a new direction.
        function test_a_full_length_identity_does_not_grow_the_bar() {
            backend.storedMode = "explore";
            harness.publishCapabilities();
            settle();
            var withoutIdentity = bar.height;

            backend.storedMode = "local";
            harness.publishCapabilities();
            settle();
            verify(identity.visible, "precondition: Local shows the identity");

            compare(bar.height, withoutIdentity,
                    "the bar is " + bar.height + "px showing a full-length "
                    + "identity but " + withoutIdentity + "px without one — "
                    + "the header grows when the id appears");
        }

        /// The identity must fit within the row rather than running under the
        /// controls to its right. `implicitWidth` is what a RowLayout budgets
        /// from, so an element whose content is wider than it claims overlaps
        /// its neighbour silently — no wrap, no clip, just illegible text.
        function test_the_identity_claims_the_width_it_draws() {
            backend.storedMode = "local";
            harness.publishCapabilities();
            settle();

            var lbl = harness.findByName(identity, "nodeIdentityLabel");
            verify(identity.width >= lbl.implicitWidth,
                   "the identity is " + identity.width + "px wide but its "
                   + "label needs " + lbl.implicitWidth + "px — the did is "
                   + "being drawn over whatever sits beside it");

            var right = identity.mapToItem(bar, identity.width, 0).x;
            var chipLeft = settingsChip.mapToItem(bar, 0, 0).x;
            verify(right <= chipLeft + 1,
                   "the identity ends at x=" + right + " but the Settings chip "
                   + "starts at x=" + chipLeft + " — they overlap");
        }

        /// And the caption, in the one mode that has one, is still inside the
        /// bar. The row is pinned to the bar's top precisely so the reserved
        /// space sits underneath it; if the row were centred instead, the
        /// caption would hang past the bar's bottom edge and be clipped —
        /// which is the tooltip bug this caption exists to replace.
        function test_the_caption_stays_inside_the_bar() {
            backend.storedMode = "embedded";
            harness.publishCapabilities();
            settle();

            var note = harness.findByName(toggle, "sourceToggleNote");
            verify(note.visible, "Embedded has a caption to place");
            verify(note.height > 0, "a zero-height caption is invisible");

            var bottom = note.mapToItem(bar, 0, note.height).y;
            verify(bottom <= bar.height + 1,
                   "the caption's bottom is at " + bottom + " inside a "
                   + bar.height + "px bar — it is being clipped");
            verify(note.mapToItem(bar, 0, 0).y >= -1,
                   "the caption starts above the bar's top edge");
        }
    }
}
