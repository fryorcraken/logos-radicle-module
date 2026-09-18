# Design — the embedded node's guided setup

## Context

The spec (`specs/embedded-setup/spec.md`) defines a **four**-step flow —
preflight, embedded, identity, network — over module methods that already exist
in `radicle_ui.rep`. It was six; start and confirm are gone, and where each went
is in the Decisions below rather than here.

**This is no longer a QML-only change, and exactly one thing made it not one.**
The autostart rule needs to know whether an existing identity's key is sealed,
and no reply carried that. `getEmbeddedIdentity()` now reports `encrypted`,
observed from the key on disk — one Rust function, one FFI entry point, two JSON
keys. `radicle_ui.rep` is still unchanged: every slot on it returns an opaque
JSON string, so a new key needs no transport change.

Everything else is still about **shape in QML**: where the flow's state lives,
how "which step is in force" and "what blocks what" are represented, how a step's
call is kept from repopulating a step the user has left, and — new here — where
the decision to start a node lives versus where the call is issued.

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

**That clearing alone is not sufficient, and the gap only opened once this piece
made the wizard re-openable.** Keying on `nodeStarted` covers the showing that
runs to completion and nothing else. A user who types a passphrase, creates the
identity — which consumes it once — and then closes the wizard *without* starting
the node leaves `nodeStarted` false, so nothing clears. The overlay is a single
instance whose `visible` the host toggles, never destroyed, and `SetupFlow`'s
`reset()` cannot reach the field because the field lives in the view. So the next
showing resumes at the start step holding the abandoned showing's plaintext
passphrase and would hand it to `startNode()` with no re-entry by the user and
nothing on screen saying the value is stale. Review demonstrated this against the
real component, not by reading: show → type → create → abandon → reopen left the
field holding the literal string.

So the field and the switch are also reset in `SetupWizard.show()`, which makes a
passphrase's lifetime **exactly one showing**. `show()` is the only place it can
go: it is the single per-showing entry point, it runs before anything could be
typed in the new showing, and it is in the view where the field is.

**The constraint that rules out the tempting fix** is the same one that put the
original clearing on the reply rather than the click: clearing in the start
button's `onClicked` would destroy the passphrase a retry needs after a refused
start. Keying on the showing sidesteps that entirely, because a refusal does not
re-enter `show()`.
`test_a_refused_start_keeps_the_passphrase_for_the_retry` is the guard that
stops a future edit from "simplifying" this back into the click handler —
it fails if the clear moves there. `test_a_passphrase_does_not_outlive_an_
abandoned_showing` is the one that fails if the `show()` clear is removed.

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
view. `tst_embedded_state.qml` asks its questions of a `QtObject` with no window,
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

### The panel's action emits a signal, and `Main.qml` now listens

`RepoList.embeddedActionTaken(kind)` is emitted with `"setup"`, `"start"` or
`"restart"`. **`Main.qml` connects to it**, routing `"setup"` into `openSetup()`
and nothing else anywhere — see *Start and restart route nowhere* for why the
other two have no destination and are rendered not-enabled rather than wired to
one that could not perform them.

The `NO SPEC:` marker on the signal is gone with the gap it named.

Performing the act in `RepoList` is still refused, by the spec and by the shape:
the list is injected with one `call` function, so every backend call it could
make is in the test's log, which makes "rendering the state writes nothing"
structural rather than a promise (`test_rendering_the_state_writes_nothing`).
The panel requests; the host decides.

### The routing reads the same flags the enablement does

`takeEmbeddedAction` was a bare `if (kind === "setup") openSetup();`, and the
panel's enablement was keyed on `embeddedSetupHosted`/`embeddedStartHosted`.
Those are two readings of one question — *does this act reach anybody?* — and
nothing tied them together, so they were free to disagree. They disagreed in the
direction that ships the defect: flipping `embeddedStartHosted` to `true` would
have rendered an **enabled** "Start the node" control whose click reached the
`if`, matched nothing, and was dropped silently. That is precisely the dead end
`embedded-state`'s spec names as the reason the hosting capability exists, and
review found both this file's own comment and `docs/PLAN.md` asserting "hosting
them is one property" as settled fact — the half-truth that would have let it
ship, since the existing suite never armed the flag end to end.

So routing goes through `routesEmbeddedAction(kind)`, a predicate switching on
kind and returning the *same* two flags `EmbeddedState.actionHosted` derives
from. `takeEmbeddedAction` refuses anything it says no to before performing
anything.

**It is a separate function rather than an inlined guard because it is a
different job**: it decides whether an act reaches anybody, and the caller
decides what happens when it does. That separation is what makes "is every
hosted kind routed?" a question a test can ask without performing any of the
acts — which is why it was previously unasked, and therefore untested.
`test_every_hosted_kind_is_one_the_host_routes` arms `embeddedStartHosted` and
asserts the request becomes routable, with an unnamed and an unrecognised kind
as controls so it is not satisfied by a host that accepts everything. Reverting
to the bare `if` reddens it.

What this does **not** do is write the branch that carries a start out; it
cannot, for the four reasons under *Start and restart route nowhere*. The flag
plus the branch is still two things. The value is that the two can no longer
disagree *silently*: an enabled control is now either routed or refused, never
dropped. `PLAN.md` was corrected to say so rather than to keep promising one
flip.

### "Becomes ready in Embedded" needs a freshly-built list, not a mode change

The spec names two triggers that must not raise the setup: selecting Embedded
live, and Embedded being restored as the mode already in force when the module
starts. Only the first was covered. `tst_setup_host.qml`'s single `RepoList` is
built once, before any test runs, and every test reaches its state by mutating
the harness and calling `reload()` — which is a live mode change by construction.
A host that auto-raised the setup from a completion handler reading a restored
`embedded` mode would pass it, and `local.yaml` cannot help because the app
always starts in `explore` and reaches `embedded` only by a click. So a null
implementation that opened the setup on startup whenever the resumed mode was
`embedded` with no identity passed every test at every layer.

