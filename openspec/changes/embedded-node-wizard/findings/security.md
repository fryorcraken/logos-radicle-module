# Security review — `embedded-node-wizard`, piece 2 (hosting the setup wizard)

Scope: `radicle-ui/src/qml/Main.qml` (the host), `SetupWizard.qml`,
`SetupFlow.qml`'s re-entry logic (`restart()`/`reset()`/
`landOnFirstUnfinishedStep()`), `EmbeddedState.qml`, `RepoList.qml`, and their
tests, diffed `90ec3b9..b802335`. Security dimension only. This overwrites
piece 1's now-closed `security.md` (its `SetupWizard.qml` line references and
step layout — `ModePicker` at `stepIndex === 1` — no longer match this piece's
six-step flow).

## Findings

- [ ] **`dev-writer`** — `SetupWizard.qml:96-98,557-563` /
      `SetupFlow.qml:426-430,680-708` — the passphrase-residency fix from piece
      1 (clear `passphraseField.text` on `nodeStarted`) does not cover the
      close-and-reopen path this piece adds, so a passphrase typed in one
      showing can silently outlive it and be reused, unrefreshed, in a later
      one.
      **Scenario:** a user opens the setup, types a passphrase at the identity
      step, submits identity creation (`submitIdentity`) — which succeeds and
      consumes the passphrase once — and then **closes the wizard without
      starting the node** (clicks Cancel, or just navigates away; `wizardClose`
      → `wizard.closed()` → `Main.qml`'s `onClosed` only sets `setupOpen = false`
      and calls `refreshEmbedded()`; neither touches `passphraseField`). Some
      time later — the same running Basecamp session — the user reopens the
      setup (`openSetup()` → `setupWizard.show()` → `flow.restart()` →
      `reset()` + `runPreflight()` + `landOnFirstUnfinishedStep()`). Because
      the identity now exists and the node is not serving, the flow resumes
      directly at the **start** step. `wizard.passphrase` is a live binding
      (`passphraseSwitch.checked ? passphraseField.text : ""`) reading the
      *same, never-destroyed* `TextField` from the abandoned first showing —
      `SetupWizard` is one persistent instance under `Main.qml`
      (`visible: root.setupOpen`, never recreated; `StackLayout` instantiates
      every step's children eagerly). `reset()` clears every `SetupFlow`
      property (line 680-708) but never references `passphraseField` — it
      cannot, since the field lives in the view, not the flow object. So the
      old passphrase is handed to `startNode()` in the second showing with no
      re-entry by the user and no indication on screen that this is a stale
      value from an earlier attempt.
      **Why it matters:** this is the same class the piece-1 fix addressed
      (secret material resident in memory, readable through the QML inspector
      the dev Basecamp ships with, per `SetupWizard.qml:549-551`'s own
      comment), but now with an added failure mode: the passphrase can be
      *reused across sessions of the flow* rather than merely lingering within
      one. If the user meant to abandon that attempt (e.g. changed their mind
      about the passphrase, or typed it into the wrong field and wants to
      retype), the stale value is silently resubmitted as if freshly entered.
      **Measured:** confirmed by reading — the only clearing site anywhere in
      `SetupWizard.qml`/`SetupFlow.qml` is the `Connections { onNodeStartedChanged }`
      block at `SetupWizard.qml:557-563`, gated on `setupFlow.nodeStarted`
      becoming true; `reset()` (`SetupFlow.qml:680-708`) resets every `SetupFlow`
      property but has no way to reach the view's `TextField`. Then measured
      directly: wrote a throwaway QML `TestCase` instantiating a real
      `Ui.SetupWizard` against a fake backend, drove it through
      `wizard.show()` → type passphrase → `submitIdentity()` (succeeds,
      `identityExists` becomes true) → **no start** → `wizard.show()` again
      (simulating close-and-reopen) — and asserted the field's text. Result:
      `compare(String(field.text), "correct horse battery", …)` **passed** —
      the passphrase was still present verbatim after the reopen, at the very
      step (`start`) whose control would hand it to `startNode()`. Ran under
      `/usr/lib64/qt6/bin/qmltestrunner -import radicle-ui/src/qml`; the
      existing suite (`tst_setup_wizard_view.qml`, 20/20 passing, including
      `test_the_passphrase_does_not_outlive_the_calls_that_use_it`) has no
      test that closes and reopens the wizard, so nothing in the shipped suite
      exercises or guards this path. The scratch test was deleted after the
      measurement; the worktree is clean (`git status` shows nothing to
      commit).
      **Severity:** real but bounded — the passphrase is never transmitted or
      logged anywhere in this diff, and the `.rep`/`radicle_impl.h` boundary
      still takes no home/socket argument (see below), so this is an
      in-process residency and reuse issue, not a cross-process or
      cross-profile leak. It is exactly the shape CLAUDE.md and this piece's
      own task both call out as worth re-checking on re-entry, and it is now
      reachable because piece 2 is what introduces close-and-reopen. Recommend
      clearing `passphraseField.text` (and resetting `passphraseSwitch.checked`
      to its default) at the point the wizard is asked to `show()` again for a
      showing where the identity step's work is already done (i.e. whenever
      `resumeIndex` lands past `identity`), not only on `nodeStarted` — with a
      regression test that opens, types, abandons before start, reopens, and
      asserts the field is empty.

