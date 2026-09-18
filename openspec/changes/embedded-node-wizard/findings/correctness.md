# Correctness review — piece 3 (identity `encrypted`, setup collapse to four steps, qmllint gate repair)

Scope: everything since `b802335` (state panel / wizard host findings already
closed), through `b036ad8`. Reviewed `SetupFlow.qml`, `SetupWizard.qml`,
`EmbeddedState.qml`, `RepoList.qml`, the `Main.qml` host wiring, the Rust
`profileinit::key_encrypted` probe and its C++/FFI wiring, and
`lint-qml.sh`. Cross-checked against `embedded-setup`, `embedded-state`,
`embedded-header` and `embedded-identity` specs.

Verification method: ran the full Rust FFI suite (`cargo test`, all green,
including the new `key_encrypted` tests) and every relevant QML component
test file (`tst_embedded_state.qml`, `tst_embedded_panel.qml`,
`tst_setup_wizard.qml`, `tst_setup_wizard_view.qml`, `tst_setup_host.qml`,
`tst_source.qml` — all green), then made targeted mutations to check that
claimed test coverage actually reddens, restoring each afterward and
confirming `git status` clean.

## One real defect found

- [ ] **`dev-writer`** — `radicle-ui/src/qml/SetupFlow.qml:701-702`, function
      `submitIdentity` — the `createIdentity(...)` reply handler's staleness
      guard (`if (!isCurrent(issuedAt)) return;`) is present and correct, but
      **no test in `tst_setup_wizard.qml` or `tst_setup_wizard_view.qml`
      exercises it** for this specific call. Deleting that one guard line
      leaves the entire 50-test `tst_setup_wizard.qml` suite green.
      **Scenario:** user is on the identity step with no identity yet,
      submits creation against a slow backend, then presses `back()` before
      the reply lands (this bumps `epoch` per the file's own staleness
      contract). The stale `createEmbeddedIdentity` reply then arrives
      reporting success. Without the guard, `flow.identityExists`,
      `flow.identityNodeId`, `flow.identityCreatedHere` and `flow.embeddedHome`
      are all overwritten from a call issued under a step the user has left —
      exactly the "reply issued before the user moved must not repopulate the
      step now in force" property `embedded-setup/spec.md`'s "The flow reads
      the backend and keeps no second opinion" requirement states, and which
      the file's own header comment calls out as the reason every call
      carries an epoch. (The guarded branch also reads `flow.step ===
      "identity"` before auto-advancing, so in some interleavings this could
      additionally fire an unwanted `advance()` on whatever step the user has
      since reached — e.g. if they returned to "identity" via `back()`/`
      advance()` for an unrelated reason before the stale reply landed.)
      **Measured:** removed the `if (!isCurrent(issuedAt)) return;` line at
      `SetupFlow.qml:702` — `qmltestrunner -input tst_setup_wizard.qml`
      reported 50 passed, 0 failed. Restored the line and re-ran to confirm
      the green baseline is unaffected (50/50 again). This is the same class
      of gap the file's own header names as this repo's standing failure mode
      (`wantRid`/`syncEpoch` guards each hand-written slightly differently and
      each missing a test for at least one dropped capture) — here the guard
      itself was *not* dropped, but no test exists that would notice if it
      were. A test asserting "a stale identity-creation reply does not
      overwrite the step the user has since left" (parallel to the existing
      `test_a_late_reply_does_not_repopulate_a_step_the_user_left`, which
      covers the *preflight* calls only) would close this.

## Claims verified

- **Autostart (`wantsAutoStart: current === "stopped" && !encrypted`,
  `EmbeddedState.qml:256`).** Deleting the `current === "stopped" &&` term
  (leaving only `!encrypted`) reddens `test_no_autostart_outside_the_stopped_state`
  with all seven of its rows wrong, exactly as the file's own comment claims.
  Restored and reconfirmed green.
