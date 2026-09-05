//! Git-native reads: tree, blob, readme, commit list, commit + diff.
//!
//! These mirror `remoteGetTree`/`remoteGetBlob`/`remoteGetReadme`/
//! `remoteListCommits`/`remoteGetCommit`, which proxy radicle-httpd. The JSON
//! shapes here are not guessed from radicle-httpd's serde derives (that crate
//! is not vendored) — they are reconstructed from the *consumer* side: the QML
//! in `radicle-ui/src/qml/` is the only thing that reads these replies, and
//! every field below is one it actually looks at. `tests/git_reads.rs` pins
//! each one against a real fixture repo.
//!
//! Two shape details are easy to get wrong and are called out because a
//! mistake in either is silent — the view renders, just wrongly:
//!
//! - Hunks live at `diff.files[].diff.hunks[]`, with a second `diff` level
//!   inside each file entry. `CommitView.qml` reads `modelData.diff.hunks`.
//! - Every timestamp is **Unix seconds**, not milliseconds. `Radicle.js`'s
//!   `when()` does `new Date(t * 1000)`; feeding it milliseconds renders dates
//!   in the year 57000.

use radicle::prelude::ReadRepository;
use radicle::storage::git::Repository;
// `raw()` — the escape hatch to the underlying git2 handle — is declared on
// `WriteRepository`, but it is a read-only accessor: having the trait in scope
// grants no write capability, and nothing here calls a mutating method.
use radicle::storage::WriteRepository;
use serde_json::{json, Map, Value};

use crate::local::{open_storage, parse_rid};

/// Resolve a branch name, short SHA or full SHA to a commit.
///
/// `SeedClient::resolveSha` does the same job against the seed API, which
/// rejects anything shorter than 40 hex chars. Locally git itself is happy to
/// resolve short SHAs and ref names, so this is a thin wrapper — but the
/// *fallback* behaviour has to match the remote path exactly: an empty or
/// unresolvable ref falls back to the repo head rather than erroring, because
/// that is what the seed client does and the views rely on it (`RepoView`
/// passes `defaultBranch`, which is `""` when a repo payload omits it).
fn resolve_commit<'a>(
    home: &str,
    repo: &'a Repository,
    reference: &str,
) -> Result<git2::Commit<'a>, String> {
    let backend = repo.raw();

    if !reference.is_empty() {
        // THE CANDIDATE ORDER BELOW IS LOAD-BEARING. Getting it wrong does not
        // produce an error — an unresolvable ref deliberately falls through to
        // the repo head (to match `SeedClient::resolveSha`), so a missed
        // lookup renders the WRONG BRANCH'S FILES under the right branch's
        // name. Every bug in this function has had that same silent shape.
        //
        // Radicle storage keeps every branch under a peer's namespace,
        // `refs/namespaces/<nid>/refs/heads/<branch>` — the local node's own
        // included. The unnamespaced `refs/heads/*` holds a single canonical
        // delegate-consensus ref and nothing else. So:
        //
        // 1. `refs/namespaces/<self>/refs/heads/<name>` — the local node's own
        //    branches, which `list_branches` lists BARE. This candidate is the
        //    reason local branches resolve at all: `develop` exists at neither
        //    `refs/heads/develop` nor anywhere else unnamespaced, so without
        //    it every local branch except the canonical one fell through to
        //    the head fallback and showed the default branch's files.
        // 2. `refs/heads/<name>` — the canonical ref. Second so that a local
        //    branch beats it when both exist.
        // 3. `refs/namespaces/<nid>/refs/heads/<branch>` — another peer's
        //    branch, which `list_branches` qualifies as `<nid>/<branch>`.
        //    Guarded twice: the first segment must parse as a `NodeId` (so an
        //    ordinary slashed local branch like `feature/login` never builds
        //    this candidate), and it is tried after 1 so that a local branch
        //    named literally `<peer-nid>/<branch>` — legal, if perverse —
        //    still resolves to the local one.
        // 4. A raw revparse, for short and full SHAs and tags.
        let local_nid = crate::local::local_node_id(home);
        let own_namespace =
            local_nid.map(|nid| format!("refs/namespaces/{nid}/refs/heads/{reference}"));

        let peer_namespace = reference.split_once('/').and_then(|(nid, branch)| {
            nid.parse::<radicle::node::NodeId>()
                .ok()
                .map(|_| format!("refs/namespaces/{nid}/refs/heads/{branch}"))
        });

        let candidates = own_namespace
            .into_iter()
            .chain([format!("refs/heads/{reference}")])
            .chain(peer_namespace)
            .chain([reference.to_string()]);

        for candidate in candidates {
            if let Ok(object) = backend.revparse_single(&candidate) {
                if let Ok(commit) = object.peel_to_commit() {
                    return Ok(commit);
                }
            }
        }
    }

    let (_, head) = repo
        .head()
        .map_err(|e| format!("could not resolve head: {e}"))?;
    backend
        .find_commit(head.into())
        .map_err(|e| format!("could not read head commit {head}: {e}"))
}

