//! Reading and writing the node's own `config.json` — the file the node reads
//! when it is constructed, as opposed to `settings.json`, which describes the
//! module.
//!
//! ## The whole file is edited as JSON, and that is not an optimisation
//!
//! The obvious implementation is `Config::load` → change one field →
//! `Config::write`, and it **silently deletes data**. `node::Config.extra` is
//! `#[serde(flatten, skip_serializing)]` (`radicle-0.25.1/src/node/config.rs:658`):
//! every key this build does not understand is collected on deserialize and
//! never written back. Several known fields carry `skip_serializing_if` too, so
//! a value that happens to equal its default disappears as well. A user on a
//! newer `rad` would lose a field the first time a panel changed their alias,
//! and nothing would report it.
//!
//! So the file is read as a `serde_json::Value`, the individual members of its
//! `node` object are replaced in place, and the `Value` is written back. Every
//! key this module did not touch survives byte-for-byte, whether or not this
//! build has a field for it.
//!
//! **Validation is not given up in exchange.** The edited `Value` must
//! deserialize into `radicle::profile::Config` before anything is written, so a
//! shape the node cannot read never reaches disk — which is the same guarantee
//! the round-trip would have given, obtained without its data loss.
//!
//! ## Values are validated by the crate's own parsers
//!
//! Each field is checked by handing the submitted string to the type the crate
//! would have parsed it into anyway — `Alias::from_str`, `SocketAddr::from_str`,
//! `PeerAddr::from_str`, `Address::from_str`. Writing a length check or a regex
//! here instead would mean a value this module accepts and the node then
//! refuses at its next start: the deferred failure that validating on write
//! exists to prevent.

use std::collections::BTreeSet;
use std::str::FromStr;

use serde_json::{json, Map, Value};

/// The five fields this module exposes, and nothing else.
///
/// A `setNodeConfig` field outside this list is refused **by name**, rather
/// than ignored: silently dropping a field a caller believed it had set is how
/// a panel comes to display a value that was never stored.
const FIELDS: [&str; 5] = ["alias", "listen", "externalAddresses", "connect", "peers"];

/// The two members `getNodeConfig` derives rather than reads.
///
/// Named here so `setNodeConfig` can refuse them with a message saying what
/// they are, instead of the generic "not a field" refusal an unknown key gets.
/// A caller that round-trips a `getNodeConfig` reply straight back into
/// `setNodeConfig` will hit exactly these two, and the message is what tells it
/// why.
const DERIVED: [&str; 2] = ["inboundReachable", "restartRequired"];

/// Where the node's configuration lives under a Radicle home.
fn config_path(home: &str) -> std::path::PathBuf {
    std::path::Path::new(home).join("config.json")
}

/// The whole configuration file as JSON, or a message saying why not.
///
/// A missing file is distinguished from an unparseable one: the first means no
/// identity has been created here, which is a state a wizard resolves, and the
/// second means a file that needs looking at. Reporting both as "could not
/// read" would send a user to the wrong place.
fn load_document(home: &str) -> Result<Value, String> {
    if home.is_empty() {
        return Err("no Radicle home given".to_string());
    }
    let path = config_path(home);
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(format!(
                "there is no node configuration at {} — no identity has been \
                 created in this Radicle home yet.",
                path.display()
            ));
        }
        Err(e) => {
            return Err(format!(
                "could not read the node configuration at {}: {e}",
                path.display()
            ));
        }
    };

    serde_json::from_str(&text).map_err(|e| {
        format!(
            "the node configuration at {} is not valid JSON: {e}",
            path.display()
        )
    })
}

/// The `node` object inside the document, which is where every exposed field
/// lives.
fn node_object(doc: &Value, home: &str) -> Result<Map<String, Value>, String> {
    match doc.get("node") {
        Some(Value::Object(m)) => Ok(m.clone()),
        _ => Err(format!(
            "the node configuration at {} has no `node` section",
            config_path(home).display()
        )),
    }
}

