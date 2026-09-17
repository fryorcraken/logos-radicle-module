# The runner's own file

Every other file in this directory is read by the agent it names. This one is
read by the session that dispatches them — the **runner**. Read it before your
first dispatch; [`README.md`](README.md) is the flow itself.

## What a runner does

**Dispatch, track state, report.** That is the whole list.

- **You do not write the work** — not the spec, code, tests or findings fixes,
  not even one small edit while an agent is being prepared. It would land in no
  worktree, tick no row, and be reviewed by nobody.
- **You do not rebase.** It destroys work and it can conflict, which needs
  someone who has read the change. The `closer` does it.
- **You sit in your piece's worktree, and you run one piece.** This replaces the
  old "you stay in the main checkout" rule — see below, because the reason is the
  whole design.

Yours besides dispatching: `git worktree add --no-track` (the flag is
load-bearing — see "Create worktrees with `--no-track`"), removing each agent's
worktree once its work is cherry-picked, and the reading below.

## One runner per piece, sitting in that piece's worktree

**Your HEAD is the fork point for every agent you dispatch.** With
`worktree.baseRef: "head"` (see README.md — it is required, and it is not in the
repository), an agent dispatched with `isolation: "worktree"` gets a tree cut
from wherever your session's HEAD is. Measured: runner HEAD `a949ec6`,
`origin/main` `cafa02b`, agent reported `a949ec6`.

So **enter your piece's worktree once, with `EnterWorktree(path: <absolute
path>)`, and stay there.** That works for you — a session moving *itself* is the
case the tool is built for, verbatim *"Entered worktree at …/probe-baseref on
branch probe/baseref. The session is now working in the worktree."* It is
dispatched agents that cannot do it, for reasons README.md keeps.

**Why one runner per piece, and not one runner switching branches.** Two
alternatives were on the table:

| Shape | Why not |
|---|---|
| one runner, checking out each piece before dispatching | the checkouts must be serialised, and **dispatching while HEAD is on the wrong branch silently forks the agent from the wrong piece** — no error, no warning, just an agent confidently working on the wrong code |
| one runner in the main checkout, as before | every agent forks from `main` and holds none of the piece's commits |

**One runner per piece has no shared HEAD, so the first hazard is structurally
absent rather than merely avoidable.** That is the reason for the shape: not that
switching is hard to get right, but that getting it wrong produces no signal. A
runner that can only see one piece cannot fork an agent from another.

The practical consequence: **do not run two pieces from one session.** Start a
second session in the second piece's worktree instead.

### What you read, and what you only point at

You read exactly enough to decide the next dispatch:

| Read | For |
|---|---|
| `openspec/changes/<name>/tasks.md` — the `## Stages` block | which stage is next, and whether anyone is on it |
| `ls openspec/changes/<name>/findings/` — **the filenames** | whether a reviewer has reported, and which dimension |
| `grep -rn "^- \[ \]"` over `findings/` | whether anything is unanswered, as a count |
| the `closer`'s report | whether the piece closed, or what stopped it |

**You do not read the findings themselves, and never quote one into a brief.**
Name the file and let the agent read it. A finding carries the measurement that
backs it; a paraphrase arrives without that, and the content occupies your
context twice — once from the report, once rewritten into the next brief. That
crowding is what loses the state you are supposed to be tracking.

The same holds for `design.md`, `proposal.md`, PLAN.md, the spec and the code:
point at them. If you are reading a diff to judge whether it is right, that is a
reviewer's dispatch, not your reading.

## Rebuild the state before you act on it

Your memory of what you dispatched does not survive a compaction and was never
the source of truth. Run these at the start of a session and after any gap —
none costs a permission prompt:

```
gh pr list --state open                 # in flight: one row per piece
git worktree list                       # which trees exist, on what branch
openspec list                           # which changes are unarchived
grep -rn "^- \[ \]" openspec/changes/<name>/tasks.md    # what is left
```

`tasks.md`'s `## Stages` block is the state. **An unticked row with no agent
running is a stage nobody is doing** — that is the whole tracking mechanism.
A struck-through row keeps its empty box, so read the strike, not the box.

**A change with no stage block is invisible to it.** The grep returns nothing,
which reads exactly like every row ticked. Confirm the block exists before
trusting an empty result:

```
grep -c "^## Stages" openspec/changes/<name>/tasks.md
```

`0` means untracked, not done. Changes predating the rule answer `0`; a new one
should not, since the `spec-writer` writes the block first.

## Is an agent still working?

