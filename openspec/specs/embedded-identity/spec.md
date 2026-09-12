# embedded-identity Specification

## Purpose
Create and report the embedded node's Radicle identity without the `rad`
binary, in a home this module derives for itself, refusing every operation
that could overwrite a signing key or point key creation at a home the module
does not own.

## Requirements

### Requirement: Neither identity method takes a home

`getEmbeddedIdentity()` and `createEmbeddedIdentity(alias, passphrase)` MUST
NOT accept a Radicle home as a parameter. Both MUST resolve the embedded home
themselves, from the module's data directory alone.

This is a safety property, not a convenience. A home parameter crosses the
QtRO boundary from a sandboxed view, and would be a way for a caller to point
key creation at the user's own `~/.radicle`.

The embedded home MUST be derived from `XDG_DATA_HOME`, falling back to
`$HOME/.local/share` when `XDG_DATA_HOME` is unset. The derivation MUST NOT
consult `RAD_HOME`, and MUST NOT consult `$HOME/.radicle`.

#### Scenario: The reported home is the module's, not the environment's node

- **WHEN** `RAD_HOME` names a readable Radicle profile at one path and
  `XDG_DATA_HOME` names a different directory
- **THEN** `getEmbeddedIdentity()` MUST report `home` derived from the
  `XDG_DATA_HOME` directory
- **AND** the reported `home` MUST NOT equal the path `RAD_HOME` names

#### Scenario: Creation writes only into the embedded home

- **WHEN** `RAD_HOME` names a scratch directory holding no profile,
  `XDG_DATA_HOME` names a different directory, and
  `createEmbeddedIdentity("tester", "")` succeeds
- **THEN** `keys/radicle.pub` MUST exist under the embedded home derived from
  `XDG_DATA_HOME`
- **AND** neither `keys` nor `config.json` MUST exist under the path
  `RAD_HOME` names

#### Scenario: A view cannot name the home

- **WHEN** a caller invokes either identity method across the module boundary
- **THEN** the method signature MUST expose no home argument, so no argument
  value can change which directory is read or written

### Requirement: Reporting what the embedded home holds

`getEmbeddedIdentity()` MUST report the state of the embedded home without
creating, modifying or deleting anything in it.

On success it MUST return
`{"home":"<path>","exists":bool,"nodeId":"<did>","problem":""}`.

`exists` MUST be true only when the home holds a **complete** identity —
`keys/radicle.pub` and `config.json` both present. `nodeId` MUST be the DID
form (`did:key:z6Mk…`), read from the public half of the keystore, and MUST be
`""` whenever `exists` is false.

When no data directory can be resolved — neither `XDG_DATA_HOME` nor `HOME` is
set — the method MUST return `home:""`, `exists:false`, `nodeId:""` and a
non-empty `problem`. It MUST NOT return an `{"error":"..."}` object: the
question was answered, and a caller must render a blocked state rather than a
failed call it might retry.

#### Scenario: No identity yet is the ordinary state

- **WHEN** the embedded home holds no key material
- **THEN** `getEmbeddedIdentity()` MUST return `exists:false`
- **AND** `nodeId` MUST be `""`
- **AND** `problem` MUST be `""`
- **AND** `home` MUST be the non-empty embedded home path

#### Scenario: A complete identity is reported with its DID

- **WHEN** `createEmbeddedIdentity("tester", "")` has succeeded and returned a
  non-empty `nodeId`
- **THEN** a subsequent `getEmbeddedIdentity()` MUST return `exists:true`
- **AND** its `nodeId` MUST equal the `nodeId` the creation reported

#### Scenario: A half-written home is not reported as occupied

- **WHEN** the embedded home holds `keys/radicle.pub` but no `config.json`
- **THEN** `getEmbeddedIdentity()` MUST return `exists:false`
- **AND** `nodeId` MUST be `""`

#### Scenario: No data directory at all

- **WHEN** neither `XDG_DATA_HOME` nor `HOME` is set
- **THEN** `getEmbeddedIdentity()` MUST return `home:""` and `exists:false`
- **AND** `problem` MUST be non-empty
- **AND** the reply MUST NOT contain an `error` key

### Requirement: Three home states, not two

The classification of an embedded home MUST distinguish three states rather
than two:

- **Empty** — no `keys/radicle.pub`, whether or not the directory itself
  exists. Safe to create into.
- **Complete** — `keys/radicle.pub` and `config.json` both present. Creating
  here would destroy a real identity.
- **Partial** — `keys/radicle.pub` present, `config.json` absent.
  Initialisation did not finish; no usable identity exists here.

