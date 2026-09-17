# Security review — `embedded-node-config`

Scope: SECURITY only (mode gating, path provenance, input validation on the
write path, the `extra`-field round-trip, `guarded()` coverage, and
`policies.db` writes), per dispatch. Correctness, readability and architecture
are covered by other instances.

## Summary of what was checked and found clean

- **Mode gating is a single choke point, applied uniformly.** All five new
  methods (`getNodeConfig`, `setNodeConfig`, `listSeeded`, `seedRepo`,
  `unseedRepo`) call `nodeReadRefusal`/`nodeWriteRefusal`
  (`radicle/src/radicle_impl.cpp:694-819`) as their first statement, with no
  alternate call path to `m_nodeConfig`. Verified the truth table matches the
  spec: `explore` refuses both read and write on all five; `local` allows read,
  refuses write on all five; `embedded` allows both. C++ test coverage
  (`radicle/tests/test_radicle_impl.cpp:1542-1664`) exercises all five methods
  together in each of the three modes, including negative assertions that the
  wrong refusal sentence is absent (e.g. `local`'s refusal must not read as
  `explore`'s, and vice versa) — this is exactly the shape that would catch a
  per-method regression rather than a single happy-path check.
- **Path provenance holds.** None of the five new Rust entry points
  (`radicle_node_get_config`, `radicle_node_set_config`,
  `radicle_node_list_seeded`, `radicle_node_seed`, `radicle_node_unseed`) is
  reachable from `radicle_ui.rep` — `NodeConfig`'s `home` is a constructor
  argument only (`node_config.h:52-55`), resolved once by `RadicleImpl` from
  `m_local.home()`, itself derived from `storeForSettings()`'s mode-keyed
  resolution. No slot in `radicle_ui.rep` takes a home, a path, or anything a
  view could use to redirect a write — confirmed by reading the full `.rep`
  file, not just the five new lines.
- **Input validation on the write path is delegated to the crate's own
  parsers**, not hand-rolled, for every field: `Alias::from_str` (alias, 32-byte
  cap measured in bytes, confirmed against `radicle-0.25.1/src/node.rs:416-431`
  — non-empty, no whitespace/control char, byte length not char count),
  `SocketAddr::from_str` (listen), `Address::from_str` plus a hand-written `@`
  rejection (externalAddresses), and `ConnectAddress`'s own deserializer
  (connect). The one hand-written check — rejecting `@` in
  `externalAddresses` — is justified and tested
  (`nodeconfig.rs:537-546`): `Address::from_str` genuinely accepts a
  nid-carrying string and round-trips it, so the module's own rejection is the
  only thing standing between a `connect`-shaped value and being stored as an
  external address. Port range is enforced structurally by the crate's
  `Address`/`SocketAddr` types (`u16`), not by a length check that could be got
  wrong here.
- **`policies.db` writes go through parameter binding, not string
  concatenation.** `seeding.rs`'s `seed`/`unseed` call
  `radicle::node::policy::store::StoreWriter::seed`/`unseed`, which bind `?1`/
  `?2` placeholders (`radicle-0.25.1/src/node/policy/store.rs:136-149`). The
  module code builds no SQL itself. `parse_rid` uses `RepoId::from_urn`, the
  crate's own parser, not a regex or manual check — a malformed RID is
  refused before the store is even opened (`seeding.rs:130-135`).
- **The `extra`-field round-trip is handled correctly, and the design note is
  accurate.** Confirmed `radicle::profile::Config`'s (`node::Config`'s) `extra`
  field is `#[serde(flatten, skip_serializing)]`
  (`radicle-0.25.1/src/node/config.rs:657-659`), and several other fields carry
  `skip_serializing_if` (`user_agent`, `proxy`, `database`, `fetch`, `secret`).
  A naive load-into-struct-then-save would silently drop all of these.
  `nodeconfig.rs` avoids this by editing the raw `serde_json::Value` in place
  (`node_object`/`replace_node`) and only ever inserting the five keys it
  knows about, leaving every other key — known-but-unexposed or
  unknown-to-this-build — untouched. `validate_whole_document` round-trips the
  edited `Value` through `radicle::profile::Config` only to confirm it still
  parses, and is discarded rather than written back, so validation cannot
  reintroduce the data-loss the raw-JSON approach exists to avoid. Covered by
  `tests/node_config.rs::a_key_this_build_does_not_know_survives_a_write` and
  `::an_unrelated_known_field_survives_a_write`.
- **`guarded()` covers all five new entry points**, and `panic_guard.rs`'s
  `the_node_config_and_seeding_entry_points_are_guarded_too` test exercises
  each with pathological inputs: a missing home, a traversal-shaped home, NULL
  everywhere, a home that is a file (which drives `policies.db`'s open path
  into a real OS-level failure rather than a clean early return), malformed
  and wrong-kind JSON for `set_config`, and an oversized field value. Ran the
  full `cargo test` suite in this worktree — all 23 unit tests plus every
  integration test file, including `panic_guard.rs`'s 8 tests, pass.
- **Ordering is fail-closed.** `set_inner` in `nodeconfig.rs` validates every
  named field (including the cross-field `static`-with-empty-`connect` check,
  evaluated against the post-merge state so it can't be bypassed by omission
  order) before `load_document`'s result is ever mutated or
  `write_document` is called; a refused call touches the file not at all
  (confirmed by `write_document`'s temp-file-then-rename shape and the
  `a_refused_write_leaves_the_file_byte_for_byte` test).

## Findings

- [ ] **`dev-writer`** — `radicle/rust-ffi/src/nodeconfig.rs:429-440` (the
      `strings()` helper used by `parse_listen`/`parse_external_addresses`/
      `parse_connect`) — no upper bound on array length or per-entry string
      length before each entry is handed to the crate's parser.
      **Scenario:** a view (or anything upstream that can reach `setNodeConfig`
      with attacker-influenced input, e.g. a future feature that seeds
      `connect` from a fetched peer list) submits `listen`/`externalAddresses`/
      `connect` with a very large array (hundreds of thousands of entries) or
      an individual entry that is itself very large. Every entry still goes
      through validation and is very likely rejected by the crate's parser,
      but the module does the parsing work and builds/returns the full JSON
      reply before returning, so there is no early, cheap rejection of
      "this array is absurd" the way there is for other resource limits in
      this codebase (e.g. the FFI layer's use of saturating arithmetic against
      oversized pagination values). This is a local-process resource
      concern rather than a network-facing one today — the argument
      originates from the local QML view via QtRO, not from seed/remote data —
      so severity is low. Flagged because the write surface is new and its
      only caller today is trusted, but nothing in the code enforces that
      assumption structurally, and the module's own stated posture elsewhere
      (validate before touching anything expensive) does not extend to
      "validate that the request is a reasonable size" here.
      **Measured:** read `strings()` (`nodeconfig.rs:429-440`) and its three
      callers; no `.len()` check against the input `Vec` or its elements
      exists anywhere in `nodeconfig.rs` before or during validation.

## Areas explicitly clean, not just untested

Mode gating, path provenance, `policies.db` parameter binding, the `extra`
round-trip, and `guarded()` coverage are all sound with concrete evidence
above — none of these produced a finding, and none is merely "looks fine",
each was checked against the actual crate source, the actual test files, and
a real `cargo test` run in this worktree.

## Worktree

Worked from `/home/fryorcraken/src/rad/radicle-logos-module/.claude/worktrees/rev-cfg-security`
via absolute paths and no `EnterWorktree` call (dispatch instructed not to
call it). Ready for the runner to prune — no `git worktree remove` performed
here.
