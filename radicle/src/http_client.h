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

} // namespace radicle
