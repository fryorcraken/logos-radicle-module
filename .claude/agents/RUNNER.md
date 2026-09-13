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
- **You stay in the main checkout.** Agents go to worktrees; you do not.

Yours besides dispatching: `git worktree add`, and the reading below.

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
is not a unit of review**, and `openspec archive` runs once, on the piece branch
before the merge.

- **One branch per piece: `piece/<name>`.** A branch named for a stage is the
  failure happening.
- **The `dev-writer` opens the PR**, at the end of its first pass. If you are
  reaching for `gh pr create`, either it has not run yet or the PR exists.
- **Count before dispatching.** `gh pr list --state open` is one row per piece;
  more rows than pieces means something opened a PR that should not have.

Reviewer branches (`review/<name>/<dimension>`) are **local only** — one on the
remote is the same failure renamed.

**Do not rename or re-point a branch with an open PR.** A PR's head ref is
immutable, and every workaround loses something; open a new PR on the correctly
named branch and close the old one, saying where the work went. The README's
branch section has the specifics.

## Dispatching

**A brief points at the work; it does not contain it.** Name the piece, the
worktree and the file to read. Never paraphrase a finding: a number you carry
into a brief was measured earlier and the agent cannot tell how stale it is.

Every brief carries the worktree instruction, which is what keeps an agent out
of the shapes that cost a permission click:

> Act on the findings for `dev-writer` in
> `openspec/changes/<name>/findings/`. Piece branch `piece/<name>`, worktree
> `.claude/worktrees/piece-<name>` — enter it with
> `EnterWorktree(path: "…/.claude/worktrees/piece-<name>")` before anything
> else, then use plain relative paths.

**Pass `path`, never `name`** — `name` branches from `origin/main` and strands
the agent in an empty tree. You cannot enter a worktree on an agent's behalf,
which is why this belongs in the brief.

**`EnterWorktree` can refuse, and the brief has to say what to do then.** A
session whose working directory is the repository root — which is where a
dispatched agent starts — has been refused with *"switching is only available to
sessions whose working directory is inside a worktree"*. The message reads like a
permissions problem and names no fallback, so an agent that takes "before
anything else" literally does nothing at all. **Tell the agent that if the call
is refused, it works read-and-write through absolute paths and `git -C <worktree>
…` instead, and says so in its report.** That is a documented fallback rather
than the `cd` chain the instruction exists to avoid: `git -C` is one plain
command and costs no approval click.

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
| `spec-writer` / `dev-writer` / `tester` | **one in total**, not one each — they share the piece's worktree |
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

## Prune worktrees at merge time

`git worktree remove <path>` as soon as a branch is merged or abandoned. Every
stale checkout is a full copy of the repo, so a recursive grep hits each one —
and a citation from a stale copy reads exactly like one from the real tree. This
repo has reached **fifteen** at once, most on branches merged milestones ago.

`git worktree list` read against the open-PR count is the check: a tree with no
open PR and no running agent is prunable. The gap grows quietly, since nothing
fails — the greps just get less trustworthy. `git worktree prune` clears entries
whose directories are already gone.

**Check merged-ness with `gh pr list`, not `git branch --merged`** — this repo
squash-merges, so a squashed branch never looks merged to git.

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
change. Dispatch into the piece's existing worktree:

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
