# Correctness findings — `findings-handover`

Reviewer: `code-reviewer`, single instance covering all four dimensions.
Scope: the prose change on `piece/findings-handover` (`git diff main`) —
`CLAUDE.md`, `.claude/agents/README.md`, and the six agent files.

For a prose change, "correctness" is read as: does a statement contradict
another statement in the same file or a sibling file, and is each factual claim
about a command, path or tool behaviour actually true.

## Verified true (no finding)

Stated here so the clean areas are on the record rather than implied by absence.

- `grep -rn "^- \[ \]"` does what the README says: run against a fixture
  directory holding one file with an open box, one with only a ticked box, and
  one written as plain headings, it returned exactly the open-box line.
- `grep -rc "^- \[" findings/` discriminates as claimed: `0` for the
  heading-only file, non-zero for both box files. The pair therefore does catch
  the "gate cannot see the file it is gating" failure the README credits it with.
- `openspec validate --strict` is a real flag (`openspec validate --help`).
- `openspec archive` exists and updates main specs (`openspec archive --help`).
- `git log --oneline origin/<orphan> --not origin/piece/<name>` is valid syntax
  and runs (checked with local refs).
- No dangling reference to `docs/OPENSPEC-ARCHIVE.md` anywhere in `.claude/`,
  `CLAUDE.md`, `docs/` or `openspec/`. The sibling repo's file was not carried over.
- The stage block appears twice — `README.md` and `spec-writer.md` — and the two
  copies are byte-identical today.
- Every path mentioned either exists (`openspec/changes/archive/`,
  `openspec/specs/`, `.claude/agents/*.md`, `docs/rust-ffi.md`, `docs/writes.md`,
  `docs/e2e.md`) or is one the flow creates per change
  (`openspec/changes/<name>/findings/`, `tasks.md`, `design.md`).

## Findings

