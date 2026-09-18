## Purpose

Define the guided setup a user walks through to bring the embedded node into
existence: the four steps and their order, what each step may do only once the
step before it has answered, and the three consequences the flow MUST state at
the moment the user decides rather than leave to be discovered afterwards — that
a passphrase means an unlock on every start, that the embedded identity is a new
DID rather than the user's own, and that the node accepts no inbound
connections.

**The setup sets a node up and then ends.** It does not start the node and does
not display the DID. Both were steps of this flow and both are now elsewhere,
for the same reason: neither is a thing done once at setup time. Starting is
something the mode does whenever it is opened, so a flow is the wrong shape for
it — `embedded-state` owns it. The DID is wanted at arbitrary later moments and
mostly when the flow is long closed, so a screen that shows it once and is
dismissed is the worst place to keep it — `embedded-header` owns it.

**This flow sets up Embedded mode and nothing else.** A user who opened it has
already chosen Embedded, so the flow states what Embedded means and lets them
proceed or leave. It MUST NOT offer Explore or Local as alternatives within
itself: those two need no setup, choosing either abandons every step that
follows, and a flow that offers a mode it then refuses to continue from is
presenting a choice with one permitted answer.

This capability also owns **where the flow is reached from, what raising and
lowering it does to the surfaces around it, and where a reopened flow lands.**
Those were left unsaid when the steps were first specified, and the result was a
flow with no host: a close control that emitted to nobody, and a state panel
whose action reached nobody. Entry and re-entry are not a separate subject from
the steps — re-entry decides which step is in force, and how the flow ends
decides what the user is looking at afterwards — so they are stated here rather
than in a capability of their own.

## ADDED Requirements

### Requirement: Four steps in a fixed order

The setup MUST present exactly four steps, in this order: preflight, embedded,
identity, network. The step in force MUST be observable, and MUST be preflight
on every showing until the preflight has answered.

The setup MUST NOT present a step that starts the node, and MUST NOT present a
step whose only content is a restatement of what the preceding steps did. It
MUST NOT issue `startNode`, in any step, for any reason.

When advancing is permitted, it MUST move to the next step in the sequence and
MUST NOT skip one. When it is not permitted — the requirements below name every
case — it MUST leave the step in force unchanged rather than move. Going back
MUST move to the previous step and MUST NOT be offered on the first step.

Exactly one other thing moves the step in force: the resume that follows the
preflight answering, specified below, which may land on any step and is not an
advance. A user's advance and back MUST NOT be able to skip, and that rule is
about those two controls rather than about the step ever changing by more than
one.

Going back MUST NOT undo anything an earlier step already performed. Identity
creation is not reversible through this flow, so a step that has performed it
MUST report what it did when it is returned to, rather than offering to do it
again.

#### Scenario: The flow opens on preflight

- **WHEN** the setup flow is shown, before the preflight has answered
- **THEN** the step in force MUST be the preflight step
- **AND** the control for going back MUST NOT be enabled

#### Scenario: Advancing walks the sequence without skipping

- **GIVEN** a flow whose every step is permitted to advance, whose step in force
  has been put back to preflight
- **WHEN** advance is invoked three times
- **THEN** the step in force after each invocation MUST be, in order, embedded,
  identity and network
- **AND** a fourth invocation MUST leave the step in force at network

#### Scenario: Going back returns to the previous step

- **GIVEN** the step in force is the network step
- **WHEN** back is invoked
- **THEN** the step in force MUST be the identity step
- **AND** invoking back again MUST make the step in force the embedded step

#### Scenario: No step of the setup starts a node

- **GIVEN** a flow over a backend accepting every call
- **WHEN** the flow is walked from preflight to the network step, advancing and
  submitting each step's control where one is offered
- **THEN** no `startNode` call MUST have been issued

#### Scenario: Returning to a step that already acted does not offer to act again

- **GIVEN** an identity step that has created an identity, reported by the
  backend as `exists:true` with a node id
