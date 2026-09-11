## Context

See `proposal.md` — Why. This change writes specs for code that already
shipped, so its Decisions are **migrated** rather than made: they were taken
during Phase 0, Phase 1 and Phase 2 steps 1-2, and recorded until now only in
commit messages and in `docs/M3-embedded-node-plan.md`. Collecting them here is
the point of the exercise, because the archive is where this flow expects a past
decision to be found.

Two constraints shape everything below, and both were measured rather than
assumed:

- **The control socket is a Unix domain socket capped at 108 bytes**
  (`sun_path`). Basecamp's dev-profile data dir measures 166 bytes, 192 with the
  node's socket suffix — 84 bytes over before any code runs. This is the same
  cap that once made every Basecamp module segfault.
- **`git` the binary is a runtime dependency of any push into Radicle storage**,
  reached through six bare-name spawn sites across `radicle` and `radicle-node`,
  and the process's own `PATH` is the only channel that reaches all six.

## Goals / Non-Goals

**Goals:**

- State the behaviour contract for the shipped M3 surface, so Phase 2 steps 3
  and 4 have something to build and review against.
- Record, in one findable place, the decisions these increments took and what
  the alternatives were.
- Surface anything the code decided that no requirement states.

**Non-Goals:**

- **No behaviour change.** A defect found while specifying is reported, not
  fixed. Fixing one here would put a behaviour change inside a change whose
  whole premise is that it has none, and neither half could then be reviewed.
- Not specifying the node runtime or the wizard: that behaviour does not exist
  yet, and a requirement no test can cover is worse than none.
- Not reconciling `docs/M3-embedded-node-plan.md` with the code. That document
  is frozen research; where it disagrees with what shipped, the code is the
  truth and the disagreement is noted rather than edited away.

## Decisions

### The socket is resolved independently of the home

**Chosen:** two separate resolutions — `resolveHome(...)` and
`resolveSocket(...)`, combined by `resolvePaths(...)` into a `NodePaths`.

**The constraint that forced it:** the plan proposed that the socket follow the
home. Measured against Basecamp's real per-profile layout, that fails by 84
bytes before any code runs.

**Alternatives, and what ruled them out.** *Socket derived from the home* —
measured as unusable, above. *Shortening the home* — the home is legitimately
long and is where per-profile separation comes from; shortening it to suit a
socket inverts the dependency. *Letting the kernel report it* — the kernel's
error names neither the path, its length, nor the limit, which is what makes
this failure expensive to diagnose.

`resolveSocket` therefore prefers `$XDG_RUNTIME_DIR/radicle-<profile>.sock`,
short by construction and scoped per session, and falls back to
`<home>/node/control.sock` only when there is no runtime dir — because that is
where a hand-run `rad` node puts its socket, and `local` mode must still find
it.

**What it costs:** two resolutions to keep in step instead of one, and a
fallback branch that exists solely for compatibility with a node this module
did not start. It also leaves the profile name unplumbed (see Open Questions).

**The inversion worth noting:** the same cap that killed "the socket follows the
home" is what makes "the home lives wherever it likes" safe. Because the socket
is chosen independently and prefers a short directory, a long home cannot reach
it — 166 bytes is far over the cap for a socket and entirely ordinary for a
directory.

### Resolution is pure functions taking arguments, not environment reads

