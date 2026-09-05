//! Writing COBs: posting a comment on an issue, against a real profile.
//!
//! The fixture profile is created with `None` for the passphrase, so its
//! keystore is plaintext and `signer()` takes its first branch. That is a
//! deliberate limit of this layer and worth stating plainly: these tests prove
//! the *write* works, not that every signer source works. The other three
//! sources (RAD_PASSPHRASE, ssh-agent holding the key, ssh-agent not holding
//! it) depend on process environment and on what a machine's agent is holding,
//! which no fixture can create — `examples/probe_signer.rs` reports those, and
//! `can_write` is the surface that carries the answer to the UI.
//!
//! What every test here does have is a **fresh read after the write**. A write
//! that returned an id but persisted nothing would satisfy an assertion on its
//! own return value; only re-reading through `cobs::get_issue` — the same path
//! the UI uses — proves the comment is actually in the thread.

mod fixture;

use fixture::{init_profile, init_repo, parse, Fixture};

use radicle::cob::issue::Issues;
use radicle::cob::store::access::WriteAs;
use radicle::storage::ReadStorage as _;

/// Create one issue and return its id.
fn create_issue(f: &Fixture, rid: &str, title: &str, body: &str) -> String {
    let id = radicle::identity::RepoId::from_urn(rid).expect("valid rid");
    let repo = f.profile.storage.repository(id).expect("repo in storage");
    let signer = f.profile.signer().expect("signer");

    let mut store = Issues::open(&repo, WriteAs::new(&signer)).expect("open issues for write");
    let mut cache = radicle::cob::cache::NoCache;
    let issue = store
        .create(
            title.parse().expect("valid title"),
            body,
            &[],
            &[],
            [],
            &mut cache,
        )
        .expect("could not create issue");
    issue.id().to_string()
}

/// The bodies currently in an issue's thread, read back through the same
/// function the UI calls.
fn thread_bodies(home: &str, rid: &str, id: &str) -> Vec<String> {
    let v = parse(&radicle_local_ffi::cobs::get_issue(home, rid, id));
    assert!(v.get("error").is_none(), "unexpected read error: {v}");
    v["discussion"]
        .as_array()
        .expect("discussion array")
        .iter()
        .filter_map(|c| c["body"].as_str().map(|s| s.to_string()))
        .collect()
}

#[test]
fn a_comment_is_persisted_and_visible_to_a_fresh_read() {
    let f = init_profile("write-comment");
    let (rid, _) = init_repo(&f, "write-repo", "writes");
    let issue = create_issue(&f, &rid, "an issue", "the original description");
    let home = f.home();

    let before = thread_bodies(&home, &rid, &issue);
    assert_eq!(
        before.len(),
        1,
        "a fresh issue has only its root comment: {before:?}"
    );

    let v = parse(&radicle_local_ffi::cobwrite::comment_on_issue(
        &home,
        &rid,
        &issue,
        "a reply posted through the write path",
    ));
    assert!(v.get("error").is_none(), "unexpected write error: {v}");

    // The reply names the new entry, which ThreadView has no use for today but
    // which is the only handle a caller would have on what it just created.
    let id = v["id"].as_str().expect("the write returns an entry id");
    assert!(!id.is_empty(), "entry id must not be empty: {v}");

    // The load-bearing assertion: re-reading storage from scratch finds it.
    // Asserting on the write's own return value would pass just as happily
    // against a function that built a plausible id and wrote nothing.
    let after = thread_bodies(&home, &rid, &issue);
    assert_eq!(
        after.len(),
        2,
        "the comment must be in the thread after the write: {after:?}"
    );
    assert!(
        after.contains(&"a reply posted through the write path".to_string()),
        "the comment body must round-trip exactly: {after:?}"
    );
    // The root comment is untouched — a write must add, not replace.
    assert!(
        after.contains(&"the original description".to_string()),
        "the root comment must survive the write: {after:?}"
    );
}

/// Two comments in a row must both land. One comment proves the happy path;
/// two prove the store is re-opened correctly rather than the first write
/// leaving something in a state the second cannot use.
#[test]
fn successive_comments_all_land_in_order() {
    let f = init_profile("write-successive");
    let (rid, _) = init_repo(&f, "write-repo", "writes");
    let issue = create_issue(&f, &rid, "an issue", "root");
    let home = f.home();

    for n in 1..=3 {
        let v = parse(&radicle_local_ffi::cobwrite::comment_on_issue(
            &home,
            &rid,
            &issue,
            &format!("comment {n}"),
        ));
        assert!(v.get("error").is_none(), "write {n} failed: {v}");
    }

    let bodies = thread_bodies(&home, &rid, &issue);
    assert_eq!(bodies.len(), 4, "root plus three comments: {bodies:?}");
    for n in 1..=3 {
        assert!(
            bodies.contains(&format!("comment {n}")),
            "comment {n} missing from {bodies:?}"
        );
    }
}