/// Render the module's view of one `node` object.
///
/// Only the five exposed fields are read, and each is defaulted the way the
/// crate defaults it — an absent `listen` is an empty array, not a missing key,
/// because `#[serde(default)]` on the crate's field means a home that never set
/// it and one that set it to `[]` are the same node.
fn view(node: &Map<String, Value>) -> Value {
    let listen = array_of_strings(node.get("listen"));
    let inbound_reachable = !listen.is_empty();

    json!({
        "alias": node.get("alias").and_then(Value::as_str).unwrap_or_default(),
        "listen": listen,
        "externalAddresses": array_of_strings(node.get("externalAddresses")),
        "connect": array_of_strings(node.get("connect")),
        "peers": peers_discipline(node.get("peers")),
        "inboundReachable": inbound_reachable,
    })
}

/// Read an array-of-strings field, tolerating absence.
///
/// A non-array value reads as empty rather than as an error: it is a file this
/// module did not write, and a `getNodeConfig` that refused to render because
/// one field was odd would hide the four that are fine.
fn array_of_strings(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|e| e.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// The `peers` discipline as the module's surface spells it.
///
/// On disk `PeerConfig` is `#[serde(tag = "type")]`, so it is
/// `{"type":"static"}` — an object. The module exposes the bare string, because
/// a caller that saw the tagged form could try to put addresses in it, and the
/// addresses belong in `connect`. Absent or unrecognised reads as `dynamic`,
/// which is `PeerConfig`'s own `#[default]`.
fn peers_discipline(v: Option<&Value>) -> &'static str {
    match v.and_then(|p| p.get("type")).and_then(Value::as_str) {
        Some("static") => "static",
        _ => "dynamic",
    }
}

/// The configuration under `home`, as `getNodeConfig` reports it.
///
/// `restartRequired` is asked of [`crate::node::restart_required`] at the end,
/// rather than taken as a parameter. That keeps the ordering right by
/// construction on both entry points: the flag compares the file on disk
/// against what the running node was started with, so it has to be read *after*
/// a write, and a caller that had to remember which side of the write to read it
/// on would eventually read it on the wrong one.
///
/// It is not a second job for this function so much as the last step of the one
/// job — assembling the reply `getNodeConfig` documents, of which
/// `restartRequired` is a member.
pub fn get(home: &str) -> String {
    match get_inner(home) {
        Ok(v) => v,
        Err(e) => crate::local::error(e),
    }
}

fn get_inner(home: &str) -> Result<String, String> {
    let doc = load_document(home)?;
    let node = node_object(&doc, home)?;
    Ok(reply(&node, home))
}

/// The reply both entry points return: the five fields, `inboundReachable`, and
/// a freshly-read `restartRequired`.
fn reply(node: &Map<String, Value>, home: &str) -> String {
    let mut out = view(node);
    out["restartRequired"] = json!(crate::node::restart_required(home));
    out.to_string()
}

/// Apply `changes` — a JSON object naming a subset of the exposed fields — to
/// the configuration under `home`.
///
/// Returns the whole configuration in `get`'s shape, so a caller re-renders
/// from what was stored rather than from what it submitted.
///
/// `restartRequired` in the reply is read **after** the write, so a change made
/// while a node is running comes back with the banner already raised. That is
/// the ordering the spec requires and the reason neither entry point takes the
/// flag as a parameter: reading it on the wrong side of the write is a mistake
/// a caller should not be able to make.
pub fn set(home: &str, changes: &str) -> String {
    match set_inner(home, changes) {
        Ok(v) => v,
        Err(e) => crate::local::error(e),
    }
}

