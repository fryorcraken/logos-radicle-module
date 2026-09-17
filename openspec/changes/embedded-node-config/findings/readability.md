# Readability review — embedded-node-config

Dimension covered: **readability only** (not correctness, security or architecture).

## Findings

- [x] **`dev-writer`** — `radicle/rust-ffi/src/nodeconfig.rs:352-354` and `design.md:90-93` — a doc comment and the design doc both name a test that does not exist under that name
      **Scenario:** `parse_external_addresses`'s doc comment says "Removing the `@` rejection below leaves `an_external_address_carrying_a_node_id_is_refused` as the only failing test." No test with that name exists anywhere in the crate. The real test (in the same file's `#[cfg(test)] mod tests`) is named `an_external_address_with_a_node_id_is_refused_although_the_crate_accepts_it`. `design.md`'s own Decisions section (line 90) makes the identical claim under the same wrong name. A reader who greps for the name the comment gives, to check the claim or to find the control assertion, finds nothing — the exact failure mode CLAUDE.md's "a comment restating the code is noise" section warns needs checking, except here the comment names something that isn't there at all.
      **Measured:** `grep -rn "an_external_address_carrying_a_node_id_is_refused"` across the whole `radicle/` tree returns exactly one hit — the doc comment itself, at `nodeconfig.rs:353`. The design.md occurrence is a second, independent instance of the same wrong name.

      **Fixed** for the doc comment. The comment now names both real tests —
      `an_external_address_with_a_node_id_is_refused_although_the_crate_accepts_it`
      (this file's `mod tests`) and
      `each_address_spelling_is_accepted_in_its_own_field_and_refused_in_the_other`
      (`tests/node_config.rs`) — matching what the correctness reviewer measured
      the mutation to redden, and both names were re-grepped as written rather
      than copied from the finding.

      **One correction to the finding, offered rather than argued:** `design.md`
      does *not* carry the wrong name. Line 90 reads
      `an_external_address_with_a_node_id_is_refused_although_the_crate_accepts_it`,
      which is correct, and a grep for the wrong name across `openspec/` returns
      only the finding files themselves. The doc comment was the single
      occurrence, so "a second, independent instance" was one instance. Worth
      knowing since it changes the count, not the fix.

- [x] **`dev-writer`** — `openspec/changes/embedded-node-config/design.md:44-45` and `tasks.md:76` — a fabricated test count, in two places
      **Scenario:** `design.md` claims that mutating `write_document` to use `Config::write` "leaves that test as the only failing one in the file (13 pass, 1 fails...)" — i.e. 14 tests total in `tests/node_config.rs`. `tasks.md` independently claims "`radicle/rust-ffi/tests/node_config.rs` — 14 tests, including the unknown-key preservation test." The file actually contains 16 `#[test]` functions. This is exactly the pattern CLAUDE.md's readability guidance calls out by name — "a quantity reads as though someone measured it" — and a sibling reviewer on the parallel piece already found the same class of error (`tasks.md` claiming "34 assertions" for a real count of 32). Whether the mutation claim itself (13 pass / 1 fails under the `Config::write` swap) is still accurate is a correctness question for another reviewer; the count of tests "in the file" is a readability fact anyone can check and is wrong in both places it is stated.
      **Measured:** `grep -c "#\[test\]" radicle/rust-ffi/tests/node_config.rs` → `16`, not 14.

      **Fixed**, and re-measured rather than adjusted by your delta. Your `16`
      still holds for `node_config.rs` — but the tests this pass added went into
      `nodeconfig.rs`'s unit `mod tests` and `node_lifecycle.rs`, so a count
      written into either document would already describe a different file
      layout than the one a reader checks.

      Neither place now carries a number:

      - `tasks.md` names the command instead — "`grep -c "#\[test\]"` for the
        count; do not write one down" — per CLAUDE.md's "do not write down
        anything a command can answer", of which "how many tests pass" is a
        listed row. Substituting `16` would have been stale within the hour.
      - `design.md` keeps the mutation *result*, which is what the entry exists
        for, and drops the arithmetic: "leaves that test as the **only** failing
        one in the file ... and every other test in the file stays green". The
        discriminating fact is "exactly one, and it is this one"; the raw count
        added nothing and rotted on every test added.

      The mutation claim itself was re-run rather than trusted:
      `write_document` round-tripped through `radicle::profile::Config`, and
      `a_key_this_build_does_not_know_survives_a_write` is the sole failure
      (`left: Null, right: String("keep me")`), with
      `an_unrelated_known_field_survives_a_write` green — the substance held
      exactly. The pass/fail split measured **15 pass / 1 fail**, not the 13/1
      written, which is where your `14` inference came from.

- [x] **`dev-writer`** — `openspec/changes/embedded-node-config/tasks.md:78-79` — a second, independent test-count mismatch for the seeding suite
      **Scenario:** `tasks.md` claims "`radicle/rust-ffi/tests/node_seeding.rs` — 12 tests against a real `policies.db`." The file has 13.
      **Measured:** `grep -c "#\[test\]" radicle/rust-ffi/tests/node_seeding.rs` → `13`.

      **Fixed**, the same way and for the same reason. Re-measured
      independently: `13`, confirming your count. The line now describes what the
      suite covers ("against a real `policies.db`, including both directions of
      the policy/storage disagreement") and leaves the number to the command.

      Both of these, and the phantom test name above, are the same defect — a
      quantity or an identifier written as though measured when it was recalled.
      Everything asserted in this pass's answers was run first: the test counts,
      the two mutation results, and both new test names were grepped as written.

## What was clean

- `radicle/rust-ffi/src/nodeconfig.rs` and `seeding.rs`: both module-level doc comments and every function doc explain *why*, in the repo's own style — the raw-JSON design, the `Address::from_str` measurement, the `seed`/`unseed` change-count distinction. This is the strongest part of the diff and matches `guarded()`'s standard.
- `radicle-ui/src/radicle_ui.rep`: the five new slots' comments explain the boundary shape (no home parameter and why, why config/seeding are two stores with different "when does this apply" answers, why `setNodeConfig`/`seedRepo` are documented the way they are) rather than restating the signature. This meets the bar the brief asked to check.
- `docs/PLAN.md`: the claimed edits (dropping "persistent peers," dropping "`node/config.rs`'s real fields," migrating the `listen: []` and seeding-store corrections into `design.md`) are all present and read coherently — no half-corrected sentence and no claim left duplicated between the two files. (The pre-existing dangling sentence at PLAN.md:184-193 about `radSocket`/profile-name plumbing was not touched by this piece's commits — confirmed via `git show 82e310c -- docs/PLAN.md` — and is out of scope here.)
- The three `NO SPEC:` markers (`seedRepo`'s success shape in `tests/node_seeding.rs:143`, a `config.json` with no `node` section in `tests/node_config.rs:326`, a wrong-type field on read in `tests/node_config.rs:346`) are all present, accurately describe what the test below them checks, and match `design.md`'s "Unspecified behaviour chosen here" section.
- `tasks.md`'s "five gating tests" claim for `test_radicle_impl.cpp` is accurate (verified by name: `the_node_configuration_is_readable_in_local_mode_but_not_writable`, `seeding_is_listable_in_local_mode_but_not_changeable`, `explore_mode_refuses_every_node_configuration_and_seeding_call`, `embedded_mode_reaches_the_backend_rather_than_being_refused_by_the_gate`, `a_node_configuration_key_is_not_a_module_setting`), as is the "three added" claim for `node_lifecycle.rs` and the five-entry-point claim for `panic_guard.rs`.
- `radicle/src/node_config.h`/`.cpp`: the new `NodeConfig` class's doc comment gives a real rationale for rejecting each of the three existing candidate homes (`LocalReader`, `LocalWriter`, `EmbeddedNode`), matching `design.md`'s reasoning without just restating the code.
- `rebuildFromSettings()` extraction (`radicle_impl.cpp:226-236`): genuinely new function, not a reshaping of pre-existing duplicated logic within this diff — confirmed against `a1a665f~1`, where the rebuild was spelled out inline at three sites (`setDependenciesForTest`, and two sites inside/near `setSetting`) and none was named `rebuildFromSettings`. This piece extracts two of those three into the new function and leaves `setDependenciesForTest`'s copy inline with a comment explaining why it must stay separate — a correct one-job split, not a fourth hand-copied guard.

Not flagged as a defect, noted for the record: the `rebuildFromSettings()` extraction and the five-method feature (new `NodeConfig` class, mode gating, `.rep` slots) landed in one commit (`986216e`) rather than a refactor commit followed by a feature commit, which is what CLAUDE.md's "make the change easy, then make the easy change" asks for. The extraction itself is small and mechanical and I did not find it made the diff harder to read, so I left this out of the checkbox list rather than opening a box nobody needs to act on — but an architecture or process-minded reviewer may weigh it differently.
