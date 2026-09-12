## Purpose

The module's own persistent configuration: the five settings that survive a
restart, the per-Basecamp-profile file they live in, and the rule that every
value is validated when it is written rather than when something later reads
it.

## ADDED Requirements

### Requirement: The settings store holds exactly five named keys

The module MUST persist exactly five settings, named `mode`, `radHome`,
`radSocket`, `gitPath` and `remoteSeed`. No other key is stored, and the
meaning of each is fixed:

- `mode` — which node this module is pointed at; one of `explore`, `local`
  or `embedded`.
- `radHome` — an explicit Radicle home; `""` means resolve one from the
  environment.
- `radSocket` — an explicit node control socket; `""` means resolve one.
- `gitPath` — an explicit `git` executable; `""` means find one on `PATH`.
- `remoteSeed` — the seed URL the `remote*` methods proxy to; `""` means the
  built-in default.

`getSettings` MUST return all five keys on every call, with defaults filled in
for anything unset, and MUST NOT return any other key.

The second half is **currently unpinned**, and this was demonstrated rather
than suspected: injecting an extra key into the store's reply leaves the whole
unit suite green, because the covering test makes five `contains()` assertions
and never checks the count. A one-line count assertion closes it, and is
recorded in `tasks.md` rather than made here, because this change adds no
tests. Until then, a regression leaking an internal field into every reply
would ship unnoticed.

#### Scenario: Every key is present in a reply even when nothing was written

- **WHEN** `getSettings` is called against a settings file that has never
  been written
- **THEN** the reply MUST contain all five of `mode`, `radHome`, `radSocket`,
  `gitPath` and `remoteSeed`
- **AND** `mode` MUST be `explore`
- **AND** `radHome`, `radSocket`, `gitPath` and `remoteSeed` MUST each be the
  empty string

#### Scenario: A successful write returns the whole settings object

- **WHEN** `setSetting` accepts a value for one key
- **THEN** the reply MUST be the full settings object, containing all five
  keys, not only the key that changed
- **AND** the reply MUST carry no `error` member

#### Scenario: A key the store does not know is refused by name

- **WHEN** `setSetting` is called with the key `noSuchSetting`
- **THEN** the reply MUST be `{"error":"..."}`
- **AND** the error message MUST contain the text `noSuchSetting`
- **AND** no key named `noSuchSetting` MUST appear in a subsequent
  `getSettings` reply

### Requirement: The settings file lives under the XDG data home

The settings file MUST be `<base>/radicle-module/settings.json`, where
`<base>` is `$XDG_DATA_HOME` when that is set and non-empty, and
`$HOME/.local/share` otherwise. When neither is available the resolved path
MUST be empty rather than a path relative to nothing.

Basecamp hands each profile its own `XDG_DATA_HOME`, so two profiles resolve
two different files and therefore hold two independent sets of settings. The
module MUST NOT derive this path from `RAD_HOME` or from any Radicle profile
location, and MUST NOT write its settings into a node-owned file such as
`~/.radicle/config.json`.

#### Scenario: An XDG data home in force decides the path

- **WHEN** the settings path is resolved with an XDG data home of `/xdg/data`
  and a user home of `/home/u`
- **THEN** the path MUST be `/xdg/data/radicle-module/settings.json`

#### Scenario: No XDG data home falls back under the user home

- **WHEN** the settings path is resolved with an empty XDG data home and a
  user home of `/home/u`
- **THEN** the path MUST be
  `/home/u/.local/share/radicle-module/settings.json`

#### Scenario: Two Basecamp profiles resolve two different files

- **WHEN** the settings path is resolved once with an XDG data home of
  `/profiles/alice/xdg-data` and once with `/profiles/bob/xdg-data`
- **THEN** the two paths MUST differ
- **AND** each MUST lie under the XDG data home it was given

#### Scenario: Nothing to resolve from yields no path

- **WHEN** the settings path is resolved with both the XDG data home and the
  user home empty
- **THEN** the resolved path MUST be empty

#### Scenario: Two stores in two places do not see each other's values

- **WHEN** one store at path A persists `remoteSeed` as
  `https://alice.example` and a second store at path B persists it as
  `https://bob.example`
- **THEN** reading `remoteSeed` from the store at A MUST give
  `https://alice.example`
- **AND** reading it from the store at B MUST give `https://bob.example`

#### Scenario: A write through one store leaves an unrelated store at its default

- **WHEN** a store at path A persists `mode` as `local` and a store at path B
  has never had a mode written
