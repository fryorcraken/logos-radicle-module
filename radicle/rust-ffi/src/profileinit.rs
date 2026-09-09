//! Creating a Radicle identity — the `rad auth` half of the embedded node,
//! with no `rad` binary and no terminal.
//!
//! This is the first thing in this module that brings an identity into
//! existence rather than reading or writing one that already exists. Everything
//! else in `local*` assumes a profile; this is what makes one.
//!
//! ## Why this lands before the daemon
//!
//! Phase 2 is "wizard, `Profile::init`, start/stop". Those three are separable,
//! and the order matters for a reason that is about the build rather than about
//! the feature: **`Profile::init` is in the `radicle` crate this module already
//! depends on, and the node runtime is in `radicle-node`, which it does not.**
//!
//! Adding `radicle-node` is not a small change here. `radicle/flake.nix`
//! vendors `Cargo.lock` wholesale through one fixed-output derivation with a
//! pinned hash, and cargo's vendoring is feature-blind — Phase 0 measured the
//! two optional dependencies taking the lock from 208 packages to 319, none of
//! which the default build compiles, and the stale hash broke the Nix build
//! outright while `cargo build`, `cargo clippy` and `cargo test` all stayed
//! green (`docs/M3-phase0-findings.md` §4).
//!
//! So identity creation costs **no** manifest change, no lock change and no
//! vendor rehash, while the runtime costs all three. Landing them together
//! would put a +111-crate dependency review and an identity-creation review in
//! one diff, where neither can be read for itself. This file is the half that
//! is free.
//!
//! ## Isolation is the property, not a side effect
//!
//! An embedded profile is deliberately a **separate identity** from any
//! `~/.radicle` the user already has — a new machine joining their network, in
//! the plan's words. That is the accepted model rather than a compromise, and
//! it is what makes the whole mode safe: no shared storage, no shared socket,
//! no chance of corrupting an identity the user depends on.
//!
//! It is also the thing most easily broken by a change that looks harmless, and
//! most easily "proven" by a test that cannot fail. `Profile::init` takes a
//! `Seed`, and a fixed seed produces a fixed key — so two profiles created with
//! the same seed have the **same NID**, in different directories, and every
//! is-the-directory-separate assertion passes anyway. `tests/profile_init.rs`
//! therefore asserts two homes yield two *different* node ids, which is the
//! only assertion that can tell isolation from its absence.
//!
//! ## The seed is read from the OS, not from `fastrand`
//!
//! The `radicle` crate's own `profile::env::rng()` returns a `fastrand::Rng`,
//! which is wyrand — fast, and **not** a cryptographically secure generator.
//! It is the right tool where the crate uses it (jitter, shuffling) and the
//! wrong one for the seed of a signing key that is a user's permanent identity.
//!
//! `/dev/urandom` is read directly rather than through `getrandom` for the
//! vendoring reason above: the crate is already in the lock transitively, but
//! naming it as a direct dependency still rewrites `Cargo.lock` and invalidates
//! `flake.nix`'s pinned hash — the exact cost this file exists to avoid paying
//! twice. Eight lines of `File::read_exact` is what `getrandom` does on Linux
//! anyway, and a short read is treated as a failure rather than padded, because
//! a partially-random seed is worse than no key at all.

use radicle::crypto::ssh::keystore::Passphrase;
use radicle::crypto::Seed;
use radicle::node::Alias;
use radicle::profile::{Home, Profile};
use serde_json::json;

/// Draw `Seed::BYTES` of entropy from the operating system.
///
/// A short read is an error, never padded or retried into something shorter.
/// The seed becomes a permanent signing identity, so "mostly random" is not a
/// degraded success — it is a silent weakness nothing downstream can detect.
fn os_seed() -> Result<Seed, String> {
    use std::io::Read;

    let mut bytes = [0u8; 32];
    let mut f = std::fs::File::open("/dev/urandom")
        .map_err(|e| format!("could not open the system random source: {e}"))?;
    f.read_exact(&mut bytes)
        .map_err(|e| format!("could not read enough entropy for a new key: {e}"))?;
    Ok(Seed::new(bytes))
}

