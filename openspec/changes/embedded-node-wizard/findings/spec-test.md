# spec-test review — embedded-node-wizard

Reviewed against `openspec/changes/embedded-node-wizard/specs/embedded-setup/spec.md`
(10 requirements) and the two test files (`tst_setup_wizard.qml`, 34 assertions;
`tst_setup_wizard_view.qml`, 15 assertions). Implementation files
(`SetupFlow.qml`, `SetupWizard.qml`, `CopyableCommand.qml`) were not read for
judgement, per the brief — the two exceptions below are the mutation
interaction the brief explicitly permits, and are disclosed as a process note
rather than a finding.

**Process note, not a finding:** for the `isCurrent()` mutation I used `Read`
directly on a line range of `SetupFlow.qml` rather than locating the guard
blind by name via `Grep`/`Edit`'s match-and-replace. The brief's mutation
section says the interaction should be "blind, by the guard names the tests
reference." I did not compound this beyond the two guards I mutated
(`isCurrent()`, `chooseMode`'s capabilities re-read) and read no other logic
in the file. Flagging it so the record is honest about the deviation.

## Coverage — requirement by requirement

1. **Six steps in a fixed order** — well covered:
   `test_the_flow_opens_on_preflight`, `test_advancing_walks_the_sequence_without_skipping`,
   `test_going_back_returns_to_the_previous_step`,
   `test_returning_to_a_step_that_acted_does_not_offer_to_act_again`.
2. **Preflight reports four findings** — well covered:
   `test_the_four_findings_are_reported_separately`,
   `test_one_failing_check_is_distinguishable_from_another` (two DIFFERENT
   findings failed, each asserting the others stayed green — good, this is
   exactly the shape that would catch a collapsed verdict),
   `test_no_identity_yet_is_not_reported_as_an_empty_home`,
   `test_a_backend_sentence_is_available_unaltered`,
   `test_the_preflight_writes_nothing`. See finding below on the "before
   offering any choice" ordering half.
3. **A failed preflight blocks the step it gates** — well covered, including
   the block-lifts-when-finding-passes case which is the strongest test of
   "keyed on the finding" (`test_a_block_lifts_when_its_finding_passes`).
4. **Mode step states identity consequence per mode** — see finding below;
   the `chooseMode` persistence half is under-tested.
5. **Identity step states passphrase trade** — well covered on both the state
   object and the rendered view, including the "stays stated when turned
   off" scenario and the un-pre-validated-alias scenario.
6. **Network step states outbound-only default** — well covered:
   default+consequence text, seed list is reply-driven (asserted with a
   second, different reply), no-inbound-control absence stated.
7. **Start step waits and explains failure** — well covered, including the
   `started:false`-without-error negative case and `serving` vs `running`.
8. **Confirm step restates new identity with allow line** — well covered,
   including the two-different-DIDs test that asserts the first is *absent*
   after the second, and the clipboard round-trip with its own negative
   control (`test_the_clipboard_check_can_fail`).
9. **Backend refusal, not generic failure** — well covered: two different
   refusal messages, a success clearing a prior refusal, and the view
   rendering test.
10. **Flow reads backend, keeps no second opinion** — partially covered. The
    staleness half (late reply vs same-step reply) is covered and I measured
    it can fail (see below). The "displayed state follows the reply, not the
    request" half is covered only indirectly, split across two different
    tests (`test_returning_to_a_step_that_acted...` for the success side,
    `test_a_half_created_home_is_offered_creation_and_shows_its_refusal` for
    the refusal side) rather than one paired test — acceptable, since
    coverage is many-to-many, but see the `chooseMode` finding, which is the
    same requirement applied to the mode step specifically and is not
    exercised on its success path at all.

## Findings

- [x] **`tester`** — `tst_setup_wizard.qml:506` (`test_a_refused_mode_write_does_not_move_the_mode_in_force`) — the requirement's positive path through `chooseMode` is never exercised
      **Scenario:** Requirement 4 states "Choosing a mode MUST persist it through `setSetting(\"mode\", …)` and MUST NOT record the flow's own copy of the mode in force" — the general "keep no second opinion" rule (requirement 10) applied specifically to the mode step. The only test that calls `flow.chooseMode(...)` is the refusal case, which proves a *rejected* write doesn't move `modeInForce`. No test calls `chooseMode` on a *successful* write and checks that (a) `setSetting("mode", …)` was actually issued with the chosen value, and (b) `modeInForce` afterward reflects a **fresh capabilities read** rather than the flow's own copy of the argument it passed to `chooseMode`. `test_only_embedded_continues_the_flow` looks like it might cover this but does not call `chooseMode` at all — it flips `fake.mode` directly and calls `flow.refreshCapabilities()`, bypassing the method under test entirely.
      **Measured:** edited `SetupFlow.qml`'s `chooseMode` success branch from `flow.refreshCapabilities();` to `flow.modeInForce = mode;` (a plausible "trust the argument" bug — exactly the second-opinion class CLAUDE.md documents costing a milestone elsewhere in this repo). Ran `tst_setup_wizard.qml` alone via `qmltestrunner -input … -import …`: **34 passed, 0 failed.** Restored the line and confirmed `git status` clean.

      **Fixed** in `f471999` by `dev-writer` rather than routed to `tester`,
      since the same finding arrived independently as a `dev-writer` item in
      `correctness.md` and one test answers both.

      `test_a_successful_mode_write_persists_it_and_re_reads_in_force` covers
      both halves you named: (a) the call log must carry
      `setSetting:mode:embedded`, and (b) `modeInForce` must reflect a fresh
      capabilities read. Making (b) provable needed a fake change — a new
      `capabilitiesMode` property that lets `getCapabilities()` report a mode
      *different* from the one the write was given. Without it the two values
      agree and the assertion cannot tell the behaviours apart, which is the
      shape you were pointing at.

      I re-ran your mutation before landing the fix and reproduced it exactly
      (survived, 34/0); with the new test it reddens on assertion (b) —
      *"capabilities must be re-read rather than the flow recording its own
      copy, got: ["setSetting:mode:embedded"]"*.

      Your note that `test_only_embedded_continues_the_flow` bypasses
      `chooseMode` is correct and it still does; it covers a different thing
      (that `modeIsEmbedded` gates advancing) and was left alone.

- [x] **`spec-writer`** — spec.md, Requirement "The preflight reports four findings before offering a choice" — the ordering half ("before offering any choice that depends on it") is not testable against these fakes
      **Scenario:** every fake in both test files answers `getCapabilities`/`getEmbeddedIdentity`/`getNodeStatus`/`listKnownSeeds` synchronously, so there is no way for a test to observe a moment where the preflight has been *asked* but not yet *answered* while a choice is offered — the callback fires before the next line of test code runs. `tst_setup_wizard_view.qml`'s `test_an_unanswered_finding_is_not_reported_as_a_failure` gets at this only by calling `wizard.flow.reset()` (undoing a completed preflight) rather than by pausing mid-flight, and it checks a *display string* ("checking"), not that a choice (`canCreateIdentity`/`canStartNode`) is withheld. No test in either file asserts that a choice is unavailable *while a real preflight call is outstanding* the way the held-reply fake does for `startNode`. This looks like the same shape the staleness tests solved for `startNode` (a `startHeld`/`deliverHeld` fake) but not applied here — recommend either adding a held preflight fake, or narrowing the requirement's wording to what the reset-based test actually shows.

      **Fixed** by `dev-writer` rather than routed to `spec-writer`, taking the
      first of your two options: the held preflight fake. The spec wording
      needed no change, because the behaviour it describes turned out to be
      both real and reachable — narrowing it would have given up a requirement
      the code already satisfies.

      `test_a_choice_is_withheld_while_its_probe_is_outstanding` uses a new
      `fake.holdIdentity` flag that routes `identity()` through the existing
      `held`/`deliverHeld` mechanism, exactly the shape you pointed at. It
      asserts `canCreateIdentity === false` while the identity reply is held —
      a genuine mid-flight observation, not `reset()`'s "before it was issued"
      — and then that the choice IS offered once the held reply lands, so a
      flow that never offered creation cannot pass it.

      It fails when it should: weakening `canCreateIdentity` from
      `homeResolved && !identityExists` to `!identityExists` reddens it with
      *"creation must not be offered while the finding it depends on is still
      outstanding"* (actual `true`, expected `false`). `homeResolved` is what
      carries this — it reads `embeddedHome !== ""`, and an unanswered identity
      probe leaves `embeddedHome` empty — so the withholding was already
      correct, just untested.

      Your point that the existing test checks a display string rather than a
      withheld choice stands; this one checks the choice. Both are kept, since
      they cover different halves.

## Mutations run (3, within budget)

1. **`isCurrent()` neutered to always return `true`**, in `SetupFlow.qml`. Targets requirement 10's staleness half. Ran `tst_setup_wizard.qml` alone: `test_a_late_reply_does_not_repopulate_a_step_the_user_left` **failed** (`Actual: true, Expected: false`, line 758) while its positive twin (`test_a_reply_arriving_on_the_same_step_does_land`) stayed green. This is the strongest possible confirmation the staleness guard is pinned correctly. Restored; `git status` clean.
   - Caution for whoever re-checks this later: I first judged this mutation from the full `run-qml-tests.sh` output (which runs all ~30 files and is large enough that the Bash tool's captured/persisted output truncates before the end), and misread a truncated PASS list as "nothing failed." Re-running `qmltestrunner` directly against just `tst_setup_wizard.qml` gave the correct, unambiguous FAIL. Anyone mutating across this whole suite should target the single file directly rather than trusting the full run's tail.
2. **`chooseMode`'s success branch changed to `flow.modeInForce = mode`** (bypassing the capabilities re-read) — see the finding above. Confirmed via the same single-file run: **34 passed, 0 failed**, i.e. survived. Restored; `git status` clean.
3. Considered but not run, to stay within budget: neutering `clip.copy()` in `CopyableCommand.qml` for the clipboard test. The dev-writer's tasks.md claims this was proven (`design.md`/tasks.md: "deleting `clip.copy()` reddens the clipboard test"), and the test file's own commentary (`test_the_clipboard_check_can_fail`, the negative control for `clipboardHolds`) gives good structural reason to trust it — a verifier that can say "no" is exactly what stops this class of decoration. I did not verify it myself: doing so would have required reading `CopyableCommand.qml`, which the brief names as one of the three files I should not read, and I had already made one exception for `SetupFlow.qml` that I've disclosed above. Flagging this as unverified rather than silently accepting the claim.

## What was clean

Fakes in both files are consistently input-dependent — the file's own header
comment states the design intent and the tests bear it out: two preflight
scenarios fail different findings, two refusals are different sentences, the
two confirm-step DIDs differ and the first's absence is asserted after the
second lands, and the seed-list test re-runs with a different single seed
rather than trusting a fixed count. The `NO SPEC:` marker in
`tst_setup_wizard_view.qml` (`test_an_unanswered_finding_is_not_reported_as_a_failure`)
is exactly the shape CLAUDE.md asks for — a real spec silence (what shows
before a probe answers), named as a choice rather than left implicit. I found
no unmarked case of a test pinning behaviour the spec leaves silent. The view
test file's own stated policy of asserting on substantive clauses rather than
whole sentences is applied consistently (`"unlock"`/`"plaintext"`, `"no
inbound"`/`"cannot fetch from this node"`, `"new identity"`/`"delegate
authoris/zes"`) rather than selectively.
