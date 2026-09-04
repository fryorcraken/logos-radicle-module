//! Issues and patches, read out of Collaborative Objects.
//!
//! COBs are not plain git objects: each is a DAG of signed operations under
//! `refs/cobs/<typename>/<id>/...`, replayed into current state. The crate
//! does that replay, so this module only has to open the store and shape the
//! result — `Issues::open(&repo, ReadOnly)` / `Patches::open(&repo, ReadOnly)`.
//! `ReadOnly` is a unit struct requiring no signer, so nothing here can
//! prompt for a passphrase or touch the private key.
//!
//! Deliberately no SQLite cache. `~/.radicle/cache/cobs.db` is the `rad` CLI's
//! read-through optimization for its own use, not a dependency of other
//! readers; going straight to the refs means this module owns no database
//! file's lifecycle and cannot fight the CLI over one.
//!
//! **Timestamps are converted, not passed through.** A COB `Timestamp`
//! serializes as milliseconds, but `Radicle.js`'s `when()` does
//! `new Date(t * 1000)` — feeding it the raw value renders every date in the
//! year 57000. `secs()` below is the conversion, and there is a test that
//! pins a comment timestamp to a plausible year for exactly this reason.

use radicle::cob::store::access::ReadOnly;
use radicle::cob::{issue, patch, thread};
use radicle::storage::git::Repository;
use serde_json::{json, Value};

use crate::local::error;

/// Milliseconds -> seconds. See the module note: this is the one unit
/// conversion on the whole boundary and getting it wrong is silent.
fn secs(t: radicle::cob::Timestamp) -> u64 {
    // `Timestamp` derefs to `LocalTime`, whose `as_secs` is the seconds the
    // views want.
    t.as_secs()
}

/// `{alias?, name?, id}` — the shape `Radicle.js`'s `authorName()` reads,
/// trying `alias`, then `name`, then a shortened `id` with the `did:key:`
/// prefix stripped. COBs record only the DID, so `id` is all there is; the
/// view falls through to it and shows a short key, which is what the seed
/// shows for a node with no alias either.
fn author(did: &radicle::identity::Did) -> Value {
    json!({ "id": did.to_string() })
}

fn author_key(key: &radicle::crypto::PublicKey) -> Value {
    json!({ "id": radicle::identity::Did::from(*key).to_string() })
}

/// A discussion thread flattened to the array `ThreadView.qml` renders.
///
/// The view draws a flat list — it reads no `replyTo` and does no nesting —
/// so replies are emitted inline in thread order rather than dropped. Dropping
/// them would silently hide most of a real conversation.
fn discussion<T>(thread: &thread::Thread<thread::Comment<T>>) -> Vec<Value>
where
    T: Clone + PartialEq + Eq + std::fmt::Debug,
{
    thread
        .comments()
        .map(|(id, comment)| {
            json!({
                "id": id.to_string(),
                "author": author_key(comment.author()),
                "body": comment.body(),
                "timestamp": secs(comment.timestamp()),
            })
        })
        .collect()
}

fn open_issues(repo: &Repository) -> Result<issue::Issues<'_, Repository, ReadOnly>, String> {
    issue::Issues::open(repo, ReadOnly).map_err(|e| format!("could not open the issue store: {e}"))
}

fn open_patches(repo: &Repository) -> Result<patch::Patches<'_, Repository, ReadOnly>, String> {
    patch::Patches::open(repo, ReadOnly).map_err(|e| format!("could not open the patch store: {e}"))
}

fn parse_object_id(id: &str) -> Result<radicle::cob::ObjectId, String> {
    id.parse::<radicle::cob::ObjectId>()
        .map_err(|e| format!("invalid object id '{id}': {e}"))
}

/// `{"status":"open"}` / `{"status":"closed","reason":...}` — produced by the
/// crate's own serde derive (`tag = "status"`, camelCase), which is the same
/// representation the seed serves. `StatusBadge.qml` branches on
/// `state.status`, so this must stay a nested object, not a bare string.
fn state_value<S: serde::Serialize>(state: &S) -> Value {
    serde_json::to_value(state).unwrap_or_else(|_| json!({}))
}

/// One page of a sorted, filtered list, plus whether more follow.
///
/// `items` carries `(timestamp, id, value)` so the sort has a tiebreaker; see
/// below for why the id is not optional.
fn paginate(mut items: Vec<(u64, String, Value)>, page: i64, per_page: i64) -> Value {
    // Newest first, matching the seed's ordering — the views show no sort
    // control, so this ordering *is* the contract.
    //
    // The id breaks ties, and that is load-bearing rather than tidiness.
    // `secs()` truncates to whole seconds, so anything filed in the same
    // second compares equal; ties would then fall back to the order
    // `store.all()` happened to walk the git refs in, which the crate does not
    // guarantee. Each page is a SEPARATE FFI call that re-reads storage from
    // scratch, so two calls could order a tied group differently and an item
    // could land on both pages or on neither. This is the same failure
    // `gitread.rs` guards against for commits with TIME | TOPOLOGICAL.
    items.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));

    let start = (page.max(0) as usize).saturating_mul(per_page.max(0) as usize);
    let want = per_page.max(0) as usize;
    let has_more = items.len() > start.saturating_add(want);

    let page_items: Vec<Value> = items
        .into_iter()
        .skip(start)
        .take(want)
        .map(|(_, _, v)| v)
        .collect();

    json!({ "items": page_items, "page": page, "hasMore": has_more })
}

// ---------------------------------------------------------------------------
// Issues
// ---------------------------------------------------------------------------

/// Issues. `status` is "open" | "closed" | "" (all).
pub fn list_issues(home: &str, rid: &str, status: &str, page: i64, per_page: i64) -> String {
    match list_issues_inner(home, rid, status, page, per_page) {
        Ok(v) => v.to_string(),
        Err(e) => error(e),
    }
}

