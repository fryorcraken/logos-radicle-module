# Architecture findings — `findings-handover`

Reviewer: `code-reviewer`, single instance covering all four dimensions.

For a docs change, "architecture" is read as the task framed it: is a rule stated
in two places where it can drift, and does each rule live in the file whose reader
needs it — an agent reads its own definition, the README is the shared vocabulary.

## Clean, and worth saying so

- **The central split is right.** Per-agent mechanics (which branch I commit on,
  which findings file is mine, which row I tick) live in each agent's own file;
  the shared vocabulary (what a stage block is, what a findings file looks like,
  why one branch per piece) lives in the README. An agent is given one file and
  that file is sufficient for its job, which is the property that matters when the
  reader is a subagent that will not read the README.
- **The section move is a genuine relocation, not a copy.** The old "Two steps
  belong to whoever is running the change" block and the three-reviewer split were
  *deleted* from their old position and reappear under "Handing over between
  agents" / the runner's stage rows. `git diff` shows matching deletions for every
  moved paragraph — no duplicate left behind.
- **The worktree-mechanics cross-reference is the right shape.** `README.md:190-194`
  points at CLAUDE.md's "Working in a git worktree" for the git-level rules
  (branching from `origin/main`, the shared stash stack) instead of restating them.
  The old `code-reviewer.md` paragraph that restated them was deleted.
- **`tasks.md`'s one-row-per-agent-instance design is complexity in the data
  structure rather than the logic**, which is CLAUDE.md's stated preference: the
  no-conflicting-cherry-picks property holds by construction because no agent ever
  writes a line another agent writes. The README states that reason explicitly at
  241-242.
- **`design-review.md` rather than `design.md`** is the same instinct applied to a
  filename collision, and the reason is written down where the collision would
  happen (`design-reviewer.md:121-122`).

## Findings

