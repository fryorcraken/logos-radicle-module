## MODIFIED Requirements

### Requirement: A mode that cannot start asks its node for nothing

A view MUST NOT issue a request against a mode that has no node able to answer
it. Two separate conditions put a mode in that position, and a view MUST honour
both:

- the mode is one the startable set it was given omits — this build reports no
  such mode, and the requirement is a property of the view for any set it is
  given;
- the mode is startable, and so resolves a workable home, but no node exists in
  that home or none is loaded. `embedded` before its identity is created, and
  `embedded` with its node stopped, are both of this kind. `embedded-state`
  states which of its states have a node to ask and which do not.

**Startability is not the test, and treating it as one is how this surface was
lost.** A mode counts as startable when it resolves a workable home, not when a
node is running in it, so a guard keyed on startability stops firing for a mode
the moment that mode becomes startable — while the node it would have asked
still does not exist. That is exactly what happened to `embedded`: the guard and
the explanation it protected were keyed on the same condition, so both went away
together, leaving a request issued against a home with no identity and a refusal
rendered as an error banner.

A view MUST NOT issue the request and then hide the reply. The reply would still
arrive, still pass the staleness guard that compares the mode and the derived
method prefix it was issued under, and still repopulate what is on screen.

While a view is declining to fetch, it MUST render an explanation of why rather
than nothing, and MUST NOT render wording that claims the mode's node exists and
holds no repositories.

The decision to decline MUST be derived from what the backend reports — the
startable set, and the state of the mode's node — and MUST NOT be a comparison
against a particular mode's name, so that a mode gaining a node changes this
behaviour with no view edited.

#### Scenario: An unstartable mode issues no list request

- **GIVEN** a repository list in a mode the reported startable set omits
- **WHEN** the list loads
- **THEN** a list request MUST NOT be issued to the backend
- **AND** an explanation MUST be visible
- **AND** the "no repositories" wording MUST NOT be visible

#### Scenario: A startable mode fetches and shows what it fetched

- **GIVEN** the same repository list, in a mode the reported startable set
  contains, whose node exists and is serving, and whose backend answers with
  repositories named after that mode
- **WHEN** the list loads
- **THEN** a list request MUST be issued
- **AND** the rows shown MUST be the ones that mode's node returned
- **AND** the explanation MUST NOT be visible

#### Scenario: The declining state follows the set, not a mode name

- **GIVEN** a repository list showing the explanation because the reported
  startable set omits the mode in force
- **WHEN** the reported startable set is changed to include that mode, and that
  mode's node is reported as existing and serving
- **THEN** the explanation MUST NOT be visible

#### Scenario: A startable mode whose node does not exist is asked nothing

- **GIVEN** a repository list in `embedded`, which the reported startable set
  contains, where `getEmbeddedIdentity().exists` is false
- **WHEN** the list loads
- **THEN** a list request MUST NOT be issued to the backend
- **AND** an explanation MUST be visible
- **AND** the "no repositories" wording MUST NOT be visible

#### Scenario: An unprovisioned embedded home is not reported as empty

- **GIVEN** the mode is `embedded`, the mode is startable, and no identity
  exists in the embedded home yet
- **THEN** no repositories MUST be listed
- **AND** the pane MUST NOT be blank — it MUST carry rows, a message or an
  error, so there is something for the user to act on
- **AND** the "no repositories" wording MUST NOT be shown in its place, since
  a home with no identity is not a node that exists and holds nothing
- **AND** no error banner MUST be raised, since nothing was asked

The third clause of that scenario was recorded here as unpinned by any test: the
covering test asserted only that the pane was not blank, which an error
*alongside* the "no repositories" wording would satisfy. `embedded-state` now
states it as a requirement in its own right, with scenarios that distinguish the
two, so the gap closes there rather than remaining an annotation here.
