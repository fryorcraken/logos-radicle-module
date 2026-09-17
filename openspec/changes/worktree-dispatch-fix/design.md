# Correcting the agent-flow documents' worktree and measurement instructions

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

### Adopt `isolation: "worktree"` with `baseRef: "head"` as the dispatch shape

A third probe measured `isolation: "worktree"` with **no** `EnterWorktree` call
and found it works completely: `pwd` gave the agent's own worktree, `git status`
reported a clean tree on its own branch, every Bash command ran without refusal,
and relative-path `Read` and `ls` both worked. `git config --get-regexp
"^branch\."` returned no entry for its own branch, so the harness creates these
with no upstream and the `--no-track` hazard does not arise on this route.

**This does not soften the first decision, and the distinction is load-bearing.**
Probe 2 failed because it crossed from an isolated tree into the *pre-existing*
piece tree. Probe 3 never crosses. "There is no supported way to place a
dispatched subagent inside a **pre-existing** worktree" remains exactly true; what
is now also true is that an agent can have a working cwd in **its own** worktree.
Both sentences are kept adjacent in `README.md` for that reason — separated, the
second reads as a retraction of the first.

**`worktree.baseRef` decides whether the route is usable at all.** It defaults to
`fresh`, branching from `origin/<default-branch>` — the first probe landed on
`cafa02b` and held none of the piece's commits, which for a reviewer reading a
diff is the wrong tree outright. `{"worktree": {"baseRef": "head"}}` fixes the
fork point to the runner's HEAD, verified against a deliberately distinct base:
runner HEAD `a949ec6`, `origin/main` `cafa02b`, agent reported `a949ec6`. The
agent also had unrefused Bash and read `RUNNER.md` by relative path.

**Considered and rejected: keeping `git -C` as primary.** It works — three
`dev-writer`s and twelve reviewers completed real work on it. But it makes every
agent responsible for a prefix on every command, and the two tools that resolve
their root from the cwd (`openspec`, `lgs basecamp build`) stay broken under it,
one of them *silently*. Placing the agent correctly fixes the whole class at
once: a tool that takes its root from the cwd is right whenever the cwd is. That
is the data-shape fix over the per-call-site guard, in CLAUDE.md's terms.

**The setting is the user's, and this change documents it without writing it.**
`.gitignore` excludes `.claude/*` (`git check-ignore -v` names line 37), so the
file the flow now depends on reaches no clone and no fresh checkout. **Nothing
fails when it is missing** — agents are cut from `origin/main` and work
confidently on the wrong code. That silent-failure note is written beside every
mention of the key, because an absent setting with no error is exactly the shape
this piece exists to correct.

**Two consequences fall out, and both are recorded where they bite.** Agents land
on harness-named branches, so work returns by cherry-pick and each agent must
report the name it actually got. And **an agent can no longer remove its own
worktree** — it is standing in it. That last one is a happy accident: it makes
the "do not delete a tree the runner still needs" rule hold by construction,
where previously it depended on every reviewer remembering it, and one did not.

**What breaks if this section is deleted:** the next reader finds a flat
`EnterWorktree` prohibition, measures the isolation route working, and cannot
tell which half of the document to trust. The distinction that resolves it —
*pre-existing* tree versus the agent's *own* — is one sentence, and without it
the correction reads as a contradiction.

### One runner per piece, each sitting in its piece's worktree

`baseRef: "head"` makes **the runner's HEAD the fork point for every agent it
dispatches**. That turns the runner's working tree from incidental into
load-bearing, and the shape of the flow has to answer for it. Three options:

| Shape | What it costs |
|---|---|
| runner stays in the main checkout (the old rule) | every agent forks from `main` and holds none of the piece's commits — the route is useless |
| one runner checking out each piece before dispatching | works, but the checkouts must be serialised, and **dispatching while HEAD is on the wrong branch silently forks the agent from the wrong piece** |
| **one runner per piece, in that piece's worktree** | a second session per piece |

**The second option was rejected for the shape of its failure, not its
difficulty.** Getting the checkout order wrong produces no error: the agent
starts, reads a coherent tree, and does careful work against the wrong piece.
There is no conflict to catch it, because the trees were never shared. Per-piece
runners have no shared HEAD, so that hazard is **structurally absent rather than
avoidable** — the same reasoning as `--no-track` elsewhere in this change, and
CLAUDE.md's preference for an invariant that holds by construction over a rule
every call site must remember.

This is also the one place `EnterWorktree` is correct: the runner is a **session
moving itself**, which is what the tool is built for. Measured: *"Entered
worktree at …/probe-baseref on branch probe/baseref. The session is now working
in the worktree."* **Keeping that adjacent to the dispatched-agent prohibition is
deliberate** — they are the easiest pair in this document to conflate, and the
distinction is *who calls it*, not whether it works.

**The ordering rule that follows, and is easy to miss:** because each dispatch
forks from the runner's HEAD, a writer's work must be cherry-picked onto the
piece branch *before* the next writer is dispatched. Otherwise the second forks
from a HEAD without the first's commits and silently diverges. Reviewers are
exempt precisely because they only read.

### Write each process trap where it bites, not in a single "traps" section

