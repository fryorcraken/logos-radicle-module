//! Read issues and patches from one real repository and check the fields the
//! QML actually renders are populated.
//!
//! Companion to `probe_real_profile`. The fixture tests create COBs with one
//! author, one comment and no edits; a repository with years of real history
//! has redacted comments, multi-revision patches, merged states and authors
//! who never aliased themselves. This is where a shape that only breaks on
//! that shows up.
//!
//! Run with:
//!   cargo run --example probe_cobs -- <rid> [rad-home]

fn parse(s: &str) -> serde_json::Value {
    serde_json::from_str(s).unwrap_or_else(|e| panic!("non-JSON: {e}\n{s}"))
}

fn main() {
    let rid = std::env::args()
        .nth(1)
        .expect("usage: probe_cobs <rid> [rad-home]");
    let home = std::env::args()
        .nth(2)
        .unwrap_or_else(|| format!("{}/.radicle", std::env::var("HOME").expect("no HOME")));

    for (label, list, get) in [
        (
            "issue",
            radicle_local_ffi::cobs::list_issues(&home, &rid, "", 0, 200),
            true,
        ),
        (
            "patch",
            radicle_local_ffi::cobs::list_patches(&home, &rid, "", 0, 200),
            false,
        ),
    ] {
        let v = parse(&list);
        if let Some(e) = v.get("error") {
            eprintln!("{label} list failed: {e}");
            continue;
        }
        let items = v["items"].as_array().cloned().unwrap_or_default();
        eprintln!("== {} {label}s\n", items.len());

        // Every field the views read must be present on every item, or some
        // rows render as "(untitled)" by an unknown author with no badge.
        let mut missing_title = 0;
        let mut missing_author = 0;
        let mut missing_state = 0;
        let mut states = std::collections::BTreeMap::<String, usize>::new();
        let mut bad_timestamps = 0;

        for item in &items {
            if item["title"].as_str().unwrap_or("").is_empty() {
                missing_title += 1;
            }
            if !item["author"]["id"]
                .as_str()
                .unwrap_or("")
                .starts_with("did:key:")
            {
                missing_author += 1;
            }
            match item["state"]["status"].as_str() {
                Some(s) => *states.entry(s.to_string()).or_default() += 1,
                None => missing_state += 1,
            }
            // Unix seconds, not milliseconds: the view multiplies by 1000.
            let t = item["timestamp"].as_i64().unwrap_or(0);
            if !(1_000_000_000..4_000_000_000).contains(&t) {
                bad_timestamps += 1;
            }
        }

        eprintln!("  states seen:      {states:?}");
        eprintln!("  missing title:    {missing_title}");
        eprintln!("  missing author:   {missing_author}");
        eprintln!("  missing state:    {missing_state}");
        eprintln!("  odd timestamps:   {bad_timestamps}");

        // Open a handful in detail, including the busiest, since a long thread
        // is where a replay problem would surface.
        let mut sample: Vec<&serde_json::Value> = items.iter().take(3).collect();
        if let Some(last) = items.last() {
            sample.push(last);
        }
        for item in sample {
            let id = item["id"].as_str().unwrap_or_default();
            let detail = if get {
                radicle_local_ffi::cobs::get_issue(&home, &rid, id)
            } else {
                radicle_local_ffi::cobs::get_patch(&home, &rid, id)
            };
            let d = parse(&detail);
            match d.get("error") {
                Some(e) => eprintln!("  {label} {:.8} ERROR {e}", id),
                None => {
                    let comments = d["discussion"].as_array().map(|a| a.len()).unwrap_or(0);
                    let revisions = d["revisions"].as_array().map(|a| a.len()).unwrap_or(0);
                    let empty_bodies = d["discussion"]
                        .as_array()
                        .map(|a| {
                            a.iter()
                                .filter(|c| c["body"].as_str().unwrap_or("").is_empty())
                                .count()
                        })
                        .unwrap_or(0);
                    eprintln!(
                        "  {label} {:.8} \"{}\" comments={comments} (empty={empty_bodies}) revisions={revisions}",
                        id,
                        d["title"].as_str().unwrap_or("?"),
                    );
                }
            }
        }
        eprintln!();
    }
}
