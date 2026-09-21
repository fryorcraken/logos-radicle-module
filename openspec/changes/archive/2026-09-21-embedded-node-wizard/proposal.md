# A guided setup for the embedded node

## Why

Embedded mode is selectable today and, chosen cold, does nothing a user can
account for. The mode persists, `radHome` repoints at a home under the Basecamp
profile's data directory, `localAvailable` goes false, and the repository list
shows an explanation. Everything after that — create an identity, decide whether
to encrypt it, start the node, find out the node binds no port, learn the DID
another machine has to allow — is available only as separate methods with no
order and no screen that names the consequences.

Each of those consequences is a decision the user owes an answer to, and each is
cheapest to state at the moment the choice is made rather than discovered
afterwards:

- **A passphrase means an unlock every time.** `Runtime::init` is handed an
  already-decrypted signing key, so there is no later point at which one can be
  supplied. Encrypting the key is the right default and it makes the node
  un-startable unattended. A user who learns this after the fact has an
  encrypted identity they cannot re-key.
- **This is a new identity, not theirs.** The embedded home is a separate
  Radicle home with a separate DID. Their repositories are not in this storage
  and their allow-listed DID is not this one. Discovered late, it presents as
  missing repositories with nothing on screen to explain them.
- **The node binds no TCP port.** `listen` is empty, so it fetches and announces
  but peers cannot fetch from it. That is right for a desktop behind NAT and it
  is a limitation, not an absence of one.

A wizard is the artifact that can state all three at the moment each applies. It
is also where the preflight belongs: whether `git` resolves, whether the
embedded home is empty, half-created or occupied, and whether a node is already
answering on the resolved socket are all questions whose answers change what may
be offered, and all of them are answerable before anything is written.

**But only setup belongs in it, and a first attempt put two other things there.**
Dogfooding the built flow found both. It had a step that started the node and
then warned, directly above its own report of a running node, that "a node is
already answering on the resolved socket" — a warning about the node it had just
started, which is the same defect as the identity step reporting an existing
identity as a refusal: a correct fact rendered as a hazard when it describes the
user's own success. And it ended with a step whose only act was to be dismissed,
carrying a DID that is wanted at arbitrary later moments rather than once,
behind a screen the user then closes.

Neither is a setup step, and the shape of each says where it goes. Starting
happens every time the mode is opened, for the life of the mode, so it belongs to
the surface that reports the node's state — and where the key is unencrypted the
module can simply do it, because a user who set a node up has already asked for a
running node. The DID belongs in the header beside the mode toggle, where it is
always reachable and where `radicle_impl.h` already requires a view to show it.

**And a wizard nothing reaches is not a fix.** A user who picks Embedded today
gets an empty repository list, a red `no embedded identity yet` banner and the
words "No repositories matched" — which is not a missing wizard but a deleted
dead end. Making Embedded startable made `modeStartable` true, which made
`RepoList.notImplemented` false, which stopped the honest "not available in this
version yet" panel rendering; the same flag was the guard on `RepoList.fetch()`,
so the list then issued `localListRepos` against a home with no identity and
rendered the backend's refusal as an error banner. The guard and the explanation
it protected were keyed on one condition, so both went away together.

That is the regression, and it is separate from the wizard: the screen must say
which of Embedded's states the user is in, and offer the one action that state
admits, before there is anywhere for a setup entry point to live.

## What Changes

- Adds a four-step guided setup for Embedded mode — preflight, embedded,
  identity, network — as a QML flow over the module methods that already exist.
  **The setup sets up and stops.** It does not start the node and does not show
  the DID, because neither is setup: starting is something the mode does every
  time it is opened, and the DID is something the user wants at arbitrary later
  moments, not once behind a screen they then dismiss. A terminal step whose
  only act is to be dismissed is work the flow asks of the user and gives
  nothing back for.
- **Starting moves onto the Embedded surface, and happens by itself where it
  can.** Opening Embedded with an identity and a stopped node starts the node
  without being asked when the key is unencrypted, and asks for the passphrase —
  as one field on that surface, not as a step in a flow — when it is encrypted.
  This reverses a decision recorded during this change that the node never
  starts automatically; what changed is that the reason given for it turned out
  to rest on a gap that is closable, and the cost of the rule was a user being
  told to start a node the module could have started.
- **The DID moves into the header, beside the mode toggle, copyable.** The
  component that renders it for Local already exists and already sits there; in
  Embedded the header shows nothing, which is what `radicle_impl.h`'s "a view
  MUST always show `mode` and `nodeId`" forbids.
