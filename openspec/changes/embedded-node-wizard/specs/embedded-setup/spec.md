## Purpose

Define the guided setup a user walks through to bring the embedded node into
existence: the six steps and their order, what each step may do only once the
step before it has answered, and the three consequences the flow MUST state at
the moment the user decides rather than leave to be discovered afterwards — that
a passphrase means an unlock on every start, that the embedded identity is a new
DID rather than the user's own, and that the node accepts no inbound
connections.

**This flow sets up Embedded mode and nothing else.** A user who opened it has
already chosen Embedded, so the flow states what Embedded means and lets them
proceed or leave. It MUST NOT offer Explore or Local as alternatives within
itself: those two need no setup, choosing either abandons every step that
follows, and a flow that offers a mode it then refuses to continue from is
presenting a choice with one permitted answer.

## ADDED Requirements

### Requirement: Six steps in a fixed order

The setup MUST present exactly six steps, in this order: preflight, embedded,
identity, network, start, confirm. The step in force MUST be observable, and
MUST be preflight when the flow is first shown.

When advancing is permitted, it MUST move to the next step in the sequence and
MUST NOT skip one. When it is not permitted — the requirements below name every
case — it MUST leave the step in force unchanged rather than move. Going back
MUST move to the previous step and MUST NOT be offered on the first step.

Going back MUST NOT undo anything an earlier step already performed. Identity
creation and node start are not reversible through this flow, so a step that has
performed one MUST report what it did when it is returned to, rather than
offering to do it again.

#### Scenario: The flow opens on preflight

- **WHEN** the setup flow is shown for the first time
- **THEN** the step in force MUST be the preflight step
- **AND** the control for going back MUST NOT be enabled

#### Scenario: Advancing walks the sequence without skipping

- **GIVEN** a flow whose every step is permitted to advance
- **WHEN** advance is invoked five times from the preflight step
- **THEN** the step in force after each invocation MUST be, in order, embedded,
  identity, network, start and confirm
- **AND** a sixth invocation MUST leave the step in force at confirm

#### Scenario: Going back returns to the previous step

- **GIVEN** the step in force is the network step
- **WHEN** back is invoked
- **THEN** the step in force MUST be the identity step
- **AND** invoking back again MUST make the step in force the embedded step

#### Scenario: Returning to a step that already acted does not offer to act again

- **GIVEN** an identity step that has created an identity, reported by the
  backend as `exists:true` with a node id
- **WHEN** the step in force returns to the identity step
- **THEN** the control that creates an identity MUST NOT be enabled
- **AND** the created node id MUST be displayed

### Requirement: The preflight reports four findings before offering a choice

The preflight step MUST report four findings, each separately and each named,
before the flow offers any choice that depends on it:

- whether a `git` executable resolves, from `getCapabilities().gitFound`;
- whether the embedded home already holds an identity, from
  `getEmbeddedIdentity().exists`, and its node id when it does. This finding
  MUST NOT claim the home is empty when `exists` is false: a half-created home
  reports `exists:false` too, and the two are indistinguishable through this
  reply;
- whether a node is already answering on the resolved socket, from
  `getNodeStatus().serving`;
- whether the module can resolve a home to write into at all, from a non-empty
  `getEmbeddedIdentity().home` together with an empty
  `getCapabilities().pathsProblem`.

Each finding MUST be rendered as its own outcome rather than folded into a
single pass/fail, so a user sees which one failed.

A finding that failed MUST name what failed. Where the backend supplied a
sentence — `gitProblem`, `pathsProblem`, or `getEmbeddedIdentity().problem` —
that sentence MUST be displayed verbatim rather than replaced with the flow's
own wording, because those sentences name the path that was tried and the limit
that was exceeded.

The preflight MUST NOT write anything: it MUST NOT call
`createEmbeddedIdentity`, `startNode` or `setSetting`.

#### Scenario: Four findings are reported separately

- **GIVEN** a backend reporting `gitFound:true`, an embedded home that is empty,
  `serving:false` and an empty `pathsProblem`
