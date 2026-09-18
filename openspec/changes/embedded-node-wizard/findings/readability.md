# Readability review — piece 2 (hosting the setup wizard)

Scope: `SetupFlow.qml`, `SetupWizard.qml`, `EmbeddedState.qml`, `RepoList.qml`,
`Main.qml`, the new/changed tests, `design.md`, `docs/PLAN.md`, and the spec
deltas. Diff reviewed: `90ec3b9..b802335`.

## Findings

- [ ] **`dev-writer`** — `radicle-ui/tests/tst_setup_wizard.qml:1268` and
      `openspec/changes/embedded-node-wizard/design.md:658` — a fabricated test
      count: both say "all 49 tests in the file green" / "the loop left all 49
      tests green", but `tst_setup_wizard.qml` has 48 `test_` functions, not 49.
      **Scenario:** a reader trusting the comment believes the mutation (looping
      `advance()` instead of assigning `stepIndex` once) was checked against 49
      assertions in this file; it was checked against 48. The claim is wrong by
      exactly one in both places it is made, which suggests one was copied from
      the other rather than independently re-counted.
      **Measured:** `grep -c "function test_" radicle-ui/tests/tst_setup_wizard.qml`
      → `48`. The file's own last test is
      `test_a_later_reply_does_not_move_a_step_the_user_walked_to` at line 1338,
      confirming there is no 49th hiding past the visible range.

- [ ] **`dev-writer`** — `openspec/changes/embedded-node-wizard/tasks.md:239` —
      `tst_embedded_state.qml — 15 tests` is stale: the file now has 19.
      **Scenario:** the task line was accurate when written but the file grew
      afterward (this piece's diff shows `tst_embedded_state.qml` gained ~172
      lines of new assertions) without the count being updated — the exact
      "true on the day, false two edits later" failure mode CLAUDE.md's own
      "Keeping this file true" section warns about, just landed in `tasks.md`
      instead of `CLAUDE.md`.
      **Measured:** `grep -c "function test_" radicle-ui/tests/tst_embedded_state.qml`
      → `19`.

- [ ] **`dev-writer`** — `openspec/changes/embedded-node-wizard/tasks.md:244` —
      `tst_embedded_panel.qml — 17 tests` is stale: the file now has 20.
      **Scenario:** same mechanism as the previous entry — this file's diff
      shows ~109 lines added in this piece.
      **Measured:** `grep -c "function test_" radicle-ui/tests/tst_embedded_panel.qml`
      → `20`.

      (`tasks.md:340`'s `tst_setup_host.qml — 8 tests` was checked too and is
      correct: `grep -c "function test_" radicle-ui/tests/tst_setup_host.qml` → `8`.
      Not a finding — recorded so it is clear this line was checked rather than
      skipped.)

## Areas reviewed and clean

- **`SetupFlow.qml`'s four new re-entry members** (`restart()`, `resumeIndex`,
  `landOnFirstUnfinishedStep()`, `resumeWanted`) read as one idea, not four
  bolted-on ones. Each has a distinct, non-overlapping job: `resumeWanted` is a
  one-shot per-showing flag, `resumeIndex` is a pure derivation from reply state
  (testable by feeding it different replies), `landOnFirstUnfinishedStep()` is
  the single-assignment mover with a doc comment that earns its length by
  explaining a genuine trap (looping `advance()` would bump `epoch` and discard
  the very replies that chose the destination), and `restart()` is the one
  public entry point that composes the other three. The naming is precise
  enough that a reader does not need to hold all four in their head to
  understand any one of them.

- **`EmbeddedState.qml`'s "hosted" cluster** (`setupHosted`, `startHosted`,
  `actionHosted`, `actionUnavailableNote`) is introduced with a substantial
  comment block (lines 95–110) *before* first use, explaining the concept
  ("which requests reach somebody") and why it is data rather than a hard-coded
  per-state rule, before any of the four properties appears. A reader who has
  not seen `design.md` can follow "hosted" from the file alone. The two
  `actionHosted`/`actionEnabled` comments additionally cite exact test names
  that would go red under specific deletions (`test_an_outstanding_start_...`,
  `test_hosting_an_action_is_what_enables_it`, `test_a_blocked_home_offers_no_
  action_that_would_write`) — all three were spot-checked and exist in
  `tst_embedded_state.qml`.

- **`Main.qml`'s injection list** (`setupOpen`, `openSetup()`,
  `takeEmbeddedAction(kind)`, `toggleSettings()`, and the seven
  `flow.fetch*`/`flow.create*`/`flow.startNode`/`flow.saveSetting` assignments
  under `setupWizard`) reads as a list, not a wall, because each call is paired
  with a one-line reason for *which* helper it uses (`callPlain` for reads that
  must not paint the status strip red, `callSettings` for writes whose refusal
  is the useful result) rather than restating what the line does. `openSetup()`
  and `toggleSettings()` each explain the mutual-exclusion invariant once, and
  neither repeats the other's explanation — `toggleSettings()`'s comment
  explicitly points at the shape it is avoiding (a fourth hand-written
  staleness guard) rather than re-deriving the reasoning.

- **The two tests that admit the "obvious" guard is not the real one**
  (`test_the_resumed_steps_findings_are_populated` in
  `tst_setup_wizard.qml:1241` and its companion
  `test_the_landing_does_not_discard_a_reply_still_in_flight`) make the
  situation legible rather than merely admitting it: the first test's own
  doc comment states plainly that it "does NOT catch a landing that loops
  `advance()`", says how that was verified (mutation, not assumption), and
  names the actual guard by its exact function name — which does exist and
  does hold the seed reply across the landing. A reader is told exactly which
  test to trust and why, rather than being left to assume the nearest-looking
  assertion is the real guard. The one defect in this pair is the fabricated
  "49" count noted above, not the structure of the comments themselves.

- **`design.md`'s struck Open question** (`~~Where the flow is entered
  from...~~ **Answered...**`) reads correctly: the strikethrough markers are
  balanced, the struck text is left intact rather than mangled, and the
  non-struck continuation names what answered it (`embedded-setup`'s four new
  requirements) with a pointer to the two Decisions entries that carry the
  detail. Nothing here is decoration a command could answer instead.

No naming collisions with Qt built-ins or `on*`-prefixed properties were found
in the new code (the `stepMoved()` vs. `stepChanged` trap from a prior pass is
already documented and avoided, not reintroduced). One function, one job holds
throughout the reviewed files — no `handle`/`process`/vague-verb function names
and no function that has quietly grown a second, differently-shaped caller.