- **WHEN** the step in force returns to the identity step
- **THEN** invoking the identity step's forward control MUST issue no
  `createEmbeddedIdentity` call
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
  `getNodeStatus().serving`. The setup starts no node, so this finding blocks
  nothing here and is reported for what it tells the user: that something else
  is already using the socket this node would want;
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

**A failed finding that makes no step's work impossible MUST block nothing.**
Reporting a fact and blocking a step are different acts, and only one of the
four findings gates work this flow does — which is a consequence of the setup
starting no node. Two of them, named below, are reported and block nothing at
all; a step blocked for work it does not do is a step a user cannot get past for
no reason.

An unresolvable home, and a home already holding a complete identity, MUST both
block **creation** at the identity step: the first because there is nowhere to
write, the second because `createEmbeddedIdentity` refuses an occupied home.

Those two block creation differently, and the difference is what the user sees.
An unresolvable home blocks the step itself: there is no identity and no way to
make one, so the step's forward control is not enabled and the reason is
stated. An occupied home blocks only the creation call: the step's work is
already done, so the forward control stays available and advances, as the
identity step's own requirements state.

A half-created home MUST NOT block the identity step. `getEmbeddedIdentity()`
reports it as `exists:false`, which the preflight cannot distinguish from an
empty home through that reply alone, and the backend's refusal is the only
surface that names the `keys` path to remove. Submitting creation and displaying
that refusal is therefore how the user learns the recovery — which is the
general rule the refusal requirement below states, applied here.

**A missing `git` MUST block no step of this setup.** Identity creation writes
key material and does not spawn `git`, and no step here starts a node, so there
is nothing in this flow a missing `git` makes impossible. The finding MUST still
be reported, because it makes the *node* unable to fetch and the user is better
told now than at the first fetch — but reporting a fact and blocking a step are
different acts, and a step blocked for work it does not do is a step a user
cannot get past for no reason.

**A node already answering on the resolved socket MUST block no step of this
setup either**, for the same reason: this flow starts nothing, so a socket in
use stops none of its work.

Blocking MUST be keyed on the finding, so that a backend reporting the finding
as passing removes the block with nothing else changed.

#### Scenario: A missing git blocks no step

- **GIVEN** a preflight reporting `gitFound:false` and every other check passing
- **THEN** advancing from the identity step MUST be permitted
- **AND** advancing from the embedded step MUST be permitted
- **AND** the git finding MUST be displayed as failed

#### Scenario: A node already serving blocks no step

- **GIVEN** a preflight reporting `serving:true` and every other check passing
- **THEN** advancing from the identity step MUST be permitted
- **AND** advancing from the network step MUST be permitted
- **AND** the socket finding MUST report that a node is already answering

#### Scenario: An occupied home blocks creation without blocking the step

- **GIVEN** a preflight whose `getEmbeddedIdentity()` reports `exists:true`
- **WHEN** the identity step's forward control is invoked
- **THEN** no `createEmbeddedIdentity` call MUST have been issued
- **AND** the step in force MUST be the network step
- **AND WHEN** a preflight instead reports an unresolvable home with no identity
- **THEN** the forward control MUST NOT be enabled
- **AND** the step in force MUST still be the identity step

#### Scenario: A half-created home is offered creation, and its refusal shown

- **GIVEN** a preflight whose `getEmbeddedIdentity()` reports `exists:false`
  with an empty `problem`, over a home the backend will refuse as half-created
- **THEN** the identity step's forward control MUST be enabled
- **AND WHEN** it is invoked and the backend refuses with a message naming a
  `keys` path to remove
- **THEN** that message MUST be displayed verbatim
- **AND** the flow MUST NOT report the identity as created

#### Scenario: A block lifts when its finding passes

- **GIVEN** a flow whose identity step's forward control is not enabled because
  the preflight reported an unresolvable home with no identity
- **WHEN** the same flow is given a preflight reporting a resolving home, with
  nothing else changed
- **THEN** the identity step's forward control MUST be enabled

### Requirement: The embedded step confirms Embedded and states the identity consequence

The embedded step MUST state what Embedded mode is — this module keeps its own
Radicle home and runs the node itself — and MUST state, in the step itself,
that the node operates as a **new identity this module creates**, separate from
any Radicle node the user already runs and from any identity they already hold.

