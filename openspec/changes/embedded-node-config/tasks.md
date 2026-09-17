# Tasks

## Stages

- [x] spec — `spec-writer`
- [x] design + code — `dev-writer`
- [ ] tests — `tester`
- [x] review: correctness — `code-reviewer`
- [x] review: security — `code-reviewer`
- [x] review: readability — `code-reviewer`
- [x] review: architecture — `code-reviewer`
- [ ] review: spec-test — `spec-test-reviewer`
- [x] review: design — `design-reviewer`
- [ ] findings all ticked, `findings/` deleted — `closer`
- [ ] `openspec validate --strict`, then `archive` — `closer`
- [ ] CI green, title/body checked, PR merged — `closer`

## Implementation

### The node's `config.json` — `node-config`

- [x] `radicle/rust-ffi/src/nodeconfig.rs`: read and write the five exposed
      fields, editing the file's JSON in place rather than round-tripping
      through `radicle::profile::Config`, and validating the edited document
      before writing it
- [x] Validate each field with the crate's own parser — `Alias::from_str`,
      `SocketAddr::from_str`, `ConnectAddress`'s deserializer,
      `Address::from_str` — so a value accepted here is one the node can load
- [x] Reject a node id in `externalAddresses` explicitly: the crate's parser
      accepts one (measured), so this check is ours and is load-bearing
- [x] Refuse a `static` peer set with an empty `connect`, against the
      configuration the write would produce rather than the one on disk
- [x] Derive `inboundReachable` and `restartRequired`, and refuse both by name
      on write with a message saying they are derived
- [x] Write through a temporary file and `rename`, so a failed write leaves the
      previous configuration rather than a truncated one

### Seeding policies — `node-seeding`

- [x] `radicle/rust-ffi/src/seeding.rs`: list, seed and unseed against
      `<home>/node/policies.db` through `Home::policies_mut()`
- [x] Filter block rows out of `listSeeded` — the store keeps allow and block in
      one table, and a blocked RID is not a seeded one
- [x] Validate the RID and the scope before opening the store, so a malformed
      value writes nothing
- [x] Report `{"unseeded":bool}` from the `DELETE`'s change count, and delete
      nothing from storage

### The `listen` override — `node-config`

- [x] `radicle/rust-ffi/src/node.rs`: replace both `vec![]` sites with the
      configured value — `config.listen` and `Runtime::init`'s own argument
- [x] Record the configuration a node was started with on `Node`, and answer
      `restart_required` by comparing against it
- [x] Correct the now-false "binds no TCP port" claims in `node.rs`,
      `radicle_impl.h` and `radicle_ffi.h`

### The module boundary

- [x] `radicle/src/radicle_ffi.h` + `radicle/rust-ffi/src/lib.rs`: five
      `extern "C"` entry points, each through `guarded`
- [x] `radicle/src/node_config.{h,cpp}`: a new class bound to one home, with its
      own `take()` — none of `LocalReader`, `LocalWriter` or `EmbeddedNode` fits
- [x] `radicle/src/radicle_impl.{h,cpp}`: the five public methods, gated by mode
      as a read/write split
- [x] Extract `rebuildFromSettings()` rather than writing the repoint out by
      hand a third time
- [x] `radicle/CMakeLists.txt` and `radicle/tests/CMakeLists.txt`: register the
      new source pair
- [x] `radicle-ui/src/radicle_ui.rep` and `radicle_ui_backend.{h,cpp}`: five
      slots, forwarded without a capability refresh — a configuration change does
      not alter what the module can do

### Tests written alongside the code

- [x] `radicle/rust-ffi/tests/node_config.rs` — 14 tests, including the
      unknown-key preservation test that discriminates against the round-trip
- [x] `radicle/rust-ffi/tests/node_seeding.rs` — 12 tests against a real
      `policies.db`, including both directions of the policy/storage disagreement
- [x] `radicle/rust-ffi/tests/node_lifecycle.rs` — three added: a configured
      port actually bound, a collision failing the start, and the three-state
      `restartRequired` sequence
- [x] `radicle/rust-ffi/tests/panic_guard.rs` — the five new entry points added
      to the inventory
- [x] `radicle/tests/test_radicle_impl.cpp` — five gating tests, each asserting a
      decision this layer makes

### Documentation

- [x] `openspec/changes/embedded-node-config/design.md` — the Decisions section,
      carrying the reasoning migrated out of `docs/PLAN.md`
- [x] `docs/PLAN.md` — shed the `listen: []` reasoning, the seeding-store
      correction and the "persistent peers" correction, each now in `design.md`

### Not done here, deliberately

- [ ] ~~The `module-settings` `gitPath` delta~~ — **satisfied by construction.**
      The four negative cases the delta adds are already implemented in
      `env.rs::git_probe` and already covered by `tests/git_preflight.rs`
      (`a_configured_path_that_does_not_exist_is_refused_and_named`,
      `a_configured_path_that_is_not_git_is_rejected_by_the_version_check`,
      `a_binary_that_exits_nonzero_is_refused`,
      `a_relative_git_path_is_refused_rather_than_resolved_two_different_ways`).
      The delta closes a **spec** gap, not a code gap; the `tester` should find
      these green, and that is the expected outcome rather than a missing test.
- [ ] ~~The two view requirements~~ — a panel satisfies them, and no test in this
      change covers them. `proposal.md` says so; they are here so nobody reads
      their absence as an oversight.
