# source-modes Specification

## Purpose
Define the three source modes — `explore`, `local` and `embedded` — as one
setting that decides which Radicle node, if any, this module reads: what each
mode resolves, which modes this build can start, and what `getCapabilities()`
reports so that a view can render the mode in force without keeping a second
opinion about it.

## Requirements

### Requirement: The three modes and what each resolves

The module MUST recognise exactly three modes, persisted as the strings
`explore`, `local` and `embedded`, and each MUST resolve its own Radicle home
independently of the others.

`explore` MUST resolve no home at all. `local` MUST resolve the home the
environment or the `radHome` setting names. `embedded` MUST resolve the
module's own home under the Basecamp profile's XDG data directory, never a
home reachable from `RAD_HOME` or `$HOME`.

No mode MUST fall through to another mode's home resolution. A mode this build
resolves no home for MUST be inert — it MUST report no home rather than
inheriting the one `local` would have resolved.

#### Scenario: Local reports the environment's profile

- **WHEN** a readable Radicle profile exists at the home the environment names
  and the mode is set to `local`
- **THEN** `getCapabilities().radHome` MUST equal that home
- **AND** `getCapabilities().localAvailable` MUST be true

#### Scenario: Explore reports no home even when a profile exists

- **GIVEN** the same environment, in which `local` reports a non-empty
  `radHome` and `localAvailable: true`
- **WHEN** the mode is set to `explore`
- **THEN** `getCapabilities().radHome` MUST be the empty string
- **AND** `getCapabilities().localAvailable` MUST be false

#### Scenario: Embedded reports its own home, not the user's

- **GIVEN** the same environment, in which `local` reports the environment's
  profile as `radHome` with `localAvailable: true`
- **WHEN** the mode is set to `embedded`
- **THEN** `getCapabilities().radHome` MUST be non-empty and MUST be a path
  under the Basecamp profile's XDG data directory
- **AND** it MUST NOT equal the home `local` reported
- **AND** `getCapabilities().localAvailable` MUST be false while no identity
  has been created in that home
- **AND** `getCapabilities().canWriteLocal` MUST be false

#### Scenario: Embedded with no resolvable data directory is inert

- **GIVEN** neither `XDG_DATA_HOME` nor `HOME` is set, while `RAD_HOME` names a
  readable profile
- **WHEN** the mode is `embedded`
- **THEN** `getCapabilities().radHome` MUST be the empty string, and in
  particular MUST NOT be the profile `RAD_HOME` names
- **AND** `getCapabilities().localAvailable` MUST be false
- **AND** `getCapabilities().canWriteLocal` MUST be false
- **AND** `getCapabilities().writeUnavailableReason` MUST be non-empty, MUST
  name the environment variables that would give the module a data directory,
  MUST NOT advise running `rad auth`, and MUST NOT contain a path fragment left
  dangling by an empty home

### Requirement: The reason a profile is absent fits the mode that asked

When the mode in force resolves a home holding no profile, the reason reported
MUST be worded for that mode.

In `local` it MUST advise installing Radicle and running `rad auth`, which is
the fix for a home the user manages. In `embedded` it MUST NOT mention
`rad auth` — a mode whose premise is that the user never runs it — and MUST
instead name the embedded home and state that it is a separate identity from
any node the user already runs.

The reason MUST never be empty when the profile is absent: an absence with no
explanation is indistinguishable on screen from a blank pane.

#### Scenario: Embedded with no identity yet is explained in its own words

- **GIVEN** a readable profile exists at the home the environment names, so
  `local` reports `localAvailable: true`
- **WHEN** the mode is set to `embedded`, whose home holds no identity
- **THEN** `getCapabilities().writeUnavailableReason` MUST be non-empty
- **AND** it MUST NOT contain `rad auth`
- **AND** it MUST contain the value of `getCapabilities().radHome`
- **AND** it MUST state that this is a separate identity

#### Scenario: Local with no profile still gets the rad auth advice

- **GIVEN** the mode is `local` and the home the environment names holds no
  profile
- **THEN** `getCapabilities().localAvailable` MUST be false
- **AND** `getCapabilities().writeUnavailableReason` MUST contain `rad auth`

### Requirement: An uninterpretable stored mode resolves to Explore

A stored mode string that this build does not recognise MUST NOT reach any
consumer. Reading it MUST yield `explore`, and the module MUST report no local
home, no local availability and no write capability for it.

The stored file MUST NOT be rewritten on such a read: the value a newer build
or a hand edit left MUST survive so that build reading it again loses nothing.

#### Scenario: An unknown mode on disk grants no local access