The fix is a `Component` that builds a second `RepoList` against a harness
already in that state, which is as close to a module start as this layer gets.
**Proven by mutation rather than assumed**: adding exactly that auto-raising
`Component.onCompleted` to the fixture reddens
`test_starting_up_in_embedded_does_not_raise_the_setup` and leaves
`test_selecting_embedded_does_not_raise_the_setup` green — which is the
demonstration that the two scenarios are genuinely different and that the
existing test could not have covered this one.

### Hosting the setup extended `embedded-setup` rather than adding a capability

The obvious alternative was a capability of its own — "the setup's host" —
covering where the flow is reached from, what raising it does to the surfaces
beside it, and where a reopened flow lands. It was rejected, and the reason is
the re-entry rule rather than tidiness.

**Re-entry decides which of the six steps is in force.** "A reopened setup lands
at the first step with work left" is a statement about the step in force, which
is the thing the six-steps requirement already owns: the resume is the one move
other than advance and back that changes it, and the requirement on advancing
has to except it explicitly ("Exactly one other thing moves the step in force").
Split across two capabilities, that exception would point at a requirement in
another document, and the rule "advance MUST NOT skip" would read as violated by
a landing the reader cannot see. They are one subject.

The same argument does not obviously cover raising and lowering, which is about
surfaces rather than steps — and that is the honest weak point of the choice. It
went the same way because the two are decided together: the host raises, and the
raise is what triggers the resume. A capability boundary between them would put
`openSetup()`'s two lines in two documents.

What a separate capability would have bought is a home for the *durable settings
surface* later — and that surface is getting one (`embedded-node-config`'s
`node-config`). So the boundary that matters is setup-versus-durable-panel, which
this change respects, not host-versus-flow.

### Restart routes nowhere; start did, and the decisive reason fell

The state panel names a start for **stopped** and **start failed**, and a restart
for **not serving**. Routing either into this setup was considered and rejected
on four counts. **Three were about the start step, which no longer exists, and
the fourth — the decisive one — was a gap in the backend that this change
closed.** So the conclusion split: start is hosted, restart is not.

The original four, kept because three of them still explain why starting did not
simply move into the flow:

- **The start step was gated on no node answering the socket.** `canStartNode`
  was `gitFound && !alreadyServing && !startPending`, and a restart's node is
  answering it — that is what makes it a restart. The flow would have raised, run
  its preflight, and landed on a start step with its control disabled and
  `startBlockedReason` explaining that a node was already there. The user asked
  to restart and was shown a refusal to start.
- **It offered no stop**, so a restart's two calls could not be sequenced from
  it. `stopNode` and `startNode` compose, but nothing in the flow reported the
  pair, and the two refusals are different sentences a user should see
  separately.
- **It started the node with the passphrase its own identity step took, in the
  same showing.** A later showing does not have it.
- **Decisively: nothing could tell whether a passphrase was needed at all.**
  `getEmbeddedIdentity()` reported `home`, `exists`, `nodeId` and `problem` — and
  no `encrypted` field. Only `createEmbeddedIdentity`'s reply carried one, which
  is the reply a later session by definition does not have. So a host that wanted
  to prompt could not know whether to, and one that wanted to skip the prompt
  could not know whether it may.

**That fourth point is now false, and making it false is most of this change.**
`getEmbeddedIdentity()` reports `encrypted`, observed from the key on disk. See
*`encrypted` is a probed field on the identity reply* below for why that reply
and not another, and why the answer travels with a `problem`.

With it, the first three stop being reasons to route a start into the flow and
become reasons to put starting somewhere else entirely — which is where it went:
the Embedded surface, every time the mode is opened. A surface that knows whether
a passphrase is needed can ask for one where it must and start without asking
where it need not, and it needs no step of a flow to do either.

**Restart still routes nowhere**, and the second point above is why: it is a stop
followed by a start whose two refusals are different sentences, and nothing
sequences the pair. It belongs to the configuration panel. The panel **names it
without enabling it** and says restarting is not yet available from here. The
wording is careful about three claims it could have made and does not: not that a
restart *failed* (none was attempted), not that the node *cannot be restarted*
(it can, from a command line), but that it is not yet available *from here*. That
turns a dead end into a wait, and names the surface it is waiting on.

**The two hosting flags split, and that split is load-bearing.** `startHosted`
and `restartHosted` were one flag, on the stated grounds that "a host able to
carry out one is able to carry out the other" — true while both were blocked by
the same missing field, false the moment one was unblocked. Left as one flag,
hosting a start would silently have enabled a restart reaching nobody, which is
the dead end `embedded-state` exists to remove, re-created one state along.
`test_start_and_restart_are_hosted_independently` holds `startHosted` true in
both legs and moves only the restart flag, so a component reading one flag for
both answers the same in each and fails.

**Keyed on hosted-ness, not on the state.** `EmbeddedState` takes `setupHosted`
and `startHosted` as inputs and derives `actionHosted` from `actionKind`;
`Main.qml` reports `embeddedSetupHosted: true` and `embeddedStartHosted: false`.
The requirement is explicit that hosting an action must enable it with nothing
else changed, and this is what makes that structural: the day the settings
surface routes a start, one property flips and nothing in `RepoList` or
`EmbeddedState` is edited. A component that hard-coded "setup is enabled, start
is not" would have to be found and changed by someone who has to notice it.

