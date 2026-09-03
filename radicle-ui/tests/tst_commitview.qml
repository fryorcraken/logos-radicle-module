import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * CommitView: one commit's message, author, stats and diff.
 *
 * Had no test file at all before this — flagged by the pre-release coverage
 * review alongside nav.busy/nav.error and PatchesTab's threadRow. Covers the
 * GetCommit load, the same wantSha/wantRid staleness guard every other
 * loader in this codebase uses, and the computed commit/files/stats
 * properties the diff renderer reads.
 *
 * Writing this test file found two real bugs neither present before, live in
 * the tree unfixed until now:
 *   - the whole view rendered as a blank pane (see
 *     test_the_view_actually_paints_something — CommitView.qml's own
 *     `commitData` property used to be named `data`, which shadows Item's
 *     default property of the same name);
 *   - the back button was unreachable for any commit with an empty diff
 *     (see test_clicking_back_is_reachable_even_for_an_empty_diff).
 * Both are fixed in CommitView.qml in the same change as this file.
 */
Item {
    width: 900
    height: 600

    property var calls: []
    property string source: "remote"

    function call(method, args, onOk, onFail) {
        calls.push(method);
        if (method === "GetCommit") {
            var sha = args[1];
            if (sha === "deadbeef") {
                onOk({
                    commit: {
                        summary: "Fix the thing",
                        author: { name: "Someone" },
                        committer: { time: 1700000000 }
                    },
                    diff: {
                        stats: { insertions: 3, deletions: 1 },
                        files: [
                            {
                                path: "src/a.txt",
                                status: "modified",
                                diff: {
                                    hunks: [
                                        {
                                            header: "@@ -1,2 +1,3 @@",
                                            lines: [
                                                { type: "context", line: "one", lineNoOld: 1, lineNoNew: 1 },
                                                { type: "addition", line: "two", lineNoNew: 2 },
                                                { type: "deletion", line: "old", lineNoOld: 2 }
                                            ]
                                        }
                                    ]
                                }
                            }
                        ]
                    }
                });
            } else if (sha === "nostat") {
                // A commit with no diff.stats at all — the seed omits it
                // sometimes, and the header must not crash reading it.
                onOk({
                    commit: { summary: "No stats here", author: { name: "Someone" } },
                    diff: { files: [] }
                });
            } else {
                onFail();
            }
        } else {
            onOk({ items: [], hasMore: false });
        }
    }

    Ui.CommitView {
        id: view
        anchors.fill: parent
        app: parent
        rid: "rad:zTEST"
    }

    TestCase {
        name: "CommitView"
        when: windowShown

        function init() {
            calls = [];
            view.sha = "";
        }

        function test_setting_sha_fetches_the_commit() {
            view.sha = "deadbeef";
            compare(calls.indexOf("GetCommit") >= 0, true,
                    "GetCommit was not called; calls=" + calls.join(","));
            compare(view.commit.summary, "Fix the thing");
        }

        function test_stats_are_exposed_for_the_header() {
            view.sha = "deadbeef";
            verify(view.stats !== null);
            compare(view.stats.insertions, 3);
            compare(view.stats.deletions, 1);
        }

        function test_a_commit_with_no_stats_does_not_crash() {
            view.sha = "nostat";
            compare(view.stats, null);
            compare(view.commit.summary, "No stats here");
        }

        function test_files_are_exposed_for_the_diff_renderer() {
            view.sha = "deadbeef";
            compare(view.files.length, 1);
            compare(view.files[0].path, "src/a.txt");
            compare(view.files[0].diff.hunks[0].lines.length, 3);
        }

        function test_changing_sha_clears_the_previous_commit_immediately() {
            // Same principle as every other loader here: switching away must
            // not leave the old data on screen while the new one is in flight.
            view.sha = "deadbeef";
            verify(view.commit !== null);
            view.sha = "";
            compare(view.commitData, null);
            compare(view.commit, null);
        }

        function test_the_view_actually_paints_something() {
            // Regression: CommitView's own root Item declared a property
            // named `data`. Item's default property is literally called
            // `data` — every unparented child item declared in a .qml file
            // (the ColumnLayout here, and LoadingState) is assigned into it
            // at construction time to become a real scene-graph child.
            // Shadowing that name with a plain `var` property silently broke
            // the mechanism: no warning anywhere, `children.length` reported
            // 0, and the whole view rendered as a blank rectangle — the
            // header, the diff, everything. Caught here by rendering the
            // item and checking the grabbed image is not a single flat
            // colour; qmllint and check-qml-syntax.sh do not catch this
            // class of bug at all.
            view.sha = "deadbeef";
            wait(50);
            var img = grabImage(view);
            var topLeft = img.pixel(0, 0);
            var isBlank = true;
            for (var x = 0; x < img.width && isBlank; x += 4) {
                for (var y = 0; y < img.height && isBlank; y += 4) {
                    if (img.pixel(x, y) !== topLeft) isBlank = false;
                }
            }
            verify(!isBlank, "CommitView rendered as a single flat colour — nothing painted");
        }

        function test_clicking_back_is_reachable_even_for_an_empty_diff() {
            // A second, narrower regression on the same overlay: even once
            // the view renders (see above), LoadingState's overlay was keyed
            // on view.files.length, not on whether a commit loaded at all —
            // unlike ThreadView, which keys its equivalent overlay on
            // view.item so it steps aside as soon as anything loads. A
            // commit with an empty diff (a merge commit, for instance) left
            // count === 0 forever, so the full-view overlay never stepped
            // aside and the back button — declared UNDER it in the same
            // view — became physically unreachable by a real click. There
            // was no way back out of such a commit's detail view except
            // restarting the app.
            view.sha = "nostat"; // GetCommit reply has diff.files: []
            wait(50);
            var backButton = findByName(view, "commitBackButton");
            verify(backButton !== null, "no commitBackButton delegate was rendered");

            var seen = false;
            function grab() { seen = true; }
            view.back.connect(grab);
            mouseClick(backButton, backButton.width / 2, backButton.height / 2);
            view.back.disconnect(grab);

            verify(seen, "clicking the back button must emit back()");
        }

        function test_a_failed_fetch_still_marks_loadedOnce() {
            view.sha = "missing-sha";
            compare(view.loading, false);
            compare(view.loadedOnce, true);
            compare(view.commit, null);
        }
    }

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
}
