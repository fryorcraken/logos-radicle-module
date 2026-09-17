## Why

Two instructions in this repo's agent-flow documents are false, and both were
proven false by probes rather than argued about.

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

## Capabilities

### New Capabilities

None. This change corrects instruction files that govern how a change is made,
and adds no requirement to the module's behaviour contract.

### Modified Capabilities

None — `skip_specs: true`.

## Impact

`.claude/agents/README.md`, `.claude/agents/RUNNER.md`, the six agent files
under `.claude/agents/`, `CLAUDE.md` and `docs/OPENSPEC-ARCHIVE.md`. The
`EnterWorktree` instruction turned out to live in nine files, not the three the
work was scoped to — every agent file carries its own copy.

No source, no tests, no build. **No CI gate can observe any of this**, and
saying so is the honest report rather than letting a green suite stand in for
coverage: the layers that run here check QML syntax, Rust and C++ behaviour, and
none of them reads an agent instruction file. What replaces a gate is that both
corrections are stated as commands a reader can re-run — the refusal messages
are quoted verbatim, and `--no-track`'s effect is checkable with one
`git config` call.
