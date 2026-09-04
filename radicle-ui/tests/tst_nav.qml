import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * NavState: the inflight counter and error latch behind Main.qml's status
 * strip.
 *
 * A pre-release architecture review found these had only incidental coverage
 * via layout tests. Two bugs already happened here once (see NavState.qml's
 * doc comment): `busy` as a boolean instead of a counter, and `error` being
 * cleared on every request start instead of only on success/navigation. This
 * file pins both so they cannot come back.
 */
Item {
    Ui.NavState { id: nav }

    TestCase {
        name: "NavState"
        when: windowShown

        function init() {
            nav.reset();
        }

        function test_starts_idle_with_no_error() {
            compare(nav.busy, false);
            compare(nav.error, "");
            compare(nav.view, "repos");
        }

        function test_busy_is_a_counter_not_a_flag() {
            // Two requests in flight at once — SourceTab.load() alone fires
            // two, syncAll() fires dozens. With a boolean, the first reply to
            // land cleared the strip while the second was still in flight.
            nav.begin();
            nav.begin();
            compare(nav.busy, true, "busy while two requests are in flight");

            nav.succeed();
            compare(nav.busy, true,
                    "one reply landing must not clear busy while another is still in flight");

            nav.succeed();
            compare(nav.busy, false, "busy only once every request has replied");
        }

        function test_fail_also_decrements_the_counter() {
            nav.begin();
            nav.begin();
            nav.fail("boom");
            compare(nav.busy, true, "still one request in flight");
            nav.succeed();
            compare(nav.busy, false);
        }

        function test_a_later_error_is_not_erased_by_an_earlier_requests_success() {
            // The bug: nav.error used to be cleared at the START of every
            // request, so during a sync (many parallel fetches) a real error
            // from one request was wiped out by the NEXT request beginning,
            // not by that request's own outcome.
            nav.begin();  // request A starts
            nav.begin();  // request B starts
            nav.fail("A failed");
            compare(nav.error, "A failed");

            // A third request starting must not touch the error left by A.
            nav.begin();  // request C starts
            compare(nav.error, "A failed",
                    "starting a new request must not clear a previous error");

            nav.succeed(); // B succeeds
            compare(nav.error, "",
                    "a successful reply clears the error, even though a sibling request is still in flight");
        }

        function test_success_clears_a_previous_error() {
            nav.begin();
            nav.fail("first failure");
            compare(nav.error, "first failure");

            nav.begin();
            nav.succeed();
            compare(nav.error, "", "a successful reply clears a prior error");
        }

        function test_a_new_failure_replaces_the_previous_one() {
            nav.begin();
            nav.fail("first failure");
            nav.begin();
            nav.fail("second failure");
            compare(nav.error, "second failure");
        }

        function test_open_repo_switches_view_and_carries_the_repo() {
            var repo = { rid: "rad:zTEST", name: "test" };
            nav.openRepo(repo);
            compare(nav.view, "repo");
            compare(nav.rid, "rad:zTEST");
            compare(nav.repo, repo);
        }

        function test_back_returns_to_the_repo_list_and_clears_state() {
            nav.openRepo({ rid: "rad:zTEST" });
            nav.error = "stale error";
            nav.back();
            compare(nav.view, "repos");
            compare(nav.rid, "");
            compare(nav.repo, null);
            compare(nav.error, "", "leaving a repo must not leave its error behind");
        }

        function test_reset_clears_inflight_view_and_error() {
            nav.openRepo({ rid: "rad:zTEST" });
            nav.begin();
            nav.begin();
            nav.error = "stale error";

            nav.reset();

            compare(nav.view, "repos");
            compare(nav.rid, "");
            compare(nav.repo, null);
            compare(nav.busy, false, "reset must not leave orphaned in-flight requests");
            compare(nav.error, "");
        }
    }
}
