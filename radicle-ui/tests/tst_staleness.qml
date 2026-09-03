import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * SourceTab's re-sync staleness detection.
 *
 * checkForUpdate() is a lightweight poll (one ListBranches call — no tree,
 * no files) that compares the branch's current head against
 * lastSyncedCommit, the head captured when the last sync completed. It only
 * ever sets `updateAvailable`; nothing here disables or re-enables the sync
 * button — re-syncing is never wrong, just sometimes unnecessary, so
 * clickability must never depend on this.
 */
Item {
    // A fake backend that answers GetTree/GetBlob with an empty tree (so
    // syncAll() completes synchronously) and ListBranches from a script the
    // test can change between calls, so a poll can observe a head that has
    // moved since the sync that set lastSyncedCommit.
    QtObject {
        id: fakeApp
        property string branchesHead: "sha-at-sync-time"
        property int branchesCallCount: 0
        function call(method, args, onOk, onFail) {
            if (method === "ListBranches") {
                branchesCallCount++;
                onOk({ items: [{ name: "main", head: branchesHead }], default: "main" });
                return;
            }
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

    // A second fake backend whose ListBranches call can be held and
    // delivered on demand, so a poll can be issued, the repository or branch
    // switched, and only THEN have the original (now stale) reply let
    // through — the same technique tst_sync_epoch.qml uses for sync
    // requests. A synchronously-replying fake (like fakeApp above) can never
    // exercise checkForUpdate()'s guard: every request it starts is also
    // answered before pollEpoch/rid/branch can move on.
    //
    // deferBranches gates whether ListBranches itself is held: syncAll()'s
    // own ListBranches lookup (to record lastSyncedCommit) needs to answer
    // synchronously so a sync can actually complete and set up the
    // "already synced" state each test starts from — only the ListBranches
    // call made by the checkForUpdate() under test should be held.
    QtObject {
        id: deferredApp
        property bool deferBranches: false
        property var pendingBranches: null   // {onOk} while a ListBranches call is held
        function call(method, args, onOk, onFail) {
            if (method === "ListBranches") {
                if (deferBranches) {
                    pendingBranches = { onOk: onOk };
                    return;
                }
                onOk({ items: [{ name: "main", head: "sha-at-sync-time" }], default: "main" });
                return;
            }
            onOk({ entries: [] });   // GetTree/GetBlob during syncAll()
        }
        function deliverBranches(head) {
            var p = pendingBranches;
            pendingBranches = null;
            p.onOk({ items: [{ name: "main", head: head }], default: "main" });
        }
    }

    Ui.SourceTab {
        id: deferredSource
        anchors.fill: parent
        visible: false
        app: deferredApp
        rid: "rad:zTEST"
        branch: "main"
    }

    TestCase {
        name: "StalenessDetection"
        when: windowShown

        function init() {
            source.reset();
            fakeApp.branchesHead = "sha-at-sync-time";
            fakeApp.branchesCallCount = 0;
            deferredSource.reset();
            deferredSource.rid = "rad:zTEST";
            deferredSource.branch = "main";
            deferredApp.deferBranches = false;
            deferredApp.pendingBranches = null;
        }

        function test_a_completed_sync_records_the_branch_head() {
            source.syncAll();
            compare(source.lastSyncedCommit, "sha-at-sync-time");
        }

        function test_no_sync_yet_means_no_lastSyncedCommit() {
            compare(source.lastSyncedCommit, "");
            compare(source.updateAvailable, false);
        }

        function test_checkForUpdate_is_a_noop_before_any_sync() {
            // Nothing to compare against yet — must not crash, must not
            // claim an update is available out of nowhere.
            var before = fakeApp.branchesCallCount;
            source.checkForUpdate();
            compare(source.updateAvailable, false);
            compare(fakeApp.branchesCallCount, before,
                    "polling before a sync has ever completed should not even make a request");
        }

        function test_an_unchanged_head_reports_no_update() {
            source.syncAll();
            compare(source.lastSyncedCommit, "sha-at-sync-time");

            // Same head as sync time — nothing new.
            source.checkForUpdate();
            compare(source.updateAvailable, false);
        }

        function test_a_moved_head_flips_updateAvailable() {
            source.syncAll();
            compare(source.lastSyncedCommit, "sha-at-sync-time");

            // The remote moved on since the last sync.
            fakeApp.branchesHead = "sha-after-new-commits";
            source.checkForUpdate();
            compare(source.updateAvailable, true);
        }

        function test_resyncing_clears_updateAvailable_and_catches_up() {
            source.syncAll();
            fakeApp.branchesHead = "sha-after-new-commits";
            source.checkForUpdate();
            compare(source.updateAvailable, true);

            // Re-sync must always be clickable and must always work,
            // regardless of updateAvailable's value — and once it completes,
            // it has caught up: no update pending against the new head.
            source.syncAll();
            compare(source.updateAvailable, false, "syncAll() must clear the flag immediately");
            compare(source.lastSyncedCommit, "sha-after-new-commits");

            source.checkForUpdate();
            compare(source.updateAvailable, false, "freshly synced, nothing new to report");
        }

        function test_a_poll_reply_for_an_abandoned_repository_is_dropped() {
            // Same staleness-guard shape as every other loader here, just
            // against pollEpoch instead of syncEpoch/wantRid alone: a poll
            // started for one repository must not flip updateAvailable once
            // the user has moved to a different one. Uses deferredApp/
            // deferredSource: fakeApp's synchronous replies can never
            // exercise this, since every request it starts is also answered
            // before pollEpoch can move on — the exact trap tst_sync_epoch.qml
            // documents for syncAll()'s own guard.
            deferredSource.reset();
            deferredApp.deferBranches = false;
            deferredApp.pendingBranches = null;
            deferredSource.syncAll();   // answers synchronously; sets lastSyncedCommit
            compare(deferredSource.lastSyncedCommit, "sha-at-sync-time");

            // Issue the poll under test; hold its reply this time.
            deferredApp.deferBranches = true;
            deferredSource.checkForUpdate();
            verify(deferredApp.pendingBranches !== null, "expected checkForUpdate()'s ListBranches call");

            // The user leaves this repository before the poll answers.
            deferredSource.rid = "rad:zOTHER";
            deferredSource.reset();
            deferredSource.rid = "rad:zOTHER";

            // The abandoned poll finally answers, reporting a moved head —
            // exactly what should flip updateAvailable, if this were still
            // the repository it was asked about.
            deferredApp.deliverBranches("sha-after-new-commits");

            compare(deferredSource.updateAvailable, false,
                    "a poll reply for the abandoned repository must not flip updateAvailable for the new one");
        }

        function test_a_poll_reply_after_a_branch_switch_is_dropped() {
            // Same race, one level down: switching BRANCH (not repository)
            // while a poll for the old branch is in flight.
            deferredSource.reset();
            deferredSource.rid = "rad:zTEST";
            deferredSource.branch = "main";
            deferredApp.deferBranches = false;
            deferredApp.pendingBranches = null;
            deferredSource.syncAll();
            compare(deferredSource.lastSyncedCommit, "sha-at-sync-time");

            deferredApp.deferBranches = true;
            deferredSource.checkForUpdate();
            verify(deferredApp.pendingBranches !== null, "expected checkForUpdate()'s ListBranches call");

            // Switch branch before the poll answers. RepoView normally
            // calls source.reset() on a branch switch (see RepoView.qml's
            // onBranchChanged), which is what actually protects
            // lastSyncedCommit/updateAvailable; reproduced directly here so
            // this test does not depend on RepoView's wiring to prove
            // SourceTab's own guard.
            deferredSource.branch = "dev";
            deferredSource.reset();

            deferredApp.deliverBranches("sha-after-new-commits");

            compare(deferredSource.updateAvailable, false,
                    "a poll reply for the abandoned branch must not flip updateAvailable for the new one");
        }
    }
}
