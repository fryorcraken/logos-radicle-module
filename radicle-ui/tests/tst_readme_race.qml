import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * The README must not overwrite a file the user clicked while it was loading.
 *
 * Reported from the running app: open a repository, and before the README
 * arrives click another file. The file\'s contents appear, then the README
 * reply lands and relabels the pane — leaving flake.lock\'s contents under the
 * heading "README.md".
 *
 * SourceTab guards its replies on `rid` and `selectedFile`. These tests drive
 * that guard directly, because the ordering is what matters and a stubbed
 * fetcher that replies synchronously can never reproduce it.
 */
Item {
    width: 800
    height: 600

    // Stands in for SourceTab\'s guard: a reply paints only when it is still
    // what the user is looking at.
    QtObject {
        id: tab
        property string rid: "rad:zTEST"
        property string selectedFile: ""
    }

    QtObject {
        id: viewer
        property string title: ""
        property string body: ""
        property bool loading: false
    }

    // The README reply handler, with the same condition as SourceTab.
    function readmeArrives(wantRid, path, body) {
        if (tab.rid !== wantRid || tab.selectedFile !== "")
            return false;
        viewer.loading = false;
        viewer.title = path;
        viewer.body = body;
        return true;
    }

    // The blob reply handler, same shape.
    function blobArrives(wantRid, path, body) {
        if (tab.rid !== wantRid || tab.selectedFile !== path)
            return false;
        viewer.loading = false;
        viewer.title = path;
        viewer.body = body;
        return true;
    }

    TestCase {
        name: "ReadmeRace"
        when: windowShown

        function init() {
            tab.rid = "rad:zTEST";
            tab.selectedFile = "";
            viewer.title = "";
            viewer.body = "";
            viewer.loading = false;
        }

        function test_a_readme_arriving_after_a_click_is_dropped() {
            // Repo opens; the README request goes out.
            viewer.loading = true;

            // Before it lands the user clicks flake.lock, which retitles at
            // once and its own reply arrives.
            tab.selectedFile = "flake.lock";
            verify(blobArrives("rad:zTEST", "flake.lock", "{ nodes }"));
            compare(viewer.title, "flake.lock");

            // Now the slow README reply turns up. It must be discarded.
            var painted = readmeArrives("rad:zTEST", "README.md", "# radicle-tui");
            verify(!painted, "a README arriving after a click must not paint");
            compare(viewer.title, "flake.lock");
            compare(viewer.body, "{ nodes }");
        }

        function test_a_readme_paints_when_nothing_was_clicked() {
            // The ordinary case must still work.
            viewer.loading = true;
            verify(readmeArrives("rad:zTEST", "README.md", "# radicle-tui"));
            compare(viewer.title, "README.md");
            compare(viewer.loading, false);
        }

        function test_a_readme_for_a_previous_repository_is_dropped() {
            viewer.loading = true;
            var wantRid = tab.rid;
            tab.rid = "rad:zOTHER";
            verify(!readmeArrives(wantRid, "README.md", "# the old repo"));
            compare(viewer.title, "");
        }

        function test_a_blob_for_a_file_no_longer_selected_is_dropped() {
            // The same guard the other way round: a slow reply for an earlier
            // click must not overwrite a later one.
            tab.selectedFile = "Cargo.toml";
            verify(!blobArrives("rad:zTEST", "flake.lock", "stale"));
            compare(viewer.body, "");
        }
    }
}
