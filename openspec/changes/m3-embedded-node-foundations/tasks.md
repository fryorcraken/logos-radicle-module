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
- [ ] 4.11 Add the three tests the `source-modes` review found missing, each
      pinning a requirement that currently has none:
      - **`modeStartable` and `localNodeRunning` asserted from one
        `getCapabilities()` reply.** Their divergence is the requirement's
        headline distinction and nothing pins it. Someone "simplifying"
        `modeStartable` to `modeStartable && localNodeRunning` would be caught
        today only by the luck of a fixture with no daemon, not by a test that
        names the invariant
      - **The settings file is not rewritten when an unknown mode is read.**
        The scenario asserts the in-memory consequences only, so a future
        "self-healing settings" change that sanitises and persists would stay
        green while silently destroying a mode a newer build wrote, or a hand
        edit. Read the file back after construction
      - **The "no repositories" wording is absent on an unprovisioned embedded
        home.** The covering test asserts only that the pane is not blank,
        which an error rendered *alongside* the empty-state satisfies. The
        sibling test for an unstartable mode checks the empty-state is hidden;
        this case wants the same
- [ ] 4.13 **Close the one mutation that survived.** `getSettings`/`setSetting`
      MUST return exactly the five known keys, and the "no other key" half has
      no test: `set_returns_the_whole_settings_object_not_just_the_changed_key`
      makes five `contains()` assertions and never checks the count. Proved by
      mutation — injecting an extra key into `SettingsStore::all()` left **all
      161 unit tests green**. A regression leaking an internal field (a cached
      path, a debug flag, a stale key from an older schema) into every reply
      would ship unnoticed. The fix is one line,
      `LOGOS_ASSERT_EQ(result.size(), size_t(5))`, and the spec had already
      asked for exactly that assertion. Note this is a different path from
      `unknown_keys_in_the_file_are_ignored_rather_than_surfaced`, which covers
      a key read *from the file*; a key the store itself adds is unguarded
- [ ] 4.14 Add the `module-settings` tests the review found missing:
      - **The settings file is not rewritten when an unknown mode is read** —
        no test anywhere reads the settings file back off disk after a load
        (there is no `ifstream` on the settings path in the test tree). This is
        the same gap as 4.11's second bullet, found independently from the
        other side, which is worth noting: two reviewers converging on one
        hole is a strong signal
      - **`setSetting("radHome", …)` and `setSetting("radSocket", …)` take
        effect on the running instance.** Nothing in the tree calls either;
        only `mode` is exercised. The panel could show a stale home after a
        write and nothing would go red
      - **`setSetting("remoteSeed", …)` adopts the URL for subsequent
        `remote*` calls.** Adoption at construction is tested, and
        `setRemoteSeed()` is tested, but not this third entry point into the
        same state — which is also where 4.1's persistence gap lives
      - **The restart note says what it must.** `test_the_restart_note_is_present`
        asserts only that the text is non-empty, which a placeholder or the
        wrong sentence satisfies; the scenario is about the content
      - **Four of five defaults are unasserted** — only `mode` and `gitPath`
        are checked when nothing has been persisted
- [ ] 4.15 Decide where three tested-but-unspecified contracts belong, all
      found by the `module-settings` review: the settings panel's scrollability
      (`canScroll`, five tests), its escapability (close button, Escape key,
      not disturbing the navigation stack, five tests), and the identity
      readout. Each is real, tested behaviour with no requirement anywhere.
      Also cross-check that `startableModes()` returning exactly three is
      owned by `source-modes` — it is pinned hard in `test_settings_store.cpp`
      and `module-settings` never mentions it
- [ ] 4.16 State in `module-settings` why the first-run default and the
      unknown-mode fallback must be the *same* value.
      `the_default_and_the_unknown_mode_fallback_agree` pins it deliberately,
      and its comment says the file was inconsistent about this for a milestone
      and the inconsistency was the bug. The spec states both values
      independently and never says they must agree
