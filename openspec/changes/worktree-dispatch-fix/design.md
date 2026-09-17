# Correcting two false instructions in the agent-flow documents

## Context

Both defects are instructions that were written from a plausible model of the
tooling rather than from a measurement, and both survived review because the
thing they describe *sounds* right. `EnterWorktree` exists and does move a
session, so telling an agent to call it reads as correct; `git worktree add` is
the documented way to make a worktree, so prescribing it reads as correct. What
neither document had was a run of the command.

The failure mode they share is the one CLAUDE.md's "Keeping this file true"
warns about — accuracy with a short half-life — with a twist. These were never
accurate. They were plausible, which is harder to catch, because a reader
checking the document against their memory of how the tools work will agree with
it.

## Decisions

### Make the fallback primary rather than keeping it as a contingency

The documents already contained the correct instruction — absolute paths and
`git -C <worktree> …` — as a fallback behind "if the call is refused". That
phrasing is what did the damage, because it sets the agent's expectation that
the first route works. An agent that hits a certain refusal on an instruction
labelled "before anything else" does not read on to the contingency; it concludes
its environment is broken and improvises. Measured: four agents in one session
hit the refusal, and two spent significant time on `env -C` and `cd &&`
workarounds, each of which costs the user an approval click.

**Considered and rejected: softening to "may refuse, try it first".** That is
the status quo with better wording, and it keeps the cost — every dispatched
agent still spends a tool call and a recovery on a call that cannot work. The
probe measured certainty, not a tendency, so the instruction should state
certainty.

**Considered and rejected: fixing the dispatch to use `isolation: "worktree"`.**
This is the tempting fix, because probe 1's refusal names precisely the condition
that `isolation: "worktree"` establishes — the agent's cwd ends up inside a
worktree, and `EnterWorktree` then succeeds. Probe 2 measured what happens next:
the agent splits. Read follows the switch and returns the piece branch's content
by relative path, while every Bash call is refused for resolving to "the shared
checkout". So the agent reads the right files, believes it is correctly placed,
and cannot run a single command — which for a reviewer means no mutation run
executes and for a tester means no suite runs, in both cases while the files on
screen look right.

**This is why every file says `isolation: "worktree"` does not rescue it, rather
than just "do not call `EnterWorktree`".** Route 2 is rediscoverable from route
1's error message alone: an agent told only "the call is refused at the
repository root" has been handed the diagnosis that points straight at the
isolation flag. Without the second half of the warning, the correction invites
the worse bug. **Remove those sentences and the next agent to read the refusal
message walks into a failure that produces green-looking work.**

### Drop the reviewers' `ExitWorktree(action: "keep")` step

The brief asked for this to be re-read rather than assumed either way, and it
turns out to be dead code. The step existed so a reviewer standing inside its
worktree could step out before `git worktree remove`, which refuses the directory
you are in. A dispatched reviewer never enters the worktree, so it is always in
the main checkout and the precondition holds already.

**Kept: the `git rev-parse --show-toplevel` check.** Deleting the step without
keeping the check would be the wrong simplification — the condition it enforces
is still real, and a future change to how agents are placed could reintroduce the
state. What is removed is the action, not the assertion. **Remove the check too
and a reviewer that somehow is standing in the tree gets `git worktree remove`'s
refusal, which reads as a permissions problem and sends it toward `--force` in
the wrong directory.**

### `--no-track` at creation, rather than repairing the config afterwards

`git worktree add <path> -b piece/<name> origin/main` branches from a
remote-tracking ref, so `branch.autoSetupMerge` writes `remote = origin` and
`merge = refs/heads/main`. The branch is configured to push to `main` from the
moment it exists. Verified with `git config --get-regexp "^branch\.piece"`, which
returned `merge refs/heads/main` for both piece branches created that way, and
the consequence was live: `git push origin piece/embedded-node-wizard` was
rejected by branch protection for `refs/heads/main`.

This is complexity in the data rather than the logic, in CLAUDE.md's sense. The
alternative — `git branch --unset-upstream` after creation, or a rule that every
push names a full refspec — is a guard that has to be got right at every call
site, by every agent, forever. `--no-track` makes the wrong push unrepresentable:
there is no upstream for a bare `git push` to resolve to.

**Considered and rejected: `push.default = nothing` or a repo-level config.**
It would work, but it is invisible in the documents that agents read, and it
changes behaviour for the human working in the main checkout too. The flag sits
in the command the runner is already told to run.

**What breaks without `--no-track`: the piece branch silently acquires `main` as
its push target.** The failure is not reliably loud — branch protection caught it
this time, but a repository without protection on `main`, or an agent pushing
before protection applies, gets commits on `main` with no error at all.

### Replace `git branch -vv` with `git config --get-regexp`

Both documents prescribed `git branch -vv` as the check before a push. It cannot
work: it prints `[origin/main]`, and that is exactly what a correctly-tracking
branch and a wrongly-tracking one both look like. An agent reading it has no way
to tell an intended upstream from a wrong one, so the check returns a value that
cannot discriminate — the documentation equivalent of a fake that returns the
same thing for every input.

`git config --get-regexp "^branch\.<name>"` **returning nothing** is the positive
signal, and it discriminates: a `--no-track` branch has no config lines at all,
where a tracking branch has two. Verified both ways — with `--no-track` the
creation output omits the "set up to track" line and the command returns nothing;
without it, `merge refs/heads/main` comes back.

Stating the expected result as "nothing" is deliberate. A check whose pass
condition is empty output is one an agent cannot misread as passing when it
printed something.

## What no gate can see

**No CI layer can observe any of this change.** The gates here check QML syntax,
Rust and C++ behaviour, and sitometres wiring; none reads an agent instruction
file. Saying so is the honest report rather than letting a green suite stand in
for coverage — which is the rule `.claude/agents/README.md` states about
structurally blind gates, applied to its own correction.

What stands in for a gate is that both corrections are re-runnable. The refusal
messages are quoted verbatim so a future reader can compare them against what the
tool says today, and `--no-track`'s effect is checkable in one `git config` call
from any worktree.

The one thing a reader can verify immediately: this piece's own branch was
created with `--no-track`, and `git config --get-regexp "^branch\.piece"` in its
worktree returns nothing.

## A constraint this surfaced rather than fixed

`openspec` resolves its root from the cwd and has no `-C` flag. With
`EnterWorktree` unavailable to dispatched agents and `cd <dir> && openspec …`
costing an approval click, **a dispatched agent has no clean way to run
`openspec` against a change that exists only in a worktree.**

This change does not solve that; it documents it in `closer.md` and
`docs/OPENSPEC-ARCHIVE.md`, with the instruction to report an unrun validation
rather than tick the row. The alternative shapes were considered and are worse: a
compound command costs the click on every call, and having the agent claim
validation it did not perform is the failure the flow's own rules exist to
prevent. An upstream `-C` flag on `openspec` is the real fix and is not this
change's to make.
