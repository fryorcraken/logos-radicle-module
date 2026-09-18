# spec-test review — embedded-node-wizard, final pass before merge

Reviewed against all four specs under `openspec/changes/embedded-node-wizard/specs/`
(`embedded-setup`, `embedded-state`, `embedded-header`, `embedded-identity`) plus
`source-modes` (read because it is in the change's `specs/` delta). Tests read:
`tst_setup_wizard.qml`, `tst_setup_wizard_view.qml`, `tst_embedded_state.qml`,
`tst_embedded_panel.qml`, `tst_setup_host.qml`, `tst_embedded_wiring.qml`,
`tst_embedded.qml`, `tst_embedded_real.qml`, `radicle-ui/tests/ui/local.yaml`, and
the Rust tests under `radicle/rust-ffi/tests/` (`profile_init.rs` for the
`encrypted`/`key_encrypted` half of `embedded-identity`). `tst_source.qml` was also
read, though not in the assigned list, because it is where `embedded-header`'s
core requirement ("every mode with an identity shows it, one rule not a list") is
actually pinned — see below.

Implementation files were not read for comprehension, per the brief. The one
exception is the mutation sampling below, which touched `RepoList.qml`'s
`Component.onCompleted` line and `EmbeddedState.qml`'s `foundForeignNode` and
`wantsPassphrase` properties — each read only far enough to locate the property
being mutated, and each restored immediately after the run.

## Requirement-to-scenario coverage — clean

Walked every requirement in the four specs plus `source-modes` scenario by
scenario. Every scenario has a test that pins it, and coverage is thorough rather
than one-to-one in most places (several requirements are pinned at both the state
layer, `tst_embedded_state.qml`, and the rendered-panel layer,
`tst_embedded_panel.qml`, which is the right shape given the "a derivation that is
correct and never rendered is the blank pane this capability exists to remove"
reasoning both files state).

Specific areas checked against the "new this round" list in the brief, all found
covered by tests that can fail (see Mutations below for three that were verified
rather than assumed):

- **Autostart** (once per arrival, only when `encrypted:false`, only in Embedded):
  `test_an_unencrypted_stopped_node_wants_a_start` /
  `test_no_autostart_outside_the_stopped_state` (state layer),
  `test_an_unencrypted_stopped_node_is_started_without_being_asked` /
  `test_a_list_built_already_stopped_starts_its_node` /
  `test_the_automatic_start_is_issued_once_not_on_every_reading` (panel layer, the
  last two covering both "on a live change" and "already stopped on construction").
- **Passphrase field on `stopped` and `startFailed`**:
  `test_an_encrypted_stopped_node_asks_for_its_passphrase` and
  `test_the_passphrase_prompt_does_not_follow_a_failed_start` at the state layer;
  `test_an_encrypted_identity_is_offered_a_passphrase_field` and
  `test_a_refused_passphrase_can_be_corrected` at the panel layer. Mutated (see
  below) — both halves are load-bearing.
- **Foreign-node distinction**: `test_a_node_this_surface_started_is_not_reported_as_contention`
  / `test_a_node_the_surface_did_not_start_is_still_reported` (state),
  `test_a_node_this_surface_started_is_not_rendered_as_contention` (panel).
  Mutated (see below) — all three named tests reddened exactly as the code
  comment claims.
- **`encrypted` in `getEmbeddedIdentity()`**, including the unreadable-key case:
  `profile_init.rs`'s `the_reported_encryption_follows_the_key_that_was_written`,
  `reporting_encryption_needs_no_passphrase_and_no_agent`,
  `reporting_encryption_leaves_the_key_untouched`,
  `an_unreadable_key_reports_a_problem_rather_than_unencrypted` (this is the exact
  scenario the brief named — an unreadable key reports `encrypted:false` with a
  non-empty `problem`, distinct from a plaintext key), and
  `a_home_with_no_key_reports_a_problem_rather_than_unencrypted`.
- **The DID in the header for Embedded**: `tst_source.qml`'s
  `test_embedded_shows_its_identity_as_local_does`, driven through the real
  `SourceState.modeHasIdentity` (a rule, not a per-mode list — matching the spec's
  explicit "MUST NOT be a list of modes" requirement), with two distinct DIDs and
  the first asserted absent. `local.yaml`'s "the local identity reached the view"
  / "and carries no identity from it" steps close the same requirement end to end
  for both `local` and `embedded`. Solid coverage; not flagged as a gap even
  though this file was not in the assigned list, because it is where the
  requirement actually lives.
- **The identity step's three states and single forward control**: covered at
  both the flow layer (`tst_setup_wizard.qml`'s
  `test_the_three_identity_states_are_told_apart`,
  `test_one_forward_control_creates_and_advances_together`,
  `test_the_label_names_the_act_the_control_will_perform`) and the rendered view
  (`tst_setup_wizard_view.qml`'s `test_the_identity_step_renders_its_three_states_apart`,
  `test_the_identity_step_offers_exactly_one_forward_control`).

## Mutations run (3, within the stated budget)

All three targeted properties I could not convict by reading alone — two carried
an existing code comment naming which tests should redden, which I verified
rather than trusted, and one had no such comment. All three mutations were
restored immediately after their run; `git status` on the whole worktree is
clean, confirmed after the last one.

1. **`RepoList.qml`'s `Component.onCompleted: autoStartIfWanted()`**, commented
   out. This is the guard `test_a_list_built_already_stopped_starts_its_node`
   exists for — the "module becomes ready already stopped" case the brief flagged
   as a known prior defect shape. Ran `tst_embedded_panel.qml` alone
   (`qmltestrunner -input tst_embedded_panel.qml -import radicle-ui/src/qml`,
   single-file run, full output read): **27 passed, 4 failed**. The targeted test
   reddened as expected (`Actual: 0, Expected: 1`), plus three others
   (`test_a_refused_automatic_start_is_reported_and_not_retried`,
   `test_an_unencrypted_stopped_node_is_started_without_being_asked`,
   `test_the_automatic_start_is_issued_once_not_on_every_reading`) that also
   depend on the same construction-time start firing before their own
   `list.reload()` calls run their assertions — a real and correct interaction,
   not an artifact. Restored; `git diff --stat` on the file came back empty.

2. **`EmbeddedState.qml`'s `foundForeignNode`**, changed from
   `serving && !startSucceeded` to `serving`. The code carries a comment naming
   three tests this should redden; verified rather than trusted. Ran
   `tst_embedded_state.qml` alone: **28 passed, 2 failed** —
   `test_a_node_the_surface_did_not_start_is_still_reported` and
   `test_a_node_this_surface_started_is_not_reported_as_contention`, both named.
   Ran `tst_embedded_panel.qml` alone: **30 passed, 1 failed** —
   `test_a_node_this_surface_started_is_not_rendered_as_contention`, also named,
   with the failure message showing the exact contention sentence rendered over
   the surface's own success (the defect the spec's requirement exists to
   prevent). All three of the comment's claimed tests reddened; none survived.
   Restored; clean.