- [ ] 4.17 **Verify, then test, the problem-ordering in `resolvePaths`.** The
      `node-paths` spec requires that an unresolvable home is reported as its
      own problem *in preference to* a socket-length problem when both apply,
      and justifies the ordering: a user with no `HOME` and a long socket must
      be told the home is missing, not to shorten their socket. **No test calls
      `resolvePaths` with an empty home at all**, so the ordering is
      unverified — the reviewer could not confirm the code implements it
      without reading the implementation, which its remit forbids. Read the
      code first: if the order is wrong, that is a real bug this change found
      and could not see. Then pin it
- [ ] 4.18 Add the remaining `node-paths` tests, each a requirement with a
      stated rationale and no assertion behind it:
      - **A refused socket is still reported as the resolved socket.** The
        tests assert only on `problem`, never reading `paths.socket`. A
        plausible "don't hand back a path we rejected" refactor would satisfy
        every existing assertion while making the surface show a message
        naming a path whose field reads empty — the exact disagreement the
        requirement forbids
      - **`resolveSocket` with no source at all returns the empty string.**
        Every existing call passes a non-empty home, so nothing catches a
        return of `/node/control.sock` — a filesystem-root path, and precisely
        the defect `resolveHome`'s equivalent test exists to prevent. The spec
        states the rule in the same sentence shape for both resolvers and only
        one half got a test
      - **An empty profile name yields an unsuffixed socket.** Covered only
        incidentally by a writer test whose stated purpose is socket
        agreement, so a change to `radicle-.sock` would fail a test named for
        something else and no test named for this behaviour
      - **A stale socket file is not a running node.** The requirement flags
        this as the interesting case — the file outlives the daemon — and a
        `nodeRunning()` doing `stat()` instead of `connect()` passes the whole
        suite today
      - **`setSetting("radHome"/"radSocket", …)` repoints the reported paths
        without a restart.** Same gap as 4.14, reached from the paths side
- [ ] 4.12 Note `ModePicker` has no test file of its own — it is exercised
      only through `tst_settings.qml` and `tst_source.qml`. Not a gap in
      itself, but the annotation rule is now stated twice in `source-modes`, in
      different words for two controls, which is worth consolidating
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
- [x] 5.1b Re-run `spec-test-reviewer` on the remaining three capabilities,
      one agent per capability. **The narrow scope worked** — the whole-change
      agent stalled, all three narrow ones finished and removed their own
      worktrees.
      - **`source-modes`: four mutations, all caught.** Three spec defects
        fixed in place: a requirement stating flatly that all three modes are
        startable (which would licence a view hard-coding it, contradicting
        the component tests); a scenario claiming the "no repositories" wording
        is suppressed when its test only checks the pane is not blank; and a
        negative existential no test could check. Three coverage gaps recorded
        as 4.11/4.12
      - **`module-settings`: one mutation, and it SURVIVED** — see 4.13. That
        is the single most valuable result of the whole review, because a
        surviving mutation is the only kind of finding that cannot be argued
        with. Recorded as 4.13-4.16
      - **`node-paths`: three mutations, all caught**, including the 107/108
        boundary in both directions (the 107 test stayed green under a
        loosened check, so it is not passing by accident) and the
        socket-does-not-follow-the-home invariant, whose removal turns five
        tests red. Two spec defects fixed: two clauses asserting a syscall is
        *not* made, which nothing at this layer can observe, and a scenario
        citing a socket path the test does not use. A cross-capability
        dependency was made explicit rather than left implied. Coverage gaps
        recorded as 4.17-4.18
      - **All three reviewers independently reported the same positive
        finding**, which is worth recording as loudly as the defects: **no
        same-answer-for-every-input fixture exists in any of these files.**
        Fakes store what they are given, per-store values differ
        (`alice.example` vs `bob.example`), each precedence branch asserts a
        value distinct from what the branch below would give, and several
        tests exist *solely* to stop a sibling passing vacuously. The trap
        that shipped a dead feature through every gate is genuinely not
        present here
      - Two reviewers looked specifically for the aspiration-instead-of-
        description defect found in `embedded-identity` and **neither found
        another**. What they found instead is its milder cousin: requirements
        that are true and carry a stated rationale, with nothing asserting
        them. That is the characteristic residue of a retrospective capture,
        and it is what §4 now lists
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
