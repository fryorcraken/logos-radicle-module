# Architecture review — `embedded-node-wizard`, piece 2 (hosting the setup wizard)

Scope: architecture only, per dispatch (correctness, security and readability
are held by other instances). Reviewing `git diff 90ec3b9..b802335` — the
overlay hosting, `SetupFlow`'s re-entry, and `EmbeddedState`'s `hosted` inputs.

Read: `design.md`, `specs/embedded-setup/spec.md`, `specs/embedded-state/spec.md`,
`user-flow.md` §2/§7, `Main.qml`, `SetupFlow.qml`, `EmbeddedState.qml`,
`RepoList.qml`, `SetupWizard.qml`, `tst_setup_host.qml`, `tst_setup_wizard.qml`,
`tst_embedded_state.qml`, `tst_embedded_panel.qml`, `local.yaml`, `PLAN.md`.
Verified findings by mutation with `/usr/lib64/qt6/bin/qmltestrunner -import
radicle-ui/src/qml` against `tst_setup_wizard.qml` (50 tests),
`tst_embedded_state.qml` (21 tests) and `tst_setup_host.qml` (10 tests), all
green on the unmutated tree.

`tasks.md` marks this row `[x]` from piece 1's pass; the header block says the
spec was reopened for the host and every reviewer row needs re-running — this
review is that re-run for architecture.

## Findings

- [ ] **`dev-writer`** — `Main.qml:200,320-322` and `PLAN.md:113-115` —
      "hosting a start is one property" is true for `EmbeddedState`'s
      enablement but false for `Main.qml`'s routing, and nothing ties the two
      together.
      **Scenario:** `embeddedStartHosted` is the single input that
      `EmbeddedState.actionHosted`/`actionEnabled` derive from, and `RepoList`
      passes it through unconditionally — so flipping `Main.qml:200`'s
      `embeddedStartHosted: false` to `true` alone makes the panel render an
      **enabled** "Start the node" / "Restart the node" control. But
      `takeEmbeddedAction(kind)` at `Main.qml:320-322` is `if (kind === "setup")
      openSetup();` with no branch for `"start"`/`"restart"` — so a user who
      clicks that now-enabled control gets `embeddedActionTaken("start")`
      emitted, routed into `takeEmbeddedAction`, and silently dropped. That is
      exactly the failure mode `embedded-state`'s spec names as the reason
      this whole capability exists: "A control that is enabled, looks ordinary
      and does nothing when taken is worse than no control at all… the dead
      end this capability was written to remove." `PLAN.md:113-115` states
      "Hosting them is one property… the panel needs no edit" as settled fact,
      which is the exact half-truth that would let this ship: a future
      implementer flips the one flag PLAN.md points at, runs the existing
      suite (which never arms `embeddedStartHosted` end-to-end — see below),
      sees green, and ships the dead click.
      **Measured:** `grep -n "embeddedStartHosted\|startHosted"` across
      `radicle-ui/src/qml/` shows exactly one write site
      (`Main.qml:200`) and confirms `RepoList.qml:109` passes it straight into
      `EmbeddedState.startHosted` with no second gate. `grep -n "startHosted"`
      over `tst_setup_host.qml` shows only `harness.embeddedStartHosted =
      false;` in `init()` and the two calls in
      `test_a_start_request_does_not_raise_the_setup` that assert a start
      request does *not* raise the setup while unhosted — no test in that
      file, `tst_embedded_state.qml`, or `tst_embedded_panel.qml` arms
      `startHosted = true` and then exercises `takeEmbeddedAction("start")`
      through to a routing outcome. `tst_embedded_state.qml:320,507` do arm
      `st.startHosted = true`, but only on the bare `EmbeddedState` component
      to check `actionEnabled` flips — never through `RepoList`'s signal into
      a host's `takeEmbeddedAction`. So the gap is invisible to every test
      layer that exists today, and would stay invisible after the flag flips,
      because nothing forces `takeEmbeddedAction`'s branch list to grow with
      it. The fix is the same shape `actionKind`/`actionHosted` already use one
      layer down — route `takeEmbeddedAction` on a table keyed by kind rather
      than an `if` for one kind, or at minimum have `takeEmbeddedAction` assert
      (dev build) on an unrecognised-but-enabled kind — but the concrete ask
      here is narrower: correct `PLAN.md:113-115`'s claim, or land the routing
      change in the same commit as the day the flag flips, so "one property"
      does not quietly become "one property, plus remembering the other file."
      Severity: not a bug today (`embeddedStartHosted` is `false`, so the
      branch is unreachable), but it is exactly the kind of documented-as-safe
      trap CLAUDE.md's "put the complexity in the data structure" section
      warns about — a claim of "one flip" that is actually two, with only one
      of them structurally enforced.

## What was clean

