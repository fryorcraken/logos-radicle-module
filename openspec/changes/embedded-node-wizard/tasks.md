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

**The identity step was reopened a second time, from dogfooding the built app.**
Three defects on one screen, all of them the spec's silence rather than the
implementation's: the step offered creation and advancing as two controls where
creating the identity *is* how the step is left; an identity that already existed
rendered as a refusal beside a success, so "you already did this" and "your
attempt failed" looked the same; and neither message named the home being written
to, though `getEmbeddedIdentity()` reports it. The spec now carries three
requirements for the identity step — one forward control, its three states, and
the home named — and the blocking, resume and passphrase requirements were
adjusted where they assumed two controls. **The `dev-writer`, `tester` and every
reviewer row above predate this**; the runner owns re-dispatching them.

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

**The spec was reopened a third time, from dogfooding the built app, and this
one changes what the piece is.** Two things that were steps of the wizard are
steps of nothing now. Step 5 rendered an amber "a node is already answering on
the resolved socket" directly above its own green "Running as did:key:…" — a
warning about the node it had just started, the same defect class as the identity
step's already-exists refusal. Step 6 was a terminal screen whose only act was to
be dismissed. So the setup shrinks to four steps and does **setup only**:
starting moves to the Embedded surface, where it happens by itself for an
unencrypted key and behind one passphrase field for an encrypted one, and the DID
moves to the header, reusing `NodeIdentity.qml` where it already sits.

**This piece is no longer QML-only.** The autostart rule needs
`getEmbeddedIdentity()` to report `encrypted`, which it does not — only
`createEmbeddedIdentity`'s reply carries that field, and it echoes its argument
rather than observing the key. `getCapabilities().canWriteLocal` was considered
and rejected as a substitute: it probes the home of the mode in force, so it is
silent about the embedded home from any other mode, and it conflates encryption
with a missing or unreadable key. So `embedded-identity` gains a MODIFIED
requirement and `radicle/` gains a change — the probe itself,
`Keystore::is_encrypted()`, is already used in this repo's write path and needs
no passphrase or agent, so what is new is exposing it rather than obtaining it.
`radicle_ui.rep` is unchanged; every slot on it already returns opaque JSON.

A third capability, `embedded-header`, is added for the DID. **`design + code`,
tests and every reviewer row need re-running against all of this**; the runner
owns re-dispatching them, and the rows are left as they are for the same
one-row-per-stage reason as above.

## Implementation — the collapsed setup flow (eighth pass)

Acting on the third reopening of the spec, from the user dogfooding the built
app. No stage row is ticked or added: `design + code` was already ticked and the
block is one row per stage, so concurrent cherry-picks do not conflict.

**This is the pass that is not QML-only.** Two commits: the backend field, then
the flow that consumes it.

### The backend — `getEmbeddedIdentity().encrypted`

- [x] `profileinit::key_encrypted(home)` — wraps the `Keystore::is_encrypted()`
      probe `cobwrite::signer` already uses. Answers
      `{"encrypted":bool,"problem":""}` rather than a bare bool, because there
      are THREE answers: sealed, not sealed, and could not tell. Collapsing the
      third into `false` is the dangerous direction.
- [x] `radicle_local_key_encrypted` through `guarded`, a `LocalReader::keyEncrypted`
      wrapper, and both `getEmbeddedIdentity()` JSON build sites.
- [x] Asked only where `exists` is true: the probe opens the SECRET key file, so
      an empty home would report a missing-key `problem` for a key that is
      legitimately not there.
- [x] `radicle_impl.h`'s `createEmbeddedIdentity` paragraph corrected — it told
      callers to read `canWriteLocal` for this question, which probes the mode in
      force and conflates encryption with three other causes.
- [x] Five Rust tests and one C++ test, every one reading a home some OTHER call
      created with the creating reply DISCARDED — so an implementation echoing
      what it was told has nothing to echo. `can_write` is the control that
      proves the probe unlocks nothing.
- [x] **Mutation:** the `Err` flattened to `encrypted:false, problem:""` — 2 red,
      both named. Reverted.
- [x] `cargo fmt --check`, `cargo clippy --all-targets -D warnings`, and the full
      `cargo test` green. `nix build '.#checks.x86_64-linux.unit-tests'` green.

### The Embedded surface — starting, and the passphrase

- [x] `EmbeddedState` gains `encrypted`, `startSucceeded` and `restartHosted`
      as inputs; `wantsAutoStart`, `wantsPassphrase` and `foundForeignNode` as
      derivations. `encrypted` defaults TRUE and `startSucceeded` FALSE — both
      the direction where a missing reply costs a dismissal rather than an
      unasked-for start or a suppressed warning.
