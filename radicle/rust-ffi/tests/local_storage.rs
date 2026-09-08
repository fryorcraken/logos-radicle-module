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
use radicle::crypto::Signer;
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
    init_repo_with(fixture, name, description, Visibility::default())
}

/// As `init_repo`, but private. A private repository is the case that
/// justifies local browsing existing at all — a seed never shows one — so the
/// `scope: "private"` filter needs a positive example, not only the empty one.
fn init_private_repo(fixture: &Fixture, name: &str, description: &str) -> String {
    init_repo_with(fixture, name, description, Visibility::private([]))
}

fn init_repo_with(
    fixture: &Fixture,
    name: &str,
    description: &str,
    visibility: Visibility,
) -> String {
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
        visibility,
        &signer,
        storage,
    )
    .expect("rad init failed");

    rid.urn()
}

/// Create branches under a peer's namespace and sign them, the way real
/// storage holds every peer's branches:
/// `refs/namespaces/<nid>/refs/heads/<branch>`, attested by that peer's
/// `rad/sigrefs`.
///
/// This is the shape that made the branch picker show one entry for every
/// repo. A fixture that only ever calls `rad::init` cannot expose it — the
/// canonical `refs/heads/<default>` that `init` writes is exactly the one ref
/// the old glob did find, so the bug was invisible to a self-consistent
/// fixture. Confirmed against this machine's real storage with
/// `rad inspect --refs` before being written here.
///
/// The refs must be *signed*, not merely written: `list_branches` reads
/// `remotes()`, which replays each peer's signed ref set rather than globbing
/// raw namespaces. Writing a bare git ref and skipping the signature would
/// produce a fixture that fails for a reason unrelated to the bug.
fn init_signed_branches(fixture: &Fixture, rid: &str, signer: &impl Signer, branches: &[&str]) {
    let id = radicle::identity::RepoId::from_urn(rid).expect("invalid rid");
    let repo = radicle::storage::ReadStorage::repository(&fixture.profile.storage, id)
        .expect("repo not in storage");
    let remote = signer.public_key();

    // Point every new branch at whatever the canonical head already is: these
    // tests are about which refs are *found*, not about divergent history.
    let head = radicle::storage::WriteRepository::raw(&repo)
        .revparse_single("refs/heads/master")
        .expect("no canonical master in fixture")
        .peel_to_commit()
        .expect("master is not a commit")
        .id();

    for branch in branches {
        radicle::storage::WriteRepository::raw(&repo)
            .reference(
                &format!("refs/namespaces/{remote}/refs/heads/{branch}"),
                head,
                true,
                "fixture branch",
            )
            .expect("could not create namespaced branch");
    }

    radicle::storage::SignRepository::sign_refs(&repo, signer).expect("could not sign refs");
}

/// A throwaway keypair standing in for another peer on the network. Real
/// rather than a literal node-id string because signing that peer's refs
/// needs its private half.
fn peer_signer(seed: u8) -> radicle::crypto::SigningKey {
    radicle::crypto::SigningKey::from_seed(Seed::new([seed; 32]))
}

