# Design review — findings-handover

No `design.md` for this change. That is **not** itself a finding: of
`dev-writer`'s triggers (FFI boundary, new dependency, JSON contract, write
path, migration or performance complexity) this change meets none — it touches
only instruction prose. `tasks.md`'s stage block already declares the spec and
test rows struck through with reasons, and those reasons hold.

The review below is therefore against the adopted rules themselves: whether each
carries the reason the sibling recorded, whether any cited evidence is this
repo's, and whether the set is coherent.

Reviewed against the sibling repo's `6e31bc0` and `b6a8cef` commit messages and
the resulting `6e31bc0:.claude/agents/README.md`.

## Fabricated or borrowed evidence

- [x] **`dev-writer`** — `.claude/agents/code-reviewer.md` and
      `.claude/agents/spec-test-reviewer.md`, checkbox templates — **`tst_sourcetab.qml`
      does not exist in this repo**
      Both templates cite `tst_sourcetab.qml:60` / `tst_sourcetab.qml` as the file
      whose assertion could not fail. `git ls-files radicle-ui/tests` lists 26
      `tst_*.qml` files and no `tst_sourcetab.qml`; the real ones for this story are
      `tst_source.qml` and `tst_branch_switch.qml`.
      **Why it matters:** the template is the one thing every reviewer copies, and
      it is the example of what a *measured* finding looks like. An agent that
      opens the cited path to see the shape finds nothing, which undercuts exactly
      the "get it from a command" discipline the templates are teaching. The
      surrounding numbers (`122 tests`, `onBranchChanged`) **are** this repo's —
      `accc288` put them in CLAUDE.md — so the filename is the only false note,
      which makes it the more likely to be believed.
      **Also check the line number:** the template pins `SourceTab.qml:140`, but
      `onBranchChanged` lives in `RepoView.qml:191` (SourceTab.qml:206 only
      *mentions* it in a comment). CLAUDE.md tells this story about
      `RepoView.onBranchChanged`. Both coordinates in the template are wrong for
      the defect they describe.

      **Fixed**, and this is the most serious finding of the review — I invented a
      filename inside the one artefact every reviewer copies, while the surrounding
      evidence was real, which is the combination that gets believed. Verified both
      coordinates from commands before editing: `ls radicle-ui/tests/` has no
      `tst_sourcetab.qml`, and `grep -rn onBranchChanged radicle-ui/` puts the handler
      at `RepoView.qml:191` with `tst_branch_switch.qml` as its test. The templates now
      cite those. The "122 tests" count also went, replaced by "the QML suite" — a
      count in a template is a fabricated measurement waiting to be copied, and the
      suite size is exactly what CLAUDE.md says not to write down.

- [x] **`dev-writer`** — `.claude/agents/README.md:~170` (branch-names section) —
      the rename-endpoint trap lost the evidence that makes it credible, and it is
      this repo's weakest-supported claim
      The sibling's version ends "Six reviewers' findings went that way here and
      were recovered only because the commit was still in a local reflog" — 2,391
      lines across six files, per `6e31bc0`. The local copy keeps the full
      mechanism (200-and-ignores, auto-close, recreate-at-old-tip) and drops the
      incident.
      This is the **right** call on borrowed-evidence grounds — it did not happen
      here — and the finding is not that the story should be restored. It is that
      what remains is now a bare set of API assertions with no "verified how"
      anywhere, in a repo whose CLAUDE.md is explicit that a claim a command can
      check should name the command. Either attribute it (`per the sibling repo's
      `6e31bc0``) or say it is untested here. As written a future agent cannot
      tell it from something someone assumed about the GitHub API.

      **Fixed** by attribution, which is the option the finding offers and the honest
      one: the paragraph now says the specifics were established in the sibling repo,
      are recorded as inherited rather than measured, and should be re-checked against
      `gh api` before anyone relies on one. The sibling's incident is named in one
      clause as what it cost there — that is attribution, not a borrowed war story. A
      separate security finding asked for the missing imperative, so the paragraph also
      now says what to do instead: open a new PR on the correct name and close the old
      one.

## Reasoning dropped in the port

