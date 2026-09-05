# The `local*` write path

Read this when touching `cobwrite.rs`, `LocalWriter`, `CommentComposer.qml` or
`NewIssueForm.qml`, or when adding a write action of your own.

**[`M2.2-write-actions-design.md`](M2.2-write-actions-design.md) is the primary
document** — it covers signing (the four signer states and why the common case
needs no passphrase prompt, with the probe that tells you which state a machine
is in), what a COB write does on disk and on the network, the API shape, and
what is deliberately out of scope. Read it first; it is more precise than any
summary, and it cites the crate source.

This file is the part that is not in it: what implementing the design taught,
which by definition was not knowable when the design was written.

## What shipped

Two writes, each a full vertical slice: **`localCommentOnIssue`**
(`CommentComposer.qml` in `ThreadView`) and **`localCreateIssue`**
(`NewIssueForm.qml`, from a "New issue" button on the Issues tab). Both run
Rust (`cobwrite.rs`) → FFI → `LocalWriter` → `radicle_impl` → `.rep` → QML,
with tests at every layer.

## The rules that came out of building it

**Gate every write affordance on `canWriteLocal`, never on `localAvailable`.**
A profile can exist while its key stays locked. Stated in `radicle_impl.h` too,
because offering a compose box that cannot be submitted loses whatever the user
typed — the one failure this surface must not have. It is also why
`CommentComposer` keeps its draft on failure, and why a successful post
*reloads* the thread rather than appending locally: an append renders correctly
whether or not the write landed, which is the branch-switch fake trap wearing
different clothes.

**A save that has not been announced says so.** Both composers carry a
`queuedNotice` in `Theme.warn` — not `Theme.bad`, because nothing went wrong
and there is nothing to retry. Checked as `announced === false`, not for
falsiness: an older backend omitting the field means "no claim made", and
inventing a warning from a missing field would alarm the user about nothing.

**Creating an issue must drop the cache before reloading.** `IssuesTab` is
cache-first, so `RepoView.onCreated` calls `issues.reset()` and *then* `load()`.
A plain `load()` serves the page from before the create and the new issue is
simply absent — a screen that looks like it worked while showing stale data.
Pinned by a test that fails against a plain `load()`.

**`IssuesTab`/`PatchesTab` had no `count` property**, yet `RepoView` and
`Main.qml` had read `issues.count` / `patches.count` since they were written —
all four were `undefined`, so a spec asserting `issueCount > 0` would have
compared against undefined. Nothing noticed, because no spec asserted on them
and `CommitsTab` had the equivalent all along. Worth knowing as a class: **a
`readonly property` alias to a child that does not exist fails silently in
QML.**

**`cobwrite.rs` is separate from `cobs.rs` on purpose.** `cobs.rs` opens every
store with `ReadOnly`, a unit struct holding no signer, and that is what lets
local browsing work offline with an encrypted key. Putting a write beside it
would turn a guarantee you can check by reading one file into one you have to
check per function. Same reason `LocalWriter` is not a few more methods on
`LocalReader`.

## `write.yaml` runs in CI against a profile seeded for the run

The obstacle was never the spec but the profile: a write needs a **signable
key**, a runner has none, and pointing the spec at a developer's real profile is
not an option for something that appends a COB comment on every run — COBs have
no delete, so those would accumulate forever.

So the profile is built for the run. `cargo run --example seed_write_profile`
creates a keystore, one repository, and one issue with one comment through the
radicle crate's public API — no network, no `rad` binary, no daemon, because a
COB write is local. That is what makes it affordable in CI at all. Its keystore
is **plaintext** (`Profile::init` with no passphrase), the only signer state
reachable without prompting a human or putting a passphrase in the environment,
and it is what makes `canWriteLocal` true there. The key is generated from a
fixed seed into a runner directory destroyed with the runner: a fixture, not a
credential.

Two details that will bite anyone editing that job. The seeder **refuses an
existing directory** rather than clearing one, so a mistyped path can never
land on somebody's `~/.radicle`. And the seeded home reaches the module only
through `--env RAD_HOME=…`, gated on `matrix.spec == 'write'` — the read specs
must *not* be handed a profile they have no use for. See [`e2e.md`](e2e.md) for
why every local spec needs `RAD_HOME` at all.

Do not read green component tests as covering this wiring. They structurally
cannot.

## `objectName`s the write surface exposes

For whoever extends the specs: `commentComposer`, `commentComposerPanel`,
`commentField`, `commentSubmit`, `composerError`, `composerQueuedNotice`,
`composerUnavailable`; `newIssueButton`, `newIssueForm`, `newIssueTitle`,
`newIssueDescription`, `newIssueSubmit`, `newIssueCancel`, `newIssueError`,
`newIssueQueuedNotice`, `newIssueUnavailable`. Each sits on the clickable
element, not its parent. `Main.qml` re-exports `composerVisible`,
`canCreateIssue` and `newIssueOpen` for `state:` assertions, since a spec
cannot reach into a `StackLayout` child.