`config.json` MUST be the completeness marker. `storage/` MUST NOT be used as
that marker: the directory tree, `storage/` included, is created before any key
is written, so a home in the Partial state holds `storage/` too.

A Partial home MUST classify as "no complete identity" — that is, it reports
`exists:false` — because creating into it is a recovery rather than a
destructive act.

#### Scenario: An existing but empty directory is not a profile

- **WHEN** the embedded home directory exists and is empty
- **THEN** it MUST classify as Empty
- **AND** `createEmbeddedIdentity("tester", "")` into it MUST succeed with
  `created:true`

#### Scenario: `storage/` is present in the Partial state

- **WHEN** a complete profile has been created and its `config.json` is then
  removed
- **THEN** `storage/` MUST still exist under that home
- **AND** `config.json` MUST NOT exist
- **AND** the home MUST classify as Partial rather than Complete

### Requirement: An occupied home is refused and never overwritten

`createEmbeddedIdentity(alias, passphrase)` MUST refuse when the embedded home
is in the Complete state, and MUST leave the existing key material byte-for-byte
unchanged.

There MUST NOT be a `force` parameter or any other caller-supplied way to
overwrite an existing identity. The signing key *is* the identity: replacing it
is unrecoverable, and every repository delegating to it becomes unreachable.

The refusal MUST come back as `{"error":"..."}` whose message names the home
that was in the way and states the consequence — that creating another would
overwrite a signing key that cannot be recovered — rather than describing a
keystore file.

The refusal MUST happen before the home directory tree is created or modified,
so a refused call leaves the filesystem exactly as it found it.

#### Scenario: A second creation is refused and the first identity survives

- **WHEN** `createEmbeddedIdentity("tester", "")` has succeeded with node id
  `N`
- **AND** `createEmbeddedIdentity("someone-else", "")` is then called
- **THEN** the second reply MUST contain an `error`
- **AND** the error message MUST name the embedded home
- **AND** the error message MUST state that creating another would overwrite
  its signing key
- **AND** a subsequent `getEmbeddedIdentity()` MUST still report `nodeId` equal
  to `N`

#### Scenario: No force escape hatch exists

- **WHEN** a caller wishes to replace an existing embedded identity
- **THEN** the method signature MUST accept only `alias` and `passphrase`, so
  no argument value can turn the refusal into an overwrite

### Requirement: A half-created home is reported as recoverable, not occupied

`createEmbeddedIdentity` MUST refuse a home in the Partial state with a message
distinct from the occupied-home refusal.

That message MUST describe the home as half-created, MUST state that nothing
has ever signed with the key material present, and MUST name the `keys`
directory as the path to remove. It MUST NOT claim a signing key is at stake:
that claim is both false and unactionable for a stub left by a failed run.

The Partial state MUST be reported rather than repaired. The module MUST NOT
delete key material automatically, because a misclassification would then cost
an identity — the one failure here with no recovery.

Removing the named path MUST make creation succeed.

#### Scenario: The half-created refusal differs from the occupied refusal

- **WHEN** the embedded home holds key material but no `config.json`
- **AND** `createEmbeddedIdentity("tester", "")` is called
- **THEN** the reply MUST contain an `error`
- **AND** the message MUST describe the home as half-created
- **AND** the message MUST name the `keys` path to remove
- **AND** the message MUST NOT say that a signing key would be overwritten

#### Scenario: The named recovery works

- **WHEN** the embedded home is in the Partial state and the `keys` directory
  it names is removed
- **AND** `createEmbeddedIdentity("tester", "")` is then called
- **THEN** the reply MUST report `created:true` with a non-empty `nodeId`

#### Scenario: Key material is never deleted by the module

- **WHEN** `createEmbeddedIdentity` refuses a home in the Partial state
- **THEN** `keys/radicle.pub` MUST still exist under that home afterwards

### Requirement: Creation yields a distinct identity per home

Each successful creation MUST produce a signing key derived from entropy read
from the operating system's random source, never from a fixed or
pseudo-random seed.

A short read of that entropy MUST be treated as a failure rather than padded
or retried into something shorter.

Two homes MUST therefore hold two different identities. The observable
statement is that the node ids differ: directory-shaped assertions cannot
distinguish this from a shared fixed seed.

#### Scenario: Two homes yield two different node ids

- **WHEN** an identity is created into home A and another into home B, where
  neither path is a prefix of the other
- **THEN** both replies MUST report non-empty `nodeId` values
- **AND** the two `nodeId` values MUST differ from each other
- **AND** each home MUST hold its own complete profile