- [x] **`dev-writer`** — `.claude/agents/README.md:~140` ("One writer at a time")
      — the spec-moves-under-the-writer rule lost its *instance* and kept only the
      mechanism
      Sibling: "This session did it — a scope reworded while four reviewers read
      the code implementing it." Local: the mechanism only ("the implementation
      answers a contract that changed underneath it, with neither agent knowing").
      Correctly removed as not-this-repo's. But this is the rule most likely to be
      rationalised away under time pressure — "the spec edit is tiny, the dev can
      keep going" — and it is now the one rule in the section with no concrete
      failure attached, while its sibling bullet (`tester` mutating code it does
      not own) keeps a full mechanism. Per the README's own thesis, the imperative
      without the case is the part an agent applies wrongly to the case it did not
      anticipate. This repo has a substitutable local instance available: the
      `onBranchChanged` class — a handler changing a property and reading a binding
      derived from it in the same breath — is the same "state moved underneath the
      reader" shape, already in CLAUDE.md, already this repo's.

      **Fixed** with the substitution the finding proposes, which is better than what it
      replaced: the rule now names `onBranchChanged` as this repo's own instance of
      "answered the wrong version of the question", and says two agents on one piece is
      that hazard with a spec in place of a binding. The analogy earns its place because
      it carries the same punchline — every gate was green, since nothing observes a
      question answered against state that had already moved. Local evidence, and a
      shape an agent here already recognises.

- [x] **`dev-writer`** — `.claude/agents/README.md:~195` (`git add -A`) — the
      reason is stated as build-output hygiene, losing the sharper one
      Local: "A worktree collects build output (`.scaffold/`, `target/`, `result-*`
      symlinks) and `./tmp/` scratch, and sweeping up another agent's half-finished
      edit corrupts the branch you were working on." The paths are correctly
      localized (the sibling's "gitignored SDK symlink" became this repo's real
      ones — good).
      But the two halves are fused into one sentence, and they are different rules
      with different consequences: committing `target/` is noise a reviewer spots,
      whereas **sweeping up a concurrent agent's half-finished edit is the silent
      one** — `6e31bc0`'s later commit calls it "a reviewer that sweeps up a
      fixer's half-finished edit has corrupted the branch it was reviewing", and
      `code-reviewer.md` states it as the consequence while README states it as an
      aside. The noise reason is the one an agent will remember, because it is
      first and concrete; the corruption reason is the one that matters.

      **Fixed.** The two are now separate bullets with the corruption reason **first**,
      and the README says why that order: the artefact reason is the one an agent
      remembers because it is concrete, and the corruption one is the one that does
      damage — it is silent, the commit looks like yours, and the agent whose work you
      took cannot see that it left. This landed together with the architecture finding
      about the same list being repeated in five files, so the canonical list lives here
      and the agent files keep the rule plus their own reader's consequence.

