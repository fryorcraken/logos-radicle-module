## 1. Capture the shipped behaviour as specs

Each spec is written from the code and its tests, never from
`docs/M3-embedded-node-plan.md`, which is frozen research describing intentions
that implementation revised.

- [x] 1.1 Write `specs/module-settings/spec.md` from `settings_store.{h,cpp}`,
      `test_settings_store.cpp` and the `getSettings`/`setSetting` surface;
      verify with `openspec validate m3-embedded-node-foundations --strict`
- [x] 1.2 Write `specs/source-modes/spec.md` from `startableModes()`,
      `storeForSettings()`, `getCapabilities()` and `SourceState.qml`; verify as
      above
- [x] 1.3 Write `specs/node-paths/spec.md` from `env.rs`, `resolvePaths()` and
      `control_socket.rs`; verify as above
- [x] 1.4 Write `specs/embedded-identity/spec.md` from `profileinit.rs`,
      `profile_init.rs` and the two identity methods; verify as above
- [x] 1.5 Record the migrated decisions in `design.md`, each with its
      alternatives and what ruled them out; verify every Decisions entry names
      a constraint, an alternative and a cost

## 2. Reconcile the specs with each other

The four capabilities were written in parallel and share a surface, so their
seams are where a contradiction would hide.

- [x] 2.1 Check `getCapabilities()` is described consistently across
      `source-modes`, `node-paths` and `embedded-identity` — in particular that
      only one of them defines each field, and that "startable" versus
      "running" is stated the same way in all three. Clean: `source-modes`
      owns the distinction and states the differing lifetimes
- [x] 2.2 Check the socket length bound is stated identically wherever it
      appears (the constant is 108 including the NUL, so a path may be 107, and
      the shipped error string says 107); verify against
      `local_store.cpp`'s `kSunPathMax` use rather than against either spec.
      Verified against `local_store.cpp:114-118` (`size() + 1 > kSunPathMax`,
      message says `kSunPathMax - 1`); both specs agree with the code
- [x] 2.3 Check no requirement appears in two capabilities; move any duplicate
      to the one that owns it and leave a pointer rather than a second copy.
      No duplicate requirement names; the one genuine overlap (`radSocket`
      validated both at write and at resolution) now points at `node-paths`,
      which owns the rule and explains why the double check is not redundant
- [x] 2.4 Re-run `openspec validate m3-embedded-node-foundations --strict` and
      confirm it still passes after any edits

## 3. Shed what the specs now carry

- [x] 3.1 Prune `docs/PLAN.md` of behaviour these specs now state: strike it
      through with a pointer to the capability, leaving at most a one-line
      summary that it exists; verify by reading PLAN.md end to end for anything
      that now reads as forthcoming but has shipped
- [x] 3.2 Confirm no reasoning is duplicated between `docs/PLAN.md` and
      `design.md`; the archive is the single home for a decision's rationale.
      Two passages moved: the isolated-identity decision with its two rejected
      non-goals, and the socket profile-name question. What stayed is what
      binds work not yet written — the six git spawn sites, `listen: []`,
      platform scope — which is intent rather than a decision already taken

## 4. Report what specifying found, without fixing it

This change has no code edits by construction. Every finding below is written
up for a later change, and fixing one here would put a behaviour change inside
a change whose premise is that it has none.

- [ ] 4.1 Write up the seed-persistence gap: `setRemoteSeed` probes and adopts
      but never persists, `setSetting("remoteSeed", …)` persists but does not
      probe, and the UI's picker calls the first — so the chosen seed still
      does not survive a restart, which Phase 1's own commit message claims it
      does. Verify the claim by reading `radicle_impl.cpp`'s `setRemoteSeed`
      and grepping `radicle-ui/src/qml/` for both call sites
- [ ] 4.2 Write up the unvalidated `radHome`: every other non-mode key is
      validated on write, and a bad home surfaces later as
      `localAvailable: false` — the deferred-failure shape the settings header
      itself rejects for `gitPath`
- [ ] 4.3 Write up `SettingsPanel.currentMode` defaulting to `local` where the
      backend defaults to `explore`, and the stale `NodeIdentity.qml` header
      comment that still says Embedded has no identity to show
- [ ] 4.4 Write up the coverage gaps the specs exposed: no C++ test drives
      `getCapabilities().canWriteLocal` for an encrypted embedded identity, and
      nothing pins that `getEmbeddedIdentity().nodeId` agrees with
      `getCapabilities().nodeId`
- [ ] 4.5 Note that `local` mode passes an empty profile name to
      `resolveSocket`, so per-profile socket scoping is reachable only from
      unit tests and two Basecamp profiles would collide on one runtime dir
