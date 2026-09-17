# Archiving an OpenSpec change

Read this when you are **archiving** — run by the `closer` as a commit on the
piece branch, before CI and before the merge. `.claude/agents/README.md` is the
flow; this is the one step with enough mechanical detail to be worth its own
page.

Archiving before the merge rather than after is deliberate: `archive` rewrites
the live contract in `openspec/specs/`, so it has to be in the tree CI tests and
in the diff the merge applies. The whole change — code, spec delta and the
promotion — lands as one squashed commit under one PR.

The alternative was tried in the sibling repo and **cannot work here**: archiving
after the merge needs a second push straight to `main`, and `main` has
`enforce_admins` on, so that push is rejected with `GH006`. Its first closer hit
exactly that and fell back to opening a second PR for one commit. The ordering that
demanded it does not survive either — `openspec archive` *moves* the change folder
rather than deleting it, so a squash costs nothing that matters, and what it buys is
that the code and the spec describing it revert together.

**Run `openspec --version` rather than believing any document about it** —
including this one. The CLI is `openspec`, from the npm package
`@fission-ai/openspec`; note the bare `openspec` package on npm is an unrelated
placeholder, so install with the scoped name.

## What archive does

While a change is in flight it lives in `openspec/changes/<name>/`, and its
`specs/` holds a **delta** (`## ADDED Requirements`). `openspec archive`:

1. **offers to merge the delta into `openspec/specs/`** — the live contract. It
   is a prompt, and declining it archives without promoting the spec, so take
   the sync;
2. **moves the folder** to `openspec/changes/archive/<date>-<name>/`, dated
   today unless the name already carries a date, which is never stacked.

`proposal.md`, `design.md` and `tasks.md` are moved, not deleted — still in
version control, still greppable. Finding a past decision means grepping the
archive.

A change declaring `retire_capabilities` makes archive **delete** a spec instead
of merging into it. It takes an explicit marker, so it cannot happen by
accident.

**`archive` aborts and writes nothing if the target spec has no `## Purpose`.**

**A change that declared `skip_specs: true` has no delta to promote** and
archives with `--skip-specs`, which the CLI documents for exactly this case;
taking a sync there would be promoting nothing. This repo has one of each in
`openspec/changes/archive/` — compare the two folders rather than assuming every
change carries a `specs/`.

## The transformation, and why to diff it