- **GIVEN** a readable Radicle profile exists at the home the environment
  names, and a settings file naming mode `local` makes the module report that
  home with `localAvailable: true`
- **WHEN** the settings file is replaced with one naming a mode this build does
  not know, and the module is constructed again
- **THEN** `getCapabilities().mode` MUST be `explore`
- **AND** `getCapabilities().radHome` MUST be the empty string
- **AND** `getCapabilities().localAvailable` MUST be false
- **AND** `getCapabilities().canWriteLocal` MUST be false

### Requirement: Startable means a mode resolves a workable home

`startableModes()` MUST report every mode this build can start, and a mode
counts as startable when it resolves a home this module can work against —
**not** when a node daemon is running in it. On this build all three modes
therefore resolve a workable home and are reported as startable.

**That is a fact about what this build reports, not a licence for a view to
assume it.** Every view-layer requirement below is a property of the control
for *any* set the backend might report, including sets no current build
produces — and the component tests deliberately construct builds where
`embedded` is absent from the set, because a control that is correct only for
the set that happens to ship is a control that breaks silently the moment a
mode stops resolving. A view MUST NOT hard-code the membership of this set, and
simplifying a startability check to a constant on the strength of the sentence
above is precisely the error it must not invite.

Whether a daemon answers is a separate question with a separate lifetime:
`getCapabilities().localNodeRunning` answers it by probing the control socket
live, so it MUST be free to change while the module runs, whereas the startable
set is a fact about the build and MUST NOT change at runtime.

`modeIsStartable(mode)` MUST agree with membership of the startable set for
every mode, so the boolean and the set cannot disagree.

#### Scenario: Every known mode is startable and says so per mode

- **WHEN** the mode is set in turn to `explore`, `local` and `embedded`
- **THEN** `getCapabilities().mode` MUST equal the mode just set, in each case
- **AND** `getCapabilities().modeStartable` MUST be true in each case
- **AND** `getCapabilities().modeUnavailableReason` MUST be the empty string in
  each case

#### Scenario: A mode outside the three is not startable

- **WHEN** `modeIsStartable` is asked about a string that is not one of the
  three modes
- **THEN** it MUST return false
- **AND** that string MUST NOT appear in `getCapabilities().startableModes`

#### Scenario: Startability does not require a running daemon

- **GIVEN** an `embedded` home with no identity created in it and no node
  daemon listening on any control socket
- **THEN** `getCapabilities().modeStartable` MUST be true for `embedded`
- **AND** `getCapabilities().localNodeRunning` MUST be false

#### Scenario: localNodeRunning is false wherever no profile is available

- **GIVEN** the mode in force resolves no readable profile, so
  `getCapabilities().localAvailable` is false
- **THEN** `getCapabilities().localNodeRunning` MUST be false regardless of
  what the resolved socket path is

### Requirement: The startable set is reported, not derived from one mode

`getCapabilities()` MUST report `startableModes` as an array, and its contents
MUST equal `SettingsStore::startableModes()` element for element — neither a
subset nor a superset.

The array MUST NOT vary with the mode in force: selecting a mode MUST NOT add
it to the set and MUST NOT remove any other mode from it.

A view that annotates which modes are available MUST consume `startableModes`
and MUST NOT derive that set from the boolean `modeStartable`, which answers
only whether the mode in force can start.

#### Scenario: The reported array matches the store's own answer exactly

- **WHEN** `getCapabilities()` is called
- **THEN** `startableModes` MUST be an array containing `explore`, `local` and
  `embedded`
- **AND** its length MUST equal the length of
  `SettingsStore::startableModes()`
- **AND** it MUST NOT contain any string that is not a known mode

#### Scenario: The set does not move when the selected mode moves

- **WHEN** `getCapabilities().startableModes` is read with the mode set to
  `local`, and read again with the mode set to `embedded`
- **THEN** both arrays MUST be non-empty
- **AND** the two MUST be equal

#### Scenario: A picker annotates a row from the set, not from the boolean

- **GIVEN** a mode picker rendering one row per mode, told a startable set that
  omits one mode while the mode in force is a different, startable one
- **THEN** the omitted mode's row MUST show its unavailable annotation
- **AND** the rows for the modes in the set MUST NOT show one

#### Scenario: Annotation follows the set when a mode becomes startable

- **GIVEN** a picker told a startable set omitting `embedded`, which therefore
  annotates the `embedded` row as unavailable
- **WHEN** the same picker is told a startable set that includes `embedded`,
  with nothing else changed
- **THEN** the `embedded` row MUST NOT show the unavailable annotation