fn open_repo(home: &str, rid: &str) -> Result<Repository, String> {
    let storage = open_storage(home)?;
    let id = parse_rid(rid)?;
    radicle::storage::ReadStorage::repository(&storage, id)
        .map_err(|e| format!("repository {rid} not found locally: {e}"))
}

/// The COB reads in `cobs.rs` need the same repository handle, and open it the
/// same way — one definition rather than two that could drift.
pub(crate) fn open_repo_pub(home: &str, rid: &str) -> Result<Repository, String> {
    open_repo(home, rid)
}

/// Author block in the shape `Radicle.js`'s `authorName()` expects:
/// `{alias?, name?, email?, id?}`, tried in that order. A git commit has a
/// name and an email but no Radicle DID, so only those two are set — matching
/// what the seed returns for commits, where `authorName` falls through to
/// `name` and the avatar seeds off `email`.
fn git_signature(sig: &git2::Signature<'_>) -> Value {
    json!({
        "name": sig.name().unwrap_or("").to_string(),
        "email": sig.email().unwrap_or("").to_string(),
    })
}

/// One commit's summary block, as it appears both in `listCommits`' items and
/// under `getCommit`'s `commit` key.
///
/// `committer.time` is Unix **seconds** — `git2::Time::seconds()` is already
/// in seconds, so this one needs no conversion (unlike the COB timestamps in
/// `cobs.rs`, which are milliseconds and do).
fn commit_summary(commit: &git2::Commit<'_>) -> Value {
    // git2 0.21 returns `Result<Option<&str>>` here: `Err` for a non-UTF-8
    // message, `Ok(None)` for an absent one. Both collapse to "" — a commit
    // with an unreadable message still has an id, an author and a diff worth
    // showing.
    let summary = commit.summary().ok().flatten().unwrap_or("").to_string();
    let body = commit.body().ok().flatten().unwrap_or("").to_string();

    json!({
        "id": commit.id().to_string(),
        "summary": summary,
        "description": body,
        "author": git_signature(&commit.author()),
        "committer": {
            "name": commit.committer().name().unwrap_or("").to_string(),
            "email": commit.committer().email().unwrap_or("").to_string(),
            "time": commit.committer().when().seconds(),
        },
    })
}

// ---------------------------------------------------------------------------
// Tree
// ---------------------------------------------------------------------------

/// Directory listing at `path` ("" = root) for `sha`.
/// -> `{"path":"...","entries":[{"name","path","kind":"tree"|"blob","oid"}]}`
///
/// `kind` is the field `SourceTab.qml` branches on: exactly `"tree"` means a
/// directory, anything else is treated as a file. Submodules (gitlinks) are
/// therefore reported as `"blob"` rather than inventing a third value the view
/// would silently mis-handle as a file anyway.
pub fn get_tree(home: &str, rid: &str, sha: &str, path: &str) -> String {
    match get_tree_inner(home, rid, sha, path) {
        Ok(v) => v.to_string(),
        Err(e) => crate::local::error(e),
    }
}

fn get_tree_inner(home: &str, rid: &str, sha: &str, path: &str) -> Result<Value, String> {
    let repo = open_repo(home, rid)?;
    let commit = resolve_commit(home, &repo, sha)?;
    let root = commit
        .tree()
        .map_err(|e| format!("could not read tree for {}: {e}", commit.id()))?;

    let clean = path.trim_matches('/');
    let tree = if clean.is_empty() {
        root
    } else {
        let entry = root
            .get_path(std::path::Path::new(clean))
            .map_err(|_| format!("path '{path}' not found in this commit"))?;
        entry
            .to_object(repo.raw())
            .map_err(|e| format!("could not read '{path}': {e}"))?
            .into_tree()
            .map_err(|_| format!("'{path}' is a file, not a directory"))?
    };

    let mut entries = Vec::new();
    for entry in tree.iter() {
        let name = entry.name().unwrap_or("").to_string();
        if name.is_empty() {
            // A non-UTF-8 name we cannot address in a later request anyway.
            continue;
        }
        let child = if clean.is_empty() {
            name.clone()
        } else {
            format!("{clean}/{name}")
        };
        let kind = match entry.kind() {
            Some(git2::ObjectType::Tree) => "tree",
            _ => "blob",
        };
        entries.push(json!({
            "name": name,
            "path": child,
            "kind": kind,
            "oid": entry.id().to_string(),
        }));
    }

    Ok(json!({ "path": clean, "entries": entries }))
}