/// The local node's own signer — the namespace the user's own branches live
/// under.
fn local_signer(fixture: &Fixture) -> impl Signer {
    fixture.profile.signer().expect("could not load signer")
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
        all["items"]
            .as_array()
            .expect("items should be an array")
            .len(),
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
    assert!(
        v.get("error").is_none(),
        "running off the end is not an error: {v}"
    );
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

    let v = parse(&radicle_local_ffi::local::get_repo(
        &fixture.home(),
        missing,
    ));
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

/// Scope narrows the list. The fixture's node is the delegate of every repo it
/// creates, so "delegate" sees them all and "seeded" — other people's public
/// work — sees none. That asymmetry is the point: it proves the filter is
/// actually reading the identity document rather than passing everything
/// through, which is what the previous implementation did.
#[test]
fn list_repos_narrows_by_scope() {
    let fixture = init_profile("scope");
    init_repo(&fixture, "mine-one", "first");
    init_repo(&fixture, "mine-two", "second");
    // A private repo is what justifies local browsing existing at all — a seed
    // never shows one. Without a positive example here, `count("private") == 0`
    // passed just as happily against a filter that returned nothing for every
    // input, which is the "a fake that answers the same for every input cannot
    // tell working from broken" trap this repo has been bitten by before.
    init_private_repo(&fixture, "secret", "not for the seed");
    let home = fixture.home();

    let count = |scope: &str| {
        let v = parse(&radicle_local_ffi::local::list_repos(&home, scope, 0, 10));
        assert!(
            v.get("error").is_none(),
            "unexpected error for {scope}: {v}"
        );
        v["items"].as_array().expect("items").len()
    };

    assert_eq!(count("all"), 3, "'all' lists everything");
    assert_eq!(count(""), 3, "an empty scope means all");
    assert_eq!(count("delegate"), 3, "this node delegates all three repos");
    assert_eq!(
        count("seeded"),
        0,
        "'seeded' is other people's repos, and there are none here"
    );
    assert_eq!(
        count("private"),
        1,
        "'private' finds the one private repo and not the two public ones"
    );
    // An unrecognized scope shows everything rather than nothing: an empty
    // list would be indistinguishable from a node with no repositories.
    assert_eq!(count("no-such-scope"), 3);
}

/// `visibility` and `delegates` are read by `RepoList.qml` (the private badge)
/// and are part of the shape `remoteGetRepo` returns, so a local repo must
/// carry them too or the two sources render differently.
#[test]
fn get_repo_reports_visibility_and_delegates() {
    let fixture = init_profile("visibility");
    let rid = init_repo(&fixture, "public-repo", "a public one");

    let v = parse(&radicle_local_ffi::local::get_repo(&fixture.home(), &rid));
    assert!(v.get("error").is_none(), "unexpected error: {v}");

    // `Visibility` derives `tag = "type"`, so this is the exact string
    // RepoList.qml compares against "private".
    assert_eq!(v["visibility"]["type"], "public", "got {v}");

    let delegates = v["delegates"].as_array().expect("delegates array");
    assert_eq!(delegates.len(), 1, "the creating node is the delegate: {v}");
    assert!(
        delegates[0]["id"]
            .as_str()
            .unwrap_or("")
            .starts_with("did:key:"),
        "a delegate is identified by DID: {v}"
    );
}

/// The bug this file's `init_namespaced_branch` helper exists for: branches
/// live under `refs/namespaces/<nid>/refs/heads/*`, not the canonical
/// `refs/heads/*`, so globbing the latter found exactly one branch per repo.
#[test]
fn list_branches_finds_branches_under_the_local_namespace() {
    let fixture = init_profile("branches-local");
    let rid = init_repo(&fixture, "proj", "a repo");
    let me = local_signer(&fixture);
    init_signed_branches(&fixture, &rid, &me, &["develop", "feature/thing"]);

    let v = parse(&radicle_local_ffi::local::list_branches(
        &fixture.home(),
        &rid,
    ));
    let items = v["items"].as_array().expect("items is an array");
    let names: Vec<&str> = items.iter().filter_map(|i| i["name"].as_str()).collect();

    assert!(
        names.contains(&"develop") && names.contains(&"feature/thing"),
        "own-namespace branches must be listed, got {names:?}"
    );
    assert!(
        names.contains(&"master"),
        "the default branch must still be listed, got {names:?}"
    );
    assert!(
        items.iter().all(|i| i["isLocal"] == true),
        "every branch here is the local node's: {v}"
    );
}

/// A local branch keeps its bare name, so it resolves exactly as it did
/// before this change — `resolveSha` and every `local*` read are keyed on it.
#[test]
fn a_peer_branch_is_qualified_by_node_id_and_a_local_one_is_not() {
    let fixture = init_profile("branches-peer");
    let rid = init_repo(&fixture, "proj", "a repo");
    let me = local_signer(&fixture);
    let peer = peer_signer(42);
    let peer_nid = peer.public_key().to_string();
    init_signed_branches(&fixture, &rid, &me, &["develop"]);
    init_signed_branches(&fixture, &rid, &peer, &["develop"]);

    let v = parse(&radicle_local_ffi::local::list_branches(
        &fixture.home(),
        &rid,
    ));
    let items = v["items"].as_array().expect("items is an array");

    let local: Vec<&str> = items
        .iter()
        .filter(|i| i["isLocal"] == true)
        .filter_map(|i| i["name"].as_str())
        .collect();
    let peers: Vec<&str> = items
        .iter()
        .filter(|i| i["isLocal"] == false)
        .filter_map(|i| i["name"].as_str())
        .collect();

    assert!(
        local.contains(&"develop"),
        "the local branch keeps its bare name: {local:?}"
    );
    assert!(
        peers.contains(&format!("{peer_nid}/develop").as_str()),
        "a peer branch is qualified by node id: {peers:?}"
    );
    // Two branches share the name `develop`; qualifying the peer's is what
    // stops one shadowing the other in the picker and, worse, resolving to
    // the wrong commit. Asserted as "both survive" rather than a total count,
    // because how many refs `rad::init` and `sign_refs` seed a namespace with
    // is the crate's business, not this test's.
    assert_eq!(
        local.iter().filter(|n| **n == "develop").count(),
        1,
        "exactly one local develop: {local:?}"
    );
    assert_eq!(
        peers
            .iter()
            .filter(|n| **n == format!("{peer_nid}/develop"))
            .count(),
        1,
        "exactly one peer develop, not collapsed into the local one: {peers:?}"
    );
}

/// Ordering is load-bearing: the picker draws its separator at the first
/// non-local entry, so a peer branch sorting above a local one would put the
/// divider in the wrong place.
#[test]
fn local_branches_are_listed_before_peer_branches() {
    let fixture = init_profile("branches-order");
    let rid = init_repo(&fixture, "proj", "a repo");
    let me = local_signer(&fixture);
    let peer = peer_signer(43);
    // `aaa` sorts before every local branch name, so a single flat sort over
    // the merged list would pull this peer entry to the top. Only grouping
    // local-first keeps it below.
    init_signed_branches(&fixture, &rid, &peer, &["aaa"]);
    init_signed_branches(&fixture, &rid, &me, &["zzz"]);

    let v = parse(&radicle_local_ffi::local::list_branches(
        &fixture.home(),
        &rid,
    ));
    let items = v["items"].as_array().expect("items is an array");

    let first_peer = items.iter().position(|i| i["isLocal"] == false);
    let last_local = items.iter().rposition(|i| i["isLocal"] == true);
    assert!(
        matches!((first_peer, last_local), (Some(p), Some(l)) if l < p),
        "every local branch precedes every peer branch: {v}"
    );
}

/// `refs/heads/patches/<id>` is a patch head, not a branch. On a real profile
/// these outnumber branches roughly 8:1 (heartwood: 658 refs, 84 branches),
/// so listing them would bury the branches the picker exists to show.
#[test]
fn patch_refs_are_not_listed_as_branches() {
    let fixture = init_profile("branches-patches");
    let rid = init_repo(&fixture, "proj", "a repo");
    let me = local_signer(&fixture);
    init_signed_branches(
        &fixture,
        &rid,
        &me,
        &[
            "develop",
            "patches/0026238e8d80d8539759bbd427c9b4d5f22342e4",
        ],
    );

    let v = parse(&radicle_local_ffi::local::list_branches(
        &fixture.home(),
        &rid,
    ));
    let items = v["items"].as_array().expect("items is an array");
    let names: Vec<&str> = items.iter().filter_map(|i| i["name"].as_str()).collect();

    assert!(
        names.contains(&"develop"),
        "a real branch is still listed: {names:?}"
    );
    assert!(
        !names.iter().any(|n| n.contains("patches/")),
        "patch refs are not branches: {names:?}"
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
