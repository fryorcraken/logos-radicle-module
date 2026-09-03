#include "radicle_ui_backend.h"

// Generated from metadata.json#dependencies — gives modules().radicle, a
// Qt-typed wrapper around the core module's API.
#include "logos_sdk.h"

// Every method below is a one-line forward to the core module. That is the
// whole point of this class: the view process holds no Radicle logic, so there
// is exactly one place (the core module) where endpoint shapes, SHA
// resolution and error handling are defined.

// --- source-neutral --------------------------------------------------------

QString RadicleUiBackend::getCapabilities()
{
    return modules().radicle.getCapabilities();
}

QString RadicleUiBackend::listKnownSeeds()
{
    return modules().radicle.listKnownSeeds();
}

QString RadicleUiBackend::setRemoteSeed(QString seedUrl)
{
    const QString result = modules().radicle.setRemoteSeed(seedUrl);
    // Switching seeds changes what the module can reach, so refresh the
    // auto-synced capabilities alongside it.
    setCapabilities(modules().radicle.getCapabilities());
    return result;
}

// --- remote ----------------------------------------------------------------

QString RadicleUiBackend::remoteListRepos(QString query, int page, int perPage)
{
    return modules().radicle.remoteListRepos(query, page, perPage);
}

QString RadicleUiBackend::remoteGetRepo(QString rid)
{
    return modules().radicle.remoteGetRepo(rid);
}

QString RadicleUiBackend::remoteGetTree(QString rid, QString sha, QString path)
{
    return modules().radicle.remoteGetTree(rid, sha, path);
}

QString RadicleUiBackend::remoteGetBlob(QString rid, QString sha, QString path)
{
    return modules().radicle.remoteGetBlob(rid, sha, path);
}

QString RadicleUiBackend::remoteGetReadme(QString rid, QString sha)
{
    return modules().radicle.remoteGetReadme(rid, sha);
}

QString RadicleUiBackend::remoteListCommits(QString rid, QString sha, int page, int perPage)
{
    return modules().radicle.remoteListCommits(rid, sha, page, perPage);
}

QString RadicleUiBackend::remoteGetCommit(QString rid, QString sha)
{
    return modules().radicle.remoteGetCommit(rid, sha);
}

QString RadicleUiBackend::remoteListIssues(QString rid, QString status, int page, int perPage)
{
    return modules().radicle.remoteListIssues(rid, status, page, perPage);
}

QString RadicleUiBackend::remoteGetIssue(QString rid, QString id)
{
    return modules().radicle.remoteGetIssue(rid, id);
}

QString RadicleUiBackend::remoteListPatches(QString rid, QString status, int page, int perPage)
{
    return modules().radicle.remoteListPatches(rid, status, page, perPage);
}

QString RadicleUiBackend::remoteGetPatch(QString rid, QString id)
{
    return modules().radicle.remoteGetPatch(rid, id);
}

// --- local -----------------------------------------------------------------

QString RadicleUiBackend::localListRepos(QString scope, int page, int perPage)
{
    return modules().radicle.localListRepos(scope, page, perPage);
}

QString RadicleUiBackend::localGetRepo(QString rid)
{
    return modules().radicle.localGetRepo(rid);
}

QString RadicleUiBackend::localGetTree(QString rid, QString sha, QString path)
{
    return modules().radicle.localGetTree(rid, sha, path);
}

QString RadicleUiBackend::localGetBlob(QString rid, QString sha, QString path)
{
    return modules().radicle.localGetBlob(rid, sha, path);
}

QString RadicleUiBackend::localGetReadme(QString rid, QString sha)
{
    return modules().radicle.localGetReadme(rid, sha);
}

QString RadicleUiBackend::localListCommits(QString rid, QString sha, int page, int perPage)
{
    return modules().radicle.localListCommits(rid, sha, page, perPage);
}

QString RadicleUiBackend::localGetCommit(QString rid, QString sha)
{
    return modules().radicle.localGetCommit(rid, sha);
}

QString RadicleUiBackend::localListIssues(QString rid, QString status, int page, int perPage)
{
    return modules().radicle.localListIssues(rid, status, page, perPage);
}

QString RadicleUiBackend::localGetIssue(QString rid, QString id)
{
    return modules().radicle.localGetIssue(rid, id);
}

QString RadicleUiBackend::localListPatches(QString rid, QString status, int page, int perPage)
{
    return modules().radicle.localListPatches(rid, status, page, perPage);
}

QString RadicleUiBackend::localGetPatch(QString rid, QString id)
{
    return modules().radicle.localGetPatch(rid, id);
}

// --- lifecycle -------------------------------------------------------------

void RadicleUiBackend::onContextReady()
{
    // Publish capabilities as soon as the core module is reachable so the view
    // knows on first paint whether to offer the local source at all, rather
    // than rendering a source picker and then correcting it.
    setCapabilities(modules().radicle.getCapabilities());
}