It MUST also state what follows from that separateness: the repositories in the
user's existing home are not in this node's storage, and a private repository
reaches this node only once a delegate authorises this DID.

**This step is the only place the flow states it**, so it MUST be stated here in
full rather than partly. It was previously split between this step and a
terminal step that restated it with the DID; that step is gone, and a
consequence stated in half is one a user acts on without.

Stating it here rather than after creation is also the right moment on its own
terms: a statement made only after the identity exists is made after the
decision it informs.

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
- **AND** it MUST state that a private repository reaches this node only once a
  delegate authorises this DID

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

### Requirement: The identity step offers one forward control

Creating the identity is how a user leaves the identity step: once an identity
exists there is nothing further the step does, and no other act moves it
forward. The step MUST therefore offer **exactly one control that moves the
flow forward**, and MUST NOT offer creation and advancing as two separate
controls. Two controls for one act make the user perform a second act whose
only possible answer is yes, and make it possible to advance past a step whose
work was never done.

With no identity in the embedded home, that control MUST create the identity
and, on a reply reporting the identity created, MUST advance to the next step
in the same act, without a further invocation.

With an identity already in the embedded home — whether this showing created it
or it was there when the step was entered — that control MUST advance and MUST
NOT issue `createEmbeddedIdentity`. The backend refuses an occupied home, so a
second creation call has no outcome but a refusal the user did not ask for.

The control's label MUST say which of those two it will do. A label naming
creation on a step that will only advance states an act that will not happen,
which is the same defect as a control that does the wrong thing.

The control MUST NOT be enabled while creation is blocked and no identity
exists — the blocking requirement above names those cases — because in that
state it can neither create nor advance past work that was not done.

A refused creation MUST NOT advance. The step MUST remain in force with the
refusal displayed, and the control MUST remain available so the user can
correct what was refused and submit again.

#### Scenario: One forward control creates and advances together

- **GIVEN** an identity step with alias `tester`, over a backend reporting no
  identity in the embedded home and accepting creation
- **WHEN** the step's forward control is invoked once
- **THEN** exactly one `createEmbeddedIdentity` call MUST have been issued
- **AND** the step in force MUST be the network step
- **AND** no second invocation MUST have been required to leave the identity
  step

#### Scenario: With an identity already there, the control advances and creates nothing

- **GIVEN** an identity step entered over a backend reporting `exists:true` with
  a node id
- **WHEN** the step's forward control is invoked
- **THEN** no `createEmbeddedIdentity` call MUST have been issued
- **AND** the step in force MUST be the network step

#### Scenario: The label names the act the control will perform

- **GIVEN** an identity step over a backend reporting no identity
- **THEN** the forward control's label MUST name creating the identity
- **AND WHEN** the same step is given a backend reporting `exists:true` with a
  node id
- **THEN** the forward control's label MUST NOT name creating an identity
- **AND** it MUST name continuing to the next step

#### Scenario: A refused creation stays on the step with the control available

- **GIVEN** an identity step over a backend that refuses creation with a
  distinctive message
- **WHEN** the forward control is invoked
- **THEN** that message MUST be displayed
- **AND** the step in force MUST still be the identity step
- **AND** the forward control MUST still be enabled
- **AND WHEN** the control is invoked again against a backend that now accepts
  creation
- **THEN** the step in force MUST be the network step

#### Scenario: A blocked step with no identity offers no forward control

- **GIVEN** an identity step whose home cannot be resolved, over a backend
  reporting no identity
- **THEN** the forward control MUST NOT be enabled
- **AND** the displayed reason MUST name what is blocking

### Requirement: The identity step distinguishes its three states

The identity step MUST render three states distinctly, and what it displays
MUST be derived from what the backend reported rather than from the step having
been shown:

- **no identity yet** — the backend reports no identity in the embedded home.
  The step MUST NOT display a node id, and MUST NOT display any statement that
  an identity exists. The alias and passphrase controls belong to this state,
  because it is the only one in which the step submits either.