That is true of the *panel*, and this paragraph originally stopped there and
said "one property flips" full stop — which review showed was a half-truth that
covered the enablement and not the routing. See *The routing reads the same flags
the enablement does* for the other half.

Both flags default to **false**, so a caller that forgets to wire one gets a
named-but-disabled action — visible — rather than an enabled one reaching
nobody, which is the defect.

**What breaks without each guard:**

- Deleting the `actionHosted` term from `actionEnabled` reddens
  `test_hosting_an_action_is_what_enables_it` and
  `test_an_unhosted_action_is_named_but_not_enabled_and_says_so`.
- Deleting the `!page.embedded.actionEnabled` early return in `RepoList`'s
  `onClicked` reddens `test_an_action_that_is_not_enabled_emits_no_request`.
  That guard is separate from `enabled: false` on purpose: `enabled` stops a
  pointer, not a programmatic emit, and the requirement is about the request.
- Routing every kind to `openSetup()` in the host reddens
  `test_a_start_request_does_not_raise_the_setup`. Verified by mutation. That
  test drives `takeEmbeddedAction` directly rather than through a control,
  because no control offers a start today — a click-driven test could not
  express the request, and the rule would hold only by accident of what is
  reachable.
- Deleting the `actionKind !== ""` term from `actionUnavailableNote` reddens
  `test_a_blocked_home_claims_no_unavailability`. Before that test existed it
  reddened **nothing** — every other test that reaches the note has an act
  named, so a blocked home would have claimed "starting the node is not yet
  available from here" when the obstacle is an unresolvable home and no act is
  offered at all. Found by review's mutation sweep, not by reading.

**One guard that turned out not to be one.** `actionEnabled` also carried an
`actionKind !== ""` term, and this file's comment claimed deleting it reddened
`test_a_blocked_home_offers_no_action_that_would_write`. Review measured it: the
deletion reddened nothing, and could not have. `actionHosted` switches on
`actionKind` and its `default:` branch already returns `false` for `""`, so the
term could not change the result for any input. It was removed and the
redundancy written down in its place, because the useful fact for a reader adding
an eighth state is *where* the guard actually lives — `actionHosted`'s `default:`
— not that a second copy of it once sat in the conjunction. Note the asymmetry
with `actionUnavailableNote` above, which reads `!actionHosted` and therefore
does need the term: the same expression is load-bearing in one place and dead in
the other.

**One consequence worth stating:** three scenarios in `embedded-state` changed
from asserting an enabled action to asserting a named one, and one —
`test_a_blocked_home_offers_no_action_that_would_write` — had to be
*restrengthened*. Its control leg cleared `pathsProblem` and asserted
`actionEnabled` on the resulting stopped node, which with start unhosted became
an assertion nothing could fail: a derivation returning `false` for every input
passed both halves. The leg now moves to the no-identity state, whose setup
action *is* hosted, so it discriminates again.

### The resume sets `stepIndex` once, and the test that proves it is not the obvious one

`landOnFirstUnfinishedStep()` assigns `stepIndex = resumeIndex` and emits
`stepMoved()`. It does **not** loop `advance()`, and it does **not** bump
`epoch`.

The reason is the staleness guard. Every call the flow issues captures `epoch`,
and every step change bumps it — so a landing that advanced step by step would
move the epoch past the preflight replies that *decided where it was going*. The
findings that chose the destination would be discarded on arrival: the identity
finding blank at a step reached because an identity exists, and creation offered
for an identity the backend just reported. It also cannot be expressed as an
advance at all, because `canAdvance` refuses to leave the embedded step until
capabilities report `embedded` — correct for a user's control, wrong for a move
the backend itself chose.

**The test that catches this is not the one a reader would expect, and that is
worth recording because I got it wrong first.** The obvious guard is
`test_the_resumed_steps_findings_are_populated`, which asserts exactly the
scenario above. It **cannot fail** against a looping landing: the harness is
synchronous, so all three gating replies have been written by the time the
landing runs, and bumping the epoch afterwards discards nothing. Verified by
mutation — under the loop that test stayed green, and exactly one test in the
file reddened: the one named below, not this one.

The reply that *is* still in flight at that moment is the **seed list**, because
`listKnownSeeds` is the one probe that does not gate `preflightDone`. So
`test_the_landing_does_not_discard_a_reply_still_in_flight` holds it across the
landing and delivers it afterwards. **Reverting to a loop reddens that test and
only that one** — confirmed in both directions.

This is the repo's own lesson in a new form: an assertion that cannot distinguish
the correct implementation from the broken one is decoration, however exactly it
restates the requirement. The scenario the spec names and the test that can fail
are two different things here, and both are kept.

`epoch` is deliberately *not* bumped by the landing for the same reason: no call
was issued under a step this move invalidates, and bumping would drop the
preflight's own replies.

**Why `restart()` rather than `reset()` + `runPreflight()`.** `reset()` means
"forget everything" and is what a flow wants when it is being discarded;
`restart()` means "ask the backend where we are", which is what a *showing*
wants. `resumeWanted` is held per-showing and cleared by the landing, so the
resume happens once rather than on every later reply — otherwise a node that
stopped serving while the user read the confirm step would throw them back to
start. `test_a_later_reply_does_not_move_a_step_the_user_walked_to` pins that.

### The wizard is begun by its host, not by its construction

`SetupWizard` had `Component.onCompleted: setupFlow.runPreflight()`. That is
correct for a component instantiated per showing and wrong for one hosted in an
overlay, because the overlay is not destroyed when it is lowered — `Main.qml`
keeps one instance and toggles `visible`. So construction fires for the first
showing only, and every later showing would sit on whatever step the previous
user left behind: precisely the remembered-index second opinion the requirement
forbids, arrived at by accident rather than by decision.

