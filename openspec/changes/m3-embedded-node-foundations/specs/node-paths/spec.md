# node-paths

## Purpose

Resolve the two filesystem paths every local operation needs — the Radicle
home and the node control socket — as independent answers with their own
precedence rules, and report an unusable socket path before anything tries to
bind or connect to it.

## ADDED Requirements

### Requirement: The home and the socket are resolved independently

The socket MUST be resolved from its own sources in preference to the home, so
that the home's length and location cannot constrain it; the home-derived form
is the last resort only. The home MUST NOT be derived from the socket under any
circumstances. Resolution MUST be a pure function of its inputs: the
environment is read only by the named `*FromEnv` wrappers, so every precedence
branch is reachable without mutating the process environment.

#### Scenario: A long home does not lengthen the socket

- **WHEN** the home is a per-profile data directory longer than 108 bytes,
  such as one under
  `/home/user/.local/share/logos/basecamp/profiles/alice/`, and a runtime
  directory `/run/user/1000` is available
- **THEN** the resolved socket MUST NOT contain the home as a substring
- **AND** the resolved socket MUST be within the socket length bound
- **AND** no problem MUST be reported, because a home of that length is not a
  problem and only a socket would be

#### Scenario: Changing the home alone does not change the socket

- **WHEN** two resolutions differ only in their home, and both are given the
  same runtime directory and the same profile name
- **THEN** both MUST resolve the same socket path
- **AND** each MUST resolve its own home unchanged

### Requirement: Home precedence is configured, then RAD_HOME, then the user home

`resolveHome` MUST return the configured home when it is non-empty; otherwise
the `RAD_HOME` value when that is non-empty; otherwise the user home with
`/.radicle` appended. When all three inputs are empty it MUST return the empty
string rather than a bare `/.radicle`, which would name the filesystem root.

#### Scenario: An explicit home wins over both environment values

- **WHEN** `resolveHome` is given the configured home `/chosen`, `RAD_HOME` of
  `/from-rad-home` and a user home of `/user`
- **THEN** the result MUST be `/chosen`

#### Scenario: RAD_HOME wins over the user home

- **WHEN** `resolveHome` is given no configured home, `RAD_HOME` of
  `/from-rad-home` and a user home of `/user`
- **THEN** the result MUST be `/from-rad-home`
- **AND** it MUST NOT be `/user/.radicle`

#### Scenario: The user home is the last resort and gains a suffix

- **WHEN** `resolveHome` is given no configured home and no `RAD_HOME`, and a
  user home of `/user`
- **THEN** the result MUST be `/user/.radicle`

#### Scenario: Nothing at all resolves to nothing

- **WHEN** `resolveHome` is given no configured home, no `RAD_HOME` and no user
  home
- **THEN** the result MUST be the empty string

### Requirement: Socket precedence prefers the runtime directory over the home

`resolveSocket` MUST return the configured socket when it is non-empty;
otherwise the `RAD_SOCKET` value when that is non-empty; otherwise
`<runtime dir>/radicle-<profile>.sock` when a runtime directory is given;
otherwise `<home>/node/control.sock`. The runtime directory is preferred
because it is short by construction, scoped to the user's session and cleaned
up on logout. The home-derived form is a fallback and MUST be retained,
because it is where a hand-run `rad` node places its socket and `local` mode
MUST still find it when no runtime directory exists. When the profile name is
empty the runtime-directory form MUST be `<runtime dir>/radicle.sock`. When
neither a runtime directory nor a home is available the result MUST be the
empty string.

#### Scenario: An explicit socket wins over every other source

- **WHEN** `resolveSocket` is given the configured socket `/chosen.sock`,
  `RAD_SOCKET` of `/env.sock`, a runtime directory `/run/user/1000`, the
  profile `alice` and the home `/home/u/.radicle`
- **THEN** the result MUST be `/chosen.sock`

#### Scenario: RAD_SOCKET wins over the runtime directory

- **WHEN** `resolveSocket` is given no configured socket, `RAD_SOCKET` of
  `/env.sock`, a runtime directory `/run/user/1000`, the profile `alice` and
  the home `/home/u/.radicle`
- **THEN** the result MUST be `/env.sock`
- **AND** it MUST NOT be `/run/user/1000/radicle-alice.sock`

