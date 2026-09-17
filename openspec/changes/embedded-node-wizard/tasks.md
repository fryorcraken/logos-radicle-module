## Stages

- [x] spec — `spec-writer`
- [x] design + code — `dev-writer`
- [ ] tests — `tester`
- [x] review: correctness — `code-reviewer`
- [x] review: security — `code-reviewer`
- [x] review: readability — `code-reviewer`
- [x] review: architecture — `code-reviewer`
- [x] review: spec-test — `spec-test-reviewer`
- [x] review: design — `design-reviewer`
- [ ] findings all ticked, `findings/` deleted — `closer`
- [ ] `openspec validate --strict`, then `archive` — `closer`
- [ ] CI green, title/body checked, PR merged — `closer`

**The spec was reopened after the ticked rows above were ticked.** A design pass
found that the screen a user reaches on picking Embedded has no surface at all —
the dead-end panel was deleted by the core-module change that made Embedded
startable, and nothing replaced it — so this change gained a capability
(`embedded-state`) and re-keyed one in `source-modes`. The `dev-writer` and
every reviewer row above was ticked against a spec that did not contain them.
**The runner owns re-dispatching those stages**; `spec-writer` flips only its own
row, which is why they are left ticked rather than silently reset here.

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
- [x] The **embedded step is a confirmation, not a picker**. It states what
      Embedded means and that the node runs as a new, separate identity, and
      offers one control that puts Embedded in force. No `ModePicker`, no
      Explore or Local, and no annotation of any mode as unstartable — the flow
      does not read `startableModes` at all, so there is no value to caption
      from. `ModePicker` itself is untouched and keeps its conservative empty
      default; it remains the header toggle's and the settings panel's picker.
- [x] `confirmEmbedded()` takes **no mode argument**, so `explore` and `local`
      are not expressible from this flow, and is called only by a `Button` —
      `advance()` and `back()` cannot reach it, so arriving writes no mode.
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

- [x] `tst_setup_wizard.qml` — tests against `SetupFlow`: order, findings,
      blocking, refusals, mode persistence, start semantics, staleness.
      Count them with `grep -c "function test_"` rather than trusting a number
      written here; note `qmltestrunner`'s own total is two higher, because it
      counts `initTestCase` and `cleanupTestCase`.
- [x] `tst_setup_wizard_view.qml` — tests against the rendered screen: the
      three consequence statements (the embedded one read off the rendered
      `Text`, never a data array), that no other mode is offered whatever
      `startableModes` reports, that the rendered control is what writes the
      mode, a neutral finding's backend sentence, the seed list, the
      empty-listening display, the passphrase not outliving its use, and the
      clipboard round trip. Same counting note as above.
- [x] Fakes answer from their own arguments or from a scenario that differs in
      the value the assertion reads back. Two preflight scenarios fail
      **different** findings; two refusals are **different** sentences; the two
      confirm DIDs differ and absence of the first is asserted.
- [x] Both guards proven to fail without their code: neutering `isCurrent()`
      reddens the late-reply test while its positive twin stays green, and
      deleting `clip.copy()` reddens the clipboard test.

### Review findings (second pass)

- [x] A successful start withdraws the start control. `alreadyServing` is now
      written by every reading of the node's state, so a node this flow started
      blocks a second start exactly as one it found running does.
- [x] `chooseMode`'s success path is exercised, with a fake whose reported mode
      can differ from the one written — so "re-read capabilities" is
      distinguishable from "trusted the argument".
- [x] `neutral` governs a finding's colour, not whether it can fail, so a
      backend `problem` sentence is no longer unreachable.
- [x] The mode blurb carries an `objectName` and is asserted as rendered, not
      read off `ModePicker.modes`.
- [x] The passphrase is cleared once `startNode` reports success — keyed on the
      reply, so a retry after a refusal still has it.
- [x] A choice is proven withheld while its preflight probe is outstanding,
      using a held-reply identity fake rather than `reset()`.
- [x] `preflightDone` follows three named flags rather than a literal `3`;
      `applyCapabilities()` is the one copy of the capabilities mapping.
- [x] Each of the above proven by mutation: the fix reverted, the named test
      watched to fail, the fix restored.
- [x] Full suite green — `sh radicle-ui/tests/run-qml-tests.sh`, zero failures.

### The rewritten step 2 (third pass)

The user ran the wizard and found step 2 of 6, inside a flow titled "Set up an
embedded node", offering all three modes with every row captioned "This version
cannot start this mode yet". The spec was rewritten; this is the code following
it.

- [x] `mode` → `embedded` throughout: `steps`, `canAdvance`,
      `advanceBlockedReason`, both file headers, `design.md` and `PLAN.md`.
- [x] `chooseMode(mode)` → `confirmEmbedded()`. No argument, so no other mode is
      expressible; called only by a `Button`, so arriving and going back write
      nothing.
- [x] `canConfirmEmbedded` withholds the control once the backend reports
      Embedded, while the statement of what Embedded means stays on screen.
- [x] `startableModes` and `modeUnavailableReason` removed from `SetupFlow`
      entirely, so the annotation cannot return without the property returning
      first. `ModePicker.qml` untouched.
- [x] New scenarios covered: arriving writes no mode, going back writes no mode,
      the control puts Embedded in force, the mode in force is the reply not the
      value written, a refusal neither advances nor moves it, returning does not
      re-offer it, and the startable set changes nothing.
- [x] Four mutations run, each reverted: write-on-arrival (7 red), trust the
      written value without re-reading (1 red), an unconditional unstartable
      caption (1 red), a caption keyed on the startable set (1 red, on the other
      assertion). The one mutation that reddened **nothing** is recorded in the
      test that would have had to catch it.

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
