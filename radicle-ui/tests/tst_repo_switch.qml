import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Switching repository must not leave the previous repository's data on
 * screen.
 *
 * Reported twice from the running app, one level apart:
 *   - clicking a file left the previous FILE's text under the new filename;
 *   - opening a repo left the previous REPO's tree and README under the new
 *     repo's header.
 *
 * Both are the same mistake — fetching new data without first clearing the
 * old — so these tests pin the clearing, which is the part that is easy to
 * drop when adding a screen.
 */
Item {
    width: 900
    height: 600

    Ui.CommitsTab { id: commits; anchors.fill: parent; visible: false }
    Ui.IssuesTab  { id: issues;  anchors.fill: parent; visible: false }
    Ui.PatchesTab { id: patches; anchors.fill: parent; visible: false }

    TestCase {
        name: "TabsClearOnRepoChange"
        when: windowShown

        function test_commits_expose_a_reset_that_empties_the_list() {
            verify(typeof commits.reset === "function",
                   "CommitsTab needs reset() so RepoView can clear it");
            commits.reset();
            compare(commits.count, 0);
            compare(commits.hasMore, false);
            compare(commits.loading, false);
            compare(commits.loadedOnce, false);
        }

        function test_issues_reset_clears_paging_state_too() {
            issues.page_ = 3;
            issues.hasMore = true;
            issues.reset();
            // Leaving page_ behind would fetch page 3 of the NEW repo first.
            compare(issues.page_, 0);
            compare(issues.hasMore, false);
        }

        function test_patches_reset_clears_paging_state_too() {
            patches.page_ = 2;
            patches.hasMore = true;
            patches.reset();
            compare(patches.page_, 0);
            compare(patches.hasMore, false);
        }

        function test_status_filter_survives_a_reset() {
            // The filter is a user choice about how to view any repo, not
            // data belonging to one — it should not be cleared.
            issues.status = "closed";
            issues.reset();
            compare(issues.status, "closed");
        }
    }
}
