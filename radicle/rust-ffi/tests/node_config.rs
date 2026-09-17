//! `getNodeConfig` / `setNodeConfig` against a real `config.json` on disk.
//!
//! The unit tests beside `nodeconfig.rs` cover the validators in isolation.
//! What needs a real file is everything about the read-modify-write itself:
//! that a write preserves what it did not set, that a refusal leaves the file
//! untouched, and that a value read back is the value stored rather than the
//! value submitted.

mod fixture;

use fixture::{init_profile, parse};
use radicle_local_ffi::nodeconfig;

/// The path `nodeconfig` reads and writes, for tests that inspect the file
/// directly rather than through the module.
fn config_path(home: &str) -> std::path::PathBuf {
    std::path::Path::new(home).join("config.json")
}

fn read_raw(home: &str) -> serde_json::Value {
    let text = std::fs::read_to_string(config_path(home)).expect("config.json should exist");
    serde_json::from_str(&text).expect("config.json should be JSON")
}

fn get(home: &str) -> serde_json::Value {
    parse(&nodeconfig::get(home))
}

fn set(home: &str, changes: serde_json::Value) -> serde_json::Value {
    parse(&nodeconfig::set(home, &changes.to_string()))
}

/// Put a key into the `node` object that this build has no field for.
///
/// This is the state the whole raw-JSON design exists for: a user on a newer
/// `rad` whose configuration carries a field this build predates.
fn plant_unknown_key(home: &str, key: &str, value: serde_json::Value) {
    let mut doc = read_raw(home);
    doc["node"][key] = value;
    std::fs::write(
        config_path(home),
        serde_json::to_string_pretty(&doc).unwrap(),
    )
    .expect("could not plant key");
}

#[test]
fn a_key_this_build_does_not_know_survives_a_write() {
    // **This is the test that pins the design.** `node::Config.extra` is
    // `#[serde(flatten, skip_serializing)]`, so the obvious implementation —
    // `Config::load`, change a field, `Config::write` — drops every key this
    // build does not know, silently. Verified by mutation: replacing
    // `write_document`'s raw-JSON path with `Config::write` leaves this as the
    // only failing test in the file.
    let f = init_profile("nodeconfig-unknown-key");
    let home = f.home();

    plant_unknown_key(&home, "mysteriousFutureField", serde_json::json!("keep me"));

    let reply = set(&home, serde_json::json!({ "alias": "renamed" }));
    assert!(reply.get("error").is_none(), "{reply}");

    let raw = read_raw(&home);
    // The value, not merely the presence: a write that preserved the key but
    // reset it to a default would satisfy a `contains_key` assertion while
    // losing exactly the data this is about.
    assert_eq!(
        raw["node"]["mysteriousFutureField"],
        serde_json::json!("keep me"),
        "the unknown key must survive with its value"
    );
    // And the change the caller actually asked for did land, so the test cannot
    // pass by way of a write that did nothing at all.
    assert_eq!(raw["node"]["alias"], serde_json::json!("renamed"));
}

#[test]
fn an_unrelated_known_field_survives_a_write() {
    // The sibling case the spec states separately: a field this build DOES know
    // but does not expose. `workers` is one a user might plausibly have set by
    // hand, and this module has no field for it in either direction.
    //
    // Unlike the unknown-key test above, this one does NOT discriminate against
    // the `Config::write` round-trip — measured, not assumed: `workers` is a
    // real field of the crate's type, so a round-trip carries it through. It is
    // kept because the spec requires the behaviour, and because a future change
    // to how the `node` object is rebuilt could drop it while leaving the
    // unknown-key path intact.
    let f = init_profile("nodeconfig-known-field");
    let home = f.home();

    plant_unknown_key(&home, "workers", serde_json::json!(9));

    let reply = set(&home, serde_json::json!({ "alias": "renamed" }));
    assert!(reply.get("error").is_none(), "{reply}");

    assert_eq!(read_raw(&home)["node"]["workers"], serde_json::json!(9));
}

#[test]
fn a_refused_write_leaves_the_file_byte_for_byte() {
    let f = init_profile("nodeconfig-refusal-is-inert");
    let home = f.home();

    let before = std::fs::read(config_path(&home)).expect("read before");

    // An alias with whitespace: refused by the crate's own rule.
    let reply = set(&home, serde_json::json!({ "alias": "my node" }));
    assert!(reply["error"].as_str().is_some(), "{reply}");

    let after = std::fs::read(config_path(&home)).expect("read after");
    assert_eq!(before, after, "a refused write must not touch the file");
}

