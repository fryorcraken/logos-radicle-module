//! Creating a Radicle identity, and proving the identities are separate.
//!
//! ## The one assertion that carries this file
//!
//! `two_homes_get_two_different_identities` is the test the whole embedded mode
//! rests on, and it is written the way it is because the obvious version cannot
//! fail. Isolation has an easy false proof: init two profiles, check the two
//! directories differ, check both hold a key. That passes against an
//! implementation with a hardcoded seed — which is not hypothetical, it is
//! exactly what `tests/fixture/mod.rs` does deliberately (`Seed::new([7u8;32])`,
//! fixed so failures reproduce). Two homes, one identity, every
//! directory-shaped assertion green.
//!
//! So the assertion is on the **node ids**, and that they *differ*. That is the
//! input-dependent form CLAUDE.md's branch-switch lesson asks for: a fixture
//! answering the same for every input cannot tell working from broken.
//!
//! ## Never the developer's real profile
//!
//! Every home here is under this crate's own `tmp/` and removed on drop, via
//! the same `fixture::scratch_dir` the read tests use. Nothing in this file
//! reads `RAD_HOME` or `HOME`, and nothing may: a test that created an identity
//! in a real `~/.radicle` would be writing a permanent key into a directory it
//! then deletes.

mod fixture;

use fixture::{parse, scratch_dir};
use radicle_local_ffi::profileinit::{init_profile, profile_exists};

/// A scratch home path that does not exist yet — `init_profile` creates it.
///
/// Deliberately a path *inside* a fresh scratch dir rather than the scratch dir
/// itself, so the "creates its own home" behaviour is exercised rather than
/// assumed.
fn fresh_home(name: &str) -> (std::path::PathBuf, String) {
    let dir = scratch_dir(name);
    let home = dir.join("home");
    let s = home.display().to_string();
    (dir, s)
}

fn cleanup(dir: &std::path::Path) {
    let _ = std::fs::remove_dir_all(dir);
}

/// **The isolation test.** Two homes must yield two *different* identities.
///
/// Asserting on the node ids rather than on the paths is the whole point: see
/// this file's header for why the path-shaped version of this test passes
/// against an implementation that gives every profile the same key.
#[test]
fn two_homes_get_two_different_identities() {
    let (dir_a, home_a) = fresh_home("profile-init-iso-a");
    let (dir_b, home_b) = fresh_home("profile-init-iso-b");

    let a = parse(&init_profile(&home_a, "alice", ""));
    let b = parse(&init_profile(&home_b, "bob", ""));

    let nid_a = a["nodeId"].as_str().unwrap_or_default().to_string();
    let nid_b = b["nodeId"].as_str().unwrap_or_default().to_string();

    assert!(!nid_a.is_empty(), "first profile reported no node id: {a}");
    assert!(!nid_b.is_empty(), "second profile reported no node id: {b}");
    assert_ne!(
        nid_a, nid_b,
        "two embedded profiles share one identity — an embedded node would be \
         indistinguishable from any other, which is the whole property this \
         mode promises. A fixed seed produces exactly this."
    );

    // And neither wrote into the other. Checked after the ids, because a shared
    // identity is the failure that matters and this would pass regardless of it.
    assert!(
        profile_exists(&home_a) && profile_exists(&home_b),
        "each home must hold its own profile"
    );
    assert!(
        !home_a.starts_with(&home_b) && !home_b.starts_with(&home_a),
        "the homes must not nest: {home_a} / {home_b}"
    );

    cleanup(&dir_a);
    cleanup(&dir_b);
}

/// The identity is real, not merely reported: a fresh read of the keystore
/// must agree with what creation claimed.
///
/// Without this, `init_profile` could return a well-formed node id it invented
/// and never wrote, and every other test here would still pass.
#[test]
fn the_reported_identity_is_the_one_actually_on_disk() {
    let (dir, home) = fresh_home("profile-init-readback");

    let created = parse(&init_profile(&home, "tester", ""));
    let claimed = created["nodeId"].as_str().unwrap_or_default();

    // `node_id` is the module's own independent read of `keys/radicle.pub` —
    // the same path `getCapabilities()` reports the identity through, so this
    // also pins that the two agree.
    let read_back = parse(&radicle_local_ffi::env::node_id(&home));

    assert_eq!(
        claimed,
        read_back["nodeId"].as_str().unwrap_or_default(),
        "creation reported an identity the keystore does not hold"
    );

    cleanup(&dir);
}

