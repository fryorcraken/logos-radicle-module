# Readability findings — `findings-handover`

Reviewer: `code-reviewer`, single instance covering all four dimensions.

Judged against CLAUDE.md's own prose rules — say what a command cannot, make
recorded state self-invalidating, do not restate what is checkable — rather than
generic style.

## Clean

- The new README sections lead with the rule and follow with the reason, which is
  the pattern the rest of the file uses. Each rule states what breaks without it,
  so a future reader can tell it from decoration.
- The worked finding templates in `code-reviewer.md:174-180`,
  `spec-test-reviewer.md:175-180`, `design-reviewer.md:128-133` and
  `dev-writer.md:180-186` are concrete and use real examples from this repo's
  history (`onBranchChanged`, `guarded()`, `panic_guard.rs`), which is what makes
  the format teachable rather than abstract.
- `README.md:354-357`'s self-denying instruction — "The dimensions are listed in
  `code-reviewer.md`; read them from there rather than from a number here, so
  adding one does not make this sentence quietly false" — is exactly the
  self-invalidating form CLAUDE.md asks for. It survived the section move intact.
- The cross-reference at `README.md:437-441` ties the new gate back to the
  pre-existing "a green gate structurally unable to see" lesson instead of
  restating it. Good reuse of an existing idea rather than a parallel one.

## Findings

- [x] **`dev-writer`** — `.claude/agents/README.md:219` — the heading "Two files
      carry the state of a change" undercounts its own section
      The section documents `tasks.md`, `findings/<dimension>.md`, **and** `design.md`
      as the destination for durable reasoning (line 303-304: "Durable reasoning moves
      into `design.md` before the tracker goes"), plus it ends by assigning the
      runner's stage rows. The "two files" framing is accurate for the tracker pair
      and misleading for the section as written.
      **Scenario:** a reader skims for "where does the state live" and takes away two
      files, missing that `design.md` is the only one that survives the merge — which
      is the single most important fact in the section, since `findings/` is deleted.
      **Severity:** stylistic. A heading like "The files that carry a change's state"
      costs nothing and stops the undercount.

      **Fixed**, and treated as more than stylistic because the finding identifies what
      the undercount hides: `design.md` is the only one of the three that survives the
      merge. The heading is now "Where the state of a change lives while it is in
      flight", and the section says explicitly that `tasks.md` and `findings/` are both
      scaffolding — one deleted, one archived — which is *why* durable reasoning has to
      move into `design.md` before the tracker goes. That turns a loose cross-reference
      at the end of the section into the reason the section exists.

- [x] **`dev-writer`** — `.claude/agents/README.md:286` says "Four consequences
      worth knowing whatever your role" immediately above a four-item list
      Same class as the `CLAUDE.md` "Six" finding: a count written beside the thing it
      counts, which the next edit falsifies. CLAUDE.md's "Keeping this file true"
      names exactly this ("how many files a suite has"). The list is visible, so the
      error would be self-evident — but so was "Five", and this change had to edit it.
      **Scenario:** someone adds a fifth consequence and leaves "Four" in place.
      **Severity:** stylistic, reported for consistency with the `CLAUDE.md` finding.
      Note there are now at least three such counts in the changed files ("Six that
      catch people repeatedly", "Four consequences", "Two files carry the state"),
      which is a small pattern rather than a one-off.

      **Fixed** — now "What follows from that, whatever your role". The observation that
      it is a pattern across three sites rather than one slip is the part worth keeping:
      all three were written in the same sitting, which is how a rule you know gets
      broken three times. The other two are ticked in `correctness.md`.

- [x] **`dev-writer`** — `.claude/agents/README.md:164-165` — "Named for the role
      and not the stage, because `dev/x` invites a `test/x` beside it — which is the
      shape this section exists to stop" duplicates the argument made 50 lines earlier
      Line 129-130 already says "A stage is not a unit of review, even though each one
      looks like one. Splitting by stage optimises for the author's convenience at the
      reviewer's expense." And line 116-118 says it a third time ("What never happens
      is a *stage* reaching the remote on its own"). The phrase "which is the shape
      this section exists to stop" appears twice in the same section (lines 118 and 165).
      **Scenario:** a reader looking for *the* reason one-branch-per-piece holds finds
      three statements of it and cannot tell whether they are three reasons or one
      repeated. The risk over time is the ordinary drift risk: three copies, one edited.
      **Severity:** stylistic. One statement with the branch-naming corollary attached
      would be tighter.

      **Fixed** as suggested: the "a stage is not a unit of review" statement now carries
      the branch-naming corollary directly ("which is why the branches below are named
      for the role and not the stage"), and the standalone restatement 50 lines later is
      gone, along with the second "which is the shape this section exists to stop". One
      argument, one place, with its consequence attached — which also removes the
      three-copies-one-edited drift risk the finding names.

- [x] **`dev-writer`** — `.claude/agents/spec-test-reviewer.md:22` states both
      "You get a worktree of your own" and "Make it with `git worktree add`" in
      one sentence
      Reported as a correctness/consistency finding in `correctness.md` for the
      who-creates-it ambiguity; noted here because the sentence is also simply hard to
      read as written — the reader has to decide which half is the instruction.
      **Severity:** stylistic (the substantive half is in `correctness.md`; this box
      does not need separate action if that one is addressed).

      **Fixed** by the same edit as `correctness.md` box 5, as this box anticipated. The
      sentence now has one instruction in it: the runner gives you the worktree and names
      its path, and if it did not, stop and ask. "Make it with `git worktree add`" is
      retained only as the statement that a worktree is never a copy of the repo, which
      is a different claim and no longer competes with the first.
