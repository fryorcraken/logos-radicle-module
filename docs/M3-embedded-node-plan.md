# M3 — An embedded Radicle node, set up from inside Basecamp

Status: **plan, not scoped for implementation.** No code written. Every
technical claim below was checked against the `radicle 0.25.1` source
vendored in `~/.cargo/registry`, the crates.io API, and the local docs
checkout at `~/src/rad/radicle.xyz` — the places each claim came from are
named inline so the next session can re-verify rather than re-derive.

## The problem M3 solves

Setting up `rad` by hand is cumbersome. Today's `local*` surface (M2.1)
assumes the user already did it: install the binaries, `rad auth`, start a
node, wire a systemd unit, get the DID allow-listed, `rad seed` on each
peer. `~/src/rad/agents/radicle/AGENTS.md` is 16KB of exactly that, written
by someone who had to learn it the hard way — and its "Gotchas" section is
the honest measure of the problem:

- `rad init` + `rad id update --allow` is **not enough** to replicate a
  private repo; every other node must *also* `rad seed <RID> --scope all`,
  or `rad sync` just times out with "All seeds timed out".
- A fresh node's routing table may list only the public community seeds, so
  `rad clone` fails with "no seeds found" while connected to a peer that
  has the data. Fix: `--seed <NID>` explicitly.
- Stale gossiped addresses make a node dial a peer's NAT address forever;
  the fix is a **daemon restart**, which no error message suggests.

None of those are things a user can reasonably be expected to deduce. M3's
goal: **a user picks "Embedded" in Basecamp, answers a short wizard, and has
a working node** — with a configuration panel for the things that actually
need tuning, and no terminal.

## The three questions asked, answered

### 1. Is a CLI still required?

**No, and this is better than expected — but `git` the binary is still
required.**

| Capability | CLI needed? | Evidence |
|---|---|---|
| Read storage, repos, tree, blob, commits | No | Already shipped in M2.1 |
| Read COBs (issues, patches) | No | `Issues::open` + `NoCache`, shipped |
| **Create/edit/comment issues & patches** | **No** | `IssueMut::{create, comment, edit, edit_description, lifecycle}` — `cob/issue.rs:627-670`, `Issues::create` at `:796`. Needs only a `Signer`. |
| **Create the identity/keypair (`rad auth`)** | **No** | `Profile::init(home, alias, passphrase, seed)` — `profile.rs:234`. Creates keystore, storage, config, policy/notification DBs, COB cache, in one call. |
| **Run the node daemon** | **No** — see below | `radicle-node` 0.21.1 is a **library** crate, not binary-only |
| Seed / unseed a repo | No | `Profile::{seed, unseed, add_inventory}` — `profile.rs:387-420` |
| Connect to a peer, announce, fetch | No | `node::Command::{Connect, AnnounceRefsFor, Seeds…}` over the control socket |
| **Push a branch / open a patch** | **No CLI, but yes `git`** | See the git caveat below |

**The git caveat, and it is load-bearing.** Radicle's local git transport
does **not** implement pack protocol in-process. `storage/git/transport/local.rs:53`
literally does:

```rust
let mut cmd = process::Command::new("git");
… cmd.arg(service).arg(&git_dir)   // "upload-pack" | "receive-pack"
```

So any push into Radicle storage spawns `git`. This is invisible on a dev
box and fatal in a sandboxed Basecamp bundle. **M3 must treat `git` as a
runtime dependency it discovers, reports on, and lets the user point at** —
see "The git binary is a setting, like any IDE" below. This is the single
most likely cause of "works on my machine, mysteriously broken for a user",
and it is the first thing the wizard's preflight should check.

Note this sharpens M2.2's open question #6/#7 ("does the crate expose a
direct API, or must we invoke git push"): the answer is that *even the
crate's own path* invokes git. There is no pure-library push.

#### The git binary is a setting, like any IDE