fn set_inner(home: &str, changes: &str) -> Result<String, String> {
    let changes: Value = serde_json::from_str(changes)
        .map_err(|e| format!("the configuration change is not valid JSON: {e}"))?;
    let Some(changes) = changes.as_object() else {
        return Err(
            "a configuration change must be a JSON object of field names to values".to_string(),
        );
    };

    // Everything is refused before anything is written. That ordering is the
    // whole of "a failed write leaves the previous configuration": the file is
    // not opened until every field has been validated.
    reject_unknown_fields(changes)?;

    let doc = load_document(home)?;
    let mut node = node_object(&doc, home)?;

    // Each field is validated against its own crate parser and, on success,
    // written into the `node` object in the spelling the crate uses.
    if let Some(v) = changes.get("alias") {
        node.insert("alias".to_string(), json!(parse_alias(v)?));
    }
    if let Some(v) = changes.get("listen") {
        node.insert("listen".to_string(), json!(parse_listen(v)?));
    }
    if let Some(v) = changes.get("externalAddresses") {
        node.insert(
            "externalAddresses".to_string(),
            json!(parse_external_addresses(v)?),
        );
    }
    if let Some(v) = changes.get("connect") {
        node.insert("connect".to_string(), json!(parse_connect(v)?));
    }
    if let Some(v) = changes.get("peers") {
        node.insert("peers".to_string(), json!({ "type": parse_peers(v)? }));
    }

    // `static` with nobody to connect to is refused against the configuration
    // the write would PRODUCE, not against the one on disk — so setting both in
    // one call is accepted, which is what distinguishes this check from one
    // that refuses `static` outright.
    if peers_discipline(node.get("peers")) == "static"
        && array_of_strings(node.get("connect")).is_empty()
    {
        return Err(
            "a `static` peer set with an empty `connect` configures a node to \
                    maintain connections to nobody: it would reach no peer and report \
                    no error. Set `connect` to at least one <nid>@<host>:<port> \
                    address in the same call, or leave `peers` as `dynamic`."
                .to_string(),
        );
    }

    let doc = replace_node(doc, node);
    validate_whole_document(&doc, home)?;
    write_document(home, &doc)?;

    // Read back from the document that was written, and take
    // `restartRequired` fresh — the file has just changed under whatever node
    // is running, which is the whole point of the flag.
    let node = node_object(&doc, home)?;
    Ok(reply(&node, home))
}

/// Refuse any field this module does not expose, naming it.
///
/// A derived member gets its own message: a caller that handed a
/// `getNodeConfig` reply straight back will hit `inboundReachable` or
/// `restartRequired` first, and "that is not a field" would be a true but
/// unhelpful thing to say about a key the module itself produced.
fn reject_unknown_fields(changes: &Map<String, Value>) -> Result<(), String> {
    let known: BTreeSet<&str> = FIELDS.into_iter().collect();
    for key in changes.keys() {
        if known.contains(key.as_str()) {
            continue;
        }
        if DERIVED.contains(&key.as_str()) {
            return Err(format!(
                "`{key}` is derived from the configuration rather than stored in \
                 it, so it cannot be set. It is reported by getNodeConfig and \
                 changes on its own."
            ));
        }
        return Err(format!(
            "`{key}` is not a node-configuration field this module exposes. The \
             fields are: {}.",
            FIELDS.join(", ")
        ));
    }
    Ok(())
}

/// The alias, validated by the crate's own rule.
///
/// `Alias::from_str` is non-empty, no whitespace or control character, and at
/// most 32 **bytes** (`radicle-0.25.1/src/node.rs:416-431`). Its `AliasError`
/// is passed through rather than paraphrased: re-stating the rule here is how a
/// module and a crate come to disagree about what is valid, and the byte limit
/// is the half most likely to be paraphrased wrongly as a character limit.
fn parse_alias(v: &Value) -> Result<String, String> {
    let s = v
        .as_str()
        .ok_or_else(|| "`alias` must be a string".to_string())?;
    radicle::node::Alias::from_str(s)
        .map(|a| a.to_string())
        .map_err(|e| format!("`{s}` is not a usable node alias: {e}"))
}

/// Listen addresses, which are `std::net::SocketAddr` and therefore stricter
/// than the other two address fields: an IP and a port, no DNS name.
///
/// That is the crate's own type for the field (`node/config.rs:603`), not a
/// choice made here — a hostname accepted at this layer would fail to parse at
/// the node's next start.
fn parse_listen(v: &Value) -> Result<Vec<String>, String> {
    strings(v, "listen")?
        .into_iter()
        .map(|s| {
            std::net::SocketAddr::from_str(&s)
                .map(|a| a.to_string())
                .map_err(|e| {
                    format!(
                        "`{s}` is not a usable listen address: {e}. A listen address \
                         is an IP address and a port, such as `0.0.0.0:8776` — not a \
                         host name, and not a node id."
                    )
                })
        })
        .collect()
}

