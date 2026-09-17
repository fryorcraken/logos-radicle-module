## Purpose
Read and write the fields of the embedded node's own `config.json` that a
configuration panel needs, as a surface separate from the module's five
settings: which fields are exposed, the JSON shapes they take, what is refused
on write, and when a change reaches a running node.

## ADDED Requirements

### Requirement: The node configuration is a separate surface from the module settings

The module MUST expose node configuration through its own pair of methods,
`getNodeConfig` and `setNodeConfig`, and MUST NOT route it through `getSettings`
or `setSetting`.

The two surfaces describe different things and live in different files. The
module settings describe the module — which node it is pointed at, where git is
— and live in `<XDG data home>/radicle-module/settings.json`. The node
configuration describes the node itself and lives in `<radicle home>/config.json`,
a file the node owns and reads at start.

`getSettings` MUST continue to return exactly the five keys the
`module-settings` capability names, and MUST NOT gain a node-configuration key.
`setSetting` MUST continue to refuse any key outside those five.

#### Scenario: The settings surface is unchanged by this capability

- **WHEN** `getSettings` is called
- **THEN** the reply MUST contain exactly the five keys `mode`, `radHome`,
  `radSocket`, `gitPath` and `remoteSeed`
- **AND** it MUST NOT contain `alias`, `listen`, `externalAddresses`, `connect`
  or `peers`

#### Scenario: A node-configuration key is not a module setting

- **WHEN** `setSetting` is called with the key `listen`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST contain the text `listen`

### Requirement: The exposed fields are the ones the crate has

`getNodeConfig` MUST report exactly these fields, and `setNodeConfig` MUST
accept exactly these fields:

- `alias` — the node's alias, a string.
- `listen` — the socket addresses the node binds, an array of strings.
- `externalAddresses` — the node's own public addresses, an array of strings.
- `connect` — the peers to connect to at start and keep connected, an array of
  strings.
- `peers` — the peer-set discipline, one of the strings `static` or `dynamic`.

Each MUST be spelled in the reply exactly as the node's `config.json` spells it,
so a value read here and a value read from that file cannot disagree about a
name.

`getNodeConfig` MUST additionally report two **derived** members, which are not
configuration fields and MUST NOT be accepted by `setNodeConfig`:
`inboundReachable` and `restartRequired`, each specified by its own requirement
below.

A field the module does not expose MUST NOT appear in a `getNodeConfig` reply,
and MUST be refused by name when passed to `setNodeConfig`.

A successful `setNodeConfig` MUST return the whole configuration object, in the
same shape `getNodeConfig` returns, rather than only the fields that changed —
so a caller re-renders from one reply instead of holding a stale view of the
fields it did not just set. `setNodeConfig` MUST accept a subset of the fields
and MUST leave the fields it was not given unchanged.

The `peers` field is a discipline, not a list: the addresses live in `connect`.
A caller MUST NOT be able to submit addresses through `peers`. A value other
than `static` or `dynamic` MUST be refused with a message naming both.

`peers` set to `static` with an empty `connect` MUST be refused rather than
stored: it configures a node to maintain connections to nobody, which reaches
no peers and reports no error at any later point.

#### Scenario: Every exposed field is present in a reply

- **WHEN** `getNodeConfig` is called against a home holding a node
  configuration
- **THEN** the reply MUST contain all five of `alias`, `listen`,
  `externalAddresses`, `connect` and `peers`
- **AND** it MUST contain `inboundReachable` and `restartRequired`
- **AND** it MUST contain no key other than those seven

#### Scenario: A derived member cannot be written

- **WHEN** `setNodeConfig` is called with the field `restartRequired`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST contain the text `restartRequired`

#### Scenario: A successful write returns the whole configuration object

- **WHEN** `setNodeConfig` accepts a call naming only `alias`
- **THEN** the reply MUST be the same shape `getNodeConfig` returns, containing
  all five configuration fields and both derived members
- **AND** the reply MUST carry no `error` member
- **AND** the four fields the call did not name MUST hold the values they held
  before it

#### Scenario: A field the module does not expose is refused by name

- **WHEN** `setNodeConfig` is called with the field `workers`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST contain the text `workers`
- **AND** a subsequent `getNodeConfig` reply MUST contain no key `workers`

#### Scenario: A peer discipline the module does not know is refused

- **WHEN** `setNodeConfig` sets `peers` to `manual`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST contain `static` and `dynamic`

#### Scenario: Static with nobody to connect to is refused