#### Scenario: The runtime directory is preferred over the home

- **WHEN** `resolveSocket` is given no configured socket, no `RAD_SOCKET`, a
  runtime directory `/run/user/1000`, the profile `alice` and the home
  `/home/u/.radicle`
- **THEN** the result MUST be `/run/user/1000/radicle-alice.sock`
- **AND** it MUST NOT be `/home/u/.radicle/node/control.sock`

#### Scenario: Two profiles get two sockets in one runtime directory

- **WHEN** `resolveSocket` is called twice with the same runtime directory
  `/run/user/1000` and the same home, once with the profile `alice` and once
  with `bob`
- **THEN** the two results MUST be `/run/user/1000/radicle-alice.sock` and
  `/run/user/1000/radicle-bob.sock` respectively
- **AND** they MUST differ, so two Basecamp profiles cannot contend for one
  node's socket

#### Scenario: An empty profile name yields an unsuffixed socket name

- **WHEN** `resolveSocket` is given no configured socket, no `RAD_SOCKET`, a
  runtime directory `/run/user/1000`, an empty profile name and the home
  `/home/u/.radicle`
- **THEN** the result MUST be `/run/user/1000/radicle.sock`

#### Scenario: Without a runtime directory the socket falls back under the home

- **WHEN** `resolveSocket` is given no configured socket, no `RAD_SOCKET`, no
  runtime directory, the profile `alice` and the home `/home/u/.radicle`
- **THEN** the result MUST be `/home/u/.radicle/node/control.sock`

#### Scenario: Two homes yield two fallback sockets

- **WHEN** `resolveSocket` is called twice with no configured socket, no
  `RAD_SOCKET` and no runtime directory, once with the home `/home/a` and once
  with `/home/b`
- **THEN** the two results MUST differ
- **AND** each MUST be under the home it was given

#### Scenario: No socket source at all resolves to nothing

- **WHEN** `resolveSocket` is given no configured socket, no `RAD_SOCKET`, no
  runtime directory and no home
- **THEN** the result MUST be the empty string

### Requirement: The 108-byte sun_path cap constrains the socket alone

`resolvePaths` MUST reject a resolved socket path whose length plus a
terminating NUL exceeds the 108-byte `sun_path` capacity, by reporting a
non-empty problem. A path of exactly 107 bytes MUST therefore be accepted and a
path of 108 bytes MUST be refused. The cap MUST NOT be applied to the home: a
home of any length MUST NOT produce a problem. The check MUST run at resolution time rather than at the
point of connection, so that a preflight surface can report it without a live
profile or a running node.

#### Scenario: A path exactly at the cap is accepted and one byte over is refused

- **WHEN** `resolvePaths` is given a configured socket of 107 bytes
- **THEN** the reported problem MUST be empty
- **AND WHEN** `resolvePaths` is given a configured socket of 108 bytes
- **THEN** the reported problem MUST be non-empty

#### Scenario: A home past the cap is not a problem

- **WHEN** `resolvePaths` is given a configured home longer than 108 bytes and
  a runtime directory that yields a short socket
- **THEN** the resolved home MUST be that long home unchanged
- **AND** the reported problem MUST be empty

#### Scenario: A socket within the cap reports no problem

- **WHEN** `resolvePaths` is given the home `/home/u/.radicle`, no configured
  socket, no environment values, the runtime directory `/run/user/1000` and the
  profile `alice`
- **THEN** the resolved socket MUST be `/run/user/1000/radicle-alice.sock`
- **AND** the reported problem MUST be empty

### Requirement: An over-long socket names the path, its length and the limit

The kernel's own error for an over-long `sun_path` names neither the path, nor
its length, nor the limit, which is what makes the failure expensive to
diagnose. The problem reported for an over-long socket MUST therefore contain
the offending path verbatim, its actual byte length, and the permitted length
of 107 bytes. It MUST be a sentence suitable for showing a user unaltered.

#### Scenario: The refusal names all three facts

- **WHEN** `resolvePaths` is given a configured socket consisting of `/`, 120
  repeated characters and `.sock`
- **THEN** the reported problem MUST be non-empty
- **AND** it MUST contain that socket path
- **AND** it MUST contain the path's byte length
- **AND** it MUST contain `107`

