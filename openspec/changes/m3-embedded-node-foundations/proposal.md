# Capture the shipped M3 foundations as specs

## Why

M3's first four increments — the Phase 0 spike, Phase 1's settings store and
mode selection, and Phase 2's identity creation and embedded home — shipped
before this repo adopted the spec-driven flow. Their reasoning is unusually well
preserved, in long commit messages and in `docs/M3-embedded-node-plan.md`, but
**no artifact says what the system must do** as distinct from why it was built
that way. That gap has a cost now rather than later: Phase 2 step 3 (the node
runtime) and step 4 (the wizard) are the next changes, and both build directly
on this surface. Step 4 in particular is described as "QML only" precisely
because the module methods already exist — which is a claim about a contract
nobody has written down.

This is therefore a **retrospective capture, not new behaviour**. It adds no
code and changes no behaviour; it writes the behaviour contract for what is
already running, against the code as it exists.

Two things make this worth doing as a change rather than as documentation:

- **The specs are what the next change is reviewed against.** Without them,
  step 3's reviewer has nothing to check the node lifecycle's error shapes
  against except the implementation it is reviewing.
- **Writing a spec against shipped code finds things.** Where the code answers
  a question no requirement asked, that is either a requirement nobody stated or
  behaviour nobody decided. Both are worth surfacing before a change builds on
  them.

## What Changes

- Adds four capability specs describing behaviour that is **already
  implemented**, derived from the code and its tests rather than from the plan
  document's intentions.
- Adds a `design.md` recording the decisions these increments took, migrated
  from the commit messages and from `docs/M3-embedded-node-plan.md` so that the
  reasoning lives in one place the flow knows how to find.
- Prunes `docs/PLAN.md` of behaviour these specs now state, per the flow's
  shedding rule.
- **No production code changes.** Any defect found while specifying is reported,
  not fixed — fixing it here would put a behaviour change inside a change whose
  whole premise is that it has none.

Not covered, deliberately: the node runtime (`radicle-node` is not yet a
dependency) and the wizard. Those are the next changes and their behaviour does
not exist to be specified.

## Capabilities

### New Capabilities

- `module-settings`: The module-owned settings store — what persists, where it
  lives, how a value is validated on write rather than on use, and the
  `{"error":"..."}` shape on rejection. Includes `getSettings` / `setSetting`
  and the per-Basecamp-profile separation the store's location provides.
- `source-modes`: The three modes (`explore`, `local`, `embedded`), what each
  resolves, which are startable, and the rule that mode and source are one
  question rather than two. Includes `getCapabilities`' reporting of the active
  mode and what a view may derive from it.
- `node-paths`: Resolution of the Radicle home and the control socket,
  independently of one another, and the 108-byte `sun_path` bound that
  constrains the socket alone. Includes the requirement that an over-long socket
  path fails with a message naming the path, its length and the limit.
- `embedded-identity`: Creating a Radicle identity without `rad auth` —
  `getEmbeddedIdentity` and `createEmbeddedIdentity`, the refusal to overwrite
  an occupied home, the passphrase's effect on whether the profile can sign, and
  the structural guarantee that the embedded home is never the user's own.

### Modified Capabilities

None. There are no existing specs; this change creates the first four.

## Impact

- **Specs only.** No source file changes.
- Affected surface, for the specs to describe:
  `radicle/src/settings_store.{h,cpp}`, `radicle/src/local_store.{h,cpp}`,
  `radicle/src/radicle_impl.{h,cpp}`, `radicle/rust-ffi/src/env.rs`,
  `radicle/rust-ffi/src/profileinit.rs`, and on the view side
  `SourceState.qml`, `ModePicker.qml`, `SettingsPanel.qml`, `NodeIdentity.qml`.
- `docs/PLAN.md` sheds the behaviour now specified.
- Unblocks Phase 2 step 3 and step 4 by giving both a contract to build and
  review against.
