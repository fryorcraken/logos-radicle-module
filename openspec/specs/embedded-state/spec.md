# embedded-state Specification

## Purpose
Define what the repository list shows in Embedded mode when there are no
repositories to show, and why: seven states derived from what the backend
reports, each with its own sentence and its own next action, so that a mode
whose node has not been created, has not been started, or has stopped serving
is never rendered as a node that exists and holds nothing.

This capability also owns **starting the node**. Starting is not a setup step —
it is something Embedded does every time it is opened, for the life of the
mode — so it belongs to the surface that reports the node's state rather than to
a flow a user walks once. That includes the node starting by itself where it
can, the passphrase being asked for where it cannot, and the rule that keeps a
node this module started from being reported as an obstacle.

It does not own the guided setup this surface offers to open, which is
`embedded-setup`'s, nor the durable configuration panel, nor the header's
display of the identity, which is `embedded-header`'s.

## Requirements

### Requirement: Embedded's empty surface reports one of seven states

While the mode in force is `embedded` and no repositories are listed, the
repository list MUST render exactly one state drawn from this set, and MUST
derive which one from the backend's replies rather than from a value it stores:

- **blocked** — `getCapabilities().pathsProblem` is non-empty, or
  `getEmbeddedIdentity().home` is the empty string. There is nowhere to write.
- **no identity** — a home resolves and `getEmbeddedIdentity().exists` is false.
- **stopped** — `exists` is true, and the node reports neither running nor
  serving.
- **starting** — a `startNode` call the view issued is outstanding.
- **start failed** — the last `startNode` call was answered with
  `{"error":"..."}`.
- **not serving** — the node reports `running:true` with `serving:false` and no
  start is outstanding.
- **running and empty** — the node reports `serving:true` and the list came back
  with no repositories.

More than one of those conditions can hold at once — a start can be refused in a
home that later reports a `pathsProblem` — so the list above MUST be read in
order, and the first state whose condition holds MUST be the one rendered. The
order is not arbitrary: it runs from the most fundamental obstacle to the least,
so that a user is told there is nowhere to write before being told a start
failed, rather than being sent to retry a start that cannot succeed.

The state MUST be recomputed from `getCapabilities()`,
`getEmbeddedIdentity()` and `getNodeStatus()`, and MUST NOT be held as a stored
value that a reply updates. A stored state is a second opinion that can be wrong
after a node dies, a passphrase is refused, or the mode is changed from
elsewhere.

Each state MUST carry its own sentence describing what is true, and its own
action naming what the user may do next. A single banner MUST NOT stand in for
these, because the states differ in the action they offer and not only in their
wording: a home with no identity offers to open the setup, a stopped node with
an encrypted key offers a passphrase and a start, a node that has stopped
serving offers a restart, and a blocked home offers no action that would write,
because none can succeed.

A stopped node with an **unencrypted** key offers no action at all, because the
surface starts it without being asked — see the requirement on that below. It is
the one state whose next act is the module's rather than the user's, and it MUST
NOT render a control that would duplicate a start already issued.

Naming an action is distinct from that action being available. Which actions this
version of the module can carry out is stated separately below, and a state whose
action nothing can carry out MUST still name it rather than render as a state
with nothing to say.

The **blocked** state's sentence MUST be the `pathsProblem` sentence verbatim,
because that sentence names the path that was tried and the limit that was
exceeded, which the view cannot reconstruct.

#### Scenario: Each state renders its own sentence and its own action

- **GIVEN** a repository list in `embedded` with a non-empty `pathsProblem`
- **THEN** the rendered sentence MUST contain that `pathsProblem` text verbatim
- **AND WHEN** the same list is instead told an empty `pathsProblem`, a
  resolving home and `getEmbeddedIdentity().exists` false
- **THEN** the rendered sentence MUST NOT contain the earlier `pathsProblem`
  text
