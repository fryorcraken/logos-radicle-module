import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * The settings panel, the mode picker and the node-status badge.
 *
 * The fakes here return INPUT-DEPENDENT data throughout, which is the whole
 * reason these tests can distinguish working from broken. A fake settings
 * backend that echoed one fixed object for every write would satisfy a test
 * asserting "the panel shows a mode" no matter whether the write reached it,
 * which is exactly the trap that hid a dead branch-switching feature here for
 * a whole milestone. So: the fake stores what it is given and hands back what
 * it stored, and refuses specific inputs with specific messages.
 */
Item {
    id: harness
    width: 640
    height: 800

    // ---- a settings backend that actually remembers ----------------------
    QtObject {
        id: fakeBackend

        property var stored: ({
            mode: "local",
            radHome: "",
            radSocket: "",
            gitPath: "",
            remoteSeed: ""
        })
        property int writes: 0

        function get(cb) {
            cb(JSON.parse(JSON.stringify(stored)));
        }

        function set(key, value, cb) {
            writes++;
            // Input-dependent refusals, mirroring the real validator. Each
            // names what was wrong, because the panel surfaces the message
            // verbatim and a test that accepted any error string would not
            // notice the panel showing the wrong one.
            if (key === "gitPath" && value === "/definitely/not/here/git") {
                cb({ error: "not a usable git: no such file: " + value });
                return;
            }
            if (key === "mode" && value === "turbo") {
                cb({ error: "unknown mode 'turbo'" });
                return;
            }
            var next = JSON.parse(JSON.stringify(stored));
            next[key] = value;
            stored = next;
            cb(JSON.parse(JSON.stringify(next)));
        }
    }

    // The DEFAULT capabilities: mode "local", which IS startable.
    //
    // This fixture used to say `modeStartable: false`, and that single line was
    // load-bearing in the worst way — it was the only reason the honesty test
    // below passed. The panel derived its startable SET from that boolean, so a
    // fixture pinning it false produced the right annotation by accident; in
    // the state every real first-time user is in (local, startable) the same
    // derivation offered Embedded with no caveat at all.
    //
    // So the fixture now describes the default state, and the honesty test is
    // an assertion about the code rather than about the fixture.
    readonly property var defaultCaps: ({
        mode: "local",
        modeStartable: true,
        startableModes: ["local", "explore"],
        modeUnavailableReason: "",
        gitFound: true,
        gitPath: "/usr/bin/git",
        gitVersion: "git version 2.55.0",
        gitConfigured: false
    })

    Ui.SettingsPanel {
        id: panel
        width: 600
        caps: harness.defaultCaps
        fetchSettings: function (cb) { fakeBackend.get(cb); }
        saveSetting: function (k, v, cb) { fakeBackend.set(k, v, cb); }
    }

    /// Find the first descendant carrying `name` as its objectName.
    ///
    /// `findChild` is used throughout this file and is enough for the panel's
    /// own internals, but the escape-hatch case below has to search a HOST
    /// whose child is the panel, and it has to be able to return a MouseArea —
    /// which is where the objectName lives, by this repo's own convention.
    function findByName(node, name) {
        if (!node) return null;
        if (node.objectName === name) return node;
        for (var i = 0; i < node.children.length; i++) {
            var hit = harness.findByName(node.children[i], name);
            if (hit) return hit;
        }
        return null;
    }

    // ---- the overlay, hosted the way Main.qml hosts it --------------------
    //
    // Settings do not replace a page in the navigation StackLayout; they cover
    // it. That is the whole reason closing them can restore "wherever you
    // were" without a back-stack entry — but it is also how the panel became a
    // ONE-WAY DOOR: the overlay covers the header, the header is where the
    // "Settings" toggle lives, and with no control inside the overlay there
    // was no way back at all. The user had to restart Basecamp.
    //
    // Main.qml itself needs a live QtRO backend and cannot be instantiated in a
    // component test, so what is reproduced here is the STRUCTURE that failed:
    // a body screen, an opaque pane covering it bound to `settingsOpen`, and
    // the real SettingsPanel inside. Everything asserted below is about the
    // real component; only the host is a stand-in.
    property bool settingsOpen: false

    /// Stands in for the navigation stack under the overlay. Its `screen`
    /// records where the user was, so "closing restores the previous screen"
    /// is an assertion about a value that could actually be wrong, rather than
    /// about a default that would look identical either way.
    Rectangle {
        id: bodyUnderneath
        objectName: "bodyUnderneath"
        anchors.fill: parent
        property string screen: "repos"
    }

    Rectangle {
        id: overlayPane
        objectName: "overlayPane"
        anchors.fill: parent
        // Opaque, exactly as in Main.qml: this is what makes the panel a door
        // rather than a floating card, and therefore what makes a missing exit
        // a trap rather than a nuisance.
        color: "#0d1117"
        visible: harness.settingsOpen

        Ui.SettingsPanel {
            id: overlayPanel
            objectName: "overlayPanel"
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: 600
            caps: harness.defaultCaps
            fetchSettings: function (cb) { fakeBackend.get(cb); }
            saveSetting: function (k, v, cb) { fakeBackend.set(k, v, cb); }
            onClosed: harness.settingsOpen = false
        }
    }

    TestCase {
        name: "SettingsAreEscapable"
        when: windowShown

        function init() {
            harness.settingsOpen = true;
            bodyUnderneath.screen = "repo:rad:zDEEP";
        }

        function cleanup() {
            harness.settingsOpen = false;
        }

        /// The defect, stated directly: there must BE a way out.
        ///
        /// Asserted on the element existing and being visible rather than by
        /// clicking first, because "the control is missing" and "the control is
        /// there but does nothing" are different faults with different fixes,
        /// and a click-only test reports them identically.
        function test_the_panel_offers_a_visible_way_out() {
            var back = harness.findByName(overlayPanel, "settingsBackButton");
            verify(back !== null,
                   "the settings panel has no close control — it covers the "
                   + "header that opened it, so this is a one-way door and the "
                   + "user has to restart the app");
            verify(back.visible, "a close control nobody can see is not one");
            verify(back.width > 0 && back.height > 0,
                   "the close control has no clickable area: "
                   + back.width + "x" + back.height);
        }

        /// A real click through the MouseArea, and the assertion is on the
        /// overlay's VISIBILITY rather than on a signal count.
        ///
        /// That distinction is the lesson CommitView's back button taught this
        /// repo from the other side: a click test structurally cannot see a
        /// covering overlay, so a test that only counted clicks would pass just
        /// as happily against a panel that stayed on screen. What has to be
        /// impossible is "closed" being indistinguishable from "still open but
        /// transparent" — hence `visible`, which is what actually decides
        /// whether the user is still trapped.
        function test_clicking_the_way_out_actually_closes_the_panel() {
            verify(overlayPane.visible, "the fixture must start open");

            var back = harness.findByName(overlayPanel, "settingsBackButton");
            verify(back !== null, "no close control to click");
            mouseClick(back);

            verify(!harness.settingsOpen,
                   "clicking the close control must ask the host to close");
            verify(!overlayPane.visible,
                   "the overlay is still covering the screen — the panel "
                   + "signalled nothing, or the signal is not connected");
        }

        /// Escape closes it too, consistent with every other dismissable thing
        /// a user meets. A keyboard user who cannot find the control still gets
        /// out, and the reflex costs nothing when there is a button as well.
        function test_escape_closes_the_panel() {
            verify(overlayPane.visible, "the fixture must start open");
            overlayPanel.forceActiveFocus();
            keyClick(Qt.Key_Escape);
            verify(!overlayPane.visible,
                   "Escape must dismiss the settings panel");
        }

        /// Closing restores where the user WAS, not a default screen.
        ///
        /// The value under the overlay is deliberately not the default one, so
        /// a panel that closed by resetting the navigation stack — sending a
        /// user who was deep inside a repository back to the repository list —
        /// fails here. That is a real and tempting wrong fix: it is what
        /// putting settings into the StackLayout would have forced.
        function test_closing_restores_the_screen_that_was_underneath() {
            compare(bodyUnderneath.screen, "repo:rad:zDEEP",
                    "the fixture must place the user somewhere specific");

            var back = harness.findByName(overlayPanel, "settingsBackButton");
            mouseClick(back);

            verify(!overlayPane.visible);
            compare(bodyUnderneath.screen, "repo:rad:zDEEP",
                    "closing settings sent the user somewhere else — settings "
                    + "overlay the navigation stack and must not disturb it");
        }

        /// The close control must be reachable, not merely present.
        ///
        /// It lives inside a panel that is `anchors.top`-ed to the pane and can
        /// grow past the bottom of it, so a control placed at the END of the
        /// column would be off-screen on a short window — present, visible by
        /// the property, and unclickable. Asserted on geometry for the same
        /// reason the caption is: a click test cannot tell you an element is
        /// outside the viewport, it just silently reaches whatever is there.
        function test_the_way_out_is_within_the_visible_pane() {
            var back = harness.findByName(overlayPanel, "settingsBackButton");
            var topLeft = back.mapToItem(overlayPane, 0, 0);
            var bottom = back.mapToItem(overlayPane, 0, back.height).y;

            verify(topLeft.y >= -1,
                   "the close control is above the pane's top edge, at "
                   + topLeft.y);
            verify(bottom <= overlayPane.height + 1,
                   "the close control's bottom is at " + bottom + " in a "
                   + overlayPane.height + "px pane — it is off-screen, and a "
                   + "way out the user cannot reach is not a way out");
        }
    }

    TestCase {
        name: "SettingsPanel"
        when: windowShown

        function init() {
            fakeBackend.stored = {
                mode: "local", radHome: "", radSocket: "",
                gitPath: "", remoteSeed: ""
            };
            fakeBackend.writes = 0;
            panel.loaded = false;
            panel.lastError = "";
            // `caps` is restored too, not just the backend. A test that
            // rewrites it to simulate a missing git would otherwise leak that
            // state into whichever test runs next — QtTest orders by name, so
            // the victim is arbitrary and the failure reads as unrelated. This
            // was a real failure here before the restore was added.
            //
            // Restored to the DEFAULT capabilities — the local/startable state
            // a first-time user is in — rather than to a hand-picked shape that
            // happens to make the assertions below easy.
            panel.caps = harness.defaultCaps;
            panel.reload();
        }

        function test_the_panel_loads_the_persisted_settings() {
            compare(panel.currentMode, "local");
        }

        function test_choosing_a_mode_persists_it_and_the_panel_reflects_it() {
            // Distinct from the starting value, so a panel that ignored the
            // reply and kept showing its initial state would fail here.
            panel.apply("mode", "explore");
            compare(fakeBackend.stored.mode, "explore",
                    "the write must reach the backend");
            compare(panel.currentMode, "explore",
                    "and the panel must re-render from the reply");
        }

        function test_two_different_modes_give_two_different_results() {
            // Input-dependent: a panel hardcoding either answer fails one leg.
            panel.apply("mode", "explore");
            compare(panel.currentMode, "explore");

            panel.apply("mode", "embedded");
            compare(panel.currentMode, "embedded");
        }

        function test_a_refused_git_path_surfaces_the_message_and_changes_nothing() {
            panel.apply("gitPath", "/definitely/not/here/git");

            verify(panel.hasError, "a refusal must be surfaced, not swallowed");
            verify(panel.lastError.indexOf("/definitely/not/here/git") !== -1,
                   "the message must name the path that was tried, got: "
                   + panel.lastError);
            compare(panel.currentGitPath, "",
                    "a refused value must not be shown as if it had been saved");
        }

        function test_a_refused_mode_surfaces_its_own_message() {
            // A different refusal with a different message, so a panel that
            // showed one canned error for every failure would fail here.
            panel.apply("mode", "turbo");
            verify(panel.lastError.indexOf("turbo") !== -1,
                   "got: " + panel.lastError);
            compare(panel.currentMode, "local", "the stored mode is untouched");
        }

        function test_a_successful_write_clears_a_previous_error() {
            panel.apply("mode", "turbo");
            verify(panel.hasError);

            panel.apply("mode", "explore");
            verify(!panel.hasError,
                   "a later success must clear the earlier refusal, or the "
                   + "panel keeps accusing the user of a mistake they fixed");
        }

        function test_an_accepted_git_path_is_stored() {
            panel.apply("gitPath", "/usr/bin/git");
            compare(fakeBackend.stored.gitPath, "/usr/bin/git");
            verify(!panel.hasError);
        }

        function test_the_restart_note_is_present() {
            // The one thing worse than a setting that needs a restart is one
            // that needs a restart without saying so. Asserting the note
            // EXISTS and is visible, because it is load-bearing text rather
            // than decoration.
            var note = findChild(panel, "gitRestartNote");
            verify(note !== null, "the restart-to-apply note must exist");
            verify(note.visible);
            verify(note.text.length > 0);
        }

        function test_the_resolved_git_is_reported() {
            var resolved = findChild(panel, "gitResolved");
            verify(resolved !== null);
            verify(resolved.text.indexOf("/usr/bin/git") !== -1,
                   "the resolved path must be shown so a user can see which "
                   + "git is in force, got: " + resolved.text);
        }

        function test_a_missing_git_is_reported_as_a_problem() {
            panel.caps = ({ gitFound: false,
                            gitProblem: "no `git` found on PATH" });
            var resolved = findChild(panel, "gitResolved");
            verify(resolved.text.indexOf("not found") !== -1,
                   "got: " + resolved.text);
        }
    }

    TestCase {
        name: "ModePicker"
        when: windowShown

        // Same reason as the SettingsPanel case's: a test that rewrites `caps`
        // must not leave the next one running against it. QtTest orders by
        // name, so the victim would be arbitrary and the failure would read as
        // unrelated to the test that caused it.
        function init() {
            panel.caps = harness.defaultCaps;
        }

        function test_a_non_startable_mode_says_so_in_its_own_row() {
            // The honesty guarantee, asserted IN THE DEFAULT STATE — mode
            // "local", which is startable. That is the whole point: the panel
            // used to derive its startable set from `caps.modeStartable`, a
            // fact about the CURRENT mode, so with local selected the set
            // became all three and Embedded was offered with no caveat at all.
            // The user selected it, it persisted, and only then did a warning
            // appear — a control that silently does nothing.
            //
            // This test passed before only because the fixture hardcoded
            // `modeStartable: false`, which is the same-answer-for-every-input
            // trap in fixture form. With the fixture describing the real
            // default, the assertion is about the panel again.
            compare(panel.caps.mode, "local", "the default state, on purpose");
            compare(panel.caps.modeStartable, true,
                    "local IS startable — which is exactly why deriving the "
                    + "set from this boolean cannot work");

            var picker = findChild(panel, "modePicker");
            verify(picker !== null);

            var note = findChild(picker, "modeUnavailable_embedded");
            verify(note !== null, "the embedded row must carry an availability note");
            verify(note.visible,
                   "Embedded must be annotated as unavailable BEFORE it is "
                   + "chosen, not after");
        }

        function test_a_startable_mode_carries_no_unavailability_note() {
            // The other half: if every row showed the note, the note would say
            // nothing. Attach and Seed-only are startable, so their notes stay
            // hidden while Embedded's shows — one fixture, three different
            // answers, which is what makes the annotation meaningful.
            var picker = findChild(panel, "modePicker");
            verify(!findChild(picker, "modeUnavailable_local").visible,
                   "a startable mode must not be annotated as unavailable");
            verify(!findChild(picker, "modeUnavailable_explore").visible,
                   "nor the other startable one");
            verify(findChild(picker, "modeUnavailable_embedded").visible,
                   "while the unstartable one is");
        }

        function test_the_annotation_follows_the_startable_set_not_the_selection() {
            // Input-dependent on the field that actually decides this. Handing
            // the panel a build in which Embedded IS startable must move the
            // annotation, with nothing about the selected mode changing — which
            // a panel still deriving from `modeStartable` could not do.
            var picker = findChild(panel, "modePicker");
            verify(findChild(picker, "modeUnavailable_embedded").visible);

            panel.caps = ({ mode: "local",
                            modeStartable: true,
                            startableModes: ["local", "embedded", "explore"],
                            modeUnavailableReason: "",
                            gitFound: true, gitPath: "/usr/bin/git",
                            gitVersion: "git version 2.55.0",
                            gitConfigured: false });

            verify(!findChild(picker, "modeUnavailable_embedded").visible,
                   "when the build can start Embedded, the caveat must go");

            // And the reverse, so this cannot pass by never showing the note.
            panel.caps = ({ mode: "local",
                            modeStartable: true,
                            startableModes: ["explore"],
                            modeUnavailableReason: "",
                            gitFound: true, gitPath: "/usr/bin/git",
                            gitVersion: "git version 2.55.0",
                            gitConfigured: false });

            verify(findChild(picker, "modeUnavailable_local").visible,
                   "a build that cannot start Attach must say so on the Attach "
                   + "row, even though Attach is the mode in force");
        }

        function test_clicking_a_mode_row_chooses_it() {
            // A real click through the MouseArea, not a hand-emitted signal:
            // objectName lives on the clickable element for exactly this
            // reason, and a delegate whose MouseArea was mis-parented would
            // pass a signal-emitting test and fail this one.
            var picker = findChild(panel, "modePicker");
            var area = findChild(picker, "modePick_explore");
            verify(area !== null, "the clickable element must carry the objectName");

            mouseClick(area);
            compare(panel.currentMode, "explore");
        }
    }

    // The identity readout that replaced the header's free-floating
    // "Attached · z6Mko…" badge.
    //
    // The badge was a separate chip with button chrome that did nothing, and
    // the user could not tell what it meant. The abbreviated identity now
    // rides on the source toggle's Local segment (tst_source.qml covers that);
    // the FULL DID and the resolved home are reference information, which is
    // what Settings is for. Neither is behind a hover any more — the tooltip
    // that used to hold them rendered as a clipped sliver.
    TestCase {
        name: "SettingsIdentity"
        when: windowShown

        function init() {
            panel.caps = harness.defaultCaps;
        }

        function test_the_full_identity_is_readable_without_hovering() {
            panel.caps = ({
                mode: "local", modeStartable: true,
                startableModes: ["local", "explore"],
                modeUnavailableReason: "",
                nodeId: "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd",
                radHome: "/home/u/.radicle",
                gitFound: true, gitPath: "/usr/bin/git"
            });
            var who = findChild(panel, "identityReadout");
            verify(who !== null, "the identity readout must exist");
            verify(who.visible);
            verify(who.text.indexOf(
                       "z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd") !== -1,
                   "the WHOLE did must be here — abbreviating in both places "
                   + "leaves nowhere to read it, got: " + who.text);
            verify(who.text.indexOf("/home/u/.radicle") !== -1,
                   "and the home it resolved to, got: " + who.text);
        }

        /// Input-dependent, so a hardcoded readout fails: a different profile
        /// must produce different text.
        function test_the_readout_follows_the_capabilities() {
            panel.caps = ({ nodeId: "did:key:z6MkAAAA", radHome: "/tmp/a",
                            startableModes: ["local"], modeStartable: true });
            var a = findChild(panel, "identityReadout").text;
            panel.caps = ({ nodeId: "did:key:z6MkBBBB", radHome: "/tmp/b",
                            startableModes: ["local"], modeStartable: true });
            var b = findChild(panel, "identityReadout").text;
            verify(a !== b, "got " + a + " for both profiles");
        }

        /// With no profile the readout must say so rather than showing an
        /// empty line that reads as a rendering bug.
        function test_no_profile_is_stated_rather_than_left_blank() {
            panel.caps = ({ nodeId: "", radHome: "",
                            startableModes: ["local"], modeStartable: true });
            var who = findChild(panel, "identityReadout");
            verify(who.visible, "the row stays, saying there is no identity");
            verify(who.text.length > 0);
            verify(who.text.indexOf("No local identity") !== -1,
                   "got: " + who.text);
        }
    }
}
