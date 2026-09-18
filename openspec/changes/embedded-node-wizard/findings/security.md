# Security review — `embedded-node-wizard`, round at `b036ad8`

Scope: `git diff b802335..b036ad8` — the identity step collapsing to one
control, the wizard collapsing to setup-only with autostart and the DID
moved to the header, the compile-breaking fix, and the `lint-qml.sh` CI
repair. Dimension: security only. This overwrites the previous round's
closed findings.

## Clean

- **`Keystore::is_encrypted()`** (`radicle-crypto-0.19.0/src/ssh/keystore.rs:229`)
  is exactly what `profileinit.rs`'s doc comment and the C++ contract claim:
  `ssh_key::PrivateKey::read_openssh_file` followed by `secret.is_encrypted()`
  — no passphrase parameter, nothing decrypted, nothing written back. Verified
  by reading the vendored crate source directly, not just the comment citing
  it.
- **The unreadable-key case is handled correctly.** `key_encrypted()`'s `Err`
  branch returns `{"encrypted":false,"problem":"<non-empty>"}`, and
  `radicle_impl.cpp`'s `getEmbeddedIdentity()` propagates that pair rather
  than collapsing it — an unreadable key cannot be mistaken for an
  unencrypted one by a caller that reads only the boolean. `Main.qml` also
  defaults `embeddedEncrypted` to `true` (the safe direction: `reply.encrypted
  !== false` rather than `=== true`) when a reply is old-shaped or absent, so
  a build skew or dropped field asks for an unneeded passphrase rather than
  autostarting a sealed key.
- **The wizard's one-showing rule for its own passphrase field still holds**
  now that it no longer starts anything: `SetupWizard.qml`'s `show()` clears
  `passphraseField.text` (the outer clearing, for an abandoned showing), and
  a successful `createEmbeddedIdentity` clears it again (the inner one, for
  the ordinary path) — both present and unchanged in shape from the
  documented history of this defect.
- **The `.rep` boundary is untouched.** `radicle_ui.rep` has no diff in this
  round; no slot gained a home/socket argument, and the header's new DID
  rendering reads `root.caps.nodeId`, not a value a view supplies.
- **`is_encrypted`'s error path** carries only a path under the module's own
  embedded home and the underlying `ssh_key`/io error text — consistent with
  every other error path already in this module's contract, not a new
  leakage class.
- **`canWriteLocal` vs `localAvailable`**: the new start/passphrase affordance
  is correctly not modeled as a `canWriteLocal` gate — it starts the node
  rather than writing content through it, which is a different question, and
  nothing here reintroduces the `localAvailable`-gated-compose-box mistake.

## Findings

