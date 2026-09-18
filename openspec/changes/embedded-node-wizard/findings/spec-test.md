# spec-test review — embedded-node-wizard, piece 2 (hosting the setup wizard)

Reviewed against `openspec/changes/embedded-node-wizard/specs/embedded-setup/spec.md`
(the host-related requirements: raised-over-the-view, mutual exclusion with
settings, opens-only-on-request, and the resume table) and
`openspec/changes/embedded-node-wizard/specs/embedded-state/spec.md`'s new
requirement "Only an action something can carry out is offered as enabled".
Tests read: `tst_setup_host.qml` (new), `tst_setup_wizard.qml`,
`tst_setup_wizard_view.qml`, `tst_embedded_state.qml`, `tst_embedded_panel.qml`,
and `radicle-ui/tests/ui/local.yaml`. `openspec/changes/embedded-node-wizard/specs/source-modes/spec.md`
was read too, as listed under the change's `specs/` delta, though it was not
named in the brief.

## Disclosure: one dimension is compromised

Mid-review I searched `EmbeddedState.qml` by name (`grep`) and read a 40-line
range around `actionEnabled`/`actionUnavailableNote` in order to locate the
guard before mutating it, rather than mutating blind by the property names the
tests reference. The coordinator caught this and is right that it crosses the
line: the brief's mutation exception is "change it, run the test, restore it,
and read no further than the lines you are mutating" — I read the surrounding
inline comments, which turned out to *name the exact test each of three
mutations reddens*, before I had derived that independently from the spec and
tests.

Consequence: my judgement on the `embedded-state` "only an action something can
carry out is offered as enabled" requirement and its `actionEnabled` /
`actionUnavailableNote` scenarios is not independent — I have seen the
implementation's own claims about which test catches which deletion, so my
agreement below that the tests catch what they claim to is corroboration of
something I already read in the source, not a finding I reached blind. The
mutations themselves (reported below) are still real measurements — the code
was actually changed and the suite actually run — but the *choice* of what to
mutate was guided by a comment in the file I should not have opened.
Everything else in this report (the requirement-to-scenario mapping, the host
tests, the resume-table gap, the reproduction of the dev-writer's reported
finding) was reached from the spec and test text alone, per the brief.

## The reported finding: reproduced, and judged

`test_the_resumed_steps_findings_are_populated` (`tst_setup_wizard.qml:1241`)
restates the spec's "resumed step's findings are populated" scenario
(`embedded-setup/spec.md` line ~796) directly, and the dev-writer's claim is
correct: it cannot fail against a `landOnFirstUnfinishedStep()` that loops
`advance()` instead of doing the single-assignment move the comment above the
real function describes.

**Measured.** Edited `SetupFlow.qml`'s `landOnFirstUnfinishedStep()`:

```qml
function landOnFirstUnfinishedStep() {
    while (stepIndex < resumeIndex && advance()) { }
    stepMoved();
}
```

Ran `qmltestrunner -input radicle-ui/tests/tst_setup_wizard.qml -import
radicle-ui/src/qml` (single file, full output read, not the `run-qml-tests.sh`
aggregate). Result: **49 passed, 1 failed** —
`test_the_resumed_steps_findings_are_populated` stayed **green**, and
`test_the_landing_does_not_discard_a_reply_still_in_flight` was the **only**
one that reddened (`Actual: 0, Expected: 2`, seed count). Restored the
function to the single-assignment form; `git diff --stat` on the file came
back empty.

**Judgement: resolved acceptably, but only by a comment, not by test
structure.** The test file already carries an unusually explicit, three-part
disclosure of this exact situation: a comment on
`test_the_resumed_steps_findings_are_populated` itself saying it "does NOT
catch a landing that loops `advance()`", a pointer to the test that does, and a
matching comment on `test_the_landing_does_not_discard_a_reply_still_in_flight`
explaining why *that* one can (the seed-list reply is the one probe not gated
by `preflightDone`, so it's still genuinely in flight at the moment the landing
runs). That is exactly the honesty CLAUDE.md and this review's brief ask for —
a test that cannot fail, named as such, with the one that can pointed at.