- **WHEN** the preflight step completes
- **THEN** four findings MUST be displayed
- **AND** each MUST report its own outcome

#### Scenario: One failing check is distinguishable from another

- **GIVEN** a backend reporting `gitFound:false` with a non-empty `gitProblem`,
  and every other check passing
- **THEN** the git finding MUST be displayed as failed
- **AND** the other three findings MUST NOT be displayed as failed
- **AND WHEN** the backend instead reports `gitFound:true` with a non-empty
  `pathsProblem` and every other check passing
- **THEN** the paths finding MUST be displayed as failed and the git finding MUST
  NOT be

#### Scenario: No identity yet is not reported as an empty home

- **GIVEN** a backend whose `getEmbeddedIdentity()` reports `exists:false` with
  an empty `problem`
- **THEN** the identity finding MUST report that no identity exists
- **AND** it MUST NOT state that the home is empty
- **AND WHEN** the backend reports `exists:true` with a node id
- **THEN** the identity finding MUST report that one exists, carrying that node
  id

#### Scenario: A backend sentence is shown unaltered

- **GIVEN** a backend reporting `gitFound:false` with `gitProblem` set to a
  distinctive sentence
- **THEN** that sentence MUST appear in what the preflight displays

#### Scenario: The preflight writes nothing

- **WHEN** the preflight step runs to completion against any backend
- **THEN** no `createEmbeddedIdentity` call MUST have been issued
- **AND** no `startNode` call MUST have been issued
- **AND** no `setSetting` call MUST have been issued

### Requirement: A failed preflight blocks the step it gates and says which

A preflight finding that failed MUST block advancing past the step whose work it
makes impossible, and the flow MUST state which finding is blocking rather than
presenting a disabled control with no reason.

An unresolvable home, and a home already holding a complete identity, MUST both
block the identity step: the first because there is nowhere to write, the second
because `createEmbeddedIdentity` refuses an occupied home.

A half-created home MUST NOT block the identity step. `getEmbeddedIdentity()`
reports it as `exists:false`, which the preflight cannot distinguish from an
empty home through that reply alone, and the backend's refusal is the only
surface that names the `keys` path to remove. Submitting creation and displaying
that refusal is therefore how the user learns the recovery — which is the
general rule the refusal requirement below states, applied here.

A missing `git` MUST block the start step, and MUST NOT block the identity step:
identity creation writes key material and does not spawn `git`.

A node already answering on the resolved socket MUST block the start step, and
MUST NOT block the identity step.

Blocking MUST be keyed on the finding, so that a backend reporting the finding
as passing removes the block with nothing else changed.

#### Scenario: A missing git blocks start but not identity

- **GIVEN** a preflight reporting `gitFound:false` and every other check passing
- **THEN** advancing from the identity step MUST be permitted
- **AND** the control that starts the node MUST NOT be enabled
- **AND** the displayed reason MUST name the git finding

#### Scenario: An occupied home blocks identity creation

- **GIVEN** a preflight whose `getEmbeddedIdentity()` reports `exists:true`
- **THEN** the control that creates an identity MUST NOT be enabled
- **AND** the displayed reason MUST state that an identity already exists

#### Scenario: A half-created home is offered creation, and its refusal shown

- **GIVEN** a preflight whose `getEmbeddedIdentity()` reports `exists:false`
  with an empty `problem`, over a home the backend will refuse as half-created
- **THEN** the control that creates an identity MUST be enabled
- **AND WHEN** creation is submitted and the backend refuses with a message
  naming a `keys` path to remove
- **THEN** that message MUST be displayed verbatim
- **AND** the flow MUST NOT report the identity as created

#### Scenario: A node already serving blocks start

- **GIVEN** a preflight reporting `serving:true`
- **THEN** the control that starts the node MUST NOT be enabled
- **AND** the displayed reason MUST state that a node is already answering on
  the socket

#### Scenario: A block lifts when its finding passes

