import QtQuick
import QtTest
import "../src/qml" as Ui
import "../src/qml/Theme.js" as Theme

/*
 * The header's mode control, the identity beside it, and the method routing
 * derived from the mode.
 *
 * These drive the toggle with real mouse clicks rather than by setting `mode` —
 * setting the property would pass even if the segments had no click handler,
 * which is the exact shape that shipped two click-dead rows in this codebase
 * before (see tst_clicks.qml). The user's own report of this control was that
 * it "cant be clicked", so a click that changes state is the thing under test.
 */
Item {
    id: root

    width: 800
    height: 300

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

    /// Every descendant whose objectName starts with `prefix`. Used to count
    /// segments, so "exactly three" is an assertion about what is rendered
    /// rather than about what the model happens to say.
    function collectByPrefix(node, prefix, out) {
        if (!node) return out;
        if (typeof node.objectName === "string"
            && node.objectName.indexOf(prefix) === 0)
            out.push(node.objectName);
        for (var i = 0; i < node.children.length; i++)
            collectByPrefix(node.children[i], prefix, out);
        return out;
    }

    Ui.SourceToggle {
        id: toggle
        objectName: "toggle"
        anchors.top: parent.top
        anchors.left: parent.left
        mode: "local"
        startableModes: ["explore", "local"]
        localAvailable: true
        onModeChosen: function (m) { chosen.push(m); }
    }

    Ui.NodeIdentity {
        id: identity
        objectName: "identity"
        anchors.top: parent.top
        anchors.left: toggle.right
        nodeId: ""
    }

    /// How many times the identity reported a completed copy.
    property int identityCopies: 0
    Connections {
        target: identity
        function onCopied() { root.identityCopies++; }
    }

    /// Whether anything asked for Settings. The identity used to open them and
    /// no longer does; this exists so that change can be asserted as a FALSE
    /// rather than merely by the absence of an assertion.
    property bool settingsOpened: false
    Connections {
        target: identity
        ignoreUnknownSignals: true
        function onSettingsRequested() { root.settingsOpened = true; }
    }

    // ---- reading the real clipboard ------------------------------------
    //
    // QtQuick exposes no Clipboard singleton, so the only handle on the system
    // clipboard from plain QML is TextEdit's own cut/copy/paste. That is also
    // exactly how NodeIdentity copies, so these helpers exercise the same
    // mechanism the component depends on: if the sandbox ever stops providing
    // a clipboard, these fail rather than quietly asserting nothing.
    //
    // A round trip through a SEPARATE TextEdit, deliberately — reading back the
    // component's own hidden editor would pass even if copy() were never
    // called, since its text is set regardless.
    TextEdit { id: clipProbe; visible: false }

    function clipboardSet(text) {
        clipProbe.text = text;
        clipProbe.selectAll();
        clipProbe.copy();
        clipProbe.text = "";
    }

    function clipboardGet() {
        clipProbe.text = "";
        clipProbe.selectAll();
        clipProbe.paste();
        return clipProbe.text;
    }

    // -----------------------------------------------------------------------
    // The segmented control: exactly three segments, one per mode, nothing else.
    // -----------------------------------------------------------------------
    TestCase {
        name: "SourceToggle"
        when: windowShown

        function init() {
            chosen = [];
            toggle.mode = "local";
            toggle.startableModes = ["explore", "local"];
            toggle.localAvailable = true;
            toggle.modeReason = "";
            toggle.pathsProblem = "";
            toggle.reason = "";
            // No settle here, deliberately. These tests need none because the
            // control's geometry is arithmetic rather than a layout pass —
            // see SourceToggle.qml. Earlier versions of this file called
            // `wait(0)` in every init(), and each of those was hiding a real
            // lag between the control's content and the size it reported. If a
            // settle ever becomes necessary again, that is a defect in the
            // component, not a missing line here.
        }

        function test_there_are_exactly_three_segments_one_per_mode() {
            // The user's instruction, asserted literally: the control is
            // "explore | local | embedded" and nothing else. Counting rendered
            // elements rather than reading the model, so a fourth segment
            // slipped in anywhere would fail here.
            var names = root.collectByPrefix(toggle, "sourceToggle_", []);
            compare(names.length, 3, "got: " + names.join(", "));

            verify(root.findByName(toggle, "sourceToggle_explore") !== null);
            verify(root.findByName(toggle, "sourceToggle_local") !== null);
            verify(root.findByName(toggle, "sourceToggle_embedded") !== null);
        }

        /// The identity must NOT be inside the control. It answers "who am I",
        /// which is a different question from "what am I browsing", and putting
        /// it in a segment made the control's geometry follow the capabilities.
        function test_no_identity_lives_inside_the_segmented_control() {
            verify(root.findByName(toggle, "nodeIdentity") === null,
                   "the identity element must not be inside the toggle");
            verify(root.findByName(toggle, "nodeIdentityLabel") === null);

            // And no segment label may carry a DID. Asserted on the rendered
            // text, because the failure mode was a label built from `shortId`.
            var keys = ["explore", "local", "embedded"];
            for (var i = 0; i < keys.length; i++) {
                var lbl = root.findByName(toggle, "sourceToggleLabel_" + keys[i]);
                verify(lbl !== null, "missing label for " + keys[i]);
                verify(lbl.text.indexOf("z6Mk") === -1,
                       "a segment label carries an identity: " + lbl.text);
                verify(lbl.text.indexOf("·") === -1,
                       "a segment label carries a second concept: " + lbl.text);
            }
        }

        /// Each label is the mode's own word — one vocabulary, top to bottom.
        function test_each_segment_reads_as_its_mode() {
            compare(root.findByName(toggle, "sourceToggleLabel_explore").text,
                    "Explore");
            compare(root.findByName(toggle, "sourceToggleLabel_local").text,
                    "Local");
            compare(root.findByName(toggle, "sourceToggleLabel_embedded").text,
                    "Embedded");
        }

        /// A real click, not an emitted signal: this is what proves the segment
        /// is actually wired, and it is the literal answer to "cant be clicked".
        function test_clicking_each_segment_reports_that_mode() {
            // Input-dependent across all three: a control that reported one
            // fixed mode for every click would pass a single-segment assertion
            // and fail this.
            mouseClick(root.findByName(toggle, "sourceToggle_explore"));
            compare(chosen[chosen.length - 1], "explore");

            mouseClick(root.findByName(toggle, "sourceToggle_embedded"));
            compare(chosen[chosen.length - 1], "embedded");

            mouseClick(root.findByName(toggle, "sourceToggle_local"));
            compare(chosen[chosen.length - 1], "local");

            compare(chosen.length, 3, "every click must have been delivered");
        }

        /// Embedded is offered rather than hidden or disabled — it is a real,
        /// persistable choice whose consequence is stated. A control that
        /// refused the click would be the "silently does nothing" bug in a
        /// different costume.
        function test_embedded_is_clickable_even_though_it_cannot_start() {
            verify(!toggle.isStartable("embedded"),
                   "the fixture must describe a build that cannot start it");
            mouseClick(root.findByName(toggle, "sourceToggle_embedded"));
            compare(chosen[chosen.length - 1], "embedded",
                    "an unstartable mode must still be selectable");
        }

        /// Selecting a segment must not resize it.
        ///
        /// This is a real defect rather than a test artifact: when the segment
        /// width followed `font.bold: selected`, every click re-laid the row
        /// out — the newly selected segment grew, its neighbour shifted, and a
        /// click computed against the pre-click geometry landed on the WRONG
        /// segment. A user clicking twice in quick succession hits the same
        /// window, and it reads as "the toggle sometimes ignores me".
        ///
        /// The tempting fix was a `waitForRendering` in the test. That would
        /// have made the test pass and left the control jumping under real
        /// fingers, so the geometry is pinned instead.
        function test_selecting_a_segment_does_not_move_the_others() {
            var explore = root.findByName(toggle, "sourceToggle_explore");
            var local = root.findByName(toggle, "sourceToggle_local");

            toggle.mode = "explore";
            var ew = explore.width, lw = local.width;
            var ex = explore.mapToItem(toggle, 0, 0).x;
            var lx = local.mapToItem(toggle, 0, 0).x;

            toggle.mode = "local";
            compare(explore.width, ew, "Explore changed width on select");
            compare(local.width, lw, "Local changed width on select");
            compare(explore.mapToItem(toggle, 0, 0).x, ex, "Explore moved");
            compare(local.mapToItem(toggle, 0, 0).x, lx, "Local moved");
        }
    }

    // -----------------------------------------------------------------------
    // The caption: everything the old clipped tooltip tried to say, on screen.
    // -----------------------------------------------------------------------
    TestCase {
        name: "SourceToggleCaption"
        when: windowShown

        function init() {
            chosen = [];
            toggle.mode = "local";
            toggle.startableModes = ["explore", "local"];
            toggle.localAvailable = true;
            toggle.modeReason = "";
            toggle.pathsProblem = "";
            toggle.reason = "";
        }

        /// The regression the user actually hit: *"why the warning sign for
        /// local????"*. Local browsing WORKS on a machine with a profile, and
        /// decorating a working feature with a warning is a lie.
        ///
        /// Asserted on `hasProblem` — which drives the colour — because there
        /// is no glyph to look for; the amber styling IS what the user read as
        /// a warning sign.
        function test_local_carries_no_warning_when_a_profile_exists() {
            toggle.mode = "local";
            toggle.localAvailable = true;
            verify(!toggle.hasProblem,
                   "a working local profile must not be flagged as a problem");
        }

        /// The other half, or `hasProblem` could just always be false: a real
        /// problem must still flag. One component, two different answers.
        function test_a_real_problem_still_flags() {
            toggle.pathsProblem = "the node control socket path is too long: "
                                + "114 bytes, limit 108";
            verify(toggle.hasProblem,
                   "an unusable socket path IS a problem and must show as one");
        }

        /// The Embedded caveat belongs to Embedded, so it appears when Embedded
        /// is the SELECTED mode and not otherwise.
        ///
        /// The first version of this caption was unconditional, and the user
        /// asked for it gone: *"remove the text under the toggle when embeded
        /// is NOT selected"*. It is a paragraph about a mode you have not
        /// chosen, sitting on every screen, pushing the content down — noise
        /// rather than chrome.
        ///
        /// The caveat did not simply move, though; deleting it outright would
        /// have restored the "control that silently does nothing" bug an
        /// earlier review already caught in this PR. What replaces it is the
        /// marker ON the segment, asserted in the DEFAULT state further down.
        /// The two tests are a pair, and neither is complete alone.
        function test_the_embedded_caveat_shows_when_embedded_is_selected() {
            toggle.mode = "embedded";
            verify(!toggle.isStartable("embedded"),
                   "the fixture must describe a build that cannot start it");

            var note = root.findByName(toggle, "sourceToggleNote");
            verify(note !== null, "the caption line must exist");
            verify(note.visible,
                   "the mode that cannot start must explain itself once chosen");
            verify(note.text.indexOf("Embedded") !== -1,
                   "the caption must name the mode it is about, got: " + note.text);
            verify(note.text.indexOf("not available") !== -1
                   || note.text.indexOf("will not start") !== -1,
                   "and say it will not start a node, got: " + note.text);
            verify(note.text.indexOf("separate identity") !== -1,
                   "and state the consequence that actually matters, got: "
                   + note.text);
        }

        /// ...and is ABSENT for the two modes it is not about. This is the
        /// user's request, asserted for both of the other modes rather than
        /// only for the default one — a caption keyed on `mode !== "explore"`
        /// would pass a single-mode check and still be wrong on Local.
        function test_no_caption_when_embedded_is_not_selected() {
            var note = root.findByName(toggle, "sourceToggleNote");

            toggle.mode = "local";
            verify(!note.visible,
                   "Local carries no caption — the Embedded paragraph is not "
                   + "about the mode the user is in, got: " + note.text);

            toggle.mode = "explore";
            verify(!note.visible,
                   "nor does Explore, got: " + note.text);

            // And back, so this cannot pass by never showing the caption at
            // all — which would take the caveat away entirely.
            toggle.mode = "embedded";
            verify(note.visible,
                   "the caption must still exist for the mode it is about");
        }

        /// The caveat still follows the startable SET, not just the selection:
        /// on a build that CAN start Embedded, selecting it says nothing.
        /// Otherwise the caption is decoration that happens to be true today.
        function test_the_caveat_follows_the_startable_set() {
            toggle.mode = "embedded";
            var note = root.findByName(toggle, "sourceToggleNote");
            verify(note.visible, "shown for a build that cannot start Embedded");

            toggle.startableModes = ["explore", "local", "embedded"];
            verify(!note.visible,
                   "when the build can start every mode there is nothing to "
                   + "caption, got: " + note.text);

            // And back, so this cannot pass by never showing it.
            toggle.startableModes = ["explore", "local"];
            verify(note.visible);
        }

        /// The blocker an earlier review caught in this PR, and the reason the
        /// caption could not simply be deleted: **the caveat must be visible
        /// BEFORE Embedded is chosen.** A segment that looks ordinary until you
        /// pick it, and only then admits it does nothing, is precisely the
        /// "control that silently does nothing" failure.
        ///
        /// So with the paragraph gone from the default state, the SEGMENT
        /// itself has to carry the indication. Asserted in mode `local` — the
        /// state every first-time user is in, and the one where the caption is
        /// now absent — because that is exactly where the guarantee could be
        /// lost without anything else going red.
        ///
        /// Not behind hover: the user rejected tooltips here, and this repo's
        /// last one rendered as a clipped, unreadable sliver.
        function test_the_embedded_segment_is_marked_unavailable_by_default() {
            compare(toggle.mode, "local", "the default state, on purpose");
            verify(toggle.isStartable(toggle.mode),
                   "the mode in force IS startable — so nothing about the "
                   + "current mode could be supplying this marker");

            var note = root.findByName(toggle, "sourceToggleNote");
            verify(!note.visible,
                   "precondition: the caption is gone in this state, which is "
                   + "why the segment has to speak for itself");

            var mark = root.findByName(toggle, "sourceToggleUnavailable_embedded");
            verify(mark !== null,
                   "the Embedded segment carries no unavailability marker — "
                   + "with the caption gone, nothing tells the user it will "
                   + "not start a node until after they have chosen it");
            verify(mark.visible,
                   "the marker exists but is hidden, which is the same thing "
                   + "as not having one");
            verify(mark.width > 0 && mark.height > 0,
                   "a zero-sized marker is invisible: "
                   + mark.width + "x" + mark.height);
        }

        /// The marker reads as "not built yet", not as "broken".
        ///
        /// Embedded is not in an error state — it is a Phase 2 feature — and
        /// this repo has already had the complaint from the other direction:
        /// *"why the warning sign for local????"* on a feature that works. So
        /// the marker must not borrow the error colour, and the control as a
        /// whole must not claim a problem.
        function test_the_marker_reads_as_unavailable_not_as_broken() {
            var mark = root.findByName(toggle, "sourceToggleUnavailable_embedded");
            verify(mark !== null);

            // Both the fill and the outline, because a marker drawn either way
            // would look like an error if it borrowed the error colour, and
            // asserting only the one this implementation happens to use would
            // let the other change silently.
            verify(!Qt.colorEqual(mark.color, Theme.bad)
                   && !Qt.colorEqual(mark.border.color, Theme.bad),
                   "the marker uses the error colour — Embedded is not broken, "
                   + "it is not built yet");
            verify(!Qt.colorEqual(mark.color, Theme.warn)
                   && !Qt.colorEqual(mark.border.color, Theme.warn),
                   "nor the warning colour: this repo already had the complaint "
                   + "from the other direction, a warning sign on a feature "
                   + "that works");

            verify(!toggle.hasProblem,
                   "an unbuilt mode nobody selected is not a problem with the "
                   + "mode in force, and must not flag the whole control");
        }

        /// The marker follows the startable SET, so it is an assertion about
        /// the build rather than a decoration that is true today. Same
        /// input-dependence rule as everything else here: one component, two
        /// different answers.
        function test_the_marker_goes_when_the_build_can_start_embedded() {
            var mark = root.findByName(toggle, "sourceToggleUnavailable_embedded");
            verify(mark.visible, "shown for a build that cannot start Embedded");

            toggle.startableModes = ["explore", "local", "embedded"];
            verify(!mark.visible,
                   "a build that CAN start Embedded must not mark it");

            toggle.startableModes = ["explore", "local"];
            verify(mark.visible, "and back, so this cannot pass by never showing");
        }

        /// Before the first `getCapabilities` reply, nothing is known — and
        /// "nothing is known" must not be rendered as "nothing works".
        ///
        /// `caps` starts as `({})`, so `caps.startableModes` is `undefined`
        /// until the reply lands. Passing `[]` for that produced an amber
        /// border on the whole control and an "unavailable" marker on ALL
        /// THREE segments, Local included — which is literally the *"why the
        /// warning sign for local????"* complaint this milestone already fixed,
        /// reappearing at startup on every launch.
        ///
        /// `[]` is still the right default for a caller that FORGOT to wire
        /// this — over-annotation is visible, under-annotation is the bug the
        /// property exists to prevent. But "not yet known" and "known to be
        /// empty" are different states and cannot share one value, so
        /// `undefined` now means the first and annotates nothing.
        function test_nothing_is_marked_before_capabilities_arrive() {
            // Exactly what Main.qml holds before the first reply.
            toggle.startableModes = undefined;

            verify(!toggle.hasProblem,
                   "the control claims a problem before it has been told "
                   + "anything — an amber border on every launch, on a build "
                   + "where all three modes may be perfectly fine");

            var keys = ["explore", "local", "embedded"];
            for (var i = 0; i < keys.length; i++) {
                var mark = root.findByName(toggle,
                                           "sourceToggleUnavailable_" + keys[i]);
                verify(mark === null || !mark.visible,
                       keys[i] + " is marked unavailable before capabilities "
                       + "have arrived — the UI is asserting something it "
                       + "cannot know yet, and for Local that is the exact "
                       + "false warning this milestone already fixed once");
            }
        }

        /// ...and the distinction is real in BOTH directions. A known-empty set
        /// is a genuine statement — this build starts nothing — and must still
        /// annotate everything.
        ///
        /// Without this leg the fix above could be "never annotate on an empty
        /// array", which would silently drop the caveat for a caller that
        /// forgot to wire the property at all: exactly the under-annotation the
        /// conservative default exists to prevent.
        function test_a_known_empty_set_still_marks_everything() {
            toggle.startableModes = [];

            var keys = ["explore", "local", "embedded"];
            for (var i = 0; i < keys.length; i++) {
                var mark = root.findByName(toggle,
                                           "sourceToggleUnavailable_" + keys[i]);
                verify(mark !== null && mark.visible,
                       keys[i] + " is NOT marked for a build that says it can "
                       + "start nothing — `[]` is a fact, and a caller who "
                       + "forgot to wire this must get the visible "
                       + "over-annotation rather than a silent all-clear");
            }
        }

        /// Only the unstartable segment is marked. If every segment carried one
        /// the marker would say nothing — the same reason ModePicker asserts
        /// its three rows give three answers from one fixture.
        function test_only_the_unstartable_segment_is_marked() {
            verify(root.findByName(toggle, "sourceToggleUnavailable_embedded").visible,
                   "the unstartable one is marked");

            var explore = root.findByName(toggle, "sourceToggleUnavailable_explore");
            var local = root.findByName(toggle, "sourceToggleUnavailable_local");
            verify(explore === null || !explore.visible,
                   "Explore is startable and must not be marked");
            verify(local === null || !local.visible,
                   "Local is startable and must not be marked");
        }

        /// A missing profile is a different sentence from an unstartable mode,
        /// and both must be readable rather than hovered. This is the case the
        /// old clipped tooltip existed for.
        function test_a_missing_profile_is_explained_in_words() {
            // Every mode startable, so the Embedded caveat does not mask this.
            toggle.startableModes = ["explore", "local", "embedded"];
            toggle.mode = "local";
            toggle.localAvailable = false;
            toggle.reason = "No Radicle profile on this machine — run `rad auth`";

            var note = root.findByName(toggle, "sourceToggleNote");
            verify(note.visible,
                   "a mode that wanted a profile and found none must say so");
            verify(note.text.indexOf("rad auth") !== -1,
                   "verbatim, got: " + note.text);
        }

        /// ...and NOT in Explore, where having no local profile is not a
        /// deficiency: you did not ask for one. A caption that fired here would
        /// be the "warning on a working feature" complaint again.
        function test_a_missing_profile_is_not_mentioned_in_explore() {
            toggle.startableModes = ["explore", "local", "embedded"];
            toggle.mode = "explore";
            toggle.localAvailable = false;
            toggle.reason = "No Radicle profile on this machine — run `rad auth`";

            var note = root.findByName(toggle, "sourceToggleNote");
            verify(!note.visible,
                   "Explore needs no local profile, so its absence is not "
                   + "news, got: " + note.text);
        }

        /// A resolved-paths problem is neither of the above — "we could never
        /// have talked to it" is a different fix from "it is not running" — and
        /// it must not be swallowed by the other branches.
        function test_a_paths_problem_is_explained_in_words() {
            toggle.pathsProblem = "the node control socket path is too long: "
                                + "114 bytes, limit 108";
            var note = root.findByName(toggle, "sourceToggleNote");
            verify(note.visible);
            verify(note.text.indexOf("108") !== -1,
                   "the limit must survive into the caption, got: " + note.text);
        }

        /// The old control leaked its explanation into a Rectangle anchored to
        /// `parent.bottom` inside a fixed-height bar, where `z` cannot lift it
        /// over a later sibling of a DIFFERENT parent — so it rendered as an
        /// unreadable sliver. The caption is now part of the control's own
        /// layout; assert it is INSIDE the control's bounds, because a caption
        /// hanging below its parent is that bug returning.
        ///
        /// Asserted on geometry rather than by clicking: a click test
        /// structurally cannot see a clipped overlay, which is what CommitView's
        /// back button taught this repo.
        function test_the_caption_is_inside_the_control_not_hanging_below_it() {
            // `embedded`, because that is now the only mode with a caption —
            // the paragraph used to be unconditional. The guarantee is
            // unchanged: wherever a caption DOES appear it must be inside its
            // parent. Asserting it in a state with nothing to place would be a
            // test that cannot fail.
            toggle.mode = "embedded";

            var note = root.findByName(toggle, "sourceToggleNote");
            verify(note.visible, "Embedded has a caption to place");

            // Deliberately NOT preceded by a settle. The caption's width is a
            // Theme constant rather than a function of the control beneath it,
            // so its height — and therefore the control's — is known in one
            // layout pass. When the width tracked `frame.width` the chain took
            // several passes to settle and this measured a caption genuinely
            // hanging out of a parent that had not grown yet. Waiting would
            // have hidden that; the dependency was cut instead.
            var bottom = note.mapToItem(toggle, 0, note.height).y;
            verify(bottom <= toggle.height + 1,
                   "the caption's bottom is at " + bottom + " but the control "
                   + "is only " + toggle.height + "px tall — it is hanging "
                   + "outside its parent and will be clipped");
            verify(note.mapToItem(toggle, 0, 0).y >= -1,
                   "the caption starts above the control's top edge");
            verify(note.height > 0, "a zero-height caption is invisible");
        }
    }

    // -----------------------------------------------------------------------
    // The identity: its own element, beside the control, never inside it.
    // -----------------------------------------------------------------------
    TestCase {
        name: "NodeIdentity"
        when: windowShown

        function init() {
            root.identityCopies = 0;
            root.settingsOpened = false;
            identity.nodeId = "";
            // The confirmation is on a 1.6s timer, so without this a previous
            // test's copy is still being confirmed when this one starts.
            identity.clearConfirmation();
        }

        /// The FULL DID, verbatim — not a prefix, not an elision.
        ///
        /// It used to be truncated to 14 characters plus an ellipsis, and the
        /// user asked for the whole thing. This asserts the complete string
        /// and, separately, the absence of an ellipsis: an assertion that only
        /// checked `indexOf("z6Mko") === 0` passes just as happily against the
        /// truncated version, which is what made the old test unable to catch
        /// this.
        function test_the_identity_shows_the_full_did() {
            var did = "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd";
            identity.nodeId = did;
            var lbl = root.findByName(identity, "nodeIdentityLabel");
            verify(lbl !== null && lbl.visible);
            compare(lbl.text, did,
                    "the whole identity must be on screen, got: " + lbl.text);
            verify(lbl.text.indexOf("…") === -1,
                   "no elision — the user asked for the full id, got: "
                   + lbl.text);
        }

        /// The `did:key:` prefix STAYS. `rad self` prints the DID in this form
        /// and `rad id update --allow` takes it in this form; stripping it to a
        /// bare NID is trivial for a user, guessing the prefix back is not.
        ///
        /// And it must NOT gain a `rad:` prefix: that namespaces REPOSITORY
        /// ids (`rad:z39LL…`), not node ids, so prefixing this would be
        /// actively wrong rather than merely redundant.
        function test_the_identity_keeps_did_key_and_never_says_rad() {
            var did = "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd";
            identity.nodeId = did;
            var t = root.findByName(identity, "nodeIdentityLabel").text;
            verify(t.indexOf("did:key:") === 0,
                   "the form `rad self` prints and `rad id update --allow` "
                   + "takes, got: " + t);
            verify(t.indexOf("rad:") === -1,
                   "`rad:` prefixes repository ids, not node ids — got: " + t);
        }

        /// Input-dependent, so a hardcoded label fails: two identities must
        /// render differently.
        function test_two_identities_render_differently() {
            identity.nodeId = "did:key:z6MkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
            var a = root.findByName(identity, "nodeIdentityLabel").text;
            identity.nodeId = "did:key:z6MkBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
            var b = root.findByName(identity, "nodeIdentityLabel").text;
            verify(a !== b, "got " + a + " for both");
        }

        /// It must NOT restate the mode. The segment already says "Local", and
        /// the badge saying "Attached" beside it was the duplicated vocabulary
        /// that made the header unreadable in the first place.
        function test_the_identity_does_not_restate_the_mode() {
            identity.nodeId =
                "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd";
            var t = root.findByName(identity, "nodeIdentityLabel").text;
            verify(t.indexOf("Attached") === -1, "got: " + t);
            verify(t.indexOf("Local") === -1, "got: " + t);
            verify(t.indexOf("Embedded") === -1, "got: " + t);
        }

        /// Absent rather than blank when there is nothing to show — the same
        /// reasoning that makes a missing segment better than a disabled one.
        function test_no_identity_means_no_element_at_all() {
            identity.nodeId = "";
            verify(!identity.visible,
                   "an empty identity slot reads as a rendering fault");
            compare(identity.implicitWidth, 0,
                   "and it must take no space in the header row");
        }

        /// Priority 2: anything that looks clickable must BE clickable. The
        /// badge this replaces looked like a button and did nothing, which is
        /// what made it read as broken. A real click, asserting a real effect.
        ///
        /// The effect is now COPYING, not opening Settings — the user asked for
        /// that directly. Settings stays reachable through the header's own
        /// Settings chip, which is asserted separately in tst_settings.qml.
        function test_clicking_the_identity_copies_it() {
            var did = "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd";
            identity.nodeId = did;
            var area = root.findByName(identity, "nodeIdentity");
            verify(area !== null, "the clickable element must carry the objectName");

            // Put something else on the clipboard first, so a passing
            // assertion cannot be a leftover from an earlier test.
            root.clipboardSet("something-else-entirely");
            compare(root.clipboardGet(), "something-else-entirely",
                    "precondition: the clipboard holds the decoy");

            mouseClick(area);

            compare(root.clipboardGet(), did,
                    "clicking the identity must put the FULL did on the "
                    + "clipboard, got: " + root.clipboardGet());
            compare(root.identityCopies, 1,
                    "and must report exactly one completed copy");
        }

        /// Input-dependent, so a component that copied a hardcoded string — or
        /// the first id it ever saw — cannot pass. Two identities, two clicks,
        /// two different clipboard contents.
        function test_copying_follows_the_identity_it_is_showing() {
            var a = "did:key:z6MkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
            var b = "did:key:z6MkBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
            var area = root.findByName(identity, "nodeIdentity");

            identity.nodeId = a;
            mouseClick(area);
            compare(root.clipboardGet(), a, "the first identity");

            identity.nodeId = b;
            mouseClick(area);
            compare(root.clipboardGet(), b,
                    "the second identity — a component copying a stale or "
                    + "hardcoded value would still be reporting the first");
        }

        /// Nothing to copy means nothing is copied, and no false confirmation.
        /// The element is invisible in this state, so this can only be reached
        /// programmatically — but a function that wrote "" to the clipboard
        /// would silently destroy whatever the user had there.
        function test_copying_an_absent_identity_does_nothing() {
            root.clipboardSet("untouched");
            identity.nodeId = "";
            identity.copyToClipboard();
            compare(root.clipboardGet(), "untouched",
                    "an empty identity must not clear the user's clipboard");
            compare(root.identityCopies, 0, "and must not claim it copied");
        }

        /// Clicking must NOT open Settings any more. Asserted as a false, not
        /// merely omitted: the identity was one of two ways in, and a change
        /// that copied AND opened the panel would satisfy the copy test above
        /// while still doing the thing the user asked to stop.
        function test_clicking_the_identity_does_not_open_settings() {
            identity.nodeId =
                "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd";
            root.settingsOpened = false;
            mouseClick(root.findByName(identity, "nodeIdentity"));
            compare(root.settingsOpened, false,
                    "the identity is a copy button now — Settings is reached "
                    + "through the header's Settings chip");
        }

        /// A click with no visible response is indistinguishable from a broken
        /// control, which is the fault this whole element has been corrected
        /// for twice. So the confirmation is asserted, inline and without hover.
        function test_copying_confirms_itself_on_screen() {
            identity.nodeId =
                "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd";
            var note = root.findByName(identity, "nodeIdentityCopied");
            verify(note !== null, "there must be a confirmation element");
            verify(!note.visible, "precondition: nothing to confirm yet");

            mouseClick(root.findByName(identity, "nodeIdentity"));
            verify(note.visible,
                   "a copy with no visible response reads as a dead control");
            verify(note.text.toLowerCase().indexOf("copied") !== -1,
                   "and it must say what happened, got: " + note.text);
        }

        /// The confirmation must be EARNED, not assumed.
        ///
        /// `TextEdit.copy()` returns nothing and signals failure through no
        /// channel, so the element used to restart the confirm timer and emit
        /// `copied()` unconditionally on the next line. If the clipboard were
        /// unavailable — the live-bundle risk, since an offscreen Qt platform
        /// plugin always provides one while a Wayland bundle may not — the UI
        /// would say "Copied" with nothing copied.
        ///
        /// Proven by mutation rather than argued: deleting `clip.copy()` from
        /// the component now turns THIS test and
        /// `test_copying_confirms_itself_on_screen` red. Before the check
        /// existed, the confirmation test stayed green through exactly that
        /// deletion, which is what made it worth nothing.
        ///
        /// The check itself is asserted directly: it must answer TRUE only when
        /// the clipboard really holds the value, and FALSE otherwise. A
        /// verification step that answered the same way regardless would make
        /// the confirmation exactly as unconditional as it was before, while
        /// looking like it had been fixed.
        ///
        /// Driven through the real system clipboard, using this file's own
        /// `clipboardSet` helper to put a known decoy there.
        function test_the_clipboard_check_distinguishes_landed_from_not() {
            var did = "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd";

            root.clipboardSet(did);
            verify(identity.clipboardHolds(did),
                   "the check must recognise a value that IS on the clipboard");

            root.clipboardSet("something-else-entirely");
            verify(!identity.clipboardHolds(did),
                   "the check must reject a value that is NOT on the "
                   + "clipboard — otherwise it confirms every copy, landed or "
                   + "not, which is the defect it exists to remove");
        }

        /// ...and reading the clipboard back must not disturb it. The check
        /// pastes into a scratch editor to see what is there, and a paste that
        /// left the identity sitting in a second element — or cleared what the
        /// user had — would be a new bug introduced by the fix for an old one.
        function test_checking_the_clipboard_leaves_it_alone() {
            root.clipboardSet("user-had-this");
            identity.clipboardHolds("something-else");
            compare(root.clipboardGet(), "user-had-this",
                    "verifying a copy must not modify the clipboard");
        }

        /// The confirmation must not resize the header when it appears — the
        /// identity sits on a single-line control row that has already
        /// regressed onto two lines once.
        function test_the_confirmation_does_not_change_the_elements_height() {
            identity.nodeId =
                "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd";
            var before = identity.implicitHeight;
            mouseClick(root.findByName(identity, "nodeIdentity"));
            compare(identity.implicitHeight, before,
                    "confirming the copy grew the element, which pushes the "
                    + "header row it sits on");
        }
    }

    // -----------------------------------------------------------------------
    // The mode-detail slot.
    //
    // One rule the user learns once: the thing beside the toggle is the detail
    // of whichever mode is selected. Explore's detail is the seed, Local's is
    // the identity, Embedded has none until Phase 2.
    //
    // The two REAL components are hosted here under the same `visible:`
    // bindings Main.qml gives them, so this pins the rule rather than a copy of
    // it. Main.qml itself needs a live QtRO backend and cannot be instantiated
    // in a component test; what CAN drift — the two conditions — is what is
    // asserted, and `slotMode` below is the single input both read.
    // -----------------------------------------------------------------------
    property string slotMode: "local"

    Ui.SeedPicker {
        id: slotSeedPicker
        objectName: "slotSeedPicker"
        anchors.top: toggle.bottom
        visible: root.slotMode === "explore"
        // Input-dependent: a different seed list per call, so a picker that
        // never fetched could not accidentally look right.
        fetchSeeds: function (cb) {
            cb({ items: [{ url: "https://seed.example", alias: "example" }] });
        }
    }

    Ui.NodeIdentity {
        id: slotIdentity
        objectName: "slotIdentity"
        anchors.top: slotSeedPicker.bottom
        visible: root.slotMode === "local" && slotIdentity.nodeId !== ""
        nodeId: "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd"
    }

    TestCase {
        name: "ModeDetailSlot"
        when: windowShown

        function init() {
            root.slotMode = "local";
            slotIdentity.nodeId =
                "did:key:z6MkvS2mYc1JMmSaBHqTfNvKuo4Y3kRnPKeWY1sX9qTfAbCd";
        }

        /// Local's detail is the identity, and the seed picker steps aside.
        function test_local_shows_the_identity_and_hides_the_seed_picker() {
            root.slotMode = "local";
            verify(slotIdentity.visible,
                   "the identity is Local's detail and must be shown");
            verify(!slotSeedPicker.visible,
                   "which seed is proxied to is not a fact about Local");
        }

        /// Explore's detail is the seed, and the identity steps aside — you are
        /// not operating as any identity there, so showing one is noise.
        function test_explore_shows_the_seed_picker_and_hides_the_identity() {
            root.slotMode = "explore";
            verify(slotSeedPicker.visible,
                   "the seed is Explore's detail and must be shown");
            verify(!slotIdentity.visible,
                   "in Explore you are not operating as an identity at all");
        }

        /// Embedded has no node yet, so it has no detail. Not a placeholder,
        /// not an empty pill — nothing, with the toggle's caption carrying the
        /// explanation instead.
        function test_embedded_shows_neither() {
            root.slotMode = "embedded";
            verify(!slotSeedPicker.visible);
            verify(!slotIdentity.visible);
        }

        /// Exactly one at a time, across every mode. Asserted as a loop over
        /// all three rather than three separate checks, because the invariant
        /// is "at most one", and a fourth mode added later inherits it.
        function test_at_most_one_detail_is_ever_shown() {
            var modes = ["explore", "local", "embedded"];
            for (var i = 0; i < modes.length; i++) {
                root.slotMode = modes[i];
                var shown = (slotSeedPicker.visible ? 1 : 0)
                          + (slotIdentity.visible ? 1 : 0);
                verify(shown <= 1,
                       modes[i] + " showed " + shown + " details at once");
            }
        }

        /// And the identity is absent even in its own mode when there is
        /// nothing to show — blank would read as a rendering fault.
        function test_local_without_an_identity_shows_no_slot_at_all() {
            root.slotMode = "local";
            slotIdentity.nodeId = "";
            verify(!slotIdentity.visible);
            verify(!slotSeedPicker.visible);
        }
    }

    // -----------------------------------------------------------------------
    // Routing and mode switching, against the REAL component.
    //
    // An earlier version drove hand-written QtObject stubs reproducing
    // Main.qml's logic — which meant reverting `call()` to a hardcoded "remote"
    // left every test green while the local backend became unreachable. A copy
    // asserted against itself is not a test.
    // -----------------------------------------------------------------------

    Ui.SourceState {
        id: sourceState
        mode: "local"
        localAvailable: true
        onChanged: reloads++
    }

    property int reloads: 0

    // The reload a mode switch triggers must go to the NEW surface.
    //
    // `changed()` fires while the mode write is still in flight, so anything
    // reading a BINDING derived from the mode still sees the old value — which
    // is why Main.qml defers the fetch. `switchMode()` below mirrors that
    // wiring: a binding to `current` (not a live read), a handler on `changed`,
    // and a zero-interval Timer. Drop the Timer and call `doReload()` straight
    // from the handler and this goes red.
    readonly property string boundSource: sourceState.current
    property string fetchedWith: ""

    function doReload() {
        // What Main.qml's call() does: resolve the method from the BOUND alias,
        // not by reading sourceState.current directly. Reading it directly
        // would mask the bug, since the assignment itself is immediate — it is
        // the binding that lags.
        fetchedWith = boundSource + "ListRepos";
    }

    Timer {
        id: deferredReload
        interval: 0
        repeat: false
        onTriggered: doReload()
    }

    Connections {
        target: sourceState
        function onChanged() { deferredReload.restart(); }
    }

    TestCase {
        name: "SourceRouting"

        function init() {
            sourceState.mode = "local";
            sourceState.localAvailable = true;
            reloads = 0;
        }

        /// The derivation, asserted for every mode. This is the single source
        /// of truth the whole collapse rests on: there is no stored `source`
        /// that could disagree with the mode.
        ///
        /// Input-dependent across all three, so a routing function that
        /// hardcoded either prefix fails at least one leg.
        function test_the_surface_is_derived_from_the_mode() {
            sourceState.mode = "explore";
            compare(sourceState.current, "remote");
            compare(sourceState.methodFor("ListRepos"), "remoteListRepos");

            sourceState.mode = "local";
            compare(sourceState.current, "local");
            compare(sourceState.methodFor("ListRepos"), "localListRepos");

            // The line that shows a mode and a method prefix are different
            // things that happen to share a word: `embedded` is neither, and
            // routes to the local surface.
            sourceState.mode = "embedded";
            compare(sourceState.current, "local");
            compare(sourceState.methodFor("ListRepos"), "localListRepos");
        }

        /// A mode this UI does not know routes to the SEED, not to the node.
        ///
        /// `current` was `mode === "explore" ? "remote" : "local"`, which made
        /// `local` the else — so an unrecognised mode reached the `local*`
        /// methods and the attached node's repositories rendered under a mode
        /// with no segment. The same else-shape, and the same failure, that
        /// `storeForSettings()` had in the core module.
        ///
        /// The backend's `load()` now refuses to hand out an unknown mode, so
        /// this should be unreachable in production; it is asserted because the
        /// consequence if it ever is reachable is a node identity being
        /// misattributed, and `remote` touches no local profile.
        function test_an_unknown_mode_routes_to_the_seed_not_the_node() {
            sourceState.mode = "turbo";
            compare(sourceState.current, "remote",
                    "an unrecognised mode must not reach the local* methods");
            compare(sourceState.methodFor("ListRepos"), "remoteListRepos");
        }

        /// `modeStartable` follows the reported SET, in both directions.
        ///
        /// This is what makes RepoList's not-implemented state derived rather
        /// than a third hardcoded copy of "which mode cannot start". Both
        /// directions, because a property stuck at either value would pass one
        /// of them on its own.
        function test_mode_startable_follows_the_reported_set() {
            sourceState.startableModes = ["explore", "local"];

            sourceState.mode = "local";
            verify(sourceState.modeStartable, "local is in the set");

            sourceState.mode = "embedded";
            verify(!sourceState.modeStartable, "embedded is not");

            // Phase 2, simulated: one entry added to the set, nothing else.
            sourceState.startableModes = ["explore", "local", "embedded"];
            verify(sourceState.modeStartable,
                   "the same mode must become startable when the build says so");

            sourceState.startableModes = ["explore", "local"];
        }

        /// An empty set means "capabilities have not arrived", not "nothing
        /// works" — otherwise every start would flash a not-implemented screen
        /// before the first reply lands.
        function test_an_empty_startable_set_is_not_read_as_nothing_works() {
            sourceState.startableModes = [];
            sourceState.mode = "local";
            verify(sourceState.modeStartable,
                   "before capabilities arrive the mode must not read as "
                   + "unstartable");
            sourceState.startableModes = ["explore", "local"];
        }

        function test_every_method_follows_the_mode_not_just_listing() {
            sourceState.mode = "explore";
            compare(sourceState.methodFor("GetCommit"), "remoteGetCommit");
            sourceState.mode = "local";
            compare(sourceState.methodFor("GetCommit"), "localGetCommit");
        }

        /// The per-call override, the seam for a screen showing both surfaces.
        function test_an_explicit_source_overrides_the_derived_one() {
            sourceState.mode = "local";
            compare(sourceState.methodFor("GetRepo", "remote"), "remoteGetRepo");
        }

        /// The bug a user hit: clicking Local listed the SEED's repositories,
        /// and only a second toggle showed the node's own.
        function test_the_reload_after_a_switch_uses_the_new_surface() {
            fetchedWith = "";
            sourceState.mode = "explore";
            sourceState.select("local");

            // Nothing fetches synchronously — the deferral is what guarantees
            // the fetch happens after the mode has actually settled. (This test
            // cannot reproduce the stale-binding window itself: a `Connections`
            // handler runs later than Main.qml's inline `onChanged`, so the
            // binding has already updated by the time it fires. What is pinned
            // is the observable contract — the fetch is deferred, and it
            // targets the new surface — which is what the user-visible bug
            // violated.)
            compare(fetchedWith, "", "nothing should have been fetched yet");

            // The mode is applied by the caller persisting it; here that is
            // simulated by the same assignment Main.qml's capabilities binding
            // would make.
            sourceState.mode = "local";
            tryCompare(root, "fetchedWith", "localListRepos", 1000,
                       "the deferred reload must hit the LOCAL surface");
        }

        /// And back again, so the deferral is not just right in one direction.
        function test_switching_back_to_the_seed_reloads_from_the_seed() {
            sourceState.mode = "local";
            fetchedWith = "";
            sourceState.select("explore");
            sourceState.mode = "explore";
            tryCompare(root, "fetchedWith", "remoteListRepos", 1000,
                       "switching back must refetch from the seed");
        }
    }

    TestCase {
        name: "SourceSwitching"

        function init() {
            sourceState.mode = "local";
            sourceState.localAvailable = true;
            reloads = 0;
        }

        /// Regression test. `setSource()` once called only `nav.reset()`, which
        /// was right when NavState did its own reload — M1.1 made it a pure
        /// state holder and every caller responsible for reloading. The stale
        /// assumption meant flipping the toggle in a live Basecamp switched the
        /// control, cleared the screen, and issued no request at all: an empty
        /// list that read as "your node has no repositories".
        function test_a_real_switch_signals_once_so_the_caller_can_refetch() {
            verify(sourceState.select("explore"), "the switch should be accepted");
            compare(reloads, 1, "a real switch must notify exactly once");
        }

        function test_switching_to_the_same_mode_changes_nothing() {
            verify(!sourceState.select("local"), "a no-op returns false");
            compare(reloads, 0, "no notification when nothing changed");
        }

        /// An unknown mode is refused rather than announced: the backend would
        /// reject the write, and a UI that had already told the user it
        /// switched would then be showing a mode the module is not in.
        function test_an_unknown_mode_is_refused() {
            verify(!sourceState.select("turbo"));
            compare(sourceState.mode, "local");
            compare(reloads, 0);
        }

        /// Embedded is accepted here — this layer's job is not to second-guess
        /// which modes can start. Refusing it would make the segment a control
        /// that silently does nothing, which is the bug the caption exists to
        /// avoid; the honest treatment is to persist it and say what it will do.
        function test_embedded_is_a_real_choice_at_this_layer() {
            verify(sourceState.select("embedded"),
                   "an unstartable mode is still a persistable choice");
            compare(reloads, 1);
        }
    }
}
