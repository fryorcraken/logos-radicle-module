//! The runtime environment a Radicle operation needs, and how this module
//! reports on it: where `git` is, and which identity the local node holds.
//!
//! ## Why `git` is a setting and not just a detail
//!
//! Radicle's local git transport does not implement pack protocol in-process.
//! `radicle-0.25.1/src/storage/git/transport/local.rs:53` spawns the binary:
//!
//! ```text
//! let mut cmd = process::Command::new("git");
//! … cmd.arg(service).arg(&git_dir)   // "upload-pack" | "receive-pack"
//! ```
//!
//! So any push into Radicle storage needs a `git` on `PATH`. That is invisible
//! on a developer box and fatal in a sandboxed Basecamp bundle, which is why
//! this module discovers it, reports it, and lets the user point at one.
//!
//! ## Why the process's own `PATH` is the only channel
//!
//! Phase 0 counted the spawn sites rather than assuming the one the plan cited:
//! there are **six** across the two crates, all `Command::new("git")` — a bare
//! name resolved through `PATH`. Two of them, in `radicle-node`'s worker,
//! `env_clear()` and then re-admit only `PATH` and `GIT_TRACE*`:
//!
//! ```text
//! cmd.current_dir(git_dir)
//!    .env_clear()
//!    .envs(std::env::vars().filter(|(key, _)| key == "PATH" || key.starts_with("GIT_TRACE")))
//! ```
//!
//! Two consequences, both settled rather than open questions:
//!
//! - **`GIT_EXEC_PATH` cannot work**, on two independent counts: it is stripped
//!   by that filter, and it names git's *helper* directory (`git-remote-http`
//!   and friends), not the `git` binary. It is the wrong variable regardless.
//! - **There is no single spawn path to wrap.** A resolver injected at one call
//!   site would leave five uncovered, so the only channel that reaches every
//!   site is the process's own `PATH`.
//!
//! That makes honouring a configured path a **process-global** write, which is
//! why [`apply_git_path`] is documented as init-time-only and why the settings
//! surface gives the git path restart-to-apply semantics rather than pretending
//! a live change takes effect. See `docs/M3-phase0-findings.md` §5.

use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;

/// What `git --version` said, or why it could not be asked.
///
/// Reported as an answer rather than an `{"error":...}` for the same reason
/// `can_write` is: "there is no usable git" is an answer to the question, not a
/// failure to answer it. `getCapabilities` folds this into its own reply, and a
/// preflight screen renders it directly.
pub fn git_probe(candidate: &str) -> String {
    match probe_inner(candidate) {
        Ok((path, version)) => json!({
            "found": true,
            "path": path,
            "version": version,
            "configured": !candidate.is_empty(),
        })
        .to_string(),
        Err(reason) => json!({
            "found": false,
            "path": "",
            "version": "",
            "configured": !candidate.is_empty(),
            "reason": reason,
        })
        .to_string(),
    }
}

/// Resolve and validate a git binary.
///
/// An empty `candidate` means "find it on `PATH`". A non-empty one **overrides
/// detection entirely** — there is deliberately no fallback to `PATH` when the
/// configured binary is missing, because a silent fallback makes a typo in the
/// setting look like a Radicle bug rather than a wrong path. The error names
/// the path that was tried, so the user can see what was actually looked for.
///
/// Validation runs the candidate's `git --version` rather than merely stat-ing
/// it: an executable that exists but is not git fails here, at set time, rather
/// than at the moment the user pushes their first patch.
///
/// Note this deliberately does NOT go through `radicle::git::version()`
/// (`git.rs:133`). That helper is public and would validate *whatever `PATH`
/// currently resolves*, not the specific candidate handed to it — so it cannot
/// answer the question this function is asked.
fn probe_inner(candidate: &str) -> Result<(String, String), String> {
    let resolved = if candidate.is_empty() {
        which_on_path("git").ok_or_else(|| {
            "no `git` found on PATH — Radicle spawns git to read and write \
             repository storage, so set an explicit path to it"
                .to_string()
        })?
    } else {
        let p = PathBuf::from(candidate);
        if !p.exists() {
            // Naming the path is the whole point: an explicit setting that
            // silently fell back to PATH would report success for a path that
            // does not exist.
            return Err(format!("no such file: {candidate}"));
        }
        p
    };

    let output = Command::new(&resolved)
        .arg("--version")
        .output()
        .map_err(|e| format!("could not run {}: {e}", resolved.display()))?;

    if !output.status.success() {
        return Err(format!(
            "{} exited with {} when asked for its version",
            resolved.display(),
            output.status
        ));
    }

    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    // `git --version` prints "git version 2.51.0". Anything that runs but does
    // not say so is not git, which is the real-but-not-git case: an executable
    // that exists and exits 0 must still be rejected.
    if !text.starts_with("git version") {
        return Err(format!(
            "{} does not look like git — `--version` printed {:?}",
            resolved.display(),
            text
        ));
    }

    Ok((resolved.display().to_string(), text))
}

/// Find an executable by walking `PATH`, the way a shell does.
///
/// Hand-rolled rather than pulled in as a dependency: `Cargo.lock` is vendored
/// wholesale by `radicle/flake.nix` under a pinned hash, so every added crate
/// costs vendoring on every build whether or not anything links it — the lesson
/// Phase 0 recorded when two optional dependencies added 111 crates. Twenty
/// lines here is cheaper than that.
fn which_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| is_executable_file(candidate))
}