- **created in this showing** — a `createEmbeddedIdentity` call made from this
  showing replied that the identity was created. The step MUST report it as
  created, carrying the node id the reply reported.
- **already there on arrival** — the backend reported an identity before this
  showing submitted any creation. The step MUST report that the identity was
  already present, carrying its node id, and MUST NOT report it as created by
  this showing.

The second and third states MUST NOT be rendered the same way. A user who
already holds an identity has succeeded at this step, and telling them creation
is refused describes a failure that did not happen — the refusal sentence
explains an attempt, and no attempt was made.

The step MUST NOT display, at the same time, a statement that the identity was
created and a statement that creating one is refused. Those two describe
different outcomes of the same act, and both on screen at once leave the user
unable to tell which occurred.

In the third state, an explanation that a second identity would be refused is
permitted as a note on why the step does not offer creation, and MUST NOT be
presented as a failure or an error. Where the step renders backend refusals,
that surface MUST be reserved for a refusal the backend actually returned to
this showing.

#### Scenario: The three states are told apart

- **GIVEN** an identity step over a backend reporting no identity
- **THEN** the step MUST NOT report an identity as existing
- **AND** the step MUST NOT display a node id
- **AND WHEN** creation is submitted and the backend replies created, with a
  distinctive node id
- **THEN** the step MUST report the identity as created in this showing,
  carrying that node id
- **AND WHEN** a fresh showing is instead entered over a backend reporting
  `exists:true` with a different distinctive node id, with no creation submitted
- **THEN** the step MUST report that an identity was already present, carrying
  the second node id
- **AND** it MUST NOT report the identity as created in this showing

#### Scenario: An identity that was already there is not reported as a failure

- **GIVEN** an identity step entered over a backend reporting `exists:true` with
  a node id, with no creation submitted in this showing
- **THEN** no refusal MUST be displayed
- **AND** the step MUST NOT display a statement that creating an identity was
  refused

#### Scenario: Created and refused are never displayed together

- **GIVEN** an identity step that has submitted creation and been told the
  identity was created
- **THEN** the step MUST display that the identity was created
- **AND** the step MUST NOT simultaneously display a statement that creating an
  identity is refused

### Requirement: The identity step names the home it writes to

The identity step MUST display the filesystem path of the embedded home it is
writing into, or has written into, taking it from `getEmbeddedIdentity().home`.

A DID names the identity and says nothing about where it lives. The embedded
home is a path the user did not choose and cannot guess — it is derived from
the Basecamp profile's data directory — so a step that reports only a DID
leaves the user unable to find, back up or inspect what was created, and unable
to tell an embedded home from their own Radicle home.

The path displayed MUST be the one the backend reported, so that a step told a
different home displays a different path. It MUST be displayed in all three of
the step's states, because the question it answers — which home is this — is
the same before and after creation.

When no home could be resolved, `home` is empty and there is no path to state.
The step MUST then state that no home could be resolved instead of displaying
an empty path, and MUST display the backend's own sentence where one was
supplied, as the refusal requirement below already requires.

#### Scenario: The reported home is the path displayed

- **GIVEN** an identity step told a `getEmbeddedIdentity()` reply whose `home`
  is a distinctive path
- **THEN** that path MUST be displayed
- **AND WHEN** the step is told a reply carrying a different distinctive path
- **THEN** the second path MUST be displayed and the first MUST NOT

#### Scenario: The home is stated before and after creation

- **GIVEN** an identity step over a backend reporting no identity and a
  distinctive `home`
- **THEN** that path MUST be displayed
- **AND WHEN** creation is submitted and succeeds
- **THEN** that path MUST still be displayed

#### Scenario: An unresolvable home is stated rather than shown as an empty path

- **GIVEN** an identity step told a `getEmbeddedIdentity()` reply whose `home`
  is empty, with a distinctive `problem`
- **THEN** the step MUST state that no home could be resolved
- **AND** that `problem` sentence MUST be displayed

### Requirement: The identity step states the passphrase trade where it is chosen

The identity step MUST take an alias and a passphrase, and MUST offer setting a
passphrase as the default: the control MUST arrive in the state that leads to an
encrypted key, so that leaving it alone produces the safer outcome.

