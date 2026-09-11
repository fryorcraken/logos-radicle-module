# PLAN — what is not built yet

This is the forward-looking document: **what this module does not do yet, and
what is known about doing it.** It is read before any design decision, and it is
read from `origin/main` rather than from a branch, because a change designed
against a superseded section is a real defect.

**It is not a record of what landed.** As a change ships, the part of this file
it implements sheds in two directions, and both are someone's job in the same
change:

- **Behaviour → the spec** (`openspec/specs/`). Struck through here, with a
  one-line summary that the thing exists and a pointer.
- **Reasoning → the change's `design.md`**, under Decisions, and *removed* from
  here. Someone investigating a past decision greps
  `openspec/changes/archive/`; that is what the archive is for.

What is left is what is still ahead, plus a line per built area saying it
exists — never why it works that way. Two copies of a rationale drift, and the
wrong one gets read. See [`.claude/agents/README.md`](../.claude/agents/README.md)
for the whole document model.

Sections below that describe shipped work are deliberately thin. If you want to
know *why* something works the way it does, the answer is in the archive or in
the trigger-specific docs, not here.

## What exists today

One line each; the pointer is the detail.

- **Reading, everywhere.** Browsing any public repo through a seed and the same
  surface again against the local node: search, paging, file tree, blob viewer,
  README, commits with diffs, issues and patches with full discussion, branch
  switching, sync-to-cache and staleness detection.
- **Writing, local node only.** Commenting on an issue and creating one, end to
  end. See [`writes.md`](writes.md).
- **The `local*` read path and its FFI boundary.** See
  [`rust-ffi.md`](rust-ffi.md).
- **Three modes — `explore`, `local`, `embedded` — chosen once and visible
  always**, backed by a module-owned settings store that survives a restart,
  plus a `git` preflight with a configurable path. Embedded resolves a home of
  its own and can create an identity without `rad auth`; it has no running
  daemon yet, which is the next section. **The behaviour is specified**, in the
  `source-modes`, `module-settings`, `node-paths` and `embedded-identity`
  capabilities; the decisions behind it are in that change's archived
  `design.md`. Neither is repeated here.
- **The end-to-end layer.** See [`e2e.md`](e2e.md).

Which milestone phases have merged is a `git log` question, not a sentence to
maintain here. This file previously carried per-phase status lines and they went
stale exactly as CLAUDE.md's "Keeping this file true" section predicts.

## M3 — an embedded Radicle node

**The problem.** Setting up `rad` by hand is cumbersome, and today's `local*`
surface assumes the user already did it: install the binaries, `rad auth`, start
a node, wire a systemd unit, get the DID allow-listed, `rad seed` on each peer.
None of that is deducible by a user. The goal is that a user picks "Embedded",
answers a short wizard, and has a working node — with a configuration panel for
what genuinely needs tuning, and no terminal.

Three gotchas measure the size of the problem, and each is a thing the wizard or
the config panel exists to remove:

- `rad init` + `rad id update --allow` is **not enough** to replicate a private
  repo; every other node must *also* `rad seed <RID> --scope all`, or `rad sync`
  times out with "All seeds timed out".
- A fresh node's routing table may list only the public community seeds, so
  `rad clone` fails with "no seeds found" while connected to a peer holding the
  data. The fix is an explicit `--seed <NID>`.
- Stale gossiped addresses make a node dial a peer's NAT address forever. The
  fix is a **daemon restart**, which no error message suggests — which is why
  the config panel's restart button is not a nicety.

### Still ahead

**Node start/stop (Phase 2 step 3).** The one step that needs the
`radicle-node` crate, and therefore the whole of the dependency cost: roughly
+111 crates in `Cargo.lock`, a new `flake.nix` vendor hash, and about +7 MB of
link. It is its own commit for that reason — folding it into a step that also
creates identities would put a large dependency review and a keygen review in
one diff where neither can be read for itself.

The library is drivable in-process: `Runtime::init` / `Runtime::run` /
`Handle::shutdown` is a real lifecycle, the caller supplies the signal channel,
and every process-global act (signal installation, logger, panic hook, `exit()`)
lives in the binary's `main.rs` rather than the library. Measured at 97 ms
start-to-stop.

**The wizard and the configuration panel (Phase 2 step 4).** QML only — the two
module methods it needs (`getEmbeddedIdentity`, `createEmbeddedIdentity`) are
already plumbed through `radicle_ui.rep`.

Six wizard steps, each failing loudly rather than proceeding on a guess:
preflight (is `git` there, is there an existing home, is a node already running
on its socket, can we write our own home — reported *before* offering a choice);
mode, with the identity consequence stated in one sentence each; identity
(alias plus passphrase, defaulting to setting one, with the trade-off stated);
network (inbound off by default, preferred seeds prefilled); start (launch, wait
for the control socket, show the NID, and say why on failure); and confirm,
restating the "this is a new identity" consequence with the
`rad id update --allow <DID>` line ready to copy.