- [x] **`dev-writer`** — `.claude/agents/design-reviewer.md:144` contradicts
      `.claude/agents/README.md:162` and `:257` on the branch name
      The README's branch table gives the pattern `review/<name>/<dimension>`, and
      the README's own dimension list at line 257 names this reviewer's dimension
      `design-review` (deliberately, "not `design.md`, which is the change's own
      document"). `design-reviewer.md` then says to commit on
      `review/<name>/design`.
      **Scenario:** a `design-reviewer` follows its own file and creates
      `review/embedded-wizard/design`; the runner, auditing against the README
      pattern plus the dimension list, looks for `review/embedded-wizard/design-review`
      and finds nothing. Since the branch is local-only and never pushed, there is
      no `origin/` ref to make the mismatch visible — exactly the class of silent
      divergence this change is trying to close. The same file gets the *filename*
      collision right (`design-review.md`), which makes the branch-name
      inconsistency look like an oversight rather than a decision.
      **Severity:** low as a defect, but it is the one place in the change where two
      files state the same rule differently, which is the thing the task asked about.

      **Fixed.** `design-reviewer.md` now says `review/<name>/design-review`, and the
      README states the rule that makes it derivable rather than memorable: the branch
      suffix *is* the findings filename without its extension. It also records why
      nothing catches a mismatch — the branch is never pushed, so there is no `origin/`
      ref to diverge visibly.

- [x] **`dev-writer`** — `.claude/agents/README.md:377` reuses "six" for a
      different set than the rest of the section
      Lines 149, 181, 184, 259-260, 340-342 all use "six" to mean *reviewer
      instances* (four `code-reviewer` dimensions + `spec-test-reviewer` +
      `design-reviewer`). Line 377 says "This applies to all six roles", meaning the
      six *agent definition files* — of which only three are reviewers.
      **Scenario:** a reader who has just absorbed "reviewers run in parallel, up to
      six" reaches "all six roles, and the reviewers most of all" and has to
      re-derive which six is meant. Both numbers are correct; the collision is that
      one word carries two denotations 200 lines apart. Line 377 is pre-existing
      text, but this change is what introduced the competing sense of "six" above it.
      **Severity:** readability, not a defect.

      **Rejected**, with the reason recorded because the next reviewer will see it too.
      Both uses are correct and neither is load-bearing: "six roles" counts agent files
      and "up to six" counts concurrent reviewers, and the coincidence is arithmetic —
      four dimensions plus two other reviewers happens to equal the number of role
      files. Rewording either to avoid a collision 200 lines away would make one of
      them less direct to fix an ambiguity that resolves from its own sentence. The
      counts elsewhere in the change *were* dropped, but for a different reason: those
      sat beside the list they counted and would go stale when it grew, which is the
      half-life problem. Neither "six" has that property.

- [x] **`dev-writer`** — `.claude/agents/README.md:343-346` tells the runner to
      "take the sync" unconditionally, but `openspec archive` has `--skip-specs`
      for precisely the case this change adds support for
      `openspec archive --help` documents `--skip-specs` as "useful for
      infrastructure, tooling, or doc-only changes". The README now explicitly
      blesses docs-only and test-only pieces ("A piece with no behaviour change
      still gets a change folder and a stage block", line 247), which have no spec
      delta by construction.
      **Scenario:** a docs-only piece reaches the last stage row. The runner follows
      "take the sync" and runs `openspec archive` plain. There is no delta to
      promote, so either the step is a no-op or it prompts about a spec update the
      change does not have — and the instruction gives no way to tell which outcome
      was correct. The sentence was written when every change had a delta; the same
      commit that removed that assumption left the sentence alone.
      **Severity:** low. A real gap in the new docs-only path, not a wrong claim.

      **Fixed.** "Take the sync" is now conditional on the change having a delta, and
      the `skip_specs: true` case is named as archiving with `--skip-specs`. Verified
      the flag exists and that its help text names doc-only changes
      (`openspec archive --help`) rather than taking the finding's word for it. This
      change is itself the first piece on that path, so the gap was live.

- [x] **`dev-writer`** — `CLAUDE.md:163` — "Six that catch people repeatedly" is a
      count, which CLAUDE.md's own "Keeping this file true" section says not to write
      The change edits "Five" to "Six" to account for the new pipe bullet. The rule
      it is under reads: "Do not write down anything a command can answer… how many
      files a suite has."
      **Scenario:** the next person adds a seventh trap and does not notice the
      number two lines above the list, and the file carries a false count — which is
      exactly the half-life failure the section was written to prevent, in the file
      that contains the section. The count is admittedly self-invalidating against
      its own visible list, which is the weakest version of the problem, but the fix
      is free: drop the numeral ("A few that catch people repeatedly", or just
      "These catch people repeatedly").
      **Severity:** low, and arguably stylistic — but it is a rule this repo wrote
      down about itself, so it is reported as a defect rather than a preference.

      **Fixed**, and the finding is right that this was the sharpest instance: the diff
      had to *edit* the numeral, which is the demonstration that it rots. Now "The ones
      that catch people repeatedly". Two more of the same shape introduced by this
      change went with it — "Four consequences" in the README, and the "Two files carry
      the state" heading, which also undercounted: `design.md` is the third and the only
      one that survives the merge, so that heading is now about where in-flight state
      lives and says explicitly which file outlives it.

- [x] **`dev-writer`** — `.claude/agents/README.md:151-152` says reviewers are given
      worktrees; `code-reviewer.md:25` and `spec-test-reviewer.md:22` tell the
      reviewer to create its own, while `code-reviewer.md:208` says it is given one
      Three statements about the same mechanic:
      README: "They get a worktree each". `code-reviewer.md:208`: "You **are given**
      a worktree of your own under `.claude/worktrees/` and a branch named
      `review/<name>/<dimension>`". `code-reviewer.md:25` (in the same file, 180
      lines earlier): "Make it with `git worktree add`". `spec-test-reviewer.md:22`:
      "**You get** a worktree of your own … **Make it with** `git worktree add`" —
      both halves in one sentence.
      **Scenario:** a reviewer that believes it was given a worktree looks for one,
      finds the runner did not create it (the README never tells the runner to, and
      the runner's stage rows at 339-346 do not include it), and either works in the
      shared piece tree — the exact failure mode the section exists to prevent, since
      it would break the code a concurrent fixer is editing — or creates one, making
      the "you are given" sentence false. Who creates the reviewer worktree is
      genuinely unstated anywhere in the change.
      **Severity:** medium. This is the one inconsistency with a plausible path to a
      concrete bad outcome, because the fallback behaviour on ambiguity (use the tree
      you are standing in) is the dangerous one.

      **Fixed**, and this was the most valuable finding of the review because the
      ambiguity was invisible to me — I had written all three sentences. **The runner
      creates the worktree and names its path in the dispatch**, the reviewer deletes
      it, and a reviewer given no path **stops and asks** rather than choosing either
      fallback. Stated in the README and in all three reviewer files, with the reason:
      the failure on ambiguity is destructive in *both* directions, and the finding
      named only one of them. Assume-you-must-create means mutating the piece's tree;
      assume-you-were-given means `--force`-removing a tree that may hold the only copy
      of somebody's work. Paired with the guard conditions in the security finding below.

- [x] **`tester`** — `.claude/agents/README.md:292-296` — the gate grep's `^`
      anchor silently misses an indented finding, and the sanity grep does not catch
      that case
      **Measured.** A fixture findings file containing a ticked top-level box and an
      indented open box:
      ```markdown
      - [x] **`dev-writer`** — `c.qml:3` — done
            - [ ] an indented nested box, leading whitespace
      ```
      `grep -rn "^- \[ \]"` over the directory did **not** report it — the file reads
      as having no open findings. `grep -rc "^- \["` reported `1` for that file,
      i.e. non-zero, so the companion check the README offers as the guard against
      exactly this ("confirm the files have boxes at all") passes too. Both gates are
      green on a file with an unaddressed finding in it.
      **Why it is reachable:** the change's own finding template is multi-line with
      indented continuation lines (`**Scenario:**`, `**Measured:**`), so a reviewer
      writing a sub-point under a finding — or a fixer appending an indented
      follow-up box per `dev-writer.md:176`'s "append below it" — produces this shape
      without doing anything the instructions forbid. Nothing in the change tells a
      reviewer that a finding box must start at column zero.
      **Severity:** medium. The README devotes a paragraph (and a cross-reference at
      437-441) to the argument that this gate pair is trustworthy *because* the
      second grep covers the first one's blind spot. That argument holds for the
      heading-only case it names and fails for the indentation case it does not.

      **Fixed.** Reproduced independently before changing anything — a file with a
      ticked top-level box and an indented `- [ ]` is reported clean by the open-box
      grep *and* returns `1` from the sanity grep, so both gates pass on an
      unaddressed finding. The fix is a rule rather than a cleverer pattern, because
      a pattern that matched indented boxes would then match any nested list a
      reviewer writes: **every box starts at column zero**, the `^` anchor is named as
      load-bearing, and appending under an entry is prose — a second thing that must
      happen is a second top-level entry. The README now states this as the first of
      two rules about the gate, ahead of the sanity grep, since it is the one the
      entry format itself can defeat.
