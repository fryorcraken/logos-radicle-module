# Correctness review — piece 2: hosting the setup wizard

Scope: correctness only (security, readability, architecture are other
instances' lanes), for the diff `90ec3b9..b802335` — spec commit `7a39ade` plus
implementation commit `b802335`. Piece 1 (the state panel) was reviewed
separately; this file replaces piece 1's stale correctness notes, which
referenced an earlier version of the flow (`chooseMode`, a `ModePicker`-based
mode step) not present in this diff.

Read: `specs/embedded-setup/spec.md` (six-step flow, preflight, re-entry),
`specs/embedded-state/spec.md` (the one added requirement), `design.md`'s
"the resume sets `stepIndex` once" section, `user-flow.md` §2–3,
`SetupFlow.qml`, `SetupWizard.qml`, `Main.qml`, `EmbeddedState.qml`,
`RepoList.qml`, `tst_setup_wizard.qml`, `tst_setup_host.qml`,
`tst_embedded_state.qml`, `tst_embedded_panel.qml`, `local.yaml`.

Method: read every handler in `SetupFlow.qml` for the binding-update trap and
the epoch/staleness guard, then reproduced the five mutations the dev-writer's
report named by actually applying them, running the suite, and reverting
before moving to the next. All mutations were made and reverted in this
worktree only; `git status` is clean and no mutation is left in place. Full
suite baseline (`sh radicle-ui/tests/run-qml-tests.sh`, all 31 `tst_*.qml`
files): **31 files, 533 passed, 0 failed** both before and after this review —
confirmed by summing every file's own `Totals:` line, not assumed from the
prompt's claim.

## The re-entry hazard — reproduced exactly as claimed

**Mutated `landOnFirstUnfinishedStep()` in `SetupFlow.qml` from a single
assignment into a loop over `advance()`:**

```qml
function landOnFirstUnfinishedStep() {
    while (stepIndex < resumeIndex) {
        if (!advance()) break;
    }
}
```

Ran `tst_setup_wizard.qml` (50 tests). Result: **49 passed, 1 failed** —
`test_the_landing_does_not_discard_a_reply_still_in_flight` is the only one
that reddens, with the exact failure the file's own comment predicts (`seeds`
length actual `0`, expected `2`). `test_the_resumed_steps_findings_are_populated`
— the test that restates the spec's scenario almost word for word — **stays
green** against the loop, exactly as the dev-writer's self-report claims: the
harness is synchronous, all three gating replies (`getCapabilities`,
`getEmbeddedIdentity`, `getNodeStatus`) are written before `advance()` ever
runs, and bumping the epoch on the way to `resumeIndex` discards nothing
because nothing is still in flight by then. Only the held `listKnownSeeds`
reply — the one probe that does not gate `preflightDone` — is genuinely
outstanding at the moment a real loop would move the epoch, and it is the only
thing the loop mutation actually destroys.

This is worth restating plainly for whoever reads only the tests next time:
**`test_the_resumed_steps_findings_are_populated` is not the regression guard
its name suggests.** It is a real, useful test (it pins the resumed step's
findings against a hand-walked equivalent), but it cannot fail against the one
specific defect ("landing loops instead of assigning") that this piece's
design doc calls out as the whole reason for a single assignment. The comment
block directly above the test already says this in the source
(`tst_setup_wizard.qml:1225-1240`) — so this is confirmed rather than a new
finding, and no action is needed beyond noting it held up under an independent
run.

Reverted the mutation; `SetupFlow.qml` is back to the single assignment and
the file is unmodified in git status.

## The lapsed `!startPending` proof — reproduced

