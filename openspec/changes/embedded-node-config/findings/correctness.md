# Correctness review — embedded-node-config

Scope: correctness only (inputs that violate a claimed property, and
mutation-testing the dev-writer's specific claims about `nodeconfig.rs` and
`node.rs`'s `listen` handling). Security, readability and architecture are
other instances' rows.

## Claims verified by mutation

- **`node::Config.extra` data-loss trap.** Replaced `write_document`'s raw-JSON
  read-modify-write with `radicle::profile::Config::write` (the "obvious
  implementation" the module doc warns against). Result: exactly one test in
  `tests/node_config.rs` reddens —
  `a_key_this_build_does_not_know_survives_a_write` — and
  `an_unrelated_known_field_survives_a_write` stays green, matching the
  dev-writer's own comment that the second test does not discriminate against
  this mutation (`workers` is a real field on the crate's `Config`, so a
  round-trip carries it through regardless). Claim confirmed as stated.

- **The `@` rejection in `parse_external_addresses`.** Removed the `s.contains('@')`
  early return. Reddens both
  `nodeconfig::tests::an_external_address_with_a_node_id_is_refused_although_the_crate_accepts_it`
  (unit) and `each_address_spelling_is_accepted_in_its_own_field_and_refused_in_the_other`
  (integration, `tests/node_config.rs`). Confirms `radicle::node::Address::from_str`
  really does accept `<nid>@host:port` and that the module's own check is what
  is doing the rejecting, not the crate.

- **`guarded()` coverage of the five new entry points.** All of
  `radicle_node_get_config`, `radicle_node_set_config`, `radicle_node_list_seeded`,
  `radicle_node_seed`, `radicle_node_unseed` route through `guarded()` in
  `lib.rs`, and `tests/panic_guard.rs::the_node_config_and_seeding_entry_points_are_guarded_too`
  drives all six (including `set_config` with malformed JSON, wrong-kind JSON,
  and a 100KB field) plus a file-as-home input aimed at sqlite's open path.
  The three node-lifecycle entry points (`radicle_node_start/stop/status`) are
  separately covered by `the_node_entry_points_are_guarded_too`. Inventory is
  complete for this diff.

- **`restartRequired` ordering.** `RadicleImpl::getNodeConfig`/`setNodeConfig`
  in `radicle_impl.cpp` are thin pass-throughs to `NodeConfig::get()`/`set()`,
  which call straight into Rust; nothing on the C++ side computes or threads a
  `restartRequired` bool through either path any more, so there is no call site
  left where a caller could read the flag before or independent of the write.
  `tests/node_lifecycle.rs::a_configuration_change_while_a_node_runs_asks_for_a_restart_and_a_restart_clears_it`
  exercises the full three-state sequence (not-running / running-unchanged /
  running-changed / restarted) and specifically asserts the *write's own reply*
  carries `restartRequired: true`, not just a later `get`.

## New finding

- [ ] **`dev-writer`** — `radicle/rust-ffi/src/node.rs:504-523` (`start_inner`) — a
      mutation that decouples `config.listen` (the object handed to
      `radicle_node::runtime::Runtime::init` as the node's own configuration,
      i.e. what it reports/advertises about itself) from `listen` (the separate
      argument that actually reaches `Runtime::init`'s bind step) is invisible to
      every test in the crate.
      **Scenario:** with `config.listen` forced to `vec![]` while the `listen`
      argument passed to `Runtime::init` is left as the real configured value
      (so the reactor still binds the configured port), `getNodeConfig` and
      `getNodeStatus` both still look correct because `listening` in the
      `start` reply is built from `runtime.local_addrs` (what was actually
      bound), never from `config.listen`. Concretely: a home configured with
      `listen: ["127.0.0.1:PORT"]` starts, the reactor binds `PORT` (so
      `listening` in the reply names it, satisfying
      `a_configured_listen_address_is_what_the_node_binds`), but the `Config`
      object `Runtime::init` was actually given — which is what a node reads
      back and would advertise about itself when the two are allowed to
      diverge — says `listen: []`. The module's own doc comment states "**Both
      sites had to change together**, and changing one alone is the trap" but
      nothing pins that the *value* at both sites is the same one, only that
      each site independently produces a plausible-looking reply.
      **Measured:** cloned `config.listen` into a separate `listen_for_bind`
      before zeroing `config.listen`, then passed `listen_for_bind` (the
      original value) to `Runtime::init`'s `listen` argument while `config`
      (with `listen: []`) went to its `config` argument. `cargo test --test
      node_lifecycle` (all 16 tests, single-threaded) stayed fully green,
      including `a_configured_listen_address_is_what_the_node_binds` and
      `a_configuration_change_while_a_node_runs_asks_for_a_restart_and_a_restart_clears_it`.
      No test reads back what the *node's own `Config`* was actually
      constructed with — only what `getNodeConfig`/`config.json` says (the
      file on disk, untouched by this mutation) and what `runtime.local_addrs`
      reports (the bind side, also untouched by this mutation). This is a gap
      in observability for a value the module's own comment treats as
      load-bearing, not a proven live bug — nothing in the current crate
      diverges the two values on any path exercised here — but it means the
      claim "both sites had to change together" is asserted in a comment and
      not by any test, and a future refactor that reintroduces a discrepancy
      between them (e.g. reading `listen` from the file a second time, or a
      default in the wrong place) would ship silently.

## Other things checked, clean

- `parse_alias`, `parse_listen`, `parse_connect`, `parse_peers`,
  `reject_unknown_fields` — read against `radicle-0.25.1` source paths cited in
  the comments and against the unit tests; each validator delegates to the
  crate's own parser as claimed, and the boundary cases (32 vs 33 byte alias,
  `static`+empty-`connect` refusal with both-in-one-call acceptance) are
  exercised by both the unit and integration suites.
- `seeding.rs`'s `Block`-row filtering, `seed`/`unseed`'s
  change-count-vs-policy-shape reasoning, and the seed/unseed store-opening
  order (`Home::load`, not `Home::new` — refuses rather than creates on a
  missing home) all match their comments and are exercised in
  `tests/node_seeding.rs`.
- C++ mode gating (`nodeReadRefusal`/`nodeWriteRefusal` in `radicle_impl.cpp`):
  read allowed in `local`+`embedded`, refused only in `explore`; write allowed
  only in `embedded`. Matches `docs/writes.md`'s
  `getCapabilities().canWriteLocal` framing and is exercised for all four mode
  combinations in `radicle/tests/test_radicle_impl.cpp`.
- Ran the full `radicle-local-ffi` test suite (`cargo test`, no manifest flags)
  before and after every mutation above; it is green at HEAD with no
  uncommitted changes left in the worktree (`git diff` empty for
  `node.rs`/`nodeconfig.rs`).

Worktree used: `/home/fryorcraken/src/rad/radicle-logos-module/.claude/worktrees/rev-cfg-correctness`,
left in place for the runner to prune (not removed by this review).