### Requirement: The created identity is real and readable

A successful `createEmbeddedIdentity` MUST return
`{"created":true,"nodeId":"did:key:z6Mk…","home":"<path>","alias":"<alias>","encrypted":bool}`.

`home` MUST be the embedded home the module derived. `nodeId` MUST be the DID
spelling, matching the spelling `getCapabilities().nodeId` reports, so a caller
can compare the two without normalising between forms.

The reported `nodeId` MUST be the identity actually written to the keystore: an
independent read of `keys/radicle.pub` MUST yield the same value.

The created profile MUST be openable by the module's existing local read path.

#### Scenario: The reported identity is the one on disk

- **WHEN** `createEmbeddedIdentity("tester", "")` reports `nodeId` `N`
- **THEN** an independent read of that home's `keys/radicle.pub` MUST report
  `nodeId` `N`

#### Scenario: A fresh profile reads as an empty one, not as a failure

- **WHEN** an identity has just been created into an empty embedded home
- **AND** the local read path lists that home's repositories
- **THEN** the reply MUST NOT contain an `error`
- **AND** it MUST list zero repositories

### Requirement: The passphrase decides whether the profile can sign

`createEmbeddedIdentity` MUST treat an empty `passphrase` as "no passphrase"
and write the signing key **unencrypted**, matching `ssh-keygen` and the
`radicle` crate's own passphrase handling. A non-empty `passphrase` MUST
encrypt the key.

The reply MUST report `encrypted`, and it MUST agree with whether the key on
disk is encrypted.

As shipped, `encrypted` is computed from the input (`!passphrase.is_empty()`)
and the same value selects the passphrase passed to `Profile::init`, so the
two cannot disagree in this code — but the field is not an observation of what
was written. A future change that made key creation fall back to an
unencrypted key on any path would satisfy the letter of this requirement while
reporting `encrypted: true` over an unencrypted key. What closes that is the
signability requirement below, which is checked against the key rather than
against the input; an earlier draft of this requirement asserted the field was
"derived from what was done", which the code does not do.

An unencrypted key MUST be immediately signable: the module's write path MUST
be able to load a signer with no prompt. An encrypted key MUST NOT be signable
until it is unlocked — with no passphrase supplied through the environment and
no agent holding the key, a write probe MUST report that it cannot write.

Reads MUST NOT require the passphrase: only `keys/radicle.pub` is read, so the
identity MUST remain visible while the key is locked.

#### Scenario: An empty passphrase yields an immediately signable profile

- **WHEN** `createEmbeddedIdentity("tester", "")` is called with an empty
  passphrase
- **THEN** the reply MUST report `encrypted:false`
- **AND** a write probe against that home MUST report that a write could
  succeed

#### Scenario: A passphrase yields a profile that cannot write until unlocked

- **WHEN** `createEmbeddedIdentity("tester", "correct horse battery")` is
  called
- **AND** no passphrase is available through the environment or an agent
- **THEN** the reply MUST report `encrypted:true`
- **AND** a write probe against that home MUST report that a write could not
  succeed

#### Scenario: `canWriteLocal` follows the passphrase in Embedded mode

- **WHEN** the module is in `embedded` mode and the embedded identity was
  created with an empty passphrase
- **THEN** `getCapabilities().canWriteLocal` MUST be true
- **AND WHEN** the embedded identity was instead created with a non-empty
  passphrase and nothing can supply it
- **THEN** `getCapabilities().canWriteLocal` MUST be false with a non-empty
  `writeUnavailableReason`

#### Scenario: The identity stays visible while the key is locked

- **WHEN** the embedded identity was created with a non-empty passphrase and
  nothing can supply it
- **THEN** `getEmbeddedIdentity()` MUST still report `exists:true` with the
  created `nodeId`

### Requirement: The alias is validated before anything is created

`createEmbeddedIdentity` MUST validate `alias` before creating the home
directory tree. An alias the `radicle` crate does not accept — one containing
whitespace, for instance — MUST be refused with an `{"error":"..."}` reply that
passes through the crate's own statement of the rule rather than paraphrasing
it.

A refused call MUST leave no home directory behind.

#### Scenario: A bad alias creates nothing

- **WHEN** `createEmbeddedIdentity("not a valid alias", "")` is called against
  a home that does not yet exist
- **THEN** the reply MUST contain an `error`
- **AND** the home directory MUST NOT exist afterwards

### Requirement: Creation is refused when no home can be resolved

