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
