# Security review — `embedded-node-wizard`

Scope: `radicle-ui/src/qml/SetupFlow.qml`, `SetupWizard.qml`,
`CopyableCommand.qml`, and their tests. Security dimension only.

## Findings

- [x] **`dev-writer`** — `SetupWizard.qml:92-93,382-390` — the plaintext
      passphrase outlives every use and nothing ever clears it.
      **Scenario:** a user types a passphrase at the identity step, submits
      identity creation (`submitIdentity`), advances through network and start
      (reusing the same value via `submitStart(wizard.passphrase)`), and
      reaches confirm. `passphraseField` is a plain `TextField` inside the
      `StackLayout`'s identity-step `Column` — `StackLayout` instantiates every
      child eagerly (there is no `Loader` gating any step, confirmed by reading
      the `StackLayout` block at `SetupWizard.qml:167-170`), so that `TextField`
      and its `text` property are never destroyed for the remaining lifetime of
      the wizard component. `wizard.passphrase` is a live binding read off
      `passphraseField.text` (`readonly property string passphrase:
      passphraseSwitch.checked ? passphraseField.text : ""`), so the secret sits
      in cleartext in a resident QML object indefinitely: through the network,
      start, and confirm steps, after `createEmbeddedIdentity` and `startNode`
      have both already consumed it, and until the wizard itself is destroyed
      by whatever hosts it (unspecified in this change — see design.md's open
      question on the entry point). Nothing in `SetupFlow.qml` (`reset()`,
      `submitIdentity`, `submitStart`) or in `SetupWizard.qml` ever assigns
      `passphraseField.text = ""`.
      **Why it matters:** this is exactly the surface CLAUDE.md flags for this
      repo — Basecamp's dev build (the one the e2e/inspector layer runs) ships
      with the QML inspector compiled in, which can read live object properties
      including `passphraseField.text`, and `QT_LOGGING_RULES` is already turned
      up for this project. A resident plaintext passphrase is available to that
      surface for the entire remainder of the session, not just for the moment
      it was needed.
      **Measured:** confirmed no `passphraseField.text = ""` (or equivalent
      clearing) anywhere in `SetupWizard.qml` or `SetupFlow.qml`. Confirmed
      neither test file (`tst_setup_wizard.qml`, `tst_setup_wizard_view.qml`)
      references `passphraseField` or asserts it is cleared after
      `submitIdentity`/`submitStart` succeed — grepped both files for
      `passphraseField`/`clearConfirmation`/`identityPassphrase` and found only
      the switch-toggle assertions, none touching the field's retained value.
      The full QML suite (`sh radicle-ui/tests/run-qml-tests.sh`, including both
      `tst_setup_wizard*.qml` files) is green with this retention in place —
      i.e. nothing would fail if the passphrase were retained even longer or
      copied elsewhere, which is the observable absence of a regression guard
      for this property.
      **Severity:** real but scoped — the passphrase is never written to a log,
      settings file, or clipboard by this diff, and the `.rep`/`radicle_impl.h`
      boundary correctly takes no home argument, so there's no cross-process or
      cross-profile leak here. The exposure is "resident in memory for longer
      than needed inside a process that has a documented in-process inspection
      surface (the QML debug inspector) in its own dev build," not "sent
      anywhere." Recommend clearing `passphraseField.text` (and disabling
      `persistentSelection`/undo history, if any) once both consuming calls
      (`submitIdentity` success, `submitStart` success) have completed, or once
      the confirm step is reached — whichever the fix author judges correct —
      and adding a regression test that fails first.

      **Fixed** in `f471999`. Your analysis of why it persists is what decided
      the fix: because `StackLayout` instantiates every child eagerly, no step
      change destroys the field, so it has to be cleared explicitly.

      Of the two moments you offered I took the first — on a `started:true`
      reply, which is when both consumers have run. Reaching confirm would have
      been later than necessary, and the whole point is minimising the window.

      It is keyed on `setupFlow.nodeStarted` via a `Connections` block rather
      than done inside the start button's `onClicked`. That matters: the
      handler runs *before* the reply, so clearing there would destroy the
      passphrase a retry needs after a refusal — turning a security fix into a
      usability bug on exactly the path where the user is already stuck.

      `test_the_passphrase_does_not_outlive_the_calls_that_use_it` is the
      regression test, and it failed first (actual `correct horse battery`,
      expected empty). It reads the field back at the start step *before*
      submitting, asserting the passphrase is still there — so it proves the
      clearing happened rather than that the field was never populated, which
      is the null-implementation trap for a test of this shape.

      Not done, and worth saying so rather than leaving it implied: I did not
      touch undo history or `persistentSelection`. `TextField` with
      `echoMode: TextInput.Password` is the input here, and the residue that
      finding names — a live `text` property the inspector reads — is what the
      clearing addresses. A deeper scrub of Qt's internal undo stack is not
      something this layer can assert, so claiming it would be a checkbox a
      test cannot back.

