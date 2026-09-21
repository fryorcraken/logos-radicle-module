# embedded-header Specification

## Purpose
Define what the header shows about the identity the module is operating as: that
every mode which has an identity displays it, in full and copyable, in the same
place and by the same rule — so a user can always answer "which DID am I acting
as" without opening anything, and so Embedded is not the one mode that answers it
with nothing.

This capability owns the identity's presence in the header and the rule that
governs it. It does not own the mode toggle beside it, which is `source-modes`',
nor the caption under it, nor what any mode's repository list shows, which is
`embedded-state`'s.

## Requirements

### Requirement: Every mode with an identity shows it in the header

The header MUST display the DID the backend reports for the mode in force,
whenever the mode in force has one and the reported DID is non-empty. That MUST
hold for `embedded` exactly as it holds for `local`.

`radicle_impl.h` states the reason as a requirement on any view: a user
believing they are operating as their existing DID while they are operating as a
different one finds their repositories simply missing, with nothing on screen
explaining why. Embedded is the mode where that confusion is most likely, because
its identity is one the module created rather than one the user made — so a mode
that shows no identity is showing nothing precisely where the risk is highest.

The DID MUST be displayed in full, including its `did:key:` prefix, and MUST be
the one the backend reported rather than a truncation or a placeholder — so that
a header told a different DID displays a different string.

A mode with no identity — `explore`, which resolves no home, and any mode whose
reported DID is empty — MUST display nothing rather than a blank slot or a
placeholder. An empty identity slot in a mode where the user is not operating as
anyone is noise, and a placeholder is worse, because it suggests a value that is
loading.

The display MUST be governed by one rule covering every mode, and MUST NOT be a
list of modes that each have it switched on. A rule keyed on whether the mode has
an identity is right for a mode added later without anyone editing it; a list is
one someone has to notice and extend, which is how Embedded came to show nothing
while the contract required otherwise.

#### Scenario: Embedded shows its DID as Local does

- **GIVEN** a header in `local` whose backend reports a distinctive DID
- **THEN** that DID MUST be displayed in full
- **AND WHEN** the header is in `embedded` and the backend reports a different
  distinctive DID
- **THEN** the second DID MUST be displayed in full
- **AND** the first MUST NOT be displayed

#### Scenario: A mode with no identity displays nothing

- **GIVEN** a header in `explore`, whose backend reports an empty DID
- **THEN** no identity MUST be displayed
- **AND WHEN** the header is in `embedded` with an empty reported DID, which is
  the state before an identity has been created
- **THEN** no identity MUST be displayed
- **AND WHEN** the same header is told a non-empty DID with nothing else changed
- **THEN** that DID MUST be displayed

#### Scenario: The displayed identity follows the reported one

- **GIVEN** a header in `embedded` told a distinctive DID
- **THEN** that DID MUST be displayed
- **AND WHEN** the header is told a second, different DID
- **THEN** the second MUST be displayed and the first MUST NOT

### Requirement: The header identity is copied by taking it

Taking the displayed identity MUST put the DID on the system clipboard, and MUST
confirm only once it is there.

The one thing anyone does with a DID is paste it somewhere — into
`rad id update --allow`, into a message asking a delegate to authorise this node
— so copying is the act the display exists to serve, and it MUST work the same
way in `embedded` as in `local`.

The confirmation MUST be earned rather than assumed: it MUST NOT be shown for a
copy that did not reach the clipboard. A clipboard is not available in every
environment this module runs in, and a confirmation shown regardless tells the
user their DID is in a buffer that is empty.

What is copied MUST be the full DID the backend reported, whatever the header is
displaying — so a display shortened to fit a narrow window still copies the whole
value.

#### Scenario: Taking the identity copies it in Embedded

- **GIVEN** a header in `embedded` displaying a distinctive DID
- **WHEN** the identity is taken
- **THEN** the clipboard MUST hold that DID
- **AND** the confirmation MUST be shown

#### Scenario: The confirmation is not shown for a copy that did not land

- **GIVEN** a header in `embedded` displaying a DID, where the clipboard does
  not retain what is written to it
- **WHEN** the identity is taken
- **THEN** the confirmation MUST NOT be shown

#### Scenario: The whole DID is copied whatever is displayed

- **GIVEN** a header in `embedded` displaying a DID shortened to fit
- **WHEN** the identity is taken
- **THEN** the clipboard MUST hold the full reported DID