- **GIVEN** a flow whose start step is blocked because the preflight reported
  `gitFound:false`
- **WHEN** the same flow is given a preflight reporting `gitFound:true`, with
  nothing else changed
- **THEN** the control that starts the node MUST be enabled

### Requirement: The embedded step confirms Embedded and states the identity consequence

The embedded step MUST state what Embedded mode is — this module keeps its own
Radicle home and runs the node itself — and MUST state, in the step itself,
that the node operates as a **new identity this module creates**, separate from
any Radicle node the user already runs and from any identity they already hold.

That statement MUST NOT be deferred to the confirm step: the confirm step
restates it with the DID that by then exists, and a statement made only after
the identity has been created is made after the decision it informs.

The step MUST NOT offer `explore` or `local`. It MUST NOT present the modes as a
set to pick from, and it MUST NOT annotate a mode as unavailable, whatever
`getCapabilities().startableModes` reports: the flow sets up one mode, so it has
no unstartable alternative to caption. A user who does not want Embedded leaves
the flow through the control that closes it, which every step already offers.

This step is therefore not a mode picker, so `source-modes`' requirement that a
view annotating which modes are available consume `startableModes` does not
reach it — that requirement binds the header toggle and the settings panel,
which are where a user compares the three.

Forward out of this step MUST be an act the user performs rather than a
consequence of arriving: the step MUST offer a control that puts Embedded in
force, and the mode MUST NOT be written by the step being shown. A mode written
on arrival would put a module into Embedded because the user opened a screen,
and leaves the stated consequence something they were shown rather than
something they answered.

That control MUST persist Embedded through `setSetting("mode", "embedded")`, and
MUST NOT record the flow's own copy of the mode in force — `source-modes`
already requires that of any control that changes the mode. What the step
reports as the mode in force MUST come from `getCapabilities().mode`.

Going back and closing the flow remain available here as on any other step.
Leaving this step by either route MUST leave the mode in force exactly where it
was, so a user who opened the flow and thought better of it is in the mode they
started in.

Advancing past the embedded step MUST require that `getCapabilities().mode`
reports `embedded`: the four steps after it are about a node no other mode runs,
and a backend that has not reported `embedded` has not confirmed the write
landed. A refused `setSetting` MUST therefore leave advancing refused, and the
refusal MUST be displayed.

Returning to this step once Embedded is in force MUST report that it is, and
MUST NOT offer to put it in force again. Unlike identity creation and node
start, the mode write is idempotent, so this is about not asking a question the
backend has already answered rather than about preventing a second act — which
is why the statement of what Embedded means stays displayed either way.

#### Scenario: The step states Embedded's separate identity

- **WHEN** the embedded step is shown
- **THEN** the displayed text MUST state that this module runs a node of its own
- **AND** it MUST state that the node operates as a new identity, separate from
  any Radicle node the user already runs

#### Scenario: The separateness statement precedes any identity write

- **WHEN** the embedded step is shown
- **THEN** the separate-identity statement MUST be visible
- **AND** no `createEmbeddedIdentity` call MUST have been issued

#### Scenario: No other mode is offered, whatever the startable set reports

- **GIVEN** an embedded step told a `getCapabilities().startableModes`
  containing `explore`, `local` and `embedded`
- **THEN** no control selecting `explore` MUST be present
- **AND** no control selecting `local` MUST be present
- **AND** no text MUST be displayed stating that a mode cannot be started
- **AND WHEN** the same step is told a `startableModes` containing `embedded`
  alone
- **THEN** what is displayed MUST be unchanged

#### Scenario: Arriving at the step writes no mode

- **GIVEN** a flow whose `getCapabilities().mode` is `local`
- **WHEN** the step in force becomes the embedded step
- **THEN** no `setSetting` call MUST have been issued
- **AND** the mode in force MUST still be `local`

#### Scenario: Going back from the step writes no mode

- **GIVEN** an embedded step where `getCapabilities().mode` is `local` and the
  control putting Embedded in force has not been invoked
