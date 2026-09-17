# Read and write the embedded node's configuration

## Why

M3's configuration panel is described as "backed by `node/config.rs`'s real
fields, nothing invented". Today none of those fields is reachable. The module
exposes five settings of its own — `mode`, `radHome`, `radSocket`, `gitPath`,
`remoteSeed` — and **nothing at all** from the node's own `config.json`:
`getSettings` returns exactly five keys and `setSetting` refuses every other,
by design and by spec. So the panel has nothing to render.

Worse, one node field is not merely unreadable but actively overridden.
`radicle/rust-ffi/src/node.rs` loads the home's `config.json`, then does
`config.listen = vec![]` before handing it to `Runtime::init`, and passes a
second empty `listen` as `init`'s own argument. A user who edits `config.json`
by hand today gets their listen addresses silently discarded — the one field the
panel most needs to change is the one field the start path refuses to honour.

Two of PLAN.md's three named gotchas are what this surface exists to remove, and
both are structural rather than cosmetic:

- **`rad init` plus `rad id update --allow` does not replicate a private repo.**
  Every other node must also seed the RID with scope `all`, or `rad sync` times
  out with "All seeds timed out". Without a seeding surface there is no way to do
  that from this module, and the failure the user sees names neither cause nor
  fix.
- **`listen: []` means outbound-only.** The node can fetch and announce; peers
  cannot fetch from it. That is the right default for a desktop behind NAT, and
  it is a real limitation that must be stated rather than implied away — which
  requires a field that can say it, and an opt-in that can change it.

This piece is the **read/write surface only**. It builds no panel. The split is
deliberate: the transport and the core contract are the part worth reviewing on
its own, exactly as `getEmbeddedIdentity` / `createEmbeddedIdentity` were
plumbed through `radicle_ui.rep` ahead of the wizard that calls them, so that the
wizard stayed a QML-only change. The same move here keeps the panel a QML-only
change.

## What Changes

- Adds a node-configuration read/write surface to the core module and to
  `radicle_ui.rep`, covering the fields the panel needs and **only** fields the
  `radicle` crate actually has: `alias`, `listen`, `externalAddresses`,
  `connect`, `peers` and the per-repo seeding policies.
- **Makes `listen` honoured rather than overridden.** The two hardcoded `vec![]`
  in `node.rs`'s start path become the configured value, with outbound-only
  remaining the default for a home that has never been configured.
- Adds the seeding surface — seed an RID with a scope, unseed it, list what is
  seeded — against the policies database, which is where per-repo policies live.
- Closes a spec gap in `module-settings` that PLAN.md's testing section names
  directly: the git path's **negative** cases are implemented and tested but
  unspecified, so the requirement as written could be satisfied by a resolver
  that ignores the setting.

Not covered, deliberately, and each for a reason rather than for scope's sake:

- **No UI.** No panel, no wizard, no QML component. The parallel piece
  `embedded-node-wizard` owns the one-time setup flow; this piece owns the
  durable config surface.

  The two specs do carry view requirements — that a panel renders from the reply
  rather than from what it submitted, that it states the inbound and
  restart-to-apply consequences, that it states both halves of the
  allow-is-not-enough rule. Those are stated here because they are properties of
  the contract rather than of any one screen, and because the sentence a view
  owes the user is the whole reason several of these fields exist. They are
  **not satisfied by this change** and no test in it covers them; the panel piece
  satisfies them. This follows `module-settings`, whose view requirements were
  written the same way.
- **No restart button.** PLAN.md calls it "not a nicety", and it is not — but it
  composes from the existing `stopNode` and `startNode` with no new transport, so
  it belongs to the panel that offers it.
- **No connections list, sync status or log tail.** Those are diagnostics, read
  from a running node rather than from its configuration, and none of them exists
  at any layer today.
- **No passphrase change.** It rewrites key material, which is the one operation
  in this area with no recovery; it belongs with identity, not configuration.
- **No `proxy`, `secret`, `network`, `log`, `relay`, `limits`, `workers`,
  `database` or `fetch`.** They exist on the crate's type, and nothing in the
  panel's description asks for them. A setting nobody renders is a validation
  surface nobody exercises.

## Capabilities

### New Capabilities

- `node-config`: The node's own `config.json` as a read/write surface — which
  fields are exposed, the JSON shapes they take, validation on write, the
  read-modify-write hazard that `extra` creates, and the rule that a
  configuration change takes effect at the next node start rather than on the
  running node.
- `node-seeding`: Seeding an RID with a scope, unseeding it, and listing what is
  seeded — against the policies database rather than `config.json`, and the
  distinction between this and `localListRepos`'s existing `"seeded"` scope,
  which is a question about storage contents rather than about policy.

### Modified Capabilities

- `module-settings`: The `gitPath` validation requirement gains the negative
  cases the implementation already enforces and the tests already cover — a
  real-but-not-git executable, a binary that exits non-zero, a relative path, and
  the absence of any fallback to `PATH` when a configured path fails. As written
  today the requirement names only a path that does not exist, which a resolver
  that ignored the setting entirely would still satisfy for the positive case.

## Impact

- **Core module.** `radicle/src/radicle_impl.{h,cpp}` gains the node-config and
  seeding methods; `radicle/src/radicle_ffi.h` and `radicle/src/local_reader.*`
  gain their FFI declarations.
- **Rust FFI.** A new module for reading and writing `config.json` through
  `radicle::profile::Config`, and one for the policies store. `node.rs`'s start
  path changes at the two `vec![]` sites so `listen` comes from the
  configuration.
- **Transport.** `radicle-ui/src/radicle_ui.rep` gains one slot per method, so
  the panel is a QML-only change afterwards.
- **No view changes.** Nothing in `radicle-ui/src/*.qml` is touched.
- `docs/PLAN.md` sheds the behaviour these specs now state.
- Unblocks the configuration panel, and removes the `rad seed` footgun that
  PLAN.md names as the reason the seeding fields exist.