- **Adds `encrypted` to `getEmbeddedIdentity()`'s reply** — a core change, in
  `radicle/`, not QML. It is what makes the autostart rule decidable at all; see
  Impact.
- **The flow sets up Embedded and offers no other mode.** A user who opened
  "Set up an embedded node" has already chosen it; Explore and Local need no
  setup at all, and offering them inside a flow whose next four steps are about
  a node neither mode runs is a choice with one permitted answer. Step two
  therefore states what Embedded means and puts it in force, rather than
  presenting the three modes as a pick.
- Each step reports what it found rather than proceeding on an assumption: a
  failed preflight check names the thing that failed and blocks the step it
  gates, rather than being discovered at the identity write or the node start.
- **The identity step has one forward control, three distinct states, and names
  the home it writes to.** Creating the identity *is* how the step is left, so
  offering creation and advancing separately asks a second question with one
  permitted answer. The three states are no identity yet, one this showing
  created, and one that was already there — the third is the state a two-control
  step rendered as a success and a refusal at once, which reads as a failure to a
  user who has simply already done this. And both messages named a DID while
  neither named the path: the embedded home is derived from the Basecamp
  profile's data directory, so a user cannot find or inspect what was created
  from a DID alone, though `getEmbeddedIdentity()` reports the path.
- Pins the three consequences above as requirements about **what the wizard must
  state and when**, not as prose in a design document: the passphrase trade at
  the identity step, the new-identity consequence at both the embedded step and
  the confirm step, and the inbound default at the network step.
- **Replaces the deleted dead end with a state surface.** Embedded's empty
  repository list becomes one of seven states derived from the backend's
  replies, each with its own sentence and its own action — a banner cannot carry
  these, because the states differ in what the user may do next and not only in
  their wording. Two of them are states no field distinguishes on its own: a
  node being started and a node whose threads have died both report
  `running:true, serving:false`, and only the view knows whether a start is
  outstanding.
- **Re-keys the guard that stops a request going to a node that does not
  exist**, from "is this mode startable" to "does this mode have a node to ask".
  Hiding the reply instead is not an option: the reply stays in flight, passes
  the staleness guard, and repopulates the model behind the panel.
- **No module methods are added.** `getCapabilities`, `getSettings`,
  `setSetting`, `getEmbeddedIdentity`, `createEmbeddedIdentity`, `startNode`,
  `stopNode`, `getNodeStatus` and `listKnownSeeds` are all already exposed
  through `radicle_ui.rep`, and the flow is built from them.

Not covered, deliberately:

- **Restarting a node that has stopped serving.** A restart is two calls whose
  refusals are different sentences, and nothing reports the pair; it stays named
  and not enabled on the state surface, as it is today. Starting is now hosted;
  restarting is not, and the two are kept apart rather than folded together
  because only one of them is a single call this change can make.
- **The header caption.** `SourceToggle.note`'s Embedded branch still says "not
  available in this version yet", which is false and on screen. It is a
  different item from the DID slot — it carries its own height reservation
  through a caption sizer — and correcting it here would put two header changes
  in one diff with no test able to separate them. The DID slot is in scope
  because it is the thing `radicle_impl.h` requires and the component for it
  already exists.
- **Stopping the node from any surface.** Setup never stops a node, and neither
  does the state surface; a user who wants the node stopped has no control here.
  That is the configuration panel's, alongside the restart.
- **The configuration panel.** Identity display, git path, network fields,
  seeded RIDs with scope, node control and the log tail are a separate change,
  and it depends on methods that are not merged. The wizard sets a node up once;
  the panel is where it is tuned afterwards. The state surface points at it by
  name only once it exists.
- **Persisting an inbound-connections choice.** The settings store holds five
  keys and none of them describes `listen`, and no method writes a node config.
  The network step therefore states the outbound-only default and offers the
  seeds, and records no inbound setting — see Impact.
- **Changing an existing identity's passphrase**, which is panel work and needs
  a method that does not exist.
- **Switching between the three modes.** That control already exists in the
  header toggle and the settings panel, specified by `source-modes`, and it is
  where a user compares the modes. This flow is entered having chosen one of
  them, so duplicating the comparison here would be a second place stating what
  each mode means, free to drift from the first.

## Capabilities

### New Capabilities