When neither `XDG_DATA_HOME` nor `HOME` is set, `createEmbeddedIdentity` MUST
return `{"error":"..."}` naming the missing environment as the reason, and MUST
create nothing anywhere — in particular not in whatever profile `RAD_HOME`
names.

Unlike `getEmbeddedIdentity`, which reports this as a `problem`, creation MUST
report it as an error: the caller asked for a write that did not happen.

#### Scenario: No data directory means no key is written anywhere

- **WHEN** neither `XDG_DATA_HOME` nor `HOME` is set, `RAD_HOME` names a
  readable profile directory, and `createEmbeddedIdentity("tester", "")` is
  called
- **THEN** the reply MUST contain an `error`
- **AND** no `keys` directory MUST appear under the path `RAD_HOME` names

### Requirement: Creation does not change the mode, and repoints only in Embedded

`createEmbeddedIdentity` MUST succeed regardless of which mode is in force.

It MUST NOT change the persisted mode. Choosing a mode is the user's decision,
made through the settings; switching it as a side effect of creating an
identity would move the whole view underneath someone setting an embedded node
up for later.

When `embedded` IS the mode in force, a successful creation MUST repoint this
instance's local store at the new identity without requiring a restart, and
MUST announce the changed capabilities so a view re-renders.

When any other mode is in force, a successful creation MUST NOT repoint the
local store: the module MUST go on reading the home that mode resolved.

#### Scenario: In Embedded, the new identity is readable at once

- **WHEN** the mode is `embedded`, `getCapabilities().localAvailable` is false,
  and `createEmbeddedIdentity("tester", "")` succeeds
- **THEN** `getCapabilities().localAvailable` MUST become true without a
  restart
- **AND** `getCapabilities().nodeId` MUST equal the created `nodeId`

#### Scenario: In Local, creating an embedded identity changes nothing on screen

- **WHEN** the mode is `local` with `radHome` resolved to the user's own
  profile, and `createEmbeddedIdentity("tester", "")` succeeds
- **THEN** `getCapabilities().mode` MUST still be `local`
- **AND** `getCapabilities().radHome` MUST still be the user's own profile
  path
- **AND** `getEmbeddedIdentity().exists` MUST be true, so the identity really
  was created elsewhere

### Requirement: The embedded identity is a new one and must be stated as such

The identity `createEmbeddedIdentity` creates MUST be a new DID, distinct from
any identity the user already holds. It is not, and cannot be, the user's
existing DID: their repositories are not in this storage and their allow-listed
DID is not this one.

The reply MUST carry `nodeId` so a confirmation step can show the user the DID
they need to authorise elsewhere.

A view MUST state that this is a separate identity rather than let the user
discover it as missing repositories. Where the module explains why writes are
unavailable in Embedded before an identity exists, that explanation MUST name
the embedded home and MUST say that it is a separate identity from any Radicle
node already running. It MUST NOT advise running `rad auth`, which is advice
for a mode the user did not pick.

#### Scenario: The absent-identity explanation fits Embedded, not Local

- **WHEN** the mode is `embedded` and no embedded identity has been created
- **THEN** `getCapabilities().writeUnavailableReason` MUST be non-empty
- **AND** it MUST contain the resolved `radHome`
- **AND** it MUST state that this is a separate identity
- **AND** it MUST NOT mention `rad auth`

### Requirement: Every failure crosses the boundary as JSON

Neither identity method may propagate a panic or an unwind across the FFI
boundary. Every call MUST return a well-formed JSON string: either the
documented success shape or `{"error":"..."}`.

An unusable home — a null pointer, or a path that cannot be created — MUST come
back as an error object rather than as a crash, an empty string or malformed
JSON.

#### Scenario: An uncreatable home answers with an error object

- **WHEN** identity creation is invoked across the FFI boundary with a null
  home pointer, and again with a home under a path that cannot be created
- **THEN** each call MUST return a non-null, parseable JSON string
- **AND** each MUST carry a string `error` field

### Requirement: A relative home is refused rather than resolved

The identity-creation backend MUST refuse a home that is not an absolute path,
with an error saying the path must be absolute, and MUST create nothing.

A relative path would be resolved against a working directory this module does
not control — a Basecamp-launched module's current directory is not something
the user chose or can see — so the same configured value would name a different
home depending on how the module was started.

#### Scenario: A relative home creates nothing under the working directory

- **WHEN** identity creation is invoked with a relative home path
- **THEN** the reply MUST contain an `error` whose message says the path must
  be absolute
- **AND** no directory at that relative path MUST exist under the process's
  working directory afterwards