- **WHEN** back is invoked
- **THEN** no `setSetting` call MUST have been issued
- **AND** the mode in force MUST still be `local`

#### Scenario: The step's control puts Embedded in force

- **GIVEN** an embedded step where `getCapabilities().mode` is `local`
- **WHEN** the control that puts Embedded in force is invoked, against a backend
  that accepts the write and then reports `embedded`
- **THEN** exactly one `setSetting` call MUST have been issued, with key `mode`
  and value `embedded`
- **AND** the mode in force MUST be `embedded`
- **AND** advancing MUST be permitted

#### Scenario: The mode in force is the reply, not the value written

- **GIVEN** an embedded step where `getCapabilities().mode` is `local`
- **WHEN** the control that puts Embedded in force is invoked against a backend
  that accepts the write but goes on reporting `local`
- **THEN** the mode in force MUST be `local`
- **AND** advancing MUST NOT be permitted

#### Scenario: A refused mode write neither advances nor moves the mode in force

- **GIVEN** an embedded step where `getCapabilities().mode` is `local`
- **WHEN** the control that puts Embedded in force is invoked against a backend
  that refuses the write with a distinctive message
- **THEN** that message MUST be displayed
- **AND** the mode in force MUST still be `local`
- **AND** advancing MUST NOT be permitted
- **AND** the step in force MUST still be the embedded step

#### Scenario: Returning with Embedded already in force does not re-offer it

- **GIVEN** an embedded step where `getCapabilities().mode` reports `embedded`
- **THEN** the control that puts Embedded in force MUST NOT be enabled
- **AND** the text stating that this is a new, separate identity MUST still be
  displayed
- **AND** advancing MUST be permitted

### Requirement: The identity step states the passphrase trade where it is chosen

The identity step MUST take an alias and a passphrase, and MUST offer setting a
passphrase as the default: the control MUST arrive in the state that leads to an
encrypted key, so that leaving it alone produces the safer outcome.

The step MUST state, visibly at the moment the passphrase choice is offered and
not only after it is made, that an encrypted key must be unlocked every time the
node is started — the node is handed an already-decrypted signing key when it is
built, so a passphrase cannot be supplied later — and that an unencrypted key
starts the node with no prompt at the cost of a secret stored in plaintext.

Both halves of that trade MUST be stated. A statement naming only the security
benefit, or only the unlock cost, is a recommendation rather than a trade, and
the user cannot weigh it.

The statement MUST be visible for both settings of the control, so a user who
turns the passphrase off sees what they gave up and what they gained.

The alias MUST be submitted to `createEmbeddedIdentity` as the user typed it.
The flow MUST NOT pre-validate it against its own rule: `embedded-identity`
requires the backend to pass through the `radicle` crate's own statement of the
rule, and a second rule in the view would drift from it.

#### Scenario: A passphrase is the arriving default

- **WHEN** the identity step is shown for the first time
- **THEN** the control choosing whether to set a passphrase MUST be in the state
  that sets one

#### Scenario: Both halves of the trade are stated before the choice is made

- **WHEN** the identity step is shown, before the passphrase control is touched
- **THEN** the displayed text MUST state that the node must be unlocked each
  time it starts when a passphrase is set
- **AND** it MUST state that an unencrypted key stores a secret in plaintext

#### Scenario: The trade stays stated when the passphrase is turned off

- **GIVEN** an identity step whose passphrase control has been turned off
- **THEN** the displayed text MUST still state both halves of the trade

#### Scenario: An unencrypted identity is created with an empty passphrase

- **GIVEN** an identity step with alias `tester` and the passphrase control
  turned off
- **WHEN** creation is submitted
- **THEN** exactly one `createEmbeddedIdentity` call MUST have been issued
- **AND** its alias argument MUST be `tester`
- **AND** its passphrase argument MUST be the empty string

#### Scenario: A set passphrase is the one passed through

