import QtQuick
import QtQuick.Layouts
import QtTest
import "../src/qml" as Ui
import "../src/qml/Theme.js" as Theme

/*
 * Layout tests.
 *
 * These exist because of a bug a standalone harness cannot reproduce: the
 * view rendered correctly when given an explicit size, but inside Basecamp
 * every repository row collapsed onto a single overlapping line.
 *
 * Basecamp puts a ui_qml view inside a layout, so the view is sized by its
 * parent rather than by its own implicitWidth/implicitHeight. A root that
 * does not declare Layout.fillWidth / Layout.fillHeight is handed zero size,
 * every delegate draws at y=0, and the list becomes one illegible line.
 *
 * So the container here is a real layout with a real size, and the assertions
 * are about geometry rather than about state.
 */
Item {
    width: 1000
    height: 700

    // Reproduces how Main.qml hosts its screens: a StackLayout. This is the
    // shape that actually broke — a StackLayout gives a child with no implicit
    // size and no Layout.fill* exactly 0x0. Note the fill flags are NOT set
    // here: they must come from the component's own root, which is the thing
    // under test.
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: 0

            Ui.RepoList {
                id: repoList
                objectName: "repoListUnderTest"
            }
        }
    }


    // A whole RepoView, hosted the way Main.qml hosts it, so the tab bar and
    // the tab bodies below it can be measured against each other. The fake
    // backend only has to answer enough for the view to lay itself out.
    function call(method, args, onOk, onFail) {
        if (method === "ListBranches")
            onOk({ items: [{ name: "main", head: "aaa" }], default: "main" });
        else if (method === "GetTree")
            onOk({ entries: [{ name: "src", kind: "tree", path: "src" }] });
        else if (method === "GetReadme")
            onOk({ path: "README.md", content: "hi" });
        else
            onOk({ items: [], hasMore: false });
    }
    property string source: "remote"
    property bool canWrite: false
    property string writeUnavailableReason: ""

    ColumnLayout {
        id: repoViewHost
        width: 1000
        height: 700
        spacing: 0

        Ui.RepoView {
            id: repoPage
            Layout.fillWidth: true
            Layout.fillHeight: true
            app: repoViewHost.parent
            active: true
        }
    }

    // The header's source toggle, hosted the way Main.qml hosts it: inside a
    // Rectangle whose height is the chrome budget. The bug this guards against
    // is the one the old tooltip had — an explanation rendered outside the bar
    // that contains it, clipped to an unreadable sliver, with `z: 100` doing
    // nothing because z orders siblings within one parent and cannot lift an
    // item over a different parent's later sibling.
    //
    // Asserted on geometry, not by clicking: a click test structurally cannot
    // see a clipped overlay. That is what CommitView's back button taught here.
    Rectangle {
        id: headerHost
        width: 1000
        // Budgeted from `reservedHeight`, exactly as Main.qml's top bar is.
        //
        // NOT `implicitHeight`: that is the height the control DRAWS, which
        // varies by mode because the caption is conditional, and budgeting a
        // bar from it is what makes the bar jump. `reservedHeight` is the
        // caption's budget whether or not it is on screen. The split is the
        // subject of the two tests below — see SourceToggle.qml.
        height: Math.max(Theme.barHeight, captionToggle.reservedHeight + Theme.gap)

        Ui.SourceToggle {
            id: captionToggle
            objectName: "captionToggle"
            anchors.left: parent.left
            // Pinned to the top of the control line rather than centred, which
            // is also how Main.qml places it. Centring an item that grows by
            // its caption pushes its own segment strip UPWARDS, off the line
            // the title and the node identity sit on — the misalignment the
            // user reported as "node id is not on the same line anymore".
            anchors.top: parent.top
            anchors.topMargin: (Theme.barHeight - Theme.rowHeightSm) / 2
            // `embedded`, because that is now the only mode that HAS a caption
            // — the paragraph was unconditional and the user asked for it gone
            // from the modes it is not about. The clipping guarantee still has
            // to hold wherever the caption does appear, so the fixture is the
            // state where it appears.
            //
            // The default `local` state is not left uncovered: the test below
            // switches to it and asserts the header does not jump, which is the
            // NEW hazard a conditional caption introduces.
            mode: "embedded"
            startableModes: ["explore", "local"]
            localAvailable: true
        }
    }

    // A list with rows in it, to check the rows stack rather than overlap.
    ColumnLayout {
        id: sizedHost
        width: 900
        height: 400
        ListView {
            id: probe
            objectName: "probeList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: 5
            delegate: Rectangle {
                width: probe.width
                height: Theme.rowHeight
                color: "transparent"
            }
        }
    }

    TestCase {
        name: "ViewFillsItsContainer"
        when: windowShown

        function test_repo_list_fills_its_stacklayout() {
            // The regression: 0x0 here means every row lands on the same line,
            // which is exactly what Basecamp rendered.
            verify(repoList.height > 100,
                   "RepoList height was " + repoList.height
                   + "; its root must declare Layout.fillHeight");
            verify(repoList.width > 100,
                   "RepoList width was " + repoList.width
                   + "; its root must declare Layout.fillWidth");
        }


        // The tab bar is fixed-height chrome; the tab bodies below it get
        // everything else. Wrapping SectionTabs in a RowLayout to sit a button
        // beside it broke that: the RowLayout had a Layout.preferredHeight but
        // no Layout.maximumHeight, and a child asking for Layout.fillHeight
        // makes a RowLayout's own maximum unbounded — so the ColumnLayout grew
        // the strip to 625px and left the StackLayout below it 15px.
        //
        // Nothing looked broken from the outside: the tabs still rendered, the
        // tree still loaded, treeCount was still > 0. Only the rows had
        // nowhere to be, so clicking one reached nothing. That is what the
        // source.yaml spec saw as "the click did neither of the two things".
        function test_the_tab_strip_does_not_eat_the_tab_bodies() {
            var src = repoPage.sourceTabItem;
            verify(src !== null, "RepoView must expose its SourceTab");
            verify(src.height > repoViewHost.height / 2,
                   "the tab body got " + src.height + "px of "
                   + repoViewHost.height + "; the tab strip above it is "
                   + "taking space that belongs to the tab contents");
        }

        // The same failure stated against a chrome budget rather than against
        // one suspect element. This is the broader of the two: it goes red if
        // EITHER the header or the tab strip starts stretching, where the test
        // above only names the tab strip. Both are kept because the narrow one
        // says which element to look at and this one says the invariant.
        //
        // sourceTabItem IS a child of the content StackLayout, so its height
        // is that area's height — no new property, and no second copy of the
        // layout's own arithmetic.
        //
        // From a parallel investigation that reached this diagnosis
        // independently; see the commit message.
        function test_repo_view_content_area_gets_the_leftover_height() {
            var content = repoPage.sourceTabItem.height;
            var chrome = Theme.headerHeight + Theme.tabHeight;
            verify(content > repoPage.height - chrome - 2,
                   "RepoView content area was " + content + "px of "
                   + repoPage.height + "; the chrome above it should take only "
                   + chrome + "px. Something in the chrome is stretching.");
        }

        // The header must not clip the toggle's caption. The previous design
        // put this text in an overlay anchored to `parent.bottom` inside a bar
        // pinned to Theme.barHeight, so it rendered outside its own container
        // and the user could not read it. A bar that yields to its caption is
        // the fix; this pins that it actually does.
        function test_the_header_does_not_clip_the_source_toggles_caption() {
            var note = findChild(captionToggle, "sourceToggleNote");
            verify(note !== null, "the caption must exist");
            verify(note.visible,
                   "the default state carries the Embedded caveat, so there IS "
                   + "something to place");
            verify(note.height > 0, "a zero-height caption is invisible");

            var bottom = note.mapToItem(headerHost, 0, note.height).y;
            verify(bottom <= headerHost.height + 1,
                   "the caption's bottom is at " + bottom + " inside a "
                   + headerHost.height + "px header — it is being clipped, "
                   + "which is the tooltip bug returning in a new shape");

            var top = note.mapToItem(headerHost, 0, 0).y;
            verify(top >= -1,
                   "the caption starts at " + top + ", above the header's top "
                   + "edge — also clipped");
        }

        // The caption is conditional now — visible only for Embedded — and a
        // header whose height follows a caption that comes and goes is a
        // header that JUMPS every time the user changes mode. The content
        // below it slides, and on the click that switched modes, which reads
        // as the UI lurching under the pointer.
        //
        // So the bar reserves the caption's space unconditionally: the same
        // pixels on every screen, which is the layout rule the whole file
        // states at the top. Asserted across all three modes rather than
        // between two, so a bar sized from "is this Embedded" would fail.
        //
        // Measured on `reservedHeight`, which is the property the bar is
        // budgeted from. It used to be `implicitHeight`, and that was the
        // defect rather than the fix: making one number serve both "how much
        // room must the bar keep" and "how big is this control" forced the
        // control to claim 72px while drawing 28px of content at the top of
        // it, so the header row centred it against its own empty half and the
        // node identity beside it dropped onto a second line. Two
        // requirements, two properties; this test owns the first and
        // test_the_control_is_the_height_of_what_it_draws below owns the
        // second. Neither alone is sufficient, and a fix that satisfied
        // either by abandoning the other would go red here.
        function test_the_header_does_not_jump_when_the_mode_changes() {
            var modes = ["explore", "local", "embedded"];
            var seen = [];
            for (var i = 0; i < modes.length; i++) {
                captionToggle.mode = modes[i];
                // Measured with NO settle, deliberately. The caption's own
                // history is a height that lagged its content by a layout
                // pass; if this needs a wait to be true, the geometry is being
                // settled over a frame rather than computed, and a user would
                // see the frame it was wrong in.
                seen.push(captionToggle.reservedHeight);
            }
            captionToggle.mode = "embedded";

            for (var j = 1; j < seen.length; j++) {
                compare(seen[j], seen[0],
                        "the toggle reserves " + seen[j] + "px in " + modes[j]
                        + " but " + seen[0] + "px in " + modes[0]
                        + " — the header will jump when the mode changes, and "
                        + "everything below it will slide");
            }
        }

        // The other half of that split, and the reason the reservation had to
        // move off `implicitHeight` rather than simply being deleted.
        //
        // The control must be the size of what it DRAWS. A header row centres
        // what it is given, so a control reporting 72px while rendering a 28px
        // segment strip at the top of that box sits 22px higher than the title
        // and the node identity next to it — which is precisely what the user
        // saw and reported.
        //
        // This test and the one above pull in opposite directions on purpose.
        // Re-merging the two numbers fails one of them whichever value is
        // chosen, which is what makes the pair a specification rather than a
        // pair of observations.
        function test_the_control_is_the_height_of_what_it_draws() {
            var modes = ["explore", "local"];
            for (var i = 0; i < modes.length; i++) {
                captionToggle.mode = modes[i];
                var note = findChild(captionToggle, "sourceToggleNote");
                verify(!note.visible,
                       "precondition: " + modes[i] + " draws no caption");
                compare(captionToggle.implicitHeight, Theme.rowHeightSm,
                        "in " + modes[i] + " the toggle draws only its "
                        + Theme.rowHeightSm + "px segment strip but reports "
                        + captionToggle.implicitHeight + "px — a row will "
                        + "centre it against that empty space and everything "
                        + "beside it will leave its line");
            }
            captionToggle.mode = "embedded";
        }

        // ...and the reserved space is real space, not zero. A bar that
        // "does not jump" because the caption never gets any room is the
        // clipping bug again, and the test above cannot tell the two apart.
        function test_the_reserved_caption_space_is_actually_there() {
            captionToggle.mode = "embedded";
            var note = findChild(captionToggle, "sourceToggleNote");
            verify(note.visible, "Embedded has a caption to place");
            verify(captionToggle.implicitHeight >= note.height,
                   "the toggle reports " + captionToggle.implicitHeight
                   + "px but its caption alone is " + note.height
                   + "px — the caption does not fit inside its own parent");
        }

        function test_rows_stack_instead_of_overlapping() {
            // Independent of the component under test: proves the assertion
            // above would actually catch overlap, by pinning that a list of
            // fixed-height rows is taller than one row.
            probe.forceLayout();
            compare(probe.contentHeight, 5 * Theme.rowHeight);
            verify(probe.contentHeight > Theme.rowHeight,
                   "rows are overlapping rather than stacking");
        }
    }

    TestCase {
        name: "ThemeFixedSizes"
        when: windowShown

        // The fixed chrome heights are what stop panels moving between
        // screens. If any of them goes to zero the layout silently collapses,
        // so pin that they are all real positive values.
        function test_chrome_heights_are_positive() {
            var sizes = {
                barHeight:    Theme.barHeight,
                headerHeight: Theme.headerHeight,
                tabHeight:    Theme.tabHeight,
                statusHeight: Theme.statusHeight,
                rowHeight:    Theme.rowHeight,
                rowHeightSm:  Theme.rowHeightSm,
                sidebarWidth: Theme.sidebarWidth
            };
            for (var key in sizes) {
                verify(sizes[key] > 0, key + " must be positive, was " + sizes[key]);
            }
        }

        function test_row_heights_leave_room_for_two_lines_of_text() {
            // A repo row shows a name and a description; too short and they
            // overlap the way the collapsed list did.
            verify(Theme.rowHeight >= 2 * Theme.fontLg,
                   "rowHeight " + Theme.rowHeight + " is too small for two lines");
        }
    }
}