// ---------------------------------------------------------------------------
// Blob
// ---------------------------------------------------------------------------

/// File contents. Binary files return `binary:true` and empty content —
/// `SourceTab.qml` checks `binary` first and never reads `content` when it is
/// set, so no attempt is made to encode the bytes. That matches the seed's
/// behaviour and keeps a 40 MB PNG from crossing the QtRO boundary.
pub fn get_blob(home: &str, rid: &str, sha: &str, path: &str) -> String {
    match get_blob_inner(home, rid, sha, path) {
        Ok(v) => v.to_string(),
        Err(e) => crate::local::error(e),
    }
}

fn get_blob_inner(home: &str, rid: &str, sha: &str, path: &str) -> Result<Value, String> {
    if path.trim_matches('/').is_empty() {
        return Err("blob path is required".to_string());
    }
    let repo = open_repo(home, rid)?;
    let commit = resolve_commit(home, &repo, sha)?;
    let tree = commit
        .tree()
        .map_err(|e| format!("could not read tree for {}: {e}", commit.id()))?;

    blob_json(repo.raw(), &tree, path.trim_matches('/'))
}

/// Shared by `get_blob` and `get_readme`, which return the same shape.
fn blob_json(
    backend: &git2::Repository,
    tree: &git2::Tree<'_>,
    path: &str,
) -> Result<Value, String> {
    let entry = tree
        .get_path(std::path::Path::new(path))
        .map_err(|_| format!("file '{path}' not found in this commit"))?;
    let blob = entry
        .to_object(backend)
        .map_err(|e| format!("could not read '{path}': {e}"))?
        .into_blob()
        .map_err(|_| format!("'{path}' is a directory, not a file"))?;

    let name = std::path::Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(path)
        .to_string();

    // git2's own heuristic (a NUL byte in the first 8000 bytes), which is what
    // git itself uses to decide whether to show a diff. Deliberately reusing
    // it rather than inventing a second definition of "binary".
    if blob.is_binary() {
        return Ok(json!({
            "path": path,
            "name": name,
            "binary": true,
            "content": "",
        }));
    }

    // Non-UTF-8 bytes that still pass the NUL check: report as binary rather
    // than emitting a lossy string, since the view renders `content` verbatim
    // and replacement characters would look like file corruption.
    let content = match std::str::from_utf8(blob.content()) {
        Ok(s) => s.to_string(),
        Err(_) => {
            return Ok(json!({
                "path": path,
                "name": name,
                "binary": true,
                "content": "",
            }))
        }
    };

    Ok(json!({
        "path": path,
        "name": name,
        "binary": false,
        "content": content,
    }))
}

// ---------------------------------------------------------------------------
// README
// ---------------------------------------------------------------------------

/// Candidate README names, in the order the seed prefers them. Case matters on
/// the first pass; a case-insensitive sweep of the root tree follows.
const README_NAMES: &[&str] = &[
    "README.md",
    "README.markdown",
    "README.rst",
    "README.txt",
    "README",
    "readme.md",
    "Readme.md",
];

/// Rendered-source README for `sha`, or an error if the repo has none.
///
/// "No README" is an error, not an empty success: `SourceTab.qml` swallows the
/// failure silently ("plenty of repos have no README"), and an empty-string
/// success would instead render an empty README pane.
pub fn get_readme(home: &str, rid: &str, sha: &str) -> String {
    match get_readme_inner(home, rid, sha) {
        Ok(v) => v.to_string(),
        Err(e) => crate::local::error(e),
    }
}