- [x] **`dev-writer`** — the stage block is duplicated verbatim in
      `.claude/agents/README.md:224-236` and `.claude/agents/spec-writer.md:31-43`,
      with nothing marking either as the source
      The two copies are byte-identical today (verified by reading both). Neither says
      "the canonical list is in the other file"; both present it as the block to write.
      **Scenario:** a new reviewer dimension is added to `code-reviewer.md`. Whoever
      adds it updates the README's block, because the README is where the review roster
      is discussed (353-357). `spec-writer.md` keeps the old block, and `spec-writer`
      is the agent that actually *writes* the block into `tasks.md` — so every new
      change gets the stale roster, and the missing row is invisible precisely because
      the mechanism's whole purpose is that a missing row is visible.
      **Why this is the finding that matters:** the change already identified and
      solved this exact drift risk one section away. `README.md:355-357` refuses to
      write a dimension *count* and points at `code-reviewer.md` instead, "so adding
      one does not make this sentence quietly false". The stage block is the same
      hazard with higher stakes — a whole list rather than a number — and it was
      duplicated rather than pointed at. One of the two should be illustrative and say
      so ("the block `spec-writer` writes; `spec-writer.md` has the copy it works
      from"), or the README's copy should be trimmed to a pointer.
      **Severity:** medium. No current defect; a structural drift risk the change
      demonstrably knows how to avoid.

      **Fixed**, and the finding's own framing is what decided the direction: the
      change solves this hazard one section away by refusing to write the dimension
      *count*, so the consistent move is to refuse to write the roster twice.
      `spec-writer.md` is canonical, because it is the agent that writes the block into
      `tasks.md` — the copy that is acted on should be the copy that is maintained. The
      README now describes the block's shape and points there, saying why.

- [x] **`dev-writer`** — the "never `git add -A`" rule is now stated in five files
      with five slightly different lists of what the tree collects
      `README.md:186-189` ("`.scaffold/`, `target/`, `result-*` symlinks" and `./tmp/`),
      `code-reviewer.md:197-199` (same four), `dev-writer.md:163-166` (same four),
      `tester.md:172-173` (same four), `spec-writer.md:17-18` ("build output and
      `./tmp/` scratch" — abbreviated, no list).
      **Scenario:** a new build artefact appears (say `.direnv/`, or a second
      out-link prefix). Four of the five lists get updated and the fifth does not, and
      the one that does not is whichever file the next agent happens to be reading.
      More likely: nobody updates any of them, and the lists become a historical
      record of what the tree collected in 2026.
      **This is CLAUDE.md's own "fourth slightly-different copy of a guard" signal.**
      The repo's stated response to that signal is to reshape rather than to add
      another copy. The reshape here is cheap: state the artefact list once in the
      README (or in CLAUDE.md, beside the `./tmp/` section that already exists) and
      have each agent file say "never `git add -A` — commit named paths; see the
      README for why" in one line. Each agent file keeps the rule its reader needs
      without keeping the list that rots.
      **Counter-argument, stated fairly:** an agent reads only its own file, so the
      rule itself genuinely must be repeated — that part is correct and is not the
      finding. The finding is that the *list of artefacts* is repeated with it, and
      the list is the part that changes.
      **Severity:** low-medium. Redundancy by design for the rule; drift risk for
      the list.

      **Fixed**, taking the reshape as described, and the counter-argument was the
      useful half: the *rule* must be repeated because an agent reads only its own
      file, and only the *list* is duplication. The README's branch section is now the
      canonical list and says so; the four agent files keep the rule plus the reason
      their own reader needs — a reviewer sweeping up a fixer's edit, a fixer sweeping
      up a findings file — and point here for the artefacts. Each file also gained the
      consequence specific to it, which the flat repetition had flattened away.

- [x] **`dev-writer`** — "you share the piece worktree because at most one of the
      three writers runs at a time" is argued from scratch in four places
      `README.md:138-147`, `spec-writer.md:13-15` + `145-150`, `dev-writer.md:148-151`,
      `tester.md:133-142`. Each derives the reason independently (spec moving under a
      dev; `tester` mutating code it does not own), and `tester.md` and the README give
      the same two reasons in different words.
      **Scenario:** the concurrency rule is relaxed later — say `tester` is given its
      own worktree so it can run alongside a fixer. Four arguments must be found and
      retired, and the one that is missed becomes an instruction contradicting the new
      rule, in a file some agent reads as authoritative.
      **Why it is nonetheless defensible:** unlike the artefact list, the *reason* is
      what makes an agent comply rather than work around the rule, and an agent reads
      only its own file. A bare "share the tree" without the reason invites exactly the
      workaround the section forbids. So this is reported as a known cost of the
      one-file-per-agent shape rather than as something to fix now — but it is worth
      recording in `design.md` that the duplication was chosen, so the next person
      relaxing the rule knows there are four sites and not one.
      **Severity:** low. Informational; the action may legitimately be "record the
      decision, change nothing".

      **Fixed as the finding proposed** — recorded, nothing relaxed. The README's
      worktree paragraph now says the repetition is a chosen cost rather than an
      oversight, gives the reason (an agent reads only its own file, and a bare "share
      the tree" invites the workaround), and names the consequence that makes the
      record worth keeping: **relaxing the rule means retiring four sites, not one.**
      There is no `design.md` for this change, so the README is where a recorded
      decision lives.

- [x] **`dev-writer`** — `CLAUDE.md:19-24` now carries a four-line summary of the
      branch/findings mechanism whose full statement is in
      `.claude/agents/README.md`, and the same table row above it points there
      The index row (line 13) was updated to advertise the new content ("how a change
      lands — one branch, one PR, findings in a tracked file"), which is the right
      move. The body paragraph then also summarises the mechanism: one branch, one PR,
      the stage block's location, the findings directory, and who deletes it.
      **Scenario:** the deletion owner changes (say the last fixer takes it over
      instead of the runner, or a CI check takes it over). `.claude/agents/README.md`
      is updated because that is where the runner's stage rows live; `CLAUDE.md`'s
      "which the runner deletes before merge once none is empty" is not, and CLAUDE.md
      is the file most likely to be in an agent's context from the start — which
      CLAUDE.md itself says, in "Working in a git worktree": "A stale `CLAUDE.md` is
      the most likely thing to mislead you, because it is the file most likely to be
      in context from the start and least likely to be re-read."
      **Severity:** low. The summary is genuinely useful at the index level; the
      specific detail that can drift is "which the runner deletes before merge once
      none is empty", which is a mechanism detail rather than an orientation fact and
      could be dropped without losing the pointer's value.

      **Fixed** exactly as scoped — the orientation facts stay (one branch, one PR,
      where the two state files live), and the ownership clause goes, replaced by a
      line saying that who owns each and what must hold before a merge is in the flow
      README rather than repeated. The finding's citation of CLAUDE.md against itself
      is what makes it persuasive: that file states it is the one most likely to be in
      context from the start and least likely to be re-read, which is precisely the
      wrong place for a mechanism detail.
