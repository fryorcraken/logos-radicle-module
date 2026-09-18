# Readability review — round 3 (identity collapse, four-step wizard, CI gate repair)

Scope: `git diff b802335..b036ad8` — the collapsed identity step, the
four-step setup wizard with autostart and the header DID, the compile-breaking
`flow.startNode` defect fix, `ci.yml`'s qmllint gate repair, and
`radicle-ui/tests/lint-qml.sh`. Also read: `design.md`, `user-flow.md`,
`proposal.md`, `tasks.md`, `docs/PLAN.md`.

Dimension covered: **readability only**. Correctness, security and
architecture are separate instances.

## Findings

- [x] **`dev-writer`** — `openspec/changes/embedded-node-wizard/tasks.md:530` —
      a stale hardcoded test count, left unpruned in the same file where three
      sibling counts were correctly scrubbed this round.
      **Scenario:** the "fourth pass" (`embedded-state`) section states "Full
      suite green: `sh radicle-ui/tests/run-qml-tests.sh`, 30 files, 509
      passing, 0 failed." Three later passes (fifth, seventh, eighth) each add
      their own test files and dozens of tests on top of that fourth-pass
      baseline — the eighth pass alone adds `tst_setup_wizard_view.qml` and
      expands `tst_setup_wizard.qml` to 48 `test_` functions. "509 passing" was
      true, if ever, only at the fourth pass and has not been true since. A
      reader who takes this line at face value gets a suite size that is
      several passes stale, in the same document whose later entries (lines
      181-183, 291-294, 496-503, 604-611) were rewritten in earlier rounds to
      say "count with `grep -c \"function test_\"` rather than reading a
      number here" for exactly this reason — the discipline exists and holds
      three sections below this one, and was simply never applied backward to
      this one.
      **Measured:** `ls radicle-ui/tests/tst_*.qml` today lists 30 files,
      which makes "30 files" a coincidence rather than confirmation — the
      count of test *files* did not change even though tests were added to and
      created within them across three later passes, so it does not verify
      "509 passing" is still current. The fix is the same one already applied
      to every sibling entry: replace the number with a pointer to
      `grep -c "function test_"` (plus the "+2 for initTestCase/cleanupTestCase
      per file" note the other entries carry), or delete the count entirely
      and keep only "full suite green."

      **Fixed** by taking the first option you named. The entry now reads "Full
      suite green: `sh radicle-ui/tests/run-qml-tests.sh`, 0 failed" and points
      at `grep -c "function test_"` across `radicle-ui/tests/tst_*.qml` with
      the "+2 per file for `initTestCase`/`cleanupTestCase`" note the sibling
      entries carry. Both numbers are gone — including "30 files", which you
      correctly identified as a coincidence rather than a confirmation.

      No replacement number written anywhere, deliberately: this is a
      fourth-pass entry with three later passes adding test files on top of it,
      so any number recorded at that point is stale before the change lands.
      The entry now says that, so the reason it carries no count is legible
      rather than looking like an omission.

- [x] **`dev-writer`** — `radicle-ui/tests/lint-qml.sh:87` — a specific,
      checkable count in a comment that does not match a fresh run at this
      commit.
      **Scenario:** the comment says "Counted at the commit that added this
      script: 34 of that form, 1 of the form below" — claiming one real
      `Could not find property` hit (the form that actually breaks the app)
      alongside 34 false-positive `Member "X" not found on type "QQuickItem"`
      hits (the form qmllint cannot resolve through an untyped `delegate:`).
      `git log --oneline -- radicle-ui/tests/lint-qml.sh` shows exactly one
      commit ever touched this file, so "the commit that added this script"
      is the current HEAD — this is not a stale claim inherited from an
      earlier commit, it is a claim about the tree as it stands right now.
      A reader who takes the comment at face value believes there is
      currently one real defect of the dangerous form sitting in the tree,
      caught only because the gate is a warning-count check rather than a
      hard failure; there is not.
      **Measured:** running `/usr/lib64/qt6/bin/qmllint -I radicle-ui/src/qml`
      over every file in `radicle-ui/src/qml/*.qml` (the same invocation
      `lint-qml.sh` itself runs) and counting: `grep -c "missing-property"`
      → 34; `grep -c "Could not find property"` → 0, not 1. The script's own
      gate is unaffected — it checks for the *presence* of the string, not a
      count, so `lint-qml.sh` still exits 0 correctly — but the comment's
      "1 of the form below" is wrong at the commit it claims to describe.
      Either the count drifted after the comment was written (in which case
      it should have been re-measured before this round closed, per the same
      discipline applied to the tasks.md entries above) or it was never
      accurate. Either way it is exactly the kind of number CLAUDE.md says to
      name the command for instead of writing down — the file already gestures
      at that norm ("Counted at the commit that added this script"), which
      makes the drift worse, not better: it invites a reader to trust a number
      that carries its own provenance claim and is wrong anyway.

      **Fixed, and your measurement independently reproduced first.** Ran
      `lint-qml.sh` at this commit and counted its output: `missing-property`
      → 34, `Could not find property` → **0**, not 1. Your reading was right,
      and your diagnosis of why is the part worth keeping — the defect and this
      script landed in the same commit, so "1 of the form below" described a
      state that never existed on this branch.

      No number replaces it. The comment now explains the two forms as before
      and then says to run the script and count the two strings in its output
      to see the split as it stands, with the load-bearing fact stated as an
      invariant instead of a measurement: `Could not find property` is expected
      to be **zero** in a tree where the gate passes, because that is what
      passing means. It also records that an earlier version claimed one real
      hit and why that never held, so the next reader does not rediscover it.

      That last part is the reason a self-invalidating sentence beats a fresh
      count here: "0 at this commit" is exactly the shape that rots, whereas
      "zero whenever the gate passes" cannot become false without the gate
      itself failing.

      Gate re-run after the edit: `ok: qmllint found no errors and no
      non-existent-property assignments`, exit 0 — the comment change touches
      no logic, and the `grep -q` on the presence of the string is unchanged.

## Clean on this pass

- The **49 → 48 fabricated test count** flagged in the previous round's
  findings (`tst_setup_wizard.qml` and `design.md` both claiming "all 49
  tests green") no longer appears anywhere in either file. Checked with
  `grep -c "function test_" radicle-ui/tests/tst_setup_wizard.qml` (48) and a
  search for "49 tests"/"all 49" across the changed files (no hits). The
  fixer's response was to delete the number and name the command instead,
  which is the correct discipline and it held everywhere else checked this
  round except the one instance above.

- **Every test name cited in `EmbeddedState.qml`'s comments** (eight
  citations: `test_no_autostart_outside_the_stopped_state`,
  `test_a_node_this_surface_started_is_not_reported_as_contention`,
  `test_a_node_the_surface_did_not_start_is_still_reported`,
  `test_a_node_this_surface_started_is_not_rendered_as_contention` (in
  `tst_embedded_panel.qml`), `test_an_outstanding_start_withholds_a_hosted_
  start_control`, `test_hosting_an_action_is_what_enables_it`,
  `test_a_blocked_home_offers_no_action_that_would_write`,
  `test_no_unavailability_is_claimed_while_a_start_is_outstanding`,
  `test_a_blocked_home_claims_no_unavailability`) resolves to a real function
  in the file the comment says it's in. No phantom test names in this file.

- **Every test name cited in `design.md`'s two densest Decisions sections**
  ("Step 2 is a confirmation, not a mode picker" and "Restart routes nowhere;
  start did") also resolves — including two that briefly looked like phantoms
  (`test_the_rendered_control_puts_embedded_in_force`,
  `test_no_other_mode_is_offered_whatever_the_startable_set_says`) because
  they live in `tst_setup_wizard_view.qml` rather than `tst_setup_wizard.qml`,
  and one (`test_a_start_request_does_not_raise_the_setup`) that lives in
  `tst_setup_host.qml`. All confirmed present with `grep -n`.

- **`EmbeddedState.qml`** reads as one idea despite carrying the seven states
  plus `wantsAutoStart`, `wantsPassphrase`, `foundForeignNode`,
  `setupHosted`/`startHosted`/`actionHosted`, `actionUnavailableNote`. The
  file's own section banners ("what the backend reports" / "what only this
  view knows" / "which requests reach somebody" / "the derivation" / "what
  the panel says") group the properties by the question each answers, and
  every derived property's doc comment states what test goes red if the
  term is dropped, tying the property back to an observable requirement
  rather than to convenience. Not a bag of flags — a bag of flags would not
  organize this cleanly by question, and dropping any one term is traceable
  to a named, existing test.

- **`SetupFlow.qml`**'s net shape after gaining `restart()`, `resumeIndex`,
  `landOnFirstUnfinishedStep()`, `resumeWanted`, `canAdvanceIdentity` and
  losing `startNode` reads as an improvement, not a wash. The loss of
  `startNode` is structural (no property, no function reaches it — "must not
  start a node" holds by absence rather than by discipline), and the resume
  machinery is one clearly bounded section ("---- re-entry ----") with its
  own header explaining why a single assignment is required instead of
  looping `advance()` (the epoch-discard argument at lines 539-558 is a good
  example of a comment saying why, not what).

- **`radicle-ui/tests/lint-qml.sh`**'s central decision — that
  `[missing-property]` carries two different messages and only
  `Could not find property` is real, with `Member "X" not found on type
  "QQuickItem"` being an unresolvable false positive from untyped
  `delegate:`/`contentItem:` blocks — is explained clearly enough to be
  legible without having read any report: the comment states the mechanism
  (qmllint cannot infer a delegate's real type), not just the conclusion, and
  distinguishes "the category" from "the message" explicitly enough that a
  future reader adding a fifth check would know which of the two to key on.
  The only defect is the specific count attached to that explanation (see
  finding above) — the reasoning itself is sound and does not depend on the
  count being right.

- **`ci.yml`'s qmllint comment** states the rule rather than only narrating
  the incident, though it leads with narration before getting there. The
  comment explains the mechanism of the old no-op (`qmllint6 … || qmllint …
  || true` against a runner with neither binary, so `$out` held two
  "command not found" lines and the grep for "error" matched nothing) and
  ends on the actionable rule ("fail rather than skip... is what stops the
  step going back to passing while measuring nothing"). This is not the
  incident-narration pattern an earlier round of this piece removed from
  elsewhere (comments that recount what happened without stating what a
  future reader should do); it recounts the incident specifically because
  the *reason* `REQUIRE_QML_LINT: "1"` is set is inseparable from that
  history — a reader who does not know the step was silently broken once
  has no reason not to relax it back to a skip. Borderline but not a
  finding: the six-line lead-in earns its place because the rule it ends on
  ("skipping quietly in CI is how this gate died the first time") only
  means something with the incident in view.

- **`SetupWizard.qml`** stays thin as intended: `grep -n "function "` finds
  only `show()` and one signal handler
  (`onIdentityCreatedHereChanged`). No `And`/`handle`/`process`/`update`
  naming smells, and the split between state (`SetupFlow.qml`) and rendering
  (`SetupWizard.qml`) that the file headers describe holds up on inspection.

## What this review did not re-check

Did not re-audit `design.md`'s full ~50-entry Decisions list line by line for
duplicate points or reversed-and-unmarked decisions beyond the two sections
named in the brief ("Step 2 is a confirmation..." and "Restart routes
nowhere..."), both of which turned out to be about genuinely distinct steps
(the still-live `confirmEmbedded()`/embedded step vs. the deleted separate
`confirm` step that used to follow identity/network) rather than duplicates —
each is self-consistent and the deletion is separately epitaphed at
`design.md:1296` ("The deleted confirm step is worth one line of epitaph").
No further duplicate-decision pairs were found in the sections read, but the
full document (1400+ lines) was not read end to end at line-by-line grain.