- **WHEN** `setNodeConfig` sets `peers` to `static` against a configuration
  whose `connect` is empty, without also setting `connect`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** a subsequent `getNodeConfig` reply's `peers` MUST be unchanged
- **AND WHEN** `setNodeConfig` sets `peers` to `static` and `connect` to a
  non-empty list of addresses in one call
- **THEN** the reply MUST NOT be an error

#### Scenario: peers carries a discipline rather than addresses

- **WHEN** `setNodeConfig` is called with `peers` set to an array of addresses
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** a subsequent `getNodeConfig` reply's `peers` MUST be one of the
  strings `static` or `dynamic`

### Requirement: Addresses are the two spellings the crate distinguishes

`connect` entries MUST each carry a node id, in the form
`<node id>@<host>:<port>`. `externalAddresses` entries MUST each be a bare
`<host>:<port>` with no node id.

The two spellings are not interchangeable, and a value in the wrong one MUST be
refused on write rather than stored: the crate parses these as distinct types,
so a mismatched value fails at the node's next start, which is the deferred
failure this module's validation-on-write rule exists to prevent.

`listen` entries MUST each be a bare `<host>:<port>`.

A refusal MUST name the value that was rejected and state which spelling was
expected.

#### Scenario: A connect address without a node id is refused

- **WHEN** `setNodeConfig` sets `connect` to `["seed.example.test:8776"]`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST contain `seed.example.test:8776`
- **AND** a subsequent `getNodeConfig` reply's `connect` MUST be unchanged

#### Scenario: An external address carrying a node id is refused

- **WHEN** `setNodeConfig` sets `externalAddresses` to
  `["z6MkrLMM@seed.example.test:8776"]`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** a subsequent `getNodeConfig` reply's `externalAddresses` MUST be
  unchanged

#### Scenario: Each spelling is accepted in its own field

- **WHEN** `setNodeConfig` sets `connect` to
  `["z6MkrLMM@seed.example.test:8776"]` and `externalAddresses` to
  `["node.example.test:8776"]`
- **THEN** the reply MUST NOT be an error
- **AND** a subsequent `getNodeConfig` reply MUST report both values as
  submitted

### Requirement: The alias is validated against the crate's own rule

`setNodeConfig` MUST refuse an `alias` the `radicle` crate does not accept, and
MUST pass through the crate's own statement of the rule rather than paraphrasing
it.

An alias MUST be non-empty, MUST contain no whitespace and no control
character, and MUST be at most 32 bytes. The limit is on bytes, not characters,
so an alias of 32 or fewer characters can still be refused.

A refused alias MUST leave the stored alias unchanged.

#### Scenario: An alias with whitespace is refused

- **WHEN** `setNodeConfig` sets `alias` to `my node`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** a subsequent `getNodeConfig` reply's `alias` MUST be the value stored
  before the call

#### Scenario: An empty alias is refused

- **WHEN** `setNodeConfig` sets `alias` to the empty string
- **THEN** the reply MUST be `{"error":"..."}`

#### Scenario: The length limit is measured in bytes

- **WHEN** `setNodeConfig` sets `alias` to a value of 32 bytes
- **THEN** the reply MUST NOT be an error
- **AND WHEN** `setNodeConfig` sets `alias` to a value of 33 bytes
- **THEN** the reply MUST be `{"error":"..."}`

#### Scenario: A multi-byte alias is measured the same way

- **WHEN** `setNodeConfig` sets `alias` to a value of 12 characters whose UTF-8
  encoding exceeds 32 bytes
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** a subsequent `getNodeConfig` reply's `alias` MUST be unchanged

### Requirement: Inbound is off by default and its cost is stated

A node configuration that has never set `listen` MUST report `listen` as an
empty array, and the node MUST bind no port.

`getNodeConfig` MUST report `inboundReachable`, false exactly when `listen` is
empty. A node with no listen address is outbound-only: it can fetch from peers
and announce to them, but peers cannot fetch from it.

Turning inbound on is an explicit act. `setNodeConfig` MUST NOT add a listen
address on its own — not when `externalAddresses` is set, not when `connect` is
set, and not when the node is started.

A view MUST state what leaving inbound off costs, in words naming that peers
cannot fetch from this node, wherever it offers the choice.

#### Scenario: A configuration that never set listen is outbound-only

- **WHEN** `getNodeConfig` is called against a home whose configuration has
  never set `listen`
- **THEN** `listen` MUST be an empty array
- **AND** `inboundReachable` MUST be false

#### Scenario: Setting an external address does not turn inbound on