- [x] `wantsAutoStart` is a DECISION; `RepoList` issues the call. "Issued once
      per arrival" is then an edge on a derived boolean rather than a counter.
- [x] `Component.onCompleted` beside the `Connections`, because a change signal
      fires on a CHANGE and a list built already stopped never sees one. See
      "Not covered" below — deleting it reddened nothing until a test existed.
- [x] The passphrase is ONE FIELD on the panel, cleared as the call is issued so
      its lifetime is the call. A refusal empties it, which is correct: the
      passphrase that was refused is not the one to retry with.
- [x] `startHosted` / `restartHosted` SPLIT. One flag would have made hosting a
      start silently enable a restart reaching nobody.
- [x] `Main.qml` — `embeddedEncrypted`, `embeddedStartSucceeded`,
      `startEmbeddedNode()`, `embeddedStartHosted: true`,
      `embeddedRestartHosted: false`, and `routesEmbeddedAction` reading both.

### The header — the DID

- [x] `SourceState.modeHasIdentity`, ONE rule keyed on whether the mode reads a
      home of its own. `Main.qml:950`'s `mode === "local"` becomes it.
      `NodeIdentity.qml` is untouched: it already renders a full, copyable,
      clipboard-verified DID in the slot.
- [x] `tst_source.qml`'s slot fixture now instantiates the REAL `SourceState`
      rather than reproducing the comparison, or the list-shaped rule could come
      back with that file green.

### The wizard — four steps

- [x] `steps` loses `start` and `confirm`. `startNode`, `canStartNode`,
      `startBlockedReason`, `nodeStarted`, `listening`, `nodeServing`,
      `startPending`, `nodeId`, `allowCommand`, `submitStart` and
      `refreshNodeStatus` are REMOVED rather than left unread — so "issues no
      startNode in any step" is a property of the object.
- [x] `resumeIndex` stops reading `alreadyServing`; `onLastStep` added, derived
      from the index rather than naming `network`.
- [x] The embedded step gains the allow-is-not-enough sentence; the passphrase
      trade gains what the choice decides about every later opening; the last
      step's forward control finishes.
- [x] Both test fakes dropped their `start` functions, so a future edit wiring a
      start back in cannot stay green.

### Tests and mutations

- [x] Full suite green: `sh radicle-ui/tests/run-qml-tests.sh` — 31 files, zero
      failures. Count the tests with `grep -c "function test_"` rather than
      reading a number here.
- [x] `sh radicle-ui/tests/check-qml-syntax.sh` green.
- [x] `lgs basecamp build --variant lgx --module radicle_ui` green, run from this
      worktree's root (`pwd` checked).