3. **`EmbeddedState.qml`'s `wantsPassphrase`**, narrowed from
   `encrypted && (current === "stopped" || current === "startFailed")` to drop
   the `startFailed` disjunct — checking the brief's explicit ask that the
   passphrase field cover both states. No code comment named a test here, so this
   was blind. Ran `tst_embedded_state.qml` alone: **29 passed, 1 failed** —
   `test_the_passphrase_prompt_does_not_follow_a_failed_start`. Ran
   `tst_embedded_panel.qml` alone: **30 passed, 1 failed** —
   `test_a_refused_passphrase_can_be_corrected`. Both halves of the requirement
   ("covering both `stopped` and `startFailed`") are independently load-bearing at
   both layers. Restored; clean.

No mutation in this round surfaced a survivor. All three properties tested are
genuinely guarded by tests that redden on the specific failure they claim to
catch.

## Previously reported issue, re-checked rather than re-litigated

`SetupFlow.qml`'s `landOnFirstUnfinishedStep()` is still the single-assignment
form (`stepIndex = resumeIndex; stepMoved();`), confirmed by reading the current
file rather than assuming the prior round's fix held. The prior round's finding —
that `test_the_resumed_steps_findings_are_populated` cannot fail against a
`landOnFirstUnfinishedStep()` that loops `advance()`, and that
`test_the_landing_does_not_discard_a_reply_still_in_flight` is the test that
actually reddens — was already measured twice in earlier rounds and accepted as
an observation rather than a defect requiring a code change (the comment pair in
`tst_setup_wizard.qml` explicitly documents the relationship). Not re-mutated
here to conserve the budget for properties not yet convicted; flagging only that
the situation is unchanged, in case a future edit to either test silently drops
the relationship the comment describes.

