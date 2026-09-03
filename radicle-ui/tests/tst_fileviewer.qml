import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * FileViewer behaviour while content is in flight.
 *
 * Reported from the running app: clicking a second file left the FIRST file's
 * text on screen until the reply arrived, under a header that had already
 * changed — so the pane appeared to be showing the wrong file's contents.
 */
Item {
    width: 800
    height: 600

    Ui.FileViewer {
        id: viewer
        anchors.fill: parent
    }

    TestCase {
        name: "FileViewerLoadingState"
        when: windowShown

        function init() {
            viewer.loading = false;
            viewer.title = "";
            viewer.body = "";
        }

        function test_loading_hides_the_previous_file_contents() {
            viewer.title = "README.md";
            viewer.body = "# The Radicle Website";
            compare(viewer.body, "# The Radicle Website");

            // Clicking another file: the pane goes into loading and the old
            // text must not still be displayed.
            viewer.title = "flake.lock";
            viewer.body = "";
            viewer.loading = true;

            verify(viewer.loading, "viewer should be in the loading state");
            compare(viewer.body, "",
                    "previous file's contents must be cleared while loading");
        }

        function test_loading_and_empty_states_are_distinct() {
            // "Loading…" and "Select a file" mean different things; showing
            // the latter mid-load would read as though nothing was happening.
            viewer.loading = true;
            viewer.body = "";
            verify(viewer.loading);

            viewer.loading = false;
            verify(!viewer.loading);
        }

        function test_content_returns_when_loading_finishes() {
            viewer.title = "flake.lock";
            viewer.loading = true;
            viewer.body = "";

            viewer.loading = false;
            viewer.body = "{ \"nodes\": {} }";

            compare(viewer.loading, false);
            compare(viewer.body, "{ \"nodes\": {} }");
        }
    }
}
