## Stages

- [ ] ~~spec — `spec-writer`~~ — docs-only: no behaviour change, so no spec delta. Declared `skip_specs: true` alongside `schema:` in `.openspec.yaml`.
- [x] design + code — `dev-writer`
- [ ] tests — `tester`
- [ ] review: correctness — `code-reviewer`
- [ ] review: security — `code-reviewer`
- [ ] review: readability — `code-reviewer`
- [ ] review: architecture — `code-reviewer`
- [ ] review: spec-test — `spec-test-reviewer`
- [ ] review: design — `design-reviewer`
- [ ] findings all ticked, `findings/` deleted — `closer`
- [ ] `openspec validate --strict`, then `archive` — `closer`
- [ ] CI green, title/body checked, PR merged — `closer`

## Implementation

### Defect 1 — `EnterWorktree` cannot work for a dispatched agent

- [x] Sweep for every copy of the instruction. `grep -rn "EnterWorktree"` over
      `.claude/agents/`, `docs/` and `CLAUDE.md` returns **nine** files, not the
      three the brief scoped: `README.md`, `RUNNER.md`, `dev-writer.md`,
      `tester.md`, `spec-writer.md`, `closer.md`, `code-reviewer.md`,
      `spec-test-reviewer.md`, `design-reviewer.md`, plus `CLAUDE.md` and
      `docs/OPENSPEC-ARCHIVE.md`.
- [x] `RUNNER.md` — the dispatch brief no longer tells the agent to enter the
      worktree; it names the absolute path and the `git -C` form directly.
- [x] `README.md` — "Handing over between agents" states the tool must not be
      called by a dispatched agent, with both probe results.
- [x] The six agent files — each replaces its "enter it first / the call can be
      refused" pair with the absolute-path instruction.
- [x] `CLAUDE.md` — keeps `EnterWorktree` for a session moving itself, which is
      what it is built for, and says it is not for a dispatched agent.
- [x] `docs/OPENSPEC-ARCHIVE.md` — same correction for its `openspec`-from-the-
      worktree step.
- [x] Re-read the reviewers' `ExitWorktree(action: "keep")` step in that light
      rather than assuming. It is unreachable for a dispatched reviewer and is
      removed; see `design.md`.

### Defect 2 — `git worktree add` creates branches that push to `main`

- [x] `RUNNER.md` — the worktree-creation command gains `--no-track`, with the
      `autoSetupMerge` mechanism recorded beside it.
- [x] `README.md` and `CLAUDE.md` — the bare-`git push`-lands-on-`main` warning
      now names its cause instead of only its symptom.
- [x] Replace the `git branch -vv` check in `README.md`, `dev-writer.md`,
      `tester.md` and `closer.md` with `git config --get-regexp
      "^branch\.<name>"`, which returns nothing when the branch is correct.

### Verification

- [x] `git config --get-regexp "^branch\.piece"` in this piece's own worktree
      returns nothing (exit 1) — this branch was created with `--no-track`, and
      the check is the one now prescribed.
- [ ] No CI gate can observe a docs-only change. Stated in the proposal rather
      than reported as covered.
