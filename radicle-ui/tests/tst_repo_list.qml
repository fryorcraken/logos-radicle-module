import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * RepoList.fetch() must not let a stale reply populate the list once the
 * user has moved on to a different source or search query.
 *
 * This is the fifth instance of the same bug class this codebase has fixed
 * before (IssuesTab, CommitsTab, ThreadView, CommitView, SourceTab all guard
 * their async replies with a captured wantX check) but RepoList had none at
 * all — reload() clears the model and calls fetch() again while a previous
 * fetch() may still be in flight, and the old reply's items get appended into
 * the new list at RepoList.qml's `repos.append(...)` line unconditionally.
 *
 * Reachable from Main.qml three ways: the source toggle (SourceState.onChanged
 * -> repoList.reload()), setSeed() succeeding, and pressing Enter in the
 * search field (FilterField.onAccepted -> repoList.reload()).
 */
Item {
    width: 900
    height: 600

    // A fake backend that holds every reply until the test delivers it, keyed
    // by the request's own first argument (query or scope) so multiple
    // requests can be in flight at once and delivered out of order. Each
    // reply's item COUNT is different per query/scope (alpha -> 1 item, beta
    // -> 2 items, "all" -> 3 items) — a fake that returned the same number of
    // items regardless of input could not distinguish "the stale reply was
    // dropped" from "the stale reply was empty anyway".
    QtObject {
        id: deferredApp
        property var pendingBySource: ({})
        property string source: "remote"

        // Item counts are per-request-shape, not per-value, so different
        // (source, first) inputs are guaranteed to disagree on how many rows
        // they contribute.
        function itemCountFor(forSource, first) {
            if (forSource === "remote" && first === "alpha") return 1;
            if (forSource === "remote" && first === "beta") return 2;
            if (forSource === "remote" && first === "") return 4;
            if (forSource === "local" && first === "all") return 3;
            return 9;
        }

        function call(method, args, onOk, onFail) {
            var first = args[0];
            var key = source + ":" + first;
            pendingBySource[key] = { onOk: onOk, onFail: onFail, first: first, forSource: source };
        }

        function pendingCount() {
            var n = 0;
            for (var k in pendingBySource) n++;
            return n;
        }

        // Deliver the reply for a given query/scope. The number of items
        // returned depends on (forSource, first) via itemCountFor above.
        function deliver(forSource, first, hasMore) {
            var key = forSource + ":" + first;
            var p = pendingBySource[key];
            if (!p) return false;
            delete pendingBySource[key];
            var n = itemCountFor(forSource, first);
            var items = [];
            for (var i = 0; i < n; i++)
                items.push({ rid: "rad:" + forSource + ":" + first + ":" + i });
            p.onOk({ items: items, hasMore: !!hasMore });
            return true;
        }
    }

    Ui.RepoList {
        id: list
        anchors.fill: parent
        app: deferredApp
    }

    TestCase {
        name: "RepoListStaleness"
        when: windowShown

        function init() {
            deferredApp.pendingBySource = ({});
            deferredApp.source = "remote";
            list.app = null;
            list.app = deferredApp;
            list.query = "";
            list.page_ = 0;
            list.hasMore = false;
            list.loading = false;
            list.loadedOnce = false;
        }

        /// Baseline: a single in-flight reply, delivered, populates the list
        /// with the item count that matches the query it was requested for —
        /// proves the fake's per-query counts are meaningful before relying
        /// on them below.
        function test_a_single_reply_populates_the_list_with_matching_count() {
            list.query = "alpha";
            list.fetch();
            compare(deferredApp.pendingCount(), 1);
            verify(deferredApp.deliver("remote", "alpha", false));
            compare(list.count, 1, "alpha's fake reply carries exactly 1 item");
        }

        /// The bug: reload() (as Main.qml's search field, source toggle and
        /// setSeed all trigger) clears the model and re-fetches for a NEW
        /// query while the OLD query's request is still in flight. When the
        /// old reply lands, it must be dropped rather than appended.
        function test_a_stale_query_reply_is_dropped_after_reload_with_a_new_query() {
            list.query = "alpha";
            list.fetch();
            verify(deferredApp.pendingCount() === 1, "expected the alpha request in flight");

            // The user retypes and presses Enter before "alpha" answers.
            list.query = "beta";
            list.reload();
            compare(deferredApp.pendingCount(), 2, "beta's request should now also be in flight");

            // Only "beta" answers first — proves ordering is not what saves us.
            verify(deferredApp.deliver("remote", "beta", false));
            compare(list.count, 2, "beta's fake reply carries exactly 2 items");

            // Now the stale "alpha" reply arrives (1 more item, if not dropped).
            verify(deferredApp.deliver("remote", "alpha", false));

            compare(list.count, 2,
                    "the stale alpha reply must not be appended into beta's list " +
                    "(would be 3 if it leaked through)");
        }

        /// Same failure, reached the way the source toggle reaches it: the
        /// query is unchanged but the source flips underneath an in-flight
        /// request (RepoList always requests "all" for local, so a plain
        /// query-based guard alone would not catch this path).
        function test_a_stale_reply_from_the_old_source_is_dropped_after_switching_source() {
            deferredApp.source = "remote";
            list.query = "";
            list.fetch();
            verify(deferredApp.pendingCount() === 1, "expected the remote request in flight");

            deferredApp.source = "local";
            list.reload();
            compare(deferredApp.pendingCount(), 2);

            verify(deferredApp.deliver("local", "all", false));
            compare(list.count, 3, "local/all's fake reply carries exactly 3 items");

            // The stale remote reply (4 items) arrives after switching source.
            verify(deferredApp.deliver("remote", "", false));

            compare(list.count, 3,
                    "the stale remote reply must not be appended into the local list " +
                    "(would be 7 if it leaked through)");
        }
    }
}