#[test]
fn a_write_returns_the_whole_object_and_leaves_unnamed_fields_alone() {
    let f = init_profile("nodeconfig-whole-object");
    let home = f.home();

    // Establish a non-default value in a field the next call will not name.
    let seeded = set(
        &home,
        serde_json::json!({ "externalAddresses": ["node.example.test:8776"] }),
    );
    assert!(seeded.get("error").is_none(), "{seeded}");

    let reply = set(&home, serde_json::json!({ "alias": "only-alias" }));
    assert!(reply.get("error").is_none(), "{reply}");

    // The reply is the whole shape, not a diff.
    for key in [
        "alias",
        "listen",
        "externalAddresses",
        "connect",
        "peers",
        "inboundReachable",
        "restartRequired",
    ] {
        assert!(
            reply.get(key).is_some(),
            "reply must contain {key}: {reply}"
        );
    }
    assert_eq!(
        reply.as_object().unwrap().len(),
        7,
        "the reply must contain no key beyond the seven: {reply}"
    );

    // And the field the call did not name kept its value.
    assert_eq!(
        reply["externalAddresses"],
        serde_json::json!(["node.example.test:8776"])
    );
    assert_eq!(reply["alias"], serde_json::json!("only-alias"));
}

#[test]
fn a_fresh_profile_is_outbound_only_and_says_so() {
    let f = init_profile("nodeconfig-outbound-only");
    let home = f.home();

    let reply = get(&home);
    assert_eq!(reply["listen"], serde_json::json!([]));
    assert_eq!(reply["inboundReachable"], serde_json::json!(false));
}

#[test]
fn setting_an_external_address_does_not_turn_inbound_on() {
    // The two are independent, and conflating them is an easy mistake to make:
    // "the user gave us a public address, so presumably they want inbound" is
    // exactly the kind of helpfulness that opens a port nobody asked for.
    let f = init_profile("nodeconfig-external-not-inbound");
    let home = f.home();

    let reply = set(
        &home,
        serde_json::json!({ "externalAddresses": ["node.example.test:8776"] }),
    );
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["listen"], serde_json::json!([]));
    assert_eq!(reply["inboundReachable"], serde_json::json!(false));

    assert_eq!(get(&home)["inboundReachable"], serde_json::json!(false));
}

#[test]
fn setting_a_listen_address_turns_inbound_on() {
    let f = init_profile("nodeconfig-listen-on");
    let home = f.home();

    let reply = set(&home, serde_json::json!({ "listen": ["0.0.0.0:8776"] }));
    assert!(reply.get("error").is_none(), "{reply}");

    let read_back = get(&home);
    assert_eq!(read_back["listen"], serde_json::json!(["0.0.0.0:8776"]));
    assert_eq!(read_back["inboundReachable"], serde_json::json!(true));
}

#[test]
fn each_address_spelling_is_accepted_in_its_own_field_and_refused_in_the_other() {
    let f = init_profile("nodeconfig-address-spellings");
    let home = f.home();

    let with_id = "z6MkrLMMsiPWUcNPHcRajuMi9mDfYckSoJyPwwnknocNYPm7@seed.example.test:8776";
    let without_id = "node.example.test:8776";

    // Each in its own field: accepted, and reported back as submitted.
    let reply = set(
        &home,
        serde_json::json!({ "connect": [with_id], "externalAddresses": [without_id] }),
    );
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["connect"], serde_json::json!([with_id]));
    assert_eq!(reply["externalAddresses"], serde_json::json!([without_id]));

    // Swapped: each refused, and neither stored value changes.
    let swapped_connect = set(&home, serde_json::json!({ "connect": [without_id] }));
    assert!(
        swapped_connect["error"]
            .as_str()
            .is_some_and(|m| m.contains(without_id)),
        "{swapped_connect}"
    );

    let swapped_external = set(&home, serde_json::json!({ "externalAddresses": [with_id] }));
    assert!(
        swapped_external["error"].as_str().is_some(),
        "{swapped_external}"
    );

    let read_back = get(&home);
    assert_eq!(read_back["connect"], serde_json::json!([with_id]));
    assert_eq!(
        read_back["externalAddresses"],
        serde_json::json!([without_id])
    );
}