- **AND** the rendered action MUST differ from the action rendered for the
  blocked state

#### Scenario: A stopped node and a home with no identity are different states

- **GIVEN** a repository list in `embedded` told `exists:false`
- **THEN** the rendered action MUST be the one that opens the guided setup
- **AND WHEN** the same list is told `exists:true` with `encrypted:true` and a
  node reporting `running:false` and `serving:false`
- **THEN** the rendered action MUST be the one that starts the node
- **AND** the rendered sentence MUST differ from the one rendered for
  `exists:false`

#### Scenario: A blocked home offers no action that would write

- **GIVEN** a repository list in `embedded` with a non-empty `pathsProblem`
- **THEN** no action MUST be named
- **AND** no enabled action MUST be rendered
- **AND WHEN** the same list is told an empty `pathsProblem` with a resolving
  home and `exists:false`
- **THEN** an enabled action MUST be rendered

#### Scenario: The most fundamental obstacle is the one rendered

- **GIVEN** a repository list in `embedded` told `encrypted:true`, whose
  `startNode` was answered with a distinctive refusal, and which is then told a
  non-empty `pathsProblem`
- **THEN** the rendered sentence MUST contain the `pathsProblem` text
- **AND** no action MUST be named
- **AND WHEN** the same list is told an empty `pathsProblem`, with the refusal
  unchanged
- **THEN** the rendered sentence MUST contain the refusal's text
- **AND** the named action MUST be the one that starts the node

#### Scenario: The state follows a later reply rather than the first

- **GIVEN** a repository list in `embedded` rendering the stopped state, having
  been told `exists:true` with `running:false` and `serving:false`
- **WHEN** the backend subsequently reports `running:true` with `serving:true`
  and a list reply carrying no repositories
- **THEN** the rendered state MUST be the running-and-empty one
- **AND WHEN** the backend subsequently reports `running:false` and
  `serving:false` again
- **THEN** the rendered state MUST be the stopped one again

### Requirement: A mode with no node to ask issues no list request

The repository list MUST NOT issue a `ListRepos` request while the mode in force
has no node that could answer it — in `embedded`, whenever the state is
**blocked**, **no identity**, **stopped** or **start failed**. A start that was
refused left no node loaded, so that state is asked nothing for the same reason
**stopped** is.

It MUST NOT issue the request and discard or hide the reply. A reply already in
flight still arrives, still passes the staleness guard that compares the mode
and the method prefix it was issued under, and still repopulates the model
behind whatever the view is displaying, so the rows appear under a panel saying
no node exists.

The guard MUST be keyed on whether the mode in force has a node to ask, and MUST
NOT be keyed on whether the mode is startable. `embedded` is a startable mode —
it resolves a workable home — so a guard keyed on startability never fires for
it, which is how this surface was lost: the guard stopped blocking the request
at the same moment the panel behind it stopped rendering.

Once the state is **starting**, **not serving** or **running and empty**, a
request MUST be permitted: a node that is loaded can be asked, and a node that
has stopped serving still answers reads, because reads do not touch the daemon.

#### Scenario: No request is issued while there is no node to ask

- **GIVEN** a repository list in `embedded` told `exists:false`
- **WHEN** the list loads
- **THEN** no `ListRepos` request MUST have been issued
- **AND WHEN** the same list is instead told `exists:true` with a node
  reporting `serving:true`, whose backend answers with a distinctively named
  repository
- **THEN** a `ListRepos` request MUST have been issued
- **AND** that repository MUST be listed

#### Scenario: The guard is not keyed on startability

- **GIVEN** a repository list in `embedded`, told a startable set containing
  `embedded`, and told `exists:false`
- **WHEN** the list loads
- **THEN** no `ListRepos` request MUST have been issued

#### Scenario: A stopped node is asked nothing, a non-serving one is asked

- **GIVEN** a repository list in `embedded` told `exists:true` with a node
  reporting `running:false` and `serving:false`
