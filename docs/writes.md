# M2.2 — the first write actions

Read this when touching the `local*` **write** path — `cobwrite.rs`,
`LocalWriter`, `CommentComposer.qml`, `NewIssueForm.qml` — or adding a write
action of your own. Full design in
[`M2.2-write-actions-design.md`](M2.2-write-actions-design.md); the parts below
are the ones that change what a future session should assume.

### Signing needs no passphrase prompt in the ordinary case

The M2.2 proposal recorded that Radicle Desktop prompts for the `rad`
passphrase on startup, and concluded a passphrase-entry UI belonged in the
first cut. **That is too strong.** `Profile::signer()` picks from three
sources, so there are four states, not two:

| Keystore | `RAD_PASSPHRASE` | agent holds the key | Signer? |
|---|---|---|---|
| plaintext | — | — | yes, no prompt |
| encrypted | set | — | yes, no prompt |
| encrypted | unset | yes | **yes, no prompt** |
| encrypted | unset | no | no — a prompt is genuinely needed |

The third row is the ordinary post-`rad auth` state: `rad auth` puts the key in
ssh-agent and it stays there for the session. `cargo run --example probe_signer`
reports which row a machine is in; on the machine this was built on, writes are
signable with no prompt. Basecamp inherits `SSH_AUTH_SOCK` from the session, so
the agent path works from inside the module.

So the prompt is **deferred, not skipped**: `getCapabilities().canWriteLocal`
is now a real probe rather than the hardcoded `false` it had been since M1, and
`writeUnavailableReason` names the fix. Building the prompt later fills in the
fourth row and changes no API.

### A COB write is local; announcing is separate and non-fatal

Confirmed by reading the crate, because it decides whether writes need the
daemon: there is **no `announce` anywhere under `radicle-0.25.1/src/cob/`**.
`store.create(...)` / `issue.comment(...)` append a signed operation to the DAG
in local storage and return, so **writes work with the node stopped** — the
same offline promise M2.1's reads make.

Announcing is a separate control-socket round-trip
(`Handle::announce_refs_for`, one call). Its failure is reported *alongside* a
successful write, never instead of one:

```json
{"id":"…","announced":false,"announceError":"the local node is not running"}
```

A COB written but not announced is an ordinary state — the node announces on
next start — so calling it a failed write would make the user post twice.
`Node::announce` (the richer one) blocks on an event stream until seeds
acknowledge; do not reach for it from a synchronous FFI call.

No `sign_refs` step is needed either. The test fixture calls it after a raw
`git push` into storage because that push bypasses the crate; the COB store
signs as part of the operation.

### What shipped, and the rule that came with it

Two writes, each a full vertical slice: **`localCommentOnIssue`**
(`CommentComposer.qml` in `ThreadView`) and **`localCreateIssue`**
(`NewIssueForm.qml`, reached from a "New issue" button on the Issues tab).
Both go Rust (`cobwrite.rs`) → FFI → `LocalWriter` → `radicle_impl` → `.rep` →
QML, with tests at every layer.

**A save that has not been announced now says so.** Both composers carry a
`queuedNotice` in `Theme.warn` — not `Theme.bad`, because nothing went wrong
and there is nothing to retry. Checked as `announced === false`, not for
falsiness: an older backend omitting the field means "no claim made", and
inventing a warning from a missing field would alarm the user about nothing.

**`IssuesTab`/`PatchesTab` had no `count` property**, yet `RepoView` and
`Main.qml` had read `issues.count` / `patches.count` since those were written —
all four were `undefined`, and a spec asserting `issueCount > 0` would have
compared against undefined. Nothing noticed because no spec asserts on them and
`CommitsTab` has had the equivalent all along. Fixed in both, with a regression
test. Worth knowing as a class: a `readonly property` alias to a child that
does not exist fails silently in QML.

**Creating an issue must drop the issue cache before reloading.**
`IssuesTab` is cache-first, so `RepoView.onCreated` calls `issues.reset()` and
*then* `load()`. A plain `load()` serves the page from before the create and
the new issue is simply absent — a screen that looks like it worked while
showing stale data. Pinned by a test that fails against a plain `load()`.

**Gate every write affordance on `canWriteLocal`, never on `localAvailable`.**
A profile can exist while its key stays locked. This is stated in
`radicle_impl.h` as well, because offering a compose box that cannot be
submitted loses whatever the user typed — the one failure this surface must not
have. It is why `CommentComposer` also keeps its draft on failure, and why a
successful post *reloads* the thread rather than appending locally (an append
renders correctly whether or not the write landed — the branch-switch fake trap
in different clothes).

Deferred with reasons in the design doc: commenting on a patch (needs
revision-thread *reads* first — `get_patch` does not serialize them, so a patch
comment would have nowhere to appear), close/reopen, labels and assignees,
patch review, and the passphrase UI.

**`objectName`s the write surface exposes**, for whoever writes the e2e specs:
`commentComposer`, `commentComposerPanel`, `commentField`, `commentSubmit`,
`composerError`, `composerQueuedNotice`, `composerUnavailable`;
`newIssueButton`, `newIssueForm`, `newIssueTitle`, `newIssueDescription`,
`newIssueSubmit`, `newIssueCancel`, `newIssueError`, `newIssueQueuedNotice`,
`newIssueUnavailable`. Each sits on the clickable element, not its parent.
`Main.qml` re-exports `composerVisible`, `canCreateIssue` and `newIssueOpen`
for `state:` assertions, since a spec cannot reach into a `StackLayout` child.

### `write.yaml` runs in CI against a profile seeded for the run

This section once said no write spec existed. It does now (PR #16), and it is
in the `ui-tests.yml` matrix alongside `browse`/`branches`/`source`/`sync`.

The obstacle was never the spec but the profile: a write needs a **signable
key**, a runner has none, and pointing the spec at a developer's real profile
is not an option for something that appends a COB comment on every run — COBs
have no delete, so those would accumulate forever.

So the profile is built for the run. `cargo run --example seed_write_profile`
creates a keystore, one repository, and one issue with one comment through the
radicle crate's public API — no network, no `rad` binary, no daemon, because a
COB write is local. That is what makes it affordable in CI at all. Its keystore
is **plaintext** (`Profile::init` with no passphrase), the only one of the four
signer rows above reachable without prompting a human or putting a passphrase
in the environment, and it is what makes `canWriteLocal` true there. The key is
generated from a fixed seed into a runner directory destroyed with the runner:
a fixture, not a credential.

Two details that will bite anyone editing that job. The seeder **refuses an
existing directory** rather than clearing one, so a mistyped path can never
land on somebody's `~/.radicle`. And the seeded home reaches the module only
through `--env RAD_HOME=…`, gated on `matrix.spec == 'write'` — the four read
specs must *not* be handed a profile they have no use for. See
[`e2e.md`](e2e.md) for why every local spec needs `RAD_HOME` at all.

Still true regardless: do not read green component tests as covering the
wiring. They structurally cannot.

### `cobwrite.rs` is separate from `cobs.rs` on purpose

`cobs.rs` opens every store with `ReadOnly`, a unit struct holding no signer,
and that is what lets local browsing work offline with an encrypted key.
Putting a write beside it would turn a guarantee you can check by reading one
file into one you have to check per function. Same reason `LocalWriter` is not
a few more methods on `LocalReader`.

## M2.1 — scope and FFI decision, 2026-09-03
