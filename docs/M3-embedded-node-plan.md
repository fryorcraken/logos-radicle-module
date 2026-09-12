# M3 — An embedded Radicle node, set up from inside Basecamp

> **Superseded as the forward-looking document by
> [`docs/PLAN.md`](PLAN.md).** What is still to build, and the constraints that
> bind it, moved there when this repo adopted the spec-driven flow; PLAN.md is
> what the role agents read, and it is the only one of the two that is kept
> current.
>
> **This file is kept as research, and is no longer edited as phases merge.**
> Its value is that every technical claim names where it came from, so a claim
> in PLAN.md can be re-verified here rather than re-derived. Where the two
> disagree, PLAN.md is the live one — and the phase status lines below are
> frozen at the day this was superseded. Ask `git log` instead.

Status: **research, superseded.** Which phases have landed is a `git log`
question, not a sentence to maintain here — this line used to claim "Phases 1-3
are not started" while Phase 1 had shipped, which is the failure mode CLAUDE.md's
"Keeping this file true" section is about.

Every technical claim below was checked against the `radicle 0.25.1` source
vendored in `~/.cargo/registry`, the crates.io API, and the local docs
checkout at `~/src/rad/radicle.xyz` — the places each claim came from are
named inline so the next session can re-verify rather than re-derive.

**Read [`docs/M3-phase0-findings.md`](M3-phase0-findings.md) alongside this
file.** Phase 0 settled the plan's one genuine unknown in favour of an
in-process node, and turned up two constraints this document did not
anticipate (the git `PATH` being process-global, and the control socket's
108-byte path cap). Where the two disagree, the findings doc measured it.

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
means **controlling `PATH`**. The crate offers no hook to inject the binary
directly.

**Phase 0 confirmed this and sharpened it in three ways**
([findings](M3-phase0-findings.md) §5):

- There are **six** bare-name spawn sites across `radicle` and
  `radicle-node`, not one — so there is no single "spawn path" to wrap.
- **`GIT_EXEC_PATH` is not an option.** It names git's *helper* directory
  rather than the binary, and the node's own sites `env_clear()` and
  re-admit only `PATH` (`worker/upload_pack.rs:63-66`), stripping it anyway.
- It is therefore a one-line `PATH` write, but a **process-global** one that
  must happen at module init before any thread starts — which is an ordering
  constraint on Phase 1, and means a settings change may need restart-to-apply.

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

**This needed a spike before being committed to, and the spike has run —
the recommendation stands.** `has_lib: true` proved only that a library
target exists, not that it exposes a clean "run until cancelled" entry
point rather than a `main()`-shaped one owning signal handling and the
process. `radicle-signals` being non-optional looked like a hint that it
might.

It does not. `Runtime::init` / `Runtime::run` / `Handle::shutdown` is a
real lifecycle; the caller supplies the signal channel as an
`mpsc::Receiver<Signal>`, and the library's only use of `radicle-signals`
is that enum as a type — `install()` is called from `main.rs` alone. See
[`docs/M3-phase0-findings.md`](M3-phase0-findings.md) §3 for the citations
and a measured 97 ms in-process start-to-stop. The spawned-binary fallback
is not needed.

### 3. Will it conflict with an installed node?

**Not if we isolate deliberately — and the protocol already gives us every
knob needed.** Three independent resources can collide; all three are
controllable:

| Resource | Default | Collision if shared | How we isolate |
|---|---|---|---|
| **Storage / keys** | `~/.radicle` | Two nodes writing one git storage. **This is the dangerous one** — CLAUDE.md already records step-9 e2e flakes caused by two Basecamps on one `~/.radicle`. | `RAD_HOME` → Basecamp's own XDG dir. `profile.rs:509` `home()` honours it. |
| **Control socket** | `$RAD_HOME/node/control.sock` | Commands sent to the wrong node | `RAD_SOCKET` env var, `profile.rs:48` + `socket_from_env():692`. **Must be set explicitly — letting it follow `RAD_HOME` overshoots the 108-byte `sun_path` cap under Basecamp's per-profile dirs; measured in [findings](M3-phase0-findings.md) §6.** |
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
| **`explore`** | none | none | Browse public repos; the `remote*` path |
| **`local`** | existing `~/.radicle` | Not ours — we detect and use whatever is running | Already has `rad`; M2.1's behaviour |
| **`embedded`** | Basecamp-owned dir | Started/stopped by the module | Has no `rad`, wants it to just work |

