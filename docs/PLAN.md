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
  times out with "All seeds timed out". The surface that removes this is
  specified in `node-seeding` and **built** — `listSeeded`, `seedRepo`,
  `unseedRepo`, against the policies database. The capability also requires a
  view to state both halves; what is ahead is the panel that shows it.
- A fresh node's routing table may list only the public community seeds, so
  `rad clone` fails with "no seeds found" while connected to a peer holding the
  data. The fix is an explicit `--seed <NID>`.
- Stale gossiped addresses make a node dial a peer's NAT address forever. The
  fix is a **daemon restart**, which no error message suggests — which is why
  the config panel's restart button is not a nicety.

### Still ahead

~~**Node start/stop (Phase 2 step 3).**~~ **Shipped.** `startNode`, `stopNode`
and `getNodeStatus` run `radicle-node` in-process. What it settled, and the
traps it found — a runtime that leaks threads if dropped, a 30-second blocking
`is_running()`, `running` versus `serving` as separate questions because a
node's threads are outside `guarded()`'s reach — are in
[`rust-ffi.md`](rust-ffi.md) and
[`M3-embedded-node-plan.md`](M3-embedded-node-plan.md).

~~**The wizard (Phase 2 step 4).**~~ — **specified** in `embedded-setup`: four
steps in a fixed order, what each preflight finding blocks, the consequences the
flow must state at the moment the user decides, and — since the flow first
shipped with no host at all — where it is reached from, what raising it does to
the surfaces around it, where a reopened flow lands, and what ends it.

**It does setup only**, which is the scope correction dogfooding forced: it does
not start the node and does not show the DID. Those recur and are wanted at
arbitrary later moments respectively, so neither is a thing done once at setup
time, and a flow was the wrong shape for both.

~~**What a user sees on picking Embedded.**~~ — **specified** in
`embedded-state`: seven states derived from the backend's replies, each with its
own sentence and its own action, plus the guard that stops a list request going
to a mode with no node to ask. It exists because making Embedded startable
deleted the dead-end panel and the fetch guard together — they were keyed on the
same flag — which is the kind of coupling worth recognising elsewhere, not a
status line. The reasoning is in the `embedded-node-wizard` change's `design.md`.

~~**The mode-detail slot that would show the embedded DID.**~~ — **specified**
in `embedded-header`: every mode with an identity shows it, in full and
copyable, by one rule rather than a list of modes. `NodeIdentity.qml` already
renders exactly that and already sits in the slot, so this is one condition, not
a component.

**Still ahead on that surface:** the header caption. `SourceToggle.note`'s
Embedded branch still reads "not available in this version yet", which is false.
It is a different item from the DID slot — it carries its own height reservation
through a caption sizer — and was deliberately not folded in.

~~**Starting an existing node.**~~ — **specified** in `embedded-state`, and it
is where the wizard's start step went. An unencrypted key starts its node when
Embedded is opened; an encrypted one gets a passphrase field on that surface.
This **overturned** a decision recorded during the change that the node never
starts automatically — the reasoning that fell, and why, is in the
`embedded-node-wizard` change's `design.md`.

What unblocked it is a core change: `getEmbeddedIdentity()` now reports
`encrypted`, observed from the key rather than echoed from an argument. Without
it a surface could neither know to prompt nor know it may skip prompting.
`getCapabilities().canWriteLocal` does not substitute — it probes the home of
the *mode in force*, so it says nothing about the embedded home from another
mode, and it conflates encryption with a missing or unreadable key.

**Restarting is still ahead**, and belongs to the configuration panel: it is a
stop followed by a start whose two refusals are different sentences, and nothing
sequences the pair. The state surface names it without enabling it.