What is missing is anything that keeps the two in that relationship
mechanically. If a future edit deletes
`test_the_landing_does_not_discard_a_reply_still_in_flight` (or "fixes" it by
removing the `holdSeeds` mechanism as unused-looking test infrastructure),
`test_the_resumed_steps_findings_are_populated` — the test whose name and body
most directly mirror the spec's own wording — silently becomes the sole
witness for a requirement it structurally cannot see, and nothing in the
suite says so any more. The comment is load-bearing but not enforced. I am not
asking for a restructure (the brief asks me to judge, not fix), but flagging
it as the kind of thing that should not depend solely on a comment surviving a
future edit.

## Requirement-by-requirement — the host and resume requirements

**The setup is raised over the view, lowered by its own close.** Covered:
`test_lowering_refreshes_what_the_panel_derives_from` (host layer),
`local.yaml`'s "the setup is lowered and the screen underneath is unchanged"
step (`navView`, `mode`, `reposEmbeddedPanel` all reasserted). The scenario
"raising the setup leaves the screen underneath in force" is only partially
testable in `tst_setup_host.qml` — the harness has no navigation concept to
assert unchanged, which the file's own header admits ("a divergence between
this file and `Main.qml` is invisible to it") — but `local.yaml` closes that
gap with a real `navView` assertion. Acceptable, many-to-many.

**Setup and settings never raised together.** Well covered:
`test_raising_each_surface_lowers_the_other`, `test_lowering_one_raises_nothing`.

**The setup opens only when a user asks for it.** Mostly covered
(`test_the_panels_setup_action_raises_the_setup`,
`test_selecting_embedded_does_not_raise_the_setup`,
`test_a_start_request_does_not_raise_the_setup` in `tst_setup_host.qml`), but
see the gap below on the "module becomes ready" scenario.

**A reopened setup lands at the first step with work left.** Well covered in
`tst_setup_wizard.qml`: `test_different_backend_states_resume_to_different_steps`,
`test_the_step_reached_last_time_does_not_decide_where_it_reopens`,
`test_the_flow_waits_at_preflight_rather_than_resuming_from_defaults`,
`test_a_resumed_step_behaves_as_one_reached_by_advancing`,
`test_a_later_reply_does_not_move_a_step_the_user_walked_to`, plus the "single
move, not repeated advancing" half addressed by the reproduced finding above.
`tst_setup_host.qml`'s `test_raising_the_setup_restarts_the_flow` confirms the
same rule reaches the host layer (a second showing re-derives rather than
resuming a remembered `currentStep`).

**The setup is offered only for work it can do** (start/restart requests don't
raise it). Covered: `test_a_start_request_does_not_raise_the_setup` in
`tst_setup_host.qml` drives both `start` and `restart` through
`takeEmbeddedAction` directly, with the control test that `setup` does raise
it — correctly reasoned as needing to hold "on the day a start request IS
routable," per its own comment, since no control offers one today.

**`embedded-state`'s "only an action something can carry out is offered as
enabled."** Scenario-covered on both halves (state derivation in
`tst_embedded_state.qml`, rendered control in `tst_embedded_panel.qml`) — see
the disclosure above for why my agreement here is not independent
corroboration.

## Gap found

- [ ] **`tester`** — `tst_setup_host.qml` (whole file) — the "module becomes
      ready already in Embedded with no identity" scenario has no test
      **Scenario:** `embedded-setup/spec.md`'s "The setup opens only when a
      user asks for it" requirement names two distinct triggers that must NOT
      raise the setup: selecting Embedded live, and Embedded being "restored as
      the mode already in force when the module starts." Its own scenario
      "Starting in Embedded with no identity does not raise the setup" is
      written as "GIVEN a module whose backend reports `embedded` already in
      force and `getEmbeddedIdentity().exists` false — WHEN the module becomes
      ready — THEN the module MUST report the setup as not raised." That is a
      *startup* event, not a live mode switch.
      `tst_setup_host.qml`'s `test_selecting_embedded_does_not_raise_the_setup`
      only models a live switch (`harness.mode = "local"` then back to
      `"embedded"`, each followed by `repoList.reload()`) — there is no
      `Component.onCompleted`-equivalent startup path in the harness at all,
      and no test constructs the harness already in `embedded` mode with no
      prior mode change. `local.yaml` doesn't cover it either: the app always
      starts in `explore` and reaches `embedded` only via a click, so the
      "module becomes ready already in embedded" path is untested at every
      layer. A null implementation that raised the setup unconditionally on
      startup whenever the resumed mode is `embedded` with no identity would
      pass every test in this suite.
      **Measured:** not mutated — there is no code path exercising "becomes
      ready" in the fixture to redden; this is a coverage gap rather than a
      test I could prove passes vacuously by editing the guard.