**These names are also the UI's.** This document originally called them
Attach / Embedded / Seed-only while the view spoke a second vocabulary — a
`source` of `remote`/`local` — for the same question. The two ended up side
by side in one header bar, which a user reported as unintelligible; the
identity badge in particular was mode vocabulary leaking onto a screen that
otherwise spoke source. Phase 1's UI pass unified them: the stored constant,
the settings-file value, the `getCapabilities()` string, the QML property and
the segment label are all one word. A rename on either side is a rename on
both.

One near-collision to keep in mind rather than tidy away: `local` is both a
mode and the prefix of the `local*` backend methods. They are separate things
that share a word — the method prefix is *derived* from the mode, and
`embedded` also routing to `local*` is what makes that visible.

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
that is `local` mode, which is exactly what `local` is for.

## The wizard

Six steps, each of which fails loudly rather than proceeding on a guess.

0. **Preflight.** Is `git` on PATH (see the caveat above)? Is there an
   existing `~/.radicle`, and is a node already running on its socket? Can
   we write our own home? Report all of it before offering a choice — a
   user with an existing profile should be *told* so, and offered `local`,
   not silently given a second identity.
1. **Mode.** Explore / Local / Embedded, with the identity consequence
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

**Phase 0 — spike. ✅ DONE — see
[`docs/M3-phase0-findings.md`](M3-phase0-findings.md).** Linked
`radicle-node` 0.21.1 into `rust-ffi` with `default-features = false` and
answered all five questions on evidence. **Outcome: in-process, as
proposed.** The library exposes a genuine start/stop lifecycle,
`radicle 0.25.1` stays single, systemd is excluded, and the link costs
+7.05 MB. The fallback to a spawned binary is not needed.

Two findings change Phase 1's shape rather than the plan's: the git path is
a process-global `PATH` write ordered before any thread starts (not a
per-spawn wrapper), and the control socket's 108-byte `sun_path` cap
constrains where `RAD_HOME` may live. Both are in the "still needs
verifying" list below, marked resolved.

**Phase 1 — isolation, detection and settings, no daemon yet. SHIPPED.** The
settings store (above), `RAD_HOME`/`RAD_SOCKET` plumbing, mode selection,
extended `getCapabilities`, and the `git` preflight plus its configurable path.
`local` mode works end to end. This alone is shippable and useful: it makes
M2.1 honest about *which* node it is reading, and makes the chosen seed survive
a restart.

> **That last clause is false, and is corrected here rather than left for a
> reader to trip over.** The settings *store* survives a restart; the seed
> picker does not use it. `setRemoteSeed` probes and adopts but never persists,
> `setSetting("remoteSeed", …)` persists but never probes, and the UI calls the
> first. This sentence is the origin of a claim that was later copied into a
> design document before review caught it — which is why it is annotated in
> place, even though this file is otherwise frozen. See the
> `module-settings` capability and task 4.1 of the
> `2026-09-12-m3-embedded-node-foundations` change.

Six things Phase 1 settled that this document had left open or got wrong.
Recorded so Phase 2 does not re-litigate them:

- **The socket is chosen independently of the home**, as
  [findings](M3-phase0-findings.md) §6 required — this document's "socket
  follows the home" proposal was measured against Basecamp's real per-profile
  paths and does not fit. `resolveSocket()` prefers
  `$XDG_RUNTIME_DIR/radicle-*.sock` and falls back to
  `<home>/node/control.sock` only when there is no runtime dir, because that is
  where a hand-run `rad` node puts its socket and `local` mode must still find
  it. The resolved path is length-checked, and the message names the path, its
  length **and** the limit — the kernel's own error names none of the three.