fn get_readme_inner(home: &str, rid: &str, sha: &str) -> Result<Value, String> {
    let repo = open_repo(home, rid)?;
    let commit = resolve_commit(home, &repo, sha)?;
    let tree = commit
        .tree()
        .map_err(|e| format!("could not read tree for {}: {e}", commit.id()))?;

    for name in README_NAMES {
        if tree.get_name(name).is_some() {
            return blob_json(repo.raw(), &tree, name);
        }
    }

    // Anything else called `readme*` at the root, whatever its case.
    for entry in tree.iter() {
        let name = entry.name().unwrap_or("");
        if entry.kind() == Some(git2::ObjectType::Blob)
            && name.to_ascii_lowercase().starts_with("readme")
        {
            return blob_json(repo.raw(), &tree, name);
        }
    }

    Err("this repository has no README".to_string())
}

// ---------------------------------------------------------------------------
// Commits
// ---------------------------------------------------------------------------

/// Commit log from `sha` backwards, newest first.
/// -> `{"items":[<commit>],"page":N,"hasMore":bool}`
pub fn list_commits(home: &str, rid: &str, sha: &str, page: i64, per_page: i64) -> String {
    match list_commits_inner(home, rid, sha, page, per_page) {
        Ok(v) => v.to_string(),
        Err(e) => crate::local::error(e),
    }
}

fn list_commits_inner(
    home: &str,
    rid: &str,
    sha: &str,
    page: i64,
    per_page: i64,
) -> Result<Value, String> {
    let repo = open_repo(home, rid)?;
    let commit = resolve_commit(home, &repo, sha)?;
    let backend = repo.raw();

    let mut walk = backend
        .revwalk()
        .map_err(|e| format!("could not walk history: {e}"))?;
    // TIME alone is not enough: commits made within the same second (a script,
    // a test fixture, a rebase) compare equal and come back in an arbitrary
    // order, so a page boundary can duplicate or drop one. TOPOLOGICAL breaks
    // those ties by ancestry, which is the order a commit log actually means —
    // a child is never listed after its parent.
    walk.set_sorting(git2::Sort::TIME | git2::Sort::TOPOLOGICAL)
        .map_err(|e| format!("could not sort history: {e}"))?;
    walk.push(commit.id())
        .map_err(|e| format!("could not start history at {}: {e}", commit.id()))?;

    let start = (page.max(0) as usize).saturating_mul(per_page.max(0) as usize);
    let want = per_page.max(0) as usize;

    // Take one extra to learn whether a further page exists, rather than
    // walking the whole history to count it. `remoteListCommits` infers
    // `hasMore` from a full page instead, which can yield one empty final
    // page; reading locally is cheap enough to answer exactly.
    let mut items = Vec::with_capacity(want);
    let mut has_more = false;
    for (index, oid) in walk.enumerate() {
        let oid = oid.map_err(|e| format!("could not read history entry: {e}"))?;
        if index < start {
            continue;
        }
        if items.len() == want {
            has_more = true;
            break;
        }
        let c = backend
            .find_commit(oid)
            .map_err(|e| format!("could not read commit {oid}: {e}"))?;
        items.push(commit_summary(&c));
    }

    Ok(json!({ "items": items, "page": page, "hasMore": has_more }))
}

// ---------------------------------------------------------------------------
// One commit, with its diff
// ---------------------------------------------------------------------------

/// A single commit with its diff against its first parent (against the empty
/// tree for a root commit).
///
/// -> `{"commit":{...},"diff":{"files":[{"path","status","diff":{"hunks":[...]}}],
///      "stats":{"insertions","deletions"}}}`
pub fn get_commit(home: &str, rid: &str, sha: &str) -> String {
    match get_commit_inner(home, rid, sha) {
        Ok(v) => v.to_string(),
        Err(e) => crate::local::error(e),
    }
}

fn get_commit_inner(home: &str, rid: &str, sha: &str) -> Result<Value, String> {
    let repo = open_repo(home, rid)?;
    let backend = repo.raw();

    // Unlike the tree/blob calls, an unresolvable commit id here is a real
    // error rather than a fall-back to head: the caller clicked a specific
    // commit, and quietly showing a different one would be worse than saying
    // so.
    let commit = backend
        .revparse_single(sha)
        .and_then(|o| o.peel_to_commit())
        .map_err(|e| format!("could not resolve commit '{sha}': {e}"))?;

    let new_tree = commit
        .tree()
        .map_err(|e| format!("could not read tree for {}: {e}", commit.id()))?;
    let parent_tree = match commit.parent(0) {
        Ok(parent) => Some(
            parent
                .tree()
                .map_err(|e| format!("could not read parent tree: {e}"))?,
        ),
        // A root commit has no parent; diffing against None gives the whole
        // tree as additions, which is what the seed shows too.
        Err(_) => None,
    };

    let mut options = git2::DiffOptions::new();
    let diff = backend
        .diff_tree_to_tree(parent_tree.as_ref(), Some(&new_tree), Some(&mut options))
        .map_err(|e| format!("could not diff commit {}: {e}", commit.id()))?;

    let files = collect_diff(&diff)?;
    let stats = diff
        .stats()
        .map_err(|e| format!("could not compute diff stats: {e}"))?;

    Ok(json!({
        "commit": commit_summary(&commit),
        "diff": {
            "files": files,
            "stats": {
                "insertions": stats.insertions(),
                "deletions": stats.deletions(),
                "filesChanged": stats.files_changed(),
            },
        },
    }))
}

