# Radicle for Logos Basecamp

Browse [Radicle](https://radicle.xyz) repositories from inside
[Logos Basecamp](https://github.com/logos-co/logos-basecamp).

Radicle is peer-to-peer code collaboration: repositories, issues and patches
live on a network of nodes rather than on a platform. This module gives
Basecamp a view onto that network.

**One control at the top picks where you are browsing:**

- **Explore — any public repository, with nothing installed.** Search the
  repositories a public seed node replicates, walk the file tree, read files
  and READMEs, page through commits and open any one for its diff, and read
  issues and patches with the full discussion thread. No Radicle install, no
  local node, no account.
- **Local — your own node.** If you already run Radicle on this machine, this
  reads `~/.radicle` directly: your private repositories included, and it
  works offline. Switch branches, including every peer's, not just your own.
- **Embedded — a node Basecamp runs itself.** Offered, and marked in the
  control as something this build cannot start yet: it is the next milestone,
  not a working mode. Picking it explains what it will do rather than quietly
  failing.

**And two things beyond plain browsing:**

- **Download a repository for faster browsing.** On Explore, one button caches
  everything the seed has, so browsing afterwards needs no further round trips.
  Its label is its whole interface — *Download All* the first time, a
  percentage while it runs, *Re-sync* once done, and *Update* when a later
  check finds the branch has moved past what you downloaded.
- **Take part.** Comment on an issue, or open a new one, signed by your own
  Radicle key. Writing happens on the **Local** source only, and needs a
  reachable signing key — the buttons appear when the module has probed for one
  and found it, rather than offering a box that cannot be submitted. Issues
  only for now; patch comments are not wired up yet.

## Install

Two steps: get Basecamp, then add the catalog this module is published to.

### 1. Install Logos Basecamp

Download the latest release for your platform from
[logos-co/logos-basecamp/releases](https://github.com/logos-co/logos-basecamp/releases)
— an `.AppImage` on Linux, a `.dmg` on macOS — and run it.

### 2. Add the catalog, then install the module

In Basecamp's package manager, add this URL as a module repository:

```
https://raw.githubusercontent.com/fryorcraken/logos-modules/main/logos-repo.json
```

That is [`fryorcraken/logos-modules`](https://github.com/fryorcraken/logos-modules),
a personal catalog — this module is not in a Logos-run one. Once it is added,
Basecamp can discover and install from it, and will offer updates as new
versions are published.

The app is **two** modules, and the order matters. In the package manager they
appear as:

| Install | Shown as | What it is |
|---|---|---|
| first | **Radicle Module** | the core — all the logic, no UI of its own |
| second | **Radicle** | the view you actually open |

Install **Radicle Module** first: the view declares a dependency on it and is
silently skipped if it is missing. The names are easy to get backwards — the
one with the extra word is the invisible half.

### Optional: browse your own node, and write

Nothing above requires Radicle itself. To use the **Local** source — and,
through it, to comment on and open issues — install
[Radicle](https://radicle.xyz) and let it create a profile in `~/.radicle`.
The module detects it on its own.

Writing additionally needs the *private* half of that key reachable — from an
unencrypted keystore, `RAD_PASSPHRASE`, or an `ssh-agent` holding it. Until one
of those yields a signer, the module stays read-only and says why, rather than
offering a compose box it cannot submit.

## Build it yourself

### 1. Get the source

This repository lives on two remotes, on purpose. Clone from whichever you
prefer — they hold the same history.

**From GitHub:**

```bash
git clone https://github.com/fryorcraken/logos-radicle-module
cd logos-radicle-module
```

**From Radicle**, which needs the `rad` CLI — install it by following
[radicle.xyz](https://radicle.xyz), then clone by repository ID:

```bash
rad clone rad:z39LLirsD1d4BvWMa9gFoi2B88413
cd logos-radicle-module
```

A Radicle browser ought to live on Radicle, so it does — and once you have
`rad clone`d it, the module can open this repository from its own **Local**
source. Releases still go from GitHub, because that is where the Logos catalog
publishes modules from.

Contributors push to both:

```bash
git push origin main   # GitHub
git push rad main      # Radicle
```

### 2. Build and install

Requires `nix` with flakes and [`logos-scaffold`](https://github.com/logos-co/scaffold)
(`lgs`), which drives every build from `scaffold.toml`. **This repo pins an
unreleased `lgs` build** — installing the crates.io release will get you
unrecognised-flag errors on some of the workflows here; [`CLAUDE.md`](CLAUDE.md)
carries the exact `cargo install` line and the reason.

```bash
lgs basecamp build --variant all   # both modules, both variants
lgs basecamp setup                 # once: basecamp + lgpm binaries, dev profiles
lgs basecamp install
lgs basecamp launch alice
```

This builds and launches its own Basecamp from source, so it does not need the
release download or the catalog from the previous section.

> **After any `lgs basecamp setup`, run `git diff scaffold.toml`.** `setup`
> rewrites the file and drops every comment, including the block explaining why
> `runtime_dir` is pinned — losing it re-opened a bug that made every module
> segfault. Restore what it removed.

Basecamp does not hot-reload plugins; after a rebuild, kill it, remove the
installed modules, then reinstall and relaunch.

[`CLAUDE.md`](CLAUDE.md) is the contributor guide — the full `lgs` verb table,
where artefacts land, the test layers, and the traps that have bitten changes
here.

## Modules

This repository holds all the modules for the mini app. They are published to
the Logos catalog from here.

| Directory | Module | Type | What it does |
|---|---|---|---|
| `radicle/` | `radicle` | `core` | All the business logic: seed-node HTTP, JSON parsing, ref resolution, local-node reads and writes |
| `radicle-ui/` | `radicle_ui` | `ui_qml` | Thin QML view; forwards every call to the core module |

The split is not cosmetic. Basecamp sandboxes the QML engine — it installs a
deny-all network access manager and blocks any file outside the plugin
directory — so a view cannot fetch anything itself. All network and filesystem
access has to live in a C++ module, and keeping it in one core module means the
logic is testable on its own and reusable by other frontends (a CLI, a headless
runtime) rather than trapped in a view.

## Core module API

The API names its source explicitly rather than hiding it behind one call:

- `remote*` — proxied to a seed node. Public repos only, read-only, needs network.
- `local*` — this machine's node, through a Rust staticlib over the `radicle`
  crate. Private repos, offline, and the only writable path.
- everything else (`getCapabilities`, `listKnownSeeds`, `setRemoteSeed`) is
  source-neutral.

`remoteListRepos` and `localListRepos` are different questions with different
answers, so they stay different methods. The JSON shapes they return are
identical, so a view can render either without branching.

Every method returns a JSON string; failures are always `{"error":"..."}`.
See `radicle/src/radicle_impl.h` for the full contract.

## Tests

Each layer covers what the ones below it cannot:

| Layer | Command | Covers |
|---|---|---|
| Core module unit tests | `cd radicle && nix build ".#checks.$(nix eval --raw --impure --expr builtins.currentSystem).unit-tests"` | URL building, ref resolution, pagination, error shapes, local-profile detection — no network |
| Rust FFI tests | `cd radicle/rust-ffi && cargo test` | The `local*` path against real fixture profiles, and the panic guard at the `extern "C"` boundary |
| QML component tests | `sh radicle-ui/tests/run-qml-tests.sh` | One component in isolation: selection state, layout invariants, load ordering |
| End-to-end UI tests | See [`docs/e2e.md`](docs/e2e.md) | Real clicks in a real Basecamp, real QtRO transport, real seed calls |

The unit tests drive `SeedClient` through an injected transport, so they assert
on the exact URLs built without touching the network. Two of them exist purely
because the live API is unforgiving about details that are invisible until they
fail: path parameters must be full 40-char SHAs, and the tree root needs a
trailing slash that subpaths must not have.

All of them run on every pull request.

## Disclaimer

This is an independent community project intended to demonstrate some of the
capabilities and potential uses of the Logos technology stack. It has been
developed independently by its contributor(s) and is not built for, on behalf
of, or as part of the work of Logos or the Institute of Free Technology. It has
not been reviewed, audited, approved, or endorsed by Logos or the Institute of
Free Technology. The project, including its code, documentation, views, and
functionality, is the sole responsibility of its contributor(s) and should not
be attributed to Logos or the Institute of Free Technology.

## Licence

MIT or Apache-2.0, at your option.
