## Stages

- [ ] ~~spec — `spec-writer`~~ — no behaviour contract moves: a toolchain and
      pin change, so `skip_specs: true` in `.openspec.yaml`. The proposal is
      written; a behaviour change Basecamp 0.3.0 forces comes back here.
- [x] design + code — `dev-writer`
- [x] tests — `tester`
- [ ] review: correctness — `code-reviewer`
- [ ] review: security — `code-reviewer`
- [ ] review: readability — `code-reviewer`
- [ ] review: architecture — `code-reviewer`
- [ ] review: spec-test — `spec-test-reviewer`
- [ ] review: design — `design-reviewer`
- [ ] findings all ticked, `findings/` deleted — `closer`
- [ ] `openspec validate --strict`, then `archive` — `closer`
- [ ] CI green, title/body checked, PR merged — `closer`

# Tasks

## 1. Move the pin set

- [x] 1.1 Set `LGS_VERSION` to `0.5.0` in `ci.yml` and `ui-tests.yml`; verify
      `git grep -n LGS_VERSION -- .github` shows one value in both, and that
      `cargo install logos-scaffold --version 0.5.0 --locked` succeeds.
- [x] 1.2 Set `[repos.basecamp].pin` / `[repos.lgpm].pin` to scaffold v0.5.0's
      `DEFAULT_BASECAMP_PIN` / `DEFAULT_LGPM_PIN` by hand (design Decision 2);
      verify against `src/constants.rs` at tag `v0.5.0`, and that
      `lgs basecamp setup` then prints no retired-pin rewrite.
- [x] 1.3 Pin `logos-module-builder` to `0.3.0` in both `flake.nix` files and
      relock only that input in `radicle/flake.lock`; verify the builder's
      nixpkgs rev is unchanged in the lock, and correct the `radicle/flake.nix`
      line references into module-builder that the bump moved.

## 2. Prove the gates on the new set

- [x] 2.1 `lgs basecamp build --variant all` is green with no module source
      changed, and the packaged `radicle_ui` manifest still carries `view`,
      `main` and `icon` (the `ci.yml` assertion, run by hand).
- [x] 2.2 Core unit tests (`nix build ./radicle#checks.x86_64-linux.unit-tests`)
      pass, read from the `Results:` line rather than the exit code alone.
- [x] 2.3 Rust FFI tests, QML syntax and QML component tests pass. Recorded as
      run, not as coverage: none of these three links the module-builder or
      Basecamp, so they are structurally blind to this change.
- [x] 2.4 The dev `#app` at the new pin builds, and the inspector needle
      `ui-tests.yml` greps for is present in `bin/.LogosBasecamp`.
- [x] 2.5 Run the sitometres specs against Basecamp 0.3.0 per `docs/e2e.md`
      (the seed specs, plus `write` and `local` against seeded profiles).
      The task as first written named sitometres `0.1.2`, and that could not
      be done: 0.1.2 cannot open the app on 0.3.0 at all. `SITOMETRES` moved
      to `0.2.0` in `ui-tests.yml`, `e2e-env.sh` and `docs/e2e.md`.
      On 0.2.0: browse 18/18, branches 17/17, write 36/36 and local 47/47 pass.
      `source` (step 13) and `sync` (step 17) failed identically on the OLD
      stack (Basecamp 0.2.3, sitometres 0.1.2, the pre-change modules), run
      side by side against the same seed, which is what cleared the toolchain.
      Both were spec defects, fixed by the tester in `bc24ded`: `source.yaml`
      scrolls its README row into view, and `sync.yaml` polls for staleness
      before it cancels a sync (design: Risks).

## 3. Launch-time environment

- [x] 3.1 Run `lgs basecamp setup`, then `git diff scaffold.toml`; record
      whether v0.5.0 still strips comments, and restore the file. It does:
      29 comment lines deleted and no value changed. `basecamp doctor` then
      reports the pin set as "scaffold defaults" (design Decision 6).
- [x] 3.2 Remove both `runtime_dir` lines and name the Wayland socket
      absolutely in `[basecamp.env]` (design Decision 5); verify with a real
      `lgs basecamp launch alice` that comes up on the forced `wayland`
      platform, with a control run proving the forced platform fails without
      the setting, and with alice and bob running at once. All three were
      run; the table is in Decision 5. "A window opened" is inferred from the
      process staying up on a forced Wayland backend with no `wl_display`
      error, not from looking at the screen. No automated gate can see any of
      this.
- [ ] 3.3 Verify Local mode under `lgs basecamp launch` sees no `~/.radicle`
      by default and sees the profile `RAD_HOME` names when it is exported
      before `lgs` runs (design Decision 4). Partly done, so left unticked:
      the launched environment was read back (`HOME` is the profile's own,
      no `RAD_HOME`, shell variables inherited). No launch was driven into
      Local mode, and none was run with `RAD_HOME` exported, which would need
      a `VAR=value` prefix or an edit to the developer's real shell profile.

## 4. Make the documents true again

- [x] 4.1 `scaffold.toml`'s comment block: the `runtime_dir` reasoning replaced
      by Decision 5's, the `setup` warning restated as observed in 3.1.
      Verified the file still parses (`lgs basecamp paths bob`).
- [x] 4.2 `CLAUDE.md`: release-line paragraph and verb-table note, the pin-set
      rule, the clone-build trap, the three `setup`-strips-comments passages,
      "Upstream asks", the Basecamp log path (checked against a real launch:
      `<app_logs_dir>/basecamp.log` carries the `qt.qml.import` lines), and
      Local mode under `launch`. Also the `runtime_dir` mention under
      "Environment goes in `scaffold.toml`", plus README.md's stale
      "unreleased `lgs` build" claim and its `setup` note.
- [x] 4.3 `docs/e2e.md`: the flake-attribute table names the release it was
      read at; the `local.yaml` contention caveat accounts for per-profile
      `HOME`; the sitometres version and its pairing with Basecamp; the
      `calls:` note qualified by the versions it was measured on.
- [x] 4.4 Workflow comments in `ci.yml` / `ui-tests.yml` that named v0.3.1 or
      the 0.2.3 cache measurement say what holds at the new pins (0.3.0's
      `#app` re-checked absent from the logos cache).
- [x] 4.5 `proposal.md` scope gains the `runtime_dir` removal and the
      sitometres bump; `docs/PLAN.md` "The Logos stack" points at Decision 1
      and holds the constraint, not the reasoning.

## 5. Hand over

- [ ] 5.1 Push to `refs/heads/piece/scaffold-0-5` and open the PR; verify CI
      starts both workflows on it.
