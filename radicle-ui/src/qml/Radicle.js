.pragma library

// Helpers shared by the views. Deliberately tiny: this file formats and
// unwraps data, it never fetches or interprets Radicle semantics — that all
// happens in the core module.

/// Parse a JSON reply from the backend. Returns {ok, data, error}.
function parse(text) {
    if (!text)
        return { ok: false, data: null, error: "empty response" };
    try {
        var doc = JSON.parse(text);
        if (doc && doc.error)
            return { ok: false, data: null, error: String(doc.error) };
        return { ok: true, data: doc, error: "" };
    } catch (e) {
        return { ok: false, data: null, error: "malformed response" };
    }
}

/// Pull the project payload out of a repo object from the seed API.
function project(repo) {
    if (!repo || !repo.payloads)
        return {};
    var p = repo.payloads["xyz.radicle.project"];
    return (p && p.data) ? p.data : {};
}

function projectMeta(repo) {
    if (!repo || !repo.payloads)
        return {};
    var p = repo.payloads["xyz.radicle.project"];
    return (p && p.meta) ? p.meta : {};
}

function repoName(repo) {
    return project(repo).name || "(unnamed)";
}

function repoDescription(repo) {
    return project(repo).description || "";
}

/// Short form of a RID or OID for display.
function short(id, n) {
    if (!id) return "";
    var s = String(id);
    var body = s.indexOf("rad:") === 0 ? s.substring(4) : s;
    return body.length > (n || 7) ? body.substring(0, n || 7) : body;
}

/// Best-effort display name for an author object.
function authorName(author) {
    if (!author) return "unknown";
    if (author.alias) return author.alias;
    if (author.name) return author.name;
    if (author.id) return short(String(author.id).replace("did:key:", ""), 8);
    return "unknown";
}

/// Unix seconds -> short local date string.
function when(seconds) {
    if (!seconds) return "";
    return new Date(seconds * 1000).toLocaleDateString(Qt.locale());
}

/// A deterministic colour per identifier, so avatars need no network images
/// (the QML sandbox blocks remote images anyway).
function tint(id) {
    var s = String(id || "");
    var h = 0;
    for (var i = 0; i < s.length; i++)
        h = (h * 31 + s.charCodeAt(i)) % 360;
    return Qt.hsla(h / 360, 0.45, 0.55, 1.0);
}

function initial(text) {
    var s = String(text || "?").replace("rad:", "");
    return s.length ? s.charAt(0).toUpperCase() : "?";
}

function statusOf(obj) {
    if (obj && obj.state && obj.state.status) return String(obj.state.status);
    return "";
}