The step MUST state, visibly at the moment the passphrase choice is offered and
not only after it is made, that an encrypted key must be unlocked every time the
node is started — the node is handed an already-decrypted signing key when it is
built, so a passphrase cannot be supplied later — and that an unencrypted key
starts the node with no prompt at the cost of a secret stored in plaintext.

That statement is now also a statement about what happens on **every subsequent
opening of Embedded**, not only about a start the user will ask for: an
unencrypted key means the node starts by itself, and an encrypted one means a
passphrase is asked for each time. The step MUST state that consequence, because
it is the one the user lives with and it is chosen here and nowhere else.

The passphrase the step takes MUST be used for `createEmbeddedIdentity` and for
nothing else. The setup starts no node, so it has no second use for it, and it
MUST NOT be retained past the reply to the creation call.

Both halves of that trade MUST be stated. A statement naming only the security
benefit, or only the unlock cost, is a recommendation rather than a trade, and
the user cannot weigh it.

The statement MUST be visible for both settings of the control, so a user who
turns the passphrase off sees what they gave up and what they gained.

This requirement binds the state in which the passphrase is chosen — the one
where no identity exists yet. Where an identity already exists there is no
passphrase to choose, so the step offers neither the control nor the statement:
its key was sealed, or not, when it was created, and this flow cannot change
that. Stating a trade the user can no longer make would describe a decision
that is not theirs to take.

The alias MUST be submitted to `createEmbeddedIdentity` as the user typed it.
The flow MUST NOT pre-validate it against its own rule: `embedded-identity`
requires the backend to pass through the `radicle` crate's own statement of the
rule, and a second rule in the view would drift from it.

#### Scenario: A passphrase is the arriving default

- **WHEN** the identity step is shown for the first time, over a backend
  reporting no identity
- **THEN** the control choosing whether to set a passphrase MUST be in the state
  that sets one

#### Scenario: Both halves of the trade are stated before the choice is made

- **WHEN** the identity step is shown over a backend reporting no identity,
  before the passphrase control is touched
- **THEN** the displayed text MUST state that the node must be unlocked each
  time it starts when a passphrase is set
- **AND** it MUST state that an unencrypted key stores a secret in plaintext

#### Scenario: The trade stays stated when the passphrase is turned off

- **GIVEN** an identity step over a backend reporting no identity, whose
  passphrase control has been turned off
- **THEN** the displayed text MUST still state both halves of the trade

#### Scenario: An identity that already exists offers no passphrase choice

- **GIVEN** an identity step entered over a backend reporting `exists:true` with
  a node id
- **THEN** no control choosing whether to set a passphrase MUST be present
- **AND WHEN** the same step is instead given a backend reporting no identity
- **THEN** that control MUST be present

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

#### Scenario: The trade names what happens on every later opening

- **WHEN** the identity step is shown over a backend reporting no identity
- **THEN** the displayed text MUST state that an unencrypted key lets the node
  start without a prompt
- **AND** it MUST state that an encrypted key is asked for each time

#### Scenario: The passphrase does not outlive the creation call

- **GIVEN** an identity step with alias `tester` and a passphrase of
  `correct horse battery`, over a backend that accepts creation
- **WHEN** creation is submitted and the reply reporting the identity created
  has arrived
- **THEN** the flow MUST NOT retain that passphrase
- **AND** no call carrying it MUST have been issued other than the
  `createEmbeddedIdentity` call

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

### Requirement: The setup ends by finishing, not by being dismissed

The network step is the last, and its forward control MUST end the setup: it
MUST report that the user has finished, which is what lowers the surface, and it
MUST NOT move to a further step.

The setup MUST NOT present a terminal screen whose only act is to be dismissed.
A step that states what already happened and offers one control that closes it
asks the user for an act that changes nothing — and the facts such a screen
would carry are each better placed where they are wanted: the DID in the header
where it is always reachable, and the node's state on the surface the user
returns to.

Ending the setup MUST NOT start the node, MUST NOT write the mode again, and
MUST NOT issue any call. The steps made every write this flow makes; ending is
the surface coming down.