- **WHEN** `setNodeConfig` sets `externalAddresses` to
  `["node.example.test:8776"]` against a configuration whose `listen` is empty
- **THEN** the reply MUST NOT be an error
- **AND** a subsequent `getNodeConfig` reply's `listen` MUST still be an empty
  array
- **AND** `inboundReachable` MUST still be false

#### Scenario: Setting a listen address turns inbound on

- **WHEN** `setNodeConfig` sets `listen` to `["0.0.0.0:8776"]`
- **THEN** a subsequent `getNodeConfig` reply's `listen` MUST be
  `["0.0.0.0:8776"]`
- **AND** `inboundReachable` MUST be true

#### Scenario: The panel states what inbound off means

- **WHEN** a view offers the inbound choice
- **THEN** it MUST display text saying that with inbound off, peers cannot
  fetch from this node

### Requirement: A configured listen address is what the node binds

Starting the node MUST bind the addresses the configuration's `listen` names,
and MUST NOT discard them. An empty `listen` MUST bind no port.

The started node's reported `listening` MUST be derived from the addresses the
node actually bound, not echoed from the configuration: a reply that repeated
its input would be identical whether the configuration was honoured or ignored.

#### Scenario: Two configurations produce two different bound states

- **WHEN** a node is started against a home whose `listen` is empty
- **THEN** the start reply's `listening` MUST be an empty array
- **AND WHEN** a node is started against a home whose `listen` names a port
- **THEN** the start reply's `listening` MUST be non-empty
- **AND** it MUST name that port

#### Scenario: A port that cannot be bound fails the start rather than falling back

- **WHEN** a node is started against a home whose `listen` names a port already
  bound by something else
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the node MUST NOT be reported as running
- **AND** the start MUST NOT fall back to binding no port, which would report
  success for a configuration it did not honour

### Requirement: A configuration change reaches the node at its next start

`setNodeConfig` MUST write the configuration and MUST NOT apply it to a running
node. The node reads its configuration when it is constructed, so there is no
later point at which a change could take effect.

`getNodeConfig` MUST report `restartRequired`, true exactly when a node is
running and the configuration on disk differs from the one that node was started
with.

A view MUST say that a change takes effect at the next start rather than imply
it is live.

#### Scenario: A write while a node runs does not change the running node

- **WHEN** a node is running and `setNodeConfig` changes `alias`
- **THEN** the reply MUST NOT be an error
- **AND** `getNodeStatus` MUST still report the node as running
- **AND** `getNodeConfig` MUST report `restartRequired` as true

#### Scenario: Nothing running means nothing to restart

- **WHEN** no node is running and `setNodeConfig` changes `alias`
- **THEN** `getNodeConfig` MUST report `restartRequired` as false

#### Scenario: A restart clears the pending state

- **WHEN** `getNodeConfig` reports `restartRequired` as true
- **AND** the node is stopped and started again
- **THEN** `getNodeConfig` MUST report `restartRequired` as false

#### Scenario: The panel states the restart-to-apply terms

- **WHEN** a view offers a node-configuration field
- **THEN** it MUST display text saying that a change takes effect the next time
  the node is started

### Requirement: A write preserves the fields it does not set

`setNodeConfig` MUST change only the fields the call names, and MUST leave every
other field of `config.json` as it found it — including fields this module does
not expose, and including fields a newer build of the `radicle` crate wrote that
this build does not know.

This does not hold by default. A write MUST preserve a key even when no field of
this build's configuration type corresponds to it, so that a change of one field
never becomes the deletion of another.

A write MUST leave the file parseable as a node configuration. A write that
cannot be completed MUST leave the previous file intact rather than a truncated
one.

#### Scenario: An unrelated known field survives a write

- **WHEN** a configuration holds a non-default value for a field this module
  does not expose
- **AND** `setNodeConfig` changes `alias`
- **THEN** that field MUST still hold its previous value afterwards

#### Scenario: A key this build does not know survives a write

- **WHEN** `config.json` holds a key no field of this build's configuration type
  corresponds to
- **AND** `setNodeConfig` changes `alias`
- **THEN** that key MUST still be present afterwards with its previous value
- **AND** the changed `alias` MUST be the value written

#### Scenario: A failed write leaves the previous configuration

- **WHEN** `setNodeConfig` is refused because a value did not validate
- **THEN** `config.json` MUST be byte-for-byte what it was before the call

### Requirement: The configuration read is of the mode's own home

`getNodeConfig` and `setNodeConfig` MUST act on the home the mode in force
resolved, and MUST NOT take a home as a parameter.