**`ListAgents`.** A piece not in that list has no agent, whatever you remember.

`ListAgents` and `ScheduleWakeup` are available to an **interactive main-loop
session** — which the runner is — and not to a subagent. So a reviewer sent to
check this file cannot see them and will report them as missing; that is a fact
about who dispatched it, not an error here. `Monitor` is the fallback if you ever
find they are genuinely absent.

- **One is running → `SendMessage` it.** Never start a second with `Agent`: two
  writers share a worktree, an index and a branch, and that surfaces not as a
  git conflict but as a spec that moved while code was written against it. A
  continued agent also still holds its measurements, where a new one gets your
  summary of them.
- **None running, row unticked → dispatch.**
- **Either way, set a 5–10 minute `ScheduleWakeup` or `Monitor`.** A dispatched
  agent is silent until it finishes, so a stalled one looks like a working one.

## One piece is one PR

The shape that breaks this: each stage looks like a finished unit of work, so
spec, dev and tests each get a branch and a PR — leaving the contract, the code
and the tests that prove they match in three places, none reviewable. **A stage
is not a unit of review**, and `openspec archive` runs once, as a commit on the
piece branch that rides the same PR.

- **One branch per piece: `piece/<name>`.** A branch named for a stage is the
  failure happening.
- **The `dev-writer` opens the PR**, as the last act of its first pass, having
  pushed its own commits straight to the remote `piece/<name>` ref. It does not
  wait for your cherry-pick — [`dev-writer.md`](dev-writer.md) states the
  sequence and owns it. **If you are reaching for `gh pr create`, either the
  `dev-writer` has not run yet or the PR already exists**; check with `gh pr list
  --head piece/<name>` rather than creating a second one.
- **Your cherry-pick is still yours, and it is not what puts the work on the
  remote.** The `dev-writer` has already pushed the commits; you cherry-pick so
  that *your local HEAD* carries them, because that HEAD is the fork point for
  every agent you dispatch next. Skip it and the next writer forks from a tree
  missing the previous one's work — pushed or not.
- **Count before dispatching.** `gh pr list --state open` is one row per piece;
  more rows than pieces means something opened a PR that should not have.

**No `worktree-agent-<id>` ever appears on the remote** — a harness-named branch
there is the same failure as a reviewer branch reaching it, renamed. That is a
rule about the *ref name*, not about who may push: the `dev-writer` and `closer`
both push their tip **to `refs/heads/piece/<name>`**, which creates no agent
branch on the remote. Agent branches are named by the harness rather than by you,
so you learn each one from the agent's report and cherry-pick from it.

**Do not rename or re-point a branch with an open PR.** A PR's head ref is
immutable, and every workaround loses something; open a new PR on the correctly
named branch and close the old one, saying where the work went. The README's
branch section has the specifics.

## Dispatching

**A brief points at the work; it does not contain it.** Name the piece, the
worktree and the file to read. Never paraphrase a finding: a number you carry
into a brief was measured earlier and the agent cannot tell how stale it is.

**Dispatch with `isolation: "worktree"`.** The agent then arrives in its own
tree, forked from your HEAD, with a working directory it does not have to correct
— so the brief carries no worktree instructions at all:

> Act on the findings for `dev-writer` in
> `openspec/changes/<name>/findings/`. Piece branch `piece/<name>`. Commit to
> your own branch and report its name, so the work can be cherry-picked.

**Take the `git -C` instruction and the `EnterWorktree` prohibition out of your
briefs.** An agent that is already in the right place needs neither, and a brief
carrying them sends it hunting for a problem it does not have. The explanation
stays in README.md, where a reader who meets the refusal can find it.

**What you must still ask for is the branch name.** The agent lands on a
harness-named `worktree-agent-<id>`, not on `piece/<name>`, so its commits need
cherry-picking onto the piece — and the name is assigned by the harness rather
than chosen by you. Have the agent report it rather than guessing it.

**Cherry-pick before you dispatch the next agent, and make sure your HEAD carries
it.** This is the ordering rule that replaces "one writer at a time because they
share a tree": every dispatch forks from *your HEAD*, so an agent launched before
the previous one's work has landed on your branch gets a tree without it. It will
then rewrite, duplicate or contradict work it cannot see, and nothing fails —
there is no conflict, because the two agents were never in the same tree. The
sequence per agent is: hand-back → cherry-pick onto `piece/<name>` → remove the
agent's tree → dispatch the next.

Reviewers are the exception that proves it: six run concurrently precisely
because they only *read* the code, so forking them all from the same HEAD is
correct. It is writers that must be serialised.

