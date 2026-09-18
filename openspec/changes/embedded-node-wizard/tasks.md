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

**`design + code` has now been re-run against the reopened spec.** Its row was
already ticked and stays ticked rather than gaining a second — the stage block is
one row per stage so concurrent cherry-picks do not conflict. What that tick now
covers is both passes: the wizard, and `embedded-state` plus the re-keyed
`source-modes` requirement. The reviewer rows still refer only to the first pass.

**The spec was reopened a second time, for the wizard's host.** `embedded-setup`
gained four requirements — the setup as a surface raised over the view, mutual
exclusion with the settings surface, which acts may open it, and where a reopened
flow lands — and one stating that starting or restarting an existing node is out
of scope until the configuration panel exists. `embedded-state` was reconciled
with that last one: it now names an action without enabling it where nothing can
carry the action out, which turned three scenarios that asserted an enabled start
or restart into scenarios asserting the named action instead. `design + code`,
tests and every reviewer row need re-running against this; **the runner owns
re-dispatching them**, and the rows are left as they are for the same reason as
above.

**`design + code` has now been re-run against that second reopening** — the
fifth pass below. Its row was already ticked and stays ticked rather than gaining
a second, for the one-row-per-stage reason above; what that tick now covers is
five passes, the last being the wizard's host. The reviewer rows still refer only
to the first pass.

**A sixth `design + code` pass acted on piece 2's review findings**, and again
flips no row, for the same one-row-per-stage reason. All eight findings across
`security`, `readability`, `design-review`, `architecture` and `spec-test` are
ticked with their outcomes appended. Two were real defects: a passphrase that
outlived an abandoned showing, and a routing table that could not see the
hosting flag the panel's enablement reads. Two coverage gaps were closed —
"the module becomes ready already in Embedded" and a blocked home's silence
about unavailability — and one comment claiming a mutation reddened a named test
was measured, found false, and replaced with the reason no test could have
caught it. The reviewer rows above still refer to the state before this pass.

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

## Implementation — `embedded-state` (fourth pass)

The capability the spec gained after a design pass found that picking Embedded
leads to an empty list, a red banner and "No repositories matched". One new QML
file, two new test files, and re-pointing three existing ones. No change to
`radicle/`, `radicle_ui.rep` or the Rust staticlib — every slot is already
exposed.

### The state

- [x] `EmbeddedState.qml` — a non-visual `QtObject` holding seven reply fields
      and deriving `current`, `sentence`, `actionLabel`, `actionKind`,
      `actionEnabled`, `hasNodeToAsk`. Separate from the view for the reason
      `NavState` and `SourceState` are.
- [x] **Nothing stores a state.** Every input is a field a reply carried;
      `startPending` and `startError` are the two facts only the view holds, and
      `startPending` is cleared by the reply rather than by the call.
- [x] The ordering is one `if` chain read top to bottom, not seven predicates —
      so "which condition wins when two hold" is answered once. `stopped` above
      `starting`, and `actionEnabled` reading `startPending` directly, are the
      two places a reorder would break something; both are written down in
      `design.md` with the test that reddens.

### The view

- [x] `RepoList.qml` — `embeddedState`, a centred panel replacing
      `notImplementedState` as the Embedded surface, with the state's sentence
      and the state's own action. `blocked` renders no control at all.
- [x] `fetch()`'s bail-out re-keyed from `notImplemented` (startability) to
      `hasNodeToAsk`. **This is the fix**; the old guard is what stopped firing
      when Embedded became startable.
- [x] `sayingNothing` carried from `notImplementedState.visible` to
      `embeddedState.visible`, reading the item rather than its condition. The
      `loadedOnce` gate split via `expectingAPanel`, because four of the seven
      states never set it.
- [x] `notImplementedState` KEPT — `source-modes`' generic unstartable path is
      still a requirement — with its copy made mode-neutral, because naming
      Embedded in it is now false.
- [x] `Main.qml` — the three reply fields, `refreshEmbedded()`, the reload on
      `hasNodeToAsk` moving, and `reposEmbeddedPanel` / `reposEmbeddedState`
      replacing `reposNotImplemented`.
