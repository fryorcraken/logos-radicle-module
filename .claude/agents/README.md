# The spec-driven flow

Role agents around [OpenSpec](https://openspec.dev)'s built-in `spec-driven`
schema. OpenSpec supplies the artifacts and their ordering; Claude Code supplies
the agents. Nothing here is custom tooling — subagents already give isolated
context windows, per-role models and tool limits, which is what per-role
separation needs.

The CLI is `openspec`, from the npm package `@fission-ai/openspec`
(`npm install -g @fission-ai/openspec`). `openspec --help` lists the surface.
Note the bare `openspec` package on npm is an unrelated placeholder at 0.0.0.

## The documents, and what each is for

| Document | Question | Where it ends up |
|---|---|---|
| `docs/PLAN.md` | A short summary of what exists, and **what is not built yet** | Lives at `docs/`, edited forever |
| `proposal.md` | Why this change, which capabilities it touches | `changes/archive/<date>-<name>/` |
| `openspec/specs/` | **What** the system does — the behaviour contract | `openspec/specs/`, current |
| `design.md` | **How**, and **why this approach** (Decisions) | `changes/archive/<date>-<name>/` |
| `tasks.md` | The ordered checklist, opening with the stage block | `changes/archive/<date>-<name>/` |
| `findings/<dimension>.md` | What each reviewer found, and what was done about it | **Deleted before merge** — durable reasoning moves to `design.md` first |

This sits alongside the trigger-specific docs CLAUDE.md indexes — `rust-ffi.md`,
`writes.md`, `e2e.md`. Those describe **built** areas and stay put; they are
where a shipped subsystem's traps live. PLAN.md is the forward-looking one.

### What "archived" means concretely

This is OpenSpec's own behaviour, not a convention of ours.

While a change is in flight it lives in `openspec/changes/<name>/`, and its
`specs/` holds a **delta** (`## ADDED Requirements`). `openspec archive` then:

1. **offers to merge the delta into `openspec/specs/`** — the live, current
   contract. It is a prompt, and declining it archives without promoting the
   spec, so take the sync;
2. **moves the folder** to `openspec/changes/archive/<date>-<name>/`, dated
   today unless the name already carries a date, which is never stacked.

So the change's `proposal.md`, `design.md` and `tasks.md` are moved, not
deleted: they stay in version control and stay greppable. Finding a past
decision means grepping the archive, which is what it is for.

**`openspec/specs/` is the live contract; an archived `specs/` delta is a
historical record of what one change added.** After an archive the two hold
near-identical text, and they will diverge the first time a later change amends
a requirement — the live copy moves and the archived delta does not, correctly,
because it records what *that* change did. So: **never read an archived
`specs/` file as the current contract, and never edit one to match.** If they
disagree, the live spec wins and the archive is right to differ.

This is the one duplication in the flow that is deliberate rather than a
failure, and it is worth naming precisely because everything else here says two
copies drift and the wrong one gets read. The difference is that these two
answer different questions — "what must the system do?" and "what did this
change add?" — and only the first is maintained. A reviewer greping the archive
for a past decision (which is what it is for) must not mistake a superseded
requirement for a live one.

One exception worth knowing: a change that declares `retire_capabilities` can
make archive **delete** a spec rather than merge into it. It takes an explicit
marker, so it cannot happen by accident.

### PLAN.md sheds in two directions

As a change lands, the part of PLAN.md it implements moves out:

- **Behaviour → the spec.** Struck through in PLAN.md, with a one-line summary
  that the thing exists.
- **Reasoning → `design.md`** under Decisions, and removed from PLAN.md. Someone
  investigating a past decision reads the archive; that is what it is for.

PLAN.md is left with what is **not built yet**, plus one line per built area
saying it exists — never why it works that way. Keeping a second copy of the
reasoning is the failure mode: two copies drift and the wrong one gets read.
This is the same discipline CLAUDE.md's "Keeping this file true" section
describes, applied to a second file; that section exists because a third of
CLAUDE.md was once deleted for having quietly become false.

Reasoning never goes in a spec at all — a spec is a behaviour contract, and
prose rationale in one is prose nobody will maintain.

**This applies to changes as they land, not as a migration.** PLAN.md holds
plenty that has no change to attach to yet — the git-spawn-site constraint, the
open passphrase-at-start question. Leave it. It shrinks by attrition as changes
touch each area.

`docs/M3-embedded-node-plan.md` is M3's own working document and **is** edited
as phases merge — each step adds its findings there. `docs/M3-phase0-findings.md`
beside it records one spike and is finished. Both cite the crate source line by
line, which is what makes a claim in PLAN.md re-verifiable rather than
re-derivable. PLAN.md is the cross-milestone view; the two overlap on M3, and
the more recently edited one wins.

An earlier version of this paragraph called both files frozen. A milestone step
edited one of them two days later, which is the lesson: **do not write down that
a document has stopped changing.** It is a claim about the future, and the
cheapest kind to get wrong.

## The roles

| Agent | Reads | Writes |
|---|---|---|
| `spec-writer` | PLAN.md (from `origin/main`) | `proposal.md`, `specs/` |
| `dev-writer` | spec, PLAN.md | `design.md`, `tasks.md`, code, tests-as-it-goes |
| `tester` | spec, inherited tests | the test suite |
| `spec-test-reviewer` | **spec + tests only** | findings |
| `design-reviewer` | code, `design.md`, PLAN.md | findings |
| `code-reviewer` | code | findings |

## One piece of work is one branch and one PR

Every stage — spec, design, code, tests, review fixes — lands as **commits on one
remote branch, under one PR**.

Local branches are fine and a reviewer needs one. What never happens is a *stage*
reaching the remote on its own: only `piece/<name>` is ever pushed, so
`origin/<anything-else>` is a visible mistake rather than a judgement call, and a
second PR on one piece is the failure this section exists to stop.

**The unit of review is a behaviour change with its contract and its tests
attached.** A reviewer must be able to see that they belong together, not be told
so by whoever is orchestrating — and verifying exactly that is what a reviewer is
for. `openspec archive` settles it independently: it runs once, on merge, and
promotes the delta into `openspec/specs/`. Split across several merges, the
contract lands at a different time from the code that honours it — and a delta
whose heading matches nothing applies nothing, so there is no error to notice when
they drift.

A stage is not a unit of review, even though each one looks like one — which is why
the branches below are named for the role and not the stage: `dev/x` invites a
`test/x` beside it, and then a PR each.

### One writer at a time; reviewers in parallel

**A piece has at most one `spec-writer`, `dev-writer` or `tester` running** — not
one of each, **one in total**. They share the piece's single worktree, which they
can do precisely because they never overlap. Two reasons, and neither surfaces as
a git conflict:

- **A spec must not move while code is written against it.** Run the pair together
  and the implementation answers a contract that changed underneath it, with
  neither agent knowing. This repo knows the shape from its own worst bug, one
  layer down: `onBranchChanged` set a property and then called something reading a
  binding derived from it, so the refetch went out against state that had already
  moved — and every gate was green, because nothing observes "answered the wrong
  version of the question". Two agents on one piece is that hazard with a spec in
  place of a binding. It holds on the way back too: when review routes a spec gap,
  stop the fixer, land the spec, restart the fixer against the new text.
- **`tester` mutates implementation code it does not own**, restoring after each
  mutation. A concurrent writer either inherits the broken state or overwrites the
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
| `piece/<name>` | one, shared | the three writers, in turn | **the** task branch, and **the only one pushed**. Spec, code, tests and findings-fixes all commit here directly |
| `review/<name>/<dimension>` | one each | one reviewer | **local only** — its findings file, nothing else, cherry-picked onto the piece and never pushed |

`<dimension>` is the findings filename without its extension — `correctness`,
`security`, `readability`, `architecture`, `spec-test`, `design-review` — so the
branch and the file it carries are never two things to remember. The branch is never
pushed, so there is no `origin/` ref to make a mismatch visible; the naming rule is
all that catches it.

**Why the three writers share one tree rather than getting one each**, since a tree
each is the obvious alternative: they never run at the same time, so the isolation
would protect nothing, and each would then need a cherry-pick to get its work onto the
piece — a step to get wrong in exchange for nothing. Reviewers pay that cost because
they genuinely overlap.

That reasoning is deliberately repeated in `spec-writer.md`, `dev-writer.md` and
`tester.md` as well as here. The duplication is a chosen cost: an agent reads only its
own file, and a bare "share the tree" without the reason invites the workaround the
rule exists to prevent. **So if the concurrency rule is ever relaxed — giving `tester`
its own tree, say — there are four sites to retire, not one.** Written down because a
missed one becomes an instruction contradicting the new rule, in a file some agent
reads as authoritative.

**Open the PR on `piece/<name>` from the first commit.** Renaming the branch under an
open PR is not a cheap correction, so the cheap thing is getting the name right once.

The specifics below were established in the sibling dialectica repo rather than here,
and are recorded as inherited rather than measured — if you need to rely on one,
re-check it against `gh api` first. A PR's head ref is reported there as immutable:
`PATCH /pulls/<n> -f head=…` returns 200 and silently ignores the field, and `--base`
changes the target, not the source. The rename endpoint does follow open PRs, but
auto-closes one whose *head* vanished; and where the target name already exists you
must delete that ref first, at which point the rename recreates it at the old
branch's tip and drops what the deleted ref held. That last one cost six reviewers'
findings there, recovered only from a local reflog.

**So do not try to rename or re-point a branch that has an open PR.** If the name is
wrong, open a new PR on the correctly-named branch and close the old one, saying in
the closing comment where the work went. That loses a PR number and nothing else;
every other route risks losing commits.

**Only the runner pushes.** A reviewer commits its findings file on its own branch,
cherry-picks that commit onto the local `piece/<name>`, and stops; the writers commit
to `piece/<name>` directly. With one pusher there is no race to lose, no rebase to
retry, and no force-push to be tempted by.

Cherry-pick rather than merge, so the task branch reads as a flat sequence of
findings and fixes rather than six merge commits carrying six branches.

**Only reviewers get a side branch**, because only reviewers genuinely run in
parallel — six at once, while a fixer may still be changing the code they are
reading. Everyone else writes the piece one at a time and commits to it directly; a
side branch there would add a step to get wrong and misname the commits besides.

The reason single-pusher matters is sharper for fixes than for findings. Two reviewers
never write the same path, so their files could have gone straight to the branch
safely. **Two fixes to one piece routinely touch the same file** — and serialising
them through the one role that can see both changes is what leaves a conflict to
somebody able to resolve it, rather than to whichever agent pushed second.

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
list**; each agent file states the rule, because an agent reads only its own file, and
points here rather than repeating the list, which is the part that changes.

**Check `git branch -vv` before any git write.** A worktree created from a branch
inherits that branch's upstream, so a bare `git push` can land commits somewhere
you did not name. CLAUDE.md's "Working in a git worktree" has the rest — in
particular that worktrees branch from `origin/main`, and that the stash stack is
shared with every other worktree, so never bare `git stash pop`.

**Consolidating branches is not finished until the orphaned PRs are closed.**
Folding a branch into the piece leaves its PR open, describing work that now lives
somewhere else — so the PR list stops being a count of work in progress, which is
the only thing that makes a work-in-progress limit checkable. Before closing one,
prove it is redundant:

```
git log --oneline origin/<orphan> --not origin/piece/<name>
```

Empty means contained. **Non-empty means fold it first** — and a commit
cherry-picked rather than merged shows here even though its content is already in,
so read the commits rather than the count.

## Where the state of a change lives while it is in flight

`tasks.md` carries which stages are done and `findings/` carries what review found.
Each agent's own file says what it writes; these two are the shapes everyone needs to
recognise, because everyone reads both.

Both are scaffolding and both go: `findings/` is deleted before merge, and `tasks.md`
is archived. **`design.md` is the one that survives as something anyone reads again**,
which is why durable reasoning has to be moved into it before the tracker is deleted.

**`tasks.md` opens with a stage block**, written once by `spec-writer` and unticked:
one row per stage, then two rows the runner owns. **The roster itself lives in
[`spec-writer.md`](spec-writer.md)**, which is the agent that writes it into
`tasks.md`; copying it here as well would mean a roster change made in one file
shipping the stale list from the other, which is the hazard the dimension count two
sections down is deliberately not written to avoid.

**One row per agent instance, not per role** — `code-reviewer` runs once per
dimension, so it gets one row per dimension, each ticked by the instance that did
it. Do not collapse them onto one line to save space: a shared checkbox is one
nobody can tick truthfully, and all four instances would then edit the same line,
which is the conflict one-row-per-agent exists to prevent.

Each agent flips its own row and adds none, so concurrent cherry-picks never touch
the same line. **An unticked row with no agent running is a stage nobody is
doing** — that is the whole point — **unless it is struck through**, which is how a
stage says it does not apply and why the row is struck rather than deleted: a deleted
row and a skipped stage look identical, and a struck one says which. A struck row
keeps its empty box, so read the strike, not the box. Nothing greps this block; the
`findings/` greps are scoped to that directory, and the stage block is read. Without it, which stages a change has been
through lives only in the runner's head, and a piece can reach the edge of merge
missing reviewers with nothing visible to say so.

**A piece with no behaviour change still gets a change folder and a stage block.**
A test-only or docs-only piece adds no requirement, so it has no spec delta and
its spec row is struck through with that reason. Declare that in the change's
`.openspec.yaml` as `skip_specs: true` — **alongside a `schema:` key**, because
`skip_specs` on its own is reported as metadata that "is not valid change
metadata, so the marker is not honored", which reads as a complaint about the
marker rather than about the missing line beside it. It still needs reviewing, and
without the block there is no unticked row to say so: the signal that catches a
missing reviewer is absent exactly where it is easiest to skip one. That is not
hypothetical here — this flow's own adopting change nearly shipped with the
`code-reviewer` step skipped entirely, on the reasoning that a change with no
source diff had nothing to review.

**`findings/<dimension>.md`**, one file per reviewer — `correctness`, `security`,
`readability`, `architecture`, `spec-test`, `design-review`. One file *per
reviewer* and not one shared file, because six reviewers appending to one path in
six worktrees is six conflicting versions of it, which git resolves as a conflict
rather than a merge. `design-review.md` rather than `design.md`, because the change
already has one of those and the collision would be silent.

**Every finding is a checkbox**, written unticked by the reviewer:

```markdown
- [ ] **`dev-writer`** — `RepoView.qml:191` — the refetch goes out for the old branch
      **Scenario:** pick branch `b` while on `a` → the pane repopulates with `a`'s
      entries, because `SourceTab.branch` is a binding that has not re-evaluated inside
      the handler that changed its source.
      **Measured:** deleting the whole `onBranchChanged` body leaves the QML suite green.
```

Whoever acts on it flips the box and appends the outcome — **fixed** (with the test
that fails without it), **rejected** (with the argument), or **deferred** (and
where to) — **without editing the reviewer's text**. The runner deletes the
directory before merge, once no box is empty.

The tick distinguishes the three outcomes on purpose: "fixed" is the one nobody
re-reads, and a rejection closed as a fix loses both the defect and the reasoning
that would have caught it.

So "blocks the merge" is literal and checkable: `grep -rn "^- \[ \]"` over the
directory either returns lines or it does not.

What follows from that, whatever your role:

- **An unticked entry blocks the merge.** A file, not a convention, so a forgotten
  finding stops a PR instead of evaporating.
- **The gate only sees a box in the first column.** `grep -rn "^- \[ \]"` reports a
  file of headings as clean, so an entry written any other way is invisible to the
  gate that exists to catch exactly it. This is the same failure this repo keeps
  hitting from the other side — a green gate structurally unable to see what it
  appears to check. Two rules follow, and both were measured rather than reasoned:

  **Every box starts at column zero.** The `^` anchor is load-bearing, and an
  indented `- [ ]` defeats *both* greps at once — the first misses it on the
  anchor, and the second counts the ticked box above it and returns non-zero, so
  the companion check reports clean too. That is reachable from the entry format
  itself, whose continuation lines are indented: a follow-up written as a nested
  box disappears. Append prose under an entry, never another box; a second thing
  that must happen is a second top-level entry.

  **Before trusting an empty result, confirm the files have boxes at all** —
  `grep -rc "^- \[" findings/` is non-zero for every file in the intended format
  and zero for one written any other way. A zero has two causes and they are fixed
  differently: a reviewer that wrote prose instead of boxes needs that one file read
  and re-formatted, where a directory written before a format change needs the whole
  directory re-read. The sibling repo hit the second — forty entries, four of them
  high-severity, all reading as done to the gate — which is the case to expect if this
  format is ever revised.
- **Findings stay attributable**, which is what a rejection needs: a fixer that
  disagrees knows which reviewer to argue with, and the runner can send it back to
  that agent while it still holds its worktree and its measurements.
- **Never relay a finding through a brief.** Name the file. A paraphrase arrives
  without the evidence that backed it, and a full report copied into the runner's
  context and then rewritten into the next brief occupies that context twice —
  which is what crowds out the state the runner needs to keep track of which work
  has an agent on it.

Durable reasoning moves into `design.md` before the tracker goes. The tracker is
scaffolding; the reasoning is not.

### Handing over between agents

**Read the files another agent wrote** — findings, `design.md`, `tasks.md`. What
does not reach you is its *report*, which returns to the runner; so anything an
agent needs passed on must be in a file, not in a report.

**A brief points at the work; it does not contain it.** A dispatch is which piece,
which worktree, which file:

> Act on the findings for `dev-writer` in
> `openspec/changes/embedded-node-wizard/findings/`. Piece branch
> `piece/embedded-wizard`, worktree `.claude/worktrees/piece-embedded`.

**If you are writing out what a finding says, you have the wrong shape.** The
reviewer already wrote it with the measurement behind it; a restatement puts a
paraphrase in front of the evidence. Reports work the same way in reverse: path,
count, who each entry is for.

Two corollaries. **Continue an agent rather than starting one** — it still holds
its worktree and its measurements, where a new one gets your summary of them. And
**write the dead end down**: a reviewer that spends an afternoon proving an
approach impossible has produced a result worth as much as the review, and
unwritten, the next agent spends the same afternoon. It goes in `design.md`,
beside the decision it rules out.

**The runner owns the last two stage rows, plus dispatching and pushing.**
`tasks.md`'s stage block is the list — read it to see what is left. Dispatch by
naming the findings files rather than carrying their content, and re-run only the
reviewers whose findings led to changes. Those two rows are:

- **Deleting `findings/` once no box is empty**, having checked with the grep pair
  above. With several fixers across six files, "whoever finishes last" is an owner
  nobody is, which is how a gate gets skipped; the runner is the one role that sees
  all six. Every reviewer ends "findings only, do not fix", and routing is the
  reviewer's own job — each finding names who it is for.
- **`openspec validate --strict` and `openspec archive`.** Archive is where the
  delta is merged into `openspec/specs/` — skip the step, or decline its sync
  prompt, and the change ships with its spec never promoted. Do it once the change
  is otherwise done, and **take the sync whenever the change has a delta**. A piece
  that declared `skip_specs: true` has none to promote, and archives with
  `--skip-specs`, which the CLI documents for exactly this case; taking a sync there
  would be promoting nothing.

The reviewers run in parallel and ask different questions:

- `code-reviewer` asks **is this code correct, safe and well-shaped?**
- `spec-test-reviewer` asks **do the tests pin what the spec requires, and can
  they fail?**
- `design-reviewer` asks **did the code take the decisions that were recorded,
  and were the decisions worth recording recorded?**

**`code-reviewer` is launched once per dimension** — correctness, security,
readability, architecture — with the prompt naming which. One agent holding all
four does each worse: scanning for a stale-reply guard is a different reading of
the same file from scanning for a function doing two jobs, and a single pass
becomes whichever the reviewer started with. A small change can take one
instance covering all four — and then it writes one findings file per dimension it
was given, and ticks each of those rows, so an unticked row still means nobody has
done it.

So a full review is one `code-reviewer` per dimension, plus `spec-test-reviewer`
and `design-reviewer`. The dimensions are listed in `code-reviewer.md`; read
them from there rather than from a number here, so adding one does not make this
sentence quietly false.

`spec-test-reviewer` is deliberately blind to the implementation. Someone who
has read the code judges tests by what the code does, which is exactly the
failure a spec exists to catch: a test that faithfully pins the wrong behaviour.

### Every agent pays CLAUDE.md's Bash costs

This applies to all six roles, and the reviewers most of all, because they run
suites and mutations in a loop. **Read CLAUDE.md's "How to work in this repo,
and what Bash costs" before the first shell command.**

The rule that catches agents most often is **never chain**: `cd somewhere &&
cargo test` prompts *even though* `cargo test` is allow-listed, because the
permission checker cannot statically analyse a compound command, so no rule
applies to it. An allow rule cannot save a compound command. Run one plain
command per call — `cd` alone in its own call is free, and the Bash tool's
directory persists between calls.

**When you write a prompt for one of these agents, do not phrase an
instruction in a way that invites a chain.** "`cargo test` from
`radicle/rust-ffi/`" reads as `cd radicle/rust-ffi && cargo test`; say which
directory to run in as its own step, or give a `--manifest-path`. This is a
real cost that has been paid here.

**A long output is not a reason to pipe.** This is the most common way the rule
gets broken by someone who knows it: appending `| tail -30` to keep the output
manageable turns a call the checker would have approved into a prompt, which is the
opposite of what the pipe was for. Run it plain and read the whole thing.

**Address the repo's agents unqualified** — `code-reviewer`, not
`agent-skills:code-reviewer`. The plugin ships a similarly-described reviewer,
and it carries none of this repo's traps: the input-independent fake, the
binding that has not settled, `guarded()`, the vendor-hash-and-lock pairing,
the `grep -q` SIGPIPE exit.

**A change with no source diff still gets reviewed.** That is not an exemption,
and treating it as one is how this flow's own adopting change nearly shipped
with the `code-reviewer` step skipped entirely. Agent instruction files, the
`openspec/config.yaml` context block injected into every future artifact
prompt, and the prose in `CLAUDE.md` and `docs/` are all reviewable material —
and reviewing them found a false claim in a header, an agent file whose
frontmatter defeated its own thesis, and a handoff that could silently lose the
reasoning this flow exists to preserve. A change like that has no spec delta, so
its spec row is struck through with that reason — and every review row stays.

## What experience has taught this flow

Each of these is in the agent files because it cost something here.

**Make fakes input-dependent, or the assertion is decoration.** A fake that
returns the same thing for every input cannot tell "reloaded" from "never
reloaded", and a feature has shipped completely dead here past every gate for
exactly that reason. CLAUDE.md's "A binding does not update inside the handler
that changed its source" tells the whole story and owns it; read it there
rather than from a second copy that can drift from the first.

**The same trap wears other clothes.** A composer that appends a posted comment
locally renders correctly whether or not the write landed — which is why a
successful post *reloads* the thread instead. Watch for any assertion that would
hold under the null implementation.

**A green gate can be structurally unable to see the change.** Turning Embedded
on was one line in `startableModes()` and touched no QML at all, so the QML
suite proved nothing about it. Ask which layer can actually observe what you
changed, and if the honest answer is "none of the ones that ran", that is the
finding.

This flow's own gates are not exempt, which is why the findings section carries the
pair of greps rather than one: `grep -rn "^- \[ \]"` reports a findings file written
as plain headings as clean, so the check that exists to block a forgotten finding
passes precisely on the files it cannot read.

**A regression test must provably fail before the fix.** Write it first, watch
it fail, then fix. A regression test that has never failed proves nothing about
the bug it claims to cover.

**Silent failure is this codebase's house style, and it must be designed
against.** Basecamp swallows QML errors, so a view that fails to compile, a
plugin skipped for a missing manifest field and a binding evaluating to
`undefined` all present identically as "clicking the app does nothing" — four
separate bugs wore that face. `qmllint` does not catch syntax errors. A
`readonly property` alias to a child that does not exist is `undefined` with no
complaint, which is how four `count` reads stayed broken unnoticed. And an
unannounced COB write is legitimately not an error, which is how an announce
going nowhere stayed invisible.

**A binding does not update inside the handler that changed its source.** If a
handler sets a property then calls something reading a binding derived from it,
the binding has not re-evaluated yet. Defer by one event-loop turn or pass the
value explicitly.

**Read PLAN.md from `origin/main`.** A worktree branches from the fetched remote
head, so local `main`, `origin/main` and the worktree can be three different
commits — verified here. A stale plan is the most likely thing to mislead you,
because it is the file most likely to be in context from the start and least
likely to be re-read.

**Specs get reorganised as concepts generalise.** When a second instance shows
that requirements written for one capability are really about a general one,
they move — `REMOVED` from the old spec and `ADDED` to the new, verbatim, in one
change. OpenSpec has no capability move or rename, so the extraction is composed
from those primitives. Do it when the generality is demonstrated, not predicted.