#### Scenario: A refused socket is still reported as the resolved socket

- **WHEN** `resolvePaths` refuses an over-long configured socket
- **THEN** the resolved socket MUST still be that path rather than empty, so a
  surface reporting the problem and the path cannot disagree about which path
  was refused

### Requirement: An unresolvable home is reported as its own problem

When no home can be resolved from any source, `resolvePaths` MUST report the
problem `no Radicle home found (set RAD_HOME or HOME)` and MUST NOT go on to
report a socket-length problem. A missing home is the more fundamental failure
and reporting the socket instead would name the wrong cause.

#### Scenario: No home reports the home problem rather than a socket problem

- **WHEN** `resolvePaths` is given no configured home, no `RAD_HOME` and no
  user home, together with an over-long configured socket
- **THEN** the reported problem MUST name the missing home
- **AND** it MUST NOT be the socket-length message

### Requirement: The socket setting is validated against the same cap on write

Setting `radSocket` to a non-empty value whose length plus a terminating NUL
exceeds the same 108-byte capacity MUST be refused with an `{"error":"..."}`
reply naming the path, its byte length and the 107-byte limit, and the value
MUST NOT be persisted. An empty value MUST be accepted, meaning "resolve from
the environment". This check is not redundant with the resolution-time one: a
socket path can also arrive from `RAD_SOCKET`, which the settings store never
sees, and a resolution-time check alone would let a bad value persist.

#### Scenario: An over-long socket setting is refused

- **WHEN** `radSocket` is set to a path of 120 bytes
- **THEN** the reply MUST be an error naming that path, `120` and `107`
- **AND** a subsequent read of the settings MUST show the previous value

#### Scenario: A socket setting within the cap is accepted

- **WHEN** `radSocket` is set to `/run/user/1000/radicle-alice.sock`
- **THEN** the reply MUST NOT be an error
- **AND** a subsequent read of the settings MUST show that path

### Requirement: The socket the module resolved is the socket a write announces to

The announce step of a write MUST use the socket path resolved by the module
and passed to it, rather than re-deriving one from the home or re-reading the
environment. An empty socket argument MUST be treated as unset, falling back to
`<home>/node/control.sock`. Announcing to the wrong socket is silent — the
write still lands in git storage and still reports success, and an unannounced
write is legitimately not an error — so the read path and the write path MUST
resolve one socket in one place.

#### Scenario: The resolved socket wins over the home-derived default

- **WHEN** the announce socket is resolved for the home
  `/home/alice/.radicle` with the socket `/run/user/1000/radicle-alice.sock`
- **THEN** the result MUST be `/run/user/1000/radicle-alice.sock`
- **AND** it MUST NOT be `/home/alice/.radicle/node/control.sock`

#### Scenario: One home with two sockets yields two answers

- **WHEN** the announce socket is resolved twice for the same home
  `/home/alice/.radicle`, once with `/run/user/1000/a.sock` and once with
  `/run/user/1000/b.sock`
- **THEN** the two results MUST differ

#### Scenario: No socket falls back under the home

- **WHEN** the announce socket is resolved for the home `/some/home` with no
  socket given
- **THEN** the result MUST be `/some/home/node/control.sock`

#### Scenario: An empty socket is treated as unset rather than as an empty path

- **WHEN** the announce socket is resolved for the home `/some/home` with an
  empty socket string
- **THEN** the result MUST be `/some/home/node/control.sock`
- **AND** it MUST NOT be the empty path, whose connection failure would name
  nothing at all

### Requirement: The embedded home is derived only from the module's own data directory

`embeddedHomeFor` MUST derive the embedded Radicle home from the XDG data home
alone, falling back to `<user home>/.local/share` only when no XDG data home is
given, and appending the module's own directory and `embedded-home`. It MUST
have no branch that reads `RAD_HOME` or that can return the user's conventional
`~/.radicle`. When neither an XDG data home nor a user home is available it
MUST return the empty string rather than a path relative to nothing.

#### Scenario: The embedded home follows the XDG data home when set

- **WHEN** `embeddedHomeFor` is given the XDG data home `/xdg/data` and the
  user home `/home/u`
- **THEN** the result MUST be `/xdg/data/radicle-module/embedded-home`
- **AND** the result MUST NOT contain `/home/u`