## `NO SPEC:` markers found

One, in `tst_setup_wizard_view.qml`:

- `test_an_unanswered_finding_is_not_reported_as_a_failure` — the spec does not
  say what a preflight finding shows before its own probe has answered; the test
  names this as an unanswered state ("Checking…") rather than a default result.
  This is a real behavioural choice (every finding has a legitimate falsy value,
  so showing defaults would report failures before a single call went out) that
  nobody wrote into the spec. Worth `spec-writer` capturing as a scenario under
  "The preflight reports four findings before offering a choice," since the
  behaviour is sound and durable but currently exists only as a test comment.

No unmarked gaps of the same shape were found — I looked for behaviour pinned by
a test with no corresponding spec scenario, and did not find one beyond the
marked case above.

## `PLAN.md` / spec staleness

Not separately checked in this pass — the brief's scope was the four
`embedded-*` specs plus the listed test files, and a `PLAN.md`-vs-spec
reconciliation was not flagged as part of this round's ask. Noting the omission
rather than silently skipping it.

## What was clean

- The `tst_embedded_panel.qml` "list built already stopped" fixture (the
  `freshList` component) and `tst_setup_host.qml`'s equivalent `freshRepoList`
  are both present and doing real work — verified by mutation for the panel one
  (above), and the setup-host one was already verified in the prior round
  (`test_starting_up_in_embedded_does_not_raise_the_setup`, present and unchanged
  in this file).
- `ui-tests.yml`'s matrix includes `local` (`spec: [browse, branches, source,
  sync, write, local]`, confirmed by reading the file rather than assuming); the
  spec is not merely present in the tree.
- `local.yaml`'s Embedded section is exercised for real: the setup-raised/lowered
  steps click through `embeddedStateAction` and `wizardClose` rather than calling
  functions directly, and the no-identity-state assertions
  (`reposEmbeddedPanel`/`reposEmbeddedState`) are the pair the file's own
  comments say is needed to distinguish "didn't render" from "rendered the wrong
  state" — both actually present, not just described.
- `tst_embedded.qml` and `tst_embedded_real.qml` correctly split the "mode the
  build cannot start" behaviour (now re-keyed onto `local` in the fixture, since
  `embedded` is startable in this build) from "Embedded actually works" — the
  file headers explain the split honestly and neither file quietly tests a
  fixture state that no longer occurs in production.
- `embedded-identity`'s MODIFIED requirement is fully pinned at the Rust layer,
  including the two edge cases (`problem` non-empty and `encrypted:false` for
  both an unreadable key and no key at all) that are easy to collapse into a
  single `unwrap_or(false)` and easy to miss covering.

## Findings

No open findings. All requirement-to-scenario mappings hold, all three sampled
mutations were caught by name-matched or newly-identified tests, and no
untestable scenario or contradictory requirement was found across the five specs
read. The one `NO SPEC:` item above is a gap in the spec's coverage of an
already-sound behavioural choice, not a defect — recorded for `spec-writer` to
evaluate, not blocking.