**Decision (accepted): `git` is user-configurable, not auto-detected-only.**
VS Code (`git.path`), IntelliJ ("Path to Git executable") and Sublime Merge
all do the same thing for the same reason — auto-detection is right ~95% of
the time and unfixable by the user the other 5%: Nix profiles, Homebrew vs
Xcode git, a portable bundle whose `PATH` is not the user's login `PATH`.

Shape:

- **Default is empty, meaning "find it"** — resolve `git` from `PATH` and
  report the resolved absolute path back to the UI. An empty setting is a
  working setting, so most users never see this field.
- **An explicit path overrides detection entirely.** No silent fallback to
  `PATH` if the configured binary is missing: that would make a typo look
  like a Radicle bug. Fail with the path that was tried.
- **Validate on set, not on first push.** Run the candidate's
  `git --version`, accept only on success, and surface version and path.
  Discovering a bad git path at the moment a user pushes their first patch
  is exactly the deferred-failure shape this repo keeps getting bitten by.
- **Expose it in preflight and diagnostics**, not just in a settings pane —
  "git: /nix/store/…/bin/git (2.51.0)" or "git: not found" belongs in the
  capability report, because it is the difference between writes working
  and not.

Because the transport spawns git via `process::Command::new("git")` — a
bare name, resolved through `PATH` — honouring a configured absolute path
means **setting `PATH` (or `GIT_EXEC_PATH`) for the child environment**
before any operation that can reach the transport. The crate offers no hook
to inject the binary directly. Worth confirming in Phase 0 alongside the
runtime spike, since it decides whether this is a one-line env tweak or
needs a wrapper on the spawn path.

### 2. Can the node actually be embedded?

**Yes — and this is the finding that makes M3 buildable rather than
aspirational.**

The `radicle` crate you already depend on is a **client library, not the
daemon**. `node::Node` (`node.rs:1166`) is a thin Unix-socket client:
`Node::call` opens a `UnixStream` to `control.sock` and writes a JSON
command. Grepping the crate for a server runtime finds nothing. So the
existing dependency alone cannot run a node — it can only talk to one.

The daemon is the separate `radicle-node` crate, and crates.io reports:

```
radicle-node 0.21.1   "has_lib": true   bin_names: ["radicle-node"]
  depends on: radicle ^0.25.1        <-- exactly what rust-ffi already pins
  features: default = [backtrace, i2p, systemd, structured-logger, socket2, tor]
```

Two facts that matter enormously:

- **`has_lib: true`** — it is not a binary-only crate. It can be linked and
  driven in-process, which is what "embedded" should mean.
- **It wants `radicle ^0.25.1`, the exact version `rust-ffi/Cargo.lock`
  already resolves.** No version bridge, no duplicate `radicle` in the
  graph, no second libgit2. The compatibility risk that would normally sink
  this idea is simply absent.
- `systemd` is a **default feature**, and optional (`cfg(target_os = "linux")`).
  An embedded node must build with `default-features = false` and re-add
  only what it needs, or it will try to talk to a service manager that
  isn't supervising it.

**Recommendation: in-process thread, not a spawned binary.** Ship the node
as a thread inside the core module, started and stopped by the module.
Rationale: the module already owns an FFI boundary and a lifecycle; a
spawned binary means shipping a second executable through the `.lgx`
packaging, finding it at runtime, and orphan-process cleanup when Basecamp
dies. The in-process route trades that for a larger link and the need to
never panic across the FFI boundary — a discipline `guarded()` already
establishes in this crate.

**This needs a spike before it is committed to** (see Phase 0). `has_lib:
true` proves a library target exists; it does not prove the library exposes
a clean "run until cancelled" entry point rather than a `main()`-shaped one
that assumes it owns signal handling and the process. `radicle-signals` is
a non-optional dependency, which is a hint that it might. Phase 0 exists to
answer exactly this, and the fallback (spawn the bundled binary) is real
and not much worse.

### 3. Will it conflict with an installed node?

**Not if we isolate deliberately — and the protocol already gives us every
knob needed.** Three independent resources can collide; all three are
controllable:

| Resource | Default | Collision if shared | How we isolate |
|---|---|---|---|
| **Storage / keys** | `~/.radicle` | Two nodes writing one git storage. **This is the dangerous one** — CLAUDE.md already records step-9 e2e flakes caused by two Basecamps on one `~/.radicle`. | `RAD_HOME` → Basecamp's own XDG dir. `profile.rs:509` `home()` honours it. |
| **Control socket** | `$RAD_HOME/node/control.sock` | Commands sent to the wrong node | `RAD_SOCKET` env var, `profile.rs:48` + `socket_from_env():692`. Follows `RAD_HOME` by default anyway. |
| **P2P port** | `8776` (`node.rs:61` `DEFAULT_PORT`) | Second node cannot bind; startup fails | `config.listen` (`node/config.rs:603`). Embedded default: **`listen: []`** — outbound-only. |

`listen: []` deserves emphasis, because it is both the safe default and a
real limitation the UI must be honest about. Per the seeder guide and
AGENTS.md Part F, a node with `listen: []` is **outbound-only**: it can
fetch and announce, but other nodes cannot fetch *from* it. For a desktop
user behind NAT that is the correct default — it needs no port, no firewall
rule, and cannot collide. The config panel should offer "allow inbound
connections" as an explicit opt-in with a port field, defaulting off, and
should say plainly that leaving it off means peers can't pull from you
directly.

**The isolation decision has a real cost. Decision (accepted): pay it.** A
fully isolated embedded node has its **own NID/DID** — a different identity
from the user's existing `~/.radicle`. Their repos are not there, their
allow-listed DID is not this one, and (per the AGENTS.md gotcha) getting a
private repo replicated to the new DID means a delegate must
`rad id update --allow` it *and* every peer must `rad seed` it. So for a
user who already has `rad`, an isolated embedded node is a **new machine
joining their network** — which is accepted as the intended model, not a
compromise to design around.

What that buys: isolation by construction. No shared storage, no shared
socket, no port contention, no possibility of the embedded node corrupting
an identity the user depends on.

What it obliges: the consequence must be **stated, never silent**. A user
who clicks "Embedded" while holding an existing profile has to be told they
are creating a second identity, and handed the `rad id update --allow
<DID>` line that authorizes it. Treating "new machine" as the accepted
model is what makes that a clear onboarding step rather than a bug report.

Hence the three modes below.

## Proposed model: three modes, chosen once, visible always

| Mode | `RAD_HOME` | Node lifecycle | Who it's for |
|---|---|---|---|
| **Attach** | existing `~/.radicle` | Not ours — we detect and use whatever is running | Already has `rad`; M2.1's current behaviour |
| **Embedded** | Basecamp-owned dir | Started/stopped by the module | Has no `rad`, wants it to just work |
| **Seed-only** | none | none | Browse public repos; today's `remote*` path |

`getCapabilities()` already reports `localAvailable` / `localNodeRunning` /
`canWriteLocal`; M3 extends it with the active mode, the NID, the resolved
`RAD_HOME`, and whether `git` was found. **The UI must always show which
mode is active and which identity is in use** — the failure this design is
most exposed to is a user believing they are operating as their existing
DID when they are operating as a fresh embedded one, and not understanding
why their private repos are missing.

A deliberate non-goal: **do not offer to copy or move an existing
`~/.radicle` into the embedded home, and do not offer to import the user's
existing secret key.** Both are plausible-sounding features that risk
corrupting the user's real identity or duplicating a key across two running
nodes writing the same storage. If a user wants their existing identity,
that is Attach mode, which is exactly what Attach is for.

## The wizard

Six steps, each of which fails loudly rather than proceeding on a guess.

0. **Preflight.** Is `git` on PATH (see the caveat above)? Is there an
   existing `~/.radicle`, and is a node already running on its socket? Can
   we write our own home? Report all of it before offering a choice — a
   user with an existing profile should be *told* so, and offered Attach,
   not silently given a second identity.
1. **Mode.** Attach / Embedded / Seed-only, with the identity consequence
   stated in one sentence each.
