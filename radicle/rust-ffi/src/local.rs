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
pub(crate) fn open_storage(home: &str) -> Result<Storage, String> {
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
    Storage::open(&storage_dir, info).map_err(|e| {
        format!(
            "failed to open Radicle storage at {}: {e}",
            storage_dir.display()
        )
    })
}

pub(crate) fn parse_rid(rid: &str) -> Result<RepoId, String> {
    RepoId::from_urn(rid).map_err(|e| format!("invalid repository id '{rid}': {e}"))
}

/// The local node's own id — the namespace this machine's branches live under.
///
/// Reads only `keys/radicle.pub`, the same public half `open_storage` already
/// reads, so no passphrase and no signer. `None` when the keystore is absent
/// or unreadable; every caller degrades rather than failing, because a missing
/// key is not a reason to refuse to render a repository.
pub(crate) fn local_node_id(home: &str) -> Option<radicle::node::NodeId> {
    if home.is_empty() {
        return None;
    }
    let keys_dir = std::path::Path::new(home).join("keys");
    Keystore::new(&keys_dir).public_key().ok().flatten()
}

pub(crate) fn error(msg: impl Into<String>) -> String {
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
    let project: radicle::identity::Project = serde_json::from_value(project.clone().into_inner())
        .map_err(|e| format!("malformed project payload for {rid}: {e}"))?;

    let (_, head) = repo
        .head()
        .map_err(|e| format!("could not resolve head for {rid}: {e}"))?;

    // Counts default to zero rather than failing the whole repo view: a repo
    // with no issues/patches store yet (never opened locally before) is not
    // an error, just empty.
    let issue_counts =
        radicle::cob::issue::Issues::open(&repo, radicle::cob::store::access::ReadOnly)
            .ok()
            .and_then(|issues| issues.counts().ok())
            .unwrap_or_default();
    let patch_counts =
        radicle::cob::patch::Patches::open(&repo, radicle::cob::store::access::ReadOnly)
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

    // `Visibility` derives `tag = "type"` + camelCase, so this serializes to
    // exactly `{"type":"private",...}` / `{"type":"public"}` — the shape
    // `RepoList.qml` checks with `visibility.type === "private"` to decide
    // whether to draw the private badge.
    let visibility = serde_json::to_value(doc.visibility()).unwrap_or_else(|_| json!({}));
    let delegates: Vec<Value> = doc
        .delegates()
        .iter()
        .map(|did| json!({ "id": did.to_string() }))
        .collect();

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
        "delegates": delegates,
        "visibility": visibility,
        "threshold": doc.threshold(),
        "refs": { "refs": Value::Object(refs), "tags": Value::Object(tags) },
    }))
}

/// Every branch in local storage, the local node's own first.
///
/// **Why this is a dedicated entry point and not derived from `get_repo`.**
/// `localListBranches` used to filter `get_repo`'s `refs.refs` map, exactly as
/// `SeedClient::listBranches` filters the seed's — one filter, one shape, no
/// drift. That worked only because both sides were reporting the same thing:
/// the *canonical* `refs/heads/*`. They are not the same thing. In local
/// storage every peer's branches — including your own — live under
/// `refs/namespaces/<nid>/refs/heads/*`, and the unnamespaced `refs/heads/*`
/// holds a single delegate-consensus ref. Globbing it returned exactly one
/// branch for every repository on the machine, which is what the picker showed.
///
/// Namespaced refs cannot simply be poured into `refs.refs` instead:
/// `resolveSha` (both here and in `seed_client.cpp`) reads that same map to
/// turn a ref name into a commit, so widening it would change what an
/// unqualified branch name resolves to. The map keeps its canonical meaning;
/// branches get their own reply shape.
///
/// The reply is `{"items":[{name,label,head,remote,isLocal}],"default":"..."}`:
///
/// - the local node's branches come first, `isLocal: true`, and their `name`
///   is the bare branch (`main`) so it resolves exactly as it did before;
/// - every other peer's branches follow, `name` fully qualified
///   (`<nid>/<branch>`) so it cannot collide with a local branch of the same
///   name, and `label` abbreviated for display.
///
/// Order is load-bearing: the picker draws a separator at the first entry
/// whose `isLocal` is false, so "yours" and "theirs" stay visually distinct.
pub fn list_branches(home: &str, rid: &str) -> String {
    match list_branches_inner(home, rid) {
        Ok(v) => v.to_string(),
        Err(e) => error(e),
    }
}

