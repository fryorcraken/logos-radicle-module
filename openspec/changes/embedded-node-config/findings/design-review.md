# Design review — `embedded-node-config`

Scope: did the code take the decisions `design.md` records, and were the
decisions worth recording actually recorded. Cross-checked against
`radicle/rust-ffi/src/{nodeconfig,node,seeding}.rs`, `radicle/src/{node_config.h,radicle_impl.cpp}`,
`docs/PLAN.md` (both the branch's copy and `origin/main`'s), and
`openspec/changes/embedded-node-config/{design.md,proposal.md,specs/module-settings/spec.md}`.

## Decisions taken as recorded

Each of the following was checked against the actual code, not just the prose,
and the code matches what `design.md` says was chosen:

- **Raw-JSON edit of `config.json`, validated by round-trip into `Config`
  before write** — `nodeconfig.rs::set_inner` reads via `load_document`,
  mutates the `Map`, calls `validate_whole_document` (a
  `serde_json::from_value::<radicle::profile::Config>` check) before
  `write_document`. The `node::Config.extra` citation (`node/config.rs:658`,
  `#[serde(flatten, skip_serializing)]`) is accurate — verified directly
  against the vendored crate source.
- **Validation via the crate's own parsers**, one per field, including the
  `@`-rejection in `parse_external_addresses` that the crate's own
  `Address::from_str` would otherwise accept — matches
  `nodeconfig.rs:355-376`, and the control test
  `an_external_address_with_a_node_id_is_refused_although_the_crate_accepts_it`
  is present and asserts exactly the control design.md describes.
- **`peers` matched explicitly, `static`+empty-`connect` refused against the
  configuration the write would produce** — `nodeconfig.rs:243-261` matches;
  the check reads `node.get("peers")`/`node.get("connect")` from the map
  already updated by this call, not the one loaded from disk.
- **Two-store split** — `seeding.rs`'s module doc and `open()` cite
  `Home::policies_mut()` (`profile.rs:719`) and `store.rs:136-147`/`:320`
  exactly as design.md does, and `list` filters `policy.is_allow()`, `seed`
  omits the change-count boolean while `unseed` reports it. All matches.
- **`listSeeded` reports policies, not storage** — `node_config.h`'s doc
  comment and `seeding.rs`'s module doc both state the distinction from
  `LocalReader::listRepos("seeded", …)` explicitly; nothing in `seeding.rs`
  touches storage.
- **`listen` honoured at both sites** — `node.rs:508-585` carries the comment
  trail design.md paraphrases, `config.listen` and `Runtime::init`'s own
  `listen` argument both now use `config.listen.clone()`, and `listening` in
  the reply is built from `runtime.local_addrs` (`node.rs:585`).
- **`restartRequired` computed inside `get`/`set`, not passed in** —
  `nodeconfig.rs::reply()` calls `crate::node::restart_required(home)` fresh
  on every call, and `node.rs::restart_required` compares
  `Node.started_with` (captured at `Runtime::init`, `node.rs:611`) against
  `nodeconfig::fingerprint(home)`. Matches the "read after the write" ordering
  design.md describes as the fix for the rejected bool-parameter draft.
- **`NodeConfig` as a new class**, bound to a home via constructor argument
  only, no socket member — `node_config.h`'s doc comment states the same
  three rejected candidates and reasons design.md gives, close to verbatim.
- **`rebuildFromSettings()`**, and `setDependenciesForTest` deliberately not
  calling it — both present in `radicle_impl.cpp`, comment at the call site
  matches design.md's stated reason.
- **Mode gating in C++, read/write split** — `radicle_impl.cpp`'s
  `nodeReadRefusal`/`nodeWriteRefusal` implement exactly the table in
  design.md: `explore` refuses both, `local` reads but not writes, `embedded`
  does both. All five methods (`getNodeConfig`, `setNodeConfig`, `listSeeded`,
  `seedRepo`, `unseedRepo`) go through one of the two refusal functions.
- **Three `NO SPEC:` markers** — present exactly as described, at
  `node_config.rs:326`, `:346`, and `node_seeding.rs:143`, matching the three
  bullets under "Unspecified behaviour chosen here."

No place was found where the code contradicts a recorded decision, and no
decision was found only partially applied at a second call site.

## Gap: the wizard/panel scope decision is not recorded anywhere

- [ ] **`dev-writer`** — `design.md` has no entry for why inbound-toggle
      configuration lives in this change's `node-config` surface (the `listen`
      field) rather than in the wizard, even though the wizard is exactly
      where PLAN.md's "network" step describes deciding it
      (`docs/PLAN.md`'s wizard section: "network (inbound off by default,
      preferred seeds prefilled)").
      **Scenario:** a future reader designing the wizard finds `listen` already
      exposed through `node-config`, sees `module-settings` locked to five keys
      (`mode`, `gitPath`, `radSocket`, `remoteSeed`, `radHome` —
      `specs/module-settings/spec.md`), and has no note explaining that the
      wizard *could not* have persisted an inbound toggle itself, because
      `module-settings` has nowhere to put it. Without that note they either
      re-litigate why the toggle isn't a sixth settings key, or add one
      redundantly.
      **Measured:** `design.md` and `proposal.md` were grepped for `inbound`
      and `module-settings`; the only two hits are `proposal.md`'s summary line
      ("that it states the inbound and …") and its `module-settings` gitPath
      note — neither explains the scope choice. The archived
      `m3-embedded-node-foundations` `design.md` also does not contain it
      (checked for "five"/"locked"/"keys"). The reasoning exists only in this
      review's own derivation from the spec file, which is exactly the kind of
      choice this role exists to catch before it is lost.

## Everything else

`docs/PLAN.md`'s diff against `origin/main` was checked line by line against
the dev-writer's report and it holds: the seeding gotcha now says "built" and
names `listSeeded`/`seedRepo`/`unseedRepo`; the panel paragraph lost
"persistent peers" (now "the peers to stay connected to") and the
"`node/config.rs`'s real fields" phrasing (now "real fields"); the two
correction paragraphs (seeding store, persistent-peers) are gone from PLAN.md
and appear, as one copy each, in `design.md`'s "Seeding writes `policies.db`,
not `config.json`" section; the `listen: []` paragraph is struck through and
points at `design.md`. No sentence was found half-corrected, and no reasoning
was found duplicated in both files.

`docs/M3-embedded-node-plan.md` was left untouched by this piece, and that
reads as a correct call: this step's territory (`node-config`/`node-seeding`,
Phase 2 step 4's data half) is not one of the constraints that document tracks
line-by-line against crate source (git-as-dependency, NID/DID isolation,
listen default, socket-name collision) — those remain exactly as they were,
still open or still pointing at `rust-ffi.md`. Nothing this change learned
belongs there instead.

Every Decisions entry that describes a guard also carries mutation evidence
(the unknown-key-preservation test, the two-site `listen` fix, the `@`-check
control) — this repo's own bar for a guard entry is met throughout.

## Summary

One gap, otherwise clean: the code takes every decision `design.md` records,
faithfully and without partial application, and `design.md`'s cross-checkable
citations (crate line numbers, test names) were spot-verified against the
vendored source and found accurate. The single missing entry is the
wizard-vs-panel scope decision for inbound configuration — worth recording
before the wizard piece is written, since that piece is the one that will
otherwise re-derive or contradict it.
