## Purpose
Seed a repository with a scope, unseed it, and report what is seeded — the
operation that makes a private repository actually replicate, which allow-listing
a DID alone does not.

## ADDED Requirements

### Requirement: Seeding is a policy, not a question about stored repositories

The module MUST expose seeding through `listSeeded`, `seedRepo` and
`unseedRepo`, and these MUST report and change the node's **seeding policy**.

A seeding policy is a decision about what this node will replicate. It is a
different question from `localListRepos("seeded")`, which reports repositories
already present in local storage that this node is neither a delegate of nor
which are private. The two disagree in both directions, and both disagreements
are ordinary rather than faults: a repository can be seeded by policy with
nothing yet replicated, and a repository can sit in storage with no policy
seeding it.

`listSeeded` MUST report policies. It MUST NOT be implemented by filtering
storage, and MUST NOT omit a seeded RID merely because nothing has replicated
for it yet.

#### Scenario: A newly seeded RID is listed before anything replicates

- **WHEN** `seedRepo` succeeds for an RID that is not in local storage
- **THEN** `listSeeded` MUST include that RID
- **AND** `localListRepos` with scope `seeded` MUST NOT include it

#### Scenario: The two surfaces are not derived from one another

- **WHEN** a repository is present in local storage with no seeding policy for
  it
- **THEN** `listSeeded` MUST NOT include that RID
- **AND** `localListRepos` with scope `all` MUST include it

### Requirement: Seeding takes a scope and the scope is reported back

`seedRepo(rid, scope)` MUST accept a scope of `all` or `followed`, and MUST
refuse any other value with `{"error":"..."}` naming both valid scopes.

`listSeeded` MUST report each entry's scope alongside its RID, as
`{"items":[{"rid":"...","scope":"all"|"followed"}]}`.

The scope is not cosmetic and MUST NOT be defaulted silently on the caller's
behalf: `all` seeds every remote, `followed` seeds only delegates and explicitly
followed nodes, and the difference decides whether a private repository
replicates at all.

Seeding an RID that is already seeded with a different scope MUST replace the
scope rather than add a second entry.

#### Scenario: Both scopes are accepted and reported back

- **WHEN** `seedRepo` is called for one RID with scope `all` and for another
  with scope `followed`
- **THEN** neither reply MUST be an error
- **AND** `listSeeded` MUST report the first RID with scope `all` and the
  second with scope `followed`

#### Scenario: A scope the module does not know is refused

- **WHEN** `seedRepo` is called with scope `everything`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST contain `all` and `followed`
- **AND** `listSeeded` MUST NOT include that RID

#### Scenario: Re-seeding with a different scope replaces the scope

- **WHEN** `seedRepo` succeeds for an RID with scope `followed`
- **AND** `seedRepo` is then called for the same RID with scope `all`
- **THEN** `listSeeded` MUST report that RID exactly once
- **AND** its scope MUST be `all`

### Requirement: Unseeding removes the policy and is idempotent

`unseedRepo(rid)` MUST remove the seeding policy for that RID, after which
`listSeeded` MUST NOT include it.

Unseeding an RID that is not seeded MUST be an answer rather than an error: the
caller has got what it asked for. The reply MUST distinguish the two outcomes so
a view can say which happened, as `{"unseeded":bool}`.

Unseeding MUST NOT delete anything from local storage. A policy and a
replicated copy are different things, and removing a policy is reversible where
deleting storage is not.

#### Scenario: Unseeding removes the entry

- **WHEN** `seedRepo` has succeeded for an RID
- **AND** `unseedRepo` is called for that RID
- **THEN** the reply MUST report `unseeded` as true
- **AND** `listSeeded` MUST NOT include that RID

#### Scenario: Unseeding what is not seeded is an answer

- **WHEN** `unseedRepo` is called for an RID that `listSeeded` does not include
- **THEN** the reply MUST NOT contain an `error`
- **AND** it MUST report `unseeded` as false

#### Scenario: Unseeding leaves storage alone

- **WHEN** a repository is present in local storage and seeded by policy
- **AND** `unseedRepo` is called for its RID
- **THEN** `localListRepos` with scope `all` MUST still include that RID

### Requirement: An RID that is not one is refused before anything is written

`seedRepo` and `unseedRepo` MUST refuse a value that is not a well-formed
repository id, with `{"error":"..."}` naming the value that was rejected, and
MUST write nothing.

A malformed RID accepted into the policy store would be a policy that can never
match a repository, invisible except as a repository that mysteriously never
replicates.

#### Scenario: A malformed RID creates no policy

- **WHEN** `seedRepo` is called with the RID `not-a-rid` and scope `all`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST contain `not-a-rid`
- **AND** `listSeeded` MUST NOT include any entry for it