/// This node's own public addresses: `<host>:<port>`, with **no** node id.
///
/// ## The `@` check is load-bearing, and the crate will not make it for us
///
/// `Address::from_str` splits on the last colon and parses the remainder as a
/// `HostName`, whose DNS arm accepts anything host-shaped — including
/// `z6MkrLMM…@seed.example.test`. Measured, not assumed: that string parses
/// **Ok** and round-trips unchanged. So a `connect`-shaped value in this field
/// would be stored, and the node would then advertise a public address nobody
/// can reach.
///
/// Removing the `@` rejection below leaves
/// `an_external_address_carrying_a_node_id_is_refused` as the only failing
/// test.
fn parse_external_addresses(v: &Value) -> Result<Vec<String>, String> {
    strings(v, "externalAddresses")?
        .into_iter()
        .map(|s| {
            if s.contains('@') {
                return Err(format!(
                    "`{s}` carries a node id, but `externalAddresses` takes this \
                     node's own public addresses as `<host>:<port>` with no node \
                     id. An address with a node id belongs in `connect`."
                ));
            }
            radicle::node::Address::from_str(&s)
                .map(|a| a.to_string())
                .map_err(|e| {
                    format!(
                        "`{s}` is not a usable external address: {e}. An external \
                         address is `<host>:<port>`, such as `node.example.com:8776`."
                    )
                })
        })
        .collect()
}

/// Peers to connect to and stay connected to: `<nid>@<host>:<port>`.
///
/// Validated through the same `PeerAddr` parse `ConnectAddress`'s
/// `serde_ext::string` performs, so a value accepted here is one the node can
/// load. Unlike the external-address case the crate's own error is sufficient:
/// it says the address must contain a peer key separated by `@`.
fn parse_connect(v: &Value) -> Result<Vec<String>, String> {
    strings(v, "connect")?
        .into_iter()
        .map(|s| {
            serde_json::from_value::<radicle::node::config::ConnectAddress>(Value::String(
                s.clone(),
            ))
            .map(|a| a.to_string())
            .map_err(|e| {
                format!(
                    "`{s}` is not a usable peer address: {e}. A `connect` entry is \
                     `<node id>@<host>:<port>`, such as \
                     `z6MkrLMM…@seed.example.com:8776`."
                )
            })
        })
        .collect()
}

/// The peer-set discipline: `static` or `dynamic`, and nothing else.
///
/// Matched explicitly rather than deserialized into `PeerConfig`, because
/// serde's error for an unknown tag names neither valid value and the spec
/// requires a refusal that names both. The array case is called out separately:
/// a caller reaching for `peers` with a list of addresses has the right idea in
/// the wrong field, and saying so is more use than "expected a string".
fn parse_peers(v: &Value) -> Result<&'static str, String> {
    if v.is_array() {
        return Err(
            "`peers` is a discipline, not a list of addresses: it is `static` \
                    or `dynamic`. The addresses to connect to go in `connect`."
                .to_string(),
        );
    }
    match v.as_str() {
        Some("static") => Ok("static"),
        Some("dynamic") => Ok("dynamic"),
        Some(other) => Err(format!(
            "`{other}` is not a peer-set discipline — it is `static` or `dynamic`."
        )),
        None => Err("`peers` must be the string `static` or `dynamic`.".to_string()),
    }
}

/// Read an array-of-strings argument, refusing anything else by name.
fn strings(v: &Value, field: &str) -> Result<Vec<String>, String> {
    let arr = v
        .as_array()
        .ok_or_else(|| format!("`{field}` must be an array of strings"))?;
    arr.iter()
        .map(|e| {
            e.as_str()
                .map(str::to_string)
                .ok_or_else(|| format!("every entry in `{field}` must be a string"))
        })
        .collect()
}

/// Put the edited `node` object back into the whole document.
fn replace_node(mut doc: Value, node: Map<String, Value>) -> Value {
    if let Some(obj) = doc.as_object_mut() {
        obj.insert("node".to_string(), Value::Object(node));
    }
    doc
}

/// Refuse to write a document the node could not load.
///
/// This is what the raw-JSON path gives up in exchange for preserving unknown
/// keys, bought back: a `Value` that does not deserialize into the crate's own
/// `Config` is one the node would reject at its next start, and the point of
/// validating on write is that such a value never reaches disk.
fn validate_whole_document(doc: &Value, home: &str) -> Result<(), String> {
    serde_json::from_value::<radicle::profile::Config>(doc.clone()).map_err(|e| {
        format!(
            "the change would leave {} unreadable as a node configuration: {e}",
            config_path(home).display()
        )
    })?;
    Ok(())
}