/// What a directory holds, as far as creating an identity is concerned.
///
/// **There are three states, not two, and missing the third is a trap.**
/// `Profile::init` writes the keystore *first* and then performs seven more
/// fallible steps (`radicle-0.25.1/src/profile.rs:240-266`: `Config::init`,
/// `Storage::open`, `policies_mut`, `notifications_mut`, `database_mut().init`,
/// `cobs_db_mut`, `migrate`), each with a `?`. If any of them fails — a full
/// disk, a permissions hiccup, the process killed — the key files are already
/// on disk and nothing removes them.
///
/// A two-state check keyed on the keystore therefore reports that home as
/// *occupied* forever after, and since there is deliberately no `force`, the
/// home becomes permanently uncompletable through this API. The guard meant to
/// protect a real identity would instead be protecting a stub that never was
/// one, while telling the user their signing key is at risk.
#[derive(Debug, PartialEq, Eq)]
pub enum HomeState {
    /// No key material. Safe to create into, whether or not the directory
    /// itself exists.
    Empty,
    /// A complete profile. Creating here would destroy a real identity.
    Complete,
    /// Key material present but initialisation did not finish. Recoverable —
    /// and the error must say so, because the key here is not one anybody has
    /// used, published or delegated to.
    Partial,
}

/// Classify `home` for the purposes of creating an identity.
///
/// ## Why `config.json` is the completeness marker and `storage/` is not
///
/// The obvious pair of markers would be `storage/` and `config.json`. Only the
/// second works, and the reason is ordering rather than taste: `Home::new`
/// creates **all four subdirectories up front** — `storage`, `keys`, `node`,
/// `cobs` (`profile.rs:595-599`, via `subdirectories()` at `:654`) — before a
/// single key is written. So `storage/` is present in the partial state too,
/// and using it as the marker would classify every broken home as complete,
/// which is the bug this enum exists to fix.
///
/// `config.json` is a *file*, written by `Config::init` at `profile.rs:242` —
/// the very next statement after `keystore.init`. It exists only if keygen
/// succeeded and init got at least one step further, which is exactly the
/// question being asked.
///
/// Note this makes the marker narrower than "the profile is fully usable": a
/// home that failed at, say, the COB cache migration has a `config.json` and
/// reads as `Complete` here. That is deliberate and is the safe direction to
/// err — `Complete` refuses, and refusing to overwrite a home that has real
/// key material *and* a config is right even when some later database is
/// missing. Only the pre-config window is unambiguously "nothing here was ever
/// a working identity".
pub fn home_state(home: &str) -> HomeState {
    if home.is_empty() {
        return HomeState::Empty;
    }
    let path = std::path::Path::new(home);

    // The public key is the marker for "key material exists" rather than the
    // directory: an embedded home is one this module creates and may well have
    // created already — for settings, or on a run that failed between `mkdir`
    // and keygen. Treating "the directory is there" as "a profile is there"
    // would refuse to ever complete such a setup.
    if !path.join("keys").join("radicle.pub").exists() {
        return HomeState::Empty;
    }

    if path.join("config.json").exists() {
        HomeState::Complete
    } else {
        HomeState::Partial
    }
}

/// Whether `home` already holds a **complete** Radicle profile.
///
/// Kept as the boolean the C++ boundary asks for, derived from `home_state`
/// rather than re-deriving its own answer — one classifier, one set of markers.
///
/// Note this deliberately answers a different question from
/// `LocalStore::available()` on the C++ side, which looks for `storage/`: that
/// one asks "can I browse this", this asks "would creating here destroy a real
/// identity". A home with keys and no storage answers yes here and no there,
/// and both are correct.
///
/// **A partial home reports `false`**, because it is not a profile — creating
/// into it is the recovery, not a destructive act.
pub fn profile_exists(home: &str) -> bool {
    home_state(home) == HomeState::Complete
}

