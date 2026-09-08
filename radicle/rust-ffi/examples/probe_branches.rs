//! Print `refs.refs` from `get_repo` for every local repo, so the branch list
//! the UI's picker is built from can be compared against `rad inspect --refs`.
//!
//! Not a test — it reads this machine's real profile, so it can neither pass
//! nor fail meaningfully in CI. It exists for the same reason
//! `probe_real_profile` does: a fixture built by the same code that reads it
//! can agree with itself while both are wrong about a real `rad`-created
//! profile.
//!
//! Run with:
//!   cargo run --example probe_branches -- [rad-home]

fn main() {
    let home = std::env::args().nth(1).unwrap_or_else(|| {
        std::env::var("RAD_HOME")
            .unwrap_or_else(|_| format!("{}/.radicle", std::env::var("HOME").expect("no HOME")))
    });
    eprintln!("== reading {home}\n");

    let repos = radicle_local_ffi::local::list_repos(&home, "all", 0, 100);
    let v: serde_json::Value = serde_json::from_str(&repos).expect("list_repos returned non-JSON");
    let items = v["items"].as_array().cloned().unwrap_or_default();

    for item in &items {
        let rid = item["rid"].as_str().unwrap_or("?");
        let name = item["payloads"]["xyz.radicle.project"]["data"]["name"]
            .as_str()
            .unwrap_or("?");
        let repo = radicle_local_ffi::local::get_repo(&home, rid);
        let r: serde_json::Value = match serde_json::from_str(&repo) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("{name}: non-JSON: {e}");
                continue;
            }
        };
        if let Some(err) = r.get("error") {
            eprintln!("{name}: error {err}");
            continue;
        }
        let refs = r["refs"]["refs"].as_object().cloned().unwrap_or_default();

        let branches = radicle_local_ffi::local::list_branches(&home, rid);
        let b: serde_json::Value = match serde_json::from_str(&branches) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("{name}: list_branches non-JSON: {e}");
                continue;
            }
        };
        if let Some(err) = b.get("error") {
            eprintln!("{name}: list_branches error {err}");
            continue;
        }
        let items = b["items"].as_array().cloned().unwrap_or_default();
        let local = items.iter().filter(|i| i["isLocal"] == true).count();

        eprintln!(
            "{name}  (canonical refs/heads: {}, branches: {} — {} local, {} peer)",
            refs.len(),
            items.len(),
            local,
            items.len() - local,
        );
        for i in &items {
            eprintln!(
                "    {:<44} {}",
                i["label"].as_str().unwrap_or("?"),
                if i["isLocal"] == true {
                    "local"
                } else {
                    "peer"
                },
            );
        }
    }
}
