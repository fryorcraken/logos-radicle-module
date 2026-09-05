//! Tree, blob, readme, commit-list and commit-diff reads, against a real
//! repository in real local storage.
//!
//! Every assertion here is a field the QML actually reads. Where the view
//! *branches* on a value ("tree" vs anything else, "addition"/"deletion",
//! `lineNoOld` present vs absent), the test pins the value rather than just
//! its presence — a wrong-but-present value renders silently.

mod fixture;

use fixture::{init_profile, init_repo, parse};

#[test]
fn get_tree_lists_the_root_with_kinds_the_view_branches_on() {
    let f = init_profile("tree-root");
    let (rid, _) = init_repo(&f, "tree-repo", "trees");

    let v = parse(&radicle_local_ffi::gitread::get_tree(
        &f.home(),
        &rid,
        "",
        "",
    ));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    let entries = v["entries"].as_array().expect("entries should be an array");
    let by_name = |name: &str| {
        entries
            .iter()
            .find(|e| e["name"] == name)
            .unwrap_or_else(|| panic!("no entry named {name} in {v}"))
    };

    // `SourceTab.qml` treats exactly "tree" as a directory and everything
    // else as a file. Both sides of that branch must be right.
    assert_eq!(by_name("src")["kind"], "tree");
    assert_eq!(by_name("README.md")["kind"], "blob");

    // `path` is passed straight back as the next request's argument, so it
    // must be repo-relative and complete, not just the basename.
    assert_eq!(by_name("src")["path"], "src");
    assert_eq!(by_name("README.md")["path"], "README.md");
}

#[test]
fn get_tree_descends_into_a_subdirectory_with_full_paths() {
    let f = init_profile("tree-sub");
    let (rid, _) = init_repo(&f, "tree-repo", "trees");

    let v = parse(&radicle_local_ffi::gitread::get_tree(
        &f.home(),
        &rid,
        "",
        "src",
    ));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    let entries = v["entries"].as_array().expect("entries array");
    let paths: Vec<&str> = entries.iter().filter_map(|e| e["path"].as_str()).collect();

    // Nested paths must carry the parent, or clicking a file in a
    // subdirectory asks for the wrong blob.
    assert!(paths.contains(&"src/main.rs"), "got {paths:?}");
    assert!(paths.contains(&"src/lib.rs"), "got {paths:?}");
}

#[test]
fn asking_for_a_file_as_a_tree_is_an_error_not_an_empty_listing() {
    let f = init_profile("tree-not-dir");
    let (rid, _) = init_repo(&f, "tree-repo", "trees");

    let v = parse(&radicle_local_ffi::gitread::get_tree(
        &f.home(),
        &rid,
        "",
        "README.md",
    ));
    // An empty `entries` would render as an empty directory, which is a
    // different and wrong answer.
    assert!(v["error"].as_str().is_some(), "expected an error, got: {v}");
}

#[test]
fn get_blob_returns_text_content_verbatim() {
    let f = init_profile("blob-text");
    let (rid, _) = init_repo(&f, "blob-repo", "blobs");

    let v = parse(&radicle_local_ffi::gitread::get_blob(
        &f.home(),
        &rid,
        "",
        "src/main.rs",
    ));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    assert_eq!(v["binary"], false);
    // Rendered verbatim in a monospace TextArea — not base64, not escaped.
    assert_eq!(v["content"], "fn main() {}\n");
    assert_eq!(v["name"], "main.rs");
    assert_eq!(v["path"], "src/main.rs");
}

#[test]
fn a_binary_blob_reports_binary_and_sends_no_content() {
    let f = init_profile("blob-binary");
    let (rid, _) = init_repo(&f, "blob-repo", "blobs");

    let v = parse(&radicle_local_ffi::gitread::get_blob(
        &f.home(),
        &rid,
        "",
        "data/binary.bin",
    ));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    // The view checks `binary` first and never reads `content` when set, so
    // shipping the bytes would be pure waste across the QtRO boundary.
    assert_eq!(v["binary"], true, "got {v}");
    assert_eq!(v["content"], "");
    assert_eq!(v["name"], "binary.bin");
}

