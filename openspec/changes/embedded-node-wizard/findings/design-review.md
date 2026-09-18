# Design review — piece 2, hosting the setup wizard

Reviewed `design.md` against the code at `b802335` (diff `90ec3b9..b802335`),
against `user-flow.md`, and against `docs/PLAN.md` (both the branch's copy and
`origin/main`'s — see note below on why they differ structurally rather than
in content that matters here).

## Summary

Four of the five decisions this piece made are recorded well, with the
reasoning the code actually takes, alternatives named, and mutation evidence
where the decision is a guard. One choice — where and how
`actionUnavailableNote` is rendered — was made without a `NO SPEC:` marker or a
Decisions entry, despite the same file marking two structurally similar
"chosen, not specified" points explicitly. One minor duplication: the
encrypted-field reasoning is written out in full in both `design.md` and
`proposal.md`'s "Not covered" section, where `PLAND.md` correctly points at
`design.md` instead of repeating it.

## Findings

- [ ] **`dev-writer`** — `EmbeddedState.qml:606-612` (rendering) and
      `EmbeddedState.qml:1024-1045` (`actionUnavailableNote`) — an unspecified
      choice was made with no `NO SPEC:` marker and no Decisions entry
      **Scenario:** the brief itself names this as a choice the spec does not
      cover — *where* the "not yet available from here" text renders (below the
      button, per `RepoList.qml:599-612`) and that it stays *silent while a
      start is outstanding* (`actionUnavailableNote`'s guard clause,
      `!startPending`). `design.md`'s own Open Questions section already marks
      two structurally identical choices this way — `preflightDone`'s
      unanswered-state wording, and "advancing past the embedded step requires
      `getCapabilities().mode === 'embedded'`" — each with a `NO SPEC:` marker
      in the code, a named test, and an Open Questions entry explaining why it
      was chosen. This third one has neither. A future reader who moves the
      note above the button, or makes it always render even while a start is
      pending, has nothing telling them either choice was deliberate rather
      than incidental — they will have to re-derive that "not stated while
      starting" avoids contradicting the `starting` sentence, and re-derive
      that placement below the button rather than beside it was ever a choice
      at all.
      **Measured:** `grep -n "NO SPEC" EmbeddedState.qml RepoList.qml Main.qml
      SetupWizard.qml` returns nothing in any of the four files touched by this
      piece; the spec (`embedded-state/spec.md:396-416`) requires only that the
      text state unavailability, never where it renders or whether it is
      silent mid-flight, so both are genuinely open per this repo's own
      `NO SPEC:` convention and neither is marked.

