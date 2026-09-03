# logos-radicle-module

Browse [Radicle](https://radicle.xyz) repositories from
[Logos Basecamp](https://github.com/logos-co/logos-basecamp).

Two ways to browse, kept deliberately distinct:

- **Any repo** — proxies to a public seed node over HTTPS. Needs no local
  Radicle install and no local node, and can reach any public repository the
  seed replicates. Read-only.
- **My node** — reads this machine's own Radicle node, including private
  repositories, and works offline.

## Where this lives

Two remotes, on purpose:

- **GitHub** — <https://github.com/fryorcraken/logos-radicle-module>. Logos
  modules are published to the catalog from GitHub, so releases go from here.
- **Radicle** — `rad:z39LLirsD1d4BvWMa9gFoi2B88413`. A Radicle browser ought to
  live on Radicle; you can open this repository in the module itself.

```bash
git push origin main   # GitHub
git push rad main      # Radicle
```

## Modules

This repository holds all the modules for the mini app. They are published to
the Logos catalog from here.

| Directory | Module | Type | What it does |
|---|---|---|---|
| `radicle/` | `radicle` | `core` | All the business logic: seed-node HTTP, JSON parsing, ref resolution, local-profile detection |
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
- `local*` — this machine's node. Private repos, offline, writable in future.
- everything else (`getCapabilities`, `listKnownSeeds`, `setRemoteSeed`) is
  source-neutral.

`remoteListRepos` and `localListRepos` are different questions with different
answers, so they stay different methods. The JSON shapes they return are
identical, so a view can render either without branching.

Every method returns a JSON string; failures are always `{"error":"..."}`.
See `radicle/src/radicle_impl.h` for the full contract.

## Tests

Three layers, each covering what the one below cannot:

| Layer | Command | Covers |
|---|---|---|
| Core module unit tests | `cd radicle && nix build '.#test'` | URL building, ref resolution, pagination, error shapes, local-profile detection — no network |
| QML component tests | `sh radicle-ui/tests/run-qml-tests.sh` | Selection state, fixed chrome heights, the seed-picker load ordering |
| End-to-end UI tests | `npx @paradoxcomputer/sitometres run radicle-ui/tests/ui/browse.yaml` | Real clicks in a real Basecamp, real QtRO transport, real seed calls |

The unit tests drive `SeedClient` through an injected transport, so they assert
on the exact URLs built without touching the network. Two of them exist purely
because the live API is unforgiving about details that are invisible until they
fail: path parameters must be full 40-char SHAs, and the tree root needs a
trailing slash that subpaths must not have.

The sitometres layer needs a Basecamp built with the QML inspector, which is a
compile-time feature that is off in the shipping AppImage:
`cd logos-basecamp && nix build .#default`.

## Status

Browsing any public repository over a seed node works: repository search,
source tree, file viewer, commits, issues and patches.

Local-node browsing is detected and reported but not yet wired up — the
`local*` methods return a clear reason rather than pretending to be empty. That
backend, and writing issues/comments, come next.

## Build

Requires `nix` with flakes.

```bash
# core module
cd radicle    && nix build '.#lgx'

# UI module (resolve the sibling core module from the working tree)
cd radicle-ui && nix build '.#lgx' --override-input radicle path:../radicle
```

Install into Basecamp with [`logos-scaffold`](https://github.com/logos-co/logos-scaffold):

```bash
lgs basecamp setup      # once
lgs basecamp modules    # discover the flakes in this repo
lgs basecamp install
lgs basecamp launch alice
```

Basecamp does not hot-reload plugins; after a rebuild, kill it, remove the
installed modules, then reinstall and relaunch.

## Licence

MIT or Apache-2.0, at your option.
