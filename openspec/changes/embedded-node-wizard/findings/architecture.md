# Architecture review — `embedded-node-wizard`

Scope: architecture only, per dispatch (correctness, security and readability
are held by other instances).

Read: `SetupFlow.qml`, `SetupWizard.qml`, `CopyableCommand.qml`,
`tst_setup_wizard.qml`, `tst_setup_wizard_view.qml`,
`openspec/changes/embedded-node-wizard/{spec.md,design.md,tasks.md,proposal.md}`,
`radicle_ui.rep`, `ModePicker.qml`, `NodeIdentity.qml`, `SettingsPanel.qml`,
`CommitsTab.qml` (for the staleness-guard comparison CLAUDE.md names).

## Findings

- [x] **`dev-writer`** — `SetupFlow.qml:330-335` — `preflightDone` flips on a
      bare literal (`3`) that is not derived from anything, and is one line
      away from the four `if (fetch...)` blocks it is supposed to summarise.
      **Scenario:** `runPreflight()` has four `if (fetchX)` blocks
      (capabilities, identity, nodeStatus, seeds), and three of them call
      `flow.notePreflightAnswer()` — seeds deliberately doesn't, since it isn't
      one of the four *findings* the spec names. `notePreflightAnswer()` then
      compares `preflightAnswers` against a hand-written `3`. A future change
      that adds a fifth preflight question (or turns the `seeds` fetch into a
      counted one, or splits `fetchCapabilities`'s reply into two calls) has
      to remember to update this literal in a function several lines away from
      the thing that should determine it, with nothing tying the two together.
      Get it wrong and `preflightDone` either fires early (reports an unasked
      question as answered — the exact failure `design.md`'s "Open questions"
      section says was designed against) or never fires at all if a wired probe
      is later made optional. This is the same class of bug the repo's
      `wantRid`/`syncEpoch` write-up warns about: a fact that should hold by
      construction (`preflightDone` should be true iff every counted probe has
      answered) is instead asserted as a magic number nobody re-derives.
      **Measured:** `design.md` and `tasks.md` document `preflightDone` as a
      deliberate decision (the "unanswered ≠ failure" naming) but never mention
      `preflightAnswers` or the threshold at all — it is an implementation
      detail that slipped in unexamined, not a decision that was weighed. A
      cheap fix in the same shape the rest of the file already uses: three
      named booleans (`capsAnswered`, `identityAnswered`, `nodeStatusAnswered`)
      with `preflightDone` as their conjunction, the same "structure carries
      the invariant" move `stepIndex` and the four separate finding properties
      already make elsewhere in this file. Severity: low likelihood today
      (nothing in this change adds a fifth probe), but it is exactly the kind
      of drift CLAUDE.md's "put the complexity in the data structure" section
      calls out, and it sits right next to code that otherwise follows that
      rule carefully.

      **Fixed** in `f471999`, taking the cheap fix in the shape you proposed
      almost exactly. `preflightAnswers` and `notePreflightAnswer()` are gone,
      replaced by three named booleans — `capabilitiesAnswered`,
      `identityAnswered`, `nodeStatusAnswered` — each set by its own callback,
      with `preflightDone` driven from their conjunction:

          readonly property bool allProbesAnswered:
              capabilitiesAnswered && identityAnswered && nodeStatusAnswered

          onAllProbesAnsweredChanged: {
              if (allProbesAnswered) preflightDone = true;
          }

      (I used `capabilitiesAnswered` rather than your `capsAnswered`, matching
      `fetchCapabilities`/`refreshCapabilities` elsewhere in the file. The one
      addition to your sketch is the intermediate `allProbesAnswered`, so the
      invariant has a name a reader can find rather than being spelled out
      inside a handler.)

      Your framing that this "slipped in unexamined rather than being weighed"
      is accurate and is why it is now a recorded decision: `design.md` gains
      "The preflight's gating probes are named flags, not a counter", naming
      the failure mode you identified — a fifth probe leaves a threshold to be
      found separately, and getting it wrong fires `preflightDone` early,
      reporting an unasked question as answered, which is precisely what the
      "unanswered ≠ failure" decision exists to prevent.

      The related readability finding on the same lines (three nouns for three
      counts) is answered in `readability.md`: `runPreflight()`'s header now
      states all three counts and why they differ, and the `fetchSeeds` block
      carries an inline note that it is the one call marking no answer.

      Severity assessment shared — nothing here adds a fifth probe today. It
      was worth doing now because the reshape cost about ten lines and the
      surrounding code already holds its invariants this way.

## What was clean

- **The step-as-index shape holds.** `stepIndex` into `steps` genuinely makes
  "advance never skips" true by construction — `advance()` can only ever
  produce `stepIndex + 1`, clamped by `canAdvance`'s `stepIndex >= steps.length
  - 1` check. `canGoBack` (`stepIndex > 0`) falls out of the same
  representation rather than being a second condition to get right. This is a
  real instance of the pattern the repo's own `wantRid`/`syncEpoch` write-up
  asks for, not just an appeal to it.

- **The four findings staying four values is correct, not decorative.**
  `canCreateIdentity` reads `homeResolved && !identityExists` and
  `canStartNode` reads `gitFound && !alreadyServing && !startPending` —
  independently, from findings, never from a folded verdict. Collapsing them
  into one `preflightPassed` would have the exact failure the design doc
  names (a missing `git` blocking identity creation, which spawns no `git`),
  and the tests exercise the independence directly
  (`test_a_missing_git_blocks_start_but_not_identity`).

- **The epoch guard is a single shape, not a fifth hand-written copy.** One
  `epoch` integer, bumped by every `advance()`/`back()`/`reset()`, captured
  once per issued call as `issuedAt`, checked once via `isCurrent()`. Compared
  directly against `CommitsTab.fetch()` (read in this review), which
  hand-rolls the equivalent guard as two separate captured locals (`wantRid`,
  `wantBranch`) compared at each callback — a different, per-field shape that
  is exactly the kind of copy CLAUDE.md says gets a capture dropped from it
  eventually. `SetupFlow` does not add a fifth variant of that guard; it uses
  the one-counter version the file's own header argues for.

- **No interface widening.** `radicle_ui.rep` shows every slot this flow
  calls (`getCapabilities`, `getEmbeddedIdentity`, `createEmbeddedIdentity`,
  `startNode`, `getNodeStatus`, `listKnownSeeds`, `setSetting`) already
  existed before this change, with a comment noting they were "plumbed
  through now, ahead of the wizard that calls them" specifically so this
  change stays QML-only. Confirmed by `proposal.md`'s Impact section and by
  there being no diff to `radicle/` or the Rust staticlib in this piece.

- **`ModePicker` reuse is reuse, not coupling.** The wizard's mode step wires
  `current`, `startableModes` and `unavailableReason` into `ModePicker`
  exactly the way `SettingsPanel.qml` already does — `ModePicker` already had
  a second consumer before this change existed, so this is not an abstraction
  invented for a caller that doesn't need it yet; it is the established
  pattern picking up a third caller. The `embedded` blurb's "separate
  identity" wording is asserted through the real component in
  `tst_setup_wizard_view.qml`, so a future edit to that wording cannot
  silently desync from what the spec requires here.

- **Not reusing `NodeIdentity`'s clipboard component was the right call, and
  it is not a missed extraction.** The payload differs (a bare DID vs. a full
  `rad id update --allow <DID>` shell command) and the chrome differs (a
  header label with hover/elision rules vs. a command block in a wizard
  body). `CopyableCommand.qml` copies the *pattern* (write to a hidden
  `TextEdit`, verify via a second, separate paste-back editor) rather than
  the component, which duplicates roughly a dozen lines of verification logic
  between the two files. Under CLAUDE.md's own counter-pressure — do not
  refactor for a caller that doesn't need it — extracting a shared
  `ClipboardVerifier` component now would be speculative: there is no third
  caller, and the two existing ones differ enough in payload and layout that
  a shared component would need parameters for both, which is exactly the
  kind of interface creep CLAUDE.md's "make the easy change" section warns
  against manufacturing pre-emptively. Not a finding, but flagged here since
  the dispatch asked the question directly: this is a judgment call the
  design doc already made and defended, and rereading it did not turn up
  a second caller that would change the answer.

- **The `SetupFlow`/`SetupWizard` split puts the testable decisions in the
  right place.** Every ordering, blocking and staleness assertion in
  `tst_setup_wizard.qml` (34 assertions) is made against `SetupFlow` directly,
  with no window and no rendered element in sight — the same shape
  `NavState.qml`/`SourceState.qml` established. `tst_setup_wizard_view.qml`
  is a genuinely separate 14-assertion file for what only rendering can
  answer (three consequence statements, the seed list, the clipboard round
  trip), and it does not re-assert anything the state-level file already
  covers. This is the split CLAUDE.md's "make the change easy" section holds
  up as the fix for `Main.qml`'s `nav.busy`/`nav.error` tangle, applied
  correctly here rather than invoked as a label.

## Not reviewed here

Correctness of the individual blocking rules, security of the DID/clipboard
handling, and QML readability/naming are out of scope for this pass — see the
sibling `correctness.md`, `security.md` and `readability.md` findings files.