**Do not check the diff against a remembered hunk count — read the edits.** The
count is not a stable property: how many hunks git prints depends on how far
apart the edits fall, and the shape of the edits themselves depends on what the
delta already had. The rule most often quoted ("prepend a title, rename the
heading, two hunks") is wrong on both halves for a delta that already carries a
title line. An earlier version of this page replaced it with "three hunks", which
was wrong too — those three edits fall within three lines of each other, so git
coalesces them into **one**.

Measured on `2026-09-12-m3-embedded-node-foundations/specs/node-paths/spec.md`
against `openspec/specs/node-paths/spec.md` — the local reference pair, **one
hunk containing three edits**:

1. the title is **rewritten**, `# node-paths` → `# node-paths Specification`.
   Nothing is prepended, because the delta already had a title; a delta that
   opens straight on `## ADDED Requirements` will differ here;
2. **the blank line after `## Purpose` is removed**, which no version of the
   two-edit rule mentions;
3. `## ADDED Requirements` is renamed to `## Requirements`.

Everything else carries across byte-for-byte. **The CLI does not report what it
changed**, so diff the promoted file against the delta and read every changed
line — `git diff --no-index <delta> <live>` on the pair above is the control that
tells you what normal looks like in this repo. A merge nobody diffed is a merge
nobody verified; **a changed line you cannot account for is the finding**, and so
is a requirement whose text moved. Count edits, not hunks.

**Do not derive the rule from a live spec that was hand-edited in the same
commit as its delta.** The sibling dialectica repo has one (`stoa-genesis`):
whole added paragraphs and `SHALL` → `MUST` rewrites landed alongside the delta,
so no diff ever showed them and the pair reads as though archive had done it.
A pair is only a reference example if the two files were never touched after the
archive.

## Traps, none visible from the files

- **Deltas vary in shape.** Some carry a `## Purpose`, some carry a title line
  and none, some open straight on `## ADDED Requirements`. A merge assuming a
  Purpose mangles those.
- **A `MODIFIED` requirement replaces the WHOLE block, scenarios included.**
  Swapping the prose and leaving the old scenarios produces a requirement whose
  scenarios contradict it, with no error.
- **A `MODIFIED` heading that matches nothing must stop the merge.** Check every
  heading against the target's actual `### Requirement:` lines, character for
  character, and report a miss rather than guessing. v1.13.0 does catch a
  MODIFIED block that *omits* a scenario the live spec still has, naming it —
  but do not rely on the tool to catch a heading that matches nothing.

**A spec can contradict itself and `validate --strict` will pass it.** It checks
heading structure, not consistency: in the sibling repo it twice passed a spec
whose prose and scenarios disagreed about the same field. Re-read the whole
requirement after editing it.

**Archive in merge order**, oldest first — a later `MODIFIED` must apply to the
text an earlier `ADDED` produced. Derive the order from
`git log --name-status --diff-filter=A -- openspec/changes`; do not guess from
folder names. The archive date is the day you archive, which is the day the
piece merges unless the merge is held overnight.

## The root comes from the cwd

Every command reports it — `openspec list --json` ends with
`"root": {"path": …, "source": "nearest"}` — and "nearest" is literal: it walks
up from the current directory to the first `openspec/` it finds. There is **no
`--directory`, `-C` or `--root`**. `--store` takes a registered kebab-case store
id, not a path.

Agents work in worktrees, so this used to bite immediately: an agent's cwd was
the main checkout while its change lived in a worktree, and the change was simply
not listed. **That is fixed by where agents now stand rather than by anything in
`openspec`.** Dispatched with `isolation: "worktree"`, an agent's cwd *is* the
tree holding its change, so `openspec` resolves the right root and runs plainly —
no compound command, no approval click, no workaround. A tool that takes its root
from the cwd is correct exactly when the cwd is.

**Check the reported root before concluding a change is missing or the CLI is
broken.** It is one line of `openspec list --json`, and it distinguishes "the
change does not exist" from "I am standing in the wrong tree" — which otherwise
look identical.

Two things not to reach for if it ever does go wrong. **`EnterWorktree` is not
for a dispatched agent** — it refuses a session at the repository root, and
crossing between worktrees succeeds while leaving every Bash call refused;
`.claude/agents/README.md`'s "Handing over between agents" has both probes
verbatim. And **`cd <dir> && openspec …` costs an approval click** even though
`Bash(openspec:*)` is allow-listed, because the checker cannot analyse a compound
command.

If validation genuinely cannot run, **say in the report that it did not run, and
why**. An unrun gate reported as passed is worse than a skipped one, because the
row gets ticked either way.

## Reading two capabilities together

**A contradiction between capabilities is invisible until they are merged.** Two
deltas each internally consistent can jointly demand something the design
deliberately does not provide, and each was reviewed alone. Archiving is the
first moment they sit in one contract, so it is the moment to read them
together. A sweep finding such a pair should resolve it, not leave the next
reader a contract with two answers.

**Two capabilities asserting one rule is the same hazard, one step milder.** Two
copies drift and the reader who finds the stale one cannot tell. Which capability
owns a rule is a design call, not a sweep's — but the sweep is where it gets
noticed. The discipline that works is declining to restate and **saying so in the
Purpose**, naming the other requirement and the boundary.

This is the same rule as `openspec/specs/` versus an archived `specs/` delta,
which the flow README covers: those two are *allowed* to diverge because only
one is maintained. Two live capabilities are not.

## Moving requirements between capabilities

When a second instance shows that requirements written for one capability are
really about a general one, they move: `REMOVED` from the old spec and `ADDED` to
the new, verbatim, in one change. OpenSpec has no move or rename, so the
extraction is composed from those primitives. Do it when the generality is
demonstrated, not predicted.
