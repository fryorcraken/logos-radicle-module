# Security findings — `findings-handover`

Reviewer: `code-reviewer`, single instance covering all four dimensions.

This is a prose-and-instruction change with no source diff, so the usual security
surface (remote data reaching an index, a path crossing the FFI boundary, a write
affordance gated on the wrong predicate) is not present. What *is* reviewable is
whether the new instructions tell an agent to do something destructive, or remove
a safeguard that was there before.

## Clean

- No instruction in the change touches `RAD_HOME`, the user's real `~/.radicle`,
  key material, or any path that crosses the QML/FFI sandbox boundary.
- No new dependency, lockfile or vendor hash.
- The change *strengthens* one existing safeguard rather than weakening it: the
  `git add -A` prohibition is newly stated in four files
  (`README.md:186`, `code-reviewer.md:197`, `dev-writer.md:163`, `tester.md:173`,
  plus `spec-writer.md:17`), each naming the build-output and `./tmp/` scratch that
  a sweep would pick up.
- "Only the runner pushes" narrows who can reach the remote, which is a reduction
  in blast radius, not an increase.

## Findings

- [x] **`dev-writer`** — `.claude/agents/code-reviewer.md:212-215` and
      `spec-test-reviewer.md:27-28` instruct `git worktree remove <path> --force`
      with no guard on which path, while the same change removes the
      "restore and confirm clean" instruction that previously bounded the blast radius
      `--force` on `git worktree remove` discards uncommitted changes in the named
      tree without confirmation. The pre-change instruction was "Restore the tree,
      confirm it is clean, and say so" (`code-reviewer.md`, deleted at line 25-27 of
      the diff); the new instruction is unconditional deletion.
      **Scenario:** a reviewer is invoked without a dedicated worktree — which the
      correctness findings show is genuinely ambiguous in this change, since
      `code-reviewer.md:208` says one is given but the README never tells the runner
      to create it. The reviewer works in the tree it was started in, which for a
      single-instance review of a small change is plausibly the piece worktree or
      even the main checkout. It then follows line 212 and force-removes that tree,
      destroying the piece's uncommitted work. The instruction's own safety argument
      — "your findings file is already committed and cherry-picked, so nothing you
      want lives there any more" — is true only of a tree the reviewer created.
      **Mitigation the change is missing:** say that the path must be the reviewer's
      own `review/<name>/<dimension>` worktree under `.claude/worktrees/`, and that a
      reviewer which did not create a worktree must not remove one. `code-reviewer.md`
      does name `.claude/worktrees/` at line 208 but not as a precondition on the
      removal at 212.
      **Severity:** medium. Data loss rather than a security boundary, but it is the
      one place the change hands an agent an unguarded destructive command.

      **Fixed.** The finding is exactly right that the safety argument ("nothing you
      want lives there any more") silently assumed a tree the reviewer created or was
      given, and that I had deleted the bound without replacing it. All three reviewer
      files now carry three preconditions before `--force`: the path is **the one the
      dispatch named** and not one inferred, the reviewer is **not standing in it**
      (`git rev-parse --show-toplevel`), and its **findings commit is already
      cherry-picked** onto `piece/<name>` — that being the one thing in the tree it
      cannot recreate. If any fails, stop and report rather than force. Paired with
      settling worktree ownership (correctness box 5), which is what made the bad path
      reachable in the first place.

- [x] **`dev-writer`** — `.claude/agents/README.md:169-175` documents that the
      branch-rename path "silently drops anything the deleted ref held", and then
      leaves the reader with no stated prohibition
      The paragraph is an argument for getting the branch name right first time, and
      it is a good one. But it reads as a description of a destructive operation's
      failure mode without ever saying "do not do this" — and the preceding sentence
      ("It cannot be corrected later, and every workaround loses something") is a
      softer claim than the body supports.
      **Scenario:** an agent that has already created the wrong branch name reads
      this paragraph as a how-to, deletes the colliding ref as step one, and loses
      whatever that ref held — the outcome the paragraph describes. Nothing in the
      section forbids attempting it; it only explains why each route is bad.
      **Severity:** low. Worth one imperative sentence ("so do not attempt to rename
      or re-point a PR's head — open a new PR on the correct branch and close the
      old one").

      **Fixed**, taking the suggested sentence almost verbatim: do not rename or
      re-point a branch with an open PR; open a new PR on the correct name and close
      the old one, saying where the work went. With the trade named, since that is what
      makes it an instruction rather than a preference — it costs a PR number, where
      every other route risks commits. The same paragraph was separately reworked for
      the design review's point that those API claims were inherited from the sibling
      repo rather than measured here, and they are now marked as such.