Three unrelated failures were measured this session, and the temptation was one
list. They went to three different places instead, because the agent that needs
each one is different and none of them reads the others' file:

- **`run-qml-tests.sh` truncates** → `CLAUDE.md`'s test-layer section (everyone)
  and `spec-test-reviewer.md` (the agent that misjudged a mutation because of it).
  The fix recorded is a **narrower command** — `qmltestrunner -input <one file>`
  — explicitly not `| tail`, which would cost an approval click on every call and
  defeat its own purpose. Worth stating because the pipe is the obvious reach.
- **`lgs basecamp build` acts on the cwd's project root** → `dev-writer.md`, the
  only agent that builds. It is the same class as `openspec`'s missing `-C`, so
  `README.md` gained a two-row table naming the class rather than leaving two
  isolated warnings that look like separate quirks. **The shared property is what
  makes it dangerous: a wrong-tree success is indistinguishable in the output
  from a right-tree one.** A tool that refused would be harmless.
- **A reviewer removed its own tree against instruction** → `RUNNER.md` and all
  three reviewer files. This one was **overtaken by the dispatch change while
  being written**, and the outcome is better than what was planned.

**The instruction was going to be a fourth precondition; it became an
impossibility.** Under `isolation: "worktree"` an agent stands inside its tree,
so `git worktree remove` refuses it — the agent *cannot* delete the thing the
runner may still need. The rule now holds by construction rather than by every
reviewer remembering it, which is the better shape and is why the files say
"you cannot" rather than "you must not".

**The reasoning is kept anyway, attached to the runner.** It explains why removal
has an owner at all: a tree may still need reading — to re-check a finding
against the state that produced it, to compare two reviewers' citations, to
recover a mutation — and `--force` destroys the evidence behind the findings. For
`spec-test-reviewer` that evidence *is* the uncommitted mutated state, which is
why its file says so explicitly. Nothing was lost the one time an agent deleted a
tree it had been told to keep, but only because the findings commit had already
been cherry-picked; safety should not depend on that.

### Turn the fabricated-number caution into a step

`README.md` already said this repo fabricates numbers. That is a warning, and a
warning names a hazard without naming an action. One review round then found five
fabricated quantities and one phantom test name across two independently written
pieces — none of it carelessness, all of it numbers that felt remembered.

So the text now prescribes the command (`grep -c "function test_"`, `grep -c
"#\[test\]"`, `git log -S`) as a step taken **before** the number is written,
which is CLAUDE.md's "do not write down anything a command can answer" applied to
what an agent writes most: a count in a report or a doc comment.

**The second half was learned while writing this entry**, which is why it is
here rather than inferred. Re-measuring the phantom test name a reviewer had
reported in `nodeconfig.rs` found the branch had already corrected it —
`an_external_address_with_a_node_id_is_refused_although_the_crate_accepts_it`
exists and the doc comment now names it. Copying the reviewer's figure would have
introduced a fresh wrong claim in the act of documenting the rule against wrong
claims. Hence: **measure against the tree in front of you; never apply a
reviewer's quoted delta**, because that figure aged from the moment it was taken.

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

**This applies with more force to the second commit, not less.** Two of its three
process traps describe gates that are themselves unreliable — a QML suite whose
output truncates before it ends, and a build that succeeds against the wrong
tree. Neither could be caught by running the gate, because in both cases the gate
passes. They were caught by an agent noticing its result did not match what it
expected, which is not a mechanism this repo can schedule.

The `closer.md` line the survey found makes the same point about the corrections
themselves: a `grep -rn "EnterWorktree"` sweep is the closest thing this change
has to an automated check, and it is blind to any paraphrase of the instruction
it looks for. **Scoping a documentation fix by keyword finds the copies and
misses the residue**; both passes of this piece hit that, and the second only
found it because a survey read the files rather than matching them.

## A constraint this change turned out to fix

`openspec` resolves its root from the cwd and has no `-C` flag; `lgs basecamp
build` resolves `scaffold.toml`'s relative module refs against the root it was
invoked from. Neither can be pointed at another tree. Under the old dispatch that
was a standing constraint with no clean workaround — the agent's cwd was the main
checkout while its work was in a worktree — and the first version of this design
recorded it as unfixable, with instructions to report an unrun validation rather
than tick the row.

**Placing the agent correctly dissolves both**, and it is worth naming as the
strongest practical argument for the dispatch change: *a tool that takes its root
from the cwd is correct exactly when the cwd is*. No upstream `-C` flag is needed
after all. `closer.md`, `spec-writer.md` and `docs/OPENSPEC-ARCHIVE.md` now say
the command runs plainly, while keeping the "report an unrun gate rather than
tick the row" rule, which was never about `openspec` specifically.

**One asymmetry is kept in the documents even though the cause is fixed**, because
it explains why a wrong cwd was expensive rather than merely inconvenient:
`openspec` from the wrong root reports a change as *missing*, which reads as a
problem worth investigating. `lgs basecamp build` from the wrong root
**succeeds** — and a green build of code the agent did not write is
indistinguishable in the output from a green build of code it did. A tool that
refused would have been harmless. That is why `dev-writer.md` ends its note on
"never report a build you did not run" rather than on the mechanics.
