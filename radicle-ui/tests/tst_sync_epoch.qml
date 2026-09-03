import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * SourceTab.syncEpoch: a stale reply arriving AFTER a new sync has already
 * started must not corrupt the new sync's counters.
 *
 * tst_repo_switch.qml's deepApp/deepSource fixtures reply synchronously, so
 * every request started under one epoch is also answered under that same
 * epoch before the next one can begin — the false path (a reply landing
 * once syncEpoch has already moved on) can never actually happen there. This
 * file uses a fake backend that holds replies until the test delivers them,
 * so a sync can be started, abandoned (by starting a second sync, or by
 * cancelSync()/reset()), and only THEN have its original reply let through.
 */
Item {
    // A fake backend that queues every call and only answers when the test
    // tells it to. Requests are FIFO per call, so the test can target "the
    // first GetTree" by index.
    QtObject {
        id: deferredApp
        property var pending: []
        function call(method, args, onOk, onFail) {
            pending.push({ method: method, args: args, onOk: onOk, onFail: onFail });
        }
        function deliver(index, entries) {
            var p = pending[index];
            p.onOk({ entries: entries || [] });
        }
        function reset() { pending = []; }
    }

    Ui.SourceTab {
        id: source
        anchors.fill: parent
        visible: false
        app: deferredApp
        rid: "rad:zTEST"
        branch: "main"
    }

    TestCase {
        name: "SourceTabSyncEpoch"
        when: windowShown

        function init() {
            source.reset();
            deferredApp.reset();
        }

        function test_a_root_reply_from_an_abandoned_sync_is_dropped_after_syncAll_restarts() {
            // Sync #1 starts and asks for the root tree; hold that reply.
            source.syncAll();
            compare(deferredApp.pending.length, 1, "expected one GetTree(\"\") request");
            var epochAtFirstSync = source.syncEpoch;

            // The user cancels and starts again before sync #1's root reply
            // ever arrives — cancelSync() bumps syncEpoch, orphaning the
            // request already in flight.
            source.cancelSync();
            source.syncAll();
            verify(source.syncEpoch !== epochAtFirstSync,
                   "a fresh sync must use a new epoch");
            compare(deferredApp.pending.length, 2, "expected a second GetTree(\"\") request");

            var queuedAfterRestart = source.syncQueued;
            var doneAfterRestart = source.syncDone;

            // Now let sync #1's original (stale) reply land, carrying two
            // files that would otherwise inflate sync #2's counters.
            deferredApp.deliver(0, [
                { kind: "blob", path: "stale-a.txt", name: "stale-a.txt" },
                { kind: "blob", path: "stale-b.txt", name: "stale-b.txt" }
            ]);

            compare(source.syncQueued, queuedAfterRestart,
                    "a stale reply must not add to the running sync's queued count");
            compare(source.syncDone, doneAfterRestart,
                    "a stale reply must not add to the running sync's done count");
            compare(deferredApp.pending.length, 2,
                    "a stale directory's files must not be walked into new requests");

            // Sync #2 completes normally afterwards.
            deferredApp.deliver(1, []);
            compare(source.syncing, false);
            compare(source.syncedOnce, true);
        }

        function test_a_stale_reply_cannot_flip_syncing_back_on_after_cancel() {
            source.syncAll();
            compare(deferredApp.pending.length, 1);

            source.cancelSync();
            compare(source.syncing, false);

            // The cancelled sync's request finally answers.
            deferredApp.deliver(0, []);

            compare(source.syncing, false,
                    "a reply for a cancelled sync must not resurrect syncing");
            compare(source.syncedOnce, false,
                    "a cancelled sync must not be reported as completed");
        }

        function test_a_stale_reply_does_not_corrupt_a_sync_for_a_different_repository() {
            // Same shape as the CommitsTab regression, one level up: switching
            // REPOSITORY (not just restarting the same sync) must orphan an
            // in-flight sync request the same way.
            source.syncAll();
            compare(deferredApp.pending.length, 1);

            source.rid = "rad:zOTHER";
            source.reset();
            source.rid = "rad:zOTHER";

            var queuedForOther = source.syncQueued;

            deferredApp.deliver(0, [
                { kind: "blob", path: "old-repo-file.txt", name: "old-repo-file.txt" }
            ]);

            compare(source.syncQueued, queuedForOther,
                    "a reply meant for the abandoned repository must not touch the new one's counters");
            compare(source.syncing, false,
                    "no sync is running for the new repository yet");
        }
    }
}
