# Design — the embedded node's guided setup

## Context

The spec (`specs/embedded-setup/spec.md`) defines a six-step flow — preflight,
embedded, identity, network, start, confirm — over module methods that all already
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

### Step 2 is a confirmation, not a mode picker

The step began as a `ModePicker` — the wizard offering Explore, Local and
Embedded, reusing the picker's wording so the separate-identity sentence had one
copy. That was faithful to the spec as written and wrong in front of a user, who
ran it and saw *step 2 of 6, inside a flow titled "Set up an embedded node",
asking them to choose between three modes, all three captioned "This version
cannot start this mode yet"*. Their words: "the wizard is ONLY for the embedded
node! Explore and local were working out of the box, they don't need a wizard."

Both halves of that are real defects and they have different causes.

**The choice should never have been offered.** A user who opened this flow has
already chosen Embedded. Explore and Local need no setup at all, and the four
steps after this one are about a node neither of them runs — so picking either
abandons the rest of the flow. A choice the flow then refuses to continue from
has one permitted answer, which is not a choice. The spec was rewritten to say
so, and `confirmEmbedded()` replaced `chooseMode(mode)`.

**The caption came from a default that is correct where it lives.**
`ModePicker.startableModes` defaults to `[]` and is populated only when
`getCapabilities()` replies, so every row captions itself unstartable in the
window before that. `ModePicker.qml:55-58` documents that as deliberate: a
caller that forgets to wire the array gets over-annotation, which is visible,
rather than under-annotation, which is the bug the property was introduced to
end. So `ModePicker` is untouched — it remains the header toggle's and the
settings panel's picker, which are the surfaces where a user compares the three.
The wizard simply stopped being one of them.

**Why the step survived at all rather than being deleted.** Two things still
need it. The separate-identity consequence must be stated *before* any identity
is created — the confirm step restates it with the DID that by then exists, and
a statement made only there is made after the decision it informs. And the mode
write needs somewhere to hang: Embedded has to be in force before the four node
steps mean anything, and `getCapabilities().mode` is what the flow reads to know
it landed.

**Why the write is an explicit act rather than something arrival does.** Putting
`confirmEmbedded()` in `advance()` would be shorter and it is the wrong shape: it
would put a module into Embedded because someone opened a screen, and would make
the stated consequence something the user was *shown* rather than something they
*answered*. A user who reads the statement and thinks better of it must be able
to close the flow and still be in the mode they started in. So `advance()` and
`back()` cannot reach the write, and a `Button` is the only caller.

**`confirmEmbedded()` takes no argument, and that is the guard.** Its
predecessor `chooseMode(mode)` could express `explore` and `local`; with no
parameter the only write reachable from this flow is `mode=embedded`, so "MUST
NOT offer explore or local" holds in the state object rather than only in what
the screen happens to draw. For the same reason `SetupFlow` no longer holds
`startableModes` or `modeUnavailableReason` at all: there is no value here to
caption *from*, so the annotation cannot be reintroduced without first
reintroducing the property — a two-step regression rather than a one-line one.

**What breaks without each guard**, so a later reader knows what they are
deleting:

- Moving `confirmEmbedded()` into `advance()` reddens seven tests, among them
  `test_arriving_at_the_embedded_step_writes_no_mode`,
  `test_going_back_from_the_embedded_step_writes_no_mode` and
  `test_the_rendered_control_puts_embedded_in_force`. Verified by mutation.
- Deleting `refreshCapabilities()` from `confirmEmbedded`'s success path reddens
  `test_the_mode_in_force_is_the_reply_not_the_value_written`, on its call-log
  assertion. Note the *value* assertion alone cannot catch it: the fake is
  synchronous, so a flow that assigned `modeInForce` and also re-read would have
  the assignment overwritten in the same turn and stay green. The call log is
  what carries that requirement.
- Re-adding any text keyed on a startable array reddens
  `test_no_other_mode_is_offered_whatever_the_startable_set_says`, on either its
  "no text stating a mode cannot be started" assertion (an unconditional
  caption) or its "unchanged by the startable set" comparison (a conditional
  one). Both halves proven to discriminate independently.

**The lesson kept from the version this replaces**, because it is about how the
test is written rather than about `ModePicker`: **the statement is asserted as
RENDERED, not read off a data array.** The old test read
`picker.modes[i].blurb`, which stays correct however the row is drawn — review
proved the gap by blanking the rendered `Text` to `""` and watching every view
test, including that one, stay green. A statement the spec requires the user to
*see* had no gate that could notice it vanishing.
`test_the_embedded_step_states_the_separate_identity_consequence` now walks the
scene graph to the `Text` and reads `text` off it, so deleting it, hiding it or
blanking it all redden.

That is the repo's "a fake returning the same thing for every input" lesson in a
second form: an assertion read off the *input* rather than the output cannot
distinguish "rendered" from "never rendered". It is also why the "no other mode
is offered" test asserts on a walk of every visible string rather than on
objectNames alone — an objectName check catches the caption coming back under
its old name and misses a hand-written second copy of the same sentence.

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