- **`test_a_list_built_already_stopped_starts_its_node`
  (`tst_embedded_panel.qml:738`)** genuinely builds a *fresh* `RepoList`
  already in the stopped/unencrypted state rather than mutating an existing
  harness — closing the gap named in the review brief. Confirmed by deleting
  `RepoList.qml`'s `Component.onCompleted: autoStartIfWanted()`: this
  specific test failed, plus three others that depend on the same
  construction-time path (`test_an_unencrypted_stopped_node_is_started_without_being_asked`,
  `test_the_automatic_start_is_issued_once_not_on_every_reading`,
  `test_a_refused_automatic_start_is_reported_and_not_retried`). Restored and
  reconfirmed green (30/30 in that file, plus the 30/30 in
  `tst_embedded_state.qml`).
- **`foundForeignNode: serving && !startSucceeded`
  (`EmbeddedState.qml:293`).** Deleting the `!startSucceeded` term reddens
  exactly the three tests the code comment names:
  `test_a_node_this_surface_started_is_not_reported_as_contention` and
  `test_a_node_the_surface_did_not_start_is_still_reported` in
  `tst_embedded_state.qml`, and
  `test_a_node_this_surface_started_is_not_rendered_as_contention` in
  `tst_embedded_panel.qml` — the last failing with the message text being
  exactly the contention sentence rendered over the surface's own success
  sentence, i.e. the reproduction of the user's photographed screenshot.
  Restored and reconfirmed green (30/30 and 30/30 respectively).
- **The Rust `encrypted` probe (`profileinit::key_encrypted`,
  `radicle/rust-ffi/src/profileinit.rs:216`).** Read the implementation and
  its five new tests in `radicle/rust-ffi/tests/profile_init.rs`. It correctly
  distinguishes "unencrypted" from "unreadable": on `Keystore::new(...).is_encrypted()`
  returning `Err`, it reports `{"encrypted": false, "problem": "<non-empty>"}`,
  never `{"encrypted": false, "problem": ""}` — verified structurally (the
  `Err` arm always constructs a non-empty `problem` string) and by the test
  suite, including a case where the key file is replaced by a directory
  (`an_unreadable_key_reports_a_problem_rather_than_unencrypted`) and a case
  with no key at all (`a_home_with_no_key_reports_a_problem_rather_than_unencrypted`).
  The C++ wiring in `radicle_impl.cpp`'s `getEmbeddedIdentity()` correctly
  only calls this probe when `exists` is true (avoiding a spurious "no key"
  problem on an ordinary empty home), and on a JSON-parse failure of the
  probe's own reply falls back to a synthesized non-empty `problem` rather
  than silently defaulting `encrypted` to `false` with an empty `problem`.
  All Rust FFI tests pass (`cargo test --manifest-path
  radicle/rust-ffi/Cargo.toml`): 10+9+18+6+8+15+13+13+7+19 = 118 tests, 0
  failed. C++ unit test additions in `test_radicle_impl.cpp` round-trip both
  directions (plain and sealed) through a **fresh** `RadicleImpl` instance
  that never saw the creating call's reply, which is the right shape to prove
  "observed from disk" rather than "echoed from the creating call."
- **The orphaned `flow.startNode` injection (defect fix, `6407072`).**
  Confirmed genuinely removed from `Main.qml` — grepped for all
  `startNode`/`confirmStep`/`allowCommand`/`submitStart`/`refreshNodeStatus`
  references across `SetupFlow.qml`, `SetupWizard.qml` and `Main.qml`; the
  only remaining hits are comments/tests documenting the absence. Re-added
  the exact orphaned line (`flow.startNode: function (passphrase, cb) {
  root.callSettings("startNode", [passphrase], cb); }`) to `Main.qml` and ran
  `lint-qml.sh`: `qmllint` reports `Could not find property "startNode".` at
  the exact injection line, the script's grep for that literal string fires,
  and the script exits non-zero (verified both through the wrapper script and
  directly via `qmllint -I <qml_dir> Main.qml`). The gate does catch a
  reintroduction of this exact defect. Restored and reconfirmed `git status`
  clean.
