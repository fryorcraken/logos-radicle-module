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
one of each, **one in total**. They share the piece's single worktree, which they
can do precisely because they never overlap. Two reasons, and neither surfaces as a
git conflict:

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
| `piece/<name>` | one, shared | the three writers in turn, then the `closer` | **the** task branch, and the only branch of the three that is pushed. Spec, code, tests, findings-fixes and the archive all commit here directly |
| `review/<name>/<dimension>` | one each | one reviewer | **local only** — its findings file, nothing else, cherry-picked onto the piece and never pushed |
| `main` | — | nobody | **no agent ever pushes here.** It takes commits through a PR only |

**`spec-writer`, `dev-writer` and `tester` share one worktree, checked out on
`piece/<name>`.** They can share it precisely because they never run at the same
time; handing each its own tree would buy nothing and add a cherry-pick to get
wrong. Reviewers get a tree each because they are the only agents that overlap.

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

**Each agent pushes its own commits, once its work is done** — `dev-writer` and
`tester` after theirs. The `dev-writer` pushes at the end of its first pass and
opens the PR there; see [`dev-writer.md`](dev-writer.md).

The `closer` also pushes, after committing the **archive** to the piece branch,
before the CI check and the merge.

**Nobody pushes `main`.** It takes commits through a PR only — `enforce_admins`
is on, and a direct push is rejected with `GH006`. This page and `closer.md` both
used to say the archive was an exception, until a closer tried it.

**Only reviewers get a side branch**, because only reviewers run genuinely in
parallel — six at once, while a fixer may still be changing the code they are
reading. A reviewer's own branch is what stops its commit racing that. Everyone
else writes the piece one at a time and commits to it directly; a side branch there
would add a step to get wrong and misname the commits besides.

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

**Check `git branch -vv` before any git write** — a worktree created from a branch
inherits that branch's upstream, and a bare `git push` has landed commits directly
on `main` here more than once. CLAUDE.md's "Working in a git worktree" has the rest —
in particular that worktrees branch from `origin/main`, and that the stash stack is
shared with every other worktree, so never bare `git stash pop`.

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

**A brief points at the work; it does not contain it.** A dispatch is which piece,
which worktree, which file — and it tells the agent to enter that worktree first:

> Act on the findings for `dev-writer` in
> `openspec/changes/embedded-node-wizard/findings/`. Piece branch
> `piece/embedded-wizard`, worktree `.claude/worktrees/piece-embedded` — enter it
> with `EnterWorktree(path: "…/.claude/worktrees/piece-embedded")` before anything
> else, then use plain relative paths.

**Say that in every brief, because it is what keeps an agent out of the shapes
that cost a permission click.** An agent that never moves its working directory
reaches for `cd <dir> && …` or `git -C <dir> …` on every call — the first is the
single biggest source of prompts here, and the second spreads an absolute path
through every git command an agent writes. `EnterWorktree` moves the session into
the tree once, and everything after is an ordinary relative-path command in the
right place.

Two things about the tool that decide how it is used here:

- **`path` enters an existing worktree; `name` creates one.** The runner has
  already made the piece's worktree with `git worktree add`, so a dispatched agent
  passes `path` and never `name` — `name` would branch from `origin/main` and
  strand the agent in an empty tree with none of the piece's commits.
- **It only moves the agent that calls it.** From an agent whose directory was
  pinned at launch, the switch affects that agent alone. So the runner cannot
  enter a worktree on an agent's behalf; the instruction has to be in the brief,
  which is why it belongs in the dispatch shape above rather than in a setup step.
- **It can refuse, and the fallback matters.** A session sitting at the repository
  root has been refused with *"switching is only available to sessions whose
  working directory is inside a worktree"* — measured here, by a reviewer that was
  then unable to follow its own file. **If the call is refused, work through
  absolute paths and `git -C <worktree> …`, and say so in your report.** `git -C`
  is one plain command and costs no approval click, unlike the `cd <dir> && …`
  chain this rule exists to avoid.

The runner itself stays in the main checkout. It dispatches and reads; it is the
agents that need to be somewhere specific.

**A reviewer has to step out before it deletes its tree.** `git worktree remove`
cannot remove the directory you are standing in, so the last two acts are
`ExitWorktree(action: "keep")` — which returns the session to where it started and
leaves the tree alone — and then the `git worktree remove <absolute-path> --force`
its own file already specifies. `keep` is the right action there rather than
`remove`: `ExitWorktree` only removes worktrees it created itself, and these were
made by the runner with `git worktree add`, so asking it to remove one does
nothing and the tree would survive.

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

**The runner owns dispatching; the `dev-writer` opens the PR; the `closer` owns
the last three stage rows.** `tasks.md`'s stage block is the list — read it to
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
titled "stop three comments from saying the wrong thing". Get a duration or a count
from a command (`git log -S`, `grep -c`) before writing it. A plausible number
nobody checks is a fabricated citation that looks like evidence.

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