## Clean areas (no findings)

- **`start`/`restart` are structurally unhosted, not just labelled so.**
  `Main.qml`'s `embeddedStartHosted` is `readonly property bool … : false`
  (line 200), `takeEmbeddedAction()` only routes `"setup"` to `openSetup()`
  and does nothing for any other kind (line 320-322), and
  `EmbeddedState.actionEnabled` requires `actionHosted` before a control is
  even rendered enabled (`EmbeddedState.qml:272-273`). `RepoList`'s
  `embeddedStateAction` button double-checks `actionEnabled` inside
  `onClicked` before emitting the signal (`RepoList.qml:574-577`), so a caller
  invoking `.clicked()` programmatically past a disabled control still cannot
  provoke a `start`/`restart` request. `tst_setup_host.qml`'s
  `test_a_start_request_does_not_raise_the_setup` exercises this by calling
  `takeEmbeddedAction("start")`/`"restart"` directly (bypassing any control)
  and asserts the setup is not raised — confirmed passing. No path in this
  diff flips `embeddedStartHosted` or reaches `startNode`/`stopNode` from a
  session that lacks the passphrase the identity step took in the same
  showing.
- **The `.rep` boundary's "no home/socket argument" reasoning holds.** All
  seven functions `Main.qml` injects into `flow.*`
  (`fetchCapabilities`/`fetchIdentity`/`fetchNodeStatus`/`fetchSeeds`/
  `createIdentity`/`startNode`/`saveSetting`, lines 1137-1158) call exactly the
  slot signatures `radicle_ui.rep` declares
  (`getCapabilities()`, `getEmbeddedIdentity()`, `getNodeStatus()`,
  `listKnownSeeds()`, `createEmbeddedIdentity(alias, passphrase)`,
  `startNode(passphrase)`, `setSetting(key, value)`) — no home, no socket
  argument is threaded from QML anywhere in this piece.
- **Mutual exclusion of the two overlays is enforced at the raise, not by a
  binding that could fail open.** `openSetup()` unconditionally sets
  `settingsOpen = false` before `setupOpen = true`
  (`Main.qml:300-304`); `toggleSettings()` unconditionally sets
  `setupOpen = false` before `settingsOpen = true`
  (`Main.qml:331-338`). Both panes are siblings keyed on independent
  booleans (`visible: root.settingsOpen` / `visible: root.setupOpen`), so
  there is no state where both can read true from the raise functions —
  confirmed by `tst_setup_host.qml`'s
  `test_raising_each_surface_lowers_the_other` and
  `test_lowering_one_raises_nothing`, both passing. Lowering either surface
  never sets the other's flag, so a close cannot hand the user an unrequested
  overlay.
- **Nothing raises the setup except the explicit "setup" request.** Grepped
  every call site of `openSetup()`/`setupOpen = true` in `Main.qml`: the only
  one is inside `takeEmbeddedAction("setup")`, itself only reachable from
  `RepoList.onEmbeddedActionTaken`. No mode-selection handler
  (`setMode`/`sourceState.onChanged`/`onSettled`), no capabilities-driven
  handler (`onCapsJsonChanged`, `refreshEmbedded()`), and no startup handler
  (`onBackendReady`, `Component.onCompleted`) calls it — matching
  `tst_setup_host.qml`'s `test_selecting_embedded_does_not_raise_the_setup`,
  which passes.
- **No `console.*` logging or clipboard write of the passphrase, alias, or
  any reply payload** exists anywhere in the reviewed files; the confirm
  step's clipboard write (`CopyableCommand`) only ever carries the reported
  DID (`allowCommand`), never anything derived from the identity/passphrase
  fields.