/// Create a Radicle identity at `home`, the way `rad auth` does.
///
/// -> `{"created":true,"nodeId":"did:key:z6Mk…","home":"…","alias":"…","encrypted":bool}`
/// -> `{"error":"…"}`
///
/// ## An existing profile is refused, and this guard is not the only one
///
/// **The crate already refuses too, and saying otherwise would be wrong.** An
/// earlier version of this comment claimed `Keystore::init` "would happily
/// write a new key over an old one", which is false:
/// `radicle-crypto-0.19.0/src/ssh/keystore.rs:121-133` checks both the secret
/// and public key paths and returns `Error::AlreadyInitialized`. Verified by
/// deleting the guard below — all nine tests in `tests/profile_init.rs` still
/// passed, because the crate caught every case. That matters to record
/// precisely because the false version was an argument for keeping this guard:
/// a reader who checked the crate would find the justification untrue and could
/// reasonably conclude the guard is redundant and delete it.
///
/// It is not redundant, for two reasons that survive the correction:
///
/// - **It fires before `Home::new`.** The crate's check happens inside
///   `Profile::init`, by which point `Home::new` has already created the
///   directory tree — so a refusal there leaves a half-made home behind for the
///   next attempt to trip over. This one leaves the filesystem exactly as it
///   found it.
/// - **The message is the one a user can act on.** The crate says "keystore
///   already initialized, file '…' exists", which describes a keystore. This
///   says an identity exists at this home and that creating another would
///   overwrite its signing key, which describes the consequence.
///
/// Because both guards produce an error, a test asserting only that a second
/// init *fails* passes with this one deleted. `tests/profile_init.rs` therefore
/// asserts on the message text, and that was verified by mutation.
///
/// Refusing rather than offering a `force` flag is deliberate: there is no
/// caller that legitimately wants to destroy a key, and a flag that exists is a
/// flag a future UI can pass by accident. The stake is real — the signing key
/// *is* the identity, and every repository delegating to it becomes unreachable
/// if it is replaced.
///
/// ## The half-created home, which is neither of the above
///
/// `Profile::init` writes the keystore first and then runs seven more fallible
/// steps (`profile.rs:240-266`). Any of them failing leaves key files on disk
/// with no profile around them, and nothing cleans up.
///
/// A two-state check would then call that home *occupied* for ever, and with no
/// `force` it would be permanently uncompletable — the guard protecting a stub
/// that was never an identity, while telling the user their signing key is at
/// stake. That is worse than the case it was written for, because it is both
/// false and unactionable.
///
/// So `home_state` names three states and this reports the third distinctly:
/// half-created, recoverable, with the path to remove. **It is reported, not
/// repaired.** Deleting key material automatically would make a
/// misclassification cost an identity, which is the one failure here with no
/// recovery; a sentence costs the user one command and cannot destroy anything.
///
/// ## The passphrase, and why empty means unencrypted
///
/// `Profile::init` takes `Option<Passphrase>`, and `None` writes the signing
/// key **unencrypted** on disk. That is a real trade the wizard has to state
/// rather than hide: an unencrypted key lets the node start unattended and lets
/// writes happen with no prompt, at the cost of a secret sitting in plaintext.
///
/// An empty string maps to `None` here because that is what `ssh-keygen` does
/// and what `radicle`'s own `env::passphrase()` does (`profile.rs:113`) —
/// three places agreeing that "" means "no passphrase" is better than this one
/// inventing a fourth meaning. The consequence is reported back as `encrypted`
/// so the caller states the outcome rather than assuming it followed the input.
///
/// Reads never need the passphrase — only `keys/radicle.pub` is read — but
/// writes do, and so (per `docs/M3-phase0-findings.md` §7) very probably does
/// starting the node. A caller that encrypts here is choosing a node it will
/// have to unlock; that is a legitimate choice, and it is why this reports the
/// outcome instead of quietly preferring one.
pub fn init_profile(home: &str, alias: &str, passphrase: &str) -> String {
    match init_profile_inner(home, alias, passphrase) {
        Ok(v) => v,
        Err(e) => crate::local::error(e),
    }
}