**Mutated `EmbeddedState.qml`'s `actionEnabled`** from
`actionKind !== "" && actionHosted && !startPending` to
`actionKind !== "" && actionHosted`. Ran `tst_embedded_state.qml` (21 tests).
Result: **20 passed, 1 failed** — exactly
`test_an_outstanding_start_withholds_a_hosted_start_control`, and no other
test. This confirms the comment directly above `actionEnabled`
("Deleting the `!startPending` term turns
`test_an_outstanding_start_withholds_a_hosted_start_control` red") and confirms
the reasoning for why the test arms `startHosted` deliberately: with
`startHosted: false` (every other test's default), `actionEnabled` is already
`false` for every input, so a version without `!startPending` would pass every
other assertion in the file — the restrengthened test is the only one that can
see the term at all today. Reverted; file unmodified in git status.

## The other three named mutations — each reproduced, each reddens exactly one test

Applied against the `tst_setup_host.qml` harness (which reproduces `Main.qml`'s
host shape; `Main.qml`'s own `openSetup()` was diffed line-for-line against the
harness's copy and the two match exactly, so the reproduction has not
diverged for this piece):

- **Rely on `Component.onCompleted` instead of an explicit `show()` on every
  raise** (`openSetup()` drops the `setupWizard.show()` call). Ran
  `tst_setup_host.qml` (10 tests): **9 passed, 1 failed** —
  `test_raising_the_setup_restarts_the_flow`, with the exact symptom the test
  names (`currentStep` stays `"preflight"` instead of landing at `"identity"`
  on the first showing, because nothing ever called `restart()`).
- **Route every kind to `openSetup()`** (`takeEmbeddedAction(kind)` calls
  `openSetup()` unconditionally instead of gating on `kind === "setup"`). Ran
  `tst_setup_host.qml`: **9 passed, 1 failed** —
  `test_a_start_request_does_not_raise_the_setup`, which is exactly the pair
  this requirement is stated as ("a start request does not raise the setup,
  and a setup request does").
- **Drop the raise exclusion** (`openSetup()` no longer sets
  `settingsOpen = false`). Ran `tst_setup_host.qml`: **9 passed, 1 failed** —
  `test_raising_each_surface_lowers_the_other`, on the "and settings are
  lowered" assertion specifically.

All three mutations were made in the test harness file, run, observed, and
reverted; `git status` confirms `tst_setup_host.qml` is back to its original
content and no other file was touched by these three.

## Other checks made, no defect found

- **`root.setupShown`/`root.settingsShown` read the pane's `visible`, not the
  raw flags.** Confirmed in `Main.qml:534-535` — both are
  `<pane>.visible` rather than `root.setupOpen`/`root.settingsOpen` directly,
  matching the comment's stated reason (a copy of a condition agrees with the
  item whether or not it renders). `local.yaml` asserts both together in the
  steps around the setup's raise/lower, which is the layer that can actually
  see a divergence between the flag and the rendered pane.
- **Re-entrancy of `restart()`.** If `restart()` is called a second time
  before a first call's preflight has answered (e.g. the host raises the
  setup, lowers it, and raises it again quickly), `reset()` at the top of the
  second `restart()` bumps `epoch` first, so any callback still in flight from
  the first `runPreflight()` fails `isCurrent()` and cannot fire
  `onAllProbesAnsweredChanged` against the wrong showing's `resumeWanted`.
  Traced through the code; no test exercises this directly, but the mechanism
  is the same epoch guard already proven above, and no failure scenario was
  found — recorded as read-and-cleared rather than a gap, since a fourth
  `restart()`-during-`restart()` scenario would need a held-reply fixture this
  suite already has the pattern for if someone wants to add it later.
- **`submitStart`'s stale-reply branch still clears `startPending`.** Even
  when `!isCurrent(issuedAt)`, `submitStart`'s callback sets
  `flow.startPending = false` before returning (`SetupFlow.qml:606-609`).
  This is correct rather than a leak: the pending flag is local UI state about
  whether *this view* is waiting on a call, and a call issued from a step the
  user has left still needs its semaphore released or a later step's
  `canStartNode` would stay wedged. `test_a_late_reply_does_not_repopulate_a_step_the_user_left`
  passing (confirmed in the full run) shows the *data* is still correctly
  dropped; only the pending flag resolves.
- **`confirmEmbedded()`'s `refreshCapabilities()` re-entrancy.** If the step
  changes between `saveSetting`'s reply and the nested `refreshCapabilities()`
  call, the outer `isCurrent(issuedAt)` check in `confirmEmbedded`'s callback
  already returns before `refreshCapabilities()` is ever invoked, so there is
  no window where a stale `refreshCapabilities()` call is issued under the
  wrong epoch. No defect.
- **`landOnFirstUnfinishedStep()` deliberately does not bump `epoch`.**
  Confirmed by reading and by the mutation above: the function's whole
  contract is "assign once, leave the epoch where the preflight replies were
  issued" — bumping it here would have the opposite effect the fix is for,
  discarding the very seed-list reply the design doc calls out. Correct as
  written.
- **Test-count and file-count claims.** Ran `sh
  radicle-ui/tests/run-qml-tests.sh` directly (not `| tail`), captured full
  output, counted `^--- tst_` occurrences (31) and summed every `Totals:`
  line's "passed" figure (533), with 0 failed throughout. Matches the
  dev-writer's report exactly.

## Judged, not flagged

- `tst_setup_host.qml`'s honesty about its own limits (documented in its file
  header: it is a reproduction of `Main.qml`'s shape, not `Main.qml` itself,
  and the gap is closed only by `local.yaml`, which is unrun in this
  environment) is accurate and not a finding — `Main.qml`'s `openSetup()` was
  diffed against the harness's copy line-for-line and the two match for
  everything this piece touches.
- The four new `local.yaml` steps are unrun here, per the prompt's stated
  known gap. Read them for divergence from the component-level reproduction
  rather than run them; found none — the assertions on `setupShown`,
  `settingsShown`, `reposEmbeddedPanel`/`reposEmbeddedState`, and `navView`
  match what the host and the state derivation actually implement.

## Clean

The re-entry/landing logic (`restart()`, `resumeIndex`, `landOnFirstUnfinishedStep()`),
the `EmbeddedState` seven-state derivation and its ordering, the host wiring in
`Main.qml`/`tst_setup_host.qml` (raise/lower exclusion, kind-routing, restart
on show), and the `!startPending` guard in `actionEnabled` were all
independently reproduced by mutation and each reddens exactly the test the
dev-writer's report says it should, with no unexpected collateral failures and
no unexpected survivors. No new correctness defect was found in this piece
beyond what the report already surfaces.
