//! Issue and patch reads, against Collaborative Objects actually written into
//! a real repository.
//!
//! These are written through the crate's own write API (`Issues::create` with
//! `WriteAs` access) so the objects under test are real COBs — a signed
//! operation DAG under `refs/cobs/...` that the read path has to replay —
//! rather than hand-built JSON that would prove nothing about the replay.
//!
//! The read path itself uses `ReadOnly` access and `NoCache`, so these tests
//! also demonstrate the property M2.1 depends on: reading needs no signer and
//! no SQLite cache file.

mod fixture;

use fixture::{init_profile, init_repo, parse, Fixture};

use radicle::cob::issue::Issues;
use radicle::cob::patch::Patches;
use radicle::cob::store::access::WriteAs;
use radicle::storage::ReadStorage as _;

/// Open the repo for writing and create `count` issues, returning their ids
/// oldest-first. The titles are `"issue N"`.
fn create_issues(f: &Fixture, rid: &str, count: usize) -> Vec<String> {
    let id = radicle::identity::RepoId::from_urn(rid).expect("valid rid");
    let repo = f.profile.storage.repository(id).expect("repo in storage");
    let signer = f.profile.signer().expect("signer");

    let mut ids = Vec::new();
    for n in 1..=count {
        let mut store = Issues::open(&repo, WriteAs::new(&signer)).expect("open issues for write");
        let mut cache = radicle::cob::cache::NoCache;
        let issue = store
            .create(
                format!("issue {n}").parse().expect("valid title"),
                format!("the body of issue {n}"),
                &[],
                &[],
                [],
                &mut cache,
            )
            .expect("could not create issue");
        ids.push(issue.id().to_string());
    }
    ids
}

#[test]
fn list_issues_returns_the_fields_the_view_reads() {
    let f = init_profile("issues-list");
    let (rid, _) = init_repo(&f, "issue-repo", "issues");
    let created = create_issues(&f, &rid, 2);

    let v = parse(&radicle_local_ffi::cobs::list_issues(
        &f.home(),
        &rid,
        "",
        0,
        10,
    ));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    let items = v["items"].as_array().expect("items array");
    assert_eq!(items.len(), 2, "both issues listed: {v}");

    let titles: Vec<&str> = items.iter().filter_map(|i| i["title"].as_str()).collect();
    assert!(titles.contains(&"issue 1"), "got {titles:?}");
    assert!(titles.contains(&"issue 2"), "got {titles:?}");

    // `id` is what IssuesTab emits on click and ThreadView passes to
    // GetIssue, so it must round-trip exactly.
    let ids: Vec<&str> = items.iter().filter_map(|i| i["id"].as_str()).collect();
    for id in &created {
        assert!(
            ids.contains(&id.as_str()),
            "issue {id} missing from {ids:?}"
        );
    }

    // `state` is a nested object, not a bare string: StatusBadge.qml reads
    // `state.status`. A plain string here would hide every badge.
    assert_eq!(items[0]["state"]["status"], "open", "got {v}");

    // The avatar and byline both come off `author.id`, which must be a DID.
    let author_id = items[0]["author"]["id"]
        .as_str()
        .expect("author.id should be a string");
    assert!(
        author_id.starts_with("did:key:"),
        "author.id should be a DID: {author_id}"
    );
}

#[test]
fn list_issues_filters_by_status() {
    let f = init_profile("issues-filter");
    let (rid, _) = init_repo(&f, "issue-repo", "issues");
    let ids = create_issues(&f, &rid, 2);

    // Close the first one.
    let repo_id = radicle::identity::RepoId::from_urn(&rid).expect("rid");
    let repo = f.profile.storage.repository(repo_id).expect("repo");
    let signer = f.profile.signer().expect("signer");
    {
        let mut store = Issues::open(&repo, WriteAs::new(&signer)).expect("open for write");
        let mut cache = radicle::cob::cache::NoCache;
        let oid = ids[0].parse().expect("object id");
        let mut issue = store.get_mut(&oid, &mut cache).expect("get issue");
        issue
            .lifecycle(radicle::cob::issue::State::Closed {
                reason: radicle::cob::issue::CloseReason::Other,
            })
            .expect("could not close issue");
    }

    let open = parse(&radicle_local_ffi::cobs::list_issues(
        &f.home(),
        &rid,
        "open",
        0,
        10,
    ));
    let open_items = open["items"].as_array().expect("items");
    assert_eq!(open_items.len(), 1, "one issue left open: {open}");
    assert_eq!(open_items[0]["title"], "issue 2");
    assert_eq!(open_items[0]["state"]["status"], "open");

    let closed = parse(&radicle_local_ffi::cobs::list_issues(
        &f.home(),
        &rid,
        "closed",
        0,
        10,
    ));
    let closed_items = closed["items"].as_array().expect("items");
    assert_eq!(closed_items.len(), 1, "one issue closed: {closed}");
    assert_eq!(closed_items[0]["title"], "issue 1");
    // "closed" is the exact string StatusBadge.qml colours red on.
    assert_eq!(closed_items[0]["state"]["status"], "closed");

    // An empty status means "all", matching the remote surface's contract.
    let all = parse(&radicle_local_ffi::cobs::list_issues(
        &f.home(),
        &rid,
        "",
        0,
        10,
    ));
    assert_eq!(all["items"].as_array().expect("items").len(), 2);
}