`show()` replaces it, called by `openSetup()`. **Reverting to
`Component.onCompleted` reddens `test_raising_the_setup_restarts_the_flow`**,
with the second showing stuck on `network` — verified by mutation.

The alternative — destroying and recreating the wizard per showing, with a
`Loader` — would also have worked and was rejected as more machinery for the same
outcome: it makes the flow's identity depend on the overlay's lifecycle, and
`SettingsPanel` beside it already establishes the keep-one-instance pattern.

### `settingsShown` moved from the flag to the pane

It was `readonly property bool settingsShown: settingsOpen` — a copy of the
condition the pane is keyed on. `setupShown` is the new observable beside it, and
both now read the pane's own `visible`.

The reason is the one `reposEmbeddedPanel` documents: a copy of a condition
agrees with the item whether or not the item draws, so an assertion on it cannot
see a surface that was raised and never rendered — which is a blank screen, and
which a screenshot cannot distinguish from a working one either. Moving
`settingsShown` was not strictly required by this change; it is a one-word fix to
an observable that was already weaker than it looked, made while the file was
open, and `local.yaml` already asserts on it.

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

### The identity step has two gates, and collapsing them is the defect

`canCreateIdentity` (`homeResolved && !identityExists`) gates the **creation
call**. `canAdvanceIdentity` (`identityExists || canCreateIdentity`) gates the
**forward control**. They are two properties because the spec's two blocks block
two different things, and that difference is what the user sees:

- an **unresolvable home** blocks the *step*: there is no identity and no way to
  make one, so the control is withheld and the reason is stated;
- an **occupied home** blocks only the *call*: the step's work is already done,
  so the control stays available and advances.

Written as one property, the occupied case strands a user on a step whose only
act is complete — which is what shipped. The user's screenshot shows the
consequence: a disabled-looking step, an amber sentence explaining a refusal, and
a "Next" button that was the only way out, sitting beside a "Create identity"
button that could do nothing.

Keeping `canCreateIdentity` as the creation gate was a constraint rather than a
preference. `test_the_resumed_steps_findings_are_populated` and
`test_a_resumed_step_behaves_as_one_reached_by_advancing` both pivot on it as an
observable — "creation is not offered for an identity that exists" is what makes
a resumed step's findings demonstrably populated. Repurposing the name for the
forward control would have made both tests assert the opposite of what they read
as asserting, which is worse than a failing test.

**Collapsing `canAdvanceIdentity` into `canCreateIdentity` reddens
`test_an_occupied_home_blocks_creation_without_blocking_the_step` and
`test_returning_to_a_step_that_acted_does_not_offer_to_act_again`** — verified
by mutation, both restored.

### One forward control, and the advance is inside the reply

`submitIdentityStep(alias, passphrase)` is what the button calls. It branches on
what the backend reported: with an identity it advances and issues nothing, with
none it creates and — on a reply reporting one created — advances in the same
act.

**The advance is inside `createIdentity`'s reply handler, not after the call.**
A reply is the only thing that can say creation succeeded; advancing after
issuing the call would leave a refused creation sitting on the network step, and
the spec is explicit that a refusal must not advance. It is guarded on
`reply.created === true` rather than on the callback having run, which is the
same "replies are the authority" rule the rest of this flow follows.

`submitIdentity` is kept as its own function under it. Creating the identity and
leaving the step are two jobs that happen to compose: one owns the call, its
arguments and its refusal; the other owns which act to perform. It is also the
entry point the passphrase-lifetime tests drive, because those are about what
reaches the backend rather than about navigation — folding them together would
have made those three tests navigate as a side effect of asserting on a
passphrase.

**The generic `Next` is hidden on the identity step**, not disabled. Two buttons
that both move forward is the photographed defect; a disabled `Next` beside an
enabled "Create identity and continue" would still read as two ways out, one of
them broken. **Making it unconditionally visible reddens
`test_the_identity_step_offers_exactly_one_forward_control`**, whose second half
asserts it is back on the following step — so the absence is keyed on the step
rather than being a deletion.

**Dropping the advance from the reply handler reddens three named tests**:
`test_one_forward_control_creates_and_advances_together`,
`test_returning_to_a_step_that_acted_does_not_offer_to_act_again` and
`test_a_refused_creation_stays_on_the_step_and_can_retry`.

### The three identity states are one derived string, not two booleans

`identityState` is `"none"` | `"created"` | `"present"`, derived from
`identityExists` and a `identityCreatedHere` flag that only a
`createEmbeddedIdentity` reply sets.

This is "complexity in the data structure, not the logic" applied to the hardest
requirement in the reopened spec: **created and already-there must not render the
same way, and created and refused must never be on screen together.** With one
value of three cases, rendering two of them at once is unrepresentable — each
statement's `visible` is an equality against the same string. With two booleans
the view has four combinations, two of them the exact screen the user
photographed: a green *"Created: did:key:z6Mkv…"* directly above an amber *"An
identity already exists in this home … Creating a second one is refused, never
an overwrite"*.

**`identityCreatedHere` is the one fact in this flow a backend reply cannot
supply.** `getEmbeddedIdentity()` reports that an identity exists and says
nothing about who made it — there is no field that could. "This showing made it"
is a fact about this showing, so it is held here and cleared by `reset()`, which
makes it per-showing by construction: a resumed flow that finds an identity
reports it as already there, never as one it made.

It is deliberately **not** folded into `identityExists` as a third value, even
though that would be one property instead of two. The two answer different
questions — "is there one" gates the creation call, "did we make it" decides
what is reported — and folding them would put a display concern inside a gate
that `canCreateIdentity` and the resume rule both read.