**Chosen:** the resolvers take `configuredHome`, `radHomeEnv`, `userHomeEnv`
(and the socket's equivalents) as parameters, with a single
`resolvePathsFromEnv()` as the one place that consults the environment.

**The constraint:** mode selection needs to point the module at a home other
than the one the environment names, and `LocalStore` resolved the home inside
its constructor.

**Alternatives:** *resolve in the constructor and pass overrides* keeps the
environment read tangled with object construction, so the precedence rules stay
untestable. *Set environment variables before constructing* makes a test mutate
process-global state, which is exactly the shape that makes parallel tests
flaky.

**What it bought, concretely:** the precedence branches became testable, and
each is pinned by a **different** expected answer rather than one input reused.
Two cases exist only to catch the same-answer-for-every-input trap — two
profiles must get two different sockets in one runtime dir, and a store handed a
home that disagrees with the environment must use the one it was handed.
Verified by mutation: making `resolveSocket` ignore its `profile` argument turns
three tests red, and restoring it returns the suite to green.

This is also why Phase 2 step 1 needed no refactor commit ahead of it. Phase 1
had already made the room, deliberately.

### Settings are validated on write, and live in the module's own directory

**Chosen:** a module-owned JSON file under Basecamp's per-profile XDG data dir,
with validation at `setSetting` time — a git path by running its `--version`, a
socket path against the 108-byte cap, a mode against the known set.

**Alternatives:** *`~/.radicle/config.json`* belongs to the node, carries the
node's schema and the profile's lifetime, and does not exist at all in `explore`
mode. *Validate on use* defers the failure to the moment the user is no longer
looking at the field they typed into — and this repo keeps getting bitten by
deferred failure. Refusing while they are still looking at it is the whole
point.

**What it costs:** validation that runs a binary is slower than a syntax check,
and a setting can still go stale after it was validated (a git binary can be
removed later).

**A side effect worth naming:** the chosen seed now survives a restart, which it
did not before — `setRemoteSeed` previously mutated an in-memory field.

### The git path is one `PATH` write at init, and restart-to-apply

**Chosen:** resolve and write the process's `PATH` once at module init, before
any thread starts. The settings UI states that the change applies on restart.

**The constraint:** Phase 0 found six bare-name spawn sites rather than one, so
there is no single spawn path to wrap; `GIT_EXEC_PATH` is wrong on two counts
(it names git's helper directory, not the binary, and the node's own sites
`env_clear()` and re-admit only `PATH`); and a `PATH` write is process-global,
so it must happen before threads exist.

**Alternatives:** *wrap the spawn sites* — there are six, in a dependency.
*Write `PATH` on every change* — a process-global mutation racing live threads.

**What it costs:** a setting that does not take effect immediately. That is
stated on screen rather than implied, because **a setting that silently does
nothing until an unstated later moment is worse than one that states its
terms.**

An explicit path **overrides detection entirely**, with no fallback to `PATH`:
a silent fallback makes a typo look like a Radicle bug.

### Modes: `explore` means no local home at all

**Chosen:** `explore` builds `LocalStore` with empty paths, so `localAvailable`
is false even when a perfectly good profile exists.

**Alternative:** *`local` with the local parts hidden* — rejected because a user
who chose `explore` has said they do not want this module touching a local
profile. Hiding the controls while still reading the profile does the thing they
declined.

### "Startable" is a build fact about resolving a home, not a live daemon

**Chosen:** `startableModes()` reports whether this build can resolve a home it
can work against. Whether a daemon answers is `localNodeRunning`, a live socket
probe with a different lifetime.

**The constraint that forced the distinction:** turning Embedded on required
saying what "on" meant. Left implicit, `startableModes()` would have stayed
false for Embedded until the node runtime landed, and the UI would have gone on
saying "not implemented" about a mode that fully works short of a daemon.

**What it costs:** two fields that sound alike and are not, which is a naming
hazard the specs have to state plainly.

### Mode and source are one question, not two

**Chosen:** one three-valued setting; the segment control **is** the mode, and
the `remote*`/`local*` method prefix is **derived** from it in `SourceState.qml`.

**The constraint:** the view carried its own `source` (`remote`/`local`) picked
with a toggle, while the mode was picked in Settings. The header ended up
showing a two-segment source control, an identity badge in mode vocabulary and a
seed picker in one undifferentiated row, which a user reported as
unintelligible.

**Alternative:** *keep them separate and document the mapping* — two controls
for one question, free to drift, and the drift is invisible until someone reads
the header.

**What it costs:** a rename on either side is a rename on both. And `local`
remains both a mode name and the `local*` method prefix — a near-collision kept
deliberately rather than tidied, because the prefix is derived from the mode and
`embedded` also routing to `local*` is what makes that visible.

**What it bought:** whatever cannot be said in a segment is said in a caption
under the control, always visible. The tooltip it replaced was anchored past the
bottom of a fixed-height bar, where `z` cannot lift an item over another
parent's later sibling, so it rendered as an unreadable sliver.

### The embedded home is derived only from the module's data dir

**Chosen:** `<XDG data dir>/radicle-module/embedded-home`, via the same
`moduleDataDir()` the settings file uses. `embeddedHomeFor()` reads only that —
never `RAD_HOME`, never `$HOME/.radicle`.

**Why share the derivation:** it makes the per-Basecamp-profile separation of
one the separation of the other **by construction**, so alice and bob cannot
come to disagree about which home belongs to which. Two functions kept in step
would be a thing to keep in step.

**What it buys:** there is no branch by which Embedded could reach the user's
own profile. That absence is the mode's whole promise made structural, and it is
what the tests lead with.

**What it costs:** an absence is invisible in review — nothing points at the
branch that is not there, which is why it is recorded here.

### Identity creation refuses an occupied home, with no `force`

**Chosen:** `createEmbeddedIdentity` refuses rather than overwrites, and there
is deliberately no `force` parameter.

**The stake:** the signing key **is** the identity. Every repository delegating
to it becomes unreachable if it is replaced.

**Alternative:** *a `force` flag* — no caller legitimately wants to destroy a
key, so the flag's only function would be to make the destructive path
reachable.

Neither identity method takes a home argument, and that is a **safety property
rather than a convenience**: a home crossing the QtRO boundary would give a
sandboxed view a way to point key creation at the user's real Radicle home.

### The isolated node's separate identity is accepted, not designed around

**Chosen:** a fully isolated embedded node has its own NID/DID. For a user who
already runs `rad`, it is **a new machine joining their network**.

**What it buys:** isolation by construction — no shared storage, no shared
socket, no port contention, and no possibility of corrupting an identity the
user depends on.

**What it obliges:** the consequence must be **stated, never silent**. The
failure this design is most exposed to is a user believing they operate as their
existing DID while operating as a fresh one, and not understanding why their
private repositories are missing. Which is why the NID is read from the
**public** half of the keystore: the identity stays visible when the key is
locked, the case where a user is most likely to be confused about which identity
they hold.

**Rejected non-goals that follow:** do not offer to copy or move an existing
Radicle home into the embedded one, and do not offer to import the user's
existing secret key. Both sound helpful; both risk corrupting a real identity or
duplicating a key across two nodes writing one storage. A user who wants their
existing identity should choose `local`.

### Ordering: the dependency cost is its own commit

**Chosen:** identity creation (needs only the `radicle` crate already depended
on) and the embedded home landed before the node runtime, which is the whole of
the dependency cost.

**The constraint:** Phase 0 measured that adding the runtime takes `Cargo.lock`
from 208 to 319 packages, none of which the default build compiles — and that a
stale `flake.nix` vendor hash broke the Nix build while `cargo build`, `cargo
clippy` and `cargo test` all stayed green.

**Alternative:** *one Phase 2 commit* — a +111-crate dependency review and a
keygen review in one diff, where neither can be read for itself, and the
identity work held hostage to the vendoring work.

The home and the `startableModes()` flag **had to land together**, in the other
direction: adding the mode before it had a home would have told four screens at
once that Embedded works while the backend handed it nothing.

## Risks / Trade-offs

- **A spec written from shipped code can canonise a defect** → the specs are
  written from the code *and its tests*, and anything the code decides that no
  requirement would naturally state is reported as a gap rather than written up
  as a requirement. The reviewers are told the same.
- **A retrospective spec can drift from a plan document nobody edits** →
  `docs/M3-embedded-node-plan.md` is explicitly frozen as research and marked
  superseded; where it and the code disagree, the disagreement is reported.
- **"Startable" and "running" sound alike** → the specs state both and the
  difference in their lifetimes, because the names alone will not carry it.
- **The git setting can go stale after validation** → validated on write and
  surfaced in the capability report, so a later breakage shows up in
  diagnostics rather than at the moment of a first push.

## Migration Plan

None. No code changes, no data migration, nothing to roll back beyond reverting
the specs. `docs/PLAN.md` sheds the behaviour these specs now state, per the
flow's shedding rule.

## Open Questions

Deferrable without changing these specs, the approach, or the tasks:

- **Whether the node needs the passphrase at start or only at sign time.** Only
  the node runtime can settle it, and nothing in this change depends on the
  answer. The neighbouring half is already settled: an encrypted profile cannot
  write without its passphrase, and an unencrypted one is immediately signable.
- **Whether the Basecamp profile name can be plumbed through to the socket.**
  Today it is not, so the socket falls back to an unscoped name and two profiles
  sharing a runtime dir would collide; `radSocket` is the escape hatch, which is
  why that setting exists rather than being derived. The step that actually
  binds the socket should revisit it.
- **Whether `git` is available inside a shipped Basecamp bundle.** Testable now
  and constrains every write feature, but not a question about the behaviour
  specified here.