/// Shorten a node ID for display: `z6Mkire…`. The full id stays in `name`,
/// which is what every subsequent read is keyed on — only the label shrinks.
fn abbreviate_nid(nid: &str) -> String {
    // 8 chars is enough to tell this machine's handful of peers apart while
    // still fitting the picker's 140px. Collisions are a display concern
    // only; `name` is never abbreviated.
    match nid.char_indices().nth(8) {
        Some((idx, _)) => format!("{}…", &nid[..idx]),
        None => nid.to_string(),
    }
}

fn list_branches_inner(home: &str, rid: &str) -> Result<Value, String> {
    let storage = open_storage(home)?;
    let id = parse_rid(rid)?;
    let repo = storage
        .repository(id)
        .map_err(|e| format!("repository {rid} not found locally: {e}"))?;

    let doc = repo
        .identity_doc()
        .map_err(|e| format!("could not read identity document for {rid}: {e}"))?;
    let doc = radicle::identity::doc::Doc::from(doc);
    let default_branch = doc
        .payload()
        .get(&radicle::identity::doc::PayloadId::project().clone())
        .and_then(|p| {
            serde_json::from_value::<radicle::identity::Project>(p.clone().into_inner()).ok()
        })
        .map(|p| p.default_branch().to_string())
        .unwrap_or_default();

    // The local node's own key — the namespace "your" branches live under.
    // Shared with `resolve_commit`, which needs the same id to look those
    // branches up again, so there is one definition rather than two that could
    // disagree about which namespace is "mine".
    let local_key = local_node_id(home);

    let mut local_items: Vec<Value> = Vec::new();
    let mut peer_items: Vec<Value> = Vec::new();

    // `remotes()` enumerates the peers whose refs this node holds, each with
    // its signed ref set already replayed — no raw namespace globbing, and no
    // risk of picking up `rad/sigrefs`, `cobs/*` or other plumbing that a
    // `refs/namespaces/*` glob would also match.
    let remotes = radicle::storage::RemoteRepository::remotes(&repo)
        .map_err(|e| format!("could not list remotes for {rid}: {e}"))?;

    for (nid, remote) in remotes {
        // `unwrap_or(false)` degrades to "everything is a peer's", which would
        // put the user's own branches below a divider that then has nothing
        // above it. Tolerable *because it cannot normally happen*:
        // `open_storage` above reads the very same key and has already
        // returned an error if it could not, so reaching here with `None`
        // means the keystore vanished between two reads a few microseconds
        // apart. Listing branches unlabelled beats refusing to render the
        // repository over it.
        let is_local = local_key.map(|k| k == nid).unwrap_or(false);
        let nid_str = nid.to_string();

        for (refname, oid) in remote.refs.iter() {
            let Some(branch) = refname
                .to_string()
                .strip_prefix("refs/heads/")
                .map(String::from)
            else {
                continue; // tags, rad/*, cobs/* — not branches
            };

            // `refs/heads/patches/<patch-id>` is where a patch's head is
            // published — a code review, not a branch someone works on. On a
            // real profile these dominate: heartwood's five peers contribute
            // 658 refs under `refs/heads/`, of which all but ~20 are patch
            // refs. Listing them would bury the actual branches and make the
            // picker useless, which is the same argument `branchesFrom`
            // already makes for keeping tags out. Patches have their own tab.
            if branch.starts_with("patches/") {
                continue;
            }

            let entry = if is_local {
                json!({
                    "name": branch,
                    "label": branch,
                    "head": oid.to_string(),
                    "remote": nid_str,
                    "isLocal": true,
                })
            } else {
                json!({
                    "name": format!("{nid_str}/{branch}"),
                    "label": format!("{}/{branch}", abbreviate_nid(&nid_str)),
                    "head": oid.to_string(),
                    "remote": nid_str,
                    "isLocal": false,
                })
            };

            if is_local {
                local_items.push(entry);
            } else {
                peer_items.push(entry);
            }
        }
    }

    // Within each group, order by `name` so the list is stable across runs.
    // `remotes()` yields a `RandomMap` whose iteration order genuinely differs
    // per process, so without a sort the picker reshuffles between launches.
    //
    // Sorted on `name`, not `label`: labels carry an abbreviated node id, so
    // two peers sharing a `z6MkPeer…` prefix produce identical labels for the
    // same branch name. `sort_by_key` is stable, which would then preserve the
    // randomized map order between them — a total order on the unabbreviated
    // `name` avoids that entirely.
    let sort_key = |v: &Value| v["name"].as_str().unwrap_or("").to_string();
    local_items.sort_by_key(sort_key);
    peer_items.sort_by_key(sort_key);

    local_items.extend(peer_items);

    Ok(json!({
        "items": local_items,
        "default": default_branch,
    }))
}