2. **Identity.** Alias + passphrase. `Profile::init` takes
   `Option<Passphrase>`; `keystore.rs:92` confirms `None` means an
   unencrypted key on disk. **Offer a passphrase, default to setting one,
   and state the trade-off**: no passphrase means the node starts unattended
   but the signing key sits unencrypted. Reads never need it (M2.1 proved
   this — only `keys/radicle.pub` is read); **writes do**.
3. **Network.** Inbound off by default (`listen: []`). Preferred seeds
   prefilled with the built-ins the module already lists.
4. **Start.** Launch the node, wait for the control socket to answer, show
   the NID. A node that fails to start must say why.
5. **Confirm.** Show the resolved home, NID, mode, listen state, and — if
   Embedded — the "this is a new identity" consequence one final time, with
   the `rad id update --allow <DID>` line ready to copy for a user who
   needs to authorize it elsewhere.

## Settings need somewhere to live — there is no such place today

Checked, and worth stating before designing a panel on top of nothing:
**this module persists no configuration at all.** `setRemoteSeed`
(`radicle_impl.cpp:82`) mutates a function-local `static` and is lost on
restart; `listKnownSeeds` returns three compile-time constants
(`radicle_impl.cpp:15`). Nothing writes a config file.

M3 cannot avoid fixing this — mode, `RAD_HOME`, listen/port, preferred
peers and the git path must all survive a restart, or the wizard is a thing
users re-run every launch. So the git setting is not a special case needing
its own mechanism; it is one field in the settings store M3 has to
introduce regardless.

Shape, kept deliberately small:

- **Module-owned config file** under Basecamp's per-profile XDG dir, so two
  Basecamp profiles (`alice`/`bob`) keep separate settings — matching the
  isolation the rest of the stack already has.
- **Not `~/.radicle/config.json`.** That file belongs to the node and is
  rewritten by it; the module's own settings (mode, git path, chosen seed)
  are a different lifetime and a different owner. Embedded-node *node*
  config is written into the embedded home's own `config.json` as the
  node's format demands — but which mode we're in, and where git is, are
  ours.
- **Source-neutral API**, alongside `setRemoteSeed`: `getSettings()` /
  `setSetting(key, value)` returning the same `{"error":…}` shape as
  everything else, with validation on write (a git path is checked by
  running it; a port is checked for range) rather than on use.
- Existing behaviour becomes persistent as a side effect: the seed chosen
  via `setRemoteSeed` should survive restart, which today it does not.

## The configuration panel

Backed by `node/config.rs`'s real fields — nothing invented:

- **Identity**: alias, NID/DID (read-only, copyable), change passphrase.
- **Tools**: path to the git executable (blank = auto-detect), with the
  resolved path and version shown, validated on save. The IDE convention,
  for the reasons above.
- **Network**: inbound on/off + port (`listen`), `externalAddresses`,
  persistent peers (`connect`) — the AGENTS.md "persistent peers" pattern
  is a documented real-world need, not hypothetical.
- **Seeding**: seeded RIDs with scope, via `Profile::{seed, unseed}`. Given
  the "allow is not enough, you must also seed" gotcha, this panel is the
  fix for a documented footgun.
- **Node control**: start/stop/restart, connection list, sync status. A
  **restart button is not a nicety** — it is the documented remedy for
  stale gossiped addresses, and a user cannot be expected to know that.
- **Diagnostics**: node log tail. CLAUDE.md's own first rule is "before
  anything else, make the failure visible"; a node that won't connect is
  precisely the case where that applies.

## Phasing

**Phase 0 — spike (do this first, it gates everything).** Link
`radicle-node` 0.21.1 into `rust-ffi` with `default-features = false`;
determine whether it exposes a start/stop-able runtime or a `main()`-shaped
one. Confirm `radicle 0.25.1` stays single in the graph. Measure the link
size. **Decide in-process vs. spawned binary on evidence.** If the library
turns out to assume process ownership, fall back to spawning the bundled
binary and the rest of this plan is unchanged apart from packaging.