**Hosting an action is one property plus a branch — not one property.** The flag
(`embeddedStartHosted` and its siblings) decides only whether the control renders
*enabled*; the host's routing decides whether the resulting request reaches
anything. `routesEmbeddedAction()` reads the same flags, so the enablement and
the routing cannot disagree — but the branch that actually carries an act out
still has to be written in the same change that flips the flag, or the panel
offers an enabled control whose click is dropped. That is the dead end
`embedded-state`'s spec exists to remove, and an earlier version of this
paragraph said "one property… the panel needs no edit" in a way that invited
exactly it. `test_every_hosted_kind_is_one_the_host_routes` is what holds the two
together. **This now applies to restart**, start having been hosted.

**The configuration panel (Phase 2 step 4).** QML only, and what makes that
true is now the `node-config` and `node-seeding` capabilities rather than the
identity pair alone.

One scope change worth naming, because the wizard's step list used to carry it:
**the inbound opt-in is the panel's, not the wizard's.** The reasoning is in
the `embedded-node-wizard` change's `design.md`, under "The network step has no
inbound control, and says so".

The panel is backed by real fields, nothing invented: identity (alias, NID/DID
read-only and copyable, change passphrase); tools (the git path, blank meaning
auto-detect, with resolved path and version shown); network (inbound on/off plus
port, `externalAddresses`, and the peers to stay connected to); seeding (seeded
RIDs with scope, which is the fix for the allow-is-not-enough footgun); node
control (start/stop/restart, connections, sync status); and diagnostics (node
log tail, because making the failure visible is this repo's first rule).

~~The read/write surface those fields need~~ — **built.** The node's own
`config.json` (`alias`, `listen`, `externalAddresses`, `connect`, `peers`) and
the per-repo seeding policies are a module surface in the `node-config` and
`node-seeding` capabilities, with the git path's negative cases added to
`module-settings`. Which store each of those lives in, and why the two answer
"when does this apply" differently, is in the `embedded-node-config` change's
`design.md`.

What remains ahead here is the **panel itself** — QML only, plus the parts that
are not configuration: node control's restart button, the connections list, sync
status, the log tail, and changing the passphrase.

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

~~**Whether the node needs the passphrase at start or only at sign time**~~ —
**answered, and acted on.** At start; the constraint that followed for the
wizard is discharged, and `embedded-setup` requires the trade to be stated where
the choice is made. The reasoning is in the `embedded-node-wizard` change's
`design.md`.

**A fully isolated embedded node has its own NID/DID**, and for a user who
already runs `rad` it is a new machine joining their network. ~~Why that was
accepted rather than designed around, and the two rejected non-goals that follow
(no copying an existing home, no importing an existing key)~~ — decided and
acted on; the reasoning is in the `m3-embedded-node-foundations` change's
archived `design.md`, and the consequence the UI owes the user is specified in
`source-modes` and `embedded-identity`. The wizard's duty to state it at the
moment a user picks Embedded is now `embedded-setup`'s, at both the embedded
step and the confirm step; nothing about it remains ahead.

~~**`listen: []` is the embedded default, and the UI must be honest about it.**~~
— **built.** Specified in `node-config` and implemented: inbound defaults off, a
configured `listen` is now what the node binds rather than being overridden at
start, and the reported `listening` comes from the addresses actually bound so a
test can tell an honoured configuration from an ignored one. Why the override
had to go at *two* sites rather than one, and what the old code reported for a
port it never tried to bind, is in the `embedded-node-config` change's
`design.md`. The outbound-only consequence — the node can fetch and announce, but
peers cannot fetch *from* it — is a sentence the surface requires a view to
state. What remains ahead is the port field itself.

**Windows and macOS are out of scope to support, and worth not hard-coding
against.** `radicle-node` carries `uds_windows` and `radicle-windows`
dependencies, so it is not Linux-only, but this repo has only ever built and
tested Linux.

**One thing left open on purpose, and step 3 made it worse:** the module is not
told which Basecamp profile it runs under, so the control socket falls back to
an unscoped name, and two profiles sharing a runtime dir collide.
`resolveSocket` supports per-profile naming and its unit tests pin it, but
nothing reaches it in production. **Until step 3 this was two readers probing
one path, which is harmless because neither owns it; now one profile's node
*binds* it, so the second fails to start with an error about a socket in use
rather than about profiles.** The `radSocket` setting is the escape hatch — but
the question of whether the profile name can be
plumbed through.

### Testing it, per this repo's own rules

A node is stateful, networked and slow, which is exactly where a check that
cannot fail is easiest to write:

- **Isolation is the test that matters most, and it must be input-dependent.**
  Init *two* profiles in two temp homes and assert their NIDs differ and neither
  wrote to the other. A fixture with one home cannot tell isolation from its
  absence — the same trap as a fake returning identical data for every branch.
- ~~**The git-path setting needs a negative test or it proves nothing.**~~ —
  the negative cases are now **required by `module-settings`** rather than only
  advised here: a nonexistent path, a real-but-not-git binary, a non-zero exit,
  a relative path, and no fallback to `PATH`. The general lesson stands and is
  why the requirement is written as it is — a test configuring a valid git and
  seeing success passes equally against a resolver that ignores the setting.
- **Never point a test at the developer's real Radicle home.** The `probe_*`
  examples do, deliberately, and are correctly not tests. Keep that line.
- **An embedded node is easier to e2e than the current setup**, because a spec
  can create a throwaway home instead of depending on a developer's profile —
  which may finally let local browsing into CI.

## Known defects in shipped behaviour

**Cancelling a sync does not cancel its requests, and the core module stays
busy for minutes afterwards.** `cancelSync()` in `SourceTab.qml` only bumps
`syncEpoch`, which drops the replies when they arrive. Every `GetTree` and
`GetBlob` the sync already dispatched is still served, one after another, and
any call made after the cancel waits behind them. Measured against a 33-entry
repository on the live seed: a `ListBranches` issued after a cancel took 116 s
to come back. So a user who cancels and then switches branch, opens a file or
polls for staleness sees nothing happen for that long, and nothing says why.

What a fix has to settle:

- **Where the cancel is enforced.** Orphaning replies in QML cannot shorten
  the queue. The requests have to stop being served, which puts the cancel in
  the core module or in how the view dispatches. Dispatching a sync in bounded
  batches, so that a cancel stops the next batch, is a QML-only option.
  Dropping queued calls in the core would mean widening its interface.
- **The spec.** No requirement says what a cancel does to requests already
  sent, or how soon the module answers after one. This is observable
  behaviour, so it belongs in a spec before it is built.
- **The e2e workaround to undo.** `sync.yaml` polls for staleness *before* it
  starts and cancels a sync, because the reverse order waited behind the
  backlog (`scaffold-0-5`, `bc24ded`). Once a cancel really stops the work,
  the spec can go back to the order a user follows, and that order then
  becomes the regression test.

## The Logos stack

**Moving past Basecamp 0.3.0 waits for scaffold.** Newer Basecamp and
module-builder releases exist, but scaffold supports one Basecamp release at a
time. Its Basecamp and `lgpm` pins, and the module-builder generation whose
SDK matches that Basecamp, only work as a set. So
the next stack bump starts from a scaffold release that names a newer
Basecamp, not from the Basecamp release. Scaffold's `DEFAULT_BASECAMP_RELEASE`
in its `src/constants.rs` is the thing to check. The reasoning is in the
`scaffold-0-5` change's `design.md`, Decision 1 (under
`openspec/changes/archive/` once merged). When that bump happens, re-run a
spec on the current sitometres too: 0.1.2 could not drive Basecamp 0.3.0 at
all (`docs/e2e.md`).

## Background documents

`docs/M3-embedded-node-plan.md` and `docs/M3-phase0-findings.md` are the
research this section was distilled from, kept because they cite the crate
source line by line and name where each claim came from, which is what makes
them re-verifiable rather than re-derivable. Read them when you need the
evidence for a claim above; read this file for what is still to do.