**A dispatched agent cannot be put inside a pre-existing worktree.** Not "usually
fails" — two probes measured both routes and both fail, the second one *silently*
until the agent's first Bash call. **The transcripts live in
[`README.md`](README.md)**, under "Why the prohibition is still written down" and
the `Works?` table beside it; they are quoted verbatim there and in one place
only, because two copies of a measurement drift and the wrong one gets read.

What you need from them here is the operational consequence, which is short:

- **Dispatch with `isolation: "worktree"` and let the agent be**, which is what
  the section above already tells you. That route works completely and is what
  this flow runs on.
- **Do not reach for `EnterWorktree` on an agent's behalf, and do not put it in a
  brief.** The tool moves only the session that calls it, so you could not do it
  for an agent even if it were correct.
- **Do not read the first probe's refusal as a hint.** Its message names the
  precondition `isolation: "worktree"` establishes, which invites exactly the
  combination probe 2 measured failing — isolation *plus* an `EnterWorktree` call
  across into the piece tree. Isolation alone never crosses, so nothing breaks.

The cost of getting this wrong was measured: four agents in one session hit the
refusal, and two burned significant time inventing workarounds (`env -C`, `cd
&&`) that each cost the user an approval click, because the brief told them the
shape was supposed to work.

`EnterWorktree` is still the right tool for a **session moving itself** — which
is what you are, when you enter your piece's worktree. It is dispatched agents
that cannot use it.

### The setting this depends on, and how it fails

`worktree.baseRef: "head"` lives in `.claude/settings.json`, which **`.gitignore`
excludes** (`git check-ignore -v` names `.claude/*`). It therefore does not
travel with a clone or a fresh checkout.

**Nothing fails when it is missing.** Agents are simply cut from
`origin/<default-branch>` instead of your HEAD, hold none of the piece's commits,
and work confidently on the wrong code. No error, no warning. If an agent reports
a fork point that is not your HEAD, or reports files that should exist as
missing, check that file before investigating anything else.

It is the user's file. **Do not edit it**; if it is absent, say so rather than
creating it.

Two things this setting does *not* change, so you do not go looking for them: the
agent's branch is created with no upstream, so the `--no-track` hazard below does
not arise on it; and the setting is global, applying to every
`isolation: "worktree"` dispatch with no per-dispatch override.

**Do not phrase an instruction in a way that invites a chain.** "`cargo test`
from `radicle/rust-ffi/`" reads as `cd radicle/rust-ffi && cargo test`, which
costs an approval click even though `cargo test` is allow-listed. Name the
directory as its own step, or give a `--manifest-path`.

**Address this repo's agents unqualified** — `code-reviewer`, not
`agent-skills:code-reviewer`. The plugin ships a similarly-described reviewer
carrying none of this repo's traps.

### How many at once

| Stage | How many |
|---|---|
| `spec-writer` / `dev-writer` / `tester` | **one in total**, not one each — cherry-pick and commit before dispatching the next, or it forks from a HEAD without the previous one's work |
| reviewers | **six, in parallel** — a tree and a findings file each |
| `closer` | one, never beside a writer |

A full review is six agents of three types, one per stage-block row:

| Dispatch | Reads | Writes |
|---|---|---|
| `code-reviewer` × 4 — correctness, security, readability, architecture, named in the prompt | the code | `findings/<dimension>.md` |
| `spec-test-reviewer` | **spec and tests only — never the implementation** | `findings/spec-test.md` |
| `design-reviewer` | code, `design.md`, PLAN.md | `findings/design-review.md` |

The last two are not smaller `code-reviewer`s:

- **`spec-test-reviewer` is blind to the implementation on purpose** — someone
  who has read the code judges tests by what the code does, which is the defect
  a spec exists to catch. Do not hand it the code to "give it context".
- **`design-reviewer`** asks whether the recorded decisions were the ones taken.
  A gap it finds is a missing `design.md` entry, not a code defect.

**Name the dimension** when launching a `code-reviewer`: one agent asked to hold
two becomes whichever it started with. A small change can take one covering all
four — but the other two are still separate dispatches, because what
distinguishes them is what they may read.

**A change with no source diff still gets all six.** Agent files, prose and
config are reviewable material; treating "no code" as an exemption is how this
flow's own adopting change nearly shipped with `code-reviewer` skipped.

**Two concurrent authors across pieces is the ceiling.** Fanning agents across
sequential work moves dependency discovery to collision time.

## Create worktrees with `--no-track`