- [x] **Mutations run and reverted, each reddening NAMED tests:** the `Err`
      flattened (2 red); `wantsAutoStart` keyed on the key alone (1 red, all
      seven rows wrong); `foundForeignNode` dropping `!startSucceeded` (3 red
      across two layers, the third reproducing the user's screenshot);
      `modeHasIdentity` back to a mode list (3 red, one reporting `embedded:no`).
- [x] **One mutation that reddened NOTHING, and the test written for it:**
      deleting `Component.onCompleted: autoStartIfWanted()`. Recorded in
      `design.md` rather than quietly fixed.

### Not covered, and stated rather than implied

- [ ] **No end-to-end coverage of the node actually starting.** `local.yaml`
      runs against an embedded home with NO identity, so it reaches the
      no-identity state and stops — nothing there starts a node, and a spec that
      provisioned one would leave a real embedded home and a running node behind
      on every CI run. So "the node genuinely starts itself" is proven at the
      component layer, against an injected host, and the real
      `Main.startEmbeddedNode` is covered nowhere. Its shape is reproduced in two
      fixtures; a divergence between them and the real file is invisible to both.
- [ ] **The header's DID in Embedded has no end-to-end assertion either**, for
      the same reason: `local.yaml`'s Embedded leg has no identity, so the slot
      is correctly empty there. `root.nodeIdentity === ''` in that leg is now
      about the backend rather than about the gate, which is stated in the spec's
      own comment.
- [ ] **`Main.qml` still has no component test**, unchanged from earlier passes.
      `startEmbeddedNode`, the two new reply fields and the split hosting flags
      are covered at that layer only as a reproduction.

## Implementation — the respecced identity step (seventh pass)

Acting on the second reopening of the identity step, from the user dogfooding
the built app. No stage row is ticked or added: `design + code` was already
ticked and the block is one row per stage, so concurrent cherry-picks do not
conflict. Two QML files and two test files changed; no change to `radicle/`,
`radicle_ui.rep` or the Rust staticlib.

### The state

- [x] `canAdvanceIdentity` — the FORWARD-CONTROL gate, kept **distinct** from
      `canCreateIdentity`, the creation gate. The spec's two blocks block two
      different things: an unresolvable home blocks the step, an occupied home
      blocks only the call. `canCreateIdentity` keeps its meaning because two
      resume tests read it as the observable for "creation is not offered".
- [x] `submitIdentityStep(alias, passphrase)` — the one forward control. It
      advances without a call where an identity exists, and creates where none
      does. `submitIdentity` stays as its own function under it: one owns the
      call, the other owns which act to perform.
- [x] The create-and-advance happens **inside the reply handler**, guarded on
      `reply.created === true` — so a refusal stays on the step, which is what
      the spec requires and what advancing-after-the-call would break.
- [x] `identityState` — `"none"` | `"created"` | `"present"`, ONE derived string
      rather than two booleans, so "created and already-there render the same"
      and "created and refused on screen together" are unrepresentable rather
      than merely discouraged.
- [x] `identityCreatedHere` — the one fact no backend reply can supply. Cleared
      by `reset()`, so it is per-showing by construction and a resumed flow
      reports a found identity as already there.
- [x] `identityActionLabel` — derived, so "the label names the act" is a
      property of the state the act is decided from rather than of the view.
- [x] `createBlockedReason` no longer carries the "already exists … refused"
      sentence. It described an attempt nobody made.

### The view

- [x] One `identityForward` Button, labelled from the flow. The generic
      `wizardNext` is **hidden on the identity step** — hidden rather than
      disabled, because a disabled Next beside an enabled forward control still
      reads as two ways out.
- [x] Three states rendered apart: `identityCreated`, `identityAlreadyThere`
      with its plain-text note, and neither in the no-identity state.
- [x] `identityHome` renders `getEmbeddedIdentity().home` in ALL THREE states,
      and states that none could be resolved — with the backend's own sentence —
      rather than rendering an empty path.
- [x] The alias, switch, trade and passphrase field are scoped to the
      no-identity state. Both halves of the trade, in both switch positions,
      are unchanged within it.

### Tests

- [x] `tst_setup_wizard.qml` — the occupied-home test **rewritten** for the new
      substance (creation refused, step not blocked), plus the unresolvable
      home, one control creating and advancing, the label in both directions,
      the three states, an already-there identity not reported as a failure,
      created-and-refused never together, and a refused creation retried.
      `test_returning_to_a_step_that_acted…` strengthened to assert the CALL
      LOG, because the gate going false does not say the control refrains.
- [x] `tst_setup_wizard_view.qml` — exactly one forward control, the rendered
      label, the three states walked from the scene graph, no refusal for an
      already-there identity, the home in all three states, a second distinctive
      home replacing the first, an unresolvable home stated, and no passphrase
      choice where an identity exists.
- [x] `test_a_passphrase_is_the_arriving_default` pinned to the no-identity
      state rather than relying on the fixture's default.
- [x] Fakes stay input-dependent: the two homes are different distinctive paths
      and the first is asserted ABSENT; the created DID and the already-there
      DID differ, so "already existed" and "just created" cannot be confused —
      which is precisely the distinction the shipped screen got wrong.
- [x] **Seven mutations run and reverted, each reddening named tests**: the two
      gates collapsed (2 red); `identityState` folded to "created" for any
      identity (1 red on substance, 2 on preconditions); the advance dropped
      from the reply handler (3 red); `wizardNext` unconditionally visible
      (1 red); the home path blanked (2 red); the "already exists … refused"
      sentence restored to `createBlockedReason` (2 red); the passphrase row
      unconditionally visible (1 red).
- [x] Full suite green: `sh radicle-ui/tests/run-qml-tests.sh` exits 0. Count
      the tests with `grep -c "function test_"` rather than reading a number
      here; the runner's per-file total is two higher, counting
      `initTestCase`/`cleanupTestCase`.
- [x] `sh radicle-ui/tests/check-qml-syntax.sh` green.
- [x] `lgs basecamp build --variant lgx --module radicle_ui` green, run from
      this worktree's root.

### Not covered

- [ ] **No end-to-end coverage of the identity step**, unchanged from the fifth
      pass and for the same reason: every step after preflight writes, so a
      spec that walked this one would leave a provisioned embedded home behind
      on every CI run. `local.yaml` still raises and lowers the setup without
      walking a step.

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