fn init_profile_inner(home: &str, alias: &str, passphrase: &str) -> Result<String, String> {
    if home.is_empty() {
        return Err("no home given to create the profile in".to_string());
    }

    // A relative home is refused rather than resolved, mirroring the git-path
    // check in `env.rs` — and the reason applies with more force here. There it
    // was about validating one binary and running another; here it is about
    // where a PERMANENT signing key gets written. A Basecamp-launched module's
    // current directory is not something the user chose or can see, so
    // resolving against it would put an identity somewhere nobody named, and
    // the same setting would mean a different home depending on how the module
    // happened to be started.
    //
    // Latent today — every C++ caller passes an absolute path — but step 2's
    // wizard feeds this from settings, which is exactly where a relative value
    // can arrive.
    if !std::path::Path::new(home).is_absolute() {
        return Err(format!(
            "the Radicle home must be an absolute path, got: {home} — a \
             relative path is resolved against a working directory this module \
             does not control, so the identity would be created somewhere the \
             user did not choose"
        ));
    }

    // Refused before anything is created, so a rejected call leaves the
    // filesystem exactly as it found it.
    //
    // NOT the only guard: `Keystore::init` refuses an existing keystore too
    // (keystore.rs:121-133). This one earns its place by firing BEFORE
    // `Home::new` creates the directory tree, and by naming the consequence
    // rather than the file. See the doc comment — and note that the test for
    // this asserts on the message, because "it errored" is true of both.
    //
    // Three states, not two: see `home_state`. A PARTIAL home reaches the arm
    // below with its own message, because telling a user their signing key is
    // at risk when the "key" is a stub from a failed run is both false and
    // unactionable.
    match home_state(home) {
        HomeState::Empty => {}
        HomeState::Complete => {
            return Err(format!(
                "a Radicle identity already exists at {home} — creating another \
                 would overwrite its signing key, which cannot be recovered"
            ));
        }
        HomeState::Partial => {
            // Reported rather than silently repaired. Deleting key material is
            // the one act this module refuses everywhere else, and doing it
            // automatically here would mean a classifier bug becomes a destroyed
            // identity — the failure mode with no recovery, traded for the one
            // that only needs a sentence. The user is told exactly which path to
            // remove, and `keys/` is named rather than the whole home so a home
            // that also holds unrelated files is not swept away on our advice.
            let keys = std::path::Path::new(home).join("keys");
            return Err(format!(
                "the Radicle home at {home} is half-created: it has key material \
                 but initialisation did not finish, so there is no usable \
                 identity here. This is recoverable — nothing has ever signed \
                 with this key. Remove {} and try again.",
                keys.display()
            ));
        }
    }

    // Validated before the home is created, for the same reason. `Alias` has
    // real rules (non-empty, no whitespace, bounded length) and the crate's own
    // error is the accurate statement of them, so it is passed through rather
    // than paraphrased into something that could drift from what is enforced.
    let alias = alias
        .parse::<Alias>()
        .map_err(|e| format!("'{alias}' is not a usable alias: {e}"))?;

    // Empty means unencrypted, matching ssh-keygen and the crate's own
    // env::passphrase(). See the doc comment.
    let encrypted = !passphrase.is_empty();
    let passphrase = if encrypted {
        Some(Passphrase::from(passphrase.to_string()))
    } else {
        None
    };

    // `Home::new` creates the directory tree. It runs after both refusals above
    // so that a bad alias or an occupied home does not leave a half-made home
    // behind for the next attempt to trip over.
    let home_path = std::path::PathBuf::from(home);
    let radicle_home = Home::new(&home_path)
        .map_err(|e| format!("could not create a Radicle home at {home}: {e}"))?;

    let profile = Profile::init(radicle_home, alias.clone(), passphrase, os_seed()?)
        .map_err(|e| format!("could not create a Radicle identity at {home}: {e}"))?;

    Ok(json!({
        "created": true,
        // The DID, matching what `getCapabilities().nodeId` reports, so a
        // caller can compare the identity it just made against the one the
        // module says is in force without normalising between two spellings.
        "nodeId": profile.did().to_string(),
        "home": profile.home().path().display().to_string(),
        "alias": alias.to_string(),
        "encrypted": encrypted,
    })
    .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Only the checks that need no filesystem live here. Everything that
    // creates a real profile is in tests/profile_init.rs, where the scratch
    // home convention (`rust-ffi/tmp/`, removed on drop) already exists.

    #[test]
    fn an_empty_home_is_refused_rather_than_resolved_from_the_environment() {
        // The C++ side owns home resolution; an empty home reaching here is a
        // caller bug, and guessing one would create an identity somewhere the
        // user never named.
        let v: serde_json::Value = serde_json::from_str(&init_profile("", "tester", "")).unwrap();
        assert!(v["error"].as_str().unwrap().contains("no home given"));
    }

    #[test]
    fn an_empty_home_holds_no_profile() {
        assert!(!profile_exists(""));
    }
}
