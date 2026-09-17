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

## What Changes

- Adds a six-step guided setup for Embedded mode — preflight, embedded,
  identity, network, start, confirm — as a QML flow over the module methods that
  already exist.
- **The flow sets up Embedded and offers no other mode.** A user who opened
  "Set up an embedded node" has already chosen it; Explore and Local need no
  setup at all, and offering them inside a flow whose next four steps are about
  a node neither mode runs is a choice with one permitted answer. Step two
  therefore states what Embedded means and puts it in force, rather than
  presenting the three modes as a pick.
- Each step reports what it found rather than proceeding on an assumption: a
  failed preflight check names the thing that failed and blocks the step it
  gates, rather than being discovered at the identity write or the node start.
- Pins the three consequences above as requirements about **what the wizard must
  state and when**, not as prose in a design document: the passphrase trade at
  the identity step, the new-identity consequence at both the embedded step and
  the confirm step, and the inbound default at the network step.
- **No module methods are added.** `getCapabilities`, `getSettings`,
  `setSetting`, `getEmbeddedIdentity`, `createEmbeddedIdentity`, `startNode`,
  `stopNode`, `getNodeStatus` and `listKnownSeeds` are all already exposed
  through `radicle_ui.rep`, and the flow is built from them.

Not covered, deliberately:

- **The configuration panel.** Identity display, git path, network fields,
  seeded RIDs with scope, node control and the log tail are a separate change.
  The wizard sets a node up once; the panel is where it is tuned afterwards.
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

- `embedded-setup`: The guided setup flow for Embedded mode — its six steps and
  their order, what each may do only after the step before it answered, what the
  preflight refuses to offer, and the three consequences the flow must state at
  the moment the user decides rather than afterwards. Owns the wizard's
  behaviour only; the module methods it drives are specified by
  `embedded-identity`, `source-modes`, `module-settings` and `node-paths`.

### Modified Capabilities

None. The wizard consumes the four existing capabilities and changes no
requirement in any of them. In particular it adds no mode, no setting and no
identity behaviour — `createEmbeddedIdentity`'s refusals, `startNode`'s
mode restriction and the passphrase rule are consumed as specified.

## Impact

- **View only.** New QML under `radicle-ui/src/qml/`, plus component tests under
  `radicle-ui/tests/`. No change to `radicle/`, to `radicle_ui.rep`, or to the
  Rust staticlib.
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