- [x] The panel's action emits `embeddedActionTaken(kind)` and performs nothing.
      **Nothing listens to it yet** — marked `NO SPEC:` on the signal.

### Tests

- [x] `tst_embedded_state.qml` — tests against the derivation: the ordering
      in both directions, each state's own sentence and action, starting versus
      not serving, two refusals, the success that clears one, which states
      have a node to ask, and that a blocked home claims no unavailability.
      Count with `grep -c "function test_"` rather than reading a number here;
      the runner's total is two higher, counting
      `initTestCase`/`cleanupTestCase`.
- [x] `tst_embedded_panel.qml` — tests against the rendered screen and the
      fetch guard, including the blank-pane observable in all six panel states
      and the "panel prevented from rendering" case. Count with
      `grep -c "function test_"`.
- [x] Fakes answer from the MODE the request was issued for, so "listed the
      embedded node" is distinguishable from "listed the user's node under an
      Embedded badge" — the two share a method prefix. Replies are held, so "did
      not request" is distinguishable from "requested and discarded".
- [x] `tst_embedded.qml` re-pointed from `embedded` to `local` as its
      unstartable mode; its "becoming startable therefore lists" leg would
      otherwise have failed for a reason the file is not about.
- [x] `tst_embedded_real.qml`'s fixture now reports a running, serving node —
      the state a working mode is actually in — and its unprovisioned-home test
      asserts nothing is asked rather than staging a refusal.
- [x] `tst_embedded_wiring.qml`'s fixture now reports all three modes startable,
      which is what this build reports; its precondition moved from
      `notImplemented` to the Embedded panel.
- [x] `local.yaml` — `reposNotImplemented === false` replaced by
      `reposEmbeddedPanel === true` plus `reposEmbeddedState === 'noIdentity'`,
      with `navError === ''` added, and `reposEmbeddedPanel === false` asserted
      on the way back to the seed.
- [x] Five mutations run and reverted: the guard re-keyed to startability (7 red
      in the panel file, 2 in the wiring file), `sayingNothing` dropping the
      panel (4 red), `sayingNothing` reading the condition instead of the item
      (1 red, the one test that exists for it, 18 green), the ordering hoisted
      (1 red), `!startPending` dropped from `actionEnabled` (1 red).
- [x] Full suite green: `sh radicle-ui/tests/run-qml-tests.sh`, 30 files, 509
      passing, 0 failed.
- [x] `lgs basecamp build --variant lgx --module radicle_ui` green from this
      worktree's root.

### Not covered, and stated rather than implied

- [ ] **`Main.qml`'s own wiring has no component test.** Nothing instantiates
      `Main.qml` — `tst_embedded_wiring.qml` and `tst_setup_host.qml` reproduce
      its shape — so `refreshEmbedded()`, the `embeddedSettled` `Connections`,
      the new properties and the host functions are covered at that layer only
      as a reproduction. `local.yaml` is what drives the real file.
- [x] ~~**The panel's action reaches nobody.**~~ Closed by the pass below.

## Implementation — hosting the setup (fifth pass)

`RepoList.embeddedActionTaken(kind)` emitted and nothing listened;
`SetupWizard.qml` had never been instantiated by anything and its `closed()` had
no host. Both are closed here. One new QML file's worth of host wiring inside
`Main.qml`, one new test file, and four new steps in `local.yaml`. No change to
`radicle/`, `radicle_ui.rep` or the Rust staticlib — every slot the flow drives
was already exposed.

### The host

- [x] `Main.qml` — `setupOpen`, and a `setupPane` overlay SIBLING to
      `settingsPane` rather than a `nav.view` destination. Lowering restores what
      was underneath with no decision to make; a destination would have to choose
      between the step the user was on and the screen they came from.
- [x] `openSetup()` and `toggleSettings()` enforce the mutual exclusion **at the
      raise**, never as a binding — so lowering one raises nothing.
- [x] `takeEmbeddedAction(kind)` routes on the KIND. `"setup"` raises; `"start"`
      and `"restart"` reach nothing, which is what makes the rule a property of
      the function rather than of which states are reachable today.