#### Scenario: Unseeding a malformed RID is refused rather than ignored

- **WHEN** `unseedRepo` is called with the RID `not-a-rid`
- **THEN** the reply MUST be `{"error":"..."}`

### Requirement: Seeding acts on the mode's own node and takes no home

None of the three methods MUST accept a Radicle home as a parameter. Each MUST
act on the home the mode in force resolved, for the same reason the node
configuration methods do: a home crossing the boundary from a sandboxed view is
a way to rewrite the policies of a node the module does not own.

In `explore`, which resolves no home, all three MUST return `{"error":"..."}`
naming the mode.

In `local`, the node is the user's own. `listSeeded` MUST succeed, so a view can
show what that node seeds. `seedRepo` and `unseedRepo` MUST refuse, naming the
mode, and MUST write nothing.

#### Scenario: No method takes a home

- **WHEN** a caller invokes any of the three across the module boundary
- **THEN** the method signature MUST expose no home argument

#### Scenario: Explore has no node to seed on

- **WHEN** the mode is `explore` and `seedRepo` is called
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST name the mode

#### Scenario: Local is readable but not writable

- **WHEN** the mode is `local` against a home holding a node
- **THEN** `listSeeded` MUST report that node's policies rather than an error
- **AND** `seedRepo` MUST return `{"error":"..."}` naming the mode
- **AND** that home's policies MUST be unchanged afterwards

#### Scenario: Embedded seeds its own node

- **WHEN** the mode is `embedded` with an identity created in its home, and
  `seedRepo` succeeds for an RID
- **THEN** `listSeeded` MUST include that RID
- **AND** the policy store under the embedded home MUST hold it
- **AND** no policy store under the home `local` would have resolved MUST have
  been created or changed

#### Scenario: Two homes yield two different policy sets

- **WHEN** an RID is seeded against one home and a different RID against
  another, where neither path is a prefix of the other
- **THEN** each home's `listSeeded` MUST report its own RID
- **AND** neither MUST report the other's, so the two are distinguishable by
  their answer alone rather than only by their paths

### Requirement: A seeding change does not need a node restart

A policy written by `seedRepo` or `unseedRepo` MUST be visible to `listSeeded`
immediately, whether or not a node is running.

Seeding is stored separately from the node's `config.json`, so unlike a
configuration change it MUST NOT set `restartRequired`.

#### Scenario: A policy written while a node runs is visible at once

- **WHEN** a node is running and `seedRepo` succeeds for an RID
- **THEN** `listSeeded` MUST include that RID without the node being restarted
- **AND** `getNodeConfig` MUST report `restartRequired` as false

#### Scenario: A policy written with no node running is visible at once

- **WHEN** no node is running and `seedRepo` succeeds for an RID
- **THEN** `listSeeded` MUST include that RID

### Requirement: The allow-is-not-enough consequence is stated where it applies

Allow-listing a DID on a repository's identity document does not make that
repository replicate to this node. Every node that is to hold it must also seed
its RID, and a private repository requires the scope `all`.

A view offering the seeding surface MUST state that, in words naming both halves
— the delegate's allow-listing and this node's seeding — wherever it presents a
repository as not replicating.

A view MUST NOT present a seeded RID with scope `followed` as sufficient for a
private repository.

#### Scenario: The seeding view states both halves

- **WHEN** a view offers the seeding surface
- **THEN** it MUST display text stating that a delegate allow-listing this
  node's DID is not sufficient on its own
- **AND** that text MUST state that this node must also seed the repository

#### Scenario: A private repository's requirement names the scope

- **WHEN** a view offers a scope choice for a repository it presents as private
- **THEN** it MUST display text stating that scope `all` is required

### Requirement: Every failure crosses the boundary as JSON

None of the three methods may propagate a panic or an unwind across the FFI
boundary. Every call MUST return a well-formed JSON string: either the
documented success shape or `{"error":"..."}`.

A policy store that cannot be opened MUST come back as an error naming the
problem, rather than as a crash, an empty string or an empty list. An empty list
means "nothing is seeded", which is a different fact from "the policies could not
be read", and a view acting on the first when the second is true would offer to
seed a repository that is already seeded.

#### Scenario: An unopenable policy store is an error, not an empty list

- **WHEN** the policy store under the resolved home cannot be opened
- **THEN** `listSeeded` MUST return a reply carrying a string `error` field
- **AND** it MUST NOT return an items array

#### Scenario: A null argument answers with an error object

- **WHEN** the seeding backend is invoked across the FFI boundary with a null
  home pointer
- **THEN** the call MUST return a non-null, parseable JSON string
- **AND** it MUST carry a string `error` field
