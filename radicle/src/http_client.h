#pragma once

#include <string>

namespace radicle {

/// Result of a blocking HTTP GET.
struct HttpResponse {
    bool ok = false;         ///< transport succeeded AND status is 2xx
    int status = 0;          ///< HTTP status code, 0 if the request never landed
    std::string body;        ///< response body (or empty)
    std::string error;       ///< human-readable transport/HTTP error, empty when ok
};

/**
 * Minimal blocking HTTP GET over Qt Network.
 *
 * Blocking is deliberate: module methods are plain synchronous functions whose
 * return value is marshalled back to the caller, and the host already
 * dispatches each call off the UI thread. A local QEventLoop keeps the Qt
 * event machinery turning for the duration of the request without leaking
 * async plumbing into the module's public API.
 *
 * `timeoutMs` guards against a seed that accepts the connection then stalls.
 */
HttpResponse httpGet(const std::string& url, int timeoutMs = 15000);

/**
 * Decides whether a firing deadline timer should be treated as a real
 * timeout, given only whether the reply had already finished by the moment
 * the timer callback runs.
 *
 * This is the fix for a real bug: httpGet()'s deadline timer and the
 * QNetworkReply's own `finished` signal are two independently-scheduled Qt
 * events, and when a reply completes at (almost) the same moment the
 * deadline elapses, nothing guaranteed `finished` was processed first. A
 * timer callback that unconditionally set `timedOut = true` and called
 * `reply->abort()` could fire *after* the reply had already finished
 * successfully — aborting a no-op, but still latching `timedOut`, which
 * discarded a good response and reported a timeout that never happened.
 *
 * Pulled out as a pure function of the one fact that matters
 * (`replyAlreadyFinished`) so the guard is testable without a live
 * QNetworkReply or event loop timing — see test_http_client.cpp.
 */
bool isGenuineTimeout(bool replyAlreadyFinished);

/**
 * The three independent signals httpGet() observes once its event loop
 * returns.
 */
struct HttpOutcomeInputs {
    bool timedOut = false;              ///< see isGenuineTimeout() above
    bool networkErrorPresent = false;   ///< reply->error() != QNetworkReply::NoError
    std::string networkErrorString;     ///< reply->errorString(), when networkErrorPresent
    int status = 0;                     ///< HTTP status code (0 if the request never landed)
    int timeoutMs = 0;                  ///< only used to compose the timeout message
};

/**
 * Fill in `out.ok`/`out.error` (status/body are set by the caller already)
 * from `in`, in one fixed precedence: timeout, then transport error, then a
 * non-2xx status, else ok.
 *
 * Pulled out of httpGet() as a pure function so this precedence — in
 * particular, that a timeout is only ever reported when `in.timedOut` is
 * itself trustworthy (see isGenuineTimeout()) — is directly testable and
 * cannot silently drift, e.g. by someone reordering these checks so a
 * transport error masks a real timeout or vice versa.
 */
void applyHttpOutcome(HttpResponse& out, const HttpOutcomeInputs& in);

} // namespace radicle