- **`cobwrite.rs`'s announce step honoured neither `RAD_SOCKET` nor the
  setting.** It hardcoded `<home>/node/control.sock`, so against any node with
  a relocated socket the announce silently went nowhere. That failure was
  invisible by construction: an unannounced write is legitimately *not* an
  error (the node announces on next start), so nothing surfaced. Fixed, with a
  regression test watched failing first.
- **The git path is restart-to-apply**, not live — see
  [`rust-ffi.md`](rust-ffi.md). `PATH` is the only channel reaching all six
  spawn sites and writing it is process-global, so it happens once at init. The
  settings UI states this rather than implying the change is immediate.
- **Embedded was selectable and persisted, but reported as not startable**, with
  a reason naming the milestone, and the mode row said so. Hiding it would have
  misrepresented the module as never intending to support it; offering it
  silently would have been a control that does nothing. **The prediction that
  `SettingsStore::startableModes()` would be the one line that changes held
  exactly** — step 2 turned the mode on by adding one entry, and edited no QML
  at all. Which is also the trap it left: a change that touches no view can
  break no view test, so a green QML suite proved nothing about the mode being
  on. `tst_embedded_real.qml` exists to close that.
- **`explore` means no local home at all**, not "`local` with the local parts
  hidden". A user who chose it has said they do not want this module touching a
  local profile, so `LocalStore` is built with empty paths and
  `localAvailable` is false even when a perfectly good profile exists.
- **Mode and source were the same question asked twice, and collapsing them was
  the fix for a header nobody could read.** The view carried its own
  `source` (`remote`/`local`) picked with a toggle while the mode was picked in
  Settings, so the header showed a two-segment source control, a
  `Attached · z6Mko…` identity badge in mode vocabulary, and a seed picker, in a
  row with no separation. The user read the run of them as one control with a
  dead third segment. Now: **one three-valued setting, and the segment IS the
  mode**; the `remote*`/`local*` method prefix is derived from it in
  `SourceState.qml` so the two cannot drift, and the thing beside the toggle is
  the *detail of whichever mode is selected* — the seed for `explore`, the
  identity for `local`, nothing for `embedded`, which has no node yet. Whatever
  cannot be said in a segment is said in a caption line under the control,
  always visible: the tooltip it replaces was anchored past the bottom of a
  fixed-height bar, where `z` cannot lift an item over another parent's later
  sibling, so it rendered as an unreadable sliver.

**Still open, deliberately:** the module is not told which Basecamp profile it
runs under, so the socket falls back to an unscoped `radicle.sock` and two
profiles sharing a runtime dir would collide. `radSocket` is the escape hatch,
and is why that setting exists rather than being derived — but Phase 2, which
actually binds the socket, should revisit whether the profile name can be
plumbed through.

**Phase 2 — embedded lifecycle.** Wizard, `Profile::init`, start/stop, the
config panel's read-only half. **In progress; steps 1 and 2 below have landed.**

The three are separable, and the order below is chosen by what it costs the
*build* rather than by what reads best as a feature. The dividing line is
`radicle-node`:

| Step | Needs `radicle-node`? | What it costs |
|---|---|---|
| 1. `Profile::init` behind the FFI | **No** — `Profile::init` is in `radicle`, already a dependency | nothing: no manifest, lock or vendor-hash change |
| 2. The embedded home, and making the mode startable | No | nothing |
| 3. Node start/stop | **Yes** | `Cargo.lock` +111 crates, a new `flake.nix` vendor hash, +7 MB link |
| 4. Wizard and config panel | No | QML only |

**Step 3 is the whole of the dependency cost, and it is why it is its own
commit.** Phase 0 recorded that adding two optional dependencies took the lock
from 208 packages to 319, none of which the default build compiles, and that
the stale vendor hash broke the Nix build while `cargo build`, `cargo clippy`
and `cargo test` all stayed green ([findings](M3-phase0-findings.md) §4).
Folding that into a commit that also creates identities would put a +111-crate
dependency review and a keygen review in one diff, where neither can be read
for itself — and would make the *identity* work hostage to the vendoring work.

