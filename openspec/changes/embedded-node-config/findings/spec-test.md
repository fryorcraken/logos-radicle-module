# spec-test review — embedded-node-config

Scope: `specs/node-config/spec.md`, `specs/node-seeding/spec.md`,
`specs/module-settings/spec.md` against `radicle/rust-ffi/tests/node_config.rs`,
`node_seeding.rs`, `node_lifecycle.rs`, `panic_guard.rs`, `git_preflight.rs` and
`radicle/tests/test_radicle_impl.cpp`. Read only, except three temporary
mutations to implementation files, each made, tested and reverted (`git status`
confirmed clean after every one). The two panel-only requirements and the
`module-settings` `gitPath` delta's already-green negative tests are excluded
per the dispatch brief — both are confirmed correctly scoped, not reported below.

## Mutations run

1. **`nodeconfig.rs::write_document`** — round-tripped the document through
   `radicle::profile::Config` (deserialize then re-serialize) instead of writing
   the edited raw `Value`, simulating the `Config::write` data loss the module
   comment warns against.
   **Result:** exactly one test reddened, `a_key_this_build_does_not_know_survives_a_write`.
   `an_unrelated_known_field_survives_a_write` stayed green, because `workers`
   is a real field of the crate's `Config` type and survives a round-trip.
   Confirms the dev-writer's claim precisely.
2. **`node.rs::start_inner`** — reinstated `let listen = vec![];` in place of
   `config.listen.clone()` (the original override the change removes).
   **Result:** `a_configured_listen_address_is_what_the_node_binds` and
   `a_listen_port_that_cannot_be_bound_fails_the_start_rather_than_falling_back`
   both reddened, as claimed. All other `node_lifecycle` tests stayed green.
3. **`nodeconfig.rs::set_inner`** — forced the write's own reply to report
   `restartRequired: false` unconditionally, simulating an implementation that
   reads the flag before the write rather than after.
   **Result:** `a_configuration_change_while_a_node_runs_asks_for_a_restart_and_a_restart_clears_it`
   reddened on the assertion "the write's own reply must ask for the restart it
   just made necessary". Confirms this test does discriminate on reply
   ordering, not just on a later `getNodeConfig` call.

All three mutations were reverted with `Edit`, and `git -C <worktree> status`
showed a clean tree after each and after the run overall.

## Findings

- [ ] **`tester`** — `node_config.rs` / `nodeconfig.rs::parse_alias` — the empty-alias scenario has no test anywhere
      **Scenario:** spec `node-config/spec.md` "Requirement: The alias is validated against the crate's own rule" states "An alias MUST be non-empty" and scenario "An empty alias is refused" (`setNodeConfig` sets `alias` to `""` → error). No test in `node_config.rs` (integration) or the `#[cfg(test)] mod tests` block in `nodeconfig.rs` (unit) calls `parse_alias`/`set` with an empty string. The only alias tests cover whitespace, the 32/33-byte boundary and the multi-byte case. This behaviour rests entirely on `radicle::node::Alias::from_str("")` happening to error, unpinned by this change.
      **Measured:** confirmed by exhaustive grep of both files for `empty` and `""` near `alias` — zero hits. Not run as a mutation since there is nothing to mutate against; the gap is the absence of any assertion.

- [ ] **`tester`** — `test_radicle_impl.cpp:1228` (`capabilities_report_the_git_preflight`) — the modified requirement's negative-configured-path scenario and `gitProblem` are untested at the `getCapabilities()` layer
      **Scenario:** `module-settings/spec.md`'s "Requirement: The reported git path distinguishes configured from detected" adds scenario "A refused configured path is still reported as configured" (`gitConfigured` true, `gitFound` false, `gitProblem` non-empty for a bad configured `gitPath`), and states "`gitProblem` MUST be empty exactly when `gitFound` is true" for the positive scenario too. The only test touching `getCapabilities()`'s git fields, `capabilities_report_the_git_preflight`, is a pre-existing test unchanged by this piece: it only asserts the four keys are *present* and that `gitConfigured` is false when no path is configured. It never sets a bad `gitPath` and checks `gitConfigured==true`/`gitFound==false`/`gitProblem` non-empty, and never asserts `gitProblem` is empty in the positive case. `git_preflight.rs`'s `configured` assertions are on `env::git_probe`'s own JSON shape, a different layer/shape from `getCapabilities()`, so they do not close this gap.
      **Measured:** grep for `gitProblem` across `radicle/tests` and `radicle/rust-ffi/tests` returns exactly two hits, both `LOGOS_ASSERT_TRUE(caps.contains("gitProblem"))`-style presence checks in the same one test — no test asserts its value in any state. Not mutated (this is an absence, not a behaviour to break), but the gap is real: a `getCapabilities()` implementation that returned `gitConfigured=false` unconditionally for a refused configured path would pass every test in the suite.