```
git worktree add --no-track -b piece/<name> .claude/worktrees/piece-<name> origin/main
```

**The flag is what stops the piece branch being configured to push to `main`.**
Without it, `git worktree add <path> -b piece/<name> origin/main` branches from a
remote-tracking ref, and git's `branch.autoSetupMerge` default then writes
`remote = origin` and `merge = refs/heads/main` into the new branch's config. The
branch is set up to push to `main` from the moment it exists.

This is the cause of the bare-`git push`-lands-on-`main` warning that this file
and `CLAUDE.md` both carry. Measured: `git config --get-regexp "^branch\.piece"`
returned `merge refs/heads/main` for both piece branches created without the
flag, and piece A's `git push origin piece/embedded-node-wizard` was **rejected
by branch protection for `refs/heads/main`** — it only went through with a
fully-qualified refspec. The agent reported the plain push form as "not safe in
these worktrees", which is the wrong lesson to draw: the push was fine and the
branch creation was at fault.

**Check it with `git config`, not `git branch -vv`.** `branch -vv` prints
`[origin/main]` and there is nothing in that output to tell an intended upstream
from a wrong one, so the check both documents used to prescribe cannot catch
this. The positive signal is:

```
git config --get-regexp "^branch\.<name>"
```

**returning nothing.** Verified: with `--no-track` the creation output omits the
"set up to track" line and that command returns nothing at all.

A branch created this way has no upstream, so a push names the refspec in full:
`git push origin refs/heads/piece/<name>:refs/heads/piece/<name>`.

## Prune worktrees at merge time

`git worktree remove <path>` as soon as a branch is merged or abandoned. Every
stale checkout is a full copy of the repo, so a recursive grep hits each one —
and a citation from a stale copy reads exactly like one from the real tree.

This repo has reached **fifteen** at once, most on branches merged milestones ago.

`git worktree list` read against the open-PR count is the check: a tree with no
open PR and no running agent is prunable. The gap grows quietly, since nothing
fails — the greps just get less trustworthy. `git worktree prune` clears entries
whose directories are already gone.

**Check merged-ness with `gh pr list`, not `git branch --merged`** — this repo
squash-merges, so a squashed branch never looks merged to git.

**Removing each agent's worktree is now yours, and it is not optional
housekeeping — it is the last step of collecting the work.** An agent cannot
remove its own tree any more: it is standing in it, and `git worktree remove`
refuses the directory you are in. So the sequence after an agent hands back is
cherry-pick its commits off its branch, then remove its tree.

This also settles a failure that previously had no clean fix. A reviewer was once
told not to remove its tree and removed it anyway; nothing was lost only because
its findings commit was already cherry-picked. **You keep a tree when something
may still need reading** — re-checking a finding against the exact tree that
produced it, comparing two reviewers' citations, recovering a mutation — and
`--force` destroys all of it. That used to depend on every agent remembering an
instruction. It now holds because the agent has no way to do it.

Agent trees accumulate faster than piece trees, one per dispatch rather than one
per piece, so `git worktree list` is worth running at the end of each review
round rather than at merge time.

## The `closer`, and what comes back

Dispatch it when every review row is ticked; it rebases if behind, archives,
watches CI and merges. Watching a run is the cheapest work in the flow and
yours is the most expensive context to spend on it — and here `main` requires
thirteen checks, six of them sitometres e2e specs, slower still on a cold Nix
cache.

It decides nothing and dispatches nobody. Two things come back:

**A red run.** This is the most tempting moment to break the first rule in this
file — the failing lines are in the report and the fix looks like one line. The
`closer` refused it for the reason you should: it neither read nor wrote the
change. Dispatch a fixer the ordinary way — `isolation: "worktree"`, its own tree
forked from your HEAD, its commits cherry-picked back. There is no special
dispatch shape for a fixer, and **nothing goes into the piece's own worktree but
you**: putting a dispatched agent there is the failure the whole "Dispatching"
section above measures. Who to send:

| What failed | Who |
|---|---|
| implementation, build, clippy, fmt | `dev-writer` |
| a test — wrong assertion, missing case, a test that cannot fail | `tester` |
| the contract, not the code | `spec-writer`, then the fixer — never both at once |

One writer at a time still holds: the piece is idle, not free. Give the writer
the run URL, not your reading of it. Then **re-dispatch the `closer`** — a piece
merges because the `closer` saw it green, not because the fix looked right.

**An unticked box**, meaning a finding was never answered: it routes to whoever
the finding names.

A stale branch does *not* come back — the `closer` rebases it itself.