**Making `identityState` return `"created"` for any existing identity reddens
`test_the_identity_step_renders_its_three_states_apart`** on its
already-there leg, plus two preconditions in neighbouring tests.

### The already-there state is a success, and the refusal surface is reserved

`createBlockedReason` no longer carries the "an identity already exists …
creating a second one is refused" sentence. That sentence was *factually
correct* and it described an attempt nobody made: a user who already holds an
identity has succeeded at this step, and telling them creation is refused
explains a failure that did not happen.

Where the step now says why it offers no creation, it says it as a note in the
ordinary text colour — "Nothing to create — this step is done" — and never on
`wizardError`, which stays reserved for a refusal the backend returned to *this*
showing. That reservation is the reason a user can trust the error box at all.

**Restoring the sentence to `createBlockedReason` reddens
`test_an_identity_already_there_renders_no_refusal` and
`test_created_and_refused_are_never_on_screen_together`** — the two halves of
the photographed screen, each with its own test.

### The step names the home, in all three states

A DID names the identity and says nothing about where it lives. The embedded
home is derived from the Basecamp profile's data directory — a path the user did
not choose and cannot guess — so a step reporting only a DID leaves them unable
to find, back up or inspect what was created, or to tell it from their own
`~/.radicle`. The user's question on seeing the shipped screen was exactly that:
*"what HOME? where is the embedded identity created?"*.

`identityHome` renders `getEmbeddedIdentity().home`, unconditionally across the
three states, because "which home is this" is the same question before and after
creation. Where `home` is empty there is no path to print, so the step *states*
that none could be resolved and shows the backend's own sentence with it — the
same verbatim rule the rest of the flow follows, and the one that names the
limit that was exceeded.

**Blanking the path from the rendered text reddens
`test_the_reported_home_is_the_path_displayed` and
`test_the_home_is_stated_in_all_three_states`.** The first is the one that
matters: it asserts a *second* distinctive path replaces the first, so a
hardcoded path cannot pass it.

### The passphrase choice belongs to the no-identity state alone

The alias field, the encrypt switch, the trade statement and the passphrase field
are all visible only where `identityState === "none"`. An existing key was
sealed, or not, when it was created, and this flow cannot re-key it — so offering
the control would be a control that records nothing, and stating the trade would
describe a decision that is not the user's to take. The photographed screen had a
*filled* passphrase field with the switch off, beside an identity that already
existed: three statements that could not all be acted on.

What does **not** change is the rule inside that state: both halves of the trade,
stated at the control, before it is touched, and still stated when the switch is
turned off. That requirement was never about which state it applies in, and
scoping it did not weaken it —
`test_both_halves_of_the_trade_are_stated_before_the_choice` and
`test_the_trade_stays_stated_when_the_passphrase_is_turned_off` are unchanged and
still green.

`test_a_passphrase_is_the_arriving_default` was pinned to `identityState ===
"none"` explicitly rather than left relying on the fixture's default. It passed
either way, which is the problem: a test that does not say which state it is
asserting about would silently start asserting about a control that is correctly
absent. **Making the switch unconditionally visible reddens
`test_an_existing_identity_offers_no_passphrase_choice`**, whose second half —
the control present where the choice does exist — is what stops a step that
never renders it from passing.

### The alias is not pre-validated in the view

`createEmbeddedIdentity` passes the `radicle` crate's own statement of the alias
rule back as its refusal. A second rule in the view would be a copy free to
drift from the crate's, and the drift would present as the wizard rejecting an
alias the backend would have accepted — with no way for the user to tell which
layer refused.

So the alias goes to the backend as typed, and the refusal is displayed
verbatim. Same reasoning as `SettingsPanel`'s git path, which is validated on
write for the same reason.

### `encrypted` is a probed field on the identity reply, not a bare boolean

The autostart rule needs one fact no reply carried: whether an existing
identity's signing key is sealed. Three candidates were weighed.

**`createEmbeddedIdentity`'s `encrypted`** — rejected twice over. It is computed
from the passphrase argument rather than observed from the key that landed, so it
says what was asked for; and it rides a reply that, by definition, no later
session holds. It is the field a reader naturally finds first, which is why
`radicle_impl.h` now carries a cross-reference rather than leaving the next
person to re-derive that it exists on the wrong reply.

**`getCapabilities().canWriteLocal`** — rejected, and the header used to
recommend it for exactly this question. It probes the home of the **mode in
force**, so it says nothing about the embedded home from any other mode; and it
conflates an encrypted key with a missing one, an unreadable one and an
ssh-agent that is simply not running. A caller cannot recover "encrypted" from it
without matching on prose. `getEmbeddedIdentity()` always reads the embedded home
whatever mode is in force and answers this one question, which is what makes it
the right reply to carry the field.

**A fourth option that was never real: attempt a start and read the failure.**
That is a destructive probe rather than a question — it leaves a node running, or
a refusal in the log, to learn something the key already states.

**The probe itself already existed.** `Keystore::is_encrypted()` is what
`cobwrite::signer` has always used to choose between loading a key and reaching
for an agent. So what is new is exposing it, not obtaining it — which is why a
change described as "a core change" is one function and two JSON keys.

**It returns `{"encrypted":bool,"problem":""}`, not a `bool`**, because there are
three answers and not two: sealed, not sealed, and *could not tell*. Collapsing
the third is the dangerous direction — `false` is indistinguishable from a
plaintext key, and a caller reading it starts the node with an empty passphrase
against a key it cannot read. **Flattening the `Err` to `false` reddens
`an_unreadable_key_reports_a_problem_rather_than_unencrypted` and
`a_home_with_no_key_reports_a_problem_rather_than_unencrypted`**; verified by
mutation.

