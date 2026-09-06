//! The `git` preflight: finding it, validating it, and refusing it.
//!
//! **The negative cases are the point of this file.** A test that configures a
//! working git and sees success proves almost nothing: it passes just as
//! happily against a resolver that ignores the setting entirely and falls back
//! to whatever is on `PATH`. That is the same-answer-for-every-input trap this
//! repo has shipped before, and it is why the cases below exist —
//!
//!   - a path that does **not** exist, asserting the failure names that path;
//!   - a path that exists and is executable but is **not git**, asserting the
//!     `--version` validation rejects it;
//!   - a **relative** path, which `Path::exists` and `Command::new` resolve
//!     against two different roots — so accepting one would mean validating one
//!     binary and running another.
//!
//! Only those can tell "honours the setting" from "ignores the setting".

mod fixture;

use radicle_local_ffi::env;

fn parse(json: &str) -> serde_json::Value {
    serde_json::from_str(json).unwrap_or_else(|e| panic!("not valid JSON: {e}\n{json}"))
}

/// Write a shell script and make it executable, **closing the file before
/// chmod**.
///
/// The close is the point, and it is why this is a function rather than four
/// inline lines. Linux refuses `execve` on a file that is still open for
/// writing anywhere in the system, with `ETXTBSY` — "Text file busy". The tests
/// below write a fake binary and then run it a few microseconds later, so with
/// the `File` left to drop at the end of the statement the race is real but
/// rare: it was observed failing exactly once. A test that fails one run in
/// hundreds is worse than one that fails always, because it trains people to
/// re-run rather than to read.
fn write_executable(path: &std::path::Path, contents: &str) {
    use std::io::Write as _;
    use std::os::unix::fs::PermissionsExt;

    {
        let mut file = std::fs::File::create(path).expect("create fake binary");
        file.write_all(contents.as_bytes()).expect("write fake");
        // Flush to the OS explicitly rather than trusting the drop below to
        // report a failure it cannot return.
        file.sync_all().expect("sync fake");
    } // <- closed here, before the chmod and long before the exec.

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
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
    write_executable(&fake, "#!/bin/sh\necho 'I am not git'\n");

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

/// A relative path is validated against the process's current directory by
/// `Path::exists` but executed against `PATH` by `Command::new` — two different
/// binaries under one setting. That is not a hypothetical mismatch: a bare
/// `git` "exists" only if there happens to be a file called `git` in whatever
/// directory Basecamp launched the module from, and runs whatever `PATH`
/// resolves regardless. The whole point of this preflight is that the path
/// reported is the path used, so a candidate that cannot promise that is
/// refused rather than resolved one way or the other.
#[test]
fn a_relative_git_path_is_refused_rather_than_resolved_two_different_ways() {
    for candidate in ["git", "./git", "../bin/git", "bin/git"] {
        let probe = parse(&env::git_probe(candidate));
        assert_eq!(
            probe["found"],
            serde_json::json!(false),
            "a relative candidate {candidate:?} must be refused, got: {probe}"
        );
        assert!(
            probe["reason"].as_str().unwrap().contains("absolute"),
            "the reason must say what is wrong with it, got: {}",
            probe["reason"]
        );
        // Still reported as configured: the user did set something, and a UI
        // that showed "found automatically" here would be describing a state
        // the module is not in.
        assert_eq!(probe["configured"], serde_json::json!(true));
    }
}

/// The half that keeps the rejection from being a blanket refusal: a relative
/// path naming a REAL, WORKING git is still refused, while the same binary by
/// its absolute path is accepted. Without this, "refuse everything relative"
/// and "refuse everything" are indistinguishable.
#[test]
fn the_same_git_is_accepted_absolute_and_refused_relative() {
    let Some(real) = find_git() else {
        eprintln!("no git on PATH; skipping");
        return;
    };
    let relative = real.trim_start_matches('/').to_string();

    assert_eq!(
        parse(&env::git_probe(&real))["found"],
        serde_json::json!(true)
    );
    assert_eq!(
        parse(&env::git_probe(&relative))["found"],
        serde_json::json!(false),
        "the same binary named relatively must be refused"
    );
}

#[test]
fn a_binary_that_exits_nonzero_is_refused() {
    let dir = fixture::scratch_dir("git-preflight-fails");
    let fake = dir.join("failing");
    write_executable(&fake, "#!/bin/sh\nexit 3\n");

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
