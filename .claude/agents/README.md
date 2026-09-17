# The spec-driven flow

Role agents around [OpenSpec](https://openspec.dev)'s built-in `spec-driven`
schema: OpenSpec supplies the artifacts and their ordering, Claude Code the
agents. No custom tooling — subagents already give isolated context windows,
per-role models and tool limits.

> **If you are the session dispatching these agents, read
> [`RUNNER.md`](RUNNER.md) first — it is written for you, and this file is not.**
>
> Everything below is addressed to the agent it names.

## The documents, and what each is for

| Document | Question | Where it ends up |
|---|---|---|
| `docs/PLAN.md` | A short summary of what exists, and **what is not built yet** | Lives at `docs/`, edited forever |
| `proposal.md` | Why this change, which capabilities it touches | `changes/archive/<date>-<name>/` |
| `openspec/specs/` | **What** the system does — the behaviour contract | `openspec/specs/`, current |
| `design.md` | **How**, and **why this approach** (Decisions) | `changes/archive/<date>-<name>/` |
| `tasks.md` | The ordered checklist | `changes/archive/<date>-<name>/` |
| `findings/<dimension>.md` | What each reviewer found, and what was done about it | **Deleted before merge** — durable reasoning moves to `design.md` first |

A change in flight lives in `openspec/changes/<name>/`, and its `specs/` holds a
**delta**. `openspec archive` merges the delta into `openspec/specs/` and moves
the folder to `changes/archive/<date>-<name>/` — moved, not deleted, so finding a
past decision means grepping the archive.

**Archiving has enough traps to be worth its own page:
[`docs/OPENSPEC-ARCHIVE.md`](../../docs/OPENSPEC-ARCHIVE.md). Read it before you
archive, not before you start.** Archiving is the `closer`'s, and it runs as a
commit on the piece branch before CI and the merge — [`closer.md`](closer.md)
says why that ordering. `openspec` is installed; run
`openspec --version` rather than believing any document about it, this one
included.

### A spec must never cite a PLAN section number

`openspec/specs/` is read on its own. A requirement citing "§5.7" points at a
`docs/PLAN.md` heading that the reader does not have open, that carries no
stable number, and that PLAN.md sheds as changes land. Cite by requirement
name, or restate the substance in one clause.

`grep -rn "§" openspec/specs` currently returns nothing here, so this is a rule
kept rather than a mess being cleaned — which is the cheap moment to state it.
The sibling dialectica repo has a live instance it chose to leave alone, on the
grounds that an archive sweep which also edits prose is a sweep nobody can
review; that is the right call and the reason to not acquire one.

### PLAN.md sheds in two directions

As a change lands, the part of PLAN.md it implements moves out:

- **Behaviour → the spec.** Struck through in PLAN.md, with a one-line summary
  that the thing exists.
- **Reasoning → `design.md`** under Decisions, and removed from PLAN.md. Someone
  investigating a past decision reads the archive; that is what it is for.

PLAN.md is left with what is **not built yet**, plus one line per built area
saying it exists — never why it works that way. Keeping a second copy of the
reasoning is the failure mode: two copies drift and the wrong one gets read.

Reasoning never goes in a spec at all — a spec is a behaviour contract, and
prose rationale in one is prose nobody will maintain.

**This applies to changes as they land, not as a migration.** PLAN.md holds
plenty that has no change to attach to yet — the git-spawn-site constraint, the
open passphrase-at-start question. Leave it. It shrinks by attrition as changes
touch each area.

`docs/M3-embedded-node-plan.md` is M3's own working document and **is** edited as
phases merge — each step adds its findings there. `docs/M3-phase0-findings.md`
beside it records one spike and is finished. Both cite the crate source line by
line, which is what makes a claim in PLAN.md re-verifiable rather than
re-derivable. PLAN.md is the cross-milestone view; the two overlap on M3, and the
more recently edited one wins.

An earlier version of this paragraph called both files frozen. A milestone step
edited one of them two days later, which is the lesson: **do not write down that
a document has stopped changing.** It is a claim about the future, and the
cheapest kind to get wrong.

## The roles

| Agent | Reads | Writes |
|---|---|---|
| `spec-writer` | PLAN.md (from `origin/main`) | `proposal.md`, `specs/` |
| `dev-writer` | spec, PLAN.md | `design.md`, `tasks.md`, code, tests-as-it-goes, **the PR** |
| `tester` | spec, inherited tests | the test suite |
| `spec-test-reviewer` | **spec + tests only** | findings |
| `design-reviewer` | code, `design.md`, PLAN.md | findings |
| `code-reviewer` | code | findings |
| `closer` | `tasks.md`, `findings/`, CI, the PR | deletes `findings/`, the archive commit |

## One piece of work is one branch and one PR

Every stage — spec, design, code, tests, review fixes — lands as **commits on one
remote branch, under one PR**.

Local branches are fine and a reviewer needs one. What never happens is a *stage*
reaching the remote on its own: only `piece/<name>` is ever pushed, so
`origin/<anything-else>` is a mistake, and a second PR on one piece is the failure
this section exists to stop.

**The unit of review is a behaviour change with its contract and its tests
attached.** A reviewer must be able to see they belong together, not be told so
by whoever is orchestrating. And `openspec archive` runs once, on merge — split
across several merges, the contract lands at a different time from the code that
honours it.

### One writer at a time; reviewers in parallel

**A piece has at most one `spec-writer`, `dev-writer` or `tester` running** — not
one of each, **one in total**. Each now gets its own worktree, so this is no
longer about sharing a tree; it is about what the *next* agent forks from. Every
dispatch is cut from the runner's HEAD, so a second writer launched before the
first's commits are cherry-picked forks from a HEAD that does not contain them,
and the two diverge silently. Two further reasons, neither of which surfaces as a
git conflict either:

- **A spec must not move while code is written against it.** Run the pair together
  and the implementation answers a contract that changed underneath it, with
  neither agent knowing. This session did it — a scope reworded while four
  reviewers read the code implementing it. It holds on the way back too: when
  review routes a spec gap, stop the fixer, land the spec, restart the fixer
  against the new text.
- **`tester` mutates implementation code it does not own**, restoring after each
  mutation. A concurrent writer inherits the broken state or overwrites the
  restore, and neither is touching git when it happens.

**Reviewers run in parallel, up to six**, each writing only its own findings file.
They get a worktree each because a reviewer breaks code on purpose to see whether
a test notices — two sharing a tree read each other's breakage as the author's —
and each **deletes its worktree** when done rather than restoring, since deleting
cannot half-succeed where a restore depends on having tracked every edit.

**The runner creates each reviewer's worktree and names it in the dispatch**, and
the reviewer deletes it. Stating the owner matters because the failure on ambiguity
is silent and destructive in both directions: a reviewer that assumes it must make
its own may instead mutate the tree it was launched in, which is the piece's; and
one that assumes it was given one may `--force`-remove a tree holding the only copy
of somebody's work. **A reviewer that was not given a worktree path stops and says
so** rather than choosing either fallback.

Every branch rule below follows from that asymmetry.

### Branch names say which kind of branch it is

| Branch | Worktree | Whose | Holds |
|---|---|---|---|
| `piece/<name>` | the runner's | the runner, and the PR | **the** task branch, and the only one ever pushed. Work reaches it two ways: the runner cherry-picks every agent's commits onto its local copy, and the `dev-writer` and `closer` push a refspec to the remote copy |
| `worktree-agent-<id>` | one per dispatch | one agent | **local only, and named by the harness** — whatever that agent committed, cherry-picked onto the piece and never pushed |
| `main` | — | nobody | **no agent ever pushes here.** It takes commits through a PR only |

**Every dispatched agent gets its own worktree and its own branch**, cut from the
runner's HEAD. That is a change from the era when the three writers shared the
piece's tree and committed to `piece/<name>` directly: they no longer stand in it,
so their commits are cherry-picked like a reviewer's always were.

**The branch name is the harness's, not the runner's**, which is the practical
difference to absorb. There is no `review/<name>/<dimension>` to predict, so an
agent reports the name it actually landed on (`git rev-parse --abbrev-ref HEAD`)
and the runner picks from that. A name nobody recorded is work nobody can find.

Named for the role and not the stage, because `dev/x` invites a `test/x` beside
it — which is the shape this section exists to stop.

**The PR is opened on `piece/<name>` and nothing else. Whichever ref it is opened
on, it is stuck with — and every workaround loses something.** A PR's head ref is
immutable:
`PATCH /pulls/<n> -f head=…` returns **200 and silently ignores the field**, and
`--base` changes the target, not the source. The rename endpoint
(`POST /branches/<old>/rename`) does follow open PRs — but it **auto-closes** one
whose *head* vanished, and if the target name already exists you must delete that
ref first, at which point the rename recreates it **at the old branch's tip and
silently drops anything the deleted ref held**. Six reviewers' findings went that
way here and were recovered only because the commit was still in a local reflog.

**Consolidating branches is not finished until the orphaned PRs are closed.**
Folding a branch into the piece leaves its PR open, describing work that now
lives somewhere else — so the PR list stops being a count of work in progress,
which is the only thing that makes a work-in-progress limit checkable. Before
closing one, prove it is redundant:

```
git log --oneline origin/<orphan> --not origin/piece/<name>
```

Empty means contained. **Non-empty means fold it first** — a commit cherry-picked
rather than merged shows here even though its content is in, so read the commits
rather than the count. Say in the closing comment where the work went, and keep
the branch.

**`piece/<name>` is pushed by two agents only, and never by cherry-pick.** The
`dev-writer` pushes it at the end of its first pass and opens the PR there; the
`closer` pushes it again after the archive commit. Both push a **refspec to the
remote piece ref** rather than checking the branch out — it is checked out in the
runner's worktree, and git refuses a branch checked out elsewhere. **When and how
the `dev-writer` does it is [`dev-writer.md`](dev-writer.md)'s**, stated once
there; this line points rather than restates, because two copies drift.

The `closer` also pushes, after committing the **archive** to the piece branch,
before the CI check and the merge.

**Nobody pushes `main`.** It takes commits through a PR only — `enforce_admins`
is on, and a direct push is rejected with `GH006`. This page and `closer.md` both
used to say the archive was an exception, until a closer tried it.

**Every agent now gets its own branch**, reviewers included. That used to be a
reviewer-only arrangement, on the reasoning that only reviewers run genuinely in
parallel — six at once, while a fixer may still be changing the code they are
reading — and that a writer standing in the piece's tree should just commit to it.
Writers no longer stand in that tree, so the distinction is gone: the harness
names a branch per dispatch and every agent lands on one.

Cherry-pick rather than merge, so the task branch reads as a flat sequence rather
than six merge commits carrying six branches.

**Never `git add -A`** — commit named paths. Two reasons, and they are not the same
rule:

- **Sweeping up another agent's half-finished edit corrupts the branch you were
  working on.** This is the one that matters, because it is silent: the commit looks
  like yours, and the agent whose work you took has no way to see that it left.
- **A worktree collects build output that is not yours to commit** — `.scaffold/`,
  `target/`, `result-*` out-links, `./tmp/` scratch, and whatever is added to that
  list next. Noise, which a reviewer spots.

The second reason is the one an agent remembers, being concrete; the first is the one
that does damage, so it is stated first. **This is the canonical copy of the artefact
list**; each agent file states the rule and points here rather than repeating the
list, which is the part that changes.

**Check `git config --get-regexp "^branch\.<name>"` before any git write, and
expect it to return nothing.** A bare `git push` has landed commits directly on
`main` here more than once, and the cause is the creation command: `git worktree
add <path> -b piece/<name> origin/main` branches from a remote-tracking ref, so
`branch.autoSetupMerge` writes `merge = refs/heads/main` into the new branch's
config — measured, for both piece branches made that way. `git worktree add
--no-track` is the fix and `RUNNER.md` carries it; a branch made with the flag
returns nothing from that `git config` call.

**`git branch -vv` does not catch this**, which is why it is no longer the
prescribed check: it prints `[origin/main]`, and nothing in that output
distinguishes an intended upstream from a wrong one.

A `--no-track` branch has no upstream, so push the refspec in full:
`git push origin refs/heads/piece/<name>:refs/heads/piece/<name>`.

CLAUDE.md's "Working in a git worktree" has the rest — in particular that
worktrees branch from `origin/main`, and that the stash stack is shared with
every other worktree, so never bare `git stash pop`.

## Two files carry the state of a change

Each agent's own file says what it writes. These are the shapes everyone needs to
recognise, because everyone reads both.

**`tasks.md` opens with a stage block**, written once by `spec-writer` and
unticked: one row per stage, then three rows the `closer` owns. **The roster
itself lives in [`spec-writer.md`](spec-writer.md)**, which is the agent that
writes it into `tasks.md`; copying it here as well would mean a roster change made
in one file shipping the stale list from the other.

**One row per agent instance, not per role** — `code-reviewer` runs once per
dimension, so it gets one row per dimension, each ticked by the instance that did
it. Do not collapse them onto one line to save space: a shared checkbox is one
nobody can tick truthfully, and all four instances would then edit the same line,
which is the conflict one-row-per-agent exists to prevent.

Each agent flips its own row and adds none, so concurrent cherry-picks never touch
the same line. **An unticked row with no agent running is a stage nobody is
doing** — that is the whole point — **unless it is struck through**, which is how a
stage says it does not apply and why the row is struck rather than deleted: a
deleted row and a skipped stage look identical, and a struck one says which. **A
struck row keeps its empty box, so read the strike, not the box.** One consequence
to expect rather than debug: `openspec archive` counts a struck row as incomplete
and warns before continuing, because the box really is empty. That is the price of
keeping `[x]` single-valued, and it is the right way round — a tool that counts a
skipped stage beats one that cannot tell it from a finished one.

**A piece with no behaviour change still gets a change folder and a stage block.**
A test-only or docs-only piece adds no requirement, so it has no spec delta and its
spec row is struck through with that reason — declared as `skip_specs: true`
**alongside a `schema:` key** in the change's `.openspec.yaml`, because the marker
on its own is reported as "not valid change metadata, so the marker is not
honored". It still needs reviewing, and without the block there is no unticked row
to say so.

**A piece with no behaviour change still gets a change folder and a stage block.**
A test-only piece — an integration target, a regression suite — adds no
requirement, so it has no spec delta and its spec row is struck through with that
reason. It still needs reviewing, and without the block there is no unticked row to
say so: the signal that catches a missing reviewer is absent exactly where it is
easiest to skip one. The first such piece here reached review with no
`openspec/changes/<name>/` at all, so a reviewer had no row to tick and said so.

**`findings/<dimension>.md`**, one file per reviewer — `correctness`, `security`,
`readability`, `architecture`, `spec-test`, `design-review`. **Every finding is a
checkbox**, written unticked by the reviewer:

```markdown
- [ ] **`dev-writer`** — `RepoView.qml:191` — the refetch goes out for the old branch
      **Scenario:** pick branch `b` while on `a` → the pane repopulates with `a`'s
      entries, because `SourceTab.branch` is a binding that has not re-evaluated
      inside the handler that changed its source.
      **Measured:** deleting the whole `onBranchChanged` body leaves the QML suite green.
```

Whoever acts on it flips the box and appends the outcome — **fixed** (with the test
that fails without it), **rejected** (with the argument), or **deferred** (and where
to) — without editing the reviewer's text. The `closer` deletes the directory
before merge, once no box is empty.

So "blocks the merge" is literal and checkable: `grep -rn "^- \[ \]"` over the
directory either returns lines or it does not.

Three consequences worth knowing whatever your role:

- **An unticked entry blocks the merge.** A file, not a convention, so a forgotten
  finding stops a PR instead of evaporating.
- **The gate only sees checkboxes.** `grep -rn "^- \[ \]"` reports a file of
  headings as clean, so an entry written any other way is invisible to it — this
  has already happened, with forty findings including four high-severity defects
  reading as done. Before trusting an empty result, check the files have boxes at
  all: `grep -rc "^- \[" findings/` should be non-zero for every one.
- **Findings stay attributable**, which is what a rejection needs: a fixer that
  disagrees knows which reviewer to argue with.
- **Never relay a finding through a brief.** Name the file. A paraphrase arrives
  without the evidence that backed it, and a report copied into the runner's
  context and then rewritten into the next brief occupies it twice — which is what
  crowds out the state the runner needs to keep.

Durable reasoning moves into `design.md` before the tracker goes. The tracker is
scaffolding; the reasoning is not.

### Handing over between agents

**Read the files another agent wrote** — findings, `design.md`, `tasks.md`. What
does not reach you is its *report*, which returns to the runner; so anything an
agent needs passed on must be in a file, not in a report.

**A brief points at the work; it does not contain it.** A dispatch is which piece
and which file. **It no longer carries worktree instructions at all**, because
the agent is dispatched with `isolation: "worktree"` and arrives in a correct
tree already:

> Act on the findings for `dev-writer` in
> `openspec/changes/embedded-node-wizard/findings/`. Piece branch
> `piece/embedded-wizard`. Commit to your own branch and say what it is called,
> so the work can be cherry-picked onto the piece.

The `git -C <worktree>` instruction and the `EnterWorktree` prohibition **come
out of the briefs** — an agent that is already in the right place needs neither,
and a brief that still carries them sends it looking for a problem it does not
have. What remains worth saying is where the commits end up, because that did
change.

#### Why the prohibition is still written down

The failure below is no longer an operating instruction; it is the explanation
for why dispatches look the way they do. Keep it findable, because an agent that
meets the refusal without this context improvises, and the improvisations cost
real time.

**A dispatched agent must not call `EnterWorktree`.** Not "should try and fall
back" — the call cannot succeed usefully, and two probes measured both routes:

- **Dispatched normally**, working directory at the repository root, worktree
  correctly registered in `git worktree list`. Verbatim: *"Cannot enter worktree:
  the current working directory /…/radicle-logos-module is the repository root,
  not an isolated worktree — switching is only available to sessions whose
  working directory is inside a worktree of this repository."* The repository
  root is where every dispatched agent starts, so this refusal is certain rather
  than possible.
- **Dispatched with `isolation: "worktree"`**, which pins the working directory
  inside a throwaway worktree and so clears that precondition. The call
  **succeeded** and an environment update reported the directory change — then
  the agent was split: the Read tool followed the switch and read the piece
  branch by relative path, while **every Bash call was refused** with *"This
  agent is isolated in the worktree …/agent-<id>, but this command's working
  directory resolved to the shared checkout (…). Refusing to run it there — a
  worktree-isolated agent's commands must run inside its worktree."*

**There is no supported way to place a dispatched subagent inside a pre-existing
worktree with full tool access.** Route 2 is the more dangerous of the two
because it *looks* like it worked: nothing goes wrong until the first Bash call,
long after the agent has concluded it is in the right place. Do not reach for
`isolation: "worktree"` on discovering route 1 — that is the trap this paragraph
exists to close.

The measured cost of leaving this unexplained: four agents in one session hit the
refusal, and two spent significant time on workarounds (`env -C`, `cd &&`) that
cost approval clicks, because the documents described the shape as working. The
fallback that era prescribed — absolute paths and `git -C <worktree> …` — worked,
and three `dev-writer`s and twelve reviewers completed real work on it. It is
simply no longer needed, because the agent now starts where it belongs.

**The tool itself is not broken — it is for a session moving itself**, which is
what `CLAUDE.md` describes and what it is built for. The distinction is who
calls it, not whether it works.

### How an agent actually gets the right tree: `isolation: "worktree"`

**This is the route the flow now runs on.** Everything above is why it is not
`EnterWorktree`; this is what replaces it. **Dispatch with `isolation:
"worktree"` and no `EnterWorktree` call**, and the agent arrives in its own
worktree with a working directory that needs no correcting: relative paths
resolve, every Bash command runs, and there is nothing to prefix with `git -C`.

**That is not a contradiction of the section above, and the distinction is the
single easiest thing to conflate**, so it is worth stating flatly:

| | Works? |
|---|---|
| a dispatched agent entering a **pre-existing** worktree (`EnterWorktree`) | **no**, and both failure modes are above |
| a dispatched agent placed in **its own** fresh worktree (`isolation`) | **yes** |
| a **session moving itself** into a worktree (`EnterWorktree`) | **yes** — the case the tool is built for |

Probe 2 failed because it *crossed* from an isolated tree into a pre-existing
one. `isolation: "worktree"` alone never crosses, so nothing breaks. And a
session moving *itself* is a third thing again — measured: the main interactive
session called `EnterWorktree(path: …)` and got *"Entered worktree at
…/probe-baseref on branch probe/baseref. The session is now working in the
worktree."* **Who calls it decides the outcome, not whether the tool works.**

#### `baseRef: "head"` is required, and it is not in the repository

By default the agent's tree is cut from `worktree.baseRef: "fresh"` —
`origin/<default-branch>` — which holds **none** of the piece's commits. An agent
reviewing or extending a piece would be reading the wrong code. `.claude/settings.json`
fixes the fork point to the runner's HEAD:

```json
{ "worktree": { "baseRef": "head" } }
```

Measured with a fork point deliberately different from `origin/main` so the
result could not be a coincidence: runner HEAD `a949ec6`, `origin/main`
`cafa02b`, and the dispatched agent reported `a949ec6`. It also had a working
cwd, unrefused Bash, and read `.claude/agents/RUNNER.md` by relative path.

**`.gitignore` excludes `.claude/*`, so this file is not in the repository** —
`git check-ignore -v .claude/settings.json` names line 37. It therefore does not
arrive with a clone, and a fresh checkout silently reverts to forking every agent
from `origin/main`. **Nothing fails when it is missing**; agents simply get the
wrong tree and no error says so. Treat creating it as a setup step for this flow,
and if agents start reporting a fork point that is not your HEAD, check that this
file exists before looking anywhere else.

It is the **user's** file. Do not edit it on your own initiative.

#### What the agent's own branch means for getting work back

The agent lands on a harness-named branch, `worktree-agent-<id>` — **not** the
piece branch. So commits still need a cherry-pick onto `piece/<name>`, exactly
the step reviewers already perform for findings, with one difference worth
noticing: the branch name is assigned by the harness rather than being the
`review/<name>/<dimension>` the runner chose, so **read it rather than assuming
it** (`git rev-parse --abbrev-ref HEAD`).

This applies to writers too, who previously committed straight to the piece
branch because they were standing in its tree. They no longer are.

#### Tools that resolve their root from the cwd — mostly fixed by this

Two tools here cannot be pointed at another tree: **`openspec`** resolves its
root from the cwd and has no `-C`, `--directory` or `--root`; **`lgs basecamp
build`** resolves `scaffold.toml`'s relative module refs against the root it was
invoked from. Under the old dispatch both were a standing constraint, because the
agent's cwd was the main checkout while its work was in a worktree.

**Placing the agent correctly fixes both**, and that is the strongest practical
argument for this dispatch shape: a tool that takes its root from the cwd is
right whenever the cwd is right. An agent in its own tree runs `openspec` and
`lgs` plainly, with no workaround and no compound command.

The hazard they share is worth keeping in view anyway, because it is what makes a
wrong cwd expensive rather than merely inconvenient: **a wrong-tree success is
indistinguishable from a right-tree one in the output.** `lgs basecamp build`
from the wrong root does not fail — it reports a green build of code you did not
write. A tool that refused would be harmless. So before trusting either against a
tree you have not verified, `pwd` and `git rev-parse --abbrev-ref HEAD` cost
nothing.

And the rule that outlives the fix: **never report a result you did not obtain
against the tree in question.** An unrun gate reported as run is worse than a red
one, because the row gets ticked either way.

#### Who removes the agent's tree — this changed, and in the safe direction

**An agent no longer removes its own worktree, because it is standing in it.**
`git worktree remove` refuses the directory you are in, so the instruction would
fail every time it was followed. That is the same shape of defect this piece was
opened to fix, arriving by the opposite route: an instruction that was true when
agents sat in the main checkout and became false when they stopped.

So **tree removal belongs to the runner**, which is where it should have been
anyway. An agent's last act is to report its branch name and that its tree is
ready to prune; the runner removes it after cherry-picking the work off.

This is also the answer to a failure that had no clean fix before: a reviewer was
told explicitly not to remove its tree and removed it anyway. Nothing was lost
— its findings commit had already been cherry-picked — but *"nothing was lost"*
was luck rather than design. **The reason the runner keeps a tree is that it may
still need reading**: to re-check a finding against the exact tree that produced
it, to compare two reviewers' citations, or to recover a mutation the reviewer
left behind. Once `--force` has run, the evidence behind the finding is gone.

Under the old shape that rule depended on every agent remembering it. Now the
agent cannot delete its own tree even by mistake, and **the runner owns tree
lifetime because it is the only party that knows whether anything still needs to
read one.** The invariant holds by construction rather than by instruction, which
is the better fix — see CLAUDE.md on putting complexity in the data rather than
the logic.

The `ExitWorktree(action: "keep")` step this section once prescribed is still
gone, and stays gone: an agent that hands back does not need to step out first.

**If you are writing out what a finding says, you have the wrong shape.** The
reviewer already wrote it with the measurement behind it; a restatement puts a
paraphrase in front of the evidence, which is how a wrong claim reached two agents
here in one day. Reports work the same way in reverse: path, count, who each entry
is for.

Two corollaries. **Continue an agent rather than starting one** — it still holds
its worktree and its measurements, where a new one gets your summary of them. And
**write the dead end down**: a reviewer that spends an afternoon proving an
approach impossible has produced a result worth as much as the review, and
unwritten the next agent spends the same afternoon. It goes in `design.md`, beside
the decision it rules out.

**The runner owns dispatching; the `dev-writer` opens the PR at the end of its
first pass (see [`dev-writer.md`](dev-writer.md) for the sequence); the `closer`
owns the last three stage rows.** `tasks.md`'s stage block is the list — read it to
see what is left, because an unticked row with no agent running is a stage nobody
is doing.

**How the runner does that is [`RUNNER.md`](RUNNER.md), not this section** — how
to tell whether an agent is still running, how many to launch at once, and why
one piece is one PR. It is kept there rather than restated here because two
copies of a rule drift and the wrong one gets read.

The reviewers run in parallel and ask different questions:

- `code-reviewer` — **is this code correct, safe and well-shaped?**
- `spec-test-reviewer` — **do the tests pin what the spec requires, and can they
  fail?**
- `design-reviewer` — **did the code take the decisions that were recorded, and
  were the decisions worth recording recorded?**

**Launch `code-reviewer` once per dimension** — correctness, security,
readability, architecture — naming which in the prompt. Scanning for a reachable
panic is a different reading of a file from scanning for a function doing two
jobs, and one agent holding both becomes whichever it started with. A small
change can take one instance covering all four; a full review is typically six
agents.

**`spec-test-reviewer` is blind to the implementation.** Someone who has read the
code judges tests by what the code does — exactly the failure a spec exists to
catch: a test that faithfully pins the wrong behaviour.

### Every agent pays CLAUDE.md's Bash costs

This applies to every role, and the reviewers most of all, because they run
suites and mutations in a loop. **Read CLAUDE.md's "How to work in this repo,
and what Bash costs" before the first shell command.**

The rule that catches agents most often is **never chain**: `cd somewhere &&
cargo test` prompts *even though* `cargo test` is allow-listed, because the
permission checker cannot statically analyse a compound command, so no rule
applies to it. Run one plain command per call — `cd` alone in its own call is
free, and the Bash tool's directory persists between calls.

**A long output is not a reason to pipe.** This is the most common way the rule
gets broken by someone who knows it: appending `| tail -30` to keep the output
manageable turns a call the checker would have approved into a prompt, which is
the opposite of what the pipe was for. Run it plain and read the whole thing.
Likewise `gh` is free until you filter it — adding `--jq` costs a click where the
plain call costs nothing.

**Address this repo's agents unqualified** — `code-reviewer`, not
`agent-skills:code-reviewer`. The plugin ships a similarly-described reviewer,
and it carries none of this repo's traps.

**A change with no source diff still gets reviewed.** That is not an exemption,
and treating it as one is how this flow's own adopting change nearly shipped with
the `code-reviewer` step skipped entirely. Agent instruction files, config and the
prose in `CLAUDE.md` and `docs/` are all reviewable material — and reviewing them
found a false claim in a header and an agent file whose frontmatter defeated its
own thesis.

## What experience has taught this flow

Each of these is in the agent files because it cost something here.

**A number in a comment is a claim, and this repo fabricates them.** One sweep
found six comments in a single file arguing from premises the code disproves, and
the worst were quantities, because a quantity reads as though someone measured it:
*"wrong for two years"* in a repo five days old — written, no less, in the commit
titled "stop three comments from saying the wrong thing". A plausible number
nobody checks is a fabricated citation that looks like evidence.

**So this is a step, not a caution: run the command before you write the
number.** `grep -c "function test_" <file>` for QML test functions, `grep -c
"#\[test\]"` for Rust ones, `git log -S` for a duration — whichever answers the
claim you are about to make. It is one call, and it is the difference between a
measurement and a guess that reads like one. This is CLAUDE.md's "do not write
down anything a command can answer" applied to the thing an agent writes most
often: a count in a report, a task list or a doc comment.

The caution became a step because a single review round found **five** fabricated
quantities and **one** phantom test name across two independently written pieces
— assertion counts, test counts, and a doc comment citing a test that did not
exist. None of the writers was careless; each number was the kind that feels
remembered rather than invented.

**When you correct a stale number, measure it fresh — do not apply the delta a
reviewer quoted.** The reviewer's figure was itself measured at some earlier
moment, and a branch moves. Verified on this very piece: the phantom test name a
reviewer reported in `nodeconfig.rs` had already been corrected on that branch by
the time it was re-checked, so writing down the reviewer's number would have
introduced a second wrong claim while fixing the first. Re-run the command
against the tree in front of you.

**Make fakes input-dependent, or the assertion is decoration.** A fake that
returns the same thing for every input cannot tell "reloaded" from "never
reloaded", and a feature has shipped completely dead here past every gate for
exactly that reason: a branch-switch test asserted an empty tree against a fake
returning an empty tree for *every* branch — true whether the refetch ran or not.
Deleting the entire `onBranchChanged` body left all tests passing. CLAUDE.md's "A
binding does not update inside the handler that changed its source" tells the
whole story and owns it; read it there rather than from a second copy that can
drift from the first.

**The same trap wears other clothes.** A composer that appends a posted comment
locally renders correctly whether or not the write landed — which is why a
successful post *reloads* the thread instead. Watch for any assertion that would
hold under the null implementation.

**A green gate can be structurally unable to see the change.** Turning Embedded
on was one line in `startableModes()` and touched no QML at all, so the QML suite
proved nothing about it. Ask which layer can actually observe what you changed,
and if the honest answer is "none of the ones that ran", that is the finding.

**Breaking the code on purpose is how you test a test.** `cargo mutants` does it
mechanically for the `rust-ffi` crate — scope it with `--file` — but it mutates
functions and not `const` values, so a changed constant is invisible to it. For
QML and the C++ core the equivalent is manual: delete the handler body, return a
constant, and see whether anything goes red.

**Mark unspecified behaviour in the code.** When the spec is silent and the dev
chooses, the test carries `// NO SPEC: <what was chosen>`. Without a marker a
reasonable default becomes permanent by accident.

**Never write a scenario that cannot be tested.** A field with one variant
cannot be varied through the API; behaviour that does not exist yet cannot be
covered. Describe what is checkable, or say it is out of scope.

**Read PLAN.md from `origin/main`.** A worktree branches from the fetched remote
head, so local `main`, `origin/main` and the worktree can be three different
commits — verified here. A stale plan is the most likely thing to mislead you,
because it is the file most likely to be in context from the start and least
likely to be re-read.

**Silent failure is this codebase's house style, and it must be designed
against.** Basecamp swallows QML errors, so a view that fails to compile, a
plugin skipped for a missing manifest field and a binding evaluating to
`undefined` all present identically as "clicking the app does nothing" — four
separate bugs wore that face. `qmllint` does not catch syntax errors. A
`readonly property` alias to a child that does not exist is `undefined` with no
complaint, which is how four `count` reads stayed broken unnoticed.

**A green gate can be structurally blind, and this flow's own gates are not
exempt.** The findings gate is the standing example: `grep -rn "^- \[ \]"`
reports a findings file written as plain headings as clean, so the check that
exists to block a forgotten finding passes precisely on the files it cannot read —
which is why the findings section carries a pair of greps rather than one. Say
what a gate cannot see rather than reporting it as passed; "exit 0" on a gate that
measured nothing is worse than no gate.

**`qmllint` does not catch syntax errors** — it passed a file Qt then refused with
"Unexpected token `}'". `radicle-ui/tests/check-qml-syntax.sh` covers that, and
runs first in CI.

**One shell trap worth not re-learning**, because it makes a gate silently
passing: `tar tzf … | grep -q` exits 141, since `grep -q` closes the pipe at the
first match and `tar` dies of SIGPIPE. Under a bare `set -eu` that is invisible.
Use `[ "$(… | grep -c …)" -gt 0 ]`, which consumes all the output.

**Specs get reorganised as concepts generalise**, and two capabilities asserting
one rule is the failure that prevents. See
[`docs/OPENSPEC-ARCHIVE.md`](../../docs/OPENSPEC-ARCHIVE.md).