One consequence worth recording because it breaks a stated invariant:
`is_encrypted()` opens the **secret** key file, where every other read on this
path touches only `keys/radicle.pub`. It parses the envelope rather than
unlocking it — no passphrase, no agent, nothing written back, and
`reporting_encryption_leaves_the_key_untouched` compares the file's bytes before
and after. But a home holding `radicle.pub` without its secret half reaches an
`Err` here rather than a `false`, which is the `problem` case above and the
second reason the error is not flattened.

### The node starts itself, overturning a decision made before it was dogfooded

`user-flow.md` §6 recorded the opposite rule — **the node does not start
automatically, in any configuration** — and the reasoning is migrated here
because it is what this decision overturned.

The original argument was that `Runtime::init` takes an already-decrypted key, so
an encrypted profile *cannot* start unattended — still true — and that an
**unencrypted** one should not either, on three grounds:

1. it makes the passphrase choice silently change startup behaviour along an axis
   never stated at the control;
2. an autostart failing at module init has nowhere to report — the view is not
   up, and Basecamp swallows QML errors;
3. it splits the stopped state into two indistinguishable states.

**Each fell, and for a different reason.** (1) is answered by *stating* it: the
identity step now says an unencrypted key lets the node start without a prompt
and an encrypted one is asked for each time. That is the axis, named at the
control where the choice is made, which is what the objection asked for. (2)
describes an autostart at *module init*, and this is not one — the start is
issued from the Embedded surface once it is rendering, so it has exactly the
place to report that the starting and start-failed states already are. (3) is
answered by the new field: `encrypted` is what distinguishes the two stopped
states, and its absence was what made them indistinguishable in the first place.

**What the argument never weighed is the cost of the rule**, which dogfooding
made plain: a user who has set a node up is told, every time they open the mode,
to press a button the module could have pressed itself, with one possible answer.

Two things the overturn does **not** license, both still rejected:

- **A "start automatically" setting** — a module setting whose only legal value
  for the secure default is off, and whose question is now answered by whether
  the key is encrypted.
- **Prompting at Basecamp startup** — an unasked-for modal on launch, in a module
  the user may not be looking at. The passphrase prompt is a field on the
  Embedded surface, shown when the user is looking at Embedded.

### The decision to start is a derived property; the issuing is the view's

`EmbeddedState.wantsAutoStart` is a pure function of the state and the key;
`RepoList` watches it and issues the call. The split buys two things a single
imperative would not.

**"Started by itself" becomes a question about values**, answerable with no
backend anywhere — which is what `tst_embedded_state.qml` asks, walking all seven
states with `encrypted:false` held so that an over-eager derivation says yes
everywhere and fails.

**"Issued once per arrival" becomes an edge rather than a counter.** Issuing the
start makes `wantsAutoStart` false immediately — `startPending` moves the state
to `starting` — so the handler cannot fire twice for one arrival however many
times the backend reports the same status, and fires again only after the state
has genuinely left `stopped` and returned. Nothing maintains a "have I started
yet" flag, so nothing can get it wrong.

**The `Component.onCompleted` beside the `Connections` is not belt and braces,
and this is the entry worth reading before deleting it.** A change signal fires
on a *change*; a `RepoList` built against a backend already reporting a stopped
unencrypted node never sees one, because `wantsAutoStart` is true from its first
evaluation. That is the module starting up with Embedded already in force — the
ordinary case for anyone who has used the mode before.

**Deleting it reddened nothing**, and that is measured rather than feared. Every
test in `tst_embedded_panel.qml` built its `RepoList` once and reached each state
by mutating the harness, which is a live change by construction. The fix is the
same one `design.md` already records for the setup host: a `Component` that
builds a *second* list against a harness already in the state.
`test_a_list_built_already_stopped_starts_its_node` is that test, and it is the
only thing in any layer that can see this path.

One trap it cost, worth not re-learning: `destroy()` is deferred to the next
event-loop turn, so a fresh list left merely scheduled goes on watching the
harness and the *next* test's single expected start arrives twice. Three
unrelated tests reported two calls before `wait(0)` was added. A second one:
`app: app` inside the `Component` resolves to the `RepoList`'s own `app`
property rather than the outer id — QML puts the item's properties in front of
the file's ids — so the fresh list came up with a null host and derived
`blocked`. Both were caught by preconditions rather than by reading.

### The passphrase is a field on the surface, and it is cleared by the call

An encrypted key gets one field and one control on the Embedded surface, not a
step of the guided setup. A passphrase is one answer to one question asked at one
moment; routing it through a multi-step flow would make the user walk steps whose
work is already done to reach the only one that is not.

**The prompt is derived from `encrypted`, never from a start having failed.** A
prompt keyed on an error would be a consequence of something going wrong rather
than of the identity being what it is — so it would not appear on the first
opening, where it is needed, and would appear after an unrelated refusal on an
unencrypted key, where there is nothing to ask for.
`test_the_passphrase_prompt_does_not_follow_a_failed_start` holds `encrypted`
fixed in each leg and moves the refusal.

**It is cleared as the call is issued, not when the call is answered.** The call
already holds the value it needs, so clearing at issue makes the secret's
lifetime exactly the call rather than the call plus however long the backend
takes. A refusal therefore empties the field, which is correct: the passphrase
that was refused is not the one to retry with, and the field stays on screen
through `startFailed` so a corrected one can be typed. Keeping the refused value
would offer a user a filled field whose contents are known wrong.

**This is the opposite of the wizard's rule, deliberately.** There the clearing
is keyed on the *reply*, because a refused creation must leave the passphrase in
place — the alias was wrong, not the secret, and the retry is the same secret.
Here a refused start means the secret itself was wrong. Two surfaces, two
lifetimes, and the tests are the pair that pins each:
`test_a_refused_creation_keeps_the_passphrase_for_the_retry` and
`test_a_refused_passphrase_can_be_corrected`.

