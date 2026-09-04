//! Build a throwaway Radicle profile that a write can actually be aimed at,
//! and print its home so a caller can point `RAD_HOME` at it.
//!
//! Run with: cargo run --example seed_write_profile -- <dir>
//!
//! ## Why this exists, and why it is an example rather than a test
//!
//! `tests/ui/write.yaml` drives the comment box in a real Basecamp, which needs
//! three things no CI runner has: a Radicle profile, a **signable** key, and a
//! repository holding an **issue** to comment on. The other local spec
//! (`local.yaml`) needs only the first, which is why it can be pointed at
//! whatever the developer already has and is deliberately kept out of CI.
//!
//! A write spec cannot be. Aimed at a real profile it would append junk
//! comments to a real repository on every run, and it would depend on that
//! repository containing an issue — neither of which is acceptable for
//! something meant to run unattended. So the spec gets a profile built for it:
//! fresh per run, deleted after, containing exactly one repository and exactly
//! one issue with exactly one known comment in it. That is what makes the
//! spec's assertions exact ("the thread goes from 1 comment to 2") rather than
//! directional ("some number went up"), and what makes running it twice
//! identical to running it once.
//!
//! It is an **example** and not a test for the same reason `probe_signer` is:
//! it has no assertions and proves nothing on its own. It is a fixture builder
//! whose output is consumed by another layer. The `tests/` next door already
//! build the same shapes through the same public API (`tests/fixture/mod.rs`);
//! this is that code with a `main` on it, deliberately self-contained because
//! an example cannot import a test module.
//!
//! ## The keystore is plaintext, on purpose
//!
//! `Profile::init(.., None, ..)` writes the secret key unencrypted, which is
//! row 1 of the signer table in `docs/M2.2-write-actions-design.md`: a signer
//! loads with no passphrase, no `RAD_PASSPHRASE`, and no ssh-agent. That is the
//! only row a CI runner can be put in without either prompting or shipping a
//! passphrase, and it is what makes `canWriteLocal` true inside Basecamp.
//!
//! The key is therefore NOT a secret worth protecting — it is generated from a
//! fixed seed into a directory that is deleted after the run, and signs nothing
//! that leaves that directory. Do not point this at a real home: it refuses to
//! write into a directory that already exists, precisely so a mistyped argument
//! cannot land on `~/.radicle`.

use std::path::{Path, PathBuf};
use std::str::FromStr;

use radicle::cob::issue::Issues;
use radicle::cob::store::access::WriteAs;
use radicle::crypto::Seed;
use radicle::git::fmt::RefString;
use radicle::identity::project::ProjectName;
use radicle::identity::Visibility;
use radicle::node::Alias;
use radicle::profile::{Home, Profile};
use radicle::storage::ReadStorage as _;

/// The repository the spec opens. Named so a failure screenshot says which
/// repository is on screen without anyone having to guess.
const REPO_NAME: &str = "write-spec-fixture";
/// The issue the spec comments on, and its one existing comment. The spec
/// asserts the thread has exactly one comment before it posts, so this string
/// being the *only* body in the thread is part of the contract between the two
/// files.
const ISSUE_TITLE: &str = "A seeded issue for the write spec";
const ISSUE_BODY: &str = "This issue exists so the write spec has a thread to comment on.";

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(target) = args.next() else {
        eprintln!("usage: cargo run --example seed_write_profile -- <dir>");
        eprintln!();
        eprintln!("Builds a fresh Radicle profile under <dir> and prints the");
        eprintln!("home path, the repository id and the issue id, one per line.");
        std::process::exit(2);
    };

    let dir = PathBuf::from(&target);
    // Refusing rather than clearing. `rm -rf` on a path that came from an
    // argument is how a seeding helper eats somebody's ~/.radicle; making the
    // caller own the directory's lifetime costs one mkdir and removes that
    // failure entirely.
    if dir.exists() {
        eprintln!("seed_write_profile: {} already exists", dir.display());
        eprintln!("  Refusing to write into an existing directory — pass a fresh path.");
        std::process::exit(1);
    }
    std::fs::create_dir_all(&dir).expect("could not create the target directory");

    let home_dir = dir.join("home");
    let home = Home::new(&home_dir).expect("could not create a Radicle home");
    // `None` = plaintext keystore. See the module docs: this is the one signer
    // row a CI runner can be placed in, and the key is throwaway by
    // construction.
    let profile = Profile::init(home, Alias::new("write-spec"), None, Seed::new([9u8; 32]))
        .expect("could not init the profile");

    let (rid, _work) = init_repo(&profile, &dir);
    let issue = create_issue(&profile, &rid);

    // Three lines, in a fixed order, so the wrapper script can read them
    // positionally without parsing. Anything diagnostic goes to stderr so it
    // cannot be mistaken for one of them.
    println!("{}", home_dir.display());
    println!("{rid}");
    println!("{issue}");
}

