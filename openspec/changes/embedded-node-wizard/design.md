# Design — the embedded node's guided setup

## Context

The spec (`specs/embedded-setup/spec.md`) defines a six-step flow — preflight,
mode, identity, network, start, confirm — over module methods that all already
exist in `radicle_ui.rep`. No transport change, no core-module change, no new
slot. What is being decided here is therefore entirely about **shape in QML**:
where the flow's state lives, how "which step is in force" and "what blocks
what" are represented, and how a step's call is kept from repopulating a step
the user has left.

## Decisions

### The flow's state is a non-visual `QtObject`, separate from the view

`SetupFlow.qml` holds the step in force, the four preflight findings, the
blocking rules and the call-issuing functions. `SetupWizard.qml` renders it and
owns no state of its own beyond the text fields a user types into.

The alternative — one QML file with the state inline, the way `Main.qml` began —
is what this repo has already paid to undo twice. `NavState.qml` and
`SourceState.qml` were both extracted from larger files *because the behaviour
could not be tested while it was tangled into a view*, and CLAUDE.md records
that the test for each "fell out in minutes" afterwards. This flow has more
conditional behaviour than either of them: six steps, four findings, five
distinct blocking rules and a staleness guard. Writing it inline and extracting
it later would repeat a refactor whose outcome is already known.

The concrete payoff is that every `advance`/`back`/blocking assertion in the
spec is a test against a `QtObject` with no window, no layout and no rendering —
so a test asserting "advancing from the identity step MUST be permitted" asks
the flow directly rather than hunting a disabled control in a scene graph.

### The step in force is an index into one ordered list, not six booleans

`steps` is `["preflight", "mode", "identity", "network", "start", "confirm"]`
and `stepIndex` is an integer into it. `step` is derived.

This is the "complexity in the data structure, not the logic" rule applied to
the requirement that advancing "MUST move to the next step in the sequence and
MUST NOT skip one". With an index, not-skipping is true by construction —
`advance()` is `stepIndex + 1` and there is no expressible value that jumps two.
With six booleans, or with a string assigned per step, every transition is a
separate assignment that has to be got right individually, and "it went from
identity straight to start" becomes a reachable state that needs its own test.

The same shape gives "back MUST NOT be offered on the first step" as
`stepIndex > 0` and the sixth-advance-is-a-no-op requirement as a clamp, rather
than as two more conditions.

**Removing the clamp in `advance()` turns `test_advancing_walks_the_sequence`
red at its final assertion** (a sixth advance must leave the step at confirm);
removing the `stepIndex > 0` guard on `canGoBack` turns
`test_the_flow_opens_on_preflight` red.

### Blocking is keyed on the finding, and lives in one table

Each of the five blocking rules in the spec is expressed as a property that
reads a *finding*, never a step's own remembered state:

    canCreateIdentity  <- homeResolved && !identityExists
    canStartNode       <- gitFound && !alreadyServing && !startPending

