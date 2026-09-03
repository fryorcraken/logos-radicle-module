//! Local-storage reading logic, pure Rust — no C, no pointers. Every
//! function returns a JSON string, `{"error":"..."}` on failure, matching the
//! contract `radicle_impl.h` documents for every module method. Tested
//! directly with `cargo test` against scratch profiles built through the
//! crate's *public* API (`Profile::init` + `rad::init`; see
//! `tests/local_storage.rs`) — `radicle::test` is crate-internal and not
//! reachable as a dev-dependency. No FFI boundary involved.
//!
//! Shape note: `remoteGetRepo` et al. proxy radicle-httpd's `/api/v1` JSON,
//! whose exact serialization lives in a separate repository (radicle-httpd)
//! not vendored here. This module reconstructs the fields confirmed against
//! `radicle/tests/test_seed_client.cpp`'s fixture (`rid`, `payloads.
//! xyz.radicle.project.data.{name,description,defaultBranch}`,
//! `payloads.xyz.radicle.project.meta.head`, `refs.refs.<ref-name>`) rather
//! than assuming a 1:1 serde derive on `identity::Doc` — the seed's `meta`
//! block (head SHA, issue/patch counts) is computed, not stored in the
//! identity document itself.

use radicle::crypto::ssh::Keystore;
use radicle::git::UserInfo;
use radicle::identity::RepoId;
use radicle::node::Alias;
use radicle::prelude::ReadRepository;
use radicle::storage::git::Storage;
use radicle::storage::ReadStorage;
use serde_json::{json, Value};

/// Open local storage at `home` (an explicit path — the caller, i.e.
/// `local_store.cpp`, is responsible for RAD_HOME/HOME resolution so there is
/// exactly one place that logic lives, matching `LocalStore::home()`).
///
/// This mirrors what `radicle::Profile::load()` does internally, minus its
/// use of the global `RAD_HOME`/`HOME` env lookup (redundant with the
/// resolution the C++ side already did) and minus `Home::new()`'s
/// directory-creation, which a read-only browse should never trigger.
///
/// `UserInfo.key` is the local node's real public key — required by
/// `Storage::open`'s type, and used when *signing*, which this module never
/// does. Reading it needs only `keys/radicle.pub`, no passphrase: the
/// private key stays encrypted on disk and is never touched.
fn open_storage(home: &str) -> Result<Storage, String> {
    if home.is_empty() {
        return Err("no Radicle home given".to_string());
    }
    let keys_dir = std::path::Path::new(home).join("keys");
    let key = Keystore::new(&keys_dir)
        .public_key()
        .map_err(|e| format!("could not read local node key: {e}"))?
        .ok_or_else(|| format!("no Radicle key found at {}", keys_dir.display()))?;

    let info = UserInfo {
        alias: Alias::new("local"),
        key,
    };
    // Repos live under `<home>/storage`, matching `LocalStore`'s own
    // `home() + "/storage"` marker check on the C++ side.
    let storage_dir = std::path::Path::new(home).join("storage");
    Storage::open(&storage_dir, info)
        .map_err(|e| format!("failed to open Radicle storage at {}: {e}", storage_dir.display()))
}

fn parse_rid(rid: &str) -> Result<RepoId, String> {
    RepoId::from_urn(rid).map_err(|e| format!("invalid repository id '{rid}': {e}"))
}

fn error(msg: impl Into<String>) -> String {
    json!({ "error": msg.into() }).to_string()
}

/// One repo's metadata, matching `remoteGetRepo`'s shape:
/// `{"rid","payloads":{"xyz.radicle.project":{"data":{...},"meta":{...}}},"refs":{"refs":{...},"tags":{}}}`.
pub fn get_repo(home: &str, rid: &str) -> String {
    match get_repo_inner(home, rid) {
        Ok(v) => v.to_string(),
        Err(e) => error(e),
    }
}

