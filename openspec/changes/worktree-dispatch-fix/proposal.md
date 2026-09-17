## Why

Instructions in this repo's agent-flow documents were false, and each was proven
so by a probe rather than argued about. The piece began as two corrections and
grew a third as the session measured more of the same surface.

**Every dispatched agent is told to call `EnterWorktree` first, and it cannot
work.** The documents describe refusal as a possibility with a fallback —
"the call can be refused" — which reads as an edge case worth a contingency.
Refusal is certain: a dispatched agent starts with its working directory at the
repository root, and that is exactly the condition the tool refuses on. Four
agents in one session hit it, and two spent significant time inventing
workarounds (`env -C`, `cd &&`) that cost the user approval clicks, because the
documents told them the shape was supposed to work. An instruction that fails
every time it is followed is worse than no instruction, because the agent
spends its first minutes deciding the environment is broken rather than reading
the fallback.

**The worktree-creation command the runner is told to run is what makes a bare
`git push` land on `main`.** Both `RUNNER.md` and `CLAUDE.md` warn about that
push, and neither says what causes it. `git worktree add <path> -b piece/<name>
origin/main` branches from a remote-tracking ref, so `branch.autoSetupMerge`
configures the new branch with `merge = refs/heads/main` — the piece branch is
literally set up to push to `main`. The consequence was live this session:
`git push origin piece/embedded-node-wizard` was rejected by branch protection
for `refs/heads/main`. The prescribed check does not catch it either: `git
branch -vv` shows `[origin/main]`, and nothing in that output distinguishes an
intended upstream from a wrong one.

**The documents say what does not work and never said what does.** A later probe
measured `isolation: "worktree"` *without* an `EnterWorktree` call and found it
sound: the agent gets a fully working cwd in its own worktree, every Bash command
runs, and the branch is created with no upstream. That is not a reversal of the
first defect — the agent is in a *fresh* tree, not the *pre-existing* piece tree,
and crossing between them is exactly what fails.

**With `worktree.baseRef: "head"` that fresh tree also holds the right code**,
measured against a deliberately distinct fork point: runner HEAD `a949ec6`,
`origin/main` `cafa02b`, agent reported `a949ec6`. So an agent now gets the right
working directory and the right commits at once, with no `git -C`, no absolute
paths and no approval clicks — which is why this change **adopts** that dispatch
shape rather than merely recording it. The `git -C` fallback the first commit
made primary was correct for its moment and is now unnecessary.

**Three process traps were measured beside them**, each costing real work this
session: `run-qml-tests.sh`'s output truncates before the run ends, so a reviewer
misjudged a mutation; `lgs basecamp build` acts on the cwd's project root, so a
`dev-writer`'s first build silently built the main tree; and a reviewer removed
its own worktree against an explicit instruction, which was safe only by luck.

**The fabricated-number caution needs to be a step.** One review round found five
fabricated quantities and one phantom test name across two independently written
pieces. The existing wording tells an agent that this repo fabricates numbers,
which is a warning; what it does not do is name the action.

## What Changes

- **`EnterWorktree` becomes a tool a dispatched agent must not call**, in every
  file that currently tells one to. The fallback that was secondary — absolute
  paths and `git -C <worktree> …` — becomes the primary and only instruction.
  Each file states that `isolation: "worktree"` does not rescue it, so the
  second route is not rediscovered and mistaken for the answer.
- **What remains true for a session moving itself is kept**, in `CLAUDE.md`,
  where the tool is described for the case it is built for.
- **The reviewers' `ExitWorktree(action: "keep")` step is removed**, because a
  reviewer that never entered a worktree is never standing in one, so the step
  it guards against is unreachable.
- **`git worktree add` gains `--no-track`** wherever the flow documents show the
  command, with the reason recorded beside it.
- **`git branch -vv` is replaced as the check** by `git config --get-regexp
  "^branch\.<name>"` returning nothing, which discriminates where `branch -vv`
  does not.