**Phase 1 — isolation, detection and settings, no daemon yet.** The
settings store (above), `RAD_HOME`/`RAD_SOCKET` plumbing, mode selection,
extended `getCapabilities`, and the `git` preflight plus its configurable
path. Attach mode works end to end. This alone is shippable and useful: it
makes today's M2.1 honest about *which* node it is reading, and makes the
chosen seed survive a restart.

**Phase 2 — embedded lifecycle.** Wizard, `Profile::init`, start/stop, the
config panel's read-only half.

**Phase 3 — writes.** Folds in M2.2a (issues, comments, labels) now that a
signer and passphrase flow exist. M2.2's own open question — "does this
module own a passphrase prompt?" — is answered yes by M3: an embedded node
has no ssh-agent and no CLI session to borrow one from.

**Deferred:** patch open/update (needs the `git` push path proven),
delegate/identity management (M2.2 #9, unchanged).

## Relationship to the existing M2.2 proposal

`docs/M2.2-write-features-proposal.md` explicitly ruled `rad auth` out of
scope — "Radicle assumes the user already has an identity and a running
node… M2.2 should assume a signer already exists and surface a clear error
if it doesn't, not offer to create one."

**M3 deliberately reverses that call**, on the user's instruction that
manual `rad` setup is the actual pain. Worth flagging plainly rather than
quietly contradicting a checked-in document: that paragraph should be
amended when M3 is accepted, and its reasoning was sound given its
assumption — it just took "the user manages their own node" as fixed, which
is the very thing M3 changes.

M3 is best sequenced **before or alongside M2.2a**, not after: M2.2's
unresolved signing-UX question is a strict subset of M3's Phase 2/3, and
answering it twice would be waste.

## What still needs verifying (honest list)

- **Whether `radicle-node`'s library target is drivable in-process.**
  Phase 0. This is the one genuine unknown; everything else above is
  confirmed source or a design choice.
- **`git` availability inside a shipped Basecamp bundle.** Testable now,
  and worth testing early since it constrains all write features.
- **How a configured git path reaches the transport.** The crate spawns the
  bare name `git`, so an absolute path has to be honoured by controlling
  the child's `PATH`. Confirm in Phase 0 whether that is a one-line env
  tweak or needs a wrapper around the spawn path.
- Whether the node needs the passphrase at *start* or only at *sign* time —
  determines whether the wizard can start a node without prompting.
- Windows/macOS: `radicle-node` has `uds_windows` and `radicle-windows`
  deps, so it is not Linux-only, but this repo has only ever built and
  tested Linux. Out of scope to support; worth not accidentally
  hard-coding against.

## Testing, per this repo's own rules

CLAUDE.md's standing lesson — *a check that cannot fail is worth no more
than one that cannot pass* — bites hard here, because a node is stateful,
networked and slow. Concretely:

- **Rust layer**: `Profile::init` into a `tempfile` home, assert a real NID
  and a real storage tree. Already the pattern in `tests/local_storage.rs`.
- **Isolation is the test that matters most**, and it must be
  input-dependent: init *two* profiles in two temp homes and assert their
  NIDs **differ** and neither wrote to the other. A fixture with one home
  cannot tell isolation from its absence — the same trap as the
  branch-switch fake that returned identical data for every branch.
- **Never point a test at the developer's real `~/.radicle`.** The existing
  `probe_*` examples do, deliberately, and are correctly not tests; keep
  that line.
- **The git-path setting needs a negative test, or it proves nothing.** A
  test that configures a valid git and sees success passes equally against
  a resolver that ignores the setting and falls back to `PATH` — the
  same-answer-for-every-input trap. Pin it with a path that does **not**
  exist and assert the failure names that path, plus one that points at a
  real-but-not-git binary and assert `git --version` validation rejects it.
- **e2e**: `run-local-e2e.sh` already passes `--env RAD_HOME=…`. An embedded
  node is *easier* to test than the current setup, because the spec can
  create a throwaway home instead of depending on the developer's profile —
  which may finally let local browsing into CI, closing the gap CLAUDE.md
  records as the reason `local.yaml` is hand-run only.