### Requirement: An unstartable mode is offered and says so before it is chosen

Every mode MUST be selectable, including one the startable set omits: a mode
MUST NOT be hidden, and MUST NOT be silently inert when chosen.

A control offering the modes MUST mark any mode the startable set it was given
omits, on that mode's own row or segment, keyed on membership of the set rather
than on whether that mode is the one currently selected — so the caveat is
legible while the user is deciding. This behaviour is a property of the control
and MUST hold for any startable set it is given, including sets no current
build reports.

A control that ANNOTATES AN ABSENCE MUST distinguish three states of the
startable set. An absent set — `undefined`, meaning nothing has been reported
yet — MUST annotate nothing, in either direction. A reported empty array MUST
annotate every mode, because it is a build saying it can start none. A
populated array MUST annotate exactly the modes it omits.

A component that merely derives whether the mode IN FORCE is startable — and
annotates nothing on its own — MUST instead treat an empty array as not yet
reported and reduce to startable, so that no not-implemented state is shown
before the first capabilities reply arrives.

#### Scenario: Only the unstartable mode is marked

- **GIVEN** a segmented control told a startable set containing `explore` and
  `local` but not `embedded`
- **THEN** the `embedded` segment's unavailable marker MUST be visible
- **AND** the `explore` and `local` segments' markers MUST NOT be visible

#### Scenario: An unstartable mode can still be selected

- **GIVEN** a segmented control whose startable set omits `embedded`
- **WHEN** the `embedded` segment is clicked
- **THEN** the control MUST report `embedded` as the mode chosen

#### Scenario: Nothing is marked before the startable set is known

- **GIVEN** a segmented control whose startable set has not been reported —
  the value is `undefined` rather than an array
- **THEN** every segment's unavailable marker MUST NOT be visible, including
  the marker for a mode a reported set would have omitted

#### Scenario: A reported empty set marks every mode

- **GIVEN** a segmented control told a startable set that is an empty array
- **THEN** every segment's unavailable marker MUST be visible

#### Scenario: A deriving component reads an empty set as not yet reported

- **GIVEN** a component that derives only whether the mode in force is
  startable, told an empty startable set and a mode of `local`
- **THEN** its derived startable flag MUST be true
- **AND** when it is told a populated set omitting `local`, that flag MUST
  become false

### Requirement: The method prefix is derived from the mode

The `remote*` / `local*` method prefix a view calls MUST be derived from the
mode and MUST NOT be a separately stored or separately chosen value, so the two
cannot drift apart.

`local` and `embedded` MUST both derive the `local` prefix, and `explore` MUST
derive `remote`. Every mode that derives `local` MUST be named explicitly: a
mode the derivation does not recognise MUST derive `remote`, the prefix that
touches no local profile.

Because `local` and `embedded` derive the same prefix, the prefix MUST NOT be
treated as a proxy for the mode.

#### Scenario: Each mode derives its prefix

- **WHEN** the mode is `explore`
- **THEN** the derived prefix MUST be `remote`
- **AND** when the mode is `local` the derived prefix MUST be `local`
- **AND** when the mode is `embedded` the derived prefix MUST be `local`

#### Scenario: An unrecognised mode derives the seed prefix

- **WHEN** the mode is a string the view does not recognise
- **THEN** the derived prefix MUST be `remote`

#### Scenario: Before the mode is known the prefix is the seed's

- **GIVEN** a view that has not yet been told the mode in force
- **THEN** the derived prefix MUST be `remote`

#### Scenario: The prefix applies to every method, not only listing

- **WHEN** a method name is built for a suffix other than `ListRepos` while the
  mode is `local`
- **THEN** the resulting method name MUST carry the `local` prefix
- **AND** an explicit source override passed by the caller MUST take precedence
  over the derived prefix

#### Scenario: Switching between two modes sharing a prefix is still a switch

- **GIVEN** the mode in force is `local` and a view has loaded from it
- **WHEN** the mode in force becomes `embedded`, so the derived prefix is
  unchanged
- **THEN** the settled notification MUST have been emitted exactly once
- **AND** when the mode in force returns to `local` it MUST be emitted once
  more, so the user's own node does not render as an empty one

#### Scenario: A switch loads from the mode now in force, not the one clicked

- **GIVEN** a view showing repositories fetched under one mode
- **WHEN** a different mode is picked and the mode in force subsequently
  changes to it
- **THEN** the repositories shown MUST be those the new mode's node returned
- **AND** a reply to a request issued under the previous mode, arriving after
  the switch, MUST be discarded rather than rendered