- **GIVEN** an identity step with alias `tester`, the passphrase control set,
  and a passphrase of `correct horse battery`
- **WHEN** creation is submitted
- **THEN** the `createEmbeddedIdentity` call's passphrase argument MUST be
  `correct horse battery`

#### Scenario: A rejected alias is reported from the backend, not pre-empted

- **GIVEN** an identity step whose alias contains whitespace
- **WHEN** creation is submitted against a backend that refuses it with a
  distinctive message
- **THEN** a `createEmbeddedIdentity` call MUST have been issued
- **AND** the backend's message MUST be displayed

### Requirement: The network step states outbound-only as the default in force

The network step MUST state that the embedded node accepts no inbound
connections: it can fetch from peers and announce to them, and peers cannot
fetch from it. That MUST be presented as the setting in force, not as a
recommendation or as a choice the user is about to make.

The step MUST state the consequence rather than only the configuration. A user
reading "no listen address" cannot derive "another machine cannot clone from
this one"; the second sentence is the one that decides whether the default is
acceptable to them.

The step MUST offer the seeds `listKnownSeeds()` reports, with the built-in
public seeds among them, so a node that cannot be fetched from can still fetch.

The step MUST NOT offer a control that enables inbound connections. No module
method persists a listen address, so a toggle here would record nothing and the
node would keep binding no port — a control that silently does nothing is worse
than none. The step MUST instead say that enabling inbound connections is not
available in this flow, so the absence is stated rather than left to look like
an oversight.

#### Scenario: The outbound-only default and its consequence are both stated

- **WHEN** the network step is shown
- **THEN** the displayed text MUST state that the node accepts no inbound
  connections
- **AND** it MUST state that peers cannot fetch from this node

#### Scenario: The reported seeds are the ones offered

- **GIVEN** a network step told a `listKnownSeeds()` reply naming two seeds
- **THEN** both seeds MUST be offered
- **AND WHEN** the step is told a reply naming a different, single seed
- **THEN** exactly that one MUST be offered

#### Scenario: No inbound control is offered and the absence is stated

- **WHEN** the network step is shown
- **THEN** no control enabling inbound connections MUST be present
- **AND** the displayed text MUST state that enabling them is not available in
  this flow

### Requirement: The start step waits for the node and explains a failure

The start step MUST call `startNode` with the passphrase the identity step took,
and MUST report success only on a reply reporting `started:true` — never on the
call having been issued.

While the call is outstanding the step MUST show that it is waiting, and MUST
NOT offer the start control again, so a second node is not started over the
first.

On success the step MUST display the node id the reply reports, and MUST display
`listening` — including when it is empty, which is the state that confirms the
outbound-only default the network step described.

On an `{"error":"..."}` reply the step MUST display that message and MUST NOT
advance. The flow MUST NOT report a started node on any reply that is not a
success.

After a reported success the step MUST reflect `getNodeStatus().serving` rather
than only `running`: a node whose threads have died leaves `running` true while
`serving` goes false, and that is the state a user cannot otherwise account for.

#### Scenario: A started node is reported only on a success reply

- **GIVEN** a start step whose backend replies `{"started":true,…}` with a node
  id
- **WHEN** start is invoked
- **THEN** the step MUST report the node as started
- **AND** the reported node id MUST be the one in the reply

#### Scenario: An error reply is displayed and does not advance

- **GIVEN** a start step whose backend replies with an `error` carrying a
  distinctive message
- **WHEN** start is invoked
- **THEN** that message MUST be displayed
- **AND** the step MUST NOT report the node as started
- **AND** the step in force MUST still be the start step

#### Scenario: The start control is withheld while a start is outstanding

- **GIVEN** a start step where start has been invoked and no reply has arrived
- **THEN** the start control MUST NOT be enabled
- **AND** the waiting state MUST be visible

#### Scenario: An empty listening list is displayed rather than omitted

- **GIVEN** a start step whose backend replies `started:true` with an empty
  `listening` array
- **THEN** the step MUST display that the node is listening on no address