#[test]
fn static_with_nobody_to_connect_to_is_refused_but_both_in_one_call_is_not() {
    // The second half is what makes this a real check rather than a blanket
    // refusal of `static`: a test asserting only that `static` alone fails
    // passes equally against an implementation that never accepts `static`.
    let f = init_profile("nodeconfig-static-peers");
    let home = f.home();

    let alone = set(&home, serde_json::json!({ "peers": "static" }));
    assert!(alone["error"].as_str().is_some(), "{alone}");
    assert_eq!(
        get(&home)["peers"],
        serde_json::json!("dynamic"),
        "a refused discipline must leave the stored one alone"
    );

    let together = set(
        &home,
        serde_json::json!({
            "peers": "static",
            "connect": ["z6MkrLMMsiPWUcNPHcRajuMi9mDfYckSoJyPwwnknocNYPm7@seed.example.test:8776"],
        }),
    );
    assert!(together.get("error").is_none(), "{together}");
    assert_eq!(get(&home)["peers"], serde_json::json!("static"));
}

#[test]
fn a_home_with_no_configuration_is_reported_as_such_and_none_is_created() {
    let dir = fixture::scratch_dir("nodeconfig-no-config");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).expect("mkdir");
    let home = home.display().to_string();

    let reply = get(&home);
    let msg = reply["error"].as_str().expect("an error");
    assert!(msg.contains(&home), "the message must name the home: {msg}");

    let written = set(&home, serde_json::json!({ "alias": "anything" }));
    assert!(written["error"].as_str().is_some(), "{written}");
    assert!(
        !config_path(&home).exists(),
        "a write must not bring a configuration into existence"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_unparseable_configuration_is_an_error_naming_the_file_not_a_set_of_defaults() {
    let f = init_profile("nodeconfig-unparseable");
    let home = f.home();

    std::fs::write(config_path(&home), "this is not JSON at all").expect("clobber");

    let reply = get(&home);
    let msg = reply["error"].as_str().expect("an error");
    assert!(
        msg.contains("config.json"),
        "the message must name the file: {msg}"
    );
    // Defaults presented as a configuration are indistinguishable on screen
    // from a real one, so the reply must carry no configuration at all.
    assert!(reply.get("alias").is_none(), "{reply}");
}

#[test]
fn a_value_that_would_leave_the_file_unreadable_is_refused_before_it_is_written() {
    // The raw-JSON path gives up the crate's implicit shape-checking, and this
    // is where it is bought back: the edited document must deserialize into
    // `radicle::profile::Config` or nothing is written. Without that step a
    // `listen` of the wrong JSON type would reach disk and fail at the node's
    // next start instead.
    let f = init_profile("nodeconfig-shape-guard");
    let home = f.home();

    let before = std::fs::read(config_path(&home)).expect("read before");
    let reply = set(&home, serde_json::json!({ "listen": "0.0.0.0:8776" }));
    assert!(
        reply["error"].as_str().is_some(),
        "a string where an array belongs must be refused: {reply}"
    );
    assert_eq!(std::fs::read(config_path(&home)).unwrap(), before);
}

#[test]
fn two_homes_report_two_different_configurations() {
    // A fixture that answers the same for every input cannot tell "read the
    // home it was given" from "read something else": this is what makes the
    // home parameter provably load-bearing.
    let a = init_profile("nodeconfig-two-homes-a");
    let b = init_profile("nodeconfig-two-homes-b");

    assert!(set(&a.home(), serde_json::json!({ "alias": "alpha" }))
        .get("error")
        .is_none());
    assert!(set(&b.home(), serde_json::json!({ "alias": "beta" }))
        .get("error")
        .is_none());

    assert_eq!(get(&a.home())["alias"], serde_json::json!("alpha"));
    assert_eq!(get(&b.home())["alias"], serde_json::json!("beta"));
}

#[test]
fn with_no_node_running_nothing_asks_for_a_restart() {
    // The half of `restartRequired` that needs no daemon. The three-state
    // sequence — running-and-unchanged, running-and-changed, restarted — is in
    // `tests/node_lifecycle.rs`, where a real node can be stood up; asserting it
    // here would either need one or prove nothing.
    let f = init_profile("nodeconfig-no-node-no-restart");
    let home = f.home();

    assert_eq!(get(&home)["restartRequired"], serde_json::json!(false));

    let written = set(&home, serde_json::json!({ "alias": "changed" }));
    assert!(written.get("error").is_none(), "{written}");
    assert_eq!(
        written["restartRequired"],
        serde_json::json!(false),
        "with nothing running there is nothing to restart"
    );
}