/// Write the document, via a temporary file in the same directory.
///
/// A crash or a full disk mid-write leaves the previous file intact rather than
/// a truncated one: `rename` within a directory is atomic, where writing over
/// the original in place is not. The same shape `SettingsStore::save` uses on
/// the C++ side, and for the same reason.
fn write_document(home: &str, doc: &Value) -> Result<(), String> {
    let path = config_path(home);
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::to_string_pretty(doc)
        .map_err(|e| format!("could not serialize the node configuration: {e}"))?;

    std::fs::write(&tmp, format!("{text}\n"))
        .map_err(|e| format!("could not write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("could not replace {}: {e}", path.display())
    })
}

/// A fingerprint of the configuration a node was started with.
///
/// Used by `node.rs` to answer `restartRequired` without holding the whole
/// document: the question is only whether the file has changed since, and a
/// string comparison answers it. Absent when the file could not be read, in
/// which case a later read that also fails compares equal and reports no
/// pending restart — the honest answer, since nothing is known to have changed.
pub(crate) fn fingerprint(home: &str) -> Option<String> {
    std::fs::read_to_string(config_path(home)).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peers_as_a_list_of_addresses_says_where_addresses_go() {
        let e = parse_peers(&json!(["z6MkrLMM@host:8776"])).unwrap_err();
        assert!(e.contains("connect"), "{e}");
    }

    #[test]
    fn an_unknown_peer_discipline_names_both_valid_ones() {
        let e = parse_peers(&json!("manual")).unwrap_err();
        assert!(e.contains("static") && e.contains("dynamic"), "{e}");
    }

    #[test]
    fn an_alias_is_measured_in_bytes_not_characters() {
        // Nine characters, 36 bytes: accepted by any character-counting check
        // and refused by the crate's own byte limit. This is the case the spec
        // singles out, because it is the one a paraphrased rule gets wrong.
        let nine_chars = "\u{1F600}".repeat(9);
        assert_eq!(nine_chars.chars().count(), 9);
        assert!(nine_chars.len() > 32);
        assert!(parse_alias(&json!(nine_chars)).is_err());
        // 32 bytes exactly is the boundary, and it is accepted.
        assert!(parse_alias(&json!("x".repeat(32))).is_ok());
        assert!(parse_alias(&json!("x".repeat(33))).is_err());
    }

    #[test]
    fn a_listen_address_must_be_an_ip_and_a_port() {
        // The crate's field is `Vec<SocketAddr>`, so a host name that would be
        // fine in `externalAddresses` is not fine here. A module that validated
        // both the same way would accept a value the node cannot load.
        assert!(parse_listen(&json!(["0.0.0.0:8776"])).is_ok());
        assert!(parse_listen(&json!(["localhost:8776"])).is_err());
    }

    #[test]
    fn an_external_address_with_a_node_id_is_refused_although_the_crate_accepts_it() {
        // The control: the crate's own parser says yes to this string, so the
        // refusal below is this module's check and not the crate's.
        let with_id = "z6MkrLMMsiPWUcNPHcRajuMi9mDfYckSoJyPwwnknocNYPm7@seed.example.test:8776";
        assert!(radicle::node::Address::from_str(with_id).is_ok());

        let e = parse_external_addresses(&json!([with_id])).unwrap_err();
        assert!(e.contains(with_id), "the refusal must name the value: {e}");
        assert!(e.contains("connect"), "{e}");
    }

    #[test]
    fn a_connect_address_without_a_node_id_is_refused() {
        let e = parse_connect(&json!(["seed.example.test:8776"])).unwrap_err();
        assert!(e.contains("seed.example.test:8776"), "{e}");
    }

    #[test]
    fn a_derived_member_is_refused_by_a_message_saying_it_is_derived() {
        let mut m = Map::new();
        m.insert("restartRequired".to_string(), json!(true));
        let e = reject_unknown_fields(&m).unwrap_err();
        assert!(e.contains("restartRequired"), "{e}");
        assert!(e.contains("derived"), "{e}");
    }

    #[test]
    fn a_field_the_module_does_not_expose_is_refused_by_name() {
        let mut m = Map::new();
        m.insert("workers".to_string(), json!(4));
        let e = reject_unknown_fields(&m).unwrap_err();
        assert!(e.contains("workers"), "{e}");
    }
}