A home parameter crosses the boundary from a sandboxed view, and would be a way
for a caller to rewrite the configuration of a node the module does not own.

In `explore`, which resolves no home, both MUST return `{"error":"..."}` naming
the mode rather than failing obscurely, and `setNodeConfig` MUST write nothing
anywhere.

In `local`, the resolved home is the user's own. Writing there changes the
configuration of a node this module did not create and does not run.
`setNodeConfig` MUST refuse in `local`, naming the mode; `getNodeConfig` MUST
succeed, because reading the user's configuration is what lets a view show it.

#### Scenario: Neither method takes a home

- **WHEN** a caller invokes either method across the module boundary
- **THEN** the method signature MUST expose no home argument, so no argument
  value can change which file is read or written

#### Scenario: Explore has no configuration to read

- **WHEN** the mode is `explore` and `getNodeConfig` is called
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST name the mode

#### Scenario: Local is readable but not writable

- **WHEN** the mode is `local` against a home holding a node configuration
- **THEN** `getNodeConfig` MUST report that home's configuration rather than an
  error
- **AND** `setNodeConfig` MUST return `{"error":"..."}` naming the mode
- **AND** that home's `config.json` MUST be unchanged afterwards

#### Scenario: Embedded reads and writes its own home

- **WHEN** the mode is `embedded` with an identity created in its home, and
  `setNodeConfig` changes `alias`
- **THEN** the reply MUST NOT be an error
- **AND** the `config.json` under the embedded home MUST carry the new alias
- **AND** no file under the home `local` would have resolved MUST have changed

### Requirement: A home with no configuration is reported as such

`getNodeConfig` MUST return `{"error":"..."}` when the resolved home holds no
`config.json`, naming the home and stating that no identity has been created
there.

It MUST NOT return a set of defaults for a home that has none: defaults
presented as a configuration are indistinguishable on screen from a real one,
and a view would offer to edit a node that does not exist.

`setNodeConfig` MUST refuse likewise, and MUST NOT bring a home or a
configuration into existence. Creating a configuration is identity creation's
job.

#### Scenario: An empty embedded home has no configuration

- **WHEN** the mode is `embedded`, no identity has been created, and
  `getNodeConfig` is called
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST name the resolved home

#### Scenario: A write does not create a configuration

- **WHEN** the mode is `embedded`, no identity has been created, and
  `setNodeConfig` is called
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** no `config.json` MUST exist under that home afterwards

### Requirement: Every failure crosses the boundary as JSON

Neither method may propagate a panic or an unwind across the FFI boundary. Every
call MUST return a well-formed JSON string: either the documented success shape
or `{"error":"..."}`.

A `config.json` that does not parse MUST come back as an error naming the file,
rather than as a crash, an empty string or a set of defaults.

#### Scenario: An unparseable configuration answers with an error object

- **WHEN** `config.json` under the resolved home contains text that is not JSON
- **THEN** `getNodeConfig` MUST return a parseable JSON string carrying a
  string `error` field
- **AND** the message MUST name the file

#### Scenario: A null argument answers with an error object

- **WHEN** the configuration backend is invoked across the FFI boundary with a
  null home pointer
- **THEN** the call MUST return a non-null, parseable JSON string
- **AND** it MUST carry a string `error` field

### Requirement: A view renders the configuration from the reply it was given

A view MUST populate itself from a `getNodeConfig` reply rather than from its
own assumptions, and MUST re-render from the object a successful `setNodeConfig`
returns rather than from the value it submitted.

A refusal MUST be surfaced to the user verbatim — the messages name the value
that was rejected and the spelling that was expected — and the displayed
configuration MUST NOT change. A subsequent successful write MUST clear a
previously displayed refusal.

#### Scenario: The panel shows the stored configuration

- **WHEN** a node-configuration view is loaded against a configuration whose
  `alias` is `stored-alias`
- **THEN** the view's reported alias MUST be `stored-alias`

#### Scenario: Two different configurations give two different view states

- **WHEN** the view is loaded against a configuration whose `alias` is `alpha`,
  and again against one whose `alias` is `beta`
- **THEN** the view's reported alias MUST be `alpha` after the first and `beta`
  after the second

#### Scenario: A refused value is shown and changes nothing

- **WHEN** the user saves a value the backend refuses
- **THEN** the view MUST display the refusal message returned by the backend
- **AND** the view's reported value for that field MUST be unchanged

#### Scenario: A successful write clears a previous refusal

- **WHEN** the view is displaying a refusal message
- **AND** a subsequent write is accepted
- **THEN** the view MUST no longer report an error