**The start does not travel through `embeddedActionTaken(kind)`.** That signal
carries a kind and nothing else; widening it to carry a plaintext secret, or
making the host hold one it has no other use for, are both worse than
`RepoList` calling `app.startEmbeddedNode(passphrase)` directly. The hosting flag
still governs the panel's enablement, and `routesEmbeddedAction` still answers
for any caller that does route a kind — so the table stays honest without the
secret crossing it.

### A node this module started is not a node in the way

`getNodeStatus()` reports the same two fields for a node this module started and
one it found, so the surface holds the one fact the reply cannot carry: whether a
`startNode` it issued was answered with a success.

This is the defect the user photographed. Step 5 rendered an amber "a node is
already answering on the resolved socket. Starting a second one would contend for
it" directly above its own green "Running as did:key:…" and "The control socket
is answering." Both sentences were derived from true readings, and together they
described a conflict that did not exist, because the node warned about was the
one the wizard had just started.

**A correct fact rendered as a hazard when it describes the user's own success is
worse than no fact**, because it sends them looking for a second node that is not
there. So `foundForeignNode` is `serving && !startSucceeded`, and **dropping the
second term reddens three named tests across two layers**, the third reporting
the contention sentence rendered over the surface's own success — which is the
screenshot, reproduced by a test. Verified by mutation.

`startSucceeded` latches and is never cleared. It answers "did this module put a
node on that socket", and the node stopping afterwards does not make the answer
no — while clearing it would make the surface warn about contention with a node
it started itself, which is the whole defect.

**The two requirements it sits between are both live, and collapsing them was the
first thing tried.** The running-and-empty state must say this node lists what it
is seeding — so an empty list reads as a node with nothing seeded rather than one
that has lost something — *and* a foreign node must be reported. Written as
alternatives, the seeding sentence vanished for a foreign node, which is the
state where "what is listed is not this module's storage" matters most. The
existing `test_a_serving_node_that_holds_nothing_may_say_so` caught it; the
sentences are appended rather than chosen.

### The header's identity is one rule, and the list version is what shipped

`SourceState.modeHasIdentity` is `current === "local"` — a mode has an identity
exactly when it reads a Radicle home of its own, which is what routing to the
`local*` methods means. Explore is the fall-through rather than a named
exception: it resolves no home and proxies to a seed, so there is nobody to be.

**It was `mode === "local"`, and that list is what cost Embedded its DID.** The
slot showed nothing in the mode where a user is *most* likely to believe they are
operating as their existing DID — its identity is one the module created rather
than one they made — while `radicle_impl.h` required a view to always show `mode`
and `nodeId`. A list has to be noticed and extended by somebody; the rule is
right for a fourth mode before anyone writes one.

**Rewriting it back to `mode === "local"` reddens three named tests**, one
reporting `embedded:no` where it must report `embedded:yes`. Verified by
mutation.

**`NodeIdentity.qml` is untouched, and that is the point.** It already renders a
full, copyable, clipboard-verified DID and already sits in the header's
mode-detail slot. This is one condition, not a component — which is why the
`embedded-header` capability's requirements are met by a change of a single
binding plus the derivation it reads.

The test fixture changed with it: `tst_source.qml`'s slot now instantiates the
real `SourceState` and reads `modeHasIdentity`, where it previously reproduced
`slotMode === "local"` inline. A reproduced comparison would have let the same
list-shaped rule come back with that file still green.

### The last step finishes, and there is no terminal screen

The network step's forward control ends the setup, and it is the *same* control
rather than a second one beside it: the forward control is where a user's hand
already is, and a separate Finish would be two ways out of one step. It issues no
call — the steps made every write this flow makes.

`onLastStep` is derived from the index rather than from naming `network`, so the
last step is whatever `steps` ends with. That is not fussiness: this list has just
lost two entries, and a rule naming the step would have gone on naming `confirm`,
leaving the flow with no way out at all.

The deleted confirm step is worth one line of epitaph, because "delete a screen"
reads as a simplification and this was a correction: **its only act was to be
dismissed.** A step that states what already happened and offers one control that
closes it asks the user for an act that changes nothing — and each fact it
carried is better placed where it is wanted. The DID is in the header, reachable
at any later moment. Its allow-is-not-enough sentence went *up* to the embedded
step, where it is now the only place the flow states the separateness, and where
it is made before the decision it informs rather than after it.

### What the wizard stopped holding, and why absence is the requirement

`SetupFlow` no longer has a `startNode` property, a `canStartNode`, a
`startBlockedReason`, a `nodeStarted`, a `listening`, a `nodeServing`, a
`startPending`, a `nodeId` or an `allowCommand`. Each could have been left in
place and simply unread.

They were removed because **"this setup MUST NOT issue `startNode`, in any step,
for any reason" is then a property of the object rather than of what the screen
happens to draw.** There is nothing to call. A future edit that wanted to start a
node from a step would have to reintroduce the property first, which is a visible
act in a diff; an unread property left lying there is an invitation nobody
reviews. The fakes in both test files dropped their `start` functions for the
same reason — a fake offering one would let that edit land and stay green.

`alreadyServing` survives and is still populated, because it is still a *finding*:
the preflight reports that something else is using the socket this node would
want. It now blocks nothing, which is a consequence of the flow starting nothing,
and `test_a_node_already_serving_blocks_no_step` is what says so.

`resumeIndex` stopped reading it for the same reason. A resume that landed
differently for a running node than for a stopped one would be reporting the
node's state through the step it chose, which is `embedded-state`'s job and not a
step's. `test_the_node_state_does_not_change_where_a_reopened_flow_lands` moves
only the node status between its two legs.

