# Review — worktree-dispatch-fix (PR #48), all four dimensions

Covered: correctness, security, readability, architecture (one instance, as the
dispatch asked — the piece is docs-only). Findings below are tagged by which
dimension each belongs to.

## Verified claims (no finding — recorded so the next reader does not re-derive them)

- **Eleven files carry `EnterWorktree`.** `git grep -rln "EnterWorktree" --
  .claude/agents CLAUDE.md docs` returns exactly the eleven named in the
  proposal. Matches.
- **`.claude/settings.json` is tracked; `settings.local.json` is not.**
  `git check-ignore -v .claude/settings.json` exits 1 (not ignored) and the file
  is in `git ls-files .claude`. `git check-ignore -v .claude/settings.local.json`
  returns `.gitignore:45:.claude/*  .claude/settings.local.json` (ignored).
  Matches the design.md and .gitignore comment.
- **`--no-track` is present at both prescriptive worktree-creation sites**
  (`RUNNER.md:293`, `CLAUDE.md:539`), and every `git branch -vv` mention left in
  the tree is in "this does not catch it" framing, never prescribed as the check
  — checked all six occurrences across `README.md`, `RUNNER.md`, `closer.md`,
  `dev-writer.md`, `tester.md`, `CLAUDE.md`.
- **The `closer.md` stale line the dev-writer found is fixed**, and fixed with a
  self-aware parenthetical (`closer.md:214-221`) explaining why a keyword sweep
  missed it. No residue found.
- **`ExitWorktree` mentions remaining (`README.md:512`, `closer.md:376`) are both
  retrospective** ("this step is gone"), not live instructions.