- **WHEN** the list loads
- **THEN** no `ListRepos` request MUST have been issued
- **AND WHEN** the same list is told `exists:true` with a node reporting
  `running:true` and `serving:false`
- **THEN** a `ListRepos` request MUST have been issued

#### Scenario: A refused start leaves the node unasked

- **GIVEN** a repository list in `embedded` told `exists:true`, whose
  `startNode` was answered with `{"error":"..."}` and whose node still reports
  `running:false` and `serving:false`
- **WHEN** the list loads
- **THEN** no `ListRepos` request MUST have been issued
- **AND** the empty-list placeholder MUST NOT be visible

### Requirement: The no-repositories wording is withheld where no node exists

The wording that reports a node holding no repositories — the empty-list
placeholder — MUST NOT be rendered in any state the requirement above declines
to fetch in: **blocked**, **no identity**, **stopped** and **start failed**. It
MUST NOT be rendered in **starting** either, where a request may be outstanding
but no answer has arrived.

That wording is a claim about a node: that one exists, was asked, and answered
with nothing. In those states no node answered, so the wording is not a milder
version of the truth but a different and false one, and it sends a user looking
for missing repositories rather than for the setup they have not run.

It MUST be permitted in the **running and empty** state, which is the state it
correctly describes, and the sentence rendered there MUST also say that this
node lists what it is seeding — so an empty list reads as a node with nothing
seeded rather than as a node that has lost something.

#### Scenario: The empty-list wording is absent where no node was asked

- **GIVEN** a repository list in `embedded` told `exists:false`
- **THEN** the empty-list placeholder MUST NOT be visible
- **AND WHEN** the same list is told `exists:true` with a node reporting
  `running:false` and `serving:false`
- **THEN** the empty-list placeholder MUST NOT be visible

#### Scenario: A serving node that holds nothing may say so

- **GIVEN** a repository list in `embedded` told `exists:true` with a node
  reporting `serving:true`, whose `ListRepos` reply carries no repositories
- **THEN** the rendered sentence MUST state that this node lists what it is
  seeding

### Requirement: A node that has stopped serving reads as neither running nor stopped

When the node reports `running:true` with `serving:false` and no start is
outstanding, the surface MUST report that the node has stopped answering its
control socket while remaining loaded. It MUST NOT report the node as running,
and MUST NOT report it as stopped.

Both of those are false in a way the user pays for. Reporting it as running
sends them looking for a network or permissions fault while fetches silently
never arrive — reads keep working, because reads never touch the daemon, so the
repository list can look entirely healthy. Reporting it as stopped invites a
start that will refuse, because the runtime is still loaded and still holds the
socket.

The action offered MUST therefore be one that stops and then starts the node,
rather than a bare start.

This state is reachable because the panic guard at the FFI boundary does not
reach the threads a running node spawns: a node whose runtime panics leaves the
module's own bookkeeping reporting `running:true` indefinitely, and `serving` is
the only field that notices.

#### Scenario: A non-serving node is reported as neither running nor stopped

- **GIVEN** a repository list in `embedded` told `exists:true` with a node
  reporting `running:true` and `serving:false`, and no start outstanding
- **THEN** the rendered sentence MUST state that the node has stopped answering
- **AND** the rendered sentence MUST state that it is still loaded
- **AND** the sentence rendered for a node reporting `serving:true` MUST differ
  from it
- **AND** the sentence rendered for a node reporting `running:false` and
  `serving:false` MUST differ from it

#### Scenario: The offered action restarts rather than starts

- **GIVEN** a repository list in `embedded` told `running:true` and
  `serving:false` with no start outstanding
- **THEN** the rendered action MUST differ from the action rendered when the
  node reports `running:false` and `serving:false`

### Requirement: Starting is distinguished from not serving by the outstanding call