/// **An existing profile is refused, never overwritten.**
///
/// This is the irreversible one. A second init over a live keystore destroys a
/// signing key that *is* the user's identity, and nothing recovers it.
///
/// ## Why this asserts on the message and not just on failure
///
/// There are **two** guards against a second init: this module's, and the
/// crate's own — `Keystore::init` returns `Error::AlreadyInitialized`
/// (`radicle-crypto-0.19.0/src/ssh/keystore.rs:121-133`). So "the second call
/// errored" is true with our guard deleted, and an earlier version of this test
/// asserted exactly that and passed against a build with no guard at all.
///
/// Asserting that the error *names the home* does not separate them either:
/// the crate's message embeds the offending file path, which contains the home.
/// That is the same-answer-for-every-input trap CLAUDE.md documents, on the one
/// operation in this module that cannot be undone.
///
/// What distinguishes them is the wording, so that is what is asserted. Ours
/// names the consequence ("would overwrite its signing key"); the crate's
/// describes a file ("keystore already initialized"). Verified by mutation:
/// removing our guard makes this test fail while the other eight stay green.
#[test]
fn a_second_init_is_refused_and_leaves_the_first_identity_intact() {
    let (dir, home) = fresh_home("profile-init-refuse");

    let first = parse(&init_profile(&home, "tester", ""));
    let original = first["nodeId"].as_str().unwrap_or_default().to_string();
    assert!(!original.is_empty(), "precondition: a profile was created");

    let second = parse(&init_profile(&home, "someone-else", ""));
    let message = second["error"].as_str().unwrap_or_default();
    assert!(
        !message.is_empty(),
        "a second init must be refused, got: {second}"
    );
    assert!(
        message.contains(&home),
        "the refusal must name the home that was in the way, got: {second}"
    );
    // The part only THIS module's guard produces. Without it the crate refuses
    // too, with a message about a keystore file — a correct refusal, but one
    // that arrives after `Home::new` has already built the directory tree, and
    // one that does not tell the user what was at stake.
    assert!(
        message.contains("would overwrite its signing key"),
        "the refusal must be this module's, which fires before any directory \
         is created and names the consequence — a message about a keystore \
         file is the crate's guard, reached only because ours was removed. \
         Got: {second}"
    );

    // The assertion that actually matters: the key is untouched. A refusal that
    // reported an error *after* rewriting the keystore would pass the check
    // above and still have destroyed the identity.
    let after = parse(&radicle_local_ffi::env::node_id(&home));
    assert_eq!(
        original,
        after["nodeId"].as_str().unwrap_or_default(),
        "the refused init changed the identity on disk"
    );

    cleanup(&dir);
}

/// A home that exists but holds no keys is a legitimate place to create one.
///
/// This is not a corner case: the embedded home is a directory this module
/// creates and may already have made — for settings, or on a run that failed
/// between `mkdir` and keygen. Treating "the directory is there" as "a profile
/// is there" would make such a setup permanently uncompletable, with an error
/// blaming a profile that does not exist.
#[test]
fn an_empty_directory_is_not_mistaken_for_an_existing_profile() {
    let (dir, home) = fresh_home("profile-init-empty-dir");
    std::fs::create_dir_all(&home).expect("could not pre-create the home");

    assert!(
        !profile_exists(&home),
        "an empty directory must not read as a profile"
    );

    let created = parse(&init_profile(&home, "tester", ""));
    assert!(
        created["created"].as_bool().unwrap_or(false),
        "creating into an existing empty directory must work, got: {created}"
    );

    cleanup(&dir);
}

/// An empty passphrase means an unencrypted key, and the reply says so.
///
/// The pair below is the point: both directions are asserted, because a
/// reply that hardcoded `encrypted` either way would pass one of them alone.
#[test]
fn an_empty_passphrase_yields_an_unencrypted_key_and_reports_it() {
    let (dir, home) = fresh_home("profile-init-plain");

    let created = parse(&init_profile(&home, "tester", ""));
    assert_eq!(
        created["encrypted"],
        serde_json::json!(false),
        "an empty passphrase must be reported as unencrypted: {created}"
    );

    // Reported and true: the module's own write path can load a signer with no
    // prompt, which is only possible against a plaintext keystore.
    let can = parse(&radicle_local_ffi::cobwrite::can_write(&home));
    assert_eq!(
        can["canWrite"],
        serde_json::json!(true),
        "an unencrypted key must be immediately signable: {can}"
    );

    cleanup(&dir);
}

/// And a passphrase actually encrypts. Asserted through `can_write`, which
/// needs the *private* half — the only observation that distinguishes an
/// encrypted keystore from a plaintext one from outside.
///
/// This is the half that proves `encrypted` is derived rather than echoed.
#[test]
fn a_passphrase_encrypts_the_key_and_reports_it() {
    let (dir, home) = fresh_home("profile-init-encrypted");

    let created = parse(&init_profile(&home, "tester", "correct horse battery"));
    assert_eq!(
        created["encrypted"],
        serde_json::json!(true),
        "a non-empty passphrase must be reported as encrypted: {created}"
    );

    // With no RAD_PASSPHRASE and no agent holding this brand-new key, a signer
    // cannot be loaded — which is exactly what "encrypted" has to mean for it
    // to be worth reporting.
    let can = parse(&radicle_local_ffi::cobwrite::can_write(&home));
    assert_eq!(
        can["canWrite"],
        serde_json::json!(false),
        "an encrypted key must not be signable without its passphrase: {can}"
    );

    cleanup(&dir);
}