What the user sees after the setup ends is the Embedded surface, which reports
the node's state and starts it where it can — `embedded-state`'s requirements,
not this capability's. That is what replaces the dismissed terminal screen, and
it is reached without the user doing anything.

#### Scenario: Finishing the last step ends the setup

- **GIVEN** a flow whose step in force is the network step
- **WHEN** the step's forward control is invoked
- **THEN** the flow MUST report that the user has finished
- **AND** the step in force MUST NOT have moved to a further step

#### Scenario: Ending the setup issues no call

- **GIVEN** a flow whose step in force is the network step, over a backend
  accepting every call
- **WHEN** the step's forward control is invoked
- **THEN** no `startNode` call MUST have been issued
- **AND** no `setSetting` call MUST have been issued
- **AND** no `createEmbeddedIdentity` call MUST have been issued

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

### Requirement: The setup is raised over the view, and lowered by its own close

The module MUST host the setup as a surface raised over whatever screen the user
is on, leaving that screen in place underneath, and MUST NOT host it as a
navigation destination that replaces the screen or adds an entry to the
navigation history.

The distinction is observable rather than presentational. Hosted as a navigation
destination, going back from the setup has to choose between the step the user
was on and the screen they came from, and the navigation state that would make
that choice knows nothing about steps; the setup's own back control already moves
between steps, so a second back control with different meaning would be two
controls for one word. Raised over the view, lowering it restores exactly the
screen that was underneath, whatever that screen was, with no decision to make.

The module MUST expose whether the setup is raised, so that raising and lowering
it can be observed from outside the surface itself.

The setup MUST be lowered when the flow reports that the user has finished or
given up, and MUST NOT lower itself: the surface reports, and the module that
raised it decides. A surface that closed itself would leave whatever raised it
still believing the surface is up.

Lowering the setup MUST NOT change the screen underneath — not the view in
force, not the repository it was showing, and not the tab within it.

#### Scenario: Raising the setup leaves the screen underneath in force

- **GIVEN** a module showing a repository, with the setup not raised
- **WHEN** the setup is raised
- **THEN** the module MUST report the setup as raised
- **AND** the view in force MUST still be the repository view
- **AND WHEN** the flow reports the user has finished
- **THEN** the module MUST report the setup as not raised
- **AND** the view in force MUST still be the repository view, showing the same
  repository

#### Scenario: The setup is lowered by its report, not by the control that raised it

- **GIVEN** a module with the setup raised
- **WHEN** the flow reports the user has finished
- **THEN** the module MUST report the setup as not raised
- **AND WHEN** the setup is raised again and the flow makes no such report
- **THEN** the module MUST still report the setup as raised

### Requirement: The setup and the settings surface are never raised together

The module MUST NOT have the setup and the durable settings surface raised at the
same time. Raising either one MUST lower the other.

Both are opaque surfaces covering the same screen, so two raised at once leaves
one of them unreachable behind the other with no control to lower it — which is
the one-way door this module has already shipped once and which the settings
surface's own close control exists to prevent. Lowering the one being covered is
what keeps every raised surface reachable.

Lowering one MUST NOT raise the other. A user who closes the setup is returned to
the screen underneath, not handed a different surface they did not ask for.

#### Scenario: Raising each surface lowers the other

- **GIVEN** a module with the settings surface raised and the setup not raised
- **WHEN** the setup is raised
- **THEN** the module MUST report the setup as raised
- **AND** the module MUST report the settings surface as not raised
- **AND WHEN** the settings surface is then raised
- **THEN** the module MUST report the settings surface as raised
- **AND** the module MUST report the setup as not raised

#### Scenario: Lowering one raises nothing

- **GIVEN** a module with the setup raised and the settings surface not raised
- **WHEN** the flow reports the user has finished
- **THEN** the module MUST report the setup as not raised
- **AND** the module MUST report the settings surface as not raised

### Requirement: The setup opens only when a user asks for it