A node being started and a node that has stopped serving MUST be rendered as
different states, although the backend reports the same two fields for both: a
`getNodeStatus()` poll taken during startup can report `running:true` with
`serving:false`, which is exactly what a node whose threads have died reports.

The view MUST distinguish them by whether a `startNode` call it issued is still
outstanding, which is the one fact the backend reply does not carry and only the
view holds. While such a call is outstanding the state MUST be **starting**;
with none outstanding and the same fields reported, it MUST be **not serving**.

An outstanding start MUST be cleared by the reply to it — success or
`{"error":"..."}` — and MUST NOT be cleared by the call merely having been
issued, or a node that never answers would settle into **not serving** while its
start is still genuinely in flight.

While the state is **starting**, the surface MUST NOT name the action that starts
the node, so a second node is not started over the first. This holds independently
of whether that action can be carried out at all: it is a property of the state,
and it must already be true on the day a surface able to start a node exists.

#### Scenario: The same reported fields render two different states

- **GIVEN** a repository list in `embedded` that has issued a `startNode` call
  which has not been answered, with the node reporting `running:true` and
  `serving:false`
- **THEN** the rendered sentence MUST state that the node is starting
- **AND WHEN** the same fields are reported with no `startNode` call
  outstanding
- **THEN** the rendered sentence MUST state that the node has stopped answering
- **AND** the two sentences MUST differ

#### Scenario: The reply clears the outstanding start, not the request

- **GIVEN** a repository list in `embedded` that has issued a `startNode` call
  which has not been answered
- **THEN** the state MUST be the starting one
- **AND WHEN** the call is answered with `{"error":"..."}`
- **THEN** the state MUST NOT be the starting one

#### Scenario: The start action is withheld while a start is outstanding

- **GIVEN** a repository list in `embedded` that has issued a `startNode` call
  which has not been answered
- **THEN** no action MUST be named
- **AND WHEN** the call is answered with `{"error":"..."}`
- **THEN** the named action MUST be the one that starts the node

### Requirement: A refused start is displayed as the backend worded it

When a `startNode` call is answered with `{"error":"..."}`, the surface MUST
display that message as the backend worded it, and MUST go on naming the action
that starts the node, so the state does not read as terminal.

The module's refusals name the socket that was in use, the passphrase that did
not unlock the key, and the home that was in the way. A summary in the view's
own words would drop each of those, and a wrong passphrase — the most likely
refusal, since an encrypted key must be unlocked at every start — is only
actionable when it is named.

A refused start MUST NOT be rendered as a running node, and MUST NOT be rendered
as the **starting** state.

A subsequent successful start MUST clear the displayed message.

#### Scenario: Two different refusals display two different messages

- **GIVEN** a repository list in `embedded` whose `startNode` is answered with
  one distinctive message
- **THEN** that message MUST be displayed
- **AND** the named action MUST be the one that starts the node
- **AND WHEN** a further start is answered with a different distinctive message
- **THEN** the second message MUST be displayed and the first MUST NOT

#### Scenario: A success clears a displayed refusal

- **GIVEN** a repository list in `embedded` displaying a start refusal
- **WHEN** a subsequent `startNode` is answered reporting the node started
- **THEN** no refusal message MUST be displayed

### Requirement: The surface offers setup without performing it

In the **no identity** state the surface MUST offer an action that opens the
guided setup, and MUST state before it is taken that the embedded node runs as
a new identity this module creates, separate from any Radicle node the user
already runs.

Taking that action MUST do no more than request that the setup be opened. The
surface MUST NOT create an identity, MUST NOT start a node and MUST NOT write
the mode, and MUST NOT perform any of those as a consequence of merely being
rendered — a state panel that acts because it was displayed acts without being
asked.

How the setup is hosted, and the steps it then walks, are not this capability's:
they are `embedded-setup`'s.

#### Scenario: Rendering the state writes nothing