### The seven Embedded states are a component, derived, with the ordering as data

`EmbeddedState.qml` is a non-visual `QtObject` holding seven *reply fields* —
`pathsProblem`, `home`, `identityExists`, `running`, `serving`, plus the two
facts only the view holds (`startPending`, `startError`) — and deriving
`current`, `sentence`, `actionLabel`, `actionKind`, `actionEnabled` and
`hasNodeToAsk` from them. `RepoList` binds the fields and renders the answers.

Three separate decisions are folded into that shape, and each one is a thing
this repo has paid for before.

**A component rather than seven conditions in `RepoList`.** Same reason
`NavState` and `SourceState` are components: the behaviour is untestable in a
view. `tst_embedded_state.qml` asks 15 questions of a `QtObject` with no window,
where the alternative was hunting a `Button`'s `enabled` through a scene graph
seven times over.

**There is no `property string state` that a reply assigns.** Every input is a
field a backend reply carried, and `current` is a pure function of them. A
stored state is a second opinion, and it is wrong exactly when it matters — after
a node's threads die, after a passphrase is refused, after the mode is changed
from elsewhere. **`test_the_state_follows_a_later_reply_rather_than_the_first`
moves the fields to running-and-serving and back, and a stored state cannot
move back.**

**The ordering lives in one `if` chain, read top to bottom, not as seven
independent predicates.** More than one condition holds at once — a start
refused in a home that later reports a `pathsProblem` — so "which one wins" is a
real question that seven booleans answer seven times. As a chain it is answered
once, and the answer is the chain's order: most fundamental obstacle first, so a
user is told there is nowhere to write *before* being told a start failed rather
than being sent to retry a start that cannot succeed. **Hoisting `startFailed`
above `blocked` turns `test_the_most_fundamental_obstacle_is_the_one_rendered`
red** at its first assertion, and nothing else.

Two places in that order are worth knowing before anyone tidies them:

- **`stopped` sits above `starting`.** A start issued against a node still
  reporting `running:false` renders as stopped, because the backend's report
  wins over what the view is waiting for. The real `startNode` returns only once
  the control socket answers, so the window is one poll wide, and telling a user
  "starting…" about a node the backend says is not running is the second-opinion
  failure this whole component avoids.
- **`actionEnabled` reads `startPending` directly rather than through
  `current`.** That is what keeps "a second node cannot be started over the
  first" true in the `stopped` window as well as the `starting` one. Folding
  `startPending` into the state would make the guard depend on which of two
  states a poll happened to land in. **Deleting the `!startPending` term turns
  `test_the_start_action_is_withheld_while_a_start_is_outstanding` red**, at its
  first assertion — the one in the `stopped` window, which is the leg a
  state-folded version would fail.

### The fetch guard is keyed on having a node, not on being startable

`RepoList.fetch()`'s bail-out was `if (page.notImplemented)` — startability — and
that is the coupling that lost this surface. A mode counts as startable when it
resolves a workable home, not when a node is running in it. So the core-module
change that added `embedded` to `startableModes()` made `notImplemented`
permanently false, which stopped the guard firing *and* stopped the panel behind
it rendering, in the same commit, with no gate failing. `localListRepos` then
went out against a home with no identity, the backend returned
`absentProfileReason`, and it latched into the red strip under an empty list.