- [ ] 4.6 Write up the stale `local`-as-default comments, which two capability
      specs found independently: `radicle_impl.h:133-134` and
      `test_radicle_impl.cpp:673,681` call `local` "the default state, and
      where every first-time user is" when `settings_store.cpp` defaults to
      `explore`. The argument survives substituting the mode name; the name is
      wrong
- [ ] 4.7 Write up `modeUnavailableReason` being unreachable: all three modes
      are startable and an unknown stored mode sanitises to `explore`, so no
      reachable state makes it non-empty. Decide whether it stays as a
      fourth-mode affordance or goes
- [ ] 4.8 Write up `[]` meaning opposite things across a module boundary —
      `SourceToggle` reads an empty startable set as "mark every segment",
      `SourceState` reads it as "not yet reported, treat as startable". Both
      are deliberate and pinned by tests, and the failure each guards against
      differs, but one value means two things across a seam that `RepoList`
      derives from. Worth a decision on unifying
- [ ] 4.9 Write up `setSetting("mode", …)` failure being wholly unspecified
      and untested: nothing says what the segment shows when the write is
      refused, or when capabilities return a mode the user did not pick
- [ ] 4.10 Consider making **mutation evidence a standing field in Decisions
      entries** — "removing this guard turns exactly these tests red". The
      commit messages carry it for nearly every decision and `design.md`
      migrated it for only one (`resolveSocket`'s profile argument). It is
      what stops a future reader deleting a guard, and it is the most
      perishable thing in a commit message. A change to
      `.claude/agents/dev-writer.md` and the `design-reviewer`'s "what a good
      Decisions entry contains" list, not to this change

## 5. Review

- [x] 5.1 Run `spec-test-reviewer` against the specs and the existing tests —
      it reads the spec and tests but not the implementation, which is what
      makes it able to see a test that pins what was built rather than what was
      asked for. **The agent stalled part-way through its mutation run and was
      stopped**; it had produced one finding, and its pending mutation was
      completed by hand rather than abandoned:
      - **The spec was wrong, not the code.** `embedded-identity` asserted that
        the reply's `encrypted` is "derived from what was done rather than
        echoed from the input". `profileinit.rs:332` computes it as
        `!passphrase.is_empty()` — an echo. This is the aspiration-instead-of-
        description failure a retrospective spec is most prone to, and it is
        the spec that was corrected, since this change has no code edits
      - **Mutation run to settle it, and the tests hold.** Forcing
        `Profile::init` to take `None` for the passphrase — reporting
        `encrypted: true` over an unencrypted key — turns
        `a_passphrase_encrypts_the_key_and_reports_it` red with
        `canWrite: true` where `false` was expected. 13 passed, 1 failed. The
        test survives the echo because it asserts through `can_write` against
        the key on disk rather than against the reported flag. Tree restored
        and verified clean
- [ ] 5.1b Re-run `spec-test-reviewer` on the remaining three capabilities.
      Only `embedded-identity` was reached before the stall, so
      `module-settings`, `source-modes` and `node-paths` have had no
      spec-versus-test pass. Split it one capability per agent — the single
      agent stalled on a whole-change scope, and mutation runs are slow enough
      that four narrow passes will finish where one broad one did not
- [x] 5.2 Run `design-reviewer` against `design.md`, the code and
      `docs/PLAN.md`; verify it reports on decisions taken in code but not
      recorded. Findings acted on in this change, since all were artifact
      edits rather than behaviour changes:
      - **`design.md` had inherited Phase 1's false seed-persistence claim**
        from the commit message. Corrected in place and recorded *as* a
        correction, because a silent fix would hide the propagation the
        archive exists to stop
      - Added four unrecorded decisions: the spike's removal from the lock
        (cargo vendoring is feature-blind, and the probe's `.txt` suffix is
        load-bearing because cargo auto-discovers `examples/*.rs`); the
        announce socket threaded as a parameter rather than read from the
        environment; `absentProfileReason` travelling with the paths rather
        than teaching `LocalStore` about modes; and the policy of keeping
        unreachable safety branches on purpose
      - Moved the announce-socket trap into `writes.md`, where whoever edits
        `cobwrite.rs` will look, rather than leaving it only in an archived
        design document
      - Shed PLAN.md's third copy of the six-spawn-sites reasoning down to a
        pointer at `rust-ffi.md`, which owns it
- [ ] 5.3 Act on findings, routing each to the artifact that owns it, and
      re-run only the reviewers whose findings led to changes
- [ ] 5.4 `openspec archive m3-embedded-node-foundations`, taking the sync
      prompt so the deltas are promoted into `openspec/specs/`; verify with
      `openspec list --specs` showing all four capabilities
