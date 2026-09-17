## Stages

- [x] spec — `spec-writer`
- [x] design + code — `dev-writer`
- [ ] tests — `tester`
- [ ] review: correctness — `code-reviewer`
- [ ] review: security — `code-reviewer`
- [x] review: readability — `code-reviewer`
- [x] review: architecture — `code-reviewer`
- [ ] review: spec-test — `spec-test-reviewer`
- [x] review: design — `design-reviewer`
- [ ] findings all ticked, `findings/` deleted — `closer`
- [ ] `openspec validate --strict`, then `archive` — `closer`
- [ ] CI green, title/body checked, PR merged — `closer`

## Implementation

<!-- The dev-writer owns this section. -->

The spec is the contract; this is the ordering that built it. Three new QML
files and two new test files, no change to `radicle/`, `radicle_ui.rep` or the
Rust staticlib — every slot the flow drives was already exposed.

### The state

- [x] `SetupFlow.qml` — a non-visual `QtObject` holding the step in force, the
      four preflight findings, the blocking rules, the staleness epoch and the
      calls. Separate from the view for the reason `NavState` and `SourceState`
      are: the behaviour is otherwise untestable without a window.
- [x] The step in force is an **index** into one ordered `steps` list, so
      "advance moves to the next and never skips" holds by construction rather
      than per-transition. `canGoBack` and the confirm clamp fall out of it.
- [x] Four findings held as four values, never one `preflightPassed` verdict —
      the collapse would block identity creation on a missing `git`, which
      spawns no `git`.
- [x] `canCreateIdentity` / `canStartNode` read findings directly, so a backend
      reporting a finding as passing lifts the block with nothing else changed.
- [x] One `epoch`, incremented by every step change, captured by every call,
      checked in every reply. One counter rather than the four hand-written
      per-view guards CLAUDE.md records dropping a different capture each.
- [x] Every displayed fact is set from a reply payload, never from a call
      having been issued.

### The view

- [x] `SetupWizard.qml` — renders the six steps, owning no state beyond the
      fields a user types into. Injected call functions, the `SettingsPanel`
      pattern.
- [x] The mode step **reuses `ModePicker`**, whose `embedded` blurb already
      states the separate-identity consequence. One copy of that wording.
- [x] The identity step states **both halves** of the passphrase trade, at the
      control, before it is touched, and keeps stating them when it is turned
      off. The switch arrives checked.
- [x] The alias is submitted as typed — no second copy of the crate's rule.
- [x] The network step states the outbound-only default, its consequence, and
      that enabling inbound is **not available here**. No inbound control.
- [x] The start step withholds its control while a start is outstanding, and
      displays an empty `listening` rather than omitting it.
- [x] `CopyableCommand.qml` — the confirm step's `rad id update --allow <DID>`
      line, carrying the reported DID, with the copy **verified** by a
      round trip through a separate paste editor.

### Tests

- [x] `tst_setup_wizard.qml` — 34 assertions against `SetupFlow`: order,
      findings, blocking, refusals, start semantics, staleness.
- [x] `tst_setup_wizard_view.qml` — 14 assertions against the rendered screen:
      the three consequence statements, the seed list, the empty-listening
      display, and the clipboard round trip.
- [x] Fakes answer from their own arguments or from a scenario that differs in
      the value the assertion reads back. Two preflight scenarios fail
      **different** findings; two refusals are **different** sentences; the two
      confirm DIDs differ and absence of the first is asserted.
- [x] Both guards proven to fail without their code: neutering `isCurrent()`
      reddens the late-reply test while its positive twin stays green, and
      deleting `clip.copy()` reddens the clipboard test.
- [x] Full suite green — `sh radicle-ui/tests/run-qml-tests.sh`, zero failures.

### Documentation

- [x] `design.md` — the Decisions above with what was rejected and why, and the
      two PLAN.md reasoning passages moved in (passphrase-at-start, and where
      the inbound opt-in went).
- [x] `docs/PLAN.md` — the wizard's step list struck with a pointer to
      `embedded-setup`; the "QML only" claim corrected; the passphrase paragraph
      shed to `design.md`; the new-identity clause closed out. The `listen: []`
      paragraph and the panel's `node/config.rs` paragraph deliberately **not**
      touched — they belong to the parallel `embedded-node-config` piece.

### Not done, deliberately

- [ ] **No entry point is wired into `Main.qml`.** The spec defines the flow's
      behaviour, not where it is reached from, and the surrounding surface is
      the panel change's. Marked `NO SPEC:` in `SetupWizard.qml` rather than
      decided here — see `design.md`'s Open questions.