- **THEN** reading `mode` from the store at B MUST give `explore`

### Requirement: Settings survive a restart

A value accepted by `setSetting` MUST be readable by a store constructed
afresh over the same path, which is what a module restart amounts to at this
layer. Writing one key MUST NOT disturb the stored value of any other key.

A persisted `remoteSeed` MUST be adopted when the module starts, so that
`getCapabilities().remoteSeed` reports it without any caller re-setting it.

#### Scenario: A value written by one store is read back by a later one

- **WHEN** a store persists `remoteSeed` as `https://persisted.example` and
  is then destroyed
- **AND** a new store is constructed over the same path
- **THEN** the new store MUST report `remoteSeed` as
  `https://persisted.example`

#### Scenario: Writing one key leaves the others untouched

- **WHEN** a store persists `mode` as `local` and then persists `remoteSeed`
  as `https://kept.example`
- **THEN** reading `mode` MUST still give `local`
- **AND** reading `remoteSeed` MUST give `https://kept.example`

#### Scenario: A persisted seed is in force at the next start

- **WHEN** a settings file carries `remoteSeed` of
  `https://persisted.example.test`
- **AND** a module instance is constructed over that file without any further
  seed call
- **THEN** `getCapabilities().remoteSeed` MUST be
  `https://persisted.example.test`

#### Scenario: Adoption reads the settings it was given

- **WHEN** two module instances are constructed over two settings files
  carrying `https://alpha.example.test` and `https://beta.example.test`
  respectively
- **THEN** the first instance's `getCapabilities().remoteSeed` MUST be
  `https://alpha.example.test`
- **AND** the second's MUST be `https://beta.example.test`

### Requirement: Values are validated on write, not on use

`setSetting` MUST validate a value before storing it, and MUST refuse rather
than store a value it cannot accept. A refusal MUST return the module's
standard `{"error":"..."}` shape, and MUST leave the stored value unchanged.

The per-key rules are:

- `mode` MUST be one of `explore`, `local` or `embedded`. The refusal message
  MUST name all three.
- `gitPath` MUST, when non-empty, resolve to an executable that answers as
  git. An empty value is always accepted, because it means "find git on
  `PATH`". The refusal message MUST name the value that was tried.
- `radSocket` MUST, when non-empty, be short enough for a Unix domain socket
  path — at most 107 bytes, one less than the 108-byte `sun_path` capacity
  that holds its terminator. The refusal message MUST name the limit. The
  `node-paths` capability owns the full rule, including why this check is not
  redundant with the one at resolution time.
- `remoteSeed` MUST, when non-empty, begin with `http://` or `https://`.
  Validation of `remoteSeed` is shape-only: whether the seed answers is not
  checked here and MUST NOT put a network round trip on a settings write.
- `radHome` has no value validation.

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

### Requirement: A settings file that cannot be read yields defaults

The module MUST start with working defaults rather than failing when the
settings file is absent, unreadable, or does not parse as a JSON object. A
store constructed with an empty path MUST likewise report defaults, and MUST
refuse a write naming the problem rather than reporting success for a value
it did not store.

Keys present in the file that the store does not know MUST be ignored and
MUST NOT appear in what `getSettings` reports.

#### Scenario: A missing file yields defaults

- **WHEN** a store is constructed over a path where no file exists
- **THEN** reading `mode` MUST give `explore`

#### Scenario: A file that is not JSON yields defaults rather than a dead module

- **WHEN** the settings file contains `{ this is not json at all`
- **THEN** constructing a store over it MUST succeed
- **AND** reading `mode` MUST give `explore`

#### Scenario: An unknown key in the file is ignored

- **WHEN** the settings file contains
  `{"mode":"explore","somethingElse":"x"}`
- **THEN** reading `mode` MUST give `explore`
- **AND** the reported settings MUST NOT contain a key `somethingElse`

#### Scenario: A store with no path reports defaults and refuses to write

- **WHEN** a store is constructed with an empty path
- **THEN** reading `mode` MUST give `explore`
- **AND** a write of `mode` with value `local` MUST return
  `{"error":"..."}`
- **AND** a subsequent read of `mode` MUST still give `explore`

### Requirement: A stored mode this build cannot interpret reads back as explore

`setSetting` validates, so the module never writes an unknown mode — but the
file lies under the user's own data directory and a hand edit, a torn write,
or a newer build can leave one. Such a value MUST be reported as `explore`,
the one mode that touches no local profile, rather than passed through to a
caller that has no interpretation for it and rather than falling back to
`local`, which would claim a node identity on the strength of a file the
build has just admitted it cannot read.