fn is_executable_file(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    p.metadata()
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// Put `dir` at the front of this process's `PATH`.
///
/// **This is process-global state, and it must be called once at module init,
/// before any thread starts.** It is not a per-call setting and cannot be
/// scoped: the spawn sites read `std::env::vars()` at spawn time, so whatever
/// `PATH` holds then is what every future `git` resolves against.
///
/// Two consequences the caller owns rather than this function:
///
/// - Changing the git path in a settings panel does NOT take effect until the
///   module is restarted. The settings surface says so rather than letting the
///   setting appear to apply, because a setting that silently does nothing is
///   worse than one that states its constraint.
/// - `set_var` races concurrent `getenv` (which is why it is `unsafe` from Rust
///   2024 onward). Calling this at init, before threads exist, is what makes
///   that race impossible rather than merely unlikely.
///
/// Returns whether anything was changed, so init can log it.
pub fn prepend_to_path(dir: &str) -> bool {
    if dir.is_empty() {
        return false;
    }
    let existing = std::env::var_os("PATH").unwrap_or_default();
    let mut entries = vec![PathBuf::from(dir)];
    entries.extend(std::env::split_paths(&existing));

    match std::env::join_paths(entries) {
        Ok(joined) => {
            std::env::set_var("PATH", joined);
            true
        }
        // A directory containing the platform separator cannot go on PATH at
        // all. Refusing is right: silently dropping it would leave the user
        // with a setting that reads as applied and is not.
        Err(_) => false,
    }
}

/// Apply a configured git path by putting its *directory* on `PATH`.
///
/// The configured setting names the binary; `PATH` holds directories, so the
/// parent is what gets prepended. Returns the resolved binary path on success
/// so the caller can report which git is actually in force.
///
/// Validates before mutating: an unusable path must not silently reshape the
/// process's `PATH` and then fail later somewhere unrelated.
pub fn apply_git_path(configured: &str) -> Result<String, String> {
    if configured.is_empty() {
        // Empty means "find it on PATH", which needs no mutation at all.
        return probe_inner("").map(|(path, _)| path);
    }
    let (resolved, _) = probe_inner(configured)?;
    let dir = Path::new(&resolved)
        .parent()
        .ok_or_else(|| format!("{resolved} has no parent directory to add to PATH"))?;
    prepend_to_path(&dir.display().to_string());
    Ok(resolved)
}

/// The local node's ID, read from the public half of the keystore.
///
/// Deliberately independent of signing. `can_write` also reports a node id, but
/// only when a *signer* could be loaded — and the identity must be visible even
/// when the key is encrypted and locked, because the failure this whole design
/// is most exposed to is a user believing they are operating as one identity
/// when they are operating as another. An identity that only appears once you
/// can write would be invisible in exactly the case where confusion is worst.
///
/// Reads `keys/radicle.pub` and nothing else, so it needs no passphrase and
/// leaves the private key untouched — the same property the whole `local*` read
/// path relies on.
pub fn node_id(home: &str) -> String {
    match node_id_inner(home) {
        Ok(nid) => json!({ "nodeId": nid }).to_string(),
        Err(reason) => json!({ "nodeId": "", "reason": reason }).to_string(),
    }
}

fn node_id_inner(home: &str) -> Result<String, String> {
    use radicle::crypto::ssh::Keystore;

    if home.is_empty() {
        return Err("no Radicle home given".to_string());
    }
    let keys_dir = std::path::Path::new(home).join("keys");
    let key = Keystore::new(&keys_dir)
        .public_key()
        .map_err(|e| format!("could not read the local node key: {e}"))?
        .ok_or_else(|| format!("no Radicle key found at {}", keys_dir.display()))?;

    Ok(radicle::identity::Did::from(key).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // These cover the pure string/JSON shaping. The behaviour that needs a real
    // filesystem — a path that does not exist, a real-but-not-git binary — is
    // in tests/git_preflight.rs, where a scratch dir can be built.

    #[test]
    fn an_empty_candidate_is_reported_as_not_configured() {
        // Whether the answer is found or not depends on the machine, but
        // `configured` is a property of the input alone and must not drift.
        let probe: serde_json::Value = serde_json::from_str(&git_probe("")).unwrap();
        assert_eq!(probe["configured"], serde_json::json!(false));
    }

    #[test]
    fn an_explicit_candidate_is_reported_as_configured_even_when_it_fails() {
        let probe: serde_json::Value =
            serde_json::from_str(&git_probe("/nonexistent/git")).unwrap();
        assert_eq!(probe["configured"], serde_json::json!(true));
        assert_eq!(probe["found"], serde_json::json!(false));
    }

    #[test]
    fn prepending_an_empty_directory_changes_nothing() {
        assert!(!prepend_to_path(""));
    }

    #[test]
    fn node_id_without_a_home_reports_a_reason_rather_than_an_empty_answer() {
        let v: serde_json::Value = serde_json::from_str(&node_id("")).unwrap();
        assert_eq!(v["nodeId"], serde_json::json!(""));
        assert!(v["reason"].as_str().unwrap().contains("no Radicle home"));
    }
}