#[test]
fn get_readme_finds_the_root_readme() {
    let f = init_profile("readme");
    let (rid, _) = init_repo(&f, "readme-repo", "readmes");

    let v = parse(&radicle_local_ffi::gitread::get_readme(&f.home(), &rid, ""));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    assert_eq!(v["path"], "README.md");
    assert_eq!(v["content"], "# fixture\n\nHello.\n");
}

/// "No README" must be an error, not an empty success: `SourceTab.qml`
/// swallows the failure silently, whereas an empty-string success would
/// render an empty README pane on every repo that has none.
#[test]
fn a_repo_with_no_readme_reports_an_error_rather_than_empty_content() {
    let f = init_profile("readme-absent");
    let work = f.dir.join("work-bare");
    std::fs::create_dir_all(&work).expect("mkdir");
    let repo = radicle::git::raw::Repository::init(&work).expect("git init");
    std::fs::write(work.join("only.txt"), "no readme here\n").expect("write");
    fixture::commit_all(&repo, "initial");

    let signer = f.profile.signer().expect("signer");
    let (rid, _, _) = radicle::rad::init(
        &repo,
        std::str::FromStr::from_str("bare-repo").expect("name"),
        "a repo with no README",
        radicle::git::fmt::RefString::try_from("master").expect("branch"),
        radicle::identity::Visibility::default(),
        &signer,
        &f.profile.storage,
    )
    .expect("rad init");

    let v = parse(&radicle_local_ffi::gitread::get_readme(
        &f.home(),
        &rid.urn(),
        "",
    ));
    assert!(
        v["error"].as_str().is_some(),
        "a missing README is an error, not empty content: {v}"
    );
}

#[test]
fn list_commits_paginates_newest_first() {
    let f = init_profile("commits-list");
    let (rid, work) = init_repo(&f, "commit-repo", "commits");

    // Three more commits on top of the fixture's initial one.
    let repo = radicle::git::raw::Repository::open(&work).expect("open working copy");
    for n in 1..=3 {
        std::fs::write(work.join(format!("file{n}.txt")), format!("body {n}\n")).expect("write");
        fixture::commit_all(&repo, &format!("commit number {n}"));
    }
    // Sanity: the working copy really does have four commits before we push.
    // If this ever fails, the fixture's commit helper is broken, not the code
    // under test.
    let head = repo.head().expect("head").peel_to_commit().expect("commit");
    assert_eq!(
        head.summary().ok().flatten(),
        Some("commit number 3"),
        "working copy HEAD should be the last commit made"
    );

    fixture::publish(&f, &work, &rid);

    let page0 = parse(&radicle_local_ffi::gitread::list_commits(
        &f.home(),
        &rid,
        "",
        0,
        2,
    ));
    assert!(page0.get("error").is_none(), "unexpected error: {page0}");

    let items = page0["items"].as_array().expect("items array");
    assert_eq!(items.len(), 2, "a page of 2: {page0}");
    assert_eq!(page0["hasMore"], true, "more commits follow: {page0}");

    // Newest first — the views offer no sort control, so this ordering is the
    // contract.
    assert_eq!(items[0]["summary"], "commit number 3", "got {page0}");
    assert_eq!(items[1]["summary"], "commit number 2", "got {page0}");

    // committer.time is Unix *seconds*: Radicle.js multiplies by 1000. A
    // millisecond value here would render as the year ~57000.
    let time = items[0]["committer"]["time"]
        .as_i64()
        .expect("committer.time should be a number");
    assert!(
        (1_500_000_000..4_000_000_000).contains(&time),
        "committer.time should be Unix seconds, got {time}"
    );

    let page1 = parse(&radicle_local_ffi::gitread::list_commits(
        &f.home(),
        &rid,
        "",
        1,
        2,
    ));
    let items1 = page1["items"].as_array().expect("items array");
    assert_eq!(items1[0]["summary"], "commit number 1", "got {page1}");

    // Pages must not repeat a commit.
    let first_ids: Vec<&str> = items.iter().filter_map(|i| i["id"].as_str()).collect();
    let second_ids: Vec<&str> = items1.iter().filter_map(|i| i["id"].as_str()).collect();
    for id in &second_ids {
        assert!(
            !first_ids.contains(id),
            "commit {id} appeared on both pages"
        );
    }
}