The setup MUST be raised only in response to an act the user performs that names
opening it. Two such acts exist: the request the Embedded state surface emits
when its setup action is taken, and an equivalent request from the durable
settings surface once that surface offers one.

Selecting Embedded MUST NOT raise the setup, whether the mode is selected from
the header, from the settings surface, or restored as the mode already in force
when the module starts. Choosing a mode and configuring a node are different acts:
a user selecting Embedded to see what is there is answering a different question
from one who asked to set a node up, and a modal appearing because a segment was
clicked is the same defect class as writing the mode because a screen was opened.

Nothing else MUST raise it. In particular the setup MUST NOT be raised as a
consequence of the backend reporting that no identity exists, of a start failing,
or of the module becoming ready — those are states, and a state is not a request.

#### Scenario: Selecting Embedded does not raise the setup

- **GIVEN** a module in a mode other than `embedded`, with the setup not raised
- **WHEN** Embedded is selected and the backend reports it in force, with
  `getEmbeddedIdentity()` reporting `exists:false`
- **THEN** the module MUST report the setup as not raised

#### Scenario: Starting in Embedded with no identity does not raise the setup

- **GIVEN** a module whose backend reports `embedded` already in force and
  `getEmbeddedIdentity().exists` false
- **WHEN** the module becomes ready
- **THEN** the module MUST report the setup as not raised

#### Scenario: The state surface's setup request raises it

- **GIVEN** a module in `embedded` with the setup not raised, whose state surface
  is rendering the no-identity state
- **WHEN** the state surface's setup action is taken
- **THEN** the module MUST report the setup as raised

### Requirement: A reopened setup lands at the first step with work left

When the setup is raised, the flow MUST re-run the preflight and MUST put in
force the first step whose work the backend reports as not yet done. It MUST NOT
resume at the step that was in force when it was last lowered, and MUST NOT
depend on any record of a previous showing.

Closing the setup part way through is safe precisely because every write it makes
is separately durable — the mode, the identity and the started node each land on
their own — so there is no half-committed state to resume into. What the backend
reports is therefore the authority on what remains, and a remembered step index is
a second opinion that is wrong whenever anything changed between the two showings:
a module restarted, an identity created from elsewhere, a node that has since
stopped.

The step put in force MUST be derived from what the preflight replies report, so
that a flow given different replies lands on different steps:

- with the mode not yet reported as `embedded`, the embedded step;
- with the mode `embedded` and `getEmbeddedIdentity().exists` false, the identity
  step;
- with the mode `embedded` and an identity existing, the network step, which is
  the last and has no work the backend can report as done.

The node's state MUST NOT affect where a reopened setup lands. This flow neither
starts nor stops a node, so whether one is running says nothing about which of
its steps still has work — and a flow that landed differently for a running node
than for a stopped one would be reporting the node's state through the step it
chose, which is `embedded-state`'s job and not a step's.

The resume MUST put the step in force once, as a single move, rather than by
repeatedly advancing. Advancing moves the staleness epoch the preflight replies
were issued under, so a resume that advanced step by step would invalidate the
replies that determined where it was going — leaving the flow's findings
unpopulated at the step it just chose, or the move abandoned part way.

Until the preflight has answered, the step in force MUST remain the preflight
step, and the flow MUST NOT move to a step chosen from replies that have not
arrived. Every finding has a legitimate falsy value, so choosing from the defaults
would land every reopening on the same early step whatever the backend holds.

A resumed step MUST behave exactly as it does when reached by advancing: the
requirements above on what each step may do, what it must state and what blocks it
apply unchanged, and in particular a step that has already acted MUST report what
it did rather than offer to act again.

The rule above is what decides where a reopened flow lands, and an existing
identity therefore lands it past the identity step. That MUST stay true: the
identity step's forward control advancing rather than creating, when an identity
is already there, is about what the step does when a user reaches it — by going
back, or with an identity that appeared between the preflight and the step — and
MUST NOT be read as a reason for the resume to land on it. A resume that landed
on a step whose only act is already done would present a step with nothing to do
as the first step with work left.

#### Scenario: An existing identity resumes past the identity step

- **GIVEN** a setup raised against a backend reporting `embedded` in force, an
  existing identity with a node id, and the node not serving
