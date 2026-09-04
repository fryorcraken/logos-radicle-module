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