/// The created profile is a real one the existing read path can open.
///
/// `init_profile` returning success while producing something `open_storage`
/// refuses would be a profile in name only, and every assertion above would
/// still pass. This is the cheapest end-to-end statement that it is not.
#[test]
fn the_created_profile_is_readable_by_the_existing_local_path() {
    let (dir, home) = fresh_home("profile-init-readable");

    let created = parse(&init_profile(&home, "tester", ""));
    assert!(created["created"].as_bool().unwrap_or(false), "{created}");

    // An empty storage lists nothing rather than failing — the same assertion
    // `local_storage.rs` makes against a fixture-built profile. Reaching it
    // through a profile this module created is the point.
    let repos = parse(&radicle_local_ffi::local::list_repos(&home, "all", 1, 10));
    assert!(
        repos["error"].is_null(),
        "the created profile must be readable, got: {repos}"
    );
    assert_eq!(
        repos["items"].as_array().map(|a| a.len()),
        Some(0),
        "a fresh profile holds no repositories: {repos}"
    );

    cleanup(&dir);
}

/// A bad alias is refused *before* anything is created.
///
/// Asserted by the absence of a home afterwards, not by the error text alone:
/// an implementation that created the home, then validated, then errored would
/// report the same message and leave a half-made profile behind for the next
/// attempt to trip over.
#[test]
fn a_bad_alias_is_refused_and_creates_nothing() {
    let (dir, home) = fresh_home("profile-init-bad-alias");

    let out = parse(&init_profile(&home, "not a valid alias", ""));
    assert!(
        out["error"].is_string(),
        "an alias with whitespace must be refused, got: {out}"
    );
    assert!(
        !std::path::Path::new(&home).exists(),
        "a refused init must not leave a home behind"
    );

    cleanup(&dir);
}

/// A relative home is refused rather than resolved against the process CWD.
///
/// Symmetric with `env.rs`'s relative-git-path refusal, and for a stronger
/// reason: this writes a permanent signing key, and a Basecamp-launched
/// module's working directory is not something the user chose or can see.
///
/// The assertion is that **nothing was created anywhere** — not merely that an
/// error came back. A guard that errored after `Home::new` would leave a
/// profile at whatever the CWD happened to be, which is precisely the failure,
/// and "it returned an error" would not notice.
#[test]
fn a_relative_home_is_refused_rather_than_resolved_against_the_working_directory() {
    let cwd = std::env::current_dir().expect("no working directory");
    let relative = "tmp/profile-init-relative-must-not-appear";

    let out = parse(&init_profile(relative, "tester", ""));
    assert!(
        out["error"].is_string(),
        "a relative home must be refused, got: {out}"
    );
    assert!(
        out["error"].as_str().unwrap().contains("absolute"),
        "the refusal must say what was wrong with it, got: {out}"
    );
    assert!(
        !cwd.join(relative).exists(),
        "a refused init resolved the relative path anyway and created {}",
        cwd.join(relative).display()
    );
}

/// The FFI boundary answers with JSON rather than unwinding.
///
/// `panic_guard.rs` covers the read and write entry points on the same
/// principle; this adds the one that *creates* state, where a panic would land
/// mid-keygen with a half-written keystore on disk.
#[test]
fn the_init_entry_point_is_guarded() {
    use std::ffi::{CStr, CString};

    // A NUL home reaches `read_str`'s empty-string path; a home under a path
    // that cannot be created exercises the crate's own error path. Neither may
    // cross the boundary as a panic.
    let bad = CString::new("/proc/nonexistent-cannot-create/home").unwrap();
    let alias = CString::new("tester").unwrap();
    let pass = CString::new("").unwrap();

    for home in [std::ptr::null(), bad.as_ptr()] {
        let raw = unsafe {
            radicle_local_ffi::radicle_local_init_profile(home, alias.as_ptr(), pass.as_ptr())
        };
        assert!(!raw.is_null());
        let text = unsafe { CStr::from_ptr(raw) }
            .to_string_lossy()
            .into_owned();
        unsafe { radicle_local_ffi::radicle_free_string(raw) };

        let v: serde_json::Value = serde_json::from_str(&text)
            .unwrap_or_else(|e| panic!("not JSON across the boundary: {e}\n{text}"));
        assert!(
            v["error"].is_string(),
            "an unusable home must come back as an error object, got: {v}"
        );
    }
}