#[test]
fn get_commit_renders_a_diff_in_the_shape_commitview_reads() {
    let f = init_profile("commit-diff");
    let (rid, work) = init_repo(&f, "diff-repo", "diffs");

    let repo = radicle::git::raw::Repository::open(&work).expect("open working copy");
    // One modification (a line replaced) and one brand-new file, so both the
    // "added" and "modified" file statuses and both line types appear.
    std::fs::write(
        work.join("src/main.rs"),
        "fn main() { println!(\"hi\"); }\n",
    )
    .expect("write");
    std::fs::write(work.join("added.txt"), "brand new\n").expect("write");
    let sha = fixture::commit_all(&repo, "change main and add a file");
    fixture::publish(&f, &work, &rid);

    let v = parse(&radicle_local_ffi::gitread::get_commit(
        &f.home(),
        &rid,
        &sha,
    ));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    assert_eq!(v["commit"]["summary"], "change main and add a file");
    assert_eq!(v["commit"]["id"], sha);

    let files = v["diff"]["files"].as_array().expect("diff.files array");
    assert_eq!(files.len(), 2, "two files changed: {v}");

    let added = files
        .iter()
        .find(|f| f["path"] == "added.txt")
        .unwrap_or_else(|| panic!("no added.txt in {v}"));
    // `CommitView.qml` colours exactly on these strings.
    assert_eq!(added["status"], "added");

    let modified = files
        .iter()
        .find(|f| f["path"] == "src/main.rs")
        .unwrap_or_else(|| panic!("no src/main.rs in {v}"));
    assert_eq!(modified["status"], "modified");

    // The second `diff` level is not a typo: CommitView.qml reads
    // `files[].diff.hunks`, and flattening it would render every file as
    // having no changes.
    let hunks = modified["diff"]["hunks"]
        .as_array()
        .expect("files[].diff.hunks should be an array");
    assert!(!hunks.is_empty(), "expected hunks in {modified}");

    let header = hunks[0]["header"].as_str().expect("hunk header");
    assert!(header.starts_with("@@"), "unexpected hunk header: {header}");

    let lines = hunks[0]["lines"].as_array().expect("hunk lines");
    let types: Vec<&str> = lines.iter().filter_map(|l| l["type"].as_str()).collect();
    // Exactly the strings the view branches on.
    assert!(types.contains(&"addition"), "no addition line in {types:?}");
    assert!(types.contains(&"deletion"), "no deletion line in {types:?}");

    // An added line has no old line number. The view tests `!== undefined`,
    // so the key must be *absent*, not null — a null prints "null" in the
    // gutter.
    let addition = lines
        .iter()
        .find(|l| l["type"] == "addition")
        .expect("an addition line");
    assert!(
        addition.get("lineNoOld").is_none(),
        "lineNoOld must be omitted, not null, on an addition: {addition}"
    );
    assert!(
        addition.get("lineNoNew").is_some(),
        "an addition needs a new line number: {addition}"
    );

    let deletion = lines
        .iter()
        .find(|l| l["type"] == "deletion")
        .expect("a deletion line");
    assert!(
        deletion.get("lineNoNew").is_none(),
        "lineNoNew must be omitted, not null, on a deletion: {deletion}"
    );

    // Stats drive the +N / −N counters in the header.
    assert!(
        v["diff"]["stats"]["insertions"].as_u64().unwrap_or(0) > 0,
        "expected insertions in {v}"
    );
}

