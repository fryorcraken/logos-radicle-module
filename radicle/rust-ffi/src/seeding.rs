//! Seeding policies: what this node will replicate, and with what scope.
//!
//! ## This is a different store from `config.json`, and a different question
//! from `localListRepos("seeded")`
//!
//! Per-repo policies are rows in `<home>/node/policies.db`, reached through
//! `Home::policies_mut()` (`radicle-0.25.1/src/profile.rs:719`).
//! `config.json`'s `node.seedingPolicy` is only the *default* applied when no
//! row matches, and nothing here touches it. So a seeding change is visible at
//! once and never sets `restartRequired`, unlike a configuration change.
//!
//! `localListRepos("seeded")` asks a different question again: which
//! repositories are already in local storage. A repository can be seeded by
//! policy with nothing yet replicated, and can sit in storage with no policy
//! seeding it. Neither surface is derivable from the other, which is why
//! `list` reads policies and never filters storage.
//!
//! ## Two ways the store's API misleads
//!
//! **The `seeding` table holds block rows as well as allow rows.**
//! `seed_policies()` returns every row (`node/policy/store.rs:320`), and a
//! `Block` row is a repository this node has been told *not* to replicate.
//! Reporting one as seeded would be the exact opposite of the truth, so `list`
//! filters on `policy.is_allow()`.
//!
//! **`seed`/`unseed` return `change_count() > 0`, not "it is now so."**
//! Re-seeding at a scope the row already has changes nothing and returns
//! `false` (`store.rs:136-147`). `seed` therefore does not report that boolean:
//! asking for a scope a repository already has is not a failure, and the
//! success shape is the policy. `unseed` does report it, because
//! `{"unseeded":bool}` is exactly the "was there one to remove" distinction a
//! view needs, and a `DELETE`'s change count answers it precisely.

use radicle::node::policy::Scope;
use radicle::profile::Home;
use serde_json::json;

/// Open the policy store under `home` for writing.
///
/// `Home::load`, never `Home::new`: `new` creates the home and all four
/// subdirectories if they are missing (`profile.rs:586-602`), so against a
/// typo'd path it would leave an empty Radicle home on disk and then fail. The
/// same reasoning `node.rs` records for starting a node — seeding must not
/// bring a home into existence either.
fn open(home: &str) -> Result<radicle::node::policy::store::StoreWriter, String> {
    if home.is_empty() {
        return Err("no Radicle home given".to_string());
    }
    let radicle_home = Home::load(std::path::Path::new(home)).map_err(|e| {
        format!(
            "could not open the Radicle home {home}: {e}. Seeding needs a home that \
             already holds an identity."
        )
    })?;
    radicle_home
        .policies_mut()
        .map_err(|e| format!("could not open the seeding policies under {home}: {e}"))
}

/// The scope a caller asked for, or a refusal naming both valid ones.
///
/// `Scope::from_str` already accepts exactly `all` and `followed`
/// (`node/policy.rs:184-194`), but its error names neither — and the spec
/// requires a refusal that does, because the difference between the two decides
/// whether a private repository replicates at all.
fn parse_scope(scope: &str) -> Result<Scope, String> {
    match scope {
        "all" => Ok(Scope::All),
        "followed" => Ok(Scope::Followed),
        other => Err(format!(
            "`{other}` is not a seeding scope — it is `all` or `followed`. `all` \
             seeds every remote and is what a private repository needs; `followed` \
             seeds only delegates and nodes you follow."
        )),
    }
}

/// Everything this node is seeding, with each entry's scope.
///
/// -> `{"items":[{"rid":"rad:…","scope":"all"|"followed"}]}` or `{"error":"…"}`
///
/// An unopenable store is an error rather than an empty list. "Nothing is
/// seeded" and "the policies could not be read" are different facts, and a view
/// acting on the first when the second is true would offer to seed a repository
/// that is already seeded.
pub fn list(home: &str) -> String {
    match list_inner(home) {
        Ok(v) => v,
        Err(e) => crate::local::error(e),
    }
}