#[test]
fn list_issues_paginates() {
    let f = init_profile("issues-page");
    let (rid, _) = init_repo(&f, "issue-repo", "issues");
    create_issues(&f, &rid, 3);

    let page0 = parse(&radicle_local_ffi::cobs::list_issues(
        &f.home(),
        &rid,
        "",
        0,
        2,
    ));
    assert_eq!(page0["items"].as_array().expect("items").len(), 2);
    assert_eq!(page0["hasMore"], true, "a third issue follows: {page0}");

    let page1 = parse(&radicle_local_ffi::cobs::list_issues(
        &f.home(),
        &rid,
        "",
        1,
        2,
    ));
    assert_eq!(page1["items"].as_array().expect("items").len(), 1);
    assert_eq!(page1["hasMore"], false, "last page: {page1}");

    // No issue appears on both pages.
    let first: Vec<&str> = page0["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|i| i["id"].as_str())
        .collect();
    let second: Vec<&str> = page1["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|i| i["id"].as_str())
        .collect();
    for id in &second {
        assert!(!first.contains(id), "issue {id} on both pages");
    }
}

#[test]
fn get_issue_returns_the_discussion_thread() {
    let f = init_profile("issue-detail");
    let (rid, _) = init_repo(&f, "issue-repo", "issues");
    let ids = create_issues(&f, &rid, 1);

    // Add a reply so the thread has more than the root comment.
    let repo_id = radicle::identity::RepoId::from_urn(&rid).expect("rid");
    let repo = f.profile.storage.repository(repo_id).expect("repo");
    let signer = f.profile.signer().expect("signer");
    {
        let mut store = Issues::open(&repo, WriteAs::new(&signer)).expect("open for write");
        let mut cache = radicle::cob::cache::NoCache;
        let oid = ids[0].parse().expect("object id");
        let mut issue = store.get_mut(&oid, &mut cache).expect("get issue");
        let root = *issue.root().0;
        issue
            .comment("a reply from the same author", root, [])
            .expect("could not comment");
    }

    let v = parse(&radicle_local_ffi::cobs::get_issue(
        &f.home(),
        &rid,
        &ids[0],
    ));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    assert_eq!(v["title"], "issue 1");
    assert_eq!(v["state"]["status"], "open");

    // ThreadView.qml reads `discussion`, not `thread` or `comments`.
    let discussion = v["discussion"]
        .as_array()
        .expect("discussion should be an array");
    let bodies: Vec<&str> = discussion
        .iter()
        .filter_map(|c| c["body"].as_str())
        .collect();
    assert!(
        bodies.contains(&"the body of issue 1"),
        "the root comment is part of the thread: {bodies:?}"
    );
    assert!(
        bodies.contains(&"a reply from the same author"),
        "replies must not be dropped — the view renders a flat list: {bodies:?}"
    );

    // Comment timestamps are Unix *seconds*. The crate stores milliseconds,
    // so a missing conversion here renders every comment in the year ~57000.
    let ts = discussion[0]["timestamp"]
        .as_i64()
        .expect("timestamp should be a number");
    assert!(
        (1_500_000_000..4_000_000_000).contains(&ts),
        "comment timestamp should be Unix seconds, got {ts}"
    );

    let author_id = discussion[0]["author"]["id"]
        .as_str()
        .expect("comment author.id");
    assert!(
        author_id.starts_with("did:key:"),
        "comment author.id should be a DID: {author_id}"
    );
}

#[test]
fn get_issue_on_an_unknown_id_reports_an_error() {
    let f = init_profile("issue-missing");
    let (rid, _) = init_repo(&f, "issue-repo", "issues");
    create_issues(&f, &rid, 1);

    // Well-formed but absent, so this is the not-found path rather than a
    // parse failure.
    let absent = "0000000000000000000000000000000000000000";
    let v = parse(&radicle_local_ffi::cobs::get_issue(&f.home(), &rid, absent));
    assert!(
        v["error"].as_str().is_some(),
        "an unknown issue is an error, not an empty object: {v}"
    );
}

#[test]
fn an_empty_issue_store_lists_nothing_rather_than_failing() {
    let f = init_profile("issues-empty");
    let (rid, _) = init_repo(&f, "issue-repo", "issues");

    let v = parse(&radicle_local_ffi::cobs::list_issues(
        &f.home(),
        &rid,
        "",
        0,
        10,
    ));
    // A repo nobody has filed an issue on is empty, not broken — the same
    // distinction `radicle_impl.h` draws between "no repos" and "no node".
    assert!(v.get("error").is_none(), "unexpected error: {v}");
    assert_eq!(v["items"].as_array().expect("items").len(), 0);
    assert_eq!(v["hasMore"], false);
}

#[test]
fn an_empty_patch_store_lists_nothing_rather_than_failing() {
    let f = init_profile("patches-empty");
    let (rid, _) = init_repo(&f, "patch-repo", "patches");

    let v = parse(&radicle_local_ffi::cobs::list_patches(
        &f.home(),
        &rid,
        "",
        0,
        10,
    ));
    assert!(v.get("error").is_none(), "unexpected error: {v}");
    assert_eq!(v["items"].as_array().expect("items").len(), 0);
}

#[test]
fn list_patches_returns_the_fields_the_view_reads() {
    let f = init_profile("patches-list");
    let (rid, work) = init_repo(&f, "patch-repo", "patches");

    // A patch needs a revision, which needs a commit that is not on the
    // default branch. Make one and push it into storage.
    let repo = radicle::git::raw::Repository::open(&work).expect("open working copy");
    std::fs::write(work.join("feature.txt"), "a feature\n").expect("write");
    let head_sha = fixture::commit_all(&repo, "add a feature");
    fixture::publish(&f, &work, &rid);

    let repo_id = radicle::identity::RepoId::from_urn(&rid).expect("rid");
    let stored = f.profile.storage.repository(repo_id).expect("repo");
    let signer = f.profile.signer().expect("signer");

    let base = repo
        .find_commit(head_sha.parse().expect("sha"))
        .expect("commit")
        .parent(0)
        .expect("parent")
        .id();

    let patch_id = {
        let mut store = Patches::open(&stored, WriteAs::new(&signer)).expect("open patches");
        let mut cache = radicle::cob::cache::NoCache;
        let patch = store
            .create(
                "a patch title".parse().expect("valid title"),
                "a patch description",
                radicle::cob::patch::MergeTarget::default(),
                base,
                head_sha.parse::<radicle::git::Oid>().expect("sha"),
                &[],
                &mut cache,
            )
            .expect("could not create patch");
        patch.id().to_string()
    };

    let v = parse(&radicle_local_ffi::cobs::list_patches(
        &f.home(),
        &rid,
        "",
        0,
        10,
    ));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    let items = v["items"].as_array().expect("items array");
    assert_eq!(items.len(), 1, "one patch: {v}");
    assert_eq!(items[0]["title"], "a patch title");
    assert_eq!(items[0]["id"], patch_id);
    // Newly created patches are open; PatchesTab's default chip is "open".
    assert_eq!(items[0]["state"]["status"], "open", "got {v}");

    // Only "open" should match the open filter; "merged" should not.
    let merged = parse(&radicle_local_ffi::cobs::list_patches(
        &f.home(),
        &rid,
        "merged",
        0,
        10,
    ));
    assert_eq!(
        merged["items"].as_array().expect("items").len(),
        0,
        "an open patch must not appear under the merged filter: {merged}"
    );

    // Detail view: revisions drive ThreadView's footer count.
    let detail = parse(&radicle_local_ffi::cobs::get_patch(
        &f.home(),
        &rid,
        &patch_id,
    ));
    assert!(detail.get("error").is_none(), "unexpected error: {detail}");
    assert_eq!(detail["title"], "a patch title");
    let revisions = detail["revisions"]
        .as_array()
        .expect("revisions should be an array");
    assert_eq!(revisions.len(), 1, "one revision: {detail}");
    assert!(
        revisions[0]["id"].as_str().is_some(),
        "a revision needs an id: {detail}"
    );
    assert!(
        revisions[0]["author"]["id"]
            .as_str()
            .unwrap_or("")
            .starts_with("did:key:"),
        "revision author should be a DID: {detail}"
    );
}
