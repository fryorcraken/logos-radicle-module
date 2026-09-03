//! Real fixtures, not skips.
//!
//! An earlier version of this file was two `SMOKE_*`-env-gated tests that
//! returned early when the variable was unset — so they reported "ok" while
//! executing none of the code under test. This project has been bitten by
//! exactly that shape before (a test runner that silently skipped and went
//! green in CI), so these build an actual Radicle profile and an actual repo
//! on disk, through the crate's public API, and assert on the JSON that comes
//! back.
//!
//! `radicle::test` is crate-internal and cannot be used as a dev-dependency,
//! so the fixture is assembled the same way `rad init` does it:
//! `Profile::init` writes a keystore and storage root, and `rad::init` pushes
//! a git working copy into that storage as a real Radicle repository.
//!
//! Scratch homes live under this crate's own `tmp/` (gitignored), never
//! `/tmp`: everything a test writes stays inside the working directory.

use std::path::{Path, PathBuf};
use std::str::FromStr;

use radicle::crypto::Seed;
use radicle::git::fmt::RefString;
use radicle::identity::project::ProjectName;
use radicle::identity::Visibility;
use radicle::node::Alias;
use radicle::profile::{Home, Profile};

/// A scratch Radicle home that deletes itself when the test ends.
struct Fixture {
    dir: PathBuf,
    profile: Profile,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Fixture {
    fn home(&self) -> String {
        self.profile.home().path().display().to_string()
    }
}

fn scratch_dir(name: &str) -> PathBuf {
    // `tmp/` beside Cargo.toml, not the system temp dir.
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tmp").join(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("could not create scratch dir");
    dir
}

/// A profile with a keystore and an empty storage root. The seed is fixed
/// rather than random so a failure reproduces identically.
fn init_profile(name: &str) -> Fixture {
    let dir = scratch_dir(name);
    let home = Home::new(dir.join("home")).expect("could not create Radicle home");
    // No passphrase: the key is written unencrypted, which is what lets the
    // read path work with no prompt. That is the property under test.
    let profile = Profile::init(home, Alias::new("tester"), None, Seed::new([7u8; 32]))
        .expect("could not init profile");
    Fixture { dir, profile }
}

/// Create a git working copy with one commit and push it into storage as a
/// Radicle repo, returning its RID.
fn init_repo(fixture: &Fixture, name: &str, description: &str) -> String {
    let work = fixture.dir.join(format!("work-{name}"));
    std::fs::create_dir_all(&work).expect("could not create working copy dir");

    let repo = radicle::git::raw::Repository::init(&work).expect("git init failed");

    std::fs::write(work.join("README.md"), "# fixture\n").expect("could not write README");
    let mut index = repo.index().expect("no index");
    index
        .add_path(Path::new("README.md"))
        .expect("could not add README");
    index.write().expect("could not write index");
    let tree_id = index.write_tree().expect("could not write tree");
    let tree = repo.find_tree(tree_id).expect("no tree");
    let sig = radicle::git::raw::Signature::now("tester", "tester@example.com")
        .expect("could not build signature");
    repo.commit(Some("HEAD"), &sig, &sig, "initial", &tree, &[])
        .expect("could not commit");

    let signer = fixture.profile.signer().expect("could not load signer");
    let storage = &fixture.profile.storage;

    let (rid, _, _) = radicle::rad::init(
        &repo,
        ProjectName::from_str(name).expect("invalid project name"),
        description,
        RefString::try_from("master").expect("invalid branch name"),
        Visibility::default(),
        &signer,
        storage,
    )
    .expect("rad init failed");

    rid.urn()
}

fn parse(json: &str) -> serde_json::Value {
    serde_json::from_str(json).unwrap_or_else(|e| panic!("not valid JSON: {e}\n{json}"))
}

#[test]
fn get_repo_returns_the_seed_json_shape() {
    let fixture = init_profile("get-repo");
    let rid = init_repo(&fixture, "fixture-repo", "a repo built by the test harness");

    let out = radicle_local_ffi::local::get_repo(&fixture.home(), &rid);
    let v = parse(&out);

    assert!(v.get("error").is_none(), "unexpected error: {out}");

    // The shape `remoteGetRepo` produces, as pinned by test_seed_client.cpp's
    // kRepoJson fixture. A view must render either source without branching,
    // so these paths are the actual contract.
    assert_eq!(v["rid"], rid, "rid should round-trip: {out}");

    let data = &v["payloads"]["xyz.radicle.project"]["data"];
    assert_eq!(data["name"], "fixture-repo");
    assert_eq!(data["description"], "a repo built by the test harness");
    assert_eq!(data["defaultBranch"], "master");

    let meta = &v["payloads"]["xyz.radicle.project"]["meta"];
    let head = meta["head"].as_str().expect("meta.head should be a string");
    assert_eq!(head.len(), 40, "head should be a full 40-char SHA: {head}");
    assert!(
        head.chars().all(|c| c.is_ascii_hexdigit()),
        "head should be hex: {head}"
    );

    // A fresh repo has no issues or patches, but the counts must still be
    // present and zero rather than missing -- get_repo_inner defaults them
    // instead of failing the whole view.
    assert_eq!(meta["issues"]["open"], 0);
    assert_eq!(meta["patches"]["open"], 0);

    // refs.refs holds refs/heads/*; the COB and namespace plumbing a raw ref
    // walk would also turn up must not leak in.
    let refs = v["refs"]["refs"]
        .as_object()
        .expect("refs.refs should be an object");
    assert!(
        refs.keys().any(|k| k.contains("master")),
        "expected a master branch in {refs:?}"
    );
    assert!(
        refs.keys().all(|k| !k.contains("refs/cobs/")),
        "COB refs must not appear in the branch list: {refs:?}"
    );
    assert!(
        refs.keys().all(|k| !k.contains("namespaces")),
        "namespaced refs must not appear in the branch list: {refs:?}"
    );
}

#[test]
fn list_repos_paginates_and_reports_has_more() {
    let fixture = init_profile("list-repos");
    init_repo(&fixture, "repo-one", "first");
    init_repo(&fixture, "repo-two", "second");
    let home = fixture.home();

    let all = parse(&radicle_local_ffi::local::list_repos(&home, "all", 0, 10));
    assert!(all.get("error").is_none(), "unexpected error: {all}");
    assert_eq!(
        all["items"].as_array().expect("items should be an array").len(),
        2,
        "both repos should be listed: {all}"
    );
    assert_eq!(all["hasMore"], false, "no further page exists: {all}");

    // A page smaller than the result set must report hasMore, and the two
    // pages together must cover every repo exactly once. Sorting is by rid,
    // so paging is stable.
    let first = parse(&radicle_local_ffi::local::list_repos(&home, "all", 0, 1));
    let second = parse(&radicle_local_ffi::local::list_repos(&home, "all", 1, 1));

    assert_eq!(first["items"].as_array().unwrap().len(), 1);
    assert_eq!(first["hasMore"], true, "a second page exists: {first}");
    assert_eq!(second["items"].as_array().unwrap().len(), 1);
    assert_eq!(second["hasMore"], false, "the last page: {second}");

    let a = first["items"][0]["rid"].as_str().unwrap();
    let b = second["items"][0]["rid"].as_str().unwrap();
    assert_ne!(a, b, "paging must not repeat the same repo");

    // Page numbers echo back, so a caller can correlate a reply with the
    // request that produced it -- the staleness-guard shape the QML side
    // already relies on.
    assert_eq!(first["page"], 0);
    assert_eq!(second["page"], 1);
}

#[test]
fn a_page_past_the_end_is_empty_not_an_error() {
    let fixture = init_profile("past-end");
    init_repo(&fixture, "only-repo", "the only one");

    let v = parse(&radicle_local_ffi::local::list_repos(
        &fixture.home(),
        "all",
        99,
        10,
    ));
    assert!(v.get("error").is_none(), "running off the end is not an error: {v}");
    assert_eq!(v["items"].as_array().unwrap().len(), 0);
    assert_eq!(v["hasMore"], false);
}

#[test]
fn an_empty_storage_lists_nothing_rather_than_failing() {
    let fixture = init_profile("empty-storage");

    let v = parse(&radicle_local_ffi::local::list_repos(
        &fixture.home(),
        "all",
        0,
        10,
    ));
    assert!(
        v.get("error").is_none(),
        "a node with no repos is empty, not broken: {v}"
    );
    assert_eq!(v["items"].as_array().unwrap().len(), 0);
}

#[test]
fn an_unknown_rid_reports_an_error_naming_the_repo() {
    let fixture = init_profile("unknown-rid");
    // Well-formed but absent, so this exercises the not-found path rather
    // than the parse path.
    let missing = "rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5";

    let v = parse(&radicle_local_ffi::local::get_repo(&fixture.home(), missing));
    let err = v["error"].as_str().expect("expected an error field");
    assert!(
        err.contains(missing),
        "the error should name the repo asked for: {err}"
    );
}

#[test]
fn a_malformed_rid_is_rejected_before_touching_storage() {
    let fixture = init_profile("malformed-rid");

    let v = parse(&radicle_local_ffi::local::get_repo(
        &fixture.home(),
        "not-a-rid",
    ));
    let err = v["error"].as_str().expect("expected an error field");
    assert!(
        err.contains("invalid repository id"),
        "expected a parse error, got: {err}"
    );
}

/// The "no local node" case must stay distinguishable from "no repositories":
/// `radicle_impl.h` documents that these are different answers, and the UI
/// renders them differently.
#[test]
fn a_missing_home_is_an_error_not_an_empty_list() {
    let v = parse(&radicle_local_ffi::local::list_repos("", "all", 0, 10));
    assert!(
        v["error"].as_str().is_some(),
        "an absent home is an error, not an empty list: {v}"
    );

    let dir = scratch_dir("no-such-home");
    let absent = dir.join("nonexistent").display().to_string();
    let v = parse(&radicle_local_ffi::local::list_repos(&absent, "all", 0, 10));
    assert!(
        v["error"].as_str().is_some(),
        "a home with no keystore is an error, not an empty list: {v}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