#### Scenario: A node that stops serving is shown as not serving

- **GIVEN** a start step that reported a started node
- **WHEN** `getNodeStatus()` subsequently reports `running:true` with
  `serving:false`
- **THEN** the step MUST NOT display the node as serving
- **AND WHEN** `getNodeStatus()` reports `running:true` with `serving:true`
- **THEN** the step MUST display the node as serving

### Requirement: The confirm step restates the new identity with its allow line

The confirm step MUST restate that the embedded node is a new identity, distinct
from any identity the user already holds, and MUST say what follows from it: the
repositories in the user's existing home are not in this node's storage, and a
private repository reaches this node only once a delegate authorises this DID.

It MUST display the DID `createEmbeddedIdentity` or `getCapabilities().nodeId`
reported, and MUST display a `rad id update --allow <DID>` line carrying that
same DID, ready to copy. The DID in the line MUST be the one reported rather
than a placeholder, so copying the line as shown is the correct command.

Copying MUST put that line on the clipboard.

The restatement MUST NOT be the flow's only statement of the consequence; the
embedded step states it before the identity is created, and this step restates it
with the DID that now exists.

#### Scenario: The allow line carries the reported DID

- **GIVEN** a confirm step told a node id of a distinctive DID
- **THEN** a `rad id update --allow` line MUST be displayed
- **AND** it MUST contain that DID
- **AND WHEN** the step is told a different node id
- **THEN** the displayed line MUST contain the second DID and MUST NOT contain
  the first

#### Scenario: Copying puts the allow line on the clipboard

- **GIVEN** a confirm step displaying an allow line for a known DID
- **WHEN** the copy control is invoked
- **THEN** the clipboard MUST hold that line

#### Scenario: The separateness consequence is restated with its effect

- **WHEN** the confirm step is shown
- **THEN** the displayed text MUST state that this is a new identity
- **AND** it MUST state that a private repository reaches this node only once a
  delegate authorises this DID

### Requirement: A step reports a backend refusal rather than a generic failure

Every step that calls a module method MUST treat an `{"error":"..."}` reply as a
refusal to display, not as a failure to summarise. The message MUST be shown as
the backend worded it, because the module's refusals name the home that was in
the way, the path to remove, the value that was tried and the limit that was
exceeded — which is the reason validation happens on write.

A step MUST NOT advance on a refusal, and MUST NOT report the action as done.

A subsequent successful call MUST clear a displayed refusal.

#### Scenario: Two different refusals display two different messages

- **GIVEN** an identity step whose backend refuses creation with one distinctive
  message
- **THEN** that message MUST be displayed
- **AND WHEN** the same step is submitted against a backend refusing with a
  different distinctive message
- **THEN** the second message MUST be displayed and the first MUST NOT

#### Scenario: A success clears a previously displayed refusal

- **GIVEN** a step displaying a refusal message
- **WHEN** a subsequent call to the same method succeeds
- **THEN** no refusal message MUST be displayed

### Requirement: The flow reads the backend and keeps no second opinion

What the flow displays as the mode in force, as what the embedded home holds,
and as whether the node is serving MUST come from the backend's replies —
`getCapabilities()`, `getEmbeddedIdentity()` and `getNodeStatus()` — and MUST
NOT be inferred from the fact that the flow issued a call.

A reply to a request the flow issued before the user moved to a different step
MUST NOT repopulate the step now in force.

#### Scenario: The displayed state follows the reply, not the request

- **GIVEN** an identity step that has issued a creation call
- **WHEN** the backend reply reports an error
- **THEN** the flow MUST report the embedded home as holding no identity
- **AND WHEN** the backend instead reports `created:true` with a node id
- **THEN** the flow MUST report the embedded home as holding that identity

#### Scenario: A late reply does not repopulate a step the user has left

- **GIVEN** a flow that issued a call from one step and has since moved to
  another
- **WHEN** the reply to that call arrives
- **THEN** the step now in force MUST NOT display it