fn list_issues_inner(
    home: &str,
    rid: &str,
    status: &str,
    page: i64,
    per_page: i64,
) -> Result<Value, String> {
    let repo = crate::gitread::open_repo_pub(home, rid)?;
    let store = open_issues(&repo)?;

    let mut items = Vec::new();
    for entry in store
        .all()
        .map_err(|e| format!("could not list issues: {e}"))?
    {
        // One unreadable COB must not sink the whole list: a repo replicated
        // mid-write can carry an operation this version cannot replay, and
        // showing the rest beats showing an error page.
        let Ok((id, issue)) = entry else { continue };

        let matches = match status {
            "open" => matches!(issue.state(), issue::State::Open),
            "closed" => matches!(issue.state(), issue::State::Closed { .. }),
            _ => true,
        };
        if !matches {
            continue;
        }

        let timestamp = secs(issue.timestamp());
        items.push((
            timestamp,
            id.to_string(),
            json!({
                "id": id.to_string(),
                "title": issue.title(),
                "author": author(&issue.author().id),
                "state": state_value(issue.state()),
                "timestamp": timestamp,
            }),
        ));
    }

    Ok(paginate(items, page, per_page))
}

/// One issue including its full discussion thread.
pub fn get_issue(home: &str, rid: &str, id: &str) -> String {
    match get_issue_inner(home, rid, id) {
        Ok(v) => v.to_string(),
        Err(e) => error(e),
    }
}

fn get_issue_inner(home: &str, rid: &str, id: &str) -> Result<Value, String> {
    let repo = crate::gitread::open_repo_pub(home, rid)?;
    let store = open_issues(&repo)?;
    let oid = parse_object_id(id)?;

    let issue = store
        .get(&oid)
        .map_err(|e| format!("could not read issue {id}: {e}"))?
        .ok_or_else(|| format!("issue {id} not found in this repository"))?;

    Ok(json!({
        "id": id,
        "title": issue.title(),
        "author": author(&issue.author().id),
        "state": state_value(issue.state()),
        "timestamp": secs(issue.timestamp()),
        "discussion": discussion(issue.thread()),
    }))
}

// ---------------------------------------------------------------------------
// Patches
// ---------------------------------------------------------------------------

/// Patches. `status` is "open" | "merged" | "archived" | "draft" | "" (all).
pub fn list_patches(home: &str, rid: &str, status: &str, page: i64, per_page: i64) -> String {
    match list_patches_inner(home, rid, status, page, per_page) {
        Ok(v) => v.to_string(),
        Err(e) => error(e),
    }
}

fn list_patches_inner(
    home: &str,
    rid: &str,
    status: &str,
    page: i64,
    per_page: i64,
) -> Result<Value, String> {
    let repo = crate::gitread::open_repo_pub(home, rid)?;
    let store = open_patches(&repo)?;

    let mut items = Vec::new();
    for entry in store
        .all()
        .map_err(|e| format!("could not list patches: {e}"))?
    {
        let Ok((id, patch)) = entry else { continue };

        let matches = match status {
            "open" => matches!(patch.state(), patch::State::Open { .. }),
            "merged" => matches!(patch.state(), patch::State::Merged { .. }),
            "archived" => matches!(patch.state(), patch::State::Archived),
            "draft" => matches!(patch.state(), patch::State::Draft),
            _ => true,
        };
        if !matches {
            continue;
        }

        let timestamp = secs(patch.timestamp());
        items.push((
            timestamp,
            id.to_string(),
            json!({
                "id": id.to_string(),
                "title": patch.title(),
                "author": author(&patch.author().id),
                "state": state_value(patch.state()),
                "timestamp": timestamp,
            }),
        ));
    }

    Ok(paginate(items, page, per_page))
}

/// One patch including its revisions.
///
/// `ThreadView.qml` renders a patch's *root* discussion plus a revision count,
/// reading only `revisions[].id` and `revisions[].author`. Per-revision
/// discussion threads and reviews are not rendered anywhere in the UI today,
/// so they are not serialized — adding them would put unread data across the
/// QtRO boundary for every patch open.
pub fn get_patch(home: &str, rid: &str, id: &str) -> String {
    match get_patch_inner(home, rid, id) {
        Ok(v) => v.to_string(),
        Err(e) => error(e),
    }
}

fn get_patch_inner(home: &str, rid: &str, id: &str) -> Result<Value, String> {
    let repo = crate::gitread::open_repo_pub(home, rid)?;
    let store = open_patches(&repo)?;
    let oid = parse_object_id(id)?;

    let patch = store
        .get(&oid)
        .map_err(|e| format!("could not read patch {id}: {e}"))?
        .ok_or_else(|| format!("patch {id} not found in this repository"))?;

    let revisions: Vec<Value> = patch
        .revisions()
        .map(|(rev_id, revision)| {
            json!({
                "id": rev_id.to_string(),
                "author": author(&revision.author().id),
                "description": revision.description(),
                "base": revision.base().to_string(),
                "oid": revision.head().to_string(),
                "timestamp": secs(revision.timestamp()),
            })
        })
        .collect();

    // A patch's own "discussion" is the first revision's thread — a patch has
    // no separate root thread of its own, unlike an issue.
    let root_discussion = patch
        .revisions()
        .next()
        .map(|(_, revision)| discussion(revision.discussion()))
        .unwrap_or_default();

    Ok(json!({
        "id": id,
        "title": patch.title(),
        "author": author(&patch.author().id),
        "state": state_value(patch.state()),
        "timestamp": secs(patch.timestamp()),
        "discussion": root_discussion,
        "revisions": revisions,
    }))
}