- **GIVEN** a repository list in `embedded` told `exists:false`
- **WHEN** the no-identity state is rendered
- **THEN** no `createEmbeddedIdentity` call MUST have been issued
- **AND** no `startNode` call MUST have been issued
- **AND** no `setSetting` call MUST have been issued

#### Scenario: The action requests setup rather than performing it

- **GIVEN** a repository list in `embedded` told `exists:false`
- **WHEN** the action that opens the guided setup is invoked
- **THEN** the request to open the setup MUST have been emitted exactly once
- **AND** no `createEmbeddedIdentity` call MUST have been issued

#### Scenario: The separate-identity consequence is stated before setup is opened

- **GIVEN** a repository list in `embedded` told `exists:false`
- **THEN** the rendered sentence MUST state that the node runs as a new
  identity, separate from any Radicle node the user already runs

### Requirement: An unencrypted identity starts its node without being asked

While the mode in force is `embedded`, the state is **stopped**, and
`getEmbeddedIdentity()` reports `encrypted:false`, the surface MUST issue
`startNode` with an empty passphrase without the user taking any action.

A user who has set an embedded node up has asked for a node. Requiring them to
press a control the module could have pressed itself — every time the mode is
opened, for the life of the mode — is asking for an act with one possible
answer. The node can be started here and only here without a secret, so this is
the one case where starting unasked costs the user nothing to decline, because
there is nothing to decline.

The start MUST be issued **once per arrival in the stopped state**, and MUST NOT
be re-issued while the call is outstanding or after it has been answered, until
the state has left **stopped** and returned to it. A surface that re-issued on
every reading would start a node repeatedly against a backend that is slow to
answer.

A start issued this way MUST be reported through the same states as one a user
asked for: the state MUST be **starting** while it is outstanding, and a refusal
MUST put it in **start failed** with the backend's message displayed. It MUST
NOT be reported more quietly for having been automatic — a node that failed to
start is the same fact either way, and a user who never pressed anything has
less context, not more.

The automatic start MUST NOT happen in any other state. In **blocked** and **no
identity** there is nothing to start; in **not serving** the runtime is still
loaded and a bare start would be refused; in **start failed** a start has
already been tried and answered, and retrying unasked would loop against a
backend that refuses every time.

#### Scenario: A stopped node with an unencrypted key starts by itself

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:false`, and a node reporting `running:false` and `serving:false`
- **WHEN** the state is rendered, with no action taken
- **THEN** exactly one `startNode` call MUST have been issued
- **AND** its passphrase argument MUST be the empty string
- **AND** the rendered state MUST be the starting one

#### Scenario: The automatic start is issued once, not on every reading

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:false` and a node reporting `running:false` and `serving:false`,
  whose `startNode` reply is withheld
- **WHEN** the backend reports the same node status a second and a third time
- **THEN** exactly one `startNode` call MUST have been issued

#### Scenario: A refused automatic start is reported as a refusal

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:false` and a stopped node, whose `startNode` is answered with a
  distinctive message
- **THEN** the rendered state MUST be the start-failed one
- **AND** that message MUST be displayed

#### Scenario: No automatic start where there is nothing to start

- **GIVEN** a repository list in `embedded` told `exists:false`
- **THEN** no `startNode` call MUST have been issued
- **AND WHEN** the same list is instead told a non-empty `pathsProblem`
- **THEN** no `startNode` call MUST have been issued
- **AND WHEN** the same list is instead told `exists:true` with
  `encrypted:false` and a node reporting `running:true` with `serving:false`
- **THEN** no `startNode` call MUST have been issued

### Requirement: An encrypted identity is asked for its passphrase, not sent to a flow

While the mode in force is `embedded`, the state is **stopped**, and
`getEmbeddedIdentity()` reports `encrypted:true`, the surface MUST offer a field
to type a passphrase into and a control that starts the node with what was
typed. It MUST NOT start the node unasked, because it has no passphrase to start
it with.

That prompt MUST be **one field on this surface**, not a step of the guided
setup and not a separate flow. A passphrase is one answer to one question asked
at one moment; routing it through a multi-step flow would make the user walk
steps whose work is already done to reach the only one that is not.

The surface MUST NOT display the passphrase as it is typed, and MUST NOT retain
it after the reply to the `startNode` call it was submitted with. A refused
start MUST leave the field available so a mistyped passphrase can be corrected,
and the refusal MUST be displayed as the backend worded it — a wrong passphrase
is the most likely refusal, and it is only actionable when it is named.

The distinction between the two states MUST be derived from the reported
`encrypted` field, so that a surface told the same node status with a different
`encrypted` value behaves differently. It MUST NOT be derived from whether a
start has previously failed, which would make the prompt a consequence of an
error rather than of the identity's own nature.

#### Scenario: An encrypted identity prompts rather than starting

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:true`, and a node reporting `running:false` and `serving:false`
- **THEN** no `startNode` call MUST have been issued
- **AND** a field for a passphrase MUST be present
- **AND** the request to open the guided setup MUST NOT have been emitted

