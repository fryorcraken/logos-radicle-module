//! Read every repo the way the UI actually does, and report which ones fail.
//!
//! `probe_real_profile` passes an empty sha, which exercises `resolve_commit`'s
//! head fallback. The UI does NOT do that: `SourceTab.loadTree()` passes
//! `branch` — the repo's `defaultBranch` — as the sha argument. Those are
//! different inputs down a different path, and a repo can read perfectly with
//! one and return nothing with the other.
//!
//! Run with:
//!   cargo run --example probe_ui_args -- [rad-home]

fn main() {
    let home = std::env::args().nth(1).unwrap_or_else(|| {
        std::env::var("RAD_HOME")
            .unwrap_or_else(|_| format!("{}/.radicle", std::env::var("HOME").expect("no HOME")))
    });
    eprintln!("== reading {home} the way the UI does\n");

    let repos = radicle_local_ffi::local::list_repos(&home, "all", 0, 100);
    let v: serde_json::Value = serde_json::from_str(&repos).expect("list_repos returned non-JSON");
    let items = v["items"].as_array().cloned().unwrap_or_default();

    let mut failures = 0;
    for item in &items {
        let rid = item["rid"].as_str().unwrap_or("?");
        let data = &item["payloads"]["xyz.radicle.project"]["data"];
        let name = data["name"].as_str().unwrap_or("?");
        // Exactly what RepoView.branch resolves to, and what loadTree passes.
        let branch = data["defaultBranch"].as_str().unwrap_or("");

        let tree = radicle_local_ffi::gitread::get_tree(&home, rid, branch, "");
        let t: serde_json::Value = serde_json::from_str(&tree).unwrap_or_default();
        let count = t["entries"].as_array().map(|a| a.len()).unwrap_or(0);
        let err = t["error"].as_str().unwrap_or("");

        let verdict = if !err.is_empty() {
            failures += 1;
            format!("ERROR {err}")
        } else if count == 0 {
            failures += 1;
            "EMPTY TREE".to_string()
        } else {
            format!("{count} entries")
        };
        eprintln!("{name:<24} branch={branch:<10} {verdict}");
    }

    eprintln!("\n{failures} of {} repositories failed", items.len());
    if failures > 0 {
        std::process::exit(1);
    }
}