#[test]
fn get_commit_on_an_unknown_sha_errors_rather_than_showing_head() {
    let f = init_profile("commit-unknown");
    let (rid, _) = init_repo(&f, "diff-repo", "diffs");

    let v = parse(&radicle_local_ffi::gitread::get_commit(
        &f.home(),
        &rid,
        "0000000000000000000000000000000000000000",
    ));
    // Unlike tree/blob, which fall back to head to match the seed client,
    // a specific commit request must not silently show a different commit.
    assert!(
        v["error"].as_str().is_some(),
        "an unknown commit must error, not fall back: {v}"
    );
}

/// A peer's branch arrives from `list_branches` as `<nid>/<branch>`, and
/// `resolve_commit` has to find it under `refs/namespaces/<nid>/refs/heads/`.
///
/// The failure this guards against is silent, which is why the fixture makes
/// the two branches differ in *content*: an unresolvable ref falls back to the
/// repo head (deliberately, to match the seed client), so before the namespace
/// lookup existed, picking a peer's branch showed the canonical branch's files
/// while the picker happily displayed the peer's name. Asserting on a file that
/// exists only on the peer's branch is what tells those two apart — asserting
/// merely that the read succeeded would pass either way.
#[test]
fn a_peer_qualified_branch_resolves_to_that_peers_commit() {
    use radicle::storage::{SignRepository as _, WriteRepository as _};

    let f = init_profile("peer-branch-resolve");
    let (rid, work) = init_repo(&f, "peer-repo", "peers");

    // A commit that exists only on the peer's branch, carrying a file the
    // canonical branch does not have.
    let repo = radicle::git::raw::Repository::open(&work).expect("open working copy");
    std::fs::write(work.join("PEER_ONLY.md"), "# only on the peer\n").expect("write peer file");
    fixture::commit_all(&repo, "peer-only commit");

    // Publish it under a *different* node's namespace, the way a replicated
    // peer's refs actually sit in storage.
    let peer = radicle::crypto::SigningKey::from_seed(radicle::crypto::Seed::new([99u8; 32]));
    let peer_nid = radicle::crypto::Signer::public_key(&peer).to_string();

    let id = radicle::identity::RepoId::from_urn(&rid).expect("valid rid");
    let stored =
        radicle::storage::ReadStorage::repository(&f.profile.storage, id).expect("repo in storage");

    // Push the commit's OBJECTS into storage before pointing a ref at them.
    // The working copy and storage are separate object databases, so creating
    // the ref straight from the commit's OID fails with "target OID for the
    // reference doesn't exist on the repository" — at that moment the commit
    // exists only in the working copy.
    //
    // Pushed to storage's path directly rather than through the `rad` remote
    // that `rad::init` configured: that remote's URL is already scoped to THIS
    // node's namespace, so a namespaced refspec through it would nest one
    // namespace inside another (`publish` in the fixture module documents the
    // same trap) and land the branch where nothing reads it.
    let storage_path = stored.raw().path().to_path_buf();
    let mut remote = repo
        .remote_anonymous(&storage_path.display().to_string())
        .expect("could not open storage as a remote");
    remote
        .push(
            &[
                format!("+refs/heads/master:refs/namespaces/{peer_nid}/refs/heads/feature")
                    .as_str(),
            ],
            None,
        )
        .expect("could not push the peer branch into storage");

    stored.sign_refs(&peer).expect("could not sign peer refs");

    // The canonical branch must NOT have the peer's file — otherwise this test
    // could not tell the two apart.
    let canonical = parse(&radicle_local_ffi::gitread::get_tree(
        &f.home(),
        &rid,
        "master",
        "",
    ));
    let canonical_names: Vec<String> = canonical["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .map(|e| e["name"].as_str().unwrap_or("").to_string())
        .collect();
    assert!(
        !canonical_names.iter().any(|n| n == "PEER_ONLY.md"),
        "fixture is not discriminating: the canonical branch already has the \
         peer's file, so this test could not detect a wrong resolution: {canonical_names:?}"
    );

    // Now the peer's branch, addressed the way the picker addresses it.
    let v = parse(&radicle_local_ffi::gitread::get_tree(
        &f.home(),
        &rid,
        &format!("{peer_nid}/feature"),
        "",
    ));
    assert!(v.get("error").is_none(), "peer branch should read: {v}");

    let names: Vec<String> = v["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .map(|e| e["name"].as_str().unwrap_or("").to_string())
        .collect();
    assert!(
        names.iter().any(|n| n == "PEER_ONLY.md"),
        "a peer-qualified branch must resolve to that peer's commit, not the \
         repo head: {names:?}"
    );
}

/// Push a branch into storage under `signer`'s namespace, carrying `marker` as
/// a file that exists nowhere else, and sign the resulting ref set.
///
/// Two details are load-bearing and both were got wrong first time:
///
/// - **The marker.** Every bug these tests guard against is silent: an
///   unresolvable ref falls back to the repo head, so a read of the wrong
///   branch still succeeds and still renders. Only a file unique to one branch
///   distinguishes "resolved correctly" from "fell back".
/// - **`sign_refs`.** `list_branches` enumerates via `remotes()`, which reads
///   each peer's *signed* ref set rather than globbing `refs/namespaces/*`.
///   A raw push leaves the branch visible to `resolve_commit` but invisible to
///   `list_branches`, so a test that skips signing dies on its listing
///   assertion before reaching the resolution assertions it exists for —
///   passing or failing for reasons that have nothing to do with the code
///   under test.
fn push_branch_with_marker(
    f: &fixture::Fixture,
    rid: &str,
    work: &std::path::Path,
    signer: &impl radicle::crypto::Signer,
    branch: &str,
    marker: &str,
) {
    use radicle::storage::SignRepository as _;

    let namespace = radicle::crypto::Signer::public_key(signer).to_string();
    let repo = radicle::git::raw::Repository::open(work).expect("open working copy");
    std::fs::write(work.join(marker), format!("# {marker}\n")).expect("write marker");
    fixture::commit_all(&repo, &format!("commit for {branch}"));

    let id = radicle::identity::RepoId::from_urn(rid).expect("valid rid");
    let stored =
        radicle::storage::ReadStorage::repository(&f.profile.storage, id).expect("repo in storage");
    let storage_path = radicle::storage::WriteRepository::raw(&stored)
        .path()
        .to_path_buf();

    let mut remote = repo
        .remote_anonymous(&storage_path.display().to_string())
        .expect("could not open storage as a remote");
    remote
        .push(
            &[
                format!("+refs/heads/master:refs/namespaces/{namespace}/refs/heads/{branch}")
                    .as_str(),
            ],
            None,
        )
        .expect("could not push branch into storage");

    stored.sign_refs(signer).expect("could not sign refs");

    // Undo the marker in the working copy so the NEXT branch pushed from it
    // does not inherit this one's file — otherwise every branch ends up
    // carrying every marker and no assertion can tell them apart.
    std::fs::remove_file(work.join(marker)).expect("remove marker");
    fixture::commit_all(&repo, &format!("drop {marker}"));
}

/// Entry names in a repo's root tree at `sha`, as the view would see them.
fn tree_names(home: &str, rid: &str, sha: &str) -> Vec<String> {
    let v = parse(&radicle_local_ffi::gitread::get_tree(home, rid, sha, ""));
    assert!(v.get("error").is_none(), "get_tree({sha}) errored: {v}");
    v["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .map(|e| e["name"].as_str().unwrap_or("").to_string())
        .collect()
}

/// THE regression test for this change: the local node's OWN branches live
/// under `refs/namespaces/<self-nid>/`, exactly like every peer's, and are
/// listed BARE. So `develop` exists at neither `refs/heads/develop` nor
/// anywhere else unnamespaced.
///
/// Without the local-namespace candidate in `resolve_commit`, every local
/// branch except the canonical default fell through to the repo-head fallback
/// and rendered the default branch's files under the chosen branch's name —
/// silently, because the fallback is deliberate and returns no error.
///
/// Note this needs a NON-CANONICAL branch. An earlier version of the
/// peer-branch test pushed to `refs/heads/master`, which is the canonical ref
/// and resolves through a different candidate, so it passed while every real
/// local branch was broken.
#[test]
fn a_local_branch_resolves_to_itself_not_the_repo_head() {
    let f = init_profile("local-branch-resolve");
    let (rid, work) = init_repo(&f, "local-repo", "local branches");
    let me = f.profile.signer().expect("signer");

    push_branch_with_marker(&f, &rid, &work, &me, "develop", "DEVELOP_ONLY.md");
    // A slashed name too: local branches are listed bare, so `feature/login`
    // reaches resolution looking exactly like a peer-qualified reference.
    push_branch_with_marker(&f, &rid, &work, &me, "feature/login", "FEATURE_ONLY.md");

    // Both must be offered bare and flagged local.
    let listed = parse(&radicle_local_ffi::local::list_branches(&f.home(), &rid));
    let items = listed["items"].as_array().expect("items");
    for name in ["develop", "feature/login"] {
        assert!(
            items
                .iter()
                .any(|i| i["name"] == name && i["isLocal"] == true),
            "{name} should be listed bare and local: {listed}"
        );
    }

    // The fixture must be discriminating: the canonical branch carries neither
    // marker, so a fallback to head cannot satisfy the assertions below.
    let canonical = tree_names(&f.home(), &rid, "master");
    assert!(
        !canonical.iter().any(|n| n == "DEVELOP_ONLY.md")
            && !canonical.iter().any(|n| n == "FEATURE_ONLY.md"),
        "fixture is not discriminating — the canonical branch already carries a \
         marker, so this test could not detect a wrong resolution: {canonical:?}"
    );

    let develop = tree_names(&f.home(), &rid, "develop");
    assert!(
        develop.iter().any(|n| n == "DEVELOP_ONLY.md"),
        "a local branch must resolve to itself, not the repo head. Got {develop:?}, \
         which is the canonical branch's tree."
    );

    let feature = tree_names(&f.home(), &rid, "feature/login");
    assert!(
        feature.iter().any(|n| n == "FEATURE_ONLY.md"),
        "a slashed local branch must resolve to itself: {feature:?}"
    );
    // And it must not have been read as peer `feature`'s branch `login`.
    assert!(
        !feature.iter().any(|n| n == "DEVELOP_ONLY.md"),
        "feature/login resolved to the wrong branch entirely: {feature:?}"
    );
}

/// `list_commits` resolves through the same function, so it has the same
/// failure mode — and it is the tab a user lands on after the file tree.
#[test]
fn list_commits_on_a_local_branch_reads_that_branch() {
    let f = init_profile("local-branch-commits");
    let (rid, work) = init_repo(&f, "commits-repo", "local branch commits");
    let me = f.profile.signer().expect("signer");

    push_branch_with_marker(&f, &rid, &work, &me, "develop", "DEV.md");

    let v = parse(&radicle_local_ffi::gitread::list_commits(
        &f.home(),
        &rid,
        "develop",
        0,
        10,
    ));
    assert!(v.get("error").is_none(), "should read: {v}");
    let summaries: Vec<String> = v["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|c| c["summary"].as_str().unwrap_or("").to_string())
        .collect();

    // The branch's own commit is the marker; the canonical branch has only
    // "initial", so its presence proves which ref was walked.
    assert!(
        summaries.iter().any(|s| s == "commit for develop"),
        "list_commits must walk the chosen local branch, not the head: {summaries:?}"
    );
}

/// The residual ambiguity the `NodeId` parse cannot resolve: a local branch
/// named literally `<peer-nid>/<branch>` where that peer exists and has that
/// branch. Both candidates then resolve, and ordering decides which wins.
///
/// Contrived, but it is the exact shape that turns a name into a wrong answer,
/// and the guard against it — trying `refs/heads/<name>` before the peer
/// namespace — is one line that a later refactor could reorder without
/// noticing. This test is what makes that reordering fail loudly.
#[test]
fn a_local_branch_shaped_like_a_peer_reference_wins_over_the_peer() {
    use radicle::storage::SignRepository as _;

    let f = init_profile("local-beats-peer");
    let (rid, work) = init_repo(&f, "collide-repo", "collisions");

    let peer = radicle::crypto::SigningKey::from_seed(radicle::crypto::Seed::new([77u8; 32]));
    let peer_nid = radicle::crypto::Signer::public_key(&peer).to_string();
    let me = radicle::crypto::Signer::public_key(&f.profile.signer().expect("signer")).to_string();

    let repo = radicle::git::raw::Repository::open(&work).expect("open working copy");
    let id = radicle::identity::RepoId::from_urn(&rid).expect("valid rid");
    let stored =
        radicle::storage::ReadStorage::repository(&f.profile.storage, id).expect("repo in storage");
    let storage_path = radicle::storage::WriteRepository::raw(&stored)
        .path()
        .to_path_buf();

    // The peer's `wip`, with its own distinctive file.
    std::fs::write(work.join("THEIRS.md"), "# the peer's\n").expect("write");
    fixture::commit_all(&repo, "peer wip");
    let mut remote = repo
        .remote_anonymous(&storage_path.display().to_string())
        .expect("remote");
    remote
        .push(
            &[format!("+refs/heads/master:refs/namespaces/{peer_nid}/refs/heads/wip").as_str()],
            None,
        )
        .expect("push peer wip");

    // Now a LOCAL branch whose name is literally `<that peer's nid>/wip`.
    std::fs::write(work.join("MINE.md"), "# mine\n").expect("write");
    fixture::commit_all(&repo, "local branch named like a peer ref");
    let mut remote = repo
        .remote_anonymous(&storage_path.display().to_string())
        .expect("remote");
    remote
        .push(
            &[
                format!("+refs/heads/master:refs/namespaces/{me}/refs/heads/{peer_nid}/wip")
                    .as_str(),
            ],
            None,
        )
        .expect("push local lookalike");

    stored.sign_refs(&peer).expect("sign peer refs");

    let v = parse(&radicle_local_ffi::gitread::get_tree(
        &f.home(),
        &rid,
        &format!("{peer_nid}/wip"),
        "",
    ));
    assert!(v.get("error").is_none(), "should read: {v}");
    let names: Vec<String> = v["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .map(|e| e["name"].as_str().unwrap_or("").to_string())
        .collect();

    // MINE.md is on the local branch; THEIRS.md alone would mean the peer
    // namespace won and a local branch silently served a peer's files.
    assert!(
        names.iter().any(|n| n == "MINE.md"),
        "a local branch must win over a same-named peer reference: {names:?}"
    );
}

#[test]
fn a_root_commit_diffs_against_the_empty_tree() {
    let f = init_profile("commit-root");
    let (rid, work) = init_repo(&f, "root-repo", "root");

    let repo = radicle::git::raw::Repository::open(&work).expect("open");
    // The fixture's own first commit is a root commit.
    let head = repo.head().expect("head").peel_to_commit().expect("commit");
    let sha = head.id().to_string();

    let v = parse(&radicle_local_ffi::gitread::get_commit(
        &f.home(),
        &rid,
        &sha,
    ));
    assert!(v.get("error").is_none(), "a root commit is readable: {v}");

    let files = v["diff"]["files"].as_array().expect("files");
    assert!(
        !files.is_empty(),
        "a root commit's whole tree is additions: {v}"
    );
    assert!(
        files.iter().all(|f| f["status"] == "added"),
        "every file in a root commit is added: {v}"
    );
}