#[test]
fn an_empty_body_is_refused_and_writes_nothing() {
    let f = init_profile("write-empty");
    let (rid, _) = init_repo(&f, "write-repo", "writes");
    let issue = create_issue(&f, &rid, "an issue", "root");
    let home = f.home();

    // Whitespace only, not just "": the UI trims before enabling its button,
    // and the backstop has to agree with it or the two disagree about what an
    // empty comment is.
    for body in ["", "   ", "\n\t "] {
        let v = parse(&radicle_local_ffi::cobwrite::comment_on_issue(
            &home, &rid, &issue, body,
        ));
        assert!(
            v["error"].as_str().is_some(),
            "an empty body must be an error, not a silent no-op: {v}"
        );
    }

    // And nothing was appended by any of them.
    let bodies = thread_bodies(&home, &rid, &issue);
    assert_eq!(
        bodies.len(),
        1,
        "a refused comment must not reach storage: {bodies:?}"
    );
}

#[test]
fn commenting_on_an_absent_issue_errors() {
    let f = init_profile("write-absent");
    let (rid, _) = init_repo(&f, "write-repo", "writes");
    let home = f.home();

    // Well-formed but absent, so this is the not-found path rather than a
    // parse failure.
    let absent = "0000000000000000000000000000000000000000";
    let v = parse(&radicle_local_ffi::cobwrite::comment_on_issue(
        &home, &rid, absent, "hello",
    ));
    assert!(
        v["error"].as_str().is_some(),
        "commenting on an issue that does not exist is an error: {v}"
    );
}

#[test]
fn a_malformed_issue_id_errors_rather_than_panicking() {
    let f = init_profile("write-bad-id");
    let (rid, _) = init_repo(&f, "write-repo", "writes");
    let home = f.home();

    for id in ["", "not-an-oid", "zzzz", "../../etc/passwd"] {
        let v = parse(&radicle_local_ffi::cobwrite::comment_on_issue(
            &home, &rid, id, "hello",
        ));
        assert!(
            v["error"].as_str().is_some(),
            "malformed issue id {id:?} must error: {v}"
        );
    }
}

#[test]
fn a_bad_repository_errors_rather_than_writing_elsewhere() {
    let f = init_profile("write-bad-rid");
    let (rid, _) = init_repo(&f, "write-repo", "writes");
    let issue = create_issue(&f, &rid, "an issue", "root");
    let home = f.home();

    for bad in ["", "not-a-rid", "rad:", "rad:zzzzzzzzzzzzzzzzzzzzzzzzzzzz"] {
        let v = parse(&radicle_local_ffi::cobwrite::comment_on_issue(
            &home, bad, &issue, "hello",
        ));
        assert!(
            v["error"].as_str().is_some(),
            "a bad rid {bad:?} must error: {v}"
        );
    }

    // The real repo's thread is untouched by any of those.
    let bodies = thread_bodies(&home, &rid, &issue);
    assert_eq!(bodies.len(), 1, "no stray write landed: {bodies:?}");
}

#[test]
fn a_write_with_no_profile_errors() {
    // No `init_profile`: an empty home is the shape `LocalStore` produces when
    // there is no ~/.radicle at all, and it must not panic across the FFI.
    let v = parse(&radicle_local_ffi::cobwrite::comment_on_issue(
        "",
        "rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5",
        "0000000000000000000000000000000000000000",
        "hello",
    ));
    assert!(v["error"].as_str().is_some(), "no home is an error: {v}");
}

// ---------------------------------------------------------------------------
// create_issue
// ---------------------------------------------------------------------------

/// The titles currently in a repo's issue list, read back through the same
/// function the UI calls.
fn issue_titles(home: &str, rid: &str) -> Vec<String> {
    let v = parse(&radicle_local_ffi::cobs::list_issues(home, rid, "", 0, 100));
    assert!(v.get("error").is_none(), "unexpected read error: {v}");
    v["items"]
        .as_array()
        .expect("items array")
        .iter()
        .filter_map(|i| i["title"].as_str().map(|s| s.to_string()))
        .collect()
}