### Requirement: Picking a mode and the mode settling are separate events

A view MUST distinguish the moment a mode is picked from the moment the mode in
force actually changes, and MUST NOT reload data on the pick: the persisting
write is still in flight then, so everything derived from the mode still
describes the mode being left.

The settled notification MUST be emitted when the mode in force moves, and MUST
NOT be emitted when the mode in force is reassigned the value it already has.

#### Scenario: The pick notifies but does not settle

- **GIVEN** the mode in force is `local`
- **WHEN** a different mode is selected, before any capabilities reply arrives
- **THEN** the change notification MUST have been emitted exactly once
- **AND** the settled notification MUST NOT have been emitted

#### Scenario: The capabilities reply is what settles it

- **GIVEN** the state above, with a pick made and nothing settled
- **WHEN** the mode in force becomes the picked mode
- **THEN** the settled notification MUST have been emitted exactly once
- **AND** the change notification MUST NOT have been emitted a second time

#### Scenario: Reassigning the same mode settles nothing

- **GIVEN** the mode in force is `local`
- **WHEN** the mode in force is assigned `local` again
- **THEN** the settled notification MUST NOT have been emitted

### Requirement: Picking a mode persists it and the backend is the authority

Picking a mode MUST persist it through `setSetting("mode", …)`; the control
that offered the choice MUST NOT record its own copy of the mode in force.

What a view displays as the mode in force MUST come from
`getCapabilities().mode`, so a mode that failed to persist is not shown as
selected.

A pick of the mode already in force MUST persist nothing, and MUST leave the
control able to accept the next pick.

Changing `mode`, `radHome` or `radSocket` MUST repoint the module at the newly
resolved home without a restart, and MUST announce the new capabilities.

#### Scenario: Clicking a segment persists that mode

- **WHEN** a segment naming a mode other than the one in force is clicked
- **THEN** exactly one `setSetting` write MUST be issued, for key `mode` with
  that mode as its value

#### Scenario: Clicking the mode already in force writes nothing

- **WHEN** the segment for the mode already in force is clicked
- **THEN** a `setSetting` write MUST NOT be issued
- **AND** a subsequent click on a different segment MUST still issue its write

#### Scenario: A click during an in-flight write is not lost

- **GIVEN** a segment has been clicked and its `setSetting` write has not yet
  been answered
- **WHEN** a second, different segment is clicked
- **THEN** two `setSetting` writes MUST have been issued
- **AND** once both are answered, the mode in force MUST be the one clicked
  second

#### Scenario: Selecting an unknown mode is refused before it is persisted

- **WHEN** a mode selection is requested for a string that is not one of the
  three modes
- **THEN** the selection MUST be refused
- **AND** the change notification MUST NOT be emitted
- **AND** the mode the view reports as in force MUST be unchanged

#### Scenario: Changing the mode repoints the module at once

- **GIVEN** the mode is `local` and `getCapabilities().radHome` reports the
  environment's profile
- **WHEN** `setSetting("mode", "embedded")` succeeds
- **THEN** the next `getCapabilities()` MUST report the embedded home, without
  the module being restarted
- **AND** a local-availability change MUST have been announced

### Requirement: getCapabilities reports the mode and its consequences

`getCapabilities()` MUST report, alongside the rest of its fields: `mode` (one
of the three strings, whatever is on disk), `modeStartable`, `startableModes`,
`modeUnavailableReason`, `radHome`, `radSocket`, `pathsProblem`,
`localAvailable`, `localNodeRunning`, `canWriteLocal` and
`writeUnavailableReason`.

`modeUnavailableReason` MUST be the empty string whenever `modeStartable` is
true, and MUST be present rather than omitted.

On this build that condition holds for every mode, so the field is empty in
every state a test can reach: every known mode is startable and an unknown
stored mode resolves to `explore`. The requirement is written as the
conditional rather than as "it is always empty" for two reasons — the view
layer consumes it for sets the backend does not currently report (a control
marking an unstartable mode needs the sentence to show), and a fourth mode, or
a mode that stops resolving, makes the conditional live without any edit here.

Whether the sentence-building code that fills it should stay at all is an open
question recorded in `tasks.md`, not settled by this spec.

`getCapabilities()` MUST NOT fail: a probe that cannot answer MUST be reported
as a reason a capability is absent, not as an `{"error":"..."}` reply.

#### Scenario: The mode fields are all present and consistent

- **WHEN** `getCapabilities()` is called in any mode
- **THEN** the reply MUST contain `mode`, `modeStartable`, `startableModes`,
  `modeUnavailableReason`, `radHome`, `radSocket` and `pathsProblem`