- [x] **`dev-writer`** — `.claude/agents/README.md:~185` ("Only the runner
      pushes") — kept the conclusion, dropped why *fixers* specifically need the
      serialisation
      Sibling `6e31bc0`: "For fixers the reason is stronger than tidiness. Two
      reviewers never write the same path, so their files could have gone straight
      to the branch. Two fixers on one piece routinely write the same file, and
      serialising the cherry-picks through the runner is what leaves a conflict to
      someone who can see both changes."
      Local keeps only "With one pusher there is no race to lose, no rebase to
      retry, and no force-push to be tempted by" — which is the *reviewer* argument.
      The asymmetry is the load-bearing half: it explains why the rule is not
      redundant with one-writer-at-a-time, and an agent holding only the tidiness
      reason will reasonably conclude a single fixer may as well push its own work.

      **Fixed**, and the finding's diagnosis of the consequence is what made it
      actionable: with only the tidiness reason, "a single fixer may as well push" is a
      *reasonable* inference, so the rule was one rationalisation away from being
      ignored. The asymmetry is now stated — two reviewers never write the same path, so
      their files could safely have gone straight to the branch, whereas two fixes to one
      piece routinely touch the same file, and serialising through the one role that sees
      both is what leaves a conflict to somebody able to resolve it.

## Coherence gaps

- [x] **`dev-writer`** — `.claude/agents/spec-writer.md:46` vs the gate greps in
      `README.md:~275` — **a struck-through row is still an empty checkbox, and
      nothing says how the gate treats it**
      `spec-writer.md` says to strike a row through with its reason rather than
      delete it, and this change's own `tasks.md` does exactly that: `- [ ]
      ~~spec — `spec-writer`~~ — no spec delta…`. The box stays `[ ]`.
      The findings gate (`grep -rn "^- \[ \]"`) is specified only over
      `findings/`, so there is no direct contradiction. But the stage block uses
      the identical syntax, the README twice describes an unticked row as "a stage
      nobody is doing", and the runner's row reads "findings all ticked". A runner
      applying the README's own stated meaning to the stage block reads three
      struck-through rows as three stages nobody did, and the block's whole purpose
      is that an unticked row is a signal. Say which it is: either a struck row is
      ticked `[x]` with the strike carrying the reason, or the README states that
      the stage block's empty boxes are read by eye and strike-through is the
      "does not apply" marker. **This is the absence-is-a-decision case** — the
      gate deliberately does *not* cover `tasks.md`, and nothing records that.

      **Fixed**, taking the second of the two options offered: a struck row keeps its
      empty box and strike-through is the "does not apply" marker, read by eye. The
      README now says so where it states that an unticked row means nobody is doing the
      stage, adds the reason the row is struck rather than deleted (a deleted row and a
      skipped stage look identical; a struck one says which), and records that nothing
      greps this block — the `findings/` greps are scoped to that directory.

      The first option was rejected: ticking `[x]` would mean the block's boxes no
      longer answer one question, since `[x]` would mean both "done" and "not
      applicable". Keeping the box honest and putting the exception in the strike costs
      a sentence and keeps the signal single-valued. The finding is right that this was
      an absence-is-a-decision case — the scoping was mine and went unrecorded.

- [x] **`dev-writer`** — `.claude/agents/README.md` — the `b6a8cef` checkbox-gate
      lesson was ported well, but its scope was silently widened without saying so
      `b6a8cef`'s reason is specific: forty entries written *before the checkbox
      format landed* read as clean. The local copy generalises to "an entry written
      any other way is invisible", which is the right durable statement. What is
      missing is the transition case it was actually about — this repo has no
      pre-format findings files, so the rule here guards against a reviewer that
      writes prose, not against a format migration. Worth one clause, because the
      two have different fixes (re-read the file vs. re-format the directory), and
      the local text prescribes only the grep pair.

      **Fixed** with the clause the finding asks for: a zero from the sanity grep has two
      causes, and they are named with their different remedies — one file of prose gets
      that file re-formatted, a directory written before a format change gets the whole
      directory re-read. The sibling's forty entries are cited as the second case, which
      is the one to expect if this format is ever revised. The durable generalisation was
      kept; what was missing was that the two causes are not interchangeable.

- [x] **`dev-writer`** — `.claude/agents/README.md:~160` (branch table) — the
      shared-worktree rule lost its own paragraph and survives only in the table
      cell and the three writer files
      The sibling README carries a standalone paragraph: "`spec-writer`,
      `dev-writer` and `tester` share one worktree, checked out on `piece/<name>`…
      handing each its own tree would buy nothing and add a cherry-pick to get
      wrong." Locally that paragraph is gone; the table says "one, shared — the
      three writers, in turn", and each writer file repeats it.
      Defensible as de-duplication (each agent reads its own file). Flagged because
      the README is the document that holds "the shared vocabulary", the
      *counterfactual* — why not a tree each — is the part that stops someone
      "improving" this later, and it now lives in no file at all. `dev-writer.md`
      and `tester.md` say "you do not need one", which is the conclusion, not the
      reason.

      **Fixed**, and the finding's framing — the counterfactual is the part that stops
      someone "improving" this later — is what the new paragraph is built around. The
      README now states why *not* a tree each: the writers never overlap, so the
      isolation would protect nothing, and each tree would add a cherry-pick to get
      wrong in exchange for that nothing. Reviewers pay the cost because they genuinely
      overlap. A second paragraph records that the reasoning is deliberately repeated in
      the three writer files and that relaxing the rule means retiring four sites — which
      answers the architecture reviewer's related box about the same duplication.

## Correctly adapted — noted so a later reader does not re-litigate

Not findings. Listed because each is a place the port could have gone wrong and
did not, and a future sweep comparing the two repos will hit them.

- `cargo mutants` is **absent** from this repo's copy (the sibling cites it as
  what breaks dozens of lines). Correct: no such tool here. The reviewer-worktree
  rule is re-justified generically ("a reviewer breaks code on purpose to see
  whether a test notices") and the delete-don't-restore rule keeps its real
  reason (a restore depends on having tracked every edit).
- The sibling's `docs/OPENSPEC-ARCHIVE.md` split was **not** adopted; archiving
  material stayed inline (`README.md:28-72`). No dangling link — verified there is
  no `OPENSPEC-ARCHIVE` reference anywhere in `.claude/agents/` or `CLAUDE.md`.
  Reasonable: this repo's archive section is a third the sibling's size.
- The `guarded()` / `tests/panic_guard.rs` example in `design-reviewer.md` is
  genuinely this repo's, and the mutation evidence is real.
- `.claude/agents/README.md:~250` — "this flow's own adopting change nearly
  shipped with the `code-reviewer` step skipped entirely" is this repo's own
  (`0d97322`), not borrowed.
- The single-crate assumption did not come across: no `cargo fmt`/`cfg` gate
  claims, and the blind-gate example was re-pointed at this repo's own findings
  grep.
- `CLAUDE.md`'s "Five that catch people repeatedly" → "Six", with the pipe rule
  added and the count updated in the same edit. The one derivable number in the
  diff, and it was kept true.
