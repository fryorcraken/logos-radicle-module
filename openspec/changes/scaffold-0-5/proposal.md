# Proposal

## Why

This repo builds, installs and tests against logos-scaffold 0.3.1 and the
Basecamp it defaults to, which is the 0.2.3 release. Scaffold has since
narrowed to supporting exactly one Basecamp release, 0.3.0 (scaffold v0.4.0's
release notes are that one feature). v0.5.0 lists this repo's own
`scaffold.toml` pin pair among its retired sets, so `basecamp setup` would
rewrite them and `basecamp doctor` warns until it has. Staying put means
working against a stack scaffold no longer stands behind. Moving means moving
the whole set at once, because the pins only work together.

Scaffold comes first because it decides everything else: the Basecamp and
`lgpm` pins, the module-builder generation whose SDK matches that Basecamp, and
the environment `launch` hands each profile.

## What Changes

The target was chosen by the user: **scaffold v0.5.0 and the Basecamp release
it supports, 0.3.0.** These move together, as one set:

- **`LGS_VERSION` 0.3.1 → 0.5.0** in both `.github/workflows/ci.yml` and
  `.github/workflows/ui-tests.yml`.
- **`[repos.basecamp].pin` and `[repos.lgpm].pin`** in `scaffold.toml` → the
  values scaffold v0.5.0 defaults to (`DEFAULT_BASECAMP_PIN`,
  `DEFAULT_LGPM_PIN` in its `src/constants.rs`; the basecamp one is tag
  `0.3.0`). `ui-tests.yml`'s `BASECAMP_REV` already derives from that pin, so it
  follows with no literal to edit.
- **`logos-module-builder` 0.2.6 → 0.3.0** in both `radicle/flake.nix` and
  `radicle-ui/flake.nix`, with both `flake.lock`s relocked. Scaffold v0.5.0
  states that module-builder 0.3.0's SDK set is exactly Basecamp 0.3.0's, and
  that 0.3.1 is already newer than Basecamp.