#[test]
fn a_created_issue_is_visible_to_a_fresh_read() {
    let f = init_profile("create-issue");
    let (rid, _) = init_repo(&f, "create-repo", "creates");
    let home = f.home();

    assert!(
        issue_titles(&home, &rid).is_empty(),
        "the fixture starts with no issues"
    );

    let v = parse(&radicle_local_ffi::cobwrite::create_issue(
        &home,
        &rid,
        "a brand new issue",
        "with a description that becomes the root comment",
    ));
    assert!(v.get("error").is_none(), "unexpected write error: {v}");

    let id = v["id"].as_str().expect("the write returns an issue id");
    assert!(!id.is_empty(), "issue id must not be empty: {v}");

    // Re-read from scratch, the load-bearing assertion.
    let titles = issue_titles(&home, &rid);
    assert_eq!(
        titles,
        vec!["a brand new issue".to_string()],
        "got {titles:?}"
    );

    // The returned id is what a view hands straight to localGetIssue to open
    // what was just created, so it has to actually resolve.
    let detail = parse(&radicle_local_ffi::cobs::get_issue(&home, &rid, id));
    assert!(
        detail.get("error").is_none(),
        "the id must resolve: {detail}"
    );
    assert_eq!(detail["title"], "a brand new issue");
    assert_eq!(detail["state"]["status"], "open", "new issues are open");

    // The description is the root comment — that is how the crate models it,
    // and why there is no separate `description` field to assert on.
    let bodies: Vec<&str> = detail["discussion"]
        .as_array()
        .expect("discussion")
        .iter()
        .filter_map(|c| c["body"].as_str())
        .collect();
    assert_eq!(
        bodies,
        vec!["with a description that becomes the root comment"],
        "the description becomes the root comment: {bodies:?}"
    );
}

#[test]
fn a_created_issue_can_be_commented_on() {
    // The two writes compose: an issue created through this path is a real COB
    // that the comment path can then open. A create that produced something
    // subtly malformed would show up here rather than in either test alone.
    let f = init_profile("create-then-comment");
    let (rid, _) = init_repo(&f, "create-repo", "creates");
    let home = f.home();

    let created = parse(&radicle_local_ffi::cobwrite::create_issue(
        &home,
        &rid,
        "an issue",
        "the description",
    ));
    let id = created["id"].as_str().expect("issue id");

    let commented = parse(&radicle_local_ffi::cobwrite::comment_on_issue(
        &home, &rid, id, "a reply",
    ));
    assert!(
        commented.get("error").is_none(),
        "commenting on a freshly created issue must work: {commented}"
    );

    let bodies = thread_bodies(&home, &rid, id);
    assert_eq!(bodies.len(), 2, "root plus the reply: {bodies:?}");
}

#[test]
fn several_issues_can_be_created_and_are_all_listed() {
    let f = init_profile("create-several");
    let (rid, _) = init_repo(&f, "create-repo", "creates");
    let home = f.home();

    for n in 1..=3 {
        let v = parse(&radicle_local_ffi::cobwrite::create_issue(
            &home,
            &rid,
            &format!("issue {n}"),
            &format!("body {n}"),
        ));
        assert!(v.get("error").is_none(), "create {n} failed: {v}");
    }

    let titles = issue_titles(&home, &rid);
    assert_eq!(titles.len(), 3, "got {titles:?}");
    for n in 1..=3 {
        assert!(
            titles.contains(&format!("issue {n}")),
            "issue {n} missing from {titles:?}"
        );
    }
}

#[test]
fn an_empty_title_is_refused_and_creates_nothing() {
    let f = init_profile("create-empty-title");
    let (rid, _) = init_repo(&f, "create-repo", "creates");
    let home = f.home();

    for title in ["", "   ", "\t"] {
        let v = parse(&radicle_local_ffi::cobwrite::create_issue(
            &home,
            &rid,
            title,
            "a description",
        ));
        assert!(
            v["error"].as_str().is_some(),
            "an empty title {title:?} must error: {v}"
        );
    }

    assert!(
        issue_titles(&home, &rid).is_empty(),
        "a refused create must reach storage not at all"
    );
}

