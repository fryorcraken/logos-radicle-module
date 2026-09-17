## MODIFIED Requirements

### Requirement: Values are validated on write, not on use

`setSetting` MUST validate a value before storing it, and MUST refuse rather
than store a value it cannot accept. A refusal MUST return the module's
standard `{"error":"..."}` shape, and MUST leave the stored value unchanged.

The per-key rules are:

- `mode` MUST be one of `explore`, `local` or `embedded`. The refusal message
  MUST name all three.
- `gitPath` MUST, when non-empty, be an absolute path to an executable that
  answers as git. An empty value is always accepted, because it means "find git
  on `PATH`". The refusal message MUST name the value that was tried. The
  requirement "A configured git path is proved to be git, and never falls back"
  below owns the full rule, including the cases a positive test alone cannot
  distinguish.
- `radSocket` MUST, when non-empty, be short enough for a Unix domain socket
  path — at most 107 bytes, one less than the 108-byte `sun_path` capacity
  that holds its terminator. The refusal message MUST name the limit. The
  `node-paths` capability owns the full rule, including why this check is not
  redundant with the one at resolution time.
- `remoteSeed` MUST, when non-empty, begin with `http://` or `https://`.
  Validation of `remoteSeed` is shape-only: whether the seed answers is not
  checked here and MUST NOT put a network round trip on a settings write.
- `radHome` has no value validation. **This is a known gap, not the intended
  contract**: every other non-mode key is validated on write, and an
  unusable home is accepted here only to surface later as
  `localAvailable: false` — the deferred-failure shape this capability rejects
  for `gitPath`. Do not read this line as licence to leave it unvalidated.

#### Scenario: A mode the module does not know is refused and lists the valid ones

- **WHEN** `setSetting` is called with key `mode` and value `turbo`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST contain `explore`, `local` and `embedded`
- **AND** a subsequent read of `mode` MUST still give the value that was
  stored before the call

#### Scenario: All three modes are accepted

- **WHEN** `setSetting` is called with key `mode` and each of `explore`,
  `local` and `embedded` in turn
- **THEN** each call MUST return a settings object rather than an error
- **AND** a read of `mode` after each call MUST give the value just written

#### Scenario: A git path that is not a usable git is refused and named

- **WHEN** `setSetting` is called with key `gitPath` and value
  `/definitely/not/here/git`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST contain `/definitely/not/here/git`
- **AND** a subsequent read of `gitPath` MUST give the empty string

#### Scenario: An empty git path is accepted

- **WHEN** `setSetting` is called with key `gitPath` and an empty value
- **THEN** the reply MUST be a settings object rather than an error

#### Scenario: An over-long socket path is refused at write time

- **WHEN** `setSetting` is called with key `radSocket` and a value of 126
  bytes
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST state the limit as `107`
- **AND** a subsequent read of `radSocket` MUST give the empty string

#### Scenario: A socket path within the cap is accepted

- **WHEN** `setSetting` is called with key `radSocket` and value
  `/run/user/1000/rad.sock`
- **THEN** the reply MUST be a settings object rather than an error
- **AND** a subsequent read of `radSocket` MUST give
  `/run/user/1000/rad.sock`

#### Scenario: A seed URL with no scheme is refused

- **WHEN** `setSetting` is called with key `remoteSeed` and value
  `seed.radicle.xyz`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** a subsequent read of `remoteSeed` MUST give the empty string

#### Scenario: Both http and https seed URLs are accepted

- **WHEN** `setSetting` is called with key `remoteSeed` and value
  `https://seed.example`, and again with `http://localhost:8080`
- **THEN** neither reply MUST be an error

#### Scenario: The refusal reaches the caller across the module boundary

- **WHEN** `setSetting` is called through the module's public API with key
  `gitPath` and value `/definitely/not/here/git`
- **THEN** the returned JSON string MUST parse to an object carrying an
  `error` member
- **AND** that member MUST contain `/definitely/not/here/git`

## ADDED Requirements

### Requirement: A configured git path is proved to be git, and never falls back

A non-empty `gitPath` MUST be accepted only when the path it names both runs
and identifies itself as git. Each of the following MUST be refused, and each
refusal MUST name the value that was tried and say what was wrong with it:

- A path that does not exist.
- An executable that runs and exits zero but whose `--version` output does not
  identify it as git.
- An executable whose `--version` exits non-zero.
- A path that is not absolute.

A configured path that fails any of these MUST NOT fall back to a git found on
`PATH`. A silent fallback makes a typo in the setting look like a Radicle
defect rather than a wrong path, and makes the reported path differ from the
binary that would actually run.

These four cases are required together rather than as one: no positive check
distinguishes them, since a test configuring a working git and observing success
passes equally against a resolver that ignores the setting. Only a refusal
naming the configured value shows the setting was consulted.

#### Scenario: A real-but-not-git executable is refused

- **WHEN** `gitPath` is set to an absolute path to an executable that exits
  zero and prints something other than a git version
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST say that the binary does not look like git
- **AND** a subsequent read of `gitPath` MUST give the value stored before the
  call

#### Scenario: An executable that exits non-zero is refused

- **WHEN** `gitPath` is set to an absolute path to an executable that exits
  non-zero when asked for its version
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST name that path

#### Scenario: A relative path is refused even when it names a working git

- **WHEN** `gitPath` is set to a relative path
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST say the path must be absolute
- **AND** the refusal MUST hold for a relative path that names a real, working
  git, so that refusing relative paths is distinguishable from refusing
  everything

#### Scenario: The same binary is accepted by its absolute path

- **WHEN** `gitPath` is set to a relative path naming a real, working git, and
  then to that same binary's absolute path
- **THEN** the first call MUST be refused
- **AND** the second MUST NOT be an error
- **AND** the reported resolved path MUST be that absolute path

#### Scenario: A refused configured path does not silently use PATH

- **WHEN** a working git exists on `PATH`
- **AND** `gitPath` is set to an absolute path that does not exist
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the message MUST name the path that was tried rather than the one on
  `PATH`
- **AND** `getCapabilities().gitFound` MUST NOT be reported as true on the
  strength of the `PATH` git for that configured value

### Requirement: The reported git path distinguishes configured from detected

`getCapabilities()` MUST report `gitConfigured` as true exactly when a non-empty
`gitPath` setting is in force, and false when git was found on `PATH`.

It MUST report `gitConfigured` as true for a configured path that was refused,
because the user did set something: reporting "found automatically" there would
describe a state the module is not in.

`gitPath` MUST report the resolved absolute path when git was found, and the
empty string when it was not. `gitProblem` MUST be empty exactly when `gitFound`
is true.

#### Scenario: A detected git is not reported as configured

- **WHEN** the `gitPath` setting is empty and a working git is found on `PATH`
- **THEN** `getCapabilities().gitFound` MUST be true
- **AND** `gitConfigured` MUST be false
- **AND** `gitPath` MUST be a non-empty absolute path
- **AND** `gitProblem` MUST be empty

#### Scenario: A refused configured path is still reported as configured

- **WHEN** a non-empty `gitPath` is in force that does not resolve to a usable
  git
- **THEN** `getCapabilities().gitFound` MUST be false
- **AND** `gitConfigured` MUST be true
- **AND** `gitProblem` MUST be non-empty