- **Whatever Basecamp 0.2.3 → 0.3.0 breaks**, fixed in the same change, in the
  module builds, the QML component tests, the sitometres specs and the CI
  workflows. These are known to have moved upstream and need checking against
  this repo:
  - the data tree: `LOGOS_USER_DIR` as the base directory, with
    `modules`/`plugins`/`module_data`/`logs` under it;
  - logging, rewritten from `LogRedirector` to `LogSink` plus a YAML session
    config, which may move the log file that CLAUDE.md and the
    `ui-tests.yml` failure-evidence step both point at;
  - `main_ui` is no longer a package (neither module declares it);
  - dependency version ranges are now enforced on a UI plugin, and there is a
    per-plugin access policy (Basecamp's own commit calls it opt-in);
  - scaffold's `launch` now gives each profile its own `HOME` (scaffold #286).
    So unless `RAD_HOME` is set for the launch, an `lgs basecamp launch alice`
    in Local mode no longer sees the developer's `~/.radicle`.
  - sitometres `0.1.2` has only ever been run here against the 0.2.3 pin.
    Whether it still drives 0.3.0's inspector has to be measured, not
    assumed.
- **The shared `runtime_dir = "/run/user/1000"` on both profiles goes**
  (added at the user's request during design + code). Scaffold v0.5.0's
  default runtime dir is short, private and per profile, so the `sun_path`
  reason for the pin is gone. Sharing one directory between `alice` and `bob`
  is the cross-profile `logos_token_<module>` collision that scaffold's
  default exists to prevent. The pin's remaining job, letting Qt find the
  Wayland socket, is to be done by naming the socket absolutely instead, and
  only if a real launch proves it works. `design.md` Decision 5 records the
  outcome.
- **sitometres `0.1.2` → `0.2.0`** in `ui-tests.yml`, `e2e-env.sh` and
  `docs/e2e.md`, which turned out to be forced: 0.1.2 cannot open the app on
  Basecamp 0.3.0 (`design.md` Decision 6).
- **`scaffold.toml`'s comment block and CLAUDE.md, made true again** under
  CLAUDE.md's own "Keeping this file true" rules. At minimum:
  - the "written against released v0.3.1" note on the verb table, and the
    0.3.0-vs-0.3.1 clone-build trap beside it;
  - the release-line background paragraph;
  - the three passages that say `setup` strips comments;
  - the "Upstream asks" section's one open ask;
  - the profile log path in "Before anything else, make the failure visible";
  - the `local.yaml` caveat about two Basecamps sharing `~/.radicle`, which
    per-profile `HOME` changes for `lgs`-launched instances;
  - `docs/e2e.md`'s Basecamp flake-attribute table, which says "at the pinned
    rev".

  **Whether `setup` still strips comments is a claim to settle by running it,
  not by reading release notes.** v0.5.0's `src/config.rs` parses with
  `toml_edit`. But its `src/project.rs` documents `save_project_config` as "a
  destructive serialization: user comments, key ordering, and any
  hand-formatting are lost", and says the comment-preserving path is `init`'s
  only. So the source suggests the trap is still live. Run `setup`, then
  `git diff scaffold.toml`, and write down what was observed.

### Not in this change

- **Basecamp 0.3.2 and module-builder 0.3.3**, although both are newer.
  Scaffold supports one Basecamp release and v0.5.0's is 0.3.0. Moving past it
  would put this repo back on a stack scaffold's launcher, bundled-module list
  and `lgpm` pairing do not describe, which is the position this change exists
  to leave. This waits until a scaffold release supports it.
- **Adopting Basecamp 0.3.0's per-module `module_data` directory** for the
  settings file or the embedded home. Both are specified to derive from
  `XDG_DATA_HOME` (`module-settings`, `node-paths`), and scaffold v0.5.0's
  `launch` still exports a per-profile `XDG_DATA_HOME`. So nothing forces a
  move, and making one would be a behaviour change with its own spec delta.
- **Any module behaviour change.** If Basecamp 0.3.0 turns out to force one
  (a path that moves, a reply that changes shape, a surface that must
  render differently), it comes back to `spec-writer` as a spec gap. It is not
  absorbed into this change as a toolchain fix.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. This is a toolchain and build-pin change. No requirement in
`openspec/specs/` changes, so the change declares `skip_specs: true` rather
than inventing a requirement to satisfy validation.

The existing contract still has to hold on the new stack, and that is what the
gates check. Two capabilities are most exposed, because they depend on the
environment Basecamp and scaffold provide rather than on this repo's code:

- `module-settings` — the settings file under `XDG_DATA_HOME`, separate per
  profile;
- `node-paths` — the embedded home under the same directory, and the socket in
  the runtime directory.

## Impact

- **Files**: `scaffold.toml`; `.github/workflows/ci.yml` and `ui-tests.yml`;
  `radicle/flake.nix`, `radicle/flake.lock`, `radicle-ui/flake.nix`,
  `radicle-ui/flake.lock`; `CLAUDE.md`; `docs/e2e.md`; whatever module source,
  metadata, QML test or sitometres spec the Basecamp 0.3.0 move breaks.
- **Gates**: every layer is exposed. The LGX builds and the core unit tests
  follow the module-builder bump. The QML component tests follow the Qt and SDK
  set it brings. The sitometres specs follow the Basecamp binary itself, and
  the first run after the pin change pays for a cold Nix store cache, because
  `ui-tests.yml` keys that cache on `BASECAMP_REV`.
- **Developer workflow**: `lgs basecamp setup` moves a project off a retired
  pin pair, so after this change a local `.scaffold/` built on 0.2.3 needs
  `setup` re-run. Per-profile `HOME` changes what an `lgs`-launched Local mode
  finds.
- **Releases**: every `.lgx` built after this change comes from
  module-builder 0.3.0. Scaffold v0.5.0's `src/constants.rs` records that an
  older `lgpm` rejects packages from 0.3.x tooling (`Forbidden root entry:
  assets`), so a package from this change cannot be assumed to install into a
  Basecamp older than 0.3.0.
