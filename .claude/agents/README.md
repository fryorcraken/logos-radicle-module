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
| `tasks.md` | The ordered checklist | `changes/archive/<date>-<name>/` |

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

`docs/M3-embedded-node-plan.md` and `docs/M3-phase0-findings.md` are research
that PLAN.md was distilled from, kept because they cite the crate source line by
line. They are **not** edited as phases merge, and where they disagree with
PLAN.md, PLAN.md is the live one.

## The roles

| Agent | Reads | Writes |
|---|---|---|
| `spec-writer` | PLAN.md (from `origin/main`) | `proposal.md`, `specs/` |
| `dev-writer` | spec, PLAN.md | `design.md`, `tasks.md`, code, tests-as-it-goes |
| `tester` | spec, inherited tests | the test suite |
| `spec-test-reviewer` | **spec + tests only** | findings |
| `design-reviewer` | code, `design.md`, PLAN.md | findings |
| `code-reviewer` | code | findings |

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

**Two steps belong to whoever is running the change, not to any agent:**

- **Acting on findings.** Every reviewer ends "findings only, do not fix". A
  finding about behaviour goes back to `spec-writer`; about the code, to
  `dev-writer`; about a test, to `tester`. Re-run only the reviewers whose
  findings led to changes.
- **`openspec validate` and `openspec archive`.** Archive is where the delta is
  merged into `openspec/specs/` — skip the step, or decline its sync prompt, and
  the change ships with its spec never promoted. Do it once the change is
  otherwise done, and take the sync.

The three reviewers split deliberately, and run in parallel:

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
instance covering all four.

So a full review is one `code-reviewer` per dimension — four of them — plus
`spec-test-reviewer` and `design-reviewer`. The count follows from the roles
rather than being a fact to maintain: one per dimension, plus one of each other
reviewer. `ls .claude/agents/` is the authority on which roles exist.

**A change with no source diff still gets reviewed.** That is not an exemption,
and treating it as one is how this flow's own adopting change nearly shipped
with the `code-reviewer` step skipped entirely. Agent instruction files, the
`openspec/config.yaml` context block injected into every future artifact
prompt, and the prose in `CLAUDE.md` and `docs/` are all reviewable material —
and reviewing them found a false claim in a header, an agent file whose
frontmatter defeated its own thesis, and a handoff that could silently lose the
reasoning this flow exists to preserve.

`spec-test-reviewer` is deliberately blind to the implementation. Someone who
has read the code judges tests by what the code does, which is exactly the
failure a spec exists to catch: a test that faithfully pins the wrong behaviour.

**Give each reviewer that mutates code its own worktree.** Two sharing a tree
see each other's broken code and cannot tell it from the author's. See
CLAUDE.md's "Working in a git worktree" for the mechanics — in particular that
worktrees branch from `origin/main`, that the stash stack is shared, and that
they must be removed when the branch lands.

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