fn get_repo_inner(home: &str, rid: &str) -> Result<Value, String> {
    let storage = open_storage(home)?;
    let id = parse_rid(rid)?;

    let repo = storage
        .repository(id)
        .map_err(|e| format!("repository {rid} not found locally: {e}"))?;

    let doc = repo
        .identity_doc()
        .map_err(|e| format!("could not read identity document for {rid}: {e}"))?;
    let doc = radicle::identity::doc::Doc::from(doc);

    let project = doc
        .payload()
        .get(&radicle::identity::doc::PayloadId::project().clone())
        .ok_or_else(|| format!("{rid} has no project payload"))?;
    let project: radicle::identity::Project =
        serde_json::from_value(project.clone().into_inner())
            .map_err(|e| format!("malformed project payload for {rid}: {e}"))?;

    let (_, head) = repo
        .head()
        .map_err(|e| format!("could not resolve head for {rid}: {e}"))?;

    // Counts default to zero rather than failing the whole repo view: a repo
    // with no issues/patches store yet (never opened locally before) is not
    // an error, just empty.
    let issue_counts = radicle::cob::issue::Issues::open(&repo, radicle::cob::store::access::ReadOnly)
        .ok()
        .and_then(|issues| issues.counts().ok())
        .unwrap_or_default();
    let patch_counts = radicle::cob::patch::Patches::open(&repo, radicle::cob::store::access::ReadOnly)
        .ok()
        .and_then(|patches| patches.counts().ok())
        .unwrap_or_default();

    // Only `refs/heads/*` and `refs/tags/*` — matching the seed's shape,
    // which reports this repo's own canonical branches/tags, not the
    // internal namespaced/COB/sigrefs plumbing a raw `git2` ref walk would
    // also turn up (`refs/namespaces/<nid>/...`, `refs/cobs/...`, etc.).
    let heads_pattern = radicle::git::fmt::refspec::PatternStr::try_from_str("refs/heads/*")
        .expect("'refs/heads/*' is a valid refspec pattern");
    let heads = repo
        .references_glob(heads_pattern)
        .map_err(|e| format!("could not list branches for {rid}: {e}"))?;
    let mut refs = serde_json::Map::new();
    for (name, oid) in heads {
        refs.insert(name.to_string(), json!(oid.to_string()));
    }

    let tags_pattern = radicle::git::fmt::refspec::PatternStr::try_from_str("refs/tags/*")
        .expect("'refs/tags/*' is a valid refspec pattern");
    let tag_refs = repo
        .references_glob(tags_pattern)
        .map_err(|e| format!("could not list tags for {rid}: {e}"))?;
    let mut tags = serde_json::Map::new();
    for (name, oid) in tag_refs {
        tags.insert(name.to_string(), json!(oid.to_string()));
    }

    Ok(json!({
        "rid": id.urn(),
        "payloads": {
            "xyz.radicle.project": {
                "data": {
                    "name": project.name(),
                    "description": project.description(),
                    "defaultBranch": project.default_branch().to_string(),
                },
                "meta": {
                    "head": head.to_string(),
                    "issues": { "open": issue_counts.open, "closed": issue_counts.closed },
                    "patches": {
                        "open": patch_counts.open,
                        "draft": patch_counts.draft,
                        "archived": patch_counts.archived,
                        "merged": patch_counts.merged,
                    },
                },
            }
        },
        "refs": { "refs": Value::Object(refs), "tags": Value::Object(tags) },
    }))
}

/// Repos in local storage. `scope` is accepted for shape-parity with
/// `remoteListRepos`'s pagination envelope but not yet filtered by
/// delegate/private/seeded — every repo `storage.repositories()` returns is
/// listed. Narrowing by scope is follow-up work, not implemented this pass.
pub fn list_repos(home: &str, _scope: &str, page: i64, per_page: i64) -> String {
    match list_repos_inner(home, page, per_page) {
        Ok(v) => v.to_string(),
        Err(e) => error(e),
    }
}

fn list_repos_inner(home: &str, page: i64, per_page: i64) -> Result<Value, String> {
    let storage = open_storage(home)?;

    let mut infos = storage
        .repositories()
        .map_err(|e| format!("could not list local repositories: {e}"))?;
    infos.sort_by_key(|info| info.rid);

    let start = (page.max(0) as usize) * (per_page.max(0) as usize);
    let end = per_page
        .max(0)
        .checked_add(start as i64)
        .map(|v| v as usize)
        .unwrap_or(infos.len());
    let has_more = infos.len() > end;
    let page_infos = infos.into_iter().skip(start).take(end.saturating_sub(start));

    let items: Result<Vec<Value>, String> = page_infos
        .map(|info| get_repo_inner(home, &info.rid.urn()))
        .collect();

    Ok(json!({
        "items": items?,
        "page": page,
        "hasMore": has_more,
    }))
}
