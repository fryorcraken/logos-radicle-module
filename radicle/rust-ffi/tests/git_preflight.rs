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

/// Write a shell script and make it executable, staging it under a scratch
/// name and `rename`-ing it into place.
///
/// **Closing the file before the exec is necessary and not sufficient**, which
/// is what the previous version of this comment got wrong. Linux refuses
/// `execve` on a file open for writing anywhere in the system, with `ETXTBSY` —
/// "Text file busy" — and "anywhere in the system" reaches a descriptor this
/// thread has already closed:
///
///   - `fork()` copies the entire descriptor table of the forking process, and
///     `O_CLOEXEC` clears a descriptor at `execve`, **not at fork**;
///   - so while this thread holds its write handle, any *other* thread of the
///     same process that spawns anything at all hands a writable copy of that
///     handle to a child, and the file counts as open for writing until that
///     child reaches its own `execve`;
///   - several tests in this file spawn a process — that is what `git_probe`
///     does — and the harness runs them in parallel threads.
///
/// The window is far wider than it looks, too: `sync_all` is an `fsync`,
/// measured here at a mean of ~515µs and a worst case of 21ms. A sibling fork
/// lands inside that easily, which is why CI failed while a developer box on
/// more cores looked clean.
///
/// Staging and renaming is a large improvement but **not a cure**, and the
/// reason is worth keeping: the unit ETXTBSY counts is the *inode*, not the
/// path, and `rename` moves the name onto the very inode that was just held
/// open for writing. Measured against a harness of this exact shape — one
/// thread writing and exec'ing, three siblings spawning `/bin/true` — over 5000
/// execs each:
///
/// ```text
/// write in place (what this used to do)   1538 ETXTBSY
/// copy over the target                     953
/// hard-link a fresh name to it              35   <- same inode, same problem
/// stage + rename                            46
/// stage + rename, retrying on ETXTBSY        0
/// written once, before any sibling forks      0
/// ```
///
/// So the retry in [`probe_fake`] is deliberate rather than a papering-over,
/// and this is the one case where it is the right call: the fork that reopens
/// the window belongs to *another thread running library code*, so no amount of
/// care on this side can close it. The retry is bounded and narrow — it retries
/// **only** `ETXTBSY`, never any other error and never a wrong answer — so it
/// cannot mask the thing these tests exist to catch. A probe that runs the fake
/// and reports "does not look like git" still has to say so.
fn write_executable(path: &std::path::Path, contents: &str) {
    use std::io::Write as _;
    use std::os::unix::fs::PermissionsExt;

    // A sibling name in the same directory, so the rename stays within one
    // filesystem and is therefore atomic.
    let staging = path.with_extension("staging");

    {
        let mut file = std::fs::File::create(&staging).expect("create fake binary");
        file.write_all(contents.as_bytes()).expect("write fake");
        // Flush to the OS explicitly rather than trusting the drop below to
        // report a failure it cannot return.
        file.sync_all().expect("sync fake");
    } // <- closed here, so the rename publishes a complete file.

    std::fs::set_permissions(&staging, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    std::fs::rename(&staging, path).expect("publish fake binary");
}

/// Probe a fake binary this file just wrote, retrying only while the kernel
/// says `ETXTBSY`.
///
/// See [`write_executable`] for why that can happen at all and why it cannot be
/// designed out from this side. The narrowness is the safety property: the
/// retry fires on one specific transient string and nothing else, so a genuine
/// refusal — the "does not look like git" these tests assert on — is returned
/// on the first attempt and never retried into something else. If the window
/// somehow stayed open, this fails with the ETXTBSY message rather than looping
/// forever, so the failure still names the real cause.
fn probe_fake(path: &std::path::Path) -> serde_json::Value {
    let candidate = path.display().to_string();

    let mut last = serde_json::Value::Null;
    for attempt in 0..10 {
        last = parse(&env::git_probe(&candidate));
        let busy = last["reason"]
            .as_str()
            .is_some_and(|r| r.contains("Text file busy"));
        if !busy {
            return last;
        }
        // Back off enough for any forked child to reach its own execve, which
        // is what drops the inherited descriptor.
        std::thread::sleep(std::time::Duration::from_millis(5 * (attempt + 1)));
    }
    last
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

    let probe = probe_fake(&fake);

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

    let probe = probe_fake(&fake);
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