#### Scenario: The embedded home falls back to the XDG default under the user home

- **WHEN** `embeddedHomeFor` is given no XDG data home and the user home
  `/home/u`
- **THEN** the result MUST be
  `/home/u/.local/share/radicle-module/embedded-home`
- **AND** it MUST NOT be `/home/u/.radicle`

#### Scenario: No environment at all yields no embedded home

- **WHEN** `embeddedHomeFor` is given neither an XDG data home nor a user home
- **THEN** the result MUST be the empty string

#### Scenario: Two Basecamp profiles get two embedded homes

- **WHEN** `embeddedHomeFor` is called with the XDG data homes
  `/profiles/alice/xdg-data` and `/profiles/bob/xdg-data`, both with the same
  user home
- **THEN** the two results MUST differ
- **AND** each MUST be under the XDG data home it was given

#### Scenario: The embedded home is a sibling of the settings file, not the same path

- **WHEN** `embeddedHomeFor` and the settings path are resolved from the same
  XDG data home and user home
- **THEN** the two paths MUST differ
- **AND** both MUST be under the same module-owned directory, so the
  per-profile separation of one is the per-profile separation of the other

### Requirement: Embedded mode must never resolve the user's own Radicle home

When the selected mode is `embedded`, the home handed to path resolution MUST
be the embedded home and the resolution MUST NOT be able to fall through to
`RAD_HOME` or `<user home>/.radicle`. Because an empty configured home is
exactly what home resolution treats as "not configured", an unresolvable
embedded home MUST NOT be passed through to resolution; instead the mode MUST
yield inert paths with an empty home. Embedded promises an identity separate
from any node the user already runs; a resolution that could reach the user's
profile would expose their signing key and put two nodes on one git storage.

#### Scenario: An unresolvable embedded home is inert rather than the user's home

- **WHEN** the mode is `embedded` and no XDG data home or user home is
  available to derive an embedded home from, while `RAD_HOME` names a real
  Radicle profile
- **THEN** the resolved home MUST be empty
- **AND** it MUST NOT be the `RAD_HOME` path
- **AND** local availability MUST be false

#### Scenario: A resolvable embedded home overrides RAD_HOME

- **WHEN** the mode is `embedded`, an XDG data home is available, and
  `RAD_HOME` names a different directory
- **THEN** the resolved home MUST be the embedded home derived from the XDG
  data home
- **AND** it MUST NOT be the `RAD_HOME` path

#### Scenario: Local mode does read the environment

- **WHEN** the mode is `local`, no `radHome` setting is configured, and
  `RAD_HOME` names a directory
- **THEN** the resolved home MUST be that `RAD_HOME` path
- **AND** it MUST differ from the embedded home the same environment would
  yield, so the two modes are distinguishable by their answer alone

#### Scenario: An unrecognised mode resolves nothing

- **WHEN** the persisted mode is a value this module does not map to a home
- **THEN** the resolved home MUST be empty
- **AND** it MUST NOT be the `RAD_HOME` path or `<user home>/.radicle`

### Requirement: A store reports the paths it was given rather than re-reading the environment

A store constructed from an already-resolved set of paths MUST report that
home and that socket, and MUST determine availability against that home, even
when the environment names a different home. A store constructed without paths
MUST resolve them from the environment.

#### Scenario: A store pointed away from the environment uses the given home

- **WHEN** a store is constructed with a home that holds no Radicle profile,
  while `RAD_HOME` names a directory that does hold one
- **THEN** the store's reported home MUST be the given one
- **AND** availability MUST be false

#### Scenario: A store built from explicit paths reports those paths

- **WHEN** a store is constructed with a home holding a profile and the socket
  `/run/user/1000/radicle-test.sock`
- **THEN** the reported home MUST be that home
- **AND** the reported socket MUST be `/run/user/1000/radicle-test.sock`
- **AND** availability MUST be true

### Requirement: A home is a profile only when it contains storage

Availability MUST be determined by the presence of a `storage` directory under
the resolved home, not by the home directory merely existing. A home that
cannot be resolved at all MUST be unavailable.

#### Scenario: A directory without storage is not a profile

- **WHEN** the resolved home is an existing directory containing no `storage`
  directory
- **THEN** availability MUST be false

#### Scenario: A directory with storage is a profile

