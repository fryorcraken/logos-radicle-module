import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Cache-first list loading.
 *
 * Toggling between open and closed issues used to clear the list and refetch,
 * so a filter you had already viewed came back empty and made you wait again.
 * The policy is local-first: serve what we have immediately, revalidate in the
 * background, and only rebuild the model when the answer actually changed.
 */
Item {
    width: 600
    height: 400

    Ui.ListCache { id: cache }

    TestCase {
        name: "ListCache"
        when: windowShown

        function init() {
            cache.clear();
        }

        function test_a_stored_page_is_served_back() {
            verify(!cache.has("k"));
            cache.put("k", [{ id: "a" }, { id: "b" }]);
            verify(cache.has("k"));
            compare(cache.items("k").length, 2);
        }

        function test_a_fresh_entry_is_not_revalidated() {
            cache.put("k", [{ id: "a" }]);
            verify(!cache.isStale("k"));
        }

        function test_an_unknown_key_counts_as_stale() {
            verify(cache.isStale("never-seen"));
        }

        function test_keys_do_not_collide_across_filters() {
            // The bug this guards: a key omitting the filter would serve
            // closed issues under the open filter.
            cache.put("rid open 0",   [{ id: "open-1" }]);
            cache.put("rid closed 0", [{ id: "closed-1" }, { id: "closed-2" }]);
            compare(cache.items("rid open 0").length, 1);
            compare(cache.items("rid closed 0").length, 2);
        }

        function test_only_one_request_per_key_is_admitted() {
            // A rapid filter toggle must not queue several identical fetches.
            verify(cache.begin("k"));
            verify(!cache.begin("k"));
            verify(cache.busy("k"));
            cache.end("k");
            verify(!cache.busy("k"));
            verify(cache.begin("k"));
        }

        function test_identical_replies_are_recognised() {
            // An unchanged reply must not rebuild the model, or the scroll
            // position is thrown away for nothing.
            var a = [{ id: "1" }, { id: "2" }];
            var b = [{ id: "1" }, { id: "2" }];
            var c = [{ id: "1" }, { id: "3" }];
            verify(cache.sameIds(a, b));
            verify(!cache.sameIds(a, c));
            verify(!cache.sameIds(a, [{ id: "1" }]));
        }

        function test_repos_compare_by_rid_when_they_have_no_id() {
            // Repositories carry `rid`; issues and patches carry `id`.
            verify(cache.sameIds([{ rid: "rad:z1" }], [{ rid: "rad:z1" }]));
            verify(!cache.sameIds([{ rid: "rad:z1" }], [{ rid: "rad:z2" }]));
        }

        function test_clearing_drops_everything_including_in_flight() {
            cache.put("k", [{ id: "a" }]);
            cache.begin("k2");
            cache.clear();
            verify(!cache.has("k"));
            // A stale in-flight marker would block every future fetch.
            verify(!cache.busy("k2"));
        }
    }
}