## Risks / Trade-offs

- **Four steps is still a lot of screen for a one-time task.** Accepted because
  each step exists to state a consequence at the moment a decision is made, which
  is the whole reason the wizard is preferred to a single form. It was six, and
  the two that went were the two that stated nothing a user had to decide.
- **The node starts without being asked, which is a behaviour change a user
  cannot decline in the moment.** They decline it at the identity step by setting
  a passphrase, which is the only place the choice exists and is now stated as
  such — but a user who chose an unencrypted key months ago and has forgotten
  will see a node start when they open the mode. Accepted: the alternative is a
  control with one possible answer, pressed every time, for the life of the mode.
  The start is reported through the same states as one they asked for, so it is
  visible rather than silent.
- **`embeddedStartSucceeded` latches for the life of the module.** A node this
  surface started, which then stopped and was replaced by somebody else's, reads
  as "ours" until the module restarts. The alternative — clearing it on a stop —
  makes the surface warn about contention with a node it started itself the
  moment a poll lands between a start and its status refresh, which is the defect
  this field exists to prevent. The failure this accepts is a missing warning in
  a case that needs two node lifetimes to reach; the one it avoids shipped.
- **The Embedded state is read on mode-settle and on backend-ready, not
  polled.** `getNodeStatus` probes a control socket, and the panel is a state a
  user acts on rather than a live monitor — so a node that dies while the panel
  is on screen goes on reading as `runningEmpty` until something asks again.
  Polling belongs with node control in Settings › Node, which is where a user
  who cares about liveness is. The cost is that E6 is reached on the next
  refresh rather than immediately, which the `notServing` sentence handles
  honestly once it does arrive.
- **`Main.qml`'s own wiring has no component test.** No test instantiates
  `Main.qml` — `tst_embedded_wiring.qml` and now `tst_setup_host.qml` reproduce
  its shape with the real components — so `refreshEmbedded()`, the
  `embeddedSettled` `Connections`, the new `app` properties and the host's
  `openSetup`/`takeEmbeddedAction`/`toggleSettings` are covered at the component
  layer only as a *reproduction*. A divergence between those fixtures and
  `Main.qml` is invisible to both. `local.yaml` is what closes it — it drives
  the real file through the real clicks — and the four steps added there are the
  only thing in any layer that can see the real button reaching the real host.
  Neither layer is sufficient alone: the component file can ask questions a spec
  cannot (a start request that no control offers), and the spec can see the
  wiring the component file reproduces. The component suite being green still
  says nothing about `Main.qml` itself.
- **Nothing exercises the wizard against the real backend.** `local.yaml` raises
  the setup and lowers it again without walking a step, deliberately: the steps
  after preflight write — an identity, a mode, a node — and a spec that ran them
  would leave a provisioned embedded home behind on every CI run and on any
  developer machine it was run against. What is asserted is the hosting, which
  is what this piece adds. The flow's own behaviour stays at the component
  layer, where the calls are injected and nothing is written.

## Open questions

Choices were made that the spec does not require. Each is marked `NO SPEC:` in
the code and each has a test, so they are visible to review rather than becoming
permanent by accident.

- ~~**Where the flow is entered from**, and what closing it does. This change
  wires no entry point into `Main.qml`; the close control emits `closed()`
  rather than deciding, so the host's choice stays open. The surrounding surface
  is the configuration panel change's. Marked on `SetupWizard.qml`'s
  `closed()`.~~ **Answered, and it is no longer a choice this change declines to
  make.** `embedded-setup` gained four requirements naming it: the setup is
  raised over the view rather than navigated to, it is mutually exclusive with
  the settings surface, it opens only for an act that names opening it, and a
  reopened flow re-derives its step. `Main.qml` hosts it — see *Hosting the setup
  extended `embedded-setup`* and the two entries after it. The `NO SPEC:` marker
  on `closed()` is gone with the question.
- **What a preflight finding shows before its probe has answered.** The spec
  requires four findings each reported as its own outcome, but says nothing
  about the window before a reply lands. Every finding has a legitimate falsy
  value, so rendering the defaults would report four failures — a missing git,
  an unresolvable home — before a single call was issued, and a user would act
  on a diagnosis of nothing. This flow names the unanswered state instead.
  Marked on `SetupFlow.qml`'s `preflightDone`, tested by
  `test_an_unanswered_finding_is_not_reported_as_a_failure`.
- **Where the unavailability note renders, and that it is silent mid-start.** The
  spec requires only that unavailability be *stated*; it says nothing about
  placement or about the window while a start is outstanding. Two choices were
  made: the note renders **below the button** rather than beside it, so the
  explanation reads as belonging to the disabled control rather than to the state
  sentence above it; and it is **silent while a start is pending**, because the
  action is then withheld for a reply the `starting` sentence already reports,
  and "not available" over that would be false — it is not unavailable, it is in
  progress. Marked on `EmbeddedState.qml`'s `actionUnavailableNote`, tested by
  `test_no_unavailability_is_claimed_while_a_start_is_outstanding` for the
  silence. Review found this one unmarked while two structurally identical
  choices beside it were marked, which is the asymmetry that makes a deliberate
  choice read as an incidental one.

A third question the spec settles but the flow surfaces: **advancing past the
embedded step requires `getCapabilities().mode === "embedded"`, so a flow whose
capabilities have not yet answered does not advance.** That is the requirement
read literally — an unanswered backend has not reported `embedded` — and it is
pinned by `test_an_unanswered_mode_does_not_advance` rather than left implicit,
because the tempting "fix" is to treat an empty mode as permission to continue,
which would run the four node steps against a module in explore.