- **AND** `mode` MUST be one of `explore`, `local`, `embedded`
- **AND** `modeUnavailableReason` MUST be the empty string whenever
  `modeStartable` is true

#### Scenario: Switching modes changes the reported home

- **GIVEN** `getCapabilities().radHome` read with the mode set to `local`,
  pointed at a readable profile
- **WHEN** the mode is set to `embedded` and `getCapabilities()` is called
  a second time
- **THEN** the two reported `radHome` values MUST differ
- **AND** both `radSocket` and `pathsProblem` MUST be present in each reply

### Requirement: A write affordance is gated on canWriteLocal

`canWriteLocal` MUST be the result of probing for a usable signing key, not a
build flag and not a restatement of `localAvailable`: a profile can exist while
its key stays locked.

A view MUST gate every write affordance on `canWriteLocal` and MUST NOT gate it
on `localAvailable`.

`writeUnavailableReason` MUST be the empty string exactly when `canWriteLocal`
is true, so a view never shows an explanation next to an available write.

#### Scenario: A locked key leaves the profile readable but not writable

- **GIVEN** `getCapabilities().localAvailable` is true and no signing key can
  be obtained
- **THEN** `getCapabilities().canWriteLocal` MUST be false
- **AND** `writeUnavailableReason` MUST be non-empty and MUST say why no write
  is possible

#### Scenario: An available write carries no reason

- **GIVEN** a probe reporting that a write is possible
- **THEN** `canWriteLocal` MUST be true
- **AND** `writeUnavailableReason` MUST be the empty string

#### Scenario: A probe that cannot be read is a refused write, not a failure

- **GIVEN** the write probe returns a reply that cannot be parsed
- **THEN** `canWriteLocal` MUST be false
- **AND** `writeUnavailableReason` MUST be non-empty
- **AND** `getCapabilities()` MUST still return a capabilities object rather
  than an `{"error":"..."}` reply

#### Scenario: A view's write flag tracks canWriteLocal alone

- **GIVEN** a view told `localAvailable: true` and `canWriteLocal: false`
- **THEN** the view's write-enabled flag MUST be false

### Requirement: A mode that cannot start asks its node for nothing

A view MUST NOT issue a request against a mode the startable set it was given
omits. It MUST NOT issue the request and then hide the reply, because the reply
would still arrive and repopulate what is on screen. As with the annotation
above, this is a property of the view for any set it is given, not a claim that
a current build reports such a set.

While a view is declining to fetch for such a mode, it MUST render an
explanation rather than nothing, and MUST NOT render wording that claims the
mode's node exists and holds no repositories.

The decision to decline MUST be derived from the reported startable set, not
from a comparison against a particular mode's name, so that a mode becoming
startable changes this behaviour with no view edited.

#### Scenario: An unstartable mode issues no list request

- **GIVEN** a repository list in a mode the reported startable set omits
- **WHEN** the list loads
- **THEN** a list request MUST NOT be issued to the backend
- **AND** the not-implemented explanation MUST be visible
- **AND** the "no repositories" wording MUST NOT be visible

#### Scenario: A startable mode fetches and shows what it fetched

- **GIVEN** the same repository list, in a mode the reported startable set
  contains, whose backend answers with repositories named after that mode
- **WHEN** the list loads
- **THEN** a list request MUST be issued
- **AND** the rows shown MUST be the ones that mode's node returned
- **AND** the not-implemented explanation MUST NOT be visible

#### Scenario: The declining state follows the set, not a mode name

- **GIVEN** a repository list showing the not-implemented explanation because
  the reported startable set omits the mode in force
- **WHEN** the reported startable set is changed to include that mode, with the
  mode in force unchanged
- **THEN** the not-implemented explanation MUST NOT be visible

#### Scenario: An unprovisioned embedded home is not reported as empty

- **GIVEN** the mode is `embedded`, the mode is startable, and the backend
  refuses the list request because no identity exists in the embedded home yet
- **THEN** no repositories MUST be listed
- **AND** the pane MUST NOT be blank — it MUST carry rows, a message or an
  error, so there is something for the user to act on
- **AND** the "no repositories" wording MUST NOT be shown in its place, since
  a home with no identity is not a node that exists and holds nothing

Note the third clause is **not currently pinned by a test**: the covering test
asserts only that the pane is not blank, which an error *alongside* the
"no repositories" wording would satisfy. The sibling case for an unstartable
mode does check the empty-state is hidden, and this case wants the same. That
gap is recorded in `tasks.md` rather than closed here, because this change adds
no tests.