The spec requires this directly ("Blocking MUST be keyed on the finding, so
that a backend reporting the finding as passing removes the block with nothing
else changed"), and it is also what makes the "a block lifts when its finding
passes" scenario testable by moving one input.

The rule that is easy to get wrong, and is therefore stated in the code as well
as here: **a missing `git` blocks start but NOT identity**, because creating key
material spawns no `git`. The natural instinct is one `preflightPassed` boolean
gating everything, which would block identity creation on a missing git and
make the flow unusable on a machine where the user's next step is to install
git and come back. The findings stay four separate values for that reason.

### A half-created home is deliberately NOT blocked

`getEmbeddedIdentity()` reports `exists:false` for both an empty home and a
half-created one — key material with no finished profile — and the reply carries
nothing that distinguishes them. So the preflight *cannot* tell them apart, and
a flow that tried would be inventing a distinction the data does not support.

The backend's refusal is the only surface that names the `keys` path to remove,
so submitting creation and displaying that refusal verbatim is how the user
learns the recovery. This is why `canCreateIdentity` reads `identityExists`
(a `true` from the backend) rather than anything like "the home looked clean".

### The findings are four values, and `identityExists:false` is not "empty"

The preflight's identity finding says "no identity exists", never "the home is
empty". That wording is load-bearing rather than fussy: the home may hold a
half-created profile, and telling a user it is empty sends them looking for a
different problem when creation is then refused for a `keys` path that is
demonstrably there.

### A monotonic `epoch` drops replies from a step the user has left

Every call the flow issues captures `epoch` at issue time; the reply is
discarded unless `epoch` still matches. `back()` and `advance()` both increment
it.

This is the `wantRid`/`syncEpoch` guard CLAUDE.md names as this repo's standing
example *and* its standing counter-example — the same guard hand-written four
slightly different ways in `CommitsTab`, `IssuesTab`, `PatchesTab` and
`ThreadView`, dropping a different capture each time. Written once here, as one
counter covering every call the flow makes, rather than as a per-step capture of
whatever that step happened to think was relevant.

**Deleting the epoch check turns `test_a_late_reply_does_not_repopulate` red**,
with a fake that holds its reply across a step change and then delivers it.

### "A node is answering on the socket" is one value, not two

`alreadyServing` is written by every reading of the node's state — the
preflight's, the one that follows this flow's own successful start, and every
later `refreshNodeStatus()`. It began as a preflight-only memory, and that was
a bug review caught: `canStartNode` never withdrew after a success, so the
start button stayed enabled and a user could start a second node over the
first. `startBlockedReason` already named that contention for the case the
preflight detected; the same contention was reachable through this flow's own
button after its own start.

The fix is the data shape rather than a second condition on `canStartNode`. A
node this flow started and a node it found already running are the same fact
about the socket, so they are the same property. Had it been written as
`gitFound && !alreadyServing && !startPending && !nodeStarted`, the fourth
clause would have been a second answer to a question already asked — and the
"node whose threads died" case would then need a fifth clause to offer the
control again, which falls out for free here.

**Removing either write turns
`test_a_successful_start_withdraws_the_start_control` red**: the one in
`submitStart` covers the window before the status refresh replies, and the one
in `refreshNodeStatus` keeps the value current afterwards. The test's second
half — a start that *failed* must still offer the control — is what stops a
flow that withdrew it unconditionally from passing.

The fake had to change with it. Its `start()` now sets `serving = true`,
because the real `startNode` returns only once the control socket answers: a
fake reporting `started:true` while `getNodeStatus` kept saying
`serving:false` was modelling a state the backend cannot produce, and a test
written against it would have been asserting about a node that does not exist.

### `neutral` governs colour, not whether a finding can fail

`Finding`'s outcome was `neutral || ok ? okText : failText`, which made
`failText` unreachable for any neutral finding — the identity one, whose
`failText` carries `getEmbeddedIdentity().problem`. A genuine backend
diagnostic, such as a permissions error reading the identity store, was
silently replaced with "No identity exists here yet." That is directly against
the spec's requirement that a backend sentence be displayed verbatim.

The two ideas were folded into one flag. `neutral` means "no identity yet is
not a failure" — a statement about how an *absence* is reported — never "this
probe cannot fail". So the outcome now reads a separate `failed` property:
`neutral ? failText !== "" : !ok`. A neutral finding fails exactly when it was
given a sentence to show.

**Weakening `failed` to `neutral ? false : !ok` turns
`test_a_neutral_finding_still_shows_a_backend_problem` red.** That test's
second half — an empty home with no problem still reading as "no identity
exists here yet" — is what stops a finding stuck on `failText` from passing it.

### The passphrase is cleared once both calls that need it have run

`StackLayout` instantiates every child eagerly, so no step's controls are ever
destroyed: a plaintext passphrase left in `passphraseField.text` stays
resident for the rest of the wizard's life. That matters here specifically
because this repo's dev Basecamp ships the QML inspector compiled in (see
`docs/e2e.md`), and the inspector reads live object properties — so "resident"
means "readable", for three steps after the last call that needed it.

It is cleared on `nodeStarted` going true, which is the moment both consumers
have run: `createEmbeddedIdentity` at the identity step and `startNode` at the
start step. Keyed on the reply rather than done in the click handler, because
the handler runs *before* the reply, and clearing there would destroy the
passphrase a retry needs after a refusal.

**Removing the `Connections` block turns
`test_the_passphrase_does_not_outlive_the_calls_that_use_it` red.** The test
reads the field back at the start step *before* submitting, so it proves the
clearing happened rather than that the field was never filled.