- **The "phantom test name … verified on this very piece" line in `design.md`
  (242-261)** is not a claim about *this* piece's own files — `nodeconfig.rs`
  does not exist anywhere in this worktree (`git grep` and `git log --all -- '**/nodeconfig.rs'`
  show it only on other, unrelated commits/branches). Read in context ("across
  two independently written pieces"), the passage is honestly describing a
  cross-branch verification act done while writing this entry, not asserting
  the file is part of this change. Not a finding.

## Findings

- [x] **`dev-writer`** — `.claude/agents/RUNNER.md:373` — "Dispatch into the
      piece's existing worktree" is the old dispatch model's phrasing, stale
      under this piece's own change.
      **Scenario:** a `closer` reports a red run; the runner, following this
      line to re-dispatch a `dev-writer`/`tester`/`spec-writer` fixer, could read
      it as placing the fixer inside the *runner's own* (piece) worktree — which
      is exactly the "crossing a dispatched agent into a pre-existing worktree"
      failure this whole piece exists to close (Route 2 in `README.md`'s "Handing
      over between agents"), or could think a special dispatch shape is needed
      beyond the ordinary `isolation: "worktree"` fork-from-HEAD used everywhere
      else. Nowhere else in the corrected files is a fixer told to land in "the
      piece's existing worktree" — every other writer dispatch (`dev-writer.md`,
      `spec-writer.md`, `tester.md`, and `RUNNER.md`'s own "Dispatching" section)
      says the agent arrives in its *own* fresh tree forked from the runner's
      HEAD and reports a harness-named branch for cherry-pick.
      **Measured:** `git grep -rn "existing worktree" -- .claude/agents CLAUDE.md docs`
      returns only this one line; it is the sole survivor of the old model's
      phrasing that the piece's own `tasks.md` sweep (which explicitly checked
      "Tree removal moves to the runner … and all three reviewer files") did not
      catch, because that sweep never targeted this section.

      **Fixed.** The line now says a fixer is dispatched the ordinary way —
      `isolation: "worktree"`, its own tree forked from the runner's HEAD,
      commits cherry-picked back — and states positively that nothing but the
      runner goes into the piece's worktree, naming the "Dispatching" section
      above as where that is measured. The re-sweep for the *shape* rather than
      the keyword (see the report) found three more of the same residue in
      `closer.md`, all fixed in the same commit: the findings gate and the
      rebase block both said "from the piece's worktree", and the rebase and
      archive pushes both named a local `piece/<name>` the closer is not on.
      No test can observe any of this; the check is the grep in the report.

- [x] **`dev-writer`** — `.claude/agents/README.md:88,194-196,528` and
      `.claude/agents/RUNNER.md:132` all say **the `dev-writer` opens the PR**,
      directly contradicting `.claude/agents/dev-writer.md:190-198`'s own
      section ("The PR, and why you no longer push it"): *"You do not push, and
      you do not open the PR… The runner cherry-picks onto `piece/<name>` and
      pushes, and the PR is opened against that."*
      **Scenario:** a `dev-writer` follows its own file (correctly, per the rest
      of this piece's changes) and hands back without pushing or opening a PR.
      A runner following `RUNNER.md:132` ("The `dev-writer` opens the PR, at the
      end of its first pass. If you are reaching for `gh pr create`, either it
      has not run yet or the PR exists.") concludes the PR must already exist
      and never runs `gh pr create` itself — and no file in the corrected set
      assigns that action to the runner. `RUNNER.md`'s "Dispatching" section
      (lines 146-181), which does describe the runner's cherry-pick-then-push
      sequence, never mentions opening the PR either. The piece is left with
      commits pushed to `piece/<name>` and no open PR, which is silent — nothing
      errors, the review agents still work fine against the branch, and the gap
      only surfaces when someone checks `gh pr list --state open` and finds
      nothing (the very check `RUNNER.md:134` prescribes for a *different*
      failure mode).
      **Measured:** `git grep -n "opens the PR\|open the PR\|opening the PR" --
      .claude/agents/README.md .claude/agents/RUNNER.md` returns the three
      "dev-writer opens the PR" lines; `git grep -n "gh pr create" -- .claude/agents`
      returns only the one line in `RUNNER.md` that presumes the dev-writer already
      did it. `dev-writer.md`'s contradicting section is unambiguous and reads as
      the piece's actual, deliberate design (it fits the rest of the "writers no
      longer push" changes); `README.md` and `RUNNER.md` were not updated to
      match on this one point.

      **Fixed, and the finding is right that nobody owned it** — the gap was
      real, not a wording clash. Resolved the other way round from what this
      finding assumed, though: **the `dev-writer` keeps the PR** (the user's
      decision), and `dev-writer.md:190-198` is what changed.

      The mechanical objection in that section had to be answered rather than
      overruled, because it is half correct. Its claim — commits are on
      `worktree-agent-<id>`, a PR must be opened against `piece/<name>` —
      is true; the conclusion "so you cannot" is not, because **a push does not
      require a checkout**. `git push origin HEAD:refs/heads/piece/<name>` sends
      the agent's tip to the remote piece ref without touching the local branch.
      The prohibition that objection actually supports is kept verbatim: never
      push `worktree-agent-<id>` *as itself*.

      Measured while deciding this, because the alternative fix looked cleaner:
      an agent **cannot** cherry-pick onto `piece/<name>` locally — it is checked
      out in the runner's worktree and git refuses it, `fatal:
      'piece/worktree-dispatch-fix' is already used by worktree at …`. That is
      why the prescribed form is a refspec. A dry-run push of the refspec form
      succeeded (`b7ec0ec..3123b5e  piece/worktree-dispatch-fix`), so the route
      is verified rather than assumed.

      Stated positively once, in `dev-writer.md`'s "The PR is yours" section,
      with the ordering explicit (push, `gh pr list`, `gh pr create`, then hand
      back) and the reason the earlier "you cannot" reasoning does not hold
      written beside it. `README.md:195`, `README.md:533` and `RUNNER.md:132`
      now point there instead of restating. `RUNNER.md:133`'s `gh pr create`
      line is kept but rewritten: it now tells the runner to check `gh pr list
      --head piece/<name>` rather than presuming, which was the part that made
      the original line a dead end.

      Three consequential edits fell out and are in the same commit:
      `RUNNER.md`'s "agent branches are local only" (a rule about the ref *name*,
      which the piece refspec does not violate), `README.md`'s branch table row
      (work now reaches the piece two ways, not only by cherry-pick), and
      `README.md`'s "only reviewers get a side branch" (false since writers
      stopped standing in the piece tree). Rationale in `design.md` under "The
      `dev-writer` opens the PR, by pushing a refspec rather than a branch".

- [x] **readability/architecture** — `.claude/agents/README.md:361-396` and
      `.claude/agents/RUNNER.md:183-223` duplicate the same probe evidence
      near-verbatim (both refusal-message quotes, in full, ~25-35 lines each) in
      two separately maintained files rather than one file stating it and the
      other pointing at it.
      **Scenario:** this is exactly the failure mode CLAUDE.md itself names
      ("two copies drift and the wrong one gets read") and that this very piece
      diagnoses in `closer.md`'s stale line. A future correction to the probe
      wording, or a fourth probe, has two places to update, and nothing here
      forces the second edit. Severity is moderate, not a functional defect
      today — both copies currently agree — but the piece's own design.md
      explicitly reasons about not duplicating instructions across documents
      elsewhere (e.g. "Take the `git -C` instruction … out of your briefs" and
      "kept there rather than restated here because two copies of a rule drift"
      in `RUNNER.md:533-536`), so the same standard applied to itself flags this.
      **Measured:** `git grep -n "the current working directory" -- .claude/agents/RUNNER.md .claude/agents/README.md`
      shows the identical clause in both files; comparing the two blocks line by
      line (`README.md:361-396`, `RUNNER.md:183-223`) shows the same two probe
      transcripts, same wording, reproduced rather than referenced.

      **Fixed. `README.md` owns the transcripts; `RUNNER.md` points at them.**
      The choice is argued in `design.md` under "One file owns the probe
      transcripts; the other points", not left implicit: the transcripts are
      evidence for a rule about dispatch, and `README.md` already holds that
      rule's full treatment (the `Works?` table, the pre-existing-versus-own-tree
      distinction). Splitting evidence from analysis would leave the analysis
      unsupported in the file people read to understand the flow.

      The counter-argument — the runner is the party that *acts*, so the evidence
      should sit where the actor reads — is recorded and rejected there too: the
      runner does not need the transcripts to act, only the instruction, and
      evidence and instruction have different readers. `RUNNER.md` keeps the
      operational consequence as three bullets (dispatch with isolation; never
      put `EnterWorktree` in a brief; do not read probe 1's message as a hint
      toward probe 2's failure) plus the measured cost, and drops both quoted
      refusal messages.

## Areas checked and clean

- `code-reviewer.md`, `design-reviewer.md`, `spec-test-reviewer.md`,
  `spec-writer.md`, `tester.md`, `closer.md` — read in full. All consistently
  reflect: agent arrives via `isolation: "worktree"` already forked from the
  runner's HEAD; must not call `EnterWorktree`; is on a harness-named branch,
  read via `git rev-parse --abbrev-ref HEAD` and reported, never assumed;
  pushes nothing; cannot remove its own tree (stands in it); hands back a
  branch name and a "ready to prune" line rather than trying to restore or
  step out. No contradictions found among these six.
- `docs/OPENSPEC-ARCHIVE.md` — the `openspec`-root-resolution fix is
  consistent with the rest of the piece and correctly framed as "fixed by
  where agents now stand," not by anything in the CLI.
- `.gitignore` — the negation-order logic (`.claude/*` → `!.claude/agents/` →
  `.claude/agents/*` → `!.claude/agents/*.md` → `!.claude/settings.json`)
  verified directly with `git check-ignore -v` against `.claude/settings.json`,
  `.claude/settings.local.json`, and `.claude/agents/scratch/tmp.json` — all
  three resolve exactly as the comment claims.
- `--no-track` and the `git config --get-regexp` replacement check are applied
  consistently everywhere the old `git branch -vv` check or bare worktree-add
  command appeared.
- Security: no new attack surface in a docs-only change; the
  `getCapabilities().canWriteLocal` guidance and FFI-boundary guidance in
  `code-reviewer.md` are unchanged and still correctly worded.
- Correctness of the two original defects' fixes (EnterWorktree refusal
  framing, `--no-track`/`autoSetupMerge` mechanism) matches the quoted probe
  transcripts and is internally consistent everywhere it appears outside the
  two findings above.

No CI gate can observe any of this — noted per the dispatch, not filed as a
finding.
