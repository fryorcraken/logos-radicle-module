//! Print every branch's root tree, so you can see WHICH branch a read
//! resolved to rather than merely that one did.
//!
//! This exists because the resolution bug in this crate was silent: an
//! unresolvable ref falls back to the repo head and returns a populated tree
//! with no error, so counting entries cannot tell a correct read from a
//! fallback. Only a file unique to one branch can. Against the profile
//! `examples/seed_write_profile.rs` builds, the expected output is:
//!
//! ```text
//! master                      ["README.md", "src"]
//! feature/seeded              ["FEATURE.md", ...]
//! <peer>/their-work           ["THEIR_WORK.md", ...]
//! ```
//!
//! — which is what makes `local.yaml`'s "and it is the picked branch's tree"
//! step meaningful. If `THEIR_WORK.md` ever appears on more than one branch,
//! that assertion has quietly stopped discriminating and needs a new marker.
//!
//! Not a test: it reads whatever profile it is pointed at, so it can neither
//! pass nor fail in CI.
//!
//! Run with:
//!   cargo run --example probe_marker -- <rad-home>

fn main() {
    let home = std::env::args()
        .nth(1)
        .expect("usage: probe_marker <rad-home>");

    let repos = radicle_local_ffi::local::list_repos(&home, "all", 0, 100);
    let v: serde_json::Value = serde_json::from_str(&repos).expect("non-JSON");
    let items = v["items"].as_array().cloned().unwrap_or_default();

    for item in &items {
        let rid = item["rid"].as_str().unwrap_or("?");
        let name = item["payloads"]["xyz.radicle.project"]["data"]["name"]
            .as_str()
            .unwrap_or("?");
        eprintln!("{name}");

        let branches = radicle_local_ffi::local::list_branches(&home, rid);
        let b: serde_json::Value = serde_json::from_str(&branches).expect("non-JSON");
        for br in b["items"].as_array().cloned().unwrap_or_default() {
            let bname = br["name"].as_str().unwrap_or("?");
            let tree = radicle_local_ffi::gitread::get_tree(&home, rid, bname, "");
            let t: serde_json::Value = serde_json::from_str(&tree).expect("non-JSON");
            let files: Vec<String> = t["entries"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .iter()
                .map(|e| e["name"].as_str().unwrap_or("").to_string())
                .collect();
            eprintln!("    {bname:<60} {files:?}");
        }
    }
}
