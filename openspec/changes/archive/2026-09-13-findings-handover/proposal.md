## Why

Review findings had no home. A reviewer reported them to whoever was
orchestrating the change, who then paraphrased them into the next agent's brief —
so a claim arrived separated from the evidence that backed it, and nothing could
contradict it, because no artifact held it. Which stages a change had been
through had no home either: it lived in the runner's memory, where a missing
reviewer is invisible until somebody thinks to ask.

Both are the same defect in two places — state that matters to more than one
agent, kept somewhere only one agent can see.

## What Changes

- **Findings become a tracked file per reviewer**,
  `openspec/changes/<name>/findings/<dimension>.md`, every entry an unticked
  checkbox. Whoever acts on one flips the box and appends the outcome — fixed,
  rejected with the argument, or deferred and where to — without editing the
  reviewer's text. The runner deletes the directory before merge once no box is
  empty, having first moved anything durable into `design.md`.
- **`tasks.md` opens with a stage block**: one checkbox row per agent *instance*,
  written unticked by `spec-writer`, flipped by the instance that did the work.
  An unticked row with no agent running is a stage nobody is doing.
- **The branch rules are written down.** One piece of work is one branch
  (`piece/<name>`) and one PR; only reviewers get a side branch, because only
  reviewers run in parallel; only the runner pushes.
- **Each agent file says where its agent works, what it commits, and what it
  deletes when it finishes.** A reviewer removes its worktree rather than
  restoring it, because a restore depends on having tracked every edit and one
  missed restore ships a deliberately broken line that will not fail the suite.
- `CLAUDE.md` points at both from its flow-table row, and gains the Bash-cost
  rule that a long output is not a reason to pipe.

## Capabilities

### New Capabilities

None. This change alters the instruction files that govern how a change is made,
and adds no requirement to the module's behaviour contract.

### Modified Capabilities

None — `skip_specs: true`.

## Impact

`.claude/agents/README.md`, the six agent files under `.claude/agents/`, and
`CLAUDE.md`. No source, no tests, no build. Nothing a CI gate can observe, which
is itself a finding the flow's own rules require stating rather than letting a
green suite stand in for coverage.