`hasNodeToAsk` is the replacement, and it is a conjunction of two conditions that
fail for different reasons: the reported startable set omitting the mode (no mode
in this build, and still the view's property for any set it is given), and a
startable mode whose node does not exist or is not loaded. `startFailed` is in
the second group for the same reason `stopped` is — a refused start left no node
loaded. `starting` and `notServing` are not: a loaded node can be read, and a
node that has stopped serving still answers reads, because reads never touch the
daemon.

**Reverting the guard to `notImplemented` reddens seven tests in
`tst_embedded_panel.qml` and two in `tst_embedded_wiring.qml`** — the second pair
being the error-banner defect itself, at the layer that can see why it happens.
Verified by mutation, both directions.

The general lesson, which is why this is written down rather than left in the
code: **a guard and the explanation it protects must not be keyed on the same
condition.** They were, and they went away together. Keying the guard on "is
there a node" and the panel on "which state is in force" means a future change to
startability can move neither.

### `sayingNothing` reads the item's `visible`, and the observable was carried

`RepoList.sayingNothing` — the only observable in any layer that can see a pane
rendering nothing at all — read `notImplementedState.visible` *by name*. The
panel that replaces it is a different item, so the property had to be carried to
it, and **the failure to carry it would have been silent in the worst way**:
`!undefined` is `true`, so `sayingNothing` would have gone on reporting "nothing
is rendered" whatever the panel did, and `tests/ui/local.yaml`'s blank-pane
assertion would have stopped being able to fail while continuing to pass.

It is read off the item's own `visible` rather than from `embeddedShown`, the
condition the item is keyed on, for the reason the original already documented: a
recomputed copy agrees with the item whether or not the item draws. **Replacing
`embeddedState.visible` with `embeddedShown` reddens exactly one test —
`test_the_observable_follows_the_rendered_item` — and leaves the other eighteen
green.** That is the point of that test existing: it is the only thing standing
between the observable and a copy of its own condition, and the mutation proves
it rather than the comment asserting it.

One term had to change with the carrying. `loadedOnce` gated the whole
expression, and four of the seven Embedded states issue no request at all, so
`loadedOnce` never becomes true in them — a version that kept the gate would be
false in every one of those states whether or not the panel rendered, and the
"panel prevented from rendering" scenario could not go true. `expectingAPanel`
splits it: where a panel is what should be on screen its absence is the defect
and there is nothing to wait for; where a list is, `loadedOnce` still keeps this
quiet until the first reply lands.

### `reposNotImplemented` was replaced rather than deleted

`Main.qml:356` exposed `repoList.notImplemented` and `tests/ui/local.yaml`
asserted `=== false` on it. With all three modes startable that assertion is one
nothing can fail — and CLAUDE.md's rule is that a check which cannot fail is
worth no more than one that cannot pass. But deleting it outright would have left
the one state a user actually lands in with nothing asserting anything about it,
and `undefined === false` fails the step anyway, so the choice was never "delete
or keep".

`reposEmbeddedPanel` (the item's own `visible`) and `reposEmbeddedState` (which
of the seven) replace it, and both are asserted because they fail differently: a
panel that derived correctly and never drew, versus a panel that drew the wrong
state. `local.yaml` runs against a real embedded home with no identity, which is
E1, so the spec names E1 — and `reposSayingNothing === false`, two steps earlier
in the same spec, becomes genuinely meaningful for the first time, because the
thing it now reads is the panel.

### The panel's action emits a signal that nothing listens to

`RepoList.embeddedActionTaken(kind)` is emitted with `"setup"`, `"start"` or
`"restart"`. **Nothing connects to it in `Main.qml` today**, deliberately: the
wizard's host is the next piece, and start/restart need a passphrase prompt this
screen has no place for.

The alternative — no control at all until a host exists — would have left E1 with
a sentence and no next step, which is the dead end this capability was written to
remove. The alternative in the other direction — performing the act here — is
refused by the spec and by the shape: `RepoList` is injected with one `call`
function, so every backend call it could make is in the test's log, which makes
"rendering the state writes nothing" structural rather than a promise
(`test_rendering_the_state_writes_nothing`).

So the control is real, the signal is real, and it reaches nobody. That is
marked `NO SPEC:` on the signal rather than left to be discovered, and it is the
one thing in this change a reviewer should check has not quietly become
permanent.

### The generic unstartable copy stopped naming Embedded

`notImplementedState`'s text read *"Embedded runs a node inside Basecamp … it is
not available in this version yet"*. Embedded is startable now, so that sentence
would be rendered — falsely — for whichever mode the backend actually declines.
`source-modes` requires the state to be derived from the reported startable set
rather than from a mode name, and prose naming a mode re-encodes the mode name
one layer up where no gate can see it. The copy is now mode-neutral, and
`test_embedded_shows_the_not_implemented_state` asserts the note does *not*
contain the word "Embedded".

`tst_embedded.qml` was re-pointed rather than deleted for the same reason the
requirement survived: the file is about a mode the startable set omits, and it
drives `local` now instead of `embedded`. Driving `embedded` had become
incoherent — its "and it must actually list" leg collided with the panel's own
fetch guard, because a startable Embedded with no node correctly issues nothing,
so the assertion would have failed for a reason the file is not about.

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
- **The Embedded state is read on mode-settle and on backend-ready, not
  polled.** `getNodeStatus` probes a control socket, and the panel is a state a
  user acts on rather than a live monitor — so a node that dies while the panel
  is on screen goes on reading as `runningEmpty` until something asks again.
  Polling belongs with node control in Settings › Node, which is where a user
  who cares about liveness is. The cost is that E6 is reached on the next
  refresh rather than immediately, which the `notServing` sentence handles
  honestly once it does arrive.
- **`Main.qml`'s own wiring has no component test.** No test instantiates
  `Main.qml` — `tst_embedded_wiring.qml` reproduces its shape with the real
  components — so `refreshEmbedded()`, the `embeddedSettled` `Connections` and
  the new `app` properties are covered only by `local.yaml` at the end-to-end
  layer. That is a real gap and it is stated rather than papered over: the
  component suite being green says nothing about them.

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
embedded step requires `getCapabilities().mode === "embedded"`, so a flow whose
capabilities have not yet answered does not advance.** That is the requirement
read literally — an unanswered backend has not reported `embedded` — and it is
pinned by `test_an_unanswered_mode_does_not_advance` rather than left implicit,
because the tempting "fix" is to treat an empty mode as permission to continue,
which would run the four node steps against a module in explore.