- **WHEN** the preflight has answered
- **THEN** the step in force MUST NOT be the identity step
- **AND** the step in force MUST be the network step

#### Scenario: Different backend states resume to different steps

- **GIVEN** a setup raised against a backend reporting `embedded` in force,
  `getEmbeddedIdentity().exists` false
- **WHEN** the preflight has answered
- **THEN** the step in force MUST be the identity step
- **AND WHEN** a setup is raised against a backend reporting `embedded` in force
  and an existing identity with a node id
- **THEN** the step in force MUST be the network step
- **AND WHEN** a setup is raised against a backend reporting a mode other than
  `embedded` and an existing identity
- **THEN** the step in force MUST be the embedded step

#### Scenario: The node's state does not change where the flow lands

- **GIVEN** a setup raised against a backend reporting `embedded` in force, an
  existing identity, and the node reporting `running:false` and `serving:false`
- **WHEN** the preflight has answered
- **THEN** the step in force MUST be the network step
- **AND WHEN** the same setup is lowered and raised again against a backend
  identical but for the node reporting `running:true` and `serving:true`
- **THEN** the step in force MUST still be the network step

#### Scenario: A mode not yet in force resumes to the embedded step

- **GIVEN** a setup raised against a backend reporting a mode other than
  `embedded`, and `getEmbeddedIdentity().exists` false
- **WHEN** the preflight has answered
- **THEN** the step in force MUST be the embedded step

#### Scenario: The step reached last time does not decide where it reopens

- **GIVEN** a setup that was raised, advanced to the network step, and lowered,
  against a backend reporting `embedded` in force and `exists:false`
- **WHEN** the setup is raised again and the preflight has answered
- **THEN** the step in force MUST be the identity step
- **AND WHEN** the same setup is lowered and raised again against a backend now
  reporting an existing identity
- **THEN** the step in force MUST be the network step

#### Scenario: The flow waits at preflight rather than resuming from defaults

- **GIVEN** a setup raised against a backend whose identity reply is withheld,
  reporting `embedded` in force
- **THEN** the step in force MUST be the preflight step
- **AND WHEN** the withheld reply is delivered, reporting an existing identity
- **THEN** the step in force MUST be the network step

#### Scenario: The resumed step's findings are populated

- **GIVEN** a setup raised against a backend reporting `embedded` in force and
  an existing identity with a distinctive node id
- **WHEN** the preflight has answered and the step in force is the network step
- **THEN** the identity finding MUST report that an identity exists, carrying that
  node id
- **AND WHEN** back is invoked to reach the identity step
- **THEN** invoking that step's forward control MUST issue no
  `createEmbeddedIdentity` call

### Requirement: The setup is offered only for work it can do

The module MUST raise the setup only for a request to set the embedded node up.
A request to start or restart an already-created node MUST NOT raise it.

**Starting is not a step of this flow, so it cannot be served by raising it.**
The setup creates an identity and puts the mode in force; a node that already has
an identity has nothing left for any of its steps to do, so raising it for a
start request would present four steps, three of them already done, none of them
the act that was asked for. Starting belongs to the Embedded surface, which is
where a node's state is reported and where `embedded-state` requires the start to
happen.

A restart is also not this flow's: it is two calls whose refusals are different
sentences, and this capability sequences neither.

The requirement is about which request was made, not about which state the module
is in, so a host that raised the setup for every request alike MUST fail it. That
is what stops the rule being satisfied by a host that happens never to receive a
start request today.

#### Scenario: A start request does not raise the setup

- **GIVEN** a module in `embedded` with the setup not raised
- **WHEN** a request to start the node is made
- **THEN** the module MUST report the setup as not raised
- **AND WHEN** a request to set the node up is instead made
- **THEN** the module MUST report the setup as raised

#### Scenario: A restart request does not raise the setup

- **GIVEN** a module in `embedded` with the setup not raised, whose node reports
  `running:true` with `serving:false` and no start outstanding
- **WHEN** a request to restart the node is made
- **THEN** the module MUST report the setup as not raised