- [x] The wizard's seven call functions injected through `callPlain` (reads) and
      `callSettings` (writes, whose refusal is the useful result).
- [x] `onClosed` lowers and calls `refreshEmbedded()`, because the flow may have
      created an identity or started a node and the panel underneath is derived
      from those replies.
- [x] `settingsShown`/`setupShown` read off the panes' own `visible`, not off the
      flags they are keyed on.

### Re-entry

- [x] `SetupFlow.restart()` — reset, arm `resumeWanted`, run the preflight.
- [x] `resumeIndex` derives the landing step from four reply-derived values;
      `landOnFirstUnfinishedStep()` assigns `stepIndex` **once** and does not bump
      `epoch`. Not a loop over `advance()` — see `design.md` for what that breaks
      and, more importantly, for which test does and does not catch it.
- [x] The landing fires from `onAllProbesAnsweredChanged`, so the flow **waits at
      preflight** until the gating replies land rather than choosing from
      defaults.
- [x] `resumeWanted` is per-showing, so a later reply does not move a step the
      user walked to.
- [x] `SetupWizard.show()` replaces `Component.onCompleted`, because the overlay
      is not destroyed between showings.

### Only an action something can carry out is enabled

- [x] `EmbeddedState` gains `setupHosted`/`startHosted` inputs and `actionHosted`;
      `actionEnabled` conjoins it. Both default false — a forgotten wiring gets a
      disabled action, which is visible.
- [x] `actionUnavailableNote` says starting is **not yet available from here** —
      not that it failed, not that it cannot be started.
- [x] `RepoList` renders the note and guards `onClicked` on `actionEnabled`, so a
      programmatic emit cannot request an unhosted act either.
- [x] `Main.qml` reports `embeddedSetupHosted: true`, `embeddedStartHosted:
      false`, and `routesEmbeddedAction()` reads those same two flags so the
      panel's enablement and the host's routing cannot disagree. Hosting a start
      later is that one property **plus the branch that carries the act out** —
      the flag alone would otherwise enable a control whose click is dropped.

### Tests

- [x] `tst_setup_host.qml` — tests against the host's shape: the panel's action
      raises the setup, selecting Embedded does not, starting up already in
      Embedded does not, a start request does not, every hosted kind is one the
      host routes, the two surfaces exclude each other, lowering one raises
      nothing, the flow's report lowers it, lowering refreshes, and raising
      restarts the flow. Count with `grep -c "function test_"` rather than
      reading a number here; the runner's total is two higher.
- [x] `tst_setup_wizard.qml` — six re-entry tests, including one that holds the
      seed reply across the landing.
- [x] `tst_embedded_state.qml` / `tst_embedded_panel.qml` — the hosted-ness
      scenarios, and the four assertions that became named-action assertions.
- [x] `local.yaml` — four steps: the setup is not raised until asked for, the
      click raises it over the unchanged view, the close control lowers it, and
      the screen underneath is unchanged. The existing select-Embedded step now
      also proves selecting does not auto-open, because the observable exists.
- [x] Mutations run and reverted, each reddening a NAMED test: land by looping
      `advance()` (1 red, and **not** the test that restates the scenario — see
      `design.md`); rely on `Component.onCompleted` (1 red); route every kind to
      `openSetup()` (1 red); drop the exclusion on raise (1 red); drop
      `!startPending` from `actionEnabled` (1 red, in the test that arms
      `startHosted` — the spec-writer's warning that the old proof had lapsed was
      correct, and re-verified rather than trusted).
- [x] Full suite green from this worktree: `sh radicle-ui/tests/run-qml-tests.sh`
      — 31 files, 0 failed.
- [x] `lgs basecamp build --variant lgx --module radicle_ui` green, run from this
      worktree's root.

### Not covered

- [ ] **`local.yaml` raises the setup and lowers it without walking a step**,
      deliberately: every step after preflight writes, and a spec that ran them
      would leave a provisioned embedded home behind on every run. The flow's own
      behaviour stays at the component layer, where the calls are injected.