- [x] **`dev-writer`** — `RepoList.qml:147` (`autoStartIfWanted`) — the automatic
      start bypasses the capability-hosting gate every other Embedded action
      goes through
      **Scenario:** `EmbeddedState.wantsAutoStart` (`current === "stopped" &&
      !encrypted`) is a pure UI-state predicate that says nothing about
      whether starting is *permitted* — that question is `startHosted` /
      `embeddedStartHosted`, and every other act on this panel (`setup`,
      manual passphrase submit via `actionEnabled` → `actionHosted` →
      `startHosted`, `restart`) is required to pass through it before a call
      goes out; `routesEmbeddedAction()` exists specifically so "is this kind
      hosted" and "does clicking it call anything" cannot disagree. The
      autostart path never asks: `autoStartIfWanted()` is `if
      (embedded.wantsAutoStart && app) app.startEmbeddedNode("")` — no
      `startHosted` term anywhere in it. Today `embeddedStartHosted` is a
      hardcoded `readonly property bool … : true` in `Main.qml`, so the gap
      has no live effect yet — but that is exactly the situation the rest of
      this capability was built to make impossible by construction (per
      `embedded-state/spec.md`, "an act whose request reaches nobody must not
      be enabled" — and the inverse, an act reaching somebody who was told it
      wouldn't, is the same property from the other side). If
      `embeddedStartHosted` is later made conditional — the natural next step
      given this codebase's own rule to gate write affordances on
      `getCapabilities().canWriteLocal` rather than a static flag — the
      autostart path will silently keep starting the node regardless, because
      it was never wired to the gate at all.
      **Measured:** added `app.embeddedStartHosted = false;` immediately
      before `list.reload()` in
      `test_an_unencrypted_stopped_node_is_started_without_being_asked`
      (`tst_embedded_panel.qml`) and reran
      `/usr/lib64/qt6/bin/qmltestrunner -input
      radicle-ui/tests/tst_embedded_panel.qml -import radicle-ui/src/qml`: all
      31 tests including that one still pass — the autostart call
      (`app.startLog`) still fires with `embeddedStartHosted` declared false,
      proving no code path reads that flag before calling
      `startEmbeddedNode`. Mutation reverted; `git status` / `git diff
      --stat` on the test file show no changes afterward.

      **Fixed.** `startHosted` is now a term of
      `EmbeddedState.wantsAutoStart` (`EmbeddedState.qml`), so the automatic
      path inherits the same gate the rendered control goes through.

      Placed in the derivation rather than in `autoStartIfWanted()`
      deliberately: `wantsAutoStart` is the decision, and a caller-side check
      would be a second place encoding "may a start go out" — the
      fourth-copy-of-a-guard shape that produced this divergence in the first
      place. `RepoList.autoStartIfWanted()` is unchanged in behaviour and its
      doc comment now says why there is no hosting check there.

      Two tests, both of which fail without the term:
      `test_an_unhosted_start_is_not_issued_automatically`
      (`tst_embedded_state.qml`) pins the decision, and
      `test_an_unhosted_start_is_not_issued_by_the_module_either`
      (`tst_embedded_panel.qml`) pins that no CALL goes out — the latter is
      your mutation written down. Verified by removing the term: the panel test
      fails with `startLog` length 1 against an expected 0, which is exactly
      the measurement in this finding. Both tests move `embeddedStartHosted`
      as the only field, with the stopped/unencrypted status held in both legs,
      so a surface ignoring hosting answers the same in each.

      Two existing tests needed `startHosted` armed
      (`test_an_unencrypted_stopped_node_wants_a_start` and
      `test_no_autostart_outside_the_stopped_state`), since the shared fixture
      resets it to false in `init()`; both now hold it true throughout so their
      own subject — the key, and the state — remains the only thing moving.

      **No behaviour change today**, since `embeddedStartHosted` is hardcoded
      `true` in `Main.qml`. It changes behaviour the moment piece 3 makes that
      flag conditional, which is what this finding was about.

- [x] **`dev-writer`** — `RepoList.qml:602-641` (the `passphraseField`
      `TextField`) — a typed-but-never-submitted passphrase survives the
      field going invisible and becoming visible again by any route other
      than submit
      **Scenario:** user opens Embedded mode with an encrypted key
      (`stopped`, `wantsPassphrase` true), types a passphrase, then does
      *not* press the button — instead the field's visibility condition
      changes some other way (the node becomes `serving`/`running` through an
      external event, e.g. someone starts it from a command line while the
      panel is open, or an intervening screen the user visits temporarily
      changes `current`). The field disappears with the typed text still in
      `passphraseField.text`. When the state returns to `stopped`/encrypted
      (node stops again, or the same identity is revisited), `wantsPassphrase`
      goes true again and the field reappears pre-filled with the stale
      value — resident, and per this diff's own stated threat model ("this
      module's dev Basecamp ships a QML inspector that reads live object
      properties, so 'resident' means 'readable'"), inspector-readable for
      that whole span. The only clearing point in this file is inside
      `submitEmbeddedPassphrase()`, which runs solely on submit; there is no
      analogue of `SetupWizard.qml`'s `show()` here, because this `TextField`
      is a permanent object in `RepoList`'s tree (not recreated per opening
      the way the wizard is), so nothing hooks a "showing began/ended"
      transition to clear it. This is the same defect class the piece's
      history names as recurring — a passphrase outliving the showing it was
      typed for — reappearing on the one surface without a lifecycle event to
      hang the fix on.
      **Measured:** wrote a scratch test in `tst_embedded_panel.qml`:
      set `passphrase().text = "leaked-secret"` while visible, flipped
      `app.embeddedServing`/`embeddedRunning` to `true` and reloaded (field
      goes invisible, `app.startLog` stays empty — confirming no submit
      occurred), flipped both back to `false` and reloaded again (field
      visible again). `compare(passphrase().text, "leaked-secret", …)`
      passed — the value survived the full cycle untouched. Ran with
      `/usr/lib64/qt6/bin/qmltestrunner -input
      radicle-ui/tests/tst_embedded_panel.qml -import radicle-ui/src/qml`
      (32/32 passed, including the scratch test). Test added and then removed
      in the same edit; `git status` / `git diff --stat` on the test file
      show no changes afterward.

      **Fixed.** `passphraseField` gained
      `onVisibleChanged: if (!visible) text = "";`. You asked for a "showing
      began" event or for one to be made — `visible` is already that event: it
      is bound to `page.embedded.wantsPassphrase`, so it moves exactly when the
      surface starts and stops asking, and no new lifecycle plumbing is needed
      for a permanent object.

      Cleared on the way OUT rather than on the way in. Both close the cycle
      you measured, but hiding is the earlier moment: clearing on re-show would
      leave the secret resident for the whole span the field is hidden, and per
      this diff's own threat model resident means inspector-readable. Clearing
      at the hide makes the value's lifetime the showing it was typed for.

      Nothing legitimate is lost. `submitEmbeddedPassphrase()` already empties
      the field as the call is issued, so the `startFailed` showing — the one
      that must survive, so a refused passphrase can be corrected — arrives at
      an empty field either way, and `wantsPassphrase` holds `visible` true
      across `stopped`→`startFailed` regardless.
      `test_a_refused_passphrase_can_be_corrected` still passes unchanged,
      which is what says the correction path is intact.

      `test_an_abandoned_passphrase_does_not_survive_the_showing`
      (`tst_embedded_panel.qml`) is your scenario as a test: type
      `"leaked-secret"`, drive the node to serving so the field hides by a
      route that is not a submit, assert `startLog` is empty at that point (so
      the test is about the showing and not about a quiet submission), then
      stop the node and assert the field returns empty. Verified by removing
      the handler: the test fails reporting `leaked-secret` where `""` was
      expected — the same residue you measured.

Both findings are about the same root cause from two angles: the passphrase
and the act it unlocks are handled correctly along the one path this round
built and tested (manual submit → `actionEnabled` → `startHosted` →
`startEmbeddedNode`, clear-on-issue, survive-on-refusal), but the automatic
path added alongside it (`autoStartIfWanted`) was wired directly to
`app.startEmbeddedNode` rather than through the same gate and the same
field-lifetime discipline, and nothing in the test suite exercises the
combination that would show it.
