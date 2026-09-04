import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Switching between the seed and local-node sources.
 *
 * The toggle is what makes M2.1's backend reachable at all, so these drive it
 * with real mouse clicks rather than by setting `current` — setting the
 * property would pass even if the segments had no click handler, which is the
 * exact shape that shipped two click-dead rows in this codebase before (see
 * tst_clicks.qml).
 */
Item {
    width: 600
    height: 200

    property var chosen: []

    /// Find the first descendant carrying `name` as its objectName.
    function findByName(root, name) {
        if (!root) return null;
        if (root.objectName === name) return root;
        for (var i = 0; i < root.children.length; i++) {
            var hit = findByName(root.children[i], name);
            if (hit) return hit;
        }
        return null;
    }

    Ui.SourceToggle {
        id: toggle
        objectName: "toggle"
        anchors.top: parent.top
        anchors.left: parent.left
        localAvailable: true
        current: "remote"
        onSourceChosen: function (s) { chosen.push(s); }
    }

    TestCase {
        name: "SourceToggle"
        when: windowShown

        function init() {
            chosen = [];
            toggle.localAvailable = true;
            toggle.current = "remote";
        }

        function test_both_segments_are_present_when_a_local_profile_exists() {
            verify(findByName(toggle, "sourceToggle_remote") !== null,
                   "the seed segment should exist");
            verify(findByName(toggle, "sourceToggle_local") !== null,
                   "the local segment should exist when a profile was found");
        }

        /// A real click, not an emitted signal: this is what proves the
        /// segment is actually wired.
        function test_clicking_local_asks_for_the_local_source() {
            var seg = findByName(toggle, "sourceToggle_local");
            verify(seg !== null, "local segment must exist to click");
            mouseClick(seg);
            compare(chosen.length, 1, "one choice should have been reported");
            compare(chosen[0], "local");
        }

        function test_clicking_seed_asks_for_the_remote_source() {
            toggle.current = "local";
            var seg = findByName(toggle, "sourceToggle_remote");
            mouseClick(seg);
            compare(chosen[chosen.length - 1], "remote");
        }

        /// With no profile the local segment is absent rather than disabled.
        /// A disabled control that can only ever produce an error reads as a
        /// broken feature, so there must be nothing there to click.
        function test_no_local_segment_without_a_profile() {
            toggle.localAvailable = false;
            verify(findByName(toggle, "sourceToggle_local") === null,
                   "the local segment must not exist without a profile");
            verify(findByName(toggle, "sourceToggle_remote") !== null,
                   "the seed segment stays, naming what is on screen");
        }
    }

    // -----------------------------------------------------------------------
    // Routing and switching, against the REAL component.
    //
    // An earlier version of this block drove hand-written QtObject stubs that
    // reproduced Main.qml's logic — which meant deleting `setSource` from
    // Main.qml, or reverting `call()` to a hardcoded "remote", left every test
    // green while the local backend became unreachable. A copy asserted
    // against itself is not a test.
    //
    // The logic now lives in SourceState.qml (extracted the way M1.1 extracted
    // NavState, for the same reason), so these drive the real object. Break
    // `methodFor` or `select` and these go red.
    // -----------------------------------------------------------------------

    Ui.SourceState {
        id: sourceState
        localAvailable: true
        onChanged: reloads++
    }

    property int reloads: 0

    TestCase {
        name: "SourceRouting"

        function init() {
            sourceState.current = "remote";
            sourceState.localAvailable = true;
            reloads = 0;
        }

        function test_calls_go_to_the_remote_surface_by_default() {
            compare(sourceState.methodFor("ListRepos"), "remoteListRepos");
        }

        function test_calls_follow_the_selected_source() {
            sourceState.select("local");
            compare(sourceState.methodFor("ListRepos"), "localListRepos");
            compare(sourceState.methodFor("GetCommit"), "localGetCommit",
                    "every method follows the source, not just listing");
        }

        /// The per-call override, the seam for a screen showing both sources.
        function test_an_explicit_source_overrides_the_selected_one() {
            sourceState.select("local");
            compare(sourceState.methodFor("GetRepo", "remote"), "remoteGetRepo");
        }
    }

    TestCase {
        name: "SourceSwitching"

        function init() {
            sourceState.current = "remote";
            sourceState.localAvailable = true;
            reloads = 0;
        }

        /// Regression test. `setSource()` once called only `nav.reset()`,
        /// which was right when NavState did its own reload — M1.1 made it a
        /// pure state holder and every caller responsible for reloading. The
        /// stale assumption meant flipping to "Local" in a live Basecamp
        /// switched the toggle, cleared the screen, and issued no request at
        /// all: an empty list that read as "your node has no repositories".
        ///
        /// Main.qml responds to `changed` by resetting nav AND reloading, so
        /// the signal firing exactly once per real switch is what makes that
        /// possible. Suppress the signal and this goes red.
        function test_a_real_switch_signals_once_so_the_caller_can_refetch() {
            verify(sourceState.select("local"), "the switch should be accepted");
            compare(sourceState.current, "local");
            compare(reloads, 1, "a real switch must notify exactly once");
        }

        function test_switching_to_the_same_source_changes_nothing() {
            verify(!sourceState.select("remote"), "a no-op returns false");
            compare(reloads, 0, "no notification when nothing changed");
        }

        /// Guarded here as well as by hiding the segment: a spec, or a future
        /// caller, can reach select() directly.
        function test_local_is_refused_when_no_profile_exists() {
            sourceState.localAvailable = false;
            verify(!sourceState.select("local"), "local must be refused");
            compare(sourceState.current, "remote");
            compare(reloads, 0);
            // And the routing must not have moved either.
            compare(sourceState.methodFor("ListRepos"), "remoteListRepos");
        }
    }
}