- **`isolation: "worktree"` becomes the dispatch shape**, with `worktree.baseRef:
  "head"` in `.claude/settings.json` fixing the fork point to the runner's HEAD.
  The probes are recorded verbatim in `README.md`. Consequences carried through
  every agent file: **plain relative paths** replace `git -C` and absolute paths;
  the `EnterWorktree` prohibition leaves the briefs and survives only as the
  explanation for why dispatches look as they do.
- **`.claude/settings.json` is documented, not written.** It is the user's file,
  it already exists, and `.gitignore` excludes `.claude/*` — so the setting the
  flow now depends on travels with no clone and **fails silently when absent**,
  cutting every agent from `origin/main` instead. That failure mode is written
  down beside the requirement, because nothing errors when it happens.
- **The runner moves into its piece's worktree, one runner per piece.** This
  replaces RUNNER.md's "you stay in the main checkout". A session moving *itself*
  with `EnterWorktree` is the case the tool is built for and was measured
  succeeding; the per-piece split exists because the runner's HEAD is now the
  fork point, so a single runner juggling two pieces would silently fork agents
  from the wrong one.
- **Agents no longer remove their own worktrees**, because they are standing in
  them and `git worktree remove` refuses the directory you are in. Removal moves
  to the runner, which also resolves — by construction rather than by instruction
  — the case where a reviewer deleted a tree it had been told to keep.
- **Work returns by cherry-pick from a harness-named branch.** Every agent lands
  on `worktree-agent-<id>`, so each reports the branch it actually landed on
  rather than assuming `review/<name>/<dimension>`, and writers stop pushing the
  piece branch or opening the PR.
- **Three process traps are written where each bites**: `run-qml-tests.sh`
  truncation in `CLAUDE.md`'s test-layer section and `spec-test-reviewer.md`;
  `lgs basecamp build`'s root resolution in `dev-writer.md`, plus a table in
  `README.md` naming the class it shares with `openspec`; and the reason behind
  reviewer tree removal in `RUNNER.md` and all three reviewer files.
- **The fabricated-number caution becomes a required step** in `README.md`: run
  the command before writing the number, and re-measure rather than applying a
  reviewer's quoted delta.
- **One stale line found by the survey is fixed**: `closer.md` still told the
  closer it had "entered the worktree as this file says", contradicting two other
  passages in the same file. It survived the first pass because it never names
  `EnterWorktree`, so the `grep -rn "EnterWorktree"` sweep could not see it.

## Capabilities

### New Capabilities

None. This change corrects instruction files that govern how a change is made,
and adds no requirement to the module's behaviour contract.

### Modified Capabilities

None — `skip_specs: true`.

## Impact

`.claude/agents/README.md`, `.claude/agents/RUNNER.md`, the seven agent files
under `.claude/agents/`, `CLAUDE.md` and `docs/OPENSPEC-ARCHIVE.md` — **eleven
files**, measured with `grep -rln "EnterWorktree"` over `.claude/agents/`,
`CLAUDE.md` and `docs/` rather than carried from the earlier estimate. The work
was originally scoped to three; the first sweep found nine; the correct figure is
eleven. Every agent file carries its own copy of the instruction, which is why
the number keeps being larger than it looks.

**Scoping by grep is itself a finding, and it has now failed twice.** The first
pass scoped to three files and the sweep found nine. This pass found a tenth
defect the sweep structurally could not: `closer.md`'s "if you entered the
worktree as this file says" contradicted the correction while never naming the
tool, so `grep -rn "EnterWorktree"` returned nothing for it. **A keyword sweep
finds every copy of an instruction and no paraphrase of it** — the residue has to
be read for, not grepped for.

No source, no tests, no build. **No CI gate can observe any of this**, and
saying so is the honest report rather than letting a green suite stand in for
coverage: the layers that run here check QML syntax, Rust and C++ behaviour, and
none of them reads an agent instruction file. What replaces a gate is that both
corrections are stated as commands a reader can re-run — the refusal messages
are quoted verbatim, and `--no-track`'s effect is checkable with one
`git config` call.