- **`landOnFirstUnfinishedStep` deliberately not bumping `epoch`
  (`SetupFlow.qml:559-562`).** Added `epoch = epoch + 1;` to the function —
  this reddens `test_the_landing_does_not_discard_a_reply_still_in_flight`,
  confirming the comment's claim that bumping the epoch here would discard a
  still-in-flight preflight reply (e.g. the seed list) arriving after the
  resume landing. Restored and reconfirmed green.
- **`SourceState.modeHasIdentity: current === "local"`
  (`SourceState.qml`)**, and its use in `Main.qml` gating the header's
  `NodeIdentity` visibility. Read the diff; this is a single rule derived
  from `current` (which already folds `local`/`embedded` → `"local"`) rather
  than a per-mode list, so a future mode with an identity inherits correct
  behaviour without an edit here. `tst_source.qml`'s
  `ModeDetailSlot`/`NodeIdentity` suites (30 tests) all pass, including
  `test_embedded_shows_its_identity_as_local_does` and
  `test_having_an_identity_is_derived_rather_than_listed`.
- **`actionKind !== ""` redundant term in `actionEnabled`
  (`EmbeddedState.qml:433`).** This was already corrected in this round per
  the code comment at line 424-432, which explicitly documents that an
  earlier version of the comment made a false claim about a test reddening
  and that mutation testing showed no such test existed. Re-verified the
  comment's own logical claim holds: `actionHosted`'s `switch` has a
  `default: return false` that already covers `actionKind === ""`, so the
  extra term is provably redundant by inspection, matching what the comment
  now says. This is a case of the review process correcting itself and
  recording it — nothing further to flag.
- **`takeEmbeddedAction`/`routesEmbeddedAction` table
  (`Main.qml`)**: the "start" branch in `takeEmbeddedAction` is gated by
  `routesEmbeddedAction(kind)` before the `if/else if` runs, so the
  enablement table (`routesEmbeddedAction`) and the act performed cannot
  disagree by construction — matches the comment's claim about the earlier
  defect (`embeddedStartHosted` gating the control while a bare `if` gated
  the act). `tst_setup_host.qml`'s
  `test_every_hosted_kind_is_one_the_host_routes` passes.

## Areas covered and clean

- `radicle/rust-ffi/src/profileinit.rs`, `lib.rs`, and the C++
  `radicle_impl.cpp`/`.h`, `local_reader.cpp`/`.h`, `radicle_ffi.h` wiring for
  the new `encrypted`/`problem` fields on `getEmbeddedIdentity()`.
- `SetupFlow.qml`'s four-step collapse: step sequencing (`advance`/`back`),
  the four preflight findings and their blocking rules, the identity step's
  single forward control and three-state derivation, the embedded step's
  mode-confirmation gating, and the resume/landing logic
  (`resumeIndex`/`landOnFirstUnfinishedStep`) — all match
  `embedded-setup/spec.md` and are covered by passing, mutation-verified
  tests, apart from the one gap above.
- `EmbeddedState.qml`'s seven-state derivation, the `startPending`/
  `startSucceeded`/`foundForeignNode` distinctions, and
  `actionEnabled`/`actionUnavailableNote` — all correct and covered.
- `RepoList.qml`'s `hasNodeToAsk` guard, the blank-pane observable, and the
  passphrase field lifetime (cleared on submit, not on reply) — read
  correctly against the spec and passing tests.
- `lint-qml.sh` — verified it structurally does fire on the exact defect
  class it was written for (a `Could not find property` warning on an
  assignment to a deleted property), independent of the readability
  reviewer's correction about the stale "34 of that form, 1 of the form
  below" count in its comment (that count is a readability/prose-accuracy
  concern about the script's own comment, not about whether the gate
  functions — I did not rely on it for anything and it does not affect this
  finding).

## Not investigated further

Did not re-review the state-panel/wizard-host pieces already closed at
`b802335`, per scope. Did not attempt a `cargo mutants` run over
`radicle/rust-ffi` beyond the targeted manual mutations above (time-boxed;
manual mutation on the specific new surface — `key_encrypted` and its
call sites — was sufficient to verify the claims in scope).