#### Scenario: The same node status behaves differently on the encrypted field

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:true` and a node reporting `running:false` and `serving:false`
- **THEN** no `startNode` call MUST have been issued
- **AND WHEN** the same list is told the identical node status with
  `encrypted:false`
- **THEN** exactly one `startNode` call MUST have been issued

#### Scenario: The typed passphrase is the one submitted

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:true` and a stopped node, with `correct horse battery` typed into
  the passphrase field
- **WHEN** the control that starts the node is invoked
- **THEN** exactly one `startNode` call MUST have been issued
- **AND** its passphrase argument MUST be `correct horse battery`

#### Scenario: A refused passphrase can be corrected

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:true` and a stopped node, whose `startNode` is answered with a
  distinctive message
- **WHEN** a passphrase is submitted
- **THEN** that message MUST be displayed
- **AND** the passphrase field MUST still be present
- **AND WHEN** a second passphrase is submitted against a backend that now
  reports the node started
- **THEN** that message MUST NOT be displayed

#### Scenario: The passphrase does not outlive its call

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:true` and a stopped node
- **WHEN** a passphrase is submitted and the reply reporting the node started
  has arrived
- **THEN** the surface MUST NOT retain that passphrase

### Requirement: A node this module started is not reported as one in the way

A node answering the resolved socket MUST be reported as an obstacle only when
this module did not start it. When the module's own start is what put a node on
that socket, the surface MUST report that the node is running — which is the
outcome the user wanted — and MUST NOT report that something is contending for
the socket.

This is the defect the setup flow shipped and the reason starting moved here: a
screen warned that "a node is already answering on the resolved socket" directly
above its own report that the node was running and serving. Both sentences were
derived from true readings, and together they described a conflict that did not
exist, because the node being warned about was the one the module had just
started. A correct fact rendered as a hazard when it describes the user's own
success is worse than no fact, because it sends a user looking for a second node
that is not there.

The surface MUST therefore distinguish the two by whether a `startNode` call it
issued was answered with a success, and MUST NOT distinguish them by the node
status alone, which reports the same fields for both.

A node found already serving when the module has started none MUST still be
reported as such, because that one genuinely is somebody else's and a start
against it will be refused.