- [ ] **`spec-writer`** — `test_radicle_impl.cpp:1537` (`the_node_configuration_is_readable_in_local_mode_but_not_writable`) and its seeding twin at 1573 — the read-half asserts only the absence of a phrase, not that the read reached real content
      **Scenario:** `node-config/spec.md`'s "Local is readable but not writable" scenario requires `getNodeConfig` to "report that home's configuration rather than an error" in `local` mode. The C++ test's scratch home has no `config.json` (`makeStorage()` only creates `storage/`), so the backend legitimately returns its own error, and the test's own comment says so. Its assertion is `error.find("you run yourself") == npos` — true whether the mode gate correctly passed the call to a backend that legitimately has nothing to read, **or** whether the gate is broken and returns some other generic refusal that also happens not to contain that phrase. No test anywhere (C++ or Rust) exercises `RadicleImpl::getNodeConfig()` in `local` mode against a home that actually holds a `config.json`, so the positive half of the read/write asymmetry — the one thing this file exists to test, per its own header comment at line 1531 ("the READ/WRITE asymmetry in `local`") — is unproven for the case that matters (a real config present). The seeding twin (`seeding_is_listable_in_local_mode_but_not_changeable`) has the identical shape for `listSeeded`.
      **Measured:** read-only (dev-writer independently flagged this as its lowest-confidence area; reading confirms the shape — no positive assertion exists to contradict). This is reported to `spec-writer` rather than `tester` because the fix most likely requires deciding what fixture setup (a config.json in place before the mode is set to `local`) the scenario should specify, which the current spec text does not make concrete enough to drive a stronger test from.

## Areas confirmed clean

- **`node-config` core validation, write-preservation and address-spelling
  requirements** are pinned by `node_config.rs`'s 16 integration tests plus the
  unit tests in `nodeconfig.rs`'s own `#[cfg(test)]` block, and the two
  highest-risk properties — unknown-key preservation and the `Config::write`
  discrimination — are verified by mutation (above) exactly as the tasks.md
  comment claims.
- **`node.rs`'s `listen`-honouring change** is pinned by
  `a_configured_listen_address_is_what_the_node_binds` and the port-collision
  test, both confirmed by mutation to redden when the old override is
  reinstated.
- **`restartRequired`'s three-state sequence and the write-reply ordering**
  are pinned by `a_configuration_change_while_a_node_runs_asks_for_a_restart_and_a_restart_clears_it`,
  confirmed by mutation to discriminate on the write's own reply rather than
  only a subsequent read.
- **`node-seeding`'s policy/storage distinction, scope handling, idempotent
  unseed and cross-home isolation** all have input-dependent fixtures (two
  different RIDs, two different homes, a real `init_repo` alongside a policy)
  rather than constant-answer fakes — no non-discriminating shape found here.
- **The `module-settings` `gitPath` delta's four negative cases** are green in
  `git_preflight.rs` exactly as tasks.md claims, and the spec text now matches
  what those tests assert (path-not-found naming the path, not-git rejected by
  version check, non-zero exit refused, relative path refused with no silent
  `PATH` fallback, all four required together per the "four cases required
  together" paragraph).
- **The FFI boundary (`panic_guard.rs`)** covers all five new `extern "C"`
  entry points (`get_config`, `set_config`, `list_seeded`, `seed`, `unseed`)
  against NULL, malformed home, malformed JSON and malformed scope/RID inputs,
  matching both specs' "Every failure crosses the boundary as JSON" requirements.
- **Mode gating** (`explore`/`local`/`embedded`) for both new capabilities is
  covered in `test_radicle_impl.cpp` by five tests, matching tasks.md's count,
  and the negative assertions (mode message must NOT be the other mode's
  phrase) are present in each — this is real discrimination, not vacuous.
- **The two panel/view requirements** in `node-config` and the
  allow-is-not-enough view requirement in `node-seeding` are correctly left
  untested by this change, as `proposal.md` states; no test in the suite
  references them, confirming they were not silently claimed as covered.
- **PLAN.md on `origin/main`** vs. this piece's copy: the `listen: []` and
  seeding sections are properly struck through with pointers to the new
  capabilities and this change's `design.md`, matching the spec's actual
  content — no staleness found.
- **`NO SPEC` markers**: three found (`node_config.rs:326`, `:346`;
  `node_seeding.rs:143`), each a genuine spec silence rather than a disguised
  defect, and each already flagged in the test's own comment for a spec-writer
  to evaluate. No unmarked ones found in the areas reviewed.
