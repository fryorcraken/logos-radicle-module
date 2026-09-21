## MODIFIED Requirements

### Requirement: Reporting what the embedded home holds

`getEmbeddedIdentity()` MUST report the state of the embedded home without
creating, modifying or deleting anything in it.

On success it MUST return
`{"home":"<path>","exists":bool,"nodeId":"<did>","encrypted":bool,"problem":""}`.

`exists` MUST be true only when the home holds a **complete** identity —
`keys/radicle.pub` and `config.json` both present. `nodeId` MUST be the DID
form (`did:key:z6Mk…`), read from the public half of the keystore, and MUST be
`""` whenever `exists` is false.

`encrypted` MUST report whether the identity's signing key is sealed with a
passphrase, **observed from the key on disk** rather than echoed from an
argument. It MUST be false whenever `exists` is false, because there is no key
to describe.

This field exists because **it is the only way a later session can learn whether
starting the node needs a passphrase.** The node is handed an already-decrypted
signing key when it is built, so a passphrase must be supplied at start or not
at all; but the only other reply carrying an `encrypted` field is
`createEmbeddedIdentity`'s, which by definition no later session has, and which
computes the value from the passphrase argument rather than from what landed on
disk. Without this field a surface offering to start an existing node can
neither know to prompt nor know it may skip prompting — so it must either prompt
always, which is wrong for an unencrypted key, or attempt a start and read the
failure, which is a destructive probe rather than a question.

`getCapabilities().canWriteLocal` MUST NOT be treated as a substitute for it.
That field probes the home of the **mode in force**, so it says nothing about
the embedded home from any other mode, and it conflates an encrypted key with a
missing key, an unreadable one and several other causes — a caller cannot
recover "encrypted" from it without matching on prose. `getEmbeddedIdentity()`
always reads the embedded home whatever mode is in force, which is what makes it
the right reply to carry this.

Determining `encrypted` MUST NOT require a passphrase, an ssh-agent, or any
attempt to load or use the private key: it is a property of the stored key that
is readable without unlocking it. Reporting it MUST NOT unseal, rewrite or
otherwise alter the key.

When the key cannot be read at all, `encrypted` MUST be false and `problem` MUST
be non-empty rather than the field reporting a guess — an unreadable key is not
an unencrypted one, and the two MUST NOT be reported alike.

When no data directory can be resolved — neither `XDG_DATA_HOME` nor `HOME` is
set — the method MUST return `home:""`, `exists:false`, `nodeId:""`,
`encrypted:false` and a non-empty `problem`. It MUST NOT return an
`{"error":"..."}` object: the question was answered, and a caller must render a
blocked state rather than a failed call it might retry.

#### Scenario: No identity yet is the ordinary state

- **WHEN** the embedded home holds no key material
- **THEN** `getEmbeddedIdentity()` MUST return `exists:false`
- **AND** `nodeId` MUST be `""`
- **AND** `encrypted` MUST be false
- **AND** `problem` MUST be `""`
- **AND** `home` MUST be the non-empty embedded home path

#### Scenario: A complete identity is reported with its DID

- **WHEN** `createEmbeddedIdentity("tester", "")` has succeeded and returned a
  non-empty `nodeId`
- **THEN** a subsequent `getEmbeddedIdentity()` MUST return `exists:true`
- **AND** its `nodeId` MUST equal the `nodeId` the creation reported

#### Scenario: The reported encryption follows the key that was written

- **WHEN** `createEmbeddedIdentity("tester", "")` has succeeded
- **THEN** a subsequent `getEmbeddedIdentity()` MUST return `encrypted:false`
- **AND WHEN** an identity is instead created in a different home with
  `createEmbeddedIdentity("tester", "correct horse battery")`
- **THEN** `getEmbeddedIdentity()` against that home MUST return
  `encrypted:true`

#### Scenario: Reporting encryption needs no passphrase and no agent

- **WHEN** the embedded home holds an identity created with a passphrase, with
  no passphrase supplied through the environment and no ssh-agent reachable
- **THEN** `getEmbeddedIdentity()` MUST return `exists:true` with
  `encrypted:true`
- **AND** `problem` MUST be `""`
- **AND** the reply MUST NOT contain an `error` key

#### Scenario: A half-written home is not reported as occupied

- **WHEN** the embedded home holds `keys/radicle.pub` but no `config.json`
- **THEN** `getEmbeddedIdentity()` MUST return `exists:false`
- **AND** `nodeId` MUST be `""`
- **AND** `encrypted` MUST be false

#### Scenario: No data directory at all

- **WHEN** neither `XDG_DATA_HOME` nor `HOME` is set
- **THEN** `getEmbeddedIdentity()` MUST return `home:""` and `exists:false`
- **AND** `encrypted` MUST be false
- **AND** `problem` MUST be non-empty
- **AND** the reply MUST NOT contain an `error` key
