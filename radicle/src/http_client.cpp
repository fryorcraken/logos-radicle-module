#include "http_client.h"

#include <QByteArray>
#include <QCoreApplication>
#include <QEventLoop>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QString>
#include <QTimer>
#include <QUrl>

namespace radicle {

HttpResponse httpGet(const std::string& url, int timeoutMs)
{
    HttpResponse out;

    const QUrl qurl(QString::fromStdString(url));
    if (!qurl.isValid() || qurl.scheme().isEmpty()) {
        out.error = "invalid URL: " + url;
        return out;
    }

    // A QNetworkAccessManager needs a live QCoreApplication for its event
    // machinery. The module host provides one; bail out clearly if it does not
    // rather than crashing inside Qt.
    if (!QCoreApplication::instance()) {
        out.error = "no QCoreApplication instance available for network access";
        return out;
    }

    QNetworkAccessManager manager;
    QNetworkRequest request(qurl);
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QByteArray("logos-radicle-module/0.1"));
    request.setRawHeader("Accept", "application/json");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);

    QNetworkReply* reply = manager.get(request);

    QEventLoop loop;
    QTimer timer;
    timer.setSingleShot(true);
    bool timedOut = false;

    QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    QObject::connect(&timer, &QTimer::timeout, &loop, [&]() {
        // The deadline timer and reply->finished() are two independently
        // scheduled Qt events: a reply that completes at (almost) the same
        // moment the deadline elapses can still have this callback run
        // afterwards, because nothing guarantees finished() is processed
        // first. isGenuineTimeout() is the guard — only abort (and only
        // report a timeout) when the reply has not already finished. Without
        // it, a request that actually succeeded could be reported as timed
        // out and its body discarded.
        if (!isGenuineTimeout(reply->isFinished())) return;
        timedOut = true;
        reply->abort();          // genuine timeout only: abort the still-pending reply
    });

    timer.start(timeoutMs);
    loop.exec();
    timer.stop();

    out.status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QByteArray body = reply->readAll();
    out.body.assign(body.constData(), static_cast<size_t>(body.size()));

    HttpOutcomeInputs in;
    in.timedOut = timedOut;
    in.networkErrorPresent = reply->error() != QNetworkReply::NoError;
    in.networkErrorString = reply->errorString().toStdString();
    in.status = out.status;
    in.timeoutMs = timeoutMs;
    applyHttpOutcome(out, in);

    reply->deleteLater();
    return out;
}

bool isGenuineTimeout(bool replyAlreadyFinished)
{
    // If the reply had already finished by the time the deadline timer's
    // callback ran, the timer lost the race and there is nothing to time
    // out — the reply's own outcome (success or a real network error)
    // already stands and must not be overwritten.
    return !replyAlreadyFinished;
}

void applyHttpOutcome(HttpResponse& out, const HttpOutcomeInputs& in)
{
    if (in.timedOut) {
        out.error = "request timed out after " + std::to_string(in.timeoutMs) + "ms";
    } else if (in.networkErrorPresent) {
        out.error = in.networkErrorString;
    } else if (in.status < 200 || in.status >= 300) {
        out.error = "HTTP " + std::to_string(in.status);
    } else {
        out.ok = true;
    }
}

} // namespace radicle