fn list_inner(home: &str) -> Result<String, String> {
    let store = open(home)?;
    let policies = store
        .seed_policies()
        .map_err(|e| format!("could not read the seeding policies under {home}: {e}"))?;

    let mut items = Vec::new();
    for policy in policies {
        let policy =
            policy.map_err(|e| format!("could not read a seeding policy under {home}: {e}"))?;
        // Block rows live in the same table. A blocked repository is not a
        // seeded one, and reporting it as seeded would be exactly backwards.
        if let radicle::node::policy::SeedingPolicy::Allow { scope } = policy.policy {
            items.push(json!({
                "rid": policy.rid.urn(),
                "scope": scope.to_string(),
            }));
        }
    }

    Ok(json!({ "items": items }).to_string())
}

/// Seed `rid` with `scope`.
///
/// -> `{"rid":"rad:…","scope":"all"|"followed"}` or `{"error":"…"}`
///
/// Re-seeding at a different scope replaces the scope rather than adding a
/// second row — the store's own `ON CONFLICT DO UPDATE` (`store.rs:138-141`) —
/// so a caller changing its mind does not have to unseed first.
pub fn seed(home: &str, rid: &str, scope: &str) -> String {
    match seed_inner(home, rid, scope) {
        Ok(v) => v,
        Err(e) => crate::local::error(e),
    }
}

fn seed_inner(home: &str, rid: &str, scope: &str) -> Result<String, String> {
    // Both arguments are validated before the store is opened, so a malformed
    // RID writes nothing — a policy that can never match a repository is
    // invisible except as a repository that mysteriously never replicates.
    let id = crate::local::parse_rid(rid)?;
    let scope = parse_scope(scope)?;

    let mut store = open(home)?;
    store
        .seed(&id, scope)
        .map_err(|e| format!("could not seed {rid}: {e}"))?;

    // The store's boolean is `change_count() > 0` — false when the row already
    // had this scope, which is success, not failure. So the reply is the policy
    // that now holds rather than whether a row changed.
    Ok(json!({ "rid": id.urn(), "scope": scope.to_string() }).to_string())
}

/// Remove the seeding policy for `rid`.
///
/// -> `{"unseeded":bool}` or `{"error":"…"}`
///
/// Unseeding what is not seeded is an answer rather than an error: the caller
/// has got what it asked for. The boolean is what says which of the two
/// happened, so a view can report it.
///
/// **Nothing is deleted from storage.** A policy and a replicated copy are
/// different things, and removing a policy is reversible where deleting storage
/// is not.
pub fn unseed(home: &str, rid: &str) -> String {
    match unseed_inner(home, rid) {
        Ok(v) => v,
        Err(e) => crate::local::error(e),
    }
}

fn unseed_inner(home: &str, rid: &str) -> Result<String, String> {
    let id = crate::local::parse_rid(rid)?;

    let mut store = open(home)?;
    let removed = store
        .unseed(&id)
        .map_err(|e| format!("could not unseed {rid}: {e}"))?;

    Ok(json!({ "unseeded": removed }).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unknown_scope_names_both_valid_ones() {
        let e = parse_scope("everything").unwrap_err();
        assert!(e.contains("all"), "{e}");
        assert!(e.contains("followed"), "{e}");
    }

    #[test]
    fn both_scopes_are_accepted() {
        assert_eq!(parse_scope("all").unwrap().to_string(), "all");
        assert_eq!(parse_scope("followed").unwrap().to_string(), "followed");
    }

    #[test]
    fn seeding_without_a_home_is_refused_rather_than_resolved_from_the_environment() {
        // The C++ side owns home resolution. Guessing one here is how the
        // embedded mode would come to write policies into the user's own home.
        let v: serde_json::Value =
            serde_json::from_str(&seed("", "rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5", "all")).unwrap();
        assert!(v["error"].as_str().is_some());
    }

    #[test]
    fn a_malformed_rid_is_refused_and_named() {
        let v: serde_json::Value =
            serde_json::from_str(&seed("/nonexistent", "not-a-rid", "all")).unwrap();
        let msg = v["error"].as_str().unwrap();
        assert!(msg.contains("not-a-rid"), "{msg}");
    }

    #[test]
    fn unseeding_a_malformed_rid_is_refused_rather_than_ignored() {
        let v: serde_json::Value =
            serde_json::from_str(&unseed("/nonexistent", "not-a-rid")).unwrap();
        assert!(v["error"].as_str().unwrap().contains("not-a-rid"));
    }
}