Sanitising the mode MUST NOT discard the file's other settings, and MUST NOT
rewrite the file: the stored string stays as it was found, so a build that
understands it loses nothing.

A mode the build does know MUST be reported unchanged.

#### Scenario: An uninterpretable stored mode is reported as explore

- **WHEN** the settings file contains
  `{"mode":"turbo","remoteSeed":"https://kept.example.test"}`
- **THEN** reading `mode` MUST give `explore`
- **AND** reading `remoteSeed` MUST give `https://kept.example.test`

#### Scenario: Each known mode is reported unchanged

- **WHEN** the settings file contains `{"mode":"local"}`, then
  `{"mode":"embedded"}`, then `{"mode":"explore"}` in turn
- **THEN** reading `mode` after each MUST give exactly the mode that was in
  the file

#### Scenario: The unreadable-mode fallback is not a file rewrite

- **WHEN** a store reads a settings file containing `{"mode":"turbo"}`
- **AND** no write is performed through that store
- **THEN** the file on disk MUST still contain the mode string `turbo`

### Requirement: A settings write that repoints the module is applied at once

Writing `mode`, `radHome` or `radSocket` changes which Radicle home the
module reads. Those three MUST take effect on the running instance rather
than at the next start: after such a write, `getCapabilities` MUST report the
home and availability of the newly selected mode, not of the previous one.

Writing `remoteSeed` MUST adopt the URL for subsequent `remote*` calls.

Writing `gitPath` MUST NOT change the `git` in force on the running instance:
it is validated and stored now and applied at the next module start, because
the only channel that reaches Radicle's `git` spawn sites is the process's
own `PATH`, which can only be written safely before any thread exists. A
caller MUST be told this rather than left to infer that the change is live.

#### Scenario: Switching mode changes the reported home in the same session

- **WHEN** `setSetting` writes `mode` as `local` against a resolvable Radicle
  home, and `getCapabilities` is read
- **AND** `setSetting` then writes `mode` as `embedded`, and
  `getCapabilities` is read again
- **THEN** the two replies MUST report different `radHome` values
- **AND** the second reply's `mode` MUST be `embedded`

#### Scenario: Switching to explore reports no home at all

- **WHEN** `setSetting` writes `mode` as `local` against a resolvable Radicle
  home, and then writes `mode` as `explore`
- **THEN** `getCapabilities().radHome` MUST be empty
- **AND** `getCapabilities().localAvailable` MUST be false

#### Scenario: The settings panel states the git path's restart-to-apply terms

- **WHEN** the settings panel is shown
- **THEN** it MUST display text saying that a changed git path is checked
  immediately but takes effect the next time the module is started

### Requirement: A view renders settings from the reply it was given

A view MUST populate itself from a `getSettings` reply rather than from its
own assumptions, and MUST re-render from the object a successful `setSetting`
returns rather than from the value it submitted.

A refusal MUST be surfaced to the user verbatim — the messages name the path
that was tried and the limit that was exceeded, which is the whole reason
validation happens on write — and the displayed settings MUST NOT change. A
subsequent successful write MUST clear a previously displayed refusal.

#### Scenario: The panel shows the persisted settings

- **WHEN** the settings panel is loaded against a store holding `mode` of
  `local`
- **THEN** the panel MUST report its current mode as `local`

#### Scenario: Choosing a mode persists it and the panel follows

- **WHEN** the user chooses a mode in the panel
- **THEN** the panel MUST issue a `setSetting` write for `mode` with that
  value
- **AND** the panel's reported current mode MUST become the mode written

#### Scenario: Two different mode choices give two different panel states

- **WHEN** the user chooses `embedded`, and then chooses `explore`
- **THEN** the panel's reported current mode MUST be `embedded` after the
  first choice and `explore` after the second

#### Scenario: A refused git path is shown and changes nothing

- **WHEN** the user saves a git path the backend refuses
- **THEN** the panel MUST display the refusal message returned by the backend
- **AND** the panel's reported current git path MUST be unchanged

#### Scenario: A refused mode shows its own message

- **WHEN** a mode write is refused with a message naming the mode
- **THEN** the panel MUST display that message rather than the git path's
  message

#### Scenario: A successful write clears a previous refusal

- **WHEN** the panel is displaying a refusal message
- **AND** a subsequent write is accepted
- **THEN** the panel MUST no longer report an error
