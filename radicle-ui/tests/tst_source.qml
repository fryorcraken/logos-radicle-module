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
    // Routing: which backend method a call actually reaches.
    //
    // The toggle is only useful if flipping it changes where calls go. This
    // stands in for Main.qml's `call()`, whose real body cannot run here (it
    // needs a QtRO replica), reproducing the one line that does the routing:
    // `(source || root.source) + method`. A regression that hardcoded
    // "remote" again would leave the toggle visibly working and silently
    // inert, which is the failure worth pinning.
    // -----------------------------------------------------------------------

    QtObject {
        id: router
        property string source: "remote"
        property string lastMethod: ""

        function call(method, args, onOk, onFail, source) {
            lastMethod = (source || router.source) + method;
        }
    }

    // -----------------------------------------------------------------------
    // Switching source must REFETCH, not just reset navigation state.
    //
    // Regression test. `setSource()` originally called only `nav.reset()`,
    // which was right when NavState did its own reload — but M1.1 extracted
    // NavState into a pure state holder and made every caller responsible for
    // reloading (see `onBackendReady` and `setSeed`, which both call
    // `repoList.reload()` alongside it). The merge left setSource() on the old
    // assumption, so flipping to "Local" in a live Basecamp switched the
    // toggle, cleared the screen, and issued no local request at all: an
    // empty repository list that looked like "your node has no repos".
    //
    // This reproduces the shape rather than the whole component: a state
    // holder that resets without reloading, plus the caller's obligation to
    // reload. Written to fail against the one-line version — remove the
    // `reload()` from `switcher.setSource` and `reloads` stays 0.
    // -----------------------------------------------------------------------

    QtObject {
        id: navStub
        property string view: "repo"
        function reset() { view = "repos"; }   // no reload — as NavState is
    }

    QtObject {
        id: switcher
        property string source: "remote"
        property int reloads: 0
        property bool localAvailable: true

        function reload() { reloads++; }

        function setSource(next) {
            if (next === switcher.source) return;
            if (next === "local" && !switcher.localAvailable) return;
            switcher.source = next;
            navStub.reset();
            switcher.reload();
        }
    }

    TestCase {
        name: "SourceSwitchRefetches"

        function init() {
            switcher.source = "remote";
            switcher.reloads = 0;
            switcher.localAvailable = true;
            navStub.view = "repo";
        }

        function test_switching_source_refetches_the_repository_list() {
            switcher.setSource("local");
            compare(switcher.source, "local");
            // The actual bug: without this the list keeps the previous
            // source's rows, or shows none at all.
            compare(switcher.reloads, 1,
                    "switching source must refetch, not only reset nav state");
        }

        function test_switching_source_returns_to_the_repository_list() {
            switcher.setSource("local");
            compare(navStub.view, "repos",
                    "a repo id from one source is meaningless to the other");
        }

        function test_switching_to_the_same_source_does_nothing() {
            switcher.setSource("remote");
            compare(switcher.reloads, 0, "no refetch when nothing changed");
        }

        /// Guarding here as well as by hiding the segment: a spec or a future
        /// caller can reach setSource() directly.
        function test_local_is_refused_when_no_profile_exists() {
            switcher.localAvailable = false;
            switcher.setSource("local");
            compare(switcher.source, "remote");
            compare(switcher.reloads, 0);
        }
    }

    TestCase {
        name: "SourceRouting"

        function test_calls_go_to_the_remote_surface_by_default() {
            router.source = "remote";
            router.call("ListRepos", [], function () {});
            compare(router.lastMethod, "remoteListRepos");
        }

        function test_calls_follow_the_selected_source() {
            router.source = "local";
            router.call("ListRepos", [], function () {});
            compare(router.lastMethod, "localListRepos");

            router.call("GetCommit", [], function () {});
            compare(router.lastMethod, "localGetCommit",
                    "every method follows the source, not just listing");
        }

        /// The per-call override still wins, so a future screen can show both
        /// sources at once without changing the global setting.
        function test_an_explicit_source_overrides_the_selected_one() {
            router.source = "local";
            router.call("GetRepo", [], function () {}, null, "remote");
            compare(router.lastMethod, "remoteGetRepo");
        }
    }
}
