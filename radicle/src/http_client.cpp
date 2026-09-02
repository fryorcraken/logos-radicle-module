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
        timedOut = true;
        reply->abort();          // triggers finished(), which quits the loop
    });

    timer.start(timeoutMs);
    loop.exec();
    timer.stop();

    out.status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QByteArray body = reply->readAll();
    out.body.assign(body.constData(), static_cast<size_t>(body.size()));

    if (timedOut) {
        out.error = "request timed out after " + std::to_string(timeoutMs) + "ms";
    } else if (reply->error() != QNetworkReply::NoError) {
        out.error = reply->errorString().toStdString();
    } else if (out.status < 200 || out.status >= 300) {
        out.error = "HTTP " + std::to_string(out.status);
    } else {
        out.ok = true;
    }

    reply->deleteLater();
    return out;
}

} // namespace radicle
