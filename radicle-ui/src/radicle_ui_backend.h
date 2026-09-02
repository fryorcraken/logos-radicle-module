#pragma once

#include "rep_radicle_ui_source.h"
#include "logos_ui_plugin_context.h"

/**
 * @brief Thin view backend for the Radicle UI.
 *
 * This class is intentionally almost empty of logic. Every slot forwards to
 * the `radicle` core module and hands the resulting JSON string straight back
 * to QML. All Radicle knowledge — seed URLs, endpoint shapes, SHA resolution,
 * pagination, local-profile detection — lives in the core module, so that it
 * is testable on its own, reusable by other views (a CLI, a headless runtime),
 * and not duplicated here.
 *
 * Two constraints make this shape the right one rather than merely tidy:
 *
 *  - Basecamp sandboxes the QML engine: it installs a deny-all network access
 *    manager and a URL interceptor that blocks http/https and any file outside
 *    the plugin directory. A QML view therefore *cannot* fetch anything
 *    itself; a C++ backend must do it.
 *  - This backend runs in its own process (QtRO), so a stall or crash while
 *    talking to a seed cannot take Basecamp's UI down with it.
 */
class RadicleUiBackend : public RadicleUiSimpleSource,
                         public LogosUiPluginContext
{
public:
    // Source-neutral
    QString getCapabilities() override;
    QString listKnownSeeds() override;
    QString setRemoteSeed(QString seedUrl) override;

    // Remote — proxied to a seed node over HTTPS
    QString remoteListRepos(QString query, int page, int perPage) override;
    QString remoteGetRepo(QString rid) override;
    QString remoteGetTree(QString rid, QString sha, QString path) override;
    QString remoteGetBlob(QString rid, QString sha, QString path) override;
    QString remoteGetReadme(QString rid, QString sha) override;
    QString remoteListCommits(QString rid, QString sha, int page, int perPage) override;
    QString remoteListIssues(QString rid, QString status, int page, int perPage) override;
    QString remoteGetIssue(QString rid, QString id) override;
    QString remoteListPatches(QString rid, QString status, int page, int perPage) override;
    QString remoteGetPatch(QString rid, QString id) override;

    // Local — this machine's node
    QString localListRepos(QString scope, int page, int perPage) override;
    QString localGetRepo(QString rid) override;
    QString localGetTree(QString rid, QString sha, QString path) override;
    QString localGetBlob(QString rid, QString sha, QString path) override;
    QString localGetReadme(QString rid, QString sha) override;
    QString localListCommits(QString rid, QString sha, int page, int perPage) override;
    QString localListIssues(QString rid, QString status, int page, int perPage) override;
    QString localGetIssue(QString rid, QString id) override;
    QString localListPatches(QString rid, QString status, int page, int perPage) override;
    QString localGetPatch(QString rid, QString id) override;

protected:
    /// Publish the module's capabilities once the core module is reachable.
    void onContextReady() override;
};
