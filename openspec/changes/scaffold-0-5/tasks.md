## Stages

- [ ] ~~spec — `spec-writer`~~ — no behaviour contract moves: a toolchain and
      pin change, so `skip_specs: true` in `.openspec.yaml`. The proposal is
      written; a behaviour change Basecamp 0.3.0 forces comes back here.
- [ ] design + code — `dev-writer`
- [ ] tests — `tester`
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

- [ ] 1.1 Set `LGS_VERSION` to `0.5.0` in `ci.yml` and `ui-tests.yml`; verify
      `git grep -n LGS_VERSION -- .github` shows one value in both, and that
      `cargo install logos-scaffold --version 0.5.0 --locked` succeeds.
- [ ] 1.2 Set `[repos.basecamp].pin` / `[repos.lgpm].pin` to scaffold v0.5.0's
      `DEFAULT_BASECAMP_PIN` / `DEFAULT_LGPM_PIN` by hand (design Decision 2);
      verify against `src/constants.rs` at tag `v0.5.0`, and that
      `lgs basecamp setup` then prints no retired-pin rewrite.
- [ ] 1.3 Pin `logos-module-builder` to `0.3.0` in both `flake.nix` files and
      relock only that input in `radicle/flake.lock`; verify the builder's
      nixpkgs rev is unchanged in the lock, and correct the `radicle/flake.nix`
      line references into module-builder that the bump moved.

## 2. Prove the gates on the new set

- [ ] 2.1 `lgs basecamp build --variant all` is green with no module source
      changed, and the packaged `radicle_ui` manifest still carries `view`,
      `main` and `icon` (the `ci.yml` assertion, run by hand).
- [ ] 2.2 Core unit tests (`nix build ./radicle#checks.x86_64-linux.unit-tests`)
      pass, read from the `Results:` line rather than the exit code alone.
- [ ] 2.3 Rust FFI tests, QML syntax and QML component tests pass. Recorded as
      run, not as coverage: none of these three links the module-builder or
      Basecamp, so they are structurally blind to this change.
- [ ] 2.4 The dev `#app` at the new pin builds, and the inspector needle
      `ui-tests.yml` greps for is present in `bin/.LogosBasecamp`.
- [ ] 2.5 Run the sitometres specs against Basecamp 0.3.0 with sitometres
      `0.1.2` per `docs/e2e.md` (the seed specs, plus `local` against a seeded
      profile); verify each report's verdict is `pass` with every step passed.

## 3. Launch-time environment

- [ ] 3.1 Run `lgs basecamp setup`, then `git diff scaffold.toml`; record
      whether v0.5.0 still strips comments, and restore the file.
- [ ] 3.2 Remove both `runtime_dir` lines and name the Wayland socket
      absolutely in `[basecamp.env]` (design Decision 5); verify with a real
      `lgs basecamp launch alice` that opens a window on the forced `wayland`
      platform, with a control run proving the forced platform fails without
      the setting, and with alice and bob running at once.
- [ ] 3.3 Verify Local mode under `lgs basecamp launch` sees no `~/.radicle`
      by default and sees the profile `RAD_HOME` names when it is exported
      before `lgs` runs (design Decision 4).

## 4. Make the documents true again

- [ ] 4.1 `scaffold.toml`'s comment block: the `runtime_dir` reasoning replaced
      by Decision 5's, the `setup` warning restated as observed in 3.1.
- [ ] 4.2 `CLAUDE.md`: release-line paragraph and verb-table note, the pin-set
      rule, the clone-build trap, the three `setup`-strips-comments passages,
      "Upstream asks", the Basecamp log path, and Local mode under `launch`.
- [ ] 4.3 `docs/e2e.md`: the flake-attribute table names the release it was
      read at; the `local.yaml` contention caveat accounts for per-profile
      `HOME`.
- [ ] 4.4 Workflow comments in `ci.yml` / `ui-tests.yml` that named v0.3.1 or
      the 0.2.3 cache measurement say what holds at the new pins.
- [ ] 4.5 `proposal.md` scope gains the `runtime_dir` removal; `docs/PLAN.md`
      "The Logos stack" points at Decision 1 and holds no second copy of it.

## 5. Hand over

- [ ] 5.1 Push to `refs/heads/piece/scaffold-0-5` and open the PR; verify CI
      starts both workflows on it.