## Clean areas (no findings)

- **The identity-consequence-before-write ordering** is correct: the mode step
  (`stepIndex === 1`) always renders `ModePicker` — including its
  separate-identity blurb — regardless of `modeInForce`, and `canAdvance`
  keys purely off `stepIndex + 1`, so there is no code path that reaches the
  identity step (`stepIndex === 2`) without the mode step (and its statement)
  having been shown first. `createEmbeddedIdentity` cannot be issued before
  that render.
- **The `.rep` boundary's "no home argument" reasoning is respected.**
  Verified `radicle_ui.rep` and `radicle_impl.h`: neither
  `getEmbeddedIdentity()`, `createEmbeddedIdentity(alias, passphrase)`, nor
  `startNode(passphrase)` takes a home or socket parameter, and
  `SetupFlow.qml` never constructs or forwards one — it only calls the
  injected functions with `(alias, passphrase, cb)` / `(passphrase, cb)`
  exactly as the `.rep` declares. The wizard does not reintroduce the hazard
  the `.rep`'s own comment warns against.
- **The passphrase trade statement (spec's "no quiet default, no stopping
  once declined")** is implemented correctly: `passphraseSwitch.checked:
  true` is the arriving default (safer outcome without touching anything),
  and the `passphraseTrade` `Text` element carries no `visible:` binding tied
  to the switch — it renders unconditionally, so turning the passphrase off
  does not remove either half of the stated trade. Confirmed by the passing
  `test_the_trade_stays_stated_when_the_passphrase_is_turned_off` test.
- **The clipboard-bound allow line (`rad id update --allow <DID>`)** carries
  only a DID that came from a backend reply (`createEmbeddedIdentity`'s
  `nodeId` or `getCapabilities().nodeId`), never anything the view itself
  constructs from user input, so there is no way for a sandboxed QML view to
  make the copied line carry something other than the reported DID.
  `CopyableCommand`'s `command` property is copied verbatim
  (`clip.text = command`) with no interpolation of user-typed text (the
  alias and passphrase never reach this component). The verified-copy
  mechanism (`clipboardHolds`, a *separate* paste-back editor) is intact and
  its negative control (`test_the_clipboard_check_can_fail`) passes, so the
  "Copied" confirmation cannot be a false positive.
- **No `console.*` logging** of the passphrase, alias, or any reply payload
  exists anywhere in the three reviewed files.
- **`getCapabilities().canWriteLocal` vs `localAvailable`**: this wizard does
  not itself gate any write affordance on `localAvailable` — its `Create
  identity` and `Start the node` buttons are gated on `canCreateIdentity` /
  `canStartNode`, which are the wizard's own preflight-derived rules
  (`homeResolved && !identityExists`, `gitFound && !alreadyServing &&
  !startPending`), not a stand-in for the capabilities gate CLAUDE.md warns
  about. That gate governs affordances elsewhere in the app (comment/issue
  composers), which are out of scope for this diff.

## Worktree

Ready to prune at
`/home/fryorcraken/src/rad/radicle-logos-module/.claude/worktrees/rev-wiz-security`.