**Step 1 is the feature, not the refactor.** There is no refactor commit ahead
of it, and that is a finding rather than an omission: Phase 1 already made the
room. `resolvePaths()` split home and socket resolution into pure functions,
`storeForSettings()` named every mode explicitly with an inert default, and
`startableModes()` was deliberately left as the single line Phase 2 changes.
The awkwardness CLAUDE.md's "make the change easy" rule looks for is not
present, because the previous phase removed it on purpose.

**Step 2 was where the ordering constraint bit, and it held.** `startableModes()`
is the one line that turns Embedded on, and `tst_embedded.qml` pinned that the
whole UI derives from it — the not-implemented state, the list request, the
paging. Adding `kModeEmbedded` there before there was a home to point at would
have made every one of those derive to "startable" against a mode with no
profile, which is the identity-confusion failure `storeForSettings()`'s Embedded
paragraph exists to prevent. So the home and the flag landed together.

Four things step 2 settled, recorded because a later step could otherwise
re-open them:

- **The embedded home is `<XDG data dir>/radicle-module/embedded-home`**,
  derived by the same `moduleDataDir()` the settings file uses. Sharing that
  derivation is what makes the per-Basecamp-profile separation of one the
  separation of the other, by construction rather than by two functions kept in
  step. `embeddedHomeFor()` reads only the data dir — never `RAD_HOME`, never
  `$HOME/.radicle` — so there is no branch by which Embedded could reach the
  user's own profile. That absence is the mode's promise made structural, and
  `the_embedded_home_is_never_the_users_own_radicle_home` pins it.
