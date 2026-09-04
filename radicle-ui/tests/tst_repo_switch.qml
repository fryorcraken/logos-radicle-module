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

    // A fake backend that replies synchronously with an empty tree, so
    // syncAll() completes in the same tick it is called.
    QtObject {
        id: fakeApp
        function call(method, args, onOk, onFail) {
            onOk({ entries: [] });
        }
    }

    Ui.SourceTab {
        id: source
        anchors.fill: parent
        visible: false
        app: fakeApp
        rid: "rad:zTEST"
        branch: "main"
    }

    // A fake backend with a small, unbalanced tree — one directory (a/) that
    // is itself discovered late, after a file at the root has already
    // completed. That ordering is what exposes a denominator that grows
    // after the numerator has already advanced. Every reply is synchronous,
    // so recording deepSource.syncProgress right after each onOk() call
    // gives a deterministic, ordered snapshot of progress after every step
    // SourceTab takes in response to that reply.
    QtObject {
        id: deepApp
        property var progressAfterEachReply: []
        function call(method, args, onOk, onFail) {
            // syncAll() also makes one ListBranches call up front (to record
            // the branch head it is syncing to). Answer it out of band,
            // without touching progressAfterEachReply — that array is about
            // GetTree replies specifically, and dirPath below would
            // misinterpret ListBranches' single-rid argument list anyway.
            if (method === "ListBranches") {
                onOk({ items: [{ name: "main", head: "" }], default: "main" });
                return;
            }
            var dirPath = args[2];
            if (dirPath === "") {
                onOk({ entries: [
                    { kind: "blob", path: "root.txt", name: "root.txt" },
                    { kind: "tree", path: "a", name: "a" }
                ] });
            } else if (dirPath === "a") {
                onOk({ entries: [
                    { kind: "blob", path: "a/1.txt", name: "1.txt" },
                    { kind: "blob", path: "a/2.txt", name: "2.txt" },
                    { kind: "blob", path: "a/3.txt", name: "3.txt" }
                ] });
            } else {
                onOk({ entries: [] });
            }
            progressAfterEachReply.push(deepSource.syncProgress);
        }
    }

    Ui.SourceTab {
        id: deepSource
        anchors.fill: parent
        visible: false
        app: deepApp
        rid: "rad:zTEST"
        branch: "main"
    }

    // A fake backend that holds its reply until the test delivers it, so a
    // fetch can be started, the repo switched, and only then the original
    // (now stale) reply let through.
    QtObject {
        id: deferredApp
        property var pending: null
        function call(method, args, onOk, onFail) {
            pending = { args: args, onOk: onOk, onFail: onFail };
        }
        function deliver(items, hasMore) {
            pending.onOk({ items: items, hasMore: !!hasMore });
            pending = null;
        }
    }

    Ui.CommitsTab {
        id: staleCommits
        anchors.fill: parent
        visible: false
        app: deferredApp
        rid: "rad:zOLD"
        branch: "main"
    }

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

        function test_source_starts_unsynced_so_the_button_reads_download_all() {
            source.reset();
            compare(source.syncedOnce, false);
        }

        function test_a_completed_sync_flips_syncedOnce() {
            source.reset();
            source.syncAll();
            compare(source.syncing, false, "the fake backend replies synchronously");
            compare(source.syncedOnce, true);
        }

        function test_switching_repository_reverts_syncedOnce() {
            // A repo that was synced before must not lend its "already
            // synced" state to a different repo opened afterwards.
            source.reset();
            source.syncAll();
            compare(source.syncedOnce, true);
            source.reset();
            compare(source.syncedOnce, false);
        }

        function test_sync_progress_never_goes_backwards() {
            // syncQueued grows as the tree is discovered, so a naive
            // syncDone/syncQueued ratio can go UP after a small directory's
            // reply, then DOWN once that directory's own children are
            // discovered and inflate the denominator. Reported live: the
            // Download All button visibly regressed from ~90% back to ~50%.
            deepSource.reset();
            deepApp.progressAfterEachReply = [];
            deepSource.syncAll();
            var seen = deepApp.progressAfterEachReply;

            verify(seen.length > 1, "expected more than one reply");
            for (var i = 1; i < seen.length; i++) {
                verify(seen[i] >= seen[i - 1],
                       "progress regressed: " + seen[i - 1] + " -> " + seen[i]);
            }
            compare(seen[seen.length - 1], 1, "a finished sync must reach 100%");
        }

        function test_a_stale_commits_reply_is_dropped_after_switching_repos() {
            // Unlike IssuesTab/PatchesTab, CommitsTab.fetch() had no
            // wantRid guard: a reply arriving after the user has already
            // moved to a different repository would still overwrite the
            // list and flip loading/hasMore for the wrong repo.
            staleCommits.rid = "rad:zOLD";
            staleCommits.load();
            verify(deferredApp.pending !== null, "expected a request to be in flight");

            staleCommits.rid = "rad:zNEW";
            staleCommits.reset();

            deferredApp.deliver([{ id: "deadbeef", summary: "old repo commit" }], true);

            compare(staleCommits.count, 0,
                    "a reply for the abandoned repo must not populate the new repo's list");
            compare(staleCommits.loading, false);
            compare(staleCommits.hasMore, false);
        }
    }
}
