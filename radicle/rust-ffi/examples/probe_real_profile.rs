//! Read the developer's actual `~/.radicle` and print what comes back.
//!
//! Not a test — it depends on whatever happens to be on this machine, so it
//! can neither pass nor fail meaningfully in CI. It exists because the test
//! suite builds its own fixtures, and a fixture built by the same code that
//! reads it can agree with itself while both are wrong about what a real
//! `rad`-created profile looks like. This is the check against that.
//!
//! Run with:
//!   cargo run --example probe_real_profile -- [rad-home]

fn main() {
    let home = std::env::args().nth(1).unwrap_or_else(|| {
        std::env::var("RAD_HOME")
            .unwrap_or_else(|_| format!("{}/.radicle", std::env::var("HOME").expect("no HOME")))
    });
    eprintln!("== reading {home}\n");

    let repos = radicle_local_ffi::local::list_repos(&home, "all", 0, 100);
    let v: serde_json::Value = serde_json::from_str(&repos).expect("list_repos returned non-JSON");
    if let Some(err) = v.get("error") {
        eprintln!("list_repos failed: {err}");
        std::process::exit(1);
    }

    let items = v["items"].as_array().cloned().unwrap_or_default();
    eprintln!("{} repositories\n", items.len());

    for item in &items {
        let rid = item["rid"].as_str().unwrap_or("?");
        let data = &item["payloads"]["xyz.radicle.project"]["data"];
        let meta = &item["payloads"]["xyz.radicle.project"]["meta"];
        eprintln!(
            "{:<34} {:<24} branch={:<10} head={:.8} issues={} patches={} vis={}",
            rid,
            data["name"].as_str().unwrap_or("?"),
            data["defaultBranch"].as_str().unwrap_or("?"),
            meta["head"].as_str().unwrap_or("?"),
            meta["issues"]["open"],
            meta["patches"]["open"],
            item["visibility"]["type"].as_str().unwrap_or("?"),
        );
    }

    // Exercise every other read against the first repo that has a head, so a
    // shape that only breaks on real data shows up here.
    let Some(first) = items.first() else {
        eprintln!("\nno repositories to read further");
        return;
    };
    let rid = first["rid"].as_str().unwrap_or_default().to_string();
    eprintln!("\n== reading {rid} in detail\n");

    let show = |label: &str, json: String| {
        let v: serde_json::Value = match serde_json::from_str(&json) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("{label:<14} NON-JSON: {e}");
                return;
            }
        };
        match v.get("error") {
            Some(e) => eprintln!("{label:<14} error: {e}"),
            None => {
                let preview: String = json.chars().take(220).collect();
                eprintln!("{label:<14} ok   {preview}");
            }
        }
        eprintln!();
    };

    show(
        "tree",
        radicle_local_ffi::gitread::get_tree(&home, &rid, "", ""),
    );
    show(
        "readme",
        radicle_local_ffi::gitread::get_readme(&home, &rid, ""),
    );
    show(
        "commits",
        radicle_local_ffi::gitread::list_commits(&home, &rid, "", 0, 3),
    );
    show(
        "issues",
        radicle_local_ffi::cobs::list_issues(&home, &rid, "", 0, 5),
    );
    show(
        "patches",
        radicle_local_ffi::cobs::list_patches(&home, &rid, "", 0, 5),
    );

    // A commit and its diff, taken from the log rather than guessed.
    let log = radicle_local_ffi::gitread::list_commits(&home, &rid, "", 0, 1);
    if let Ok(l) = serde_json::from_str::<serde_json::Value>(&log) {
        if let Some(sha) = l["items"][0]["id"].as_str() {
            show(
                "commit+diff",
                radicle_local_ffi::gitread::get_commit(&home, &rid, sha),
            );
        }
    }

    // Scope filtering, which only means anything against a real node's mix of
    // delegated and merely-seeded repositories.
    eprintln!("== scopes\n");
    for scope in ["all", "delegate", "private", "seeded"] {
        let out = radicle_local_ffi::local::list_repos(&home, scope, 0, 100);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap_or_default();
        eprintln!(
            "{scope:<10} {} repos",
            v["items"].as_array().map(|a| a.len()).unwrap_or(0)
        );
    }
}