/// A git working copy pushed into storage as a real Radicle repository.
///
/// Deliberately the same sequence `tests/fixture/mod.rs` uses — `git init`,
/// commit, `rad::init` — because that is the sequence `rad init` itself
/// performs, and a fixture built any other way would be proving something about
/// a shape the product never produces.
fn init_repo(profile: &Profile, dir: &Path) -> (String, PathBuf) {
    let work = dir.join("work");
    std::fs::create_dir_all(work.join("src")).expect("could not create the working copy");

    let repo = radicle::git::raw::Repository::init(&work).expect("git init failed");
    std::fs::write(
        work.join("README.md"),
        "# write-spec-fixture\n\nSeeded for tests/ui/write.yaml.\n",
    )
    .expect("could not write README.md");
    std::fs::write(work.join("src/main.rs"), "fn main() {}\n").expect("could not write main.rs");

    commit_all(&repo, "initial");

    let signer = profile.signer().expect("could not load a signer");
    let (rid, _, _) = radicle::rad::init(
        &repo,
        ProjectName::from_str(REPO_NAME).expect("invalid project name"),
        "Seeded repository for the write end-to-end spec",
        RefString::try_from("master").expect("invalid branch name"),
        Visibility::default(),
        &signer,
        &profile.storage,
    )
    .expect("rad init failed");

    (rid.urn(), work)
}

fn commit_all(repo: &radicle::git::raw::Repository, message: &str) {
    let mut index = repo.index().expect("no index");
    index
        .add_all(["*"], git2::IndexAddOption::DEFAULT, None)
        .expect("could not stage files");
    index.write().expect("could not write the index");
    let tree_id = index.write_tree().expect("could not write the tree");
    let tree = repo.find_tree(tree_id).expect("no tree");
    let sig = radicle::git::raw::Signature::now("write-spec", "write-spec@example.com")
        .expect("could not build a signature");

    repo.commit(Some("HEAD"), &sig, &sig, message, &tree, &[])
        .expect("could not commit");
}

/// One issue, created through the COB store exactly as the `rad` CLI does.
///
/// `NoCache` rather than the SQLite cache for the same reason the read path
/// uses it (see CLAUDE.md, M2.1): the cache is `rad`'s own read-through
/// optimisation, not a correctness dependency, and owning a database file's
/// lifecycle here would buy nothing.
fn create_issue(profile: &Profile, rid: &str) -> String {
    let id = radicle::identity::RepoId::from_urn(rid).expect("valid rid");
    let repo = profile.storage.repository(id).expect("repo in storage");
    let signer = profile.signer().expect("could not load a signer");

    let mut store = Issues::open(&repo, WriteAs::new(&signer)).expect("could not open the issues");
    let mut cache = radicle::cob::cache::NoCache;
    let issue = store
        .create(
            ISSUE_TITLE.parse().expect("valid title"),
            ISSUE_BODY,
            &[],
            &[],
            [],
            &mut cache,
        )
        .expect("could not create the issue");

    issue.id().to_string()
}