/// Repos in local storage, narrowed by `scope`:
///
/// - `"delegate"` — repos this node is a delegate of, i.e. ones you can sign
///   changes to. Determined by matching the local node's own key against the
///   identity document's delegate list.
/// - `"private"` — repos whose identity document marks them private. These are
///   the ones a seed will never show, so this is the scope that justifies
///   local browsing existing at all.
/// - `"seeded"` — repos held in local storage that you are neither a delegate
///   of nor which are private: replicated copies of other people's public work.
/// - `"all"`, `""` or anything else — no filtering.
///
/// The scopes partition the set (a repo is delegate, else private, else
/// seeded), so a UI can offer them as exclusive chips without a repo showing
/// up twice or vanishing.
pub fn list_repos(home: &str, scope: &str, page: i64, per_page: i64) -> String {
    match list_repos_inner(home, scope, page, per_page) {
        Ok(v) => v.to_string(),
        Err(e) => error(e),
    }
}

fn list_repos_inner(home: &str, scope: &str, page: i64, per_page: i64) -> Result<Value, String> {
    let storage = open_storage(home)?;

    // The local node's own key: what "delegate" is measured against. Read from
    // the public half of the keystore only — same file `open_storage` already
    // reads, no passphrase.
    let keys_dir = std::path::Path::new(home).join("keys");
    let local_key = Keystore::new(&keys_dir).public_key().ok().flatten();

    let mut infos = storage
        .repositories()
        .map_err(|e| format!("could not list local repositories: {e}"))?;

    infos.retain(|info| {
        let is_delegate = local_key
            .map(|key| {
                let me = radicle::identity::Did::from(key);
                info.doc.delegates().iter().any(|d| *d == me)
            })
            .unwrap_or(false);
        let is_private = info.doc.visibility().is_private();

        match scope {
            "delegate" => is_delegate,
            "private" => is_private,
            "seeded" => !is_delegate && !is_private,
            // "all", "", and any unrecognized value: everything. An unknown
            // scope showing all repos beats it showing none, which would look
            // identical to an empty node.
            _ => true,
        }
    });

    infos.sort_by_key(|info| info.rid);

    // Saturating rather than plain arithmetic throughout. `page` and
    // `per_page` cross the FFI boundary as raw i64s from a caller this crate
    // does not control, and `page * per_page` on two large values panics in a
    // debug build. A panic here would unwind across the `extern "C"` boundary,
    // which is undefined behaviour — not merely a bad answer. Saturating to
    // "past the end" instead yields an empty page, which is the right answer
    // for an absurd page number anyway.
    let start = (page.max(0) as usize).saturating_mul(per_page.max(0) as usize);
    let end = start.saturating_add(per_page.max(0) as usize);
    let has_more = infos.len() > end;
    let page_infos = infos
        .into_iter()
        .skip(start)
        .take(end.saturating_sub(start));

    // One unreadable repository must not sink the whole list — the same rule
    // `cobs.rs` applies to COBs, and it matters more here because this is the
    // entry screen. A local node accumulates partially-replicated repos, and
    // `collect::<Result<_,_>>()` is fail-fast: a single malformed identity
    // document or unresolvable head would replace every row with one error,
    // with no way to tell which repo was at fault.
    let items: Vec<Value> = page_infos
        .filter_map(|info| get_repo_inner(home, &info.rid.urn()).ok())
        .collect();

    Ok(json!({
        "items": items,
        "page": page,
        "hasMore": has_more,
    }))
}