### The preflight's gating probes are named flags, not a counter

`preflightDone` flipped on `preflightAnswers >= 3`, a literal several lines
from the four `if (fetch…)` blocks that determined it. Three different nouns
for three different counts sat within one screen — "four questions" (calls),
"four findings" (git/identity/socket/home), "three probes" (calls that gate) —
with nothing saying why three was right.

They are genuinely three different numbers, and the header now says so: the
home finding has no call of its own (it is derived from capabilities'
`pathsProblem` and identity's `home`), and `listKnownSeeds` feeds the network
step's seed list, which is not a finding and gates nothing. So four calls, four
findings, three gating answers.

The counter became three named booleans conjoined into `allProbesAnswered`.
With a literal, a fifth probe leaves a threshold to be found and updated
separately, and getting it wrong fires `preflightDone` early — reporting an
unasked question as answered, the exact failure the "unanswered ≠ failure"
decision exists to prevent — or never fires it at all. As a conjunction, adding
a probe means adding a flag the conjunction cannot be satisfied without.

### One capabilities reply, one mapping

The same seven-property mapping of a `getCapabilities()` reply was written out
twice, character-for-character identical apart from the trailing call, in the
preflight and in `refreshCapabilities()`. `applyCapabilities(caps)` is now the
single copy both call.

This is the `wantRid`/`syncEpoch` lesson applied before it costs anything
rather than after: that guard was hand-written four slightly different ways and
dropped a different capture each time, and each omission needed its own
regression test. Two copies of a seven-line mapping is where that starts.

`nodeId` is the one conditional assignment in it, and deliberately so —
capabilities carries a DID only as a fallback, so a more specific one already
reported by `createEmbeddedIdentity` or `startNode` is not overwritten.

### Replies are the authority; the flow records nothing it was told

`identityExists`, `nodeId`, `modeInForce` and `serving` are all set from reply
payloads, never from the fact that a call was issued. The spec requires it
("MUST NOT be inferred from the fact that the flow issued a call"), and the
reason is the failure this module has already shipped: a UI that believed a
write succeeded because it sent one.

The visible consequence is that `createEmbeddedIdentity` returning an error
leaves `identityExists` false, so the identity step still offers creation — and
a success sets it true, which is also what disables the control on return.

### The confirm step reuses `NodeIdentity`'s verified-clipboard pattern, not the component

`NodeIdentity.qml` copies a bare DID; the confirm step copies a whole
`rad id update --allow <DID>` line. Different payloads, so the component is not
reusable as-is — but its **verified** copy is the part worth keeping, and it is
the part that is easy to drop.

That verification exists because `TextEdit.copy()` returns nothing and reports
failure through no channel, so a copy control can confirm success while the
clipboard is untouched; a reviewer proved it by deleting the `copy()` call and
watching the old version go on saying "Copied". The offscreen Qt platform plugin
always provides a clipboard, so every test here passes either way — which is
exactly why the round trip has to be asserted rather than the call.

`CopyableCommand.qml` therefore carries the same two-editor arrangement: one
editor to copy from, a **separate** one to paste back into. Separate because
reading back from the copy editor compares the text to itself — green whether
or not anything reached the clipboard, which is the failure being guarded
against.

**Collapsing the two editors into one makes
`test_copying_puts_the_allow_line_on_the_clipboard` pass for the wrong reason**;
deleting the `clip.copy()` call turns it red only because the verifier is
separate.

### The mode step reuses `ModePicker`, which already states the consequence

`ModePicker.qml`'s `embedded` blurb already says the mode "creates a SEPARATE
identity from any node you already run — a new machine joining your network, not
the same one", which is the sentence the spec requires at the mode step. Reusing
it keeps one copy of that wording; writing a second one in the wizard would give
the repo two statements of the same consequence, free to drift, with no gate
that notices.

**The blurb carries an `objectName` so the test can assert on it as rendered.**
The test first read `picker.modes[i].blurb` — the data array the row is built
from — which stays correct however the row is drawn. Review proved the gap by
blanking the rendered `Text` to `""`: every view test stayed green, including
that one. A statement the spec requires the user to *see* had no gate that
could notice it vanishing. Asserting through `modeBlurb_<key>` closes that, and
the same mutation now reddens
`test_the_mode_step_states_the_separate_identity_consequence`.

This is the repo's "a fake returning the same thing for every input" lesson in
a second form: an assertion read off the input rather than the output cannot
distinguish "rendered" from "never rendered".

### The network step has no inbound control, and says so

No module method persists a listen address — `module-settings` fixes the store
at five keys and none describes `listen`. A toggle here would record nothing and
the node would keep binding no port, which is worse than no control at all.

The step therefore states the outbound-only default, states its consequence
("peers cannot fetch from this node" — the sentence that actually decides
whether the default is acceptable), and states that enabling inbound is not
available in this flow, so the absence reads as a decision rather than an
oversight.

**Where the inbound opt-in went:** to the configuration panel, specified in
the parallel `embedded-node-config` change's `node-config` capability. That is
the surface that introduces a channel for persisting it. `docs/PLAN.md` said
"allow inbound connections belongs in the panel as an explicit opt-in with a
port field"; that sentence is now the panel's requirement, not this flow's.

### Why the passphrase trade is stated at the control, and stays stated

`Runtime::init` is handed an **already-decrypted** signing key, so there is no
later point at which a passphrase can be supplied. That is what makes the trade
irreversible in a way the user cannot recover from without re-creating the
identity: encrypting is the right default *and* it makes the node un-startable
unattended, so a user who learns it afterwards has an encrypted identity they
cannot re-key through this module.

Both halves are stated, at the control, before it is touched, and the statement
stays visible when the passphrase is switched off. A statement naming only the
security benefit is a recommendation rather than a trade, and one that vanishes
when the control is turned off tells the user least at the moment they are
choosing the riskier option.

This paragraph is moved from `docs/PLAN.md`, where it was recorded as a
constraint on unbuilt work; the constraint is now discharged and its reasoning
belongs with the code that acts on it.

### The alias is not pre-validated in the view

`createEmbeddedIdentity` passes the `radicle` crate's own statement of the alias
rule back as its refusal. A second rule in the view would be a copy free to
drift from the crate's, and the drift would present as the wizard rejecting an
alias the backend would have accepted — with no way for the user to tell which
layer refused.

So the alias goes to the backend as typed, and the refusal is displayed
verbatim. Same reasoning as `SettingsPanel`'s git path, which is validated on
write for the same reason.

## Risks / Trade-offs

- **The flow reads capabilities but does not poll them.** `getNodeStatus` is
  re-read on demand at the start step rather than on a timer. A node that dies
  between the reply and the user reading the screen shows as serving until
  something asks again. Polling is the panel's job, where node control lives.
- **Six steps is a lot of screen for a one-time task.** Accepted because each
  step exists to state a consequence at the moment a decision is made, which is
  the whole reason the wizard is preferred to a single form.

## Open questions

Two choices were made that the spec does not require. Both are marked `NO SPEC:`
in the code and both have a test, so they are visible to review rather than
becoming permanent by accident.

- **Where the flow is entered from**, and what closing it does. This change
  wires no entry point into `Main.qml`; the close control emits `closed()`
  rather than deciding, so the host's choice stays open. The surrounding surface
  is the configuration panel change's. Marked on `SetupWizard.qml`'s `closed()`.
- **What a preflight finding shows before its probe has answered.** The spec
  requires four findings each reported as its own outcome, but says nothing
  about the window before a reply lands. Every finding has a legitimate falsy
  value, so rendering the defaults would report four failures — a missing git,
  an unresolvable home — before a single call was issued, and a user would act
  on a diagnosis of nothing. This flow names the unanswered state instead.
  Marked on `SetupFlow.qml`'s `preflightDone`, tested by
  `test_an_unanswered_finding_is_not_reported_as_a_failure`.

A third question the spec settles but the flow surfaces: **advancing past the
mode step requires `getCapabilities().mode === "embedded"`, so a flow whose
capabilities have not yet answered does not advance.** That is the requirement
read literally — an unanswered backend has not reported `embedded` — and it is
pinned by `test_an_unanswered_mode_does_not_advance` rather than left implicit,
because the tempting "fix" is to treat an empty mode as permission to continue,
which would run the four node steps against a module in explore.