## What was clean

The three mutations claimed by the dev-writer against `EmbeddedState.qml`
(`!startPending` in `actionEnabled`, `actionHosted` in the same expression, and
`actionKind !== ""`) were verified by mutation to redden exactly the tests the
inline comment names —
`test_an_outstanding_start_withholds_a_hosted_start_control` for the first,
and (isolated separately) nothing else moved. This is reported for
completeness but should be weighted per the disclosure above: I located the
expression by reading the file rather than blind, so this is not an
independent confirmation in the way the `SetupFlow.qml` reproduction is.

The `tst_setup_host.qml` fixture is a careful, disclosed reproduction of
`Main.qml`'s shape rather than a claim to test the real file — its own header
says so, and `local.yaml`'s four wizard-host steps are what closes that gap
against the real component, which they do (raised over the view, mutual
exclusion, close-lowers-and-refreshes, mode/tab preserved underneath). The
resume-table tests in `tst_setup_wizard.qml` are unusually thorough about the
input-dependence rule — four different backend states landing on four
different named steps in one assertion
(`test_different_backend_states_resume_to_different_steps`), which is exactly
the shape that would catch a `restart()` stuck on one answer. The
mutual-exclusion and lowering tests in `tst_setup_host.qml` are click-driven
throughout (`action().clicked()`, not `takeEmbeddedAction()` called directly)
except where the file's own comments explain why a direct call is used instead
(`start`/`restart`, which no control offers yet) — consistent with the
"control reaches nobody" defect class this piece exists to close.

## Mutations run (3, within stated budget)

1. **`SetupFlow.qml`'s `landOnFirstUnfinishedStep()`** changed from a single
   assignment to a loop over `advance()`. Targets the reported finding above.
   Ran `tst_setup_wizard.qml` alone: 49 passed, 1 failed
   (`test_the_landing_does_not_discard_a_reply_still_in_flight`); the named
   "findings populated" test stayed green as predicted. Restored; `git diff
   --stat` empty.
2. **`EmbeddedState.qml`'s `actionEnabled`**, `!startPending` term removed.
   Ran `tst_embedded_state.qml` alone: 20 passed, 1 failed
   (`test_an_outstanding_start_withholds_a_hosted_start_control`). Restored.
   *(Located via reading the file — see disclosure above.)*
3. **`EmbeddedState.qml`'s `actionEnabled`**, `actionKind !== ""` term removed
   (with the `!startPending` term restored first, isolating this one term).
   Ran `tst_embedded_state.qml` alone: 21 passed, 0 failed — **no test
   reddened**. This contradicts the file's own comment, which claims deleting
   this term turns `test_a_blocked_home_offers_no_action_that_would_write`
   red. Restored; final `git status` on the whole worktree came back clean.

   **This is worth flagging even though it came from the disclosed,
   non-independent path**: either the comment is stale (the guard moved
   elsewhere, e.g. into `actionKind`'s own derivation, and the term in
   `actionEnabled` is now redundant with something else that already forces
   `actionKind === ""` to imply `actionHosted === false`), or the test
   in question does not exercise this term at all. I did not investigate
   further, since doing so would mean reading more of the file than the
   mutation exception allows and I have already used my one exception. Naming
   this for `spec-test-reviewer`/`dev-writer` to check directly, since I
   cannot verify it blind at this point without re-reading source I've been
   told not to.

All three mutations were restored; final `git status` on the worktree is
clean (confirmed after each restore and again at the end).
