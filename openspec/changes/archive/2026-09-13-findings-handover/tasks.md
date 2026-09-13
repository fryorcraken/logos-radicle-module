# Tasks

## Stages

The four `code-reviewer` rows were covered by **one** instance, which the dimensions
allow for a small change; it wrote one findings file per dimension and reported which
it had covered, so each tick names work actually done.

`openspec archive` counted the three struck-through rows as incomplete and warned
before continuing. Expected: a struck row keeps its empty box by design, because `[x]`
would have to mean both "done" and "not applicable". The warning is the cost of that,
and it is the right way round — a tool that counts a skipped stage is better than one
that cannot tell it from a finished one.

- [ ] ~~spec — `spec-writer`~~ — no spec delta: this change alters the flow's own
  instruction files, and adds no requirement to the module's behaviour contract
- [x] design + code — `dev-writer`
- [ ] ~~tests — `tester`~~ — no test layer can see an instruction file; the gate
  claims made here were verified by running the greps against fixtures instead
- [x] review: correctness — `code-reviewer`
- [x] review: security — `code-reviewer`
- [x] review: readability — `code-reviewer`
- [x] review: architecture — `code-reviewer`
- [ ] ~~review: spec-test — `spec-test-reviewer`~~ — its two inputs, a spec and a
  test suite, do not exist for this change
- [x] review: design — `design-reviewer`
- [x] findings all ticked, `findings/` deleted — runner
- [x] `openspec validate --strict`, then `archive` — runner

## Implementation

- [x] Route review findings through `openspec/changes/<name>/findings/<dimension>.md`,
      one file per reviewer, every entry an unticked checkbox
- [x] Give `tasks.md` a stage block, one row per agent instance, ticked by the
      instance that did the work
- [x] Write down the branch rules: one piece is one `piece/<name>` and one PR, only
      reviewers get a side branch, only the runner pushes
- [x] Say where each agent works and what it deletes when it finishes
- [x] Point `CLAUDE.md`'s flow table row and its Bash-cost list at both