/// Walk a `git2::Diff` into the nested JSON `CommitView.qml` renders.
///
/// `git2::Diff::print`/`foreach` hand back a flat callback stream, so the
/// nesting (file -> hunk -> line) is rebuilt here by tracking the current file
/// and hunk as the stream advances.
fn collect_diff(diff: &git2::Diff<'_>) -> Result<Vec<Value>, String> {
    struct FileAcc {
        path: String,
        status: &'static str,
        hunks: Vec<HunkAcc>,
    }
    struct HunkAcc {
        header: String,
        lines: Vec<Value>,
    }

    // `Diff::foreach` takes three independent `FnMut` closures at once, so
    // they cannot each hold a `&mut` to the same accumulator. A `RefCell` moves
    // that check to runtime, which is sound here because git2 invokes the
    // callbacks one at a time from a single thread — no two borrows overlap.
    let files: std::cell::RefCell<Vec<FileAcc>> = std::cell::RefCell::new(Vec::new());

    diff.foreach(
        &mut |delta, _| {
            let mut files = files.borrow_mut();
            // `new_file` carries the post-change path; for a deletion it is
            // the old path that is meaningful, and git2 reports both, so
            // prefer new and fall back to old.
            let path = delta
                .new_file()
                .path()
                .or_else(|| delta.old_file().path())
                .map(|p| p.display().to_string())
                .unwrap_or_default();
            // Exactly the strings `CommitView.qml` colours on: "added" green,
            // "deleted" red, anything else neutral-but-displayed.
            let status = match delta.status() {
                git2::Delta::Added | git2::Delta::Untracked => "added",
                git2::Delta::Deleted => "deleted",
                git2::Delta::Renamed => "renamed",
                git2::Delta::Copied => "copied",
                _ => "modified",
            };
            files.push(FileAcc {
                path,
                status,
                hunks: Vec::new(),
            });
            true
        },
        None,
        Some(&mut |_, hunk| {
            let mut files = files.borrow_mut();
            if let Some(file) = files.last_mut() {
                file.hunks.push(HunkAcc {
                    header: String::from_utf8_lossy(hunk.header()).into_owned(),
                    lines: Vec::new(),
                });
            }
            true
        }),
        Some(&mut |_, _, line| {
            let mut files = files.borrow_mut();
            let Some(file) = files.last_mut() else {
                return true;
            };
            let Some(hunk) = file.hunks.last_mut() else {
                return true;
            };
            let kind = match line.origin() {
                '+' => "addition",
                '-' => "deletion",
                // Context, plus the no-newline-at-EOF marker and the file
                // headers, which the view renders as context lines.
                _ => "context",
            };
            let mut entry = Map::new();
            entry.insert("type".into(), json!(kind));
            entry.insert(
                "line".into(),
                json!(String::from_utf8_lossy(line.content()).into_owned()),
            );
            // Omitted rather than null when absent: `CommitView.qml` tests
            // `!== undefined`, so an explicit null would print the literal
            // text "null" in the gutter.
            if let Some(n) = line.old_lineno() {
                entry.insert("lineNoOld".into(), json!(n));
            }
            if let Some(n) = line.new_lineno() {
                entry.insert("lineNoNew".into(), json!(n));
            }
            hunk.lines.push(Value::Object(entry));
            true
        }),
    )
    .map_err(|e| format!("could not read diff: {e}"))?;

    Ok(files
        .into_inner()
        .into_iter()
        .map(|f| {
            json!({
                "path": f.path,
                "status": f.status,
                // The second `diff` level is not redundant: CommitView.qml
                // reads `files[].diff.hunks`, matching the seed's own shape.
                "diff": {
                    "hunks": f.hunks.into_iter().map(|h| json!({
                        "header": h.header,
                        "lines": h.lines,
                    })).collect::<Vec<_>>(),
                },
            })
        })
        .collect())
}