- **The 108-byte cap does not constrain the home, only the socket**, and this is
  the fact that makes the placement safe rather than reckless. §6's measurement
  (166 bytes under Basecamp's layout) is far over the cap for a socket and
  entirely ordinary for a directory — and `resolveSocket()` already prefers
  `$XDG_RUNTIME_DIR` precisely so a long home cannot reach it. The constraint
  that killed "the socket follows the home" is the one that makes "the home
  lives wherever it likes" work.
- **"Startable" means the mode resolves a home this module can work against —
  not that a daemon runs in it.** That distinction had to be made explicit, or
  `startableModes()` would have stayed false for Embedded until step 3 and the
  UI would have kept saying "not implemented" about a mode that fully works
  short of a node. Whether a daemon answers is `localNodeRunning`, a live socket
  probe with a different lifetime: this set is a build fact and never moves at
  runtime.
- **`LocalStore` did not learn about modes.** It gained a
  `NodePaths::absentProfileReason` instead, because the default sentence ends
  "run `rad auth`" — right for a home the user manages, exactly wrong for the
  mode whose premise is that they never do. Putting a mode switch inside
  `LocalStore` would have moved mode vocabulary into a class about paths and
  made every future mode edit it; carrying the sentence with the paths keeps the
  mode-specific decision where the mode is already known.

Step 2 added the two module methods step 1 deliberately deferred —
`getEmbeddedIdentity()` and `createEmbeddedIdentity(alias, passphrase)` — and
plumbed both through `radicle_ui.rep`, so **step 4's wizard is a QML-only
change** exactly as the table says. Neither takes a home, which is a safety
property rather than a convenience: a home argument crossing the QtRO boundary
would be a way for a sandboxed view to point key creation at the user's real
`~/.radicle`.

Two things step 1 deliberately did **not** do, both of which step 2 then did:

- **No module method.** `radicle_impl.h` gained nothing, because a wizard
  cannot call this until there is an embedded home to create *into*, and that
  path was step 2's to define. Exposing an RPC method whose only sensible
  argument does not exist yet would be API written against a caller nobody can
  write.
- **Embedded stayed unstartable.** Not because creating an identity is not
  running a node — step 2 settled that "startable" was never about the daemon —
  but because a mode with no home of its own genuinely could not start.

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

**Phase 0 ran and resolved the first three.** Details, commands and source
citations are in [`docs/M3-phase0-findings.md`](M3-phase0-findings.md); the
one-line answers are here so this list stays readable.

- ~~**Whether `radicle-node`'s library target is drivable in-process.**~~
  **RESOLVED: yes.** `Runtime::init` + `Runtime::run` + `Handle::shutdown`
  is a real start/stop lifecycle, and every process-global act — signal
  installation, logger, panic hook, `exit()` — lives in `radicle-node`'s
  `main.rs`, not in the library. The `radicle-signals` hint was a false
  alarm: the library uses only the `Signal` enum as a type. Proven by
  running a node start-to-stop in 97 ms in-process.
- ~~**Confirm `radicle 0.25.1` stays single in the graph**, and that
  `default-features = false` excludes systemd.~~ **RESOLVED: both hold.**
  One `radicle`, one `git2`, one `libgit2-sys`; `radicle-systemd` is not in
  the graph at all. Link cost measured at **+7.05 MB**.
- ~~**How a configured git path reaches the transport.**~~ **RESOLVED, and
  it changes the answer above.** It is the process's own `PATH` — *not*
  `GIT_EXEC_PATH`, which is both the wrong variable and stripped by the
  node's own env filter. There are **six** bare-name spawn sites, not one,
  so a wrapper "on the spawn path" is not available. It is a one-line
  `set_var`, but a **process-global** one that must run at module init
  before any thread starts. See the findings doc before designing the
  settings panel's git field.
- **NEW — socket path length constrains where `RAD_HOME` can live.** The
  node's control socket is a Unix domain socket capped at 108 bytes
  (`sun_path`), and `Home::socket_default()` adds 17 of them. A home under
  this repo's own worktree already overshoots at 114 bytes and
  `Runtime::init` fails with an error naming neither the path nor the limit.
  This is the same cap that once made every Basecamp module segfault and is
  why `runtime_dir` is pinned in `scaffold.toml`. **Measured against
  Basecamp's own profile dirs, this document's "socket follows the home"
  proposal fails** — 192 bytes in the dev-profile layout, ~20 bytes of slack
  in the installed one — so `RAD_SOCKET` is a Phase 1 requirement, not an
  escape hatch, and the socket wants a short home of its own
  (`$XDG_RUNTIME_DIR` is the obvious candidate). ~~Phase 1 still owes a length
  check with a real error message, since the crate's names neither the path
  nor the limit.~~ **That landed.** `resolvePaths()` performs it and its
  message names the path, its length *and* the limit; `SettingsStore::set()`
  checks the `radSocket` setting again at set time, which is not redundant —
  a socket can also arrive from the environment, which the store never sees.
  Both read `kSunPathMax`, so the two cannot come to disagree about the number.
- **`git` availability inside a shipped Basecamp bundle.** Still open.
  Testable now, and worth testing early since it constrains all write
  features — now with six spawn sites behind it rather than one.
- Whether the node needs the passphrase at *start* or only at *sign* time —
  determines whether the wizard can start a node without prompting. Phase 0
  only exercised an *unencrypted* key, which starts with no prompt.
  `main.rs:291-325` reads the secret key up front and fails if it cannot,
  which suggests "at start" — but that is inference from the binary's flow,
  not a measurement, so **the question about starting stays open** until step 3
  links the runtime and tries it.

  What Phase 2 step 1 *did* settle is the neighbouring half, which was being
  assumed rather than measured: an encrypted profile really is unusable for
  **writes** without its passphrase, and an unencrypted one really is
  immediately signable. `profile_init.rs` asserts both directions through
  `can_write` — the only observation that distinguishes the two from outside,
  since it needs the private half. That matters for the wizard because it makes
  "offer a passphrase, default to setting one" a choice with a stated
  consequence the module can actually demonstrate, rather than a claim about
  behaviour nobody had run.
- Windows/macOS: `radicle-node` has `uds_windows` and `radicle-windows`
  deps, so it is not Linux-only, but this repo has only ever built and
  tested Linux. Out of scope to support; worth not accidentally
  hard-coding against. Phase 0 measured Linux x86_64 only.

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