- [ ] **`dev-writer`** — `proposal.md:87-96` — the encrypted-field reasoning is
      duplicated in full rather than pointed at `design.md`
      **Scenario:** `docs/PLAN.md`'s equivalent paragraph (diff hunk at
      `docs/PLAN.md:105-111`) correctly points — "the four reasons … are in the
      `embedded-node-wizard` change's `design.md`, under 'Start and restart
      route nowhere'" — rather than restating them, which is exactly the
      shedding rule `.claude/agents/README.md` and `PLAN.md`'s own header
      describe. `proposal.md`'s "Not covered, deliberately" bullet (added by
      this piece, replacing the old "How the setup is hosted" bullet) restates
      all four reasons in full, including the `getEmbeddedIdentity()`
      encrypted-field point, as a second full copy beside `design.md`'s. Two
      copies of the same reasoning drift, and the wrong one gets read — the
      exact failure this flow's document model exists to prevent, applied here
      to a document that sits one level closer to the reasoning than PLAN.md
      does.
      **Measured:** compare `proposal.md:87-96` ("Both need a passphrase, and
      nothing in this change can ask for one: the setup's start step is gated
      on no node answering the socket … `getEmbeddedIdentity()` carries no
      field saying whether an existing key is encrypted") against
      `design.md`'s "Start and restart route nowhere" section — the same four
      points, independently worded. This is a suggestion rather than a
      blocking gap: `proposal.md` is the change's own scoping document rather
      than the cross-milestone `PLAN.md` the shedding rule is written against,
      so a one-line summary with a pointer would fit its role at least as well
      as the full restatement it has now.

## What is in good shape

- **Hosting extended `embedded-setup` rather than adding a capability**
  (`design.md`'s "Hosting the setup extended…" section) — records what was
  chosen, the constraint (re-entry decides which step is in force), the
  alternative considered and why it was rejected, and is honest about the
  weakest part of its own argument (raising/lowering doesn't obviously share
  the same subject as the six steps — the entry says so directly rather than
  papering over it). No mutation evidence needed here since it isn't a guard.

- **Start/restart route nowhere** (`design.md`'s "Start and restart route
  nowhere, rather than into the wizard's start step") — all four reasons are
  recorded, the decisive one (`getEmbeddedIdentity()` carries no `encrypted`
  field, only `createEmbeddedIdentity`'s reply does, `radicle_impl.h:275`) is
  called out as the one worth writing down "because a future reader will
  otherwise re-derive it from the header." Verified against
  `radicle_impl.h:244-264` (`getEmbeddedIdentity`'s reply shape: `home`,
  `exists`, `nodeId`, `problem` — no `encrypted`) and `:266-299`
  (`createEmbeddedIdentity`'s reply, which does carry `encrypted`) myself —
  the code matches the citation exactly. `Main.qml:1074-1091`
  (`embeddedStartHosted`) takes the identical reasoning verbatim in its
  comment. Mutation evidence present (`test_a_start_request_does_not_raise_the_setup`,
  confirmed present in `tst_setup_host.qml:302`).

- **The single-assignment resume** (`design.md`'s "The resume sets `stepIndex`
  once…") — this is the strongest entry in the piece. It records the wrong
  test first (`test_the_resumed_steps_findings_are_populated`, which "cannot
  fail against a looping landing" because the harness is synchronous), names
  the test that actually catches the regression
  (`test_the_landing_does_not_discard_a_reply_still_in_flight`), and states the
  mutation evidence for both directions. I confirmed this by reading
  `tst_setup_wizard.qml:1225-1298` directly: the two tests and their comments
  match `design.md`'s account word for word, including "the loop left all 49
  tests in the file green." `SetupFlow.qml:451-474`
  (`landOnFirstUnfinishedStep`) matches: single assignment, no `advance()`
  loop, no epoch bump, exactly as recorded.

- **The host-begun wizard** (`show()` replacing `Component.onCompleted`) —
  recorded with the reason (the overlay is not destroyed between showings, so
  construction fires once), the rejected alternative (`Loader` recreating the
  wizard per showing) and why it was rejected (more machinery for the same
  outcome, and `SettingsPanel` already establishes the keep-one-instance
  pattern), plus mutation evidence
  (`test_raising_the_setup_restarts_the_flow` reddens on reversion). Matches
  `SetupWizard.qml:84-98`'s `show()` and its comment.

- **`settingsShown` moved to read the pane's `visible`** — recorded with the
  reason (a copy of a condition agrees with the item whether or not the item
  draws — the same lesson `reposEmbeddedPanel` already established earlier in
  this change) and honestly flagged as not strictly required by this piece.
  Matches `Main.qml:522-535` exactly, including the comment cross-referencing
  the earlier lesson.

## Open question struck correctly

"Where the flow is entered from" reads correctly struck (`~~…~~`) in
`design.md`'s Open Questions section, with "**Answered, and it is no longer a
choice this change declines to make**" replacing it and pointing at the four
new `embedded-setup` requirements. The one place the old unstruck wording still
appears (`design.md:791-792`) is inside the struck span itself, preserved as
history, not a live claim — `grep` for it elsewhere in `proposal.md` and
`embedded-setup/spec.md` found nothing stale.

## PLAN.md vs origin/main

`docs/PLAN.md` at `origin/main` (`3235f75`) predates this entire change — it
still has the wizard listed under "Still ahead" rather than struck, because
`embedded-node-wizard` (both pieces) is unmerged. This piece's parent commit
(`90ec3b9`, piece 1's tip) is on the same feature branch, not a descendant of
`origin/main`, so the diff shown is branch-parent-to-branch-tip, not a
comparison against `origin/main`'s content. That is expected here and not
itself a defect — there is nothing in `origin/main`'s copy of this section for
this piece's edits to contradict, since the section they're editing does not
exist there yet in specified form.

## Branch and handoff

Committed to `review/p2/design` (the branch I was placed on — verified with
`git rev-parse --abbrev-ref HEAD` before committing). Only
`openspec/changes/embedded-node-wizard/findings/design-review.md` was staged,
plus my own row in `tasks.md`'s stage block (`review: design`). Two unticked
findings above. Worktree left in place for the runner to prune.