The panel is backed by `node/config.rs`'s real fields, nothing invented:
identity (alias, NID/DID read-only and copyable, change passphrase); tools (the
git path, blank meaning auto-detect, with resolved path and version shown);
network (inbound on/off plus port, `externalAddresses`, persistent peers);
seeding (seeded RIDs with scope, which is the fix for the allow-is-not-enough
footgun); node control (start/stop/restart, connections, sync status); and
diagnostics (node log tail, because making the failure visible is this repo's
first rule).

**Phase 3 — writes against the embedded node.** Folds in the remaining write
features (issues, comments, labels) now that a signer and a passphrase flow
exist. M2.2's open question, "does this module own a passphrase prompt?", is
answered yes: an embedded node has no ssh-agent and no CLI session to borrow one
from.

**Deferred, deliberately:** patch open/update, which needs the `git` push path
proven first, and delegate/identity management.

### Constraints that bind the work still ahead

These are measured, not assumed, and they are here because they constrain a
change nobody has written yet.

**`git` the binary is a runtime dependency, and it is load-bearing.** Radicle's
local git transport does not implement pack protocol in-process — it spawns
`git`, so any push into Radicle storage needs the binary. This is invisible on a
dev box and fatal in a sandboxed bundle, which makes it the single most likely
cause of "works on my machine, mysteriously broken for a user". ~~Why `PATH` is
the only channel that reaches it~~ — acted on and shipped; the six spawn sites,
why `GIT_EXEC_PATH` is not an option, and the process-global ordering constraint
are in [`rust-ffi.md`](rust-ffi.md), which is where the next person to touch
that code will look.

**Whether `git` is available inside a shipped Basecamp bundle is still open.**
Testable now, and worth testing early, since it constrains every write feature.

**Whether the node needs the passphrase at start or only at sign time is still
open** — it determines whether the wizard can start a node without prompting.
The binary's flow reads the secret key up front and fails if it cannot, which
suggests "at start", but that is inference rather than measurement, and only
step 3 can settle it. The neighbouring half *is* settled: an encrypted profile
is unusable for writes without its passphrase, and an unencrypted one is
immediately signable.

**A fully isolated embedded node has its own NID/DID**, and for a user who
already runs `rad` it is a new machine joining their network. ~~Why that was
accepted rather than designed around, and the two rejected non-goals that follow
(no copying an existing home, no importing an existing key)~~ — decided and
acted on; the reasoning is in the `m3-embedded-node-foundations` change's
archived `design.md`, and the consequence the UI owes the user is specified in
`source-modes` and `embedded-identity`. What remains ahead is only that the
wizard must state it at the moment a user picks Embedded.

**`listen: []` is the embedded default, and the UI must be honest about it.** A
node with no listen address is outbound-only: it can fetch and announce, but
peers cannot fetch *from* it. For a desktop user behind NAT that is correct, but
"allow inbound connections" belongs in the panel as an explicit opt-in with a
port field, defaulting off, saying plainly what leaving it off means.

**Windows and macOS are out of scope to support, and worth not hard-coding
against.** `radicle-node` carries `uds_windows` and `radicle-windows`
dependencies, so it is not Linux-only, but this repo has only ever built and
tested Linux.

**One thing left open on purpose:** the module is not told which Basecamp
profile it runs under, so the control socket falls back to an unscoped name, and
two profiles sharing a runtime dir would collide. `resolveSocket` supports
per-profile naming and its unit tests pin it, but nothing reaches it in
production. The `radSocket` setting is the escape hatch — but step 3, which
actually binds the socket, should revisit whether the profile name can be
plumbed through.

### Testing it, per this repo's own rules

A node is stateful, networked and slow, which is exactly where a check that
cannot fail is easiest to write:

- **Isolation is the test that matters most, and it must be input-dependent.**
  Init *two* profiles in two temp homes and assert their NIDs differ and neither
  wrote to the other. A fixture with one home cannot tell isolation from its
  absence — the same trap as a fake returning identical data for every branch.
- **The git-path setting needs a negative test or it proves nothing.** A test
  that configures a valid git and sees success passes equally against a resolver
  that ignores the setting and falls back to `PATH`. Pin it with a path that
  does not exist, asserting the failure names that path, and with a
  real-but-not-git binary, asserting `git --version` validation rejects it.
- **Never point a test at the developer's real Radicle home.** The `probe_*`
  examples do, deliberately, and are correctly not tests. Keep that line.
- **An embedded node is easier to e2e than the current setup**, because a spec
  can create a throwaway home instead of depending on a developer's profile —
  which may finally let local browsing into CI.

## Background documents

`docs/M3-embedded-node-plan.md` and `docs/M3-phase0-findings.md` are the
research this section was distilled from, kept because they cite the crate
source line by line and name where each claim came from, which is what makes
them re-verifiable rather than re-derivable. Read them when you need the
evidence for a claim above; read this file for what is still to do.
