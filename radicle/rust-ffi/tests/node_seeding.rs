//! Seeding policies against a real `policies.db`.
//!
//! The unit tests beside `seeding.rs` cover scope parsing and the refusals that
//! need no store. What needs a real database is everything about the rows: that
//! a policy is visible before anything replicates, that re-seeding replaces
//! rather than duplicates, that unseeding distinguishes its two outcomes, and
//! that two homes do not share a store.

mod fixture;

use fixture::{init_profile, init_repo, parse};
use radicle_local_ffi::{local, seeding};

/// An RID that is well-formed but names nothing in storage — which is the whole
/// point of the first test: a policy exists before a repository does.
const ABSENT_RID: &str = "rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5";

fn list(home: &str) -> serde_json::Value {
    parse(&seeding::list(home))
}

fn seeded_rids(home: &str) -> Vec<String> {
    list(home)["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|e| e["rid"].as_str().unwrap().to_string())
        .collect()
}

fn scope_of(home: &str, rid: &str) -> Option<String> {
    list(home)["items"]
        .as_array()
        .expect("items")
        .iter()
        .find(|e| e["rid"] == serde_json::json!(rid))
        .map(|e| e["scope"].as_str().unwrap().to_string())
}

#[test]
fn a_newly_seeded_rid_is_listed_before_anything_replicates() {
    // This is what makes `listSeeded` a policy question rather than a storage
    // question. An implementation that filtered storage would report nothing
    // here, and would be wrong: the policy is exactly what makes replication
    // happen later.
    let f = init_profile("seeding-before-replication");
    let home = f.home();

    let reply = parse(&seeding::seed(&home, ABSENT_RID, "all"));
    assert!(reply.get("error").is_none(), "{reply}");

    assert!(
        seeded_rids(&home).iter().any(|r| r == ABSENT_RID),
        "the seeded RID must be listed: {:?}",
        seeded_rids(&home)
    );

    // And the storage-scope surface does NOT include it, which is the half that
    // proves the two are not derived from one another.
    let repos = parse(&local::list_repos(&home, "seeded", 0, 50));
    let listed: Vec<String> = repos["items"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|e| e["rid"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    assert!(
        !listed.iter().any(|r| r == ABSENT_RID),
        "localListRepos(seeded) must not report a policy: {listed:?}"
    );
}

#[test]
fn a_repository_in_storage_with_no_policy_is_not_listed_as_seeded() {
    // The other direction of the same disagreement. A repository this node
    // created sits in storage, and no seeding policy exists for it.
    let f = init_profile("seeding-storage-not-policy");
    let (rid, _work) = init_repo(&f, "unseeded-project", "in storage, no policy");
    let home = f.home();

    assert!(
        !seeded_rids(&home).iter().any(|r| r == &rid),
        "storage contents must not appear as policies"
    );

    let all = parse(&local::list_repos(&home, "all", 0, 50));
    let listed: Vec<String> = all["items"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|e| e["rid"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    assert!(
        listed.iter().any(|r| r == &rid),
        "the control: the repo really is in storage: {listed:?}"
    );
}

#[test]
fn both_scopes_are_accepted_and_reported_back_per_entry() {
    // Two RIDs with two different scopes, so the reply cannot pass by
    // reporting one constant. A fixture answering `all` for everything would
    // fail the second assertion.
    let f = init_profile("seeding-two-scopes");
    let home = f.home();
    let other = "rad:z2rHiZ6dDxcRSeYB1nT3FMc4qFcDR";

    assert!(parse(&seeding::seed(&home, ABSENT_RID, "all"))
        .get("error")
        .is_none());
    assert!(parse(&seeding::seed(&home, other, "followed"))
        .get("error")
        .is_none());

    assert_eq!(scope_of(&home, ABSENT_RID).as_deref(), Some("all"));
    assert_eq!(scope_of(&home, other).as_deref(), Some("followed"));
}

#[test]
fn re_seeding_with_a_different_scope_replaces_it_rather_than_adding_a_row() {
    let f = init_profile("seeding-replace-scope");
    let home = f.home();

    assert!(parse(&seeding::seed(&home, ABSENT_RID, "followed"))
        .get("error")
        .is_none());
    assert!(parse(&seeding::seed(&home, ABSENT_RID, "all"))
        .get("error")
        .is_none());

    let matching: Vec<String> = seeded_rids(&home)
        .into_iter()
        .filter(|r| r == ABSENT_RID)
        .collect();
    assert_eq!(matching.len(), 1, "exactly one entry: {matching:?}");
    assert_eq!(scope_of(&home, ABSENT_RID).as_deref(), Some("all"));
}

// NO SPEC: the spec states `listSeeded`'s shape (`{"items":[…]}`) and
// `unseedRepo`'s (`{"unseeded":bool}`), but never says what a successful
// `seedRepo` returns. `{"rid":…,"scope":…}` was chosen: it is the policy that
// now holds, which is what a view re-renders from, and it deliberately does NOT
// report the store's `change_count() > 0` boolean — see the test below for why
// that would be misleading. A spec-writer should decide whether this is the
// shape it wants before it becomes permanent by accident.
#[test]
fn a_successful_seed_reports_the_policy_that_now_holds() {
    let f = init_profile("seeding-success-shape");
    let home = f.home();

    let reply = parse(&seeding::seed(&home, ABSENT_RID, "followed"));
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["rid"], serde_json::json!(ABSENT_RID));
    assert_eq!(reply["scope"], serde_json::json!("followed"));
}

#[test]
fn re_seeding_at_the_same_scope_is_not_reported_as_a_failure() {
    // The store's `seed()` returns `change_count() > 0`, which is FALSE when
    // the row already held this scope. Reporting that boolean as success/failure
    // would make an idempotent call look like an error.
    let f = init_profile("seeding-idempotent");
    let home = f.home();

    assert!(parse(&seeding::seed(&home, ABSENT_RID, "all"))
        .get("error")
        .is_none());
    let again = parse(&seeding::seed(&home, ABSENT_RID, "all"));
    assert!(again.get("error").is_none(), "{again}");
    assert_eq!(again["scope"], serde_json::json!("all"));
}

#[test]
fn unseeding_removes_the_entry_and_says_it_did() {
    let f = init_profile("seeding-unseed");
    let home = f.home();

    assert!(parse(&seeding::seed(&home, ABSENT_RID, "all"))
        .get("error")
        .is_none());

    let reply = parse(&seeding::unseed(&home, ABSENT_RID));
    assert_eq!(reply["unseeded"], serde_json::json!(true), "{reply}");
    assert!(!seeded_rids(&home).iter().any(|r| r == ABSENT_RID));
}

#[test]
fn unseeding_what_is_not_seeded_is_an_answer_rather_than_an_error() {
    let f = init_profile("seeding-unseed-absent");
    let home = f.home();

    let reply = parse(&seeding::unseed(&home, ABSENT_RID));
    assert!(reply.get("error").is_none(), "{reply}");
    // The boolean is what distinguishes this from the case above. Without it a
    // view could not say which of the two happened.
    assert_eq!(reply["unseeded"], serde_json::json!(false));
}

#[test]
fn unseeding_leaves_local_storage_alone() {
    // A policy and a replicated copy are different things. Deleting storage is
    // irreversible where removing a policy is not, so unseeding must not do it.
    let f = init_profile("seeding-unseed-keeps-storage");
    let (rid, _work) = init_repo(&f, "kept-project", "must survive an unseed");
    let home = f.home();

    assert!(parse(&seeding::seed(&home, &rid, "all"))
        .get("error")
        .is_none());
    assert!(parse(&seeding::unseed(&home, &rid)).get("error").is_none());

    let all = parse(&local::list_repos(&home, "all", 0, 50));
    let listed: Vec<String> = all["items"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|e| e["rid"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    assert!(
        listed.iter().any(|r| r == &rid),
        "the repository must still be in storage: {listed:?}"
    );
}

#[test]
fn a_malformed_rid_writes_no_policy() {
    let f = init_profile("seeding-malformed-rid");
    let home = f.home();

    let reply = parse(&seeding::seed(&home, "not-a-rid", "all"));
    assert!(
        reply["error"]
            .as_str()
            .is_some_and(|m| m.contains("not-a-rid")),
        "{reply}"
    );
    assert!(
        list(&home)["items"].as_array().unwrap().is_empty(),
        "nothing must have been written"
    );
}

#[test]
fn an_unknown_scope_writes_no_policy_and_names_both_valid_ones() {
    let f = init_profile("seeding-unknown-scope");
    let home = f.home();

    let reply = parse(&seeding::seed(&home, ABSENT_RID, "everything"));
    let msg = reply["error"].as_str().expect("an error");
    assert!(msg.contains("all") && msg.contains("followed"), "{msg}");
    assert!(list(&home)["items"].as_array().unwrap().is_empty());
}

#[test]
fn two_homes_yield_two_different_policy_sets() {
    // Neither path is a prefix of the other, and each home is asserted NOT to
    // hold the other's RID — so the two are distinguishable by their answers
    // rather than only by their paths. A store opened at a shared location
    // would report both in both.
    let a = init_profile("seeding-isolation-a");
    let b = init_profile("seeding-isolation-b");
    let rid_a = ABSENT_RID;
    let rid_b = "rad:z2rHiZ6dDxcRSeYB1nT3FMc4qFcDR";

    assert!(parse(&seeding::seed(&a.home(), rid_a, "all"))
        .get("error")
        .is_none());
    assert!(parse(&seeding::seed(&b.home(), rid_b, "followed"))
        .get("error")
        .is_none());

    assert_eq!(seeded_rids(&a.home()), vec![rid_a.to_string()]);
    assert_eq!(seeded_rids(&b.home()), vec![rid_b.to_string()]);
}

#[test]
fn a_home_that_holds_no_identity_is_an_error_rather_than_an_empty_list() {
    // "Nothing is seeded" and "the policies could not be read" are different
    // facts, and a view acting on the first when the second is true would offer
    // to seed a repository that is already seeded.
    let dir = fixture::scratch_dir("seeding-no-home");
    let missing = dir.join("nowhere").display().to_string();

    let reply = list(&missing);
    assert!(reply["error"].as_str().is_some(), "{reply}");
    assert!(
        reply.get("items").is_none(),
        "an error must not carry an items array: {reply}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
