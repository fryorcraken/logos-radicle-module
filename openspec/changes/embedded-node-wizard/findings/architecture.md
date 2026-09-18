# Architecture review — PR #46, round covering `b802335..b036ad8`

Scope: architecture only (per dispatch). Covers the responsibility move out of
the wizard (start → Embedded surface, DID → header), the `EmbeddedState.qml`
derivation, the hosted-ness flags, the foreign-node distinction, and
`lint-qml.sh`'s new convention.

## Findings

- [x] **`dev-writer`** — `radicle-ui/src/qml/SetupFlow.qml:12-24` — the file-header
      doc comment is stale relative to this round's own change: it says "Six
      steps in a fixed order" and credits "the confirm-step clamp" as something
      that "falls out of the representation," but `steps` (line 102) now has
      four entries and the Confirm step was deleted this round (see the comment
      at line 87-101, which correctly describes the four-step, no-confirm
      shape). No behaviour is wrong — `canAdvance`/`onLastStep` correctly derive
      from `steps.length` rather than the hardcoded count — but a reader who
      trusts the file header over the code below it gets the wrong step count
      and a pointer to a mechanism ("the confirm-step clamp") that no longer
      exists under that name anywhere in the file.
      **Scenario:** someone reading only the top-of-file comment (the usual
      place to start) concludes there are six steps and that a confirm step
      still exists, then goes hunting for it in vain, or "fixes" the header
      count without noticing steps 5 and 6 were deliberately removed for
      reasons documented lower in the same file.
      **Measured:** read `steps` at line 102 (`["preflight", "embedded",
      "identity", "network"]`, 4 entries) against the header's "Six steps" and
      "confirm-step clamp" claims (lines 14, 17, 22) — the two disagree within
      one file.

      **Fixed.** The header no longer states a count at all: "Six steps in a
      fixed order" became "The steps run in a fixed order", and it now points
      at `steps` below as the one place the count lives, with a line saying
      this header said "six" for a round after the deletion and that is what
      sent a reader hunting for a screen that no longer existed. Deleting the
      number rather than correcting it to "four" is the same discipline the
      readability findings asked for elsewhere in this round — a corrected
      number rots on the next step change; a pointer does not.

      The "confirm-step clamp" reference became "the clamp at either end",
      which is what `canGoBack` and `onLastStep` actually derive and does not
      name a mechanism that no longer exists. The illustrative "identity went
      straight to start" also became "identity went straight to network", since
      the start step is gone.

      Doc-only, so no test covers it; `check-qml-syntax.sh` and the full
      component suite are green, which is all a comment change can be asked to
      show.

- [x] **`dev-writer`** — `radicle-ui/src/qml/RepoList.qml` (whole-file scope) —
      `RepoList` now owns two jobs: listing/paging repositories (its original
      one) and the Embedded node's lifecycle surface — `EmbeddedState`
      instantiation, `autoStartIfWanted()`, the `Connections` that issues the
      autostart, `submitEmbeddedPassphrase()`, and the panel UI (passphrase
      field, action button, unavailability note). The authors are aware of
      this: `openspec/changes/embedded-node-wizard/user-flow.md` §9 asks
      "Whether the Embedded empty state belongs in `RepoList` at all... A
      shared `EmbeddedState.qml` may be right, but not speculatively," and
      flags the same question one level down for `RepoView`. That open
      question was never carried into `design.md`'s "Risks / Trade-offs" —
      which records `embeddedStartSucceeded`'s latch behaviour, the
      no-component-test gap for `Main.qml`, and the not-polled status read, but
      says nothing about the panel's placement. This is a judgement call, not
      a defect: the `embedded-state` spec itself is written host-agnostically
      (it never names `RepoList`), so nothing depends on this placement being
      permanent, and moving the panel later costs a QML relocation rather than
      a spec rewrite. Flagging it because a real, self-identified open
      question about where a responsibility lives should be in the durable
      design record rather than only in the pre-implementation scratch
      document that `user-flow.md` says it is (its own header: "Not yet a
      spec").
      **Scenario:** a future contributor reads `design.md`'s Risks section
      looking for known rough edges before extending `RepoList` or `RepoView`,
      finds nothing about the node-lifecycle-in-a-list-component question, and
      either duplicates the `EmbeddedState` panel into `RepoView` by copying
      `RepoList`'s shape (the "fourth copy of a guard" pattern this repo's
      CLAUDE.md warns about), or spends time rediscovering a question the
      wizard's own authors had already asked and answered "not yet."
      **Measured:** `grep -n "RepoView\|belongs in RepoList" design.md` returns
      nothing; the question exists only in `user-flow.md` §9.

      **Fixed as recorded, not refactored** — which is what you asked for.
      `design.md`'s Risks / Trade-offs gained an entry naming the two jobs
      `RepoList` carries, the `RepoView` question one level down, why it is
      accepted now (one host, and the `IssuesTab`/`PatchesTab` pair as this
      repo's standing argument against extracting for a consumer that does not
      exist), and what does not bind it (the `embedded-state` spec is
      host-agnostic and never names `RepoList`, so a move costs a QML
      relocation and no spec rewrite).

      It also names the trap you predicted — copying `RepoList`'s shape into
      `RepoView` — and anchors it to something concrete rather than leaving it
      abstract: this same round's security finding was exactly that pattern,
      the autostart path wired straight to `startEmbeddedNode` instead of
      through the gate the manual path used. The entry says a second host
      should inherit `EmbeddedState` rather than re-derive from it.

      `user-flow.md` §9's bullet is struck through and now points at
      `design.md` instead of restating the reasoning, so there is one copy and
      the two cannot drift — `user-flow.md` is the pre-implementation scratch
      document its own header says it is, and the durable record is
      `design.md`.