- `embedded-setup`: The guided setup flow for Embedded mode — its four steps and
  their order, what each may do only after the step before it answered, what the
  preflight refuses to offer, and the consequences the flow must state at the
  moment the user decides rather than afterwards. It also owns **where the flow
  is entered from, what raising and lowering it does to the surfaces around it,
  where a reopened flow lands, and what ends it**: the setup is a surface raised
  over the view rather than a navigation destination, mutually exclusive with the
  settings surface, opened only by a user act that names opening it — never by
  selecting Embedded — and, on reopening, re-derived from the backend rather than
  resumed at a remembered step. Owns the wizard's behaviour only; the module
  methods it drives are specified by `embedded-identity`, `source-modes`,
  `module-settings` and `node-paths`.
- `embedded-state`: What the repository list shows in Embedded when there are no
  repositories to show — seven states derived from `getCapabilities()`,
  `getEmbeddedIdentity()` and `getNodeStatus()`, each with its own sentence and
  its own action, and the guard that stops a list request being issued to a mode
  with no node to ask. It also owns **starting the node**: the automatic start
  where the key allows it, the passphrase prompt where it does not, and the rule
  that distinguishes a node this module started from one it merely found.
- `embedded-header`: What the header shows about the identity the module is
  operating as, in every mode that has one. Owns the rule that Embedded's DID is
  shown and copyable exactly as Local's is, and that the two are one surface
  rather than two spellings of one idea.

### Modified Capabilities

- `source-modes`: **"A mode that cannot start asks its node for nothing"** is
  re-keyed. It required a view to decline a request for a mode *the startable
  set omits*, and Embedded is startable — it resolves a workable home — so the
  guard stopped firing for it while the node it would have asked still did not
  exist. The requirement now names both conditions that leave a mode with
  nothing able to answer, and the scenario recorded there as unpinned by a test
  is closed by `embedded-state` rather than left as an annotation.
- `embedded-identity`: **"Reporting what the embedded home holds"** gains an
  `encrypted` field on `getEmbeddedIdentity()`'s reply, observed from the key on
  disk rather than echoed from an argument. This is the change that makes the
  autostart rule decidable at all, and it is the only requirement here that is
  not view behaviour.

`module-settings` and `node-paths` are unchanged: this adds no mode, no setting
and no path resolution. `createEmbeddedIdentity`'s refusals, `startNode`'s mode
restriction and the passphrase rule are consumed as specified.

## Impact

- **No longer view only.** Most of the change is QML under
  `radicle-ui/src/qml/` with component tests beside it, but **`encrypted` on
  `getEmbeddedIdentity()` is a core change** touching `radicle/rust-ffi/`,
  `radicle/src/` and the unit tests — the first requirement in this change that
  is not view behaviour, and the reason this piece can no longer be described as
  QML-only.
- **`radicle_ui.rep` is unchanged.** Every slot on it returns an opaque JSON
  string, so adding a key to `getEmbeddedIdentity()`'s payload crosses the QtRO
  boundary without a signature change. The transport is not what makes this a
  core change; the probe behind it is.
- **The probe itself already exists in-crate and is already used here.**
  `Keystore::is_encrypted()` is called today in the write path to choose a
  signing route, and it reads the stored key without a passphrase, without an
  agent and without loading the private half — so reporting it needs no new
  dependency, no new unlock path, and no weakening of the read path's
  never-touch-the-private-key guarantee. What is new is exposing it, not
  obtaining it.
- Consumes, and does not redefine: `getCapabilities` (`mode`,
  `gitFound`/`gitPath`/`gitProblem`, `radHome`, `radSocket`, `pathsProblem`,
  `localNodeRunning`, `nodeId`, `canWriteLocal`), `getEmbeddedIdentity`,
  `createEmbeddedIdentity`, `startNode`, `getNodeStatus`, `listKnownSeeds` and
  `setSetting("mode", …)`.
- **A gap this change surfaces rather than closes:** there is no way to persist
  an inbound-connections choice or a listen port. `module-settings` fixes the
  store at five keys and none of them is about the node's network config, and no
  method writes `node/config.rs`'s fields. The network step is therefore
  informative plus seed selection, and the inbound opt-in PLAN.md describes
  waits on the panel change that introduces a channel for it. Specifying an
  inbound toggle here would produce a requirement no test could cover.
- `docs/PLAN.md` sheds the wizard's behaviour once this lands; the reasoning
  passages it holds are listed for `design.md` rather than moved here.