/// `Title::new` rejects `\n`/`\r` outright rather than trimming them, and this
/// is reachable by pasting a line of text into a single-line field. The crate's
/// own message ("invalid characters in title") names neither the character nor
/// the fix, so the translated one has to.
#[test]
fn a_multi_line_title_is_refused_with_an_actionable_message() {
    let f = init_profile("create-multiline-title");
    let (rid, _) = init_repo(&f, "create-repo", "creates");
    let home = f.home();

    for title in ["two\nlines", "carriage\rreturn", "trailing\n"] {
        let v = parse(&radicle_local_ffi::cobwrite::create_issue(
            &home,
            &rid,
            title,
            "a description",
        ));
        let message = v["error"]
            .as_str()
            .unwrap_or_else(|| panic!("a multi-line title {title:?} must error: {v}"));
        assert!(
            message.contains("single line"),
            "the message must say what is wrong and how to fix it, got: {message}"
        );
    }

    assert!(issue_titles(&home, &rid).is_empty(), "nothing was created");
}

#[test]
fn an_empty_description_is_refused_and_creates_nothing() {
    let f = init_profile("create-empty-body");
    let (rid, _) = init_repo(&f, "create-repo", "creates");
    let home = f.home();

    for body in ["", "   ", "\n\t "] {
        let v = parse(&radicle_local_ffi::cobwrite::create_issue(
            &home, &rid, "a title", body,
        ));
        assert!(
            v["error"].as_str().is_some(),
            "an empty description {body:?} must error: {v}"
        );
    }

    assert!(
        issue_titles(&home, &rid).is_empty(),
        "a refused create must reach storage not at all"
    );
}

#[test]
fn creating_in_a_bad_repository_errors() {
    let f = init_profile("create-bad-rid");
    let (rid, _) = init_repo(&f, "create-repo", "creates");
    let home = f.home();

    for bad in ["", "not-a-rid", "rad:", "rad:zzzzzzzzzzzzzzzzzzzzzzzzzzzz"] {
        let v = parse(&radicle_local_ffi::cobwrite::create_issue(
            &home,
            bad,
            "a title",
            "a description",
        ));
        assert!(
            v["error"].as_str().is_some(),
            "a bad rid {bad:?} must error: {v}"
        );
    }

    assert!(
        issue_titles(&home, &rid).is_empty(),
        "no stray issue landed in the real repo"
    );
}

#[test]
fn creating_with_no_profile_errors() {
    let v = parse(&radicle_local_ffi::cobwrite::create_issue(
        "",
        "rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5",
        "a title",
        "a description",
    ));
    assert!(v["error"].as_str().is_some(), "no home is an error: {v}");
}

// ---------------------------------------------------------------------------
// can_write
// ---------------------------------------------------------------------------

/// The fixture's keystore is plaintext, so a signer loads with no passphrase
/// and no agent. This is the first row of the design doc's signer table.
#[test]
fn can_write_is_true_for_a_profile_whose_key_is_plaintext() {
    let f = init_profile("can-write-plain");
    let v = parse(&radicle_local_ffi::cobwrite::can_write(&f.home()));

    assert_eq!(
        v["canWrite"], true,
        "a plaintext keystore needs no passphrase: {v}"
    );
    // The DID identifies who a write would be attributed to. A UI that says
    // "commenting as …" reads this, and it must be the profile's own key.
    let did = v["nodeId"].as_str().expect("nodeId should be a DID");
    assert!(did.starts_with("did:key:"), "got {did}");
    assert!(
        did.contains(&f.profile.public_key.to_human()),
        "nodeId must be this profile's key: {did}"
    );
}

/// `canWrite:false` is an *answer*, not a failure — so it comes back as a
/// normal object with a reason, never as `{"error":...}`. A UI that treated it
/// as an error would show a red banner where it should show a disabled compose
/// box with an explanation.
#[test]
fn can_write_reports_a_reason_rather_than_an_error_when_it_cannot() {
    let v = parse(&radicle_local_ffi::cobwrite::can_write(""));

    assert_eq!(v["canWrite"], false, "an empty home cannot write: {v}");
    assert!(
        v.get("error").is_none(),
        "not being able to write is an answer, not an error: {v}"
    );
    let reason = v["reason"].as_str().expect("a reason must be given");
    assert!(
        !reason.is_empty(),
        "the reason is shown to the user verbatim"
    );
}

/// A directory that exists but holds no keys is a different situation from no
/// directory at all, and must still be an answer rather than a crash.
#[test]
fn can_write_is_false_for_a_directory_that_is_not_a_profile() {
    let dir = fixture::scratch_dir("can-write-empty");
    let v = parse(&radicle_local_ffi::cobwrite::can_write(
        &dir.display().to_string(),
    ));

    assert_eq!(v["canWrite"], false, "no keystore, no writes: {v}");
    assert!(
        v["reason"].as_str().is_some(),
        "a reason must be given: {v}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
