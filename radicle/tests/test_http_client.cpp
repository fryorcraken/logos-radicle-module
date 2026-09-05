#include <logos_test.h>

#include "http_client.h"

using namespace radicle;

// ---------------------------------------------------------------------------
// isGenuineTimeout()
//
// httpGet()'s deadline timer and QNetworkReply::finished are two
// independently-scheduled Qt events. A reply that completes at (almost) the
// same moment the deadline elapses can have its timer callback run even
// though the reply already finished successfully — nothing serialises the
// two in its favour. The old code treated every timer firing as a genuine
// timeout unconditionally, latching `timedOut = true` and calling
// `reply->abort()` on a reply that had nothing left to abort, then reporting
// "timed out" for a request that actually succeeded.
//
// isGenuineTimeout() is the guard: it must say "not a real timeout" when the
// reply had already finished by the time the timer callback ran, and "real
// timeout" otherwise. A stub that answers the same regardless of input
// (as the pre-fix code effectively did) cannot tell these apart, so both
// cases are asserted.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_timer_firing_after_the_reply_already_finished_is_not_a_genuine_timeout)
{
    // This is the race: the reply finished successfully, but the deadline
    // timer's callback still runs (its event was already queued). Treating
    // this as a timeout is exactly the bug — it discards a good response.
    LOGOS_ASSERT_FALSE(isGenuineTimeout(/*replyAlreadyFinished=*/true));
}

LOGOS_TEST(a_timer_firing_while_the_reply_is_still_pending_is_a_genuine_timeout)
{
    // The ordinary case this guard must not break: a seed that never
    // replies within the deadline must still be reported as timed out.
    LOGOS_ASSERT_TRUE(isGenuineTimeout(/*replyAlreadyFinished=*/false));
}

// ---------------------------------------------------------------------------
// applyHttpOutcome()
//
// Pure precedence: timeout, then transport error, then non-2xx status, else
// ok. Testing this directly (rather than only through a live QNetworkReply)
// is what makes the ordering a fact this suite pins down instead of
// something only observable by racing real sockets.
// ---------------------------------------------------------------------------

LOGOS_TEST(a_genuine_timeout_is_reported_even_though_abort_also_sets_a_network_error)
{
    // Aborting a still-pending reply makes reply->error() come back
    // OperationCanceledError, i.e. networkErrorPresent is also true here.
    // The timeout message must win — it is the useful, specific one.
    HttpResponse out;
    HttpOutcomeInputs in;
    in.timedOut = true;
    in.networkErrorPresent = true;
    in.networkErrorString = "Operation canceled";
    in.status = 0;
    in.timeoutMs = 15000;

    applyHttpOutcome(out, in);

    LOGOS_ASSERT_FALSE(out.ok);
    LOGOS_ASSERT_CONTAINS(out.error, "timed out");
    LOGOS_ASSERT_CONTAINS(out.error, "15000");
}

LOGOS_TEST(a_successful_reply_that_narrowly_beat_the_deadline_is_reported_ok)
{
    // The actual regression scenario end to end: the reply completed
    // successfully (no network error, 2xx status) and isGenuineTimeout()
    // correctly said "not a real timeout" because the reply had already
    // finished. The response must be reported ok, carrying its real body,
    // not discarded as a timeout.
    HttpResponse out;
    out.status = 200;
    out.body = "{\"ok\":true}";

    HttpOutcomeInputs in;
    in.timedOut = false;   // isGenuineTimeout(true) => false, fed in here
    in.networkErrorPresent = false;
    in.status = 200;

    applyHttpOutcome(out, in);

    LOGOS_ASSERT_TRUE(out.ok);
    LOGOS_ASSERT_TRUE(out.error.empty());
    LOGOS_ASSERT_EQ(out.body, std::string("{\"ok\":true}"));
}

LOGOS_TEST(a_transport_error_with_no_timeout_reports_the_network_error_string)
{
    HttpResponse out;
    HttpOutcomeInputs in;
    in.timedOut = false;
    in.networkErrorPresent = true;
    in.networkErrorString = "Connection refused";
    in.status = 0;

    applyHttpOutcome(out, in);

    LOGOS_ASSERT_FALSE(out.ok);
    LOGOS_ASSERT_EQ(out.error, std::string("Connection refused"));
}

LOGOS_TEST(a_non_2xx_status_with_no_timeout_or_transport_error_reports_http_status)
{
    HttpResponse out;
    HttpOutcomeInputs in;
    in.timedOut = false;
    in.networkErrorPresent = false;
    in.status = 404;

    applyHttpOutcome(out, in);

    LOGOS_ASSERT_FALSE(out.ok);
    LOGOS_ASSERT_CONTAINS(out.error, "404");
}