#### Scenario: A node this surface started reads as running, not as contention

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:false` and a stopped node, whose `startNode` is answered reporting
  the node started, and whose node then reports `serving:true`
- **THEN** the rendered text MUST NOT state that a node is already answering on
  the socket
- **AND** the rendered text MUST NOT state that starting a second node would
  contend for it

#### Scenario: A node the surface did not start is still reported as found

- **GIVEN** a repository list in `embedded` told `exists:true` with
  `encrypted:true` and a node reporting `serving:true`, with no `startNode`
  call ever issued by this surface
- **THEN** the rendered text MUST state that a node is already answering on the
  socket
- **AND** no `startNode` call MUST have been issued

### Requirement: Only an action something can carry out is offered as enabled

The surface MUST render an action as enabled only when a request it emits reaches
something able to carry it out. An action whose request reaches nobody MUST NOT be
enabled, and the surface MUST say why rather than render a disabled control with
no explanation.

A control that is enabled, looks ordinary and does nothing when taken is worse
than no control at all: it reads as a module that is broken rather than as one
that has not built this yet, and it gives a user no other thing to try. That is
the dead end this capability was written to remove, and re-creating it one state
along would be the same defect.

The request that opens the guided setup reaches a host, and so does the request
that starts a node: this capability hosts starting, and `getEmbeddedIdentity()`
reports `encrypted`, which is what makes a passphrase askable here.

The request that **restarts** a node does not reach a host. A restart is a stop
followed by a start, whose two refusals are different sentences a user should
see separately, and nothing sequences the pair. So the **not serving** state MUST
name its action while leaving it not enabled, and MUST state that restarting the
node is not yet available from here — not that it failed, and not that the node
cannot be restarted at all.

This MUST be keyed on whether the action's request is hosted, so that hosting one
makes it enabled with nothing else changed. A surface hard-coding which states are
enabled would have to be edited again, by someone who has to notice it, at the
moment the host appears.

#### Scenario: An unhosted action is named but not enabled, and says so

- **GIVEN** a repository list in `embedded` told `exists:true` with a node
  reporting `running:true` and `serving:false` and no start outstanding
- **THEN** the named action MUST be the one that restarts the node
- **AND** it MUST NOT be enabled
- **AND** the rendered text MUST state that restarting the node is not yet
  available from here
- **AND WHEN** the same list is told `exists:false`
- **THEN** the named action MUST be the one that opens the guided setup
- **AND** it MUST be enabled
- **AND** the rendered text MUST NOT state that it is unavailable

#### Scenario: Hosting an action is what enables it

- **GIVEN** a repository list in `embedded` told `exists:true` with a node
  reporting `running:true` and `serving:false`, and told that the request to
  restart a node reaches nobody
- **THEN** the named action MUST NOT be enabled
- **AND WHEN** the same list is told that the request to restart a node reaches
  a host, with nothing else changed
- **THEN** the named action MUST be enabled
- **AND** the rendered text MUST NOT state that it is unavailable

#### Scenario: An action that is not enabled emits no request

- **GIVEN** a repository list in `embedded` told `exists:true` with a node
  reporting `running:true` and `serving:false` and no start outstanding
- **WHEN** the rendered action is taken
- **THEN** no request MUST have been emitted
- **AND** no `stopNode` call MUST have been issued

### Requirement: The blank-pane assertion keeps a live referent

The module MUST expose an observable that is true exactly when the repository
list is showing no rows, no placeholder and no state panel — the blank pane that
no other assertion can see, because an empty row count is equally true of a
legitimately empty node.

That observable MUST be computed from the rendered items' own visibility rather
than from a copy of the conditions those items are keyed on. A recomputed copy
agrees with the items whether or not either actually renders, which is the
fixture that answers the same for every input.

Replacing the item this observable reads MUST carry the observable to the
replacement. An observable naming an item that no longer exists silently reduces
to a constant, and the end-to-end assertion that consumes it stops being able to
fail — while continuing to pass.

#### Scenario: The blank-pane observable is false whenever a state is rendered

- **GIVEN** a repository list in `embedded` with no rows, in each of the
  blocked, no-identity, stopped, starting, start-failed and not-serving states
  in turn
- **THEN** the blank-pane observable MUST be false in each case

#### Scenario: The observable follows the rendered item, not a recomputed copy

- **GIVEN** a repository list in `embedded` with no rows, whose state panel is
  prevented from rendering while the conditions selecting that state are
  unchanged
- **THEN** the blank-pane observable MUST be true
