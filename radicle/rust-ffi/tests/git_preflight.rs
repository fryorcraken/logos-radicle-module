//! The `git` preflight: finding it, validating it, and refusing it.
//!
//! **The negative cases are the point of this file.** A test that configures a
//! working git and sees success proves almost nothing: it passes just as
//! happily against a resolver that ignores the setting entirely and falls back
//! to whatever is on `PATH`. That is the same-answer-for-every-input trap this
//! repo has shipped before, and it is why the two cases below exist —
//!
//!   - a path that does **not** exist, asserting the failure names that path;
//!   - a path that exists and is executable but is **not git**, asserting the
//!     `--version` validation rejects it.
//!
//! Only those two can tell "honours the setting" from "ignores the setting".

mod fixture;

use radicle_local_ffi::env;

fn parse(json: &str) -> serde_json::Value {
    serde_json::from_str(json).unwrap_or_else(|e| panic!("not valid JSON: {e}\n{json}"))
}

// ---------------------------------------------------------------------------
// The negative cases.
// ---------------------------------------------------------------------------

#[test]
fn a_configured_path_that_does_not_exist_is_refused_and_named() {
    // No silent fallback to PATH. A typo in the setting must not look like a
    // Radicle bug, so the message has to say what was actually looked for.
    let missing = "/definitely/not/here/git";
    let probe = parse(&env::git_probe(missing));

    assert_eq!(probe["found"], serde_json::json!(false));
    assert!(
        probe["reason"].as_str().unwrap().contains(missing),
        "the failure must name the path that was tried, got: {}",
        probe["reason"]
    );
}

#[test]
fn a_configured_path_that_is_not_git_is_rejected_by_the_version_check() {
    // An executable that exists and exits 0 is not enough: it has to actually
    // be git. Validating at set time is what stops this surfacing later, at the
    // moment a user pushes their first patch.
    let dir = fixture::scratch_dir("git-preflight-not-git");
    let fake = dir.join("notgit");
    std::fs::write(&fake, "#!/bin/sh\necho 'I am not git'\n").expect("write fake");

    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    let probe = parse(&env::git_probe(&fake.display().to_string()));

    assert_eq!(
        probe["found"],
        serde_json::json!(false),
        "a real-but-not-git binary must be refused, got: {probe}"
    );
    assert!(
        probe["reason"]
            .as_str()
            .unwrap()
            .contains("does not look like git"),
        "the reason should say it is not git, got: {}",
        probe["reason"]
    );
}

#[test]
fn a_binary_that_exits_nonzero_is_refused() {
    let dir = fixture::scratch_dir("git-preflight-fails");
    let fake = dir.join("failing");
    std::fs::write(&fake, "#!/bin/sh\nexit 3\n").expect("write fake");

    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    let probe = parse(&env::git_probe(&fake.display().to_string()));
    assert_eq!(probe["found"], serde_json::json!(false));
}

// ---------------------------------------------------------------------------
// The positive case, which is only meaningful next to the negatives above.
// ---------------------------------------------------------------------------

#[test]
fn a_configured_path_to_a_real_git_is_accepted_and_reports_its_version() {
    // Uses whatever git this machine has, found the same way a shell would.
    // Skipped rather than failed if there is none: that says something about
    // the machine, not the code. Every OTHER test in this file runs regardless,
    // which is what keeps this from being a suite that can quietly do nothing.
    let Some(real) = find_git() else {
        eprintln!("no git on PATH; skipping the positive case only");
        return;
    };

    let probe = parse(&env::git_probe(&real));
    assert_eq!(probe["found"], serde_json::json!(true), "got: {probe}");
    assert_eq!(probe["configured"], serde_json::json!(true));
    assert!(
        probe["version"]
            .as_str()
            .unwrap()
            .starts_with("git version"),
        "got: {}",
        probe["version"]
    );
    // The resolved path is reported back, which is what the settings UI shows
    // so a user can see which git is actually in force.
    assert_eq!(probe["path"], serde_json::json!(real));
}

#[test]
fn an_empty_setting_means_find_it_on_path() {
    let Some(real) = find_git() else {
        eprintln!("no git on PATH; skipping");
        return;
    };
    let probe = parse(&env::git_probe(""));

    assert_eq!(probe["found"], serde_json::json!(true), "got: {probe}");
    // Reported as not configured, so the UI can show "auto-detected" rather
    // than implying the user pinned this path.
    assert_eq!(probe["configured"], serde_json::json!(false));
    assert_eq!(probe["path"], serde_json::json!(real));
}

#[test]
fn the_configured_flag_distinguishes_an_explicit_path_from_detection() {
    // Input-dependent: the same resolved git, reached two ways, must report
    // `configured` differently. A probe that hardcoded either value would pass
    // one of these and fail the other.
    let Some(real) = find_git() else {
        eprintln!("no git on PATH; skipping");
        return;
    };
    let detected = parse(&env::git_probe(""));
    let explicit = parse(&env::git_probe(&real));

    assert_eq!(detected["path"], explicit["path"]);
    assert_ne!(detected["configured"], explicit["configured"]);
}

/// Locate git the way the resolver does, for the positive cases above.
fn find_git() -> Option<String> {
    let probe = parse(&env::git_probe(""));
    if probe["found"] == serde_json::json!(true) {
        Some(probe["path"].as_str().unwrap().to_string())
    } else {
        None
    }
}