- **WHEN** the resolved home is an existing directory containing a `storage`
  directory
- **THEN** availability MUST be true
- **AND** the reported home MUST be that directory

### Requirement: The absent-profile sentence is chosen by the mode that asked

`NodePaths` MUST carry an optional `absentProfileReason`, and when the home
holds no profile that sentence MUST be returned verbatim in preference to
either default. It MUST take precedence over the empty-home default as well as
over the missing-profile default, because the case most needing a mode-specific
sentence — embedded with no data directory — is the case where the home is
empty. The default sentence for a resolved but profile-less home MUST name the
path and advise installing Radicle and running `rad auth`; that advice is
correct for a home the user manages and wrong for the embedded one, whose
premise is that `rad auth` is never run and whose empty home is the state
before the wizard has run rather than a misconfiguration.

#### Scenario: A supplied reason replaces the rad auth advice

- **WHEN** a store is built from paths with the home `/nowhere/embedded-home`
  and the supplied reason `no embedded identity yet — set one up here`
- **THEN** the unavailable reason MUST be exactly that sentence
- **AND** it MUST NOT mention `rad auth`

#### Scenario: Without a supplied reason the default advice stands

- **WHEN** a store is built from paths with the home `/nowhere/user-home` and
  no supplied reason
- **THEN** the unavailable reason MUST mention `rad auth`
- **AND** it MUST name `/nowhere/user-home`

#### Scenario: A supplied reason survives an empty home

- **WHEN** a store is built from paths with an empty home and a supplied reason
- **THEN** the unavailable reason MUST be that supplied sentence
- **AND** it MUST NOT be the `set RAD_HOME or HOME` default

#### Scenario: A supplied reason is unused when a profile is present

- **WHEN** a store is built from paths whose home holds a profile, with a
  supplied reason
- **THEN** availability MUST be true
- **AND** the unavailable reason MUST NOT contain the supplied sentence

#### Scenario: Embedded's sentence names the embedded home and its separateness

- **WHEN** the mode is `embedded`, an embedded home resolves, and it holds no
  identity
- **THEN** the unavailable reason MUST name the resolved embedded home
- **AND** it MUST state that this is a separate identity from any Radicle node
  the user already runs
- **AND** it MUST NOT advise running `rad auth`

#### Scenario: Embedded with nowhere to put a home says so

- **WHEN** the mode is `embedded` and no embedded home can be resolved
- **THEN** the unavailable reason MUST state that the module keeps the home
  under the Basecamp profile's data directory and that neither `XDG_DATA_HOME`
  nor `HOME` is set
- **AND** it MUST NOT advise setting `RAD_HOME`, which is the one variable
  embedded mode must never follow

### Requirement: The resolved paths and any problem are reported to the view

`getCapabilities` MUST report the home actually resolved as `radHome`, the
socket actually resolved as `radSocket`, and the resolution problem as
`pathsProblem`, empty when there is none. These distinguish "the node is not
running" from "we could never have talked to it".

#### Scenario: Capabilities carry the resolved paths

- **WHEN** `getCapabilities` is called
- **THEN** the reply MUST contain `radHome`, `radSocket` and `pathsProblem`
- **AND** `radHome` MUST equal the home the active mode resolved

#### Scenario: Changing the home repoints the reported paths

- **WHEN** the `mode`, `radHome` or `radSocket` setting is changed
- **THEN** a subsequent `getCapabilities` MUST report the paths the new
  settings resolve, without a restart
- **AND** the local-availability change event MUST carry those same
  capabilities

### Requirement: The node is running only when its socket accepts a connection

A node MUST be reported as running only when the resolved socket path is
non-empty, is within the kernel's `sun_path` capacity, exists on disk, and
accepts a connection. A socket file that exists but accepts no connection MUST
NOT be reported as a running node, because the file can outlive the daemon. A
store with no profile MUST report the node as not running without probing.

#### Scenario: A missing socket means the node is not running

- **WHEN** the resolved home holds a profile and no socket file exists at the
  resolved socket path
- **THEN** the node MUST be reported as not running

#### Scenario: An over-long socket path is never probed

- **WHEN** the resolved socket path is at or beyond the kernel's `sun_path`
  capacity
- **THEN** the node MUST be reported as not running rather than a truncated
  path being probed