- **The overlay pattern's exclusion, for the two surfaces that exist.**
  `openSetup()` (`Main.qml:300-304`) and `toggleSettings()`
  (`Main.qml:331-338`) are two hand-written pairs (`settingsOpen = false;
  setupOpen = true` and its mirror), not a data shape that is correct by
  construction the way `stepIndex` or `epoch` are elsewhere in this same
  piece — a third overlay would need every existing raiser edited by hand to
  clear its flag too, which is the `wantRid`/`syncEpoch`-shaped risk CLAUDE.md
  warns about. But `docs/PLAN.md`'s "durable settings surface" (Phase 2 step
  4, the node-config panel) is described as an extension of the existing
  `SettingsPanel`/`settingsPane`, not a third opaque overlay — confirmed by
  `design.md:554` ("the durable settings surface", singular, referenced
  throughout as what `SettingsPanel` becomes) and no mention anywhere in
  `PLAN.md` or `design.md` of a third raised surface. Per the
  no-speculative-refactoring rule, this is not a finding: nothing concrete
  needs the general shape yet, and the two-surface hand-written exclusion is
  exactly proportionate to the two surfaces that exist and are planned.

- **The seven injected call functions are the established convention, not a
  second one.** `SettingsPanel.qml:45-46` already has `property var
  fetchSettings: null` / `saveSetting: null`, injected by `Main.qml` exactly
  the way `setupWizard`'s seven (`flow.fetchCapabilities`, `flow.fetchIdentity`,
  `flow.fetchNodeStatus`, `flow.fetchSeeds`, `flow.createIdentity`,
  `flow.startNode`, `flow.saveSetting`, at `Main.qml:1137-1158`) are. Each of
  the seven is a one-line pass-through into the pre-existing `callPlain`/
  `callSettings` helpers with no duplicated JSON-parsing or staleness logic —
  confirmed by reading the block directly. This is the same shape scaled to
  more calls, which is what a bigger flow needs, not new machinery.

- **The landing/resume rule makes the wrong version hard to write, and the
  test that proves it is the one design.md names, not the obvious one.**
  Verified by mutation: replacing `landOnFirstUnfinishedStep()`'s single
  `stepIndex = resumeIndex` with a loop that calls the equivalent of
  `advance()` step-by-step (bumping `epoch` each time) reddens **exactly one**
  test in the 50-test `tst_setup_wizard.qml` suite —
  `test_the_landing_does_not_discard_a_reply_still_in_flight` — and no other.
  `test_the_resumed_steps_findings_are_populated`, the assertion a reader would
  expect to catch this, stays green under the loop (confirmed), because the
  harness is synchronous and all three gating replies have already landed by
  the time the loop runs — exactly as design.md's "I got it wrong first"
  section describes. The mutation was reverted after the run. This is a case
  where the design shape (single assignment, epoch not bumped) makes the
  correct implementation the only one that passes, and the accompanying
  analysis of *why* the obvious test can't tell the difference is itself part
  of what makes the shape trustworthy — a future editor reading only the test
  file would reach for the loop and see it pass.

- **`hosted`-ness as a concept is an invariant by construction, one layer
  down from the finding above.** `EmbeddedState.actionHosted` (lines 246-253)
  is a pure function of `actionKind` and the two `setupHosted`/`startHosted`
  inputs — there is no per-state hard-coded "setup is enabled, start is not"
  to find and edit. The `false` defaults on both flags (documented at
  `EmbeddedState.qml:108-110`) mean a caller that forgets to wire one gets a
  named-but-disabled action rather than a silently-reachable one, which is the
  safe direction. This part of the claim holds; my finding above is that the
  claim as stated in `PLAN.md` extends one layer further than the code
  actually reaches.

- **`root.setupShown`/`root.settingsShown` read the pane's own `visible`
  consistently with the rest of the file.** `Main.qml:534-535` follows the
  same shape as `reposEmbeddedPanel` (`repoList.embeddedPanelShown`, itself
  `embeddedState.visible` in `RepoList.qml:191`) and `identityCopied`
  (`nodeIdentity.confirmShown`) — none of the test-observable properties in
  this piece recompute a copy of the flag an item is keyed on. `newIssueOpen`
  is a pre-existing pass-through outside this piece's diff and not a
  regression to flag here.

- **The reproduction in `tst_setup_host.qml` is honest about its limit, and
  structured so a divergence would at least be plausible to notice, though not
  guaranteed.** `openSetup()`, `takeEmbeddedAction()`, `toggleSettings()`, and
  the `onClosed` handler are copied into the test harness (lines 140-157,
  200-203) verbatim against `Main.qml`'s versions (lines 300-338, 1172-1175) —
  confirmed by direct line-for-line comparison; they match today. The file's
  own header (lines 5-24) and `design.md`'s "Risks/Trade-offs" section both
  name this as a reproduction rather than an instantiation, and say
  `local.yaml` is what closes the gap for the real file. Confirmed:
  `local.yaml:585-619` drives the real `embeddedStateAction` button through the
  real `Main.qml` and asserts `root.setupShown`/`root.settingsShown` on it —
  so the two layers together do cover what neither can alone. The residual
  risk (a hand-edit to `Main.qml`'s functions not mirrored in the test file)
  is exactly what the header says it is: real, acknowledged, and not something
  this review can close either, since it is the same class of gap as any
  reproduced fixture. Not a new finding — flagging as reviewed and clean given
  the acknowledgment and the `local.yaml` backstop.

## Not reviewed here

Correctness of the individual blocking/staleness rules, security of the
DID/passphrase/clipboard handling, and QML naming/readability are out of scope
for this pass — see the sibling `correctness.md`, `security.md` and
`readability.md` findings files.
