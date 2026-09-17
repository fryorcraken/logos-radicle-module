# Correctness review — `embedded-node-wizard`

Scope: correctness only (security, readability, architecture are other
instances' lanes). Covers `SetupFlow.qml`, `SetupWizard.qml`,
`CopyableCommand.qml`, `ModePicker.qml` (read as a dependency of the mode
step), `tst_setup_wizard.qml`, `tst_setup_wizard_view.qml`.

Method: read every handler for the binding-update trap and the epoch/staleness
guard, then broke the code on purpose (`isCurrent()` forced to always return
`true`, the `refreshCapabilities()` call deleted from `chooseMode()`, the
`ModePicker` blurb `Text` blanked, a benign reword of `networkInbound`'s text)
and re-ran the suite each time, plus one throwaway scratch test (written to
`tmp/`, deleted afterwards, never committed) to reproduce the double-start
finding directly. Full suite baseline: `sh
radicle-ui/tests/run-qml-tests.sh` green before and after this review, all
mutations reverted, working tree clean.

- [x] **`dev-writer`** — `SetupFlow.qml:358-372` (`chooseMode`) — the success
      path that re-reads capabilities after a mode write has no test.
      **Scenario:** `chooseMode("embedded")` is called against a backend that
      accepts the write. The real code path is: `saveSetting` succeeds →
      callback calls `flow.refreshCapabilities()` → a fresh `fetchCapabilities`
      call updates `modeInForce`. No test exercises this chain end to end;
      `test_only_embedded_continues_the_flow` calls `flow.refreshCapabilities()`
      **directly**, bypassing `chooseMode` entirely, and
      `test_a_refused_mode_write_does_not_move_the_mode_in_force` only covers
      the refusal branch, which returns before reaching the `refreshCapabilities()`
      line.
      **Measured:** deleting the `flow.refreshCapabilities();` line from
      `chooseMode`'s success branch (replacing it with a comment) leaves all 34
      `tst_setup_wizard.qml` tests green. This is exactly the shape CLAUDE.md
      warns about — a fake or test suite that cannot tell "reloaded" from
      "never reloaded" — applied to the one write path in this file that isn't
      already covered by an equivalent state check.

      **Fixed** in `f471999`:
      `test_a_successful_mode_write_persists_it_and_re_reads_in_force` now
      drives `chooseMode` on its success path. Your exact mutation —
      `flow.refreshCapabilities()` replaced with `flow.modeInForce = mode` —
      reddens it, verified before the fix landed.

      The assertion is built so trusting the argument cannot pass it. A new
      fake property `capabilitiesMode` lets `getCapabilities()` report a mode
      *different* from the one `setSetting` was handed, so the backend accepts
      the write and keeps reporting `local` while the flow asked for
      `embedded`. A flow re-reading capabilities says `local`; one recording
      its own copy says `embedded`. The test also asserts the call log carries
      both `setSetting:mode:embedded` and a `getCapabilities`, and closes with
      the other direction — a backend that *does* report the new mode must
      move `modeInForce`, without which a flow that never updated it at all
      would pass the first assertion.

      Found independently by `spec-test.md`; same fix answers both.

- [x] **`dev-writer`** — `SetupFlow.qml:193-194` (`canStartNode`) — the start
      control is not withdrawn after a successful start, so a second
      `startNode` call can be issued over a running node.
      **Scenario:** advance to the start step, call `submitStart("pw")`
      against a backend that replies `started:true`. `flow.nodeStarted` is now
      `true`, but `flow.canStartNode` is still `true` — `alreadyServing` (the
      only thing besides `gitFound`/`startPending` that gates it) is never
      updated by a successful start or by `refreshNodeStatus()`, which only
      writes `nodeServing`. The rendered `startNode` Button in
      `SetupWizard.qml:493-498` stays enabled, so a user can click "Start the
      node" again and start a second node over the first — the exact failure
      the spec names identity creation and node start as both needing to
      guard against ("a step that has performed one MUST report what it did
      when it is returned to, rather than offering to do it again";
      `startBlockedReason` even names "starting a second one would contend for
      it" for the *pre-flight-detected* case, but the same contention is
      reachable through the wizard's own start button after its own
      successful start).
      **Measured:** confirmed directly with a throwaway scratch TestCase
      (written to `tmp/`, run, then deleted — never committed): after
      `submitStart("pw")` succeeds, `flow.nodeStarted === true` and
      `flow.canStartNode === true` simultaneously. No test in
      `tst_setup_wizard.qml` or `tst_setup_wizard_view.qml` asserts
      `canStartNode` (or the rendered button's `enabled`) after a successful
      start — `test_returning_to_a_step_that_acted_does_not_offer_to_act_again`
      covers only the identity step's equivalent case, not start's.

      **Fixed** in `f471999`. Confirmed your reproduction first:
      `test_a_successful_start_withdraws_the_start_control` failed with
      `canStartNode` actual `true`, expected `false`, against the unfixed code.

      The fix is the data shape rather than a fourth clause on `canStartNode`.
      `alreadyServing` is now written by *every* reading of the node's state —
      the preflight's, `submitStart`'s success path, and every later
      `refreshNodeStatus()` — because a node this flow started and one it found
      already running are the same fact about the socket. Adding
      `&& !nodeStarted` instead would have been a second answer to a question
      already asked, and would then have needed a fifth clause to re-offer the
      control for the node-whose-threads-died case, which falls out free here.

      Two writes, and removing either reddens the test: the one in
      `submitStart` covers the window before the status refresh replies, the
      one in `refreshNodeStatus` keeps it current after.

      One thing your scratch TestCase could not have seen, which surfaced while
      fixing it: the fake's `start()` did not set `serving`, so it modelled a
      backend reporting `started:true` while `getNodeStatus` kept saying
      `serving:false` — a state the real backend cannot produce, since
      `startNode` returns only once the control socket answers. The fake now
      sets it, and `fake.reset()` clears it since it became mutable state.

      The test's second half is the guard against over-fixing: a start that
      *failed* must leave the control offered, since retrying is the correct
      response to a refusal. Without it, a flow withdrawing the control
      unconditionally would pass.

- [x] **`dev-writer`** — `SetupWizard.qml:623-661` (`component Finding`) +
      `SetupWizard.qml:206-226` (the identity `Finding`) — a genuine
      `getEmbeddedIdentity().problem` sentence can never be displayed for the
      identity preflight finding.
      **Scenario:** a backend reports `exists:false` together with a
      non-empty `problem` (a real probe failure distinct from "no identity
      yet" — e.g. a permissions error reading the identity store, which is
      exactly the kind of finding the spec requires named: "A finding that
      failed MUST name what failed. Where the backend supplied a sentence —
      `gitProblem`, `pathsProblem`, or `getEmbeddedIdentity().problem` — that
      sentence MUST be displayed verbatim"). The identity `Finding` in
      `SetupWizard.qml` is wired `neutral: true`, and `Finding`'s own outcome
      text is `parent.neutral || parent.ok ? parent.okText : parent.failText`
      — because of the `||`, `neutral: true` makes `failText` (which carries
      `setupFlow.identityProblem`) permanently unreachable, regardless of
      whether `identityProblem` is empty or not. The wizard shows "No identity
      exists here yet." even when the backend supplied a distinct diagnostic
      sentence.
      **Measured:** traced from the `Finding` ternary directly (ternary logic
      is unconditional, not input-dependent, so no mutation was needed to
      demonstrate it — `neutral: true` alone proves `failText` dead for this
      instance). Confirmed no existing test exercises a non-empty
      `identityProblem` at the view layer: `tst_setup_wizard_view.qml` has no
      test naming `identityProblem` or `findingIdentity`'s failure text, and
      `tst_setup_wizard.qml`'s only assertion on the field
      (`test_no_identity_yet_is_not_reported_as_an_empty_home`) checks the
      **state** object's `flow.identityProblem` value, never what the screen
      renders from it.

      **Fixed** in `f471999`. Your trace is right, and the root cause is that
      one flag was carrying two meanings. `neutral` is a statement about how an
      *absence* is reported — "no identity yet is not a failure" — and it was
      being read as "this probe cannot fail", which are different claims. The
      identity probe absolutely can fail; a permissions error reading the
      identity store is exactly the case.

      They are now separate. `Finding` gains
      `readonly property bool failed: neutral ? failText !== "" : !ok`, and the
      outcome reads `parent.failed ? failText : okText`. A neutral finding
      fails exactly when it was given a sentence to show. Colour follows the
      same property, so a genuine diagnostic renders in `Theme.bad` rather than
      neutral body text.

      `test_a_neutral_finding_still_shows_a_backend_problem` covers it at the
      view layer, which is where you noted no test reached: it drives a backend
      replying `exists:false` with a non-empty `problem` and asserts the
      rendered `findingOutcome` text equals that sentence verbatim. Weakening
      `failed` to `neutral ? false : !ok` — i.e. restoring the bug — reddens
      it, verified. Its second half asserts an empty home with no problem still
      reads "no identity exists here yet", so a finding stuck on `failText`
      cannot pass either.

- [x] **`tester`** — `tst_setup_wizard_view.qml:157-181`
      (`test_the_mode_step_states_the_separate_identity_consequence`) — the
      dev-writer's own stated low-confidence area, confirmed real: the
      assertion reads `picker.modes[i].blurb` (the QML component's data
      array), never a rendered `Text` element, so it cannot fail if
      `ModePicker` stops rendering the blurb at all.
      **Scenario:** the embedded mode's blurb paragraph — the one sentence
      the spec requires stated at the mode step, before any identity is
      created — silently stops being drawn on screen (e.g. an edit deletes
      the `Text` binding, or sets `visible: false`, or the row's `Column`
      loses that child). The picker's `modes` array is untouched, so the
      test still reads the correct blurb string from data that was never
      displayed.
      **Measured:** blanking the rendered blurb `Text`'s `text` to `""` in
      `ModePicker.qml` (`text: parent.parent.modelData.blurb` →
      `text: ""`) leaves all 15 `tst_setup_wizard_view.qml` tests green,
      including this one. Mutation reverted; working tree confirmed clean
      afterward. No other test in the suite (including `ModePicker`'s own
      `tst_settings.qml` coverage) asserts on the rendered blurb text either,
      so this consequence statement has no test that can see it stop being
      drawn.

      **Fixed** in `f471999` by `dev-writer` rather than routed to `tester`:
      the test could not be fixed without a source change, since `ModePicker`'s
      blurb `Text` carried no `objectName` and so was unreachable from a test.
      It now carries `modeBlurb_<key>`, and
      `test_the_mode_step_states_the_separate_identity_consequence` asserts on
      the rendered `text` (and `visible`) of `modeBlurb_embedded`, with the
      negative half reading `modeBlurb_local` the same way.

      Your exact mutation — `text: parent.parent.modelData.blurb` → `text: ""`
      — now reddens it: *"the embedded option must state that it is a separate
      identity, got: "*. `tst_settings.qml`, which covers `ModePicker`'s other
      consumers, stays green with the added `objectName`.

      Recorded in `design.md` under the `ModePicker` reuse decision, since the
      general point outlives this test: an assertion read off the input data
      cannot distinguish "rendered" from "never rendered", which is this
      repo's fake-returning-the-same-thing lesson in a second form.

## Judged, not flagged (the two areas the dev-writer invited disagreement on)

- **`test_the_mode_step_states_the_separate_identity_consequence` asserting on
  `ModePicker.modes` rather than rendered text** — confirmed as a real gap
  above (ticked as a `tester` finding), not merely a style question: the
  scenario it would miss (a shipped ModePicker that renders nothing) is
  concretely reachable and the mutation reproduces it directly.
- **The view tests asserting substantive clauses rather than whole
  sentences** — checked this is not hiding a wording regression by rewording
  `networkInbound`'s text while preserving its two substantive clauses
  (`"no inbound"`, `"cannot fetch from this node"`); the assertions are
  correctly keyed on substance, not brittle on exact wording. No finding here.
- **`test_an_unanswered_mode_does_not_advance`, and fixing the two tests that
  walked the sequence without running the preflight rather than changing
  `canAdvance`** — checked against the spec text directly: "Advancing past the
  mode step MUST require that the mode in force... is `embedded`." An
  unanswered mode is `""`, not `"embedded"`, so `canAdvance` returning `false`
  before the preflight answers is the spec-correct behaviour, not a
  convenient reading. Fixing the two tests (not the code) was the right call;
  changing `canAdvance` to tolerate an empty mode would have been the actual
  bug.

## Clean

The `epoch`/`isCurrent()` staleness guard itself is sound and is exercised
correctly: forcing `isCurrent()` to always return `true` reddens exactly
`test_a_late_reply_does_not_repopulate_a_step_the_user_left` and nothing else,
with the positive twin (`test_a_reply_arriving_on_the_same_step_does_land`)
staying green — the guard is real, not decorative, and one file's worth of
coverage catches its removal precisely. `advance()`/`back()` correctly bump
the epoch on every step change, so no cross-step binding-read trap of the
`RepoView.onBranchChanged` shape was found: every handler that changes a
property either reads a fresh reply directly or issues a new fetch rather
than reading a stale binding synchronously. `CopyableCommand`'s
copy-then-verify round trip is sound as designed (a separate paste-back
editor, cleared either way). `Finding`'s "checking…" unanswered state and the
four separately-keyed blocking rules (`canCreateIdentity` /
`createBlockedReason`, `canStartNode` / `startBlockedReason`) match the spec's
requirement that findings never collapse into one verdict, and the git/home/
serving/exists findings are independently triggerable per the tests that
already cover them.