## What is clean

- **The wizard/surface boundary has no residue.** `SetupFlow.qml` holds no
  `startNode` function property at all — verified by reading the file, not
  just its comments — so "the setup MUST NOT issue startNode" is structural,
  not a convention someone could silently violate. The compile-breaking defect
  this round fixed (`SetupFlow.startNode` deleted, `Main.qml`'s injection site
  left behind) has no surviving sibling: I grepped every `startNode`/`SetupFlow`
  reference across `Main.qml`, `RepoList.qml` and `SetupFlow.qml` and each one
  is live and intentional.

- **`routesEmbeddedAction`/`takeEmbeddedAction` genuinely fixes the "half-true"
  gap** a previous review found. `embeddedStartHosted` now has a real branch in
  `takeEmbeddedAction` (`Main.qml:425-429`), and both the panel's enablement
  (`EmbeddedState.actionHosted`) and the host's routing
  (`routesEmbeddedAction`) read the same three flags, so they cannot disagree
  by construction. `restart` is correctly left unhosted in both places.

- **`EmbeddedState.qml`'s derivation is one coherent thing, not several
  concerns sharing a file.** Every property — the seven states, `wantsAutoStart`,
  `wantsPassphrase`, `foundForeignNode`, the three hosted-ness flags,
  `actionLabel`/`actionKind`/`actionHosted`/`actionEnabled`/
  `actionUnavailableNote` — is a pure function of the same eight backend-derived
  inputs plus the three hosted-ness flags. I mutation-tested the
  `foundForeignNode` guard (dropped `!startSucceeded`) and confirmed via a real
  `qmltestrunner` run that exactly the two named tests
  (`test_a_node_this_surface_started_is_not_reported_as_contention`,
  `test_a_node_the_surface_did_not_start_is_still_reported`) go red, matching
  the comment's claim exactly (28 passed / 2 failed of 30); the mutation was
  then reverted. This is centralization earned by the repeated
  three-copies-of-a-guard failure mode CLAUDE.md documents, not speculative
  abstraction.

- **The `getEmbeddedIdentity().encrypted` interface widening earns its place.**
  `radicle_impl.h`'s own comment (lines 315-333) and `profileinit.rs`'s
  `key_encrypted` explain concretely why `getCapabilities().canWriteLocal`
  cannot substitute: it is scoped to the mode in force (silent about the
  embedded home from any other mode) and conflates an encrypted key with a
  missing/unreadable one and an absent agent. This reasoning holds up against
  the code — `canWriteLocal`'s C++ side has no path back to "this key
  specifically is sealed." One field added, not several; interface stays
  narrow.

- **`Main.qml`'s no-component-test gap is already documented**, in
  `design.md`'s "Risks / Trade-offs" (the paragraph beginning "`Main.qml`'s own
  wiring has no component test"), including the explicit statement that a
  divergence between `tst_setup_host.qml`'s hand-reproduced routing table and
  the real `Main.qml` is invisible to both, and that `local.yaml`'s real clicks
  are what closes the gap. Per the dispatch instructions this is a known gap
  and I am not re-reporting it; I confirmed `local.yaml` does exercise
  `setupShown` through real clicks (`radicle-ui/tests/ui/local.yaml:594-627`),
  which supports the mitigation claim rather than just asserting it.

- **`lint-qml.sh` follows the existing two scripts' shape rather than
  introducing a third convention**: no-argument, `REQUIRE_QML_LINT` mirrors
  `REQUIRE_QML_TESTS`, same qmllint-binary-resolution comment structure as
  `check-qml-syntax.sh`'s qmlformat lookup, and it is wired into
  `ci.yml` immediately after `check-qml-syntax.sh` and before component tests
  — the same ordering rationale ("parse every file for real, first").

- **Mutual exclusion between `setupOpen` and `settingsOpen` is symmetric and
  enforced at both raise points** (`openSetup()` and `toggleSettings()`), not
  by a binding — matching what `design.md`/`user-flow.md` describe and
  avoiding the one-way-door defect this module has already shipped once.

- The stale comment at the old `Main.qml:656-658` that `user-flow.md` §7
  flagged as needing correction has already been rewritten correctly in this
  diff (now documents `settingsShown`/`setupShown` reading off `.visible`
  rather than the flag).
