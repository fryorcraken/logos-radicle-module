## Stages

- [ ] ~~spec — `spec-writer`~~ — docs-only: no behaviour change, so no spec delta. Declared `skip_specs: true` alongside `schema:` in `.openspec.yaml`.
- [x] design + code — `dev-writer`
- [ ] tests — `tester`
- [x] review: correctness — `code-reviewer`
- [x] review: security — `code-reviewer`
- [x] review: readability — `code-reviewer`
- [x] review: architecture — `code-reviewer`
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

### Defect 3 — the flow moves to `isolation: "worktree"` with `baseRef: "head"`

- [x] `README.md` — records both probes verbatim, then the adopted route: the
      three-row table separating *pre-existing tree* (fails), *own tree*
      (works), and *session moving itself* (works). Placed immediately after the
      "no supported way … pre-existing worktree" paragraph, which **stays true
      and stays put**, so the distinction is read as one thought.
- [x] `RUNNER.md` — one runner per piece, in its piece's worktree, with the
      rejected alternatives and why the silent-wrong-fork hazard decided it.
- [x] `CLAUDE.md` — the short form in the existing `EnterWorktree` bullet.
- [x] The `.gitignore` consequence is documented wherever the setting is: the
      file reaches no clone, and **nothing fails when it is absent** — agents are
      simply cut from `origin/main`. Verified with `git check-ignore -v`.
- [x] Every copy says **settings are the user's**; this change does not create
      or edit `.claude/settings.json`.
- [x] Briefs lose the `git -C` instruction and the `EnterWorktree` prohibition;
      the prohibition survives as explanation only. Updated in `README.md`,
      `RUNNER.md`, `spec-writer.md`, `dev-writer.md`, `tester.md`, `closer.md`,
      `code-reviewer.md`, `spec-test-reviewer.md`, `design-reviewer.md`.
- [x] Cherry-pick hand-off: every agent reads its branch with `git rev-parse
      --abbrev-ref HEAD` and reports it, since the harness names it
      `worktree-agent-<id>` rather than the runner choosing it.
- [x] Writers stop pushing `piece/<name>` and stop opening the PR; the branch
      table in `README.md` is rewritten to match.
- [x] Tree removal moves to the runner in `RUNNER.md`, `CLAUDE.md`, `README.md`
      and all three reviewer files — an agent standing in its tree cannot remove
      it, so the old instruction would fail every time it was followed.
- [x] The writer-serialisation rule is re-grounded: it was "they share a tree",
      it is now "each dispatch forks from the runner's HEAD, so cherry-pick
      before dispatching the next". Same rule, a reason that is still true.

### Three process traps, each measured this session

- [x] `run-qml-tests.sh` output truncation → `CLAUDE.md`'s test-layers section
      and `spec-test-reviewer.md`, both prescribing `qmltestrunner -input <one
      file>` and both saying explicitly **not** to pipe to `tail`.
- [x] `lgs basecamp build` acts on the cwd's project root → `dev-writer.md`.
      The dispatch change **fixes the cause**, so the note is reframed: run it
      plainly, and remember that a wrong-tree build succeeds silently.
- [x] `README.md` records the class `lgs` shares with `openspec` — tools that
      resolve their root from the cwd — and that placing the agent correctly
      fixes both at once, which is the argument for the dispatch shape.
- [x] Reviewer tree removal → `RUNNER.md`, `CLAUDE.md`, `README.md` and all
      three reviewer files. Planned as a fourth precondition; it became an
      **impossibility** instead, because an agent now stands in its tree. The
      reasoning is kept, attached to the runner that owns removal.

### The fabricated-number caution becomes a step

- [x] `README.md` — "run the command before you write the number", naming
      `grep -c "function test_"`, `grep -c "#\[test\]"` and `git log -S`.
- [x] The same passage requires a **fresh measurement** when correcting a stale
      number, rather than applying a reviewer's quoted delta.
- [x] Applied to this change's own writing: the illustration cited is the one
      re-measured here, and the re-measurement changed the claim — see below.

### A stale line the first pass could not have found

- [x] `closer.md` — "If you entered the worktree as this file says, you are
      already in the right place" contradicted `closer.md`'s own line 34 and its
      "You never entered one". It never names `EnterWorktree`, so the first
      pass's `grep -rn "EnterWorktree"` sweep was structurally blind to it. Fixed,
      with a parenthetical recording why the sweep missed it.

### Verification

- [x] `git config --get-regexp "^branch\.piece"` in this piece's own worktree
      returns nothing (exit 1) — this branch was created with `--no-track`, and
      the check is the one now prescribed.
- [x] The `EnterWorktree` file count in the proposal was **re-measured**, not
      carried: `grep -rln "EnterWorktree"` over `.claude/agents/`, `CLAUDE.md`
      and `docs/` now returns eleven files. The proposal states both numbers and
      what each counts.
- [x] The phantom test name was re-measured rather than quoted. The reviewer
      reported `nodeconfig.rs` citing
      `an_external_address_carrying_a_node_id_is_refused`; that string has **zero
      hits** in `radicle/rust-ffi/`, and the branch now carries
      `an_external_address_with_a_node_id_is_refused_although_the_crate_accepts_it`
      at `nodeconfig.rs:353`, which exists at `:540`. **The finding was real when
      filed and is already fixed** — so quoting it as a live defect would have
      been the exact error the rule forbids. That is why `design.md` cites it as
      the illustration.
- [ ] No CI gate can observe a docs-only change. Stated in the proposal rather
      than reported as covered. The second commit makes this sharper, not
      weaker: two of its three traps describe gates that pass while being
      unreliable, so running them proves nothing about the corrections.
