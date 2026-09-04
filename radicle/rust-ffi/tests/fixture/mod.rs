//! Shared fixture builder: a real Radicle profile with real repositories, on
//! disk, built through the crate's *public* API.
//!
//! `radicle::test` is crate-internal, so this assembles a profile the same way
//! `rad auth` + `rad init` do: `Profile::init` writes a keystore and storage
//! root, and `rad::init` pushes a git working copy into that storage as a real
//! Radicle repository.
//!
//! Scratch homes live under this crate's own `tmp/` (gitignored), never
//! `/tmp`: everything a test writes stays inside the working directory, and
//! `Fixture`'s `Drop` removes it.

#![allow(dead_code)] // each test file uses a different subset

use std::path::{Path, PathBuf};
use std::str::FromStr;

use radicle::crypto::Seed;
use radicle::git::fmt::RefString;
use radicle::identity::project::ProjectName;
use radicle::identity::Visibility;
use radicle::node::Alias;
use radicle::profile::{Home, Profile};

pub struct Fixture {
    pub dir: PathBuf,
    pub profile: Profile,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Fixture {
    pub fn home(&self) -> String {
        self.profile.home().path().display().to_string()
    }
}

pub fn scratch_dir(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tmp").join(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("could not create scratch dir");
    dir
}

/// A profile with a keystore and an empty storage root. The seed is fixed
/// rather than random so a failure reproduces identically.
pub fn init_profile(name: &str) -> Fixture {
    let dir = scratch_dir(name);
    let home = Home::new(dir.join("home")).expect("could not create Radicle home");
    // No passphrase: the key is written unencrypted, which is what lets the
    // read path work with no prompt. That is a property under test.
    let profile = Profile::init(home, Alias::new("tester"), None, Seed::new([7u8; 32]))
        .expect("could not init profile");
    Fixture { dir, profile }
}

/// A git working copy with a known file layout, pushed into storage as a
/// Radicle repo. Returns `(rid, working-copy path)`.
///
/// The layout is fixed so tree/blob/readme tests can assert on exact names:
///
/// ```text
/// README.md          "# fixture\n\nHello.\n"
/// src/main.rs        "fn main() {}\n"
/// src/lib.rs         "pub fn one() -> u32 { 1 }\n"
/// data/binary.bin    3 bytes with an embedded NUL
/// ```
pub fn init_repo(fixture: &Fixture, name: &str, description: &str) -> (String, PathBuf) {
    let work = fixture.dir.join(format!("work-{name}"));
    std::fs::create_dir_all(work.join("src")).expect("could not create working copy dir");
    std::fs::create_dir_all(work.join("data")).expect("could not create data dir");

    let repo = radicle::git::raw::Repository::init(&work).expect("git init failed");

    std::fs::write(work.join("README.md"), "# fixture\n\nHello.\n").expect("write README");
    std::fs::write(work.join("src/main.rs"), "fn main() {}\n").expect("write main.rs");
    std::fs::write(work.join("src/lib.rs"), "pub fn one() -> u32 { 1 }\n").expect("write lib.rs");
    // An embedded NUL is exactly git's own binary heuristic, so this file must
    // come back as `binary: true` with no content.
    std::fs::write(work.join("data/binary.bin"), [0x00u8, 0x01, 0x02]).expect("write binary");

    commit_all(&repo, "initial");

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

    (rid.urn(), work)
}

/// Stage everything in the working copy and commit it onto HEAD.
pub fn commit_all(repo: &radicle::git::raw::Repository, message: &str) -> String {
    let mut index = repo.index().expect("no index");
    index
        .add_all(["*"], git2::IndexAddOption::DEFAULT, None)
        .expect("could not stage files");
    index.write().expect("could not write index");
    let tree_id = index.write_tree().expect("could not write tree");
    let tree = repo.find_tree(tree_id).expect("no tree");
    let sig = radicle::git::raw::Signature::now("tester", "tester@example.com")
        .expect("could not build signature");

    let parents = match repo.head().ok().and_then(|h| h.peel_to_commit().ok()) {
        Some(ref parent) => vec![parent.clone()],
        None => vec![],
    };
    let parent_refs: Vec<&radicle::git::raw::Commit> = parents.iter().collect();

    let oid = repo
        .commit(Some("HEAD"), &sig, &sig, message, &tree, &parent_refs)
        .expect("could not commit");
    oid.to_string()
}

/// Publish the working copy's current `master` into Radicle storage, the way
/// `rad push` does, and move storage's own `HEAD` to match.
///
/// `rad::init` pushes the *initial* commit into storage and configures the
/// `rad` remote; later commits stay in the working copy until pushed. Without
/// this, a test that commits more history and then reads it back through
/// storage sees only the initial commit — which is how the first draft of
/// `list_commits_paginates_newest_first` failed, correctly.
///
/// Storage keeps each peer's refs under `refs/namespaces/<node-key>/`, so the
/// push target is namespaced and `HEAD` is then pointed at the namespaced
/// branch. `Repository::head()` prefers storage's local `HEAD` before falling
/// back to a quorum computation, so setting it is what makes the new commits
/// visible to every read in this crate.
pub fn publish(fixture: &Fixture, work: &Path, rid: &str) {
    let repo = git2::Repository::open(work).expect("open working copy");
    let key = fixture
        .profile
        .public_key
        .to_human()
        .parse::<String>()
        .unwrap_or_else(|_| fixture.profile.public_key.to_human());

    // The `rad://` remote URL `rad::init` configures is *already* scoped to
    // this node's namespace, so the refspec must be the plain branch name.
    // Spelling the namespace out here too produces
    // `refs/namespaces/<key>/refs/namespaces/<key>/refs/heads/master` — a ref
    // nothing reads, so the push "succeeds" and the new commits stay
    // invisible. That is exactly how the first draft of this helper failed.
    let mut remote = repo.find_remote("rad").expect("rad remote from rad::init");
    remote
        .push(&["+refs/heads/master:refs/heads/master"], None)
        .expect("could not push into storage");

    let id = radicle::identity::RepoId::from_urn(rid).expect("valid rid");
    let stored = radicle::storage::ReadStorage::repository(&fixture.profile.storage, id)
        .expect("repo in storage");

    // Re-sign the refs so the repo's own signed-refs record matches what was
    // just pushed, exactly as `rad push` does.
    use radicle::storage::SignRepository as _;
    use radicle::storage::WriteRepository as _;
    let signer = fixture.profile.signer().expect("signer");
    stored.sign_refs(&signer).expect("could not sign refs");

    // `Repository::head()` prefers storage's own `HEAD` before falling back to
    // a quorum computation over delegates' refs, so pointing it at this node's
    // namespaced branch is what makes the pushed commits visible to reads.
    stored
        .raw()
        .set_head(&format!("refs/namespaces/{key}/refs/heads/master"))
        .expect("could not move storage HEAD");
}

pub fn parse(json: &str) -> serde_json::Value {
    serde_json::from_str(json).unwrap_or_else(|e| panic!("not valid JSON: {e}\n{json}"))
}
