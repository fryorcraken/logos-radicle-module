# User flow: configuring and running the embedded Radicle node

> Written by a design pass after the wizard shipped unreachable. Not yet a
> spec — this is the flow the spec should be rewritten against.

## 0. The diagnosis

The screen a user sees on picking Embedded — an empty repository list, a red
`no embedded identity yet` banner, "No repositories matched" — is **not a
missing wizard**. It is the placeholder-removal side of making Embedded
startable, with nothing put in its place.

`radicle/src/settings_store.cpp:152` returns `{explore, local, embedded}`, so
`SourceState.modeStartable` is true in Embedded, so `RepoList.notImplemented`
is false, so `notImplementedState` (the honest "not available in this version
yet" panel at `RepoList.qml:340-372`) **no longer renders**. `RepoList.fetch()`
therefore issues `localListRepos`, the embedded home has no identity, and
`radicle_impl.cpp:175-179` returns `absentProfileReason`, which `Main.qml`'s
`call()` routes through `nav.fail()` into the red `StatusStrip`.

So the old dead-end was deleted by a core-module change and its replacement was
never wired. That is the regression, and it is what the entry point must fix.

Two further facts, both verified:

- **Nothing calls `startNode` at construction.** There is no autostart at any
  layer today.
- **PR #47 has already added** `getNodeConfig`, `setNodeConfig`, `listSeeded`,
  `seedRepo`, `unseedRepo` to `radicle_ui.rep`, with a `restartRequired` field.
  The configuration panel is a QML-only change once that merges.

## 1. The state model

Seven user-visible states in Embedded. State is **derived, never stored**, from
`getCapabilities()`, `getEmbeddedIdentity()` and `getNodeStatus()`.

```
                       mode = embedded
                              │
                    ┌─────────┴──────────┐
                    │  E0  BLOCKED       │   pathsProblem ≠ "" or home = ""
                    │  no home to write  │   (terminal until Settings fixes it)
                    └─────────┬──────────┘
                              │ home resolves
                              ▼
          ┌──────────────────────────────────────┐
          │  E1  NO IDENTITY                     │  exists:false
          └───────────────┬──────────────────────┘
                          │ createEmbeddedIdentity → created:true
                          ▼
          ┌──────────────────────────────────────┐
     ┌───▶│  E2  IDENTITY, NODE STOPPED          │  exists:true
     │    │                                      │  running:false serving:false
     │    └───────────────┬──────────────────────┘
     │                    │ startNode(passphrase)
     │                    ▼
     │    ┌──────────────────────────────────────┐
     │    │  E3  STARTING                        │  call outstanding
     │    └────────┬───────────────────┬─────────┘
     │             │ started:true      │ {"error":…}
     │             ▼                   ▼
     │    ┌──────────────────┐  ┌──────────────────────────┐
     │    │ E4  RUNNING      │  │ E5  START FAILED         │
     │    │ running+serving  │  │ + the backend's sentence │
     │    └────────┬─────────┘  └───────┬──────────────────┘
     │  stopNode   │                    │ retry
     └─────────────┤                    └──────────┐
                   │ threads die                   │
                   ▼                               │
          ┌──────────────────────────────┐         │
          │  E6  DIED                    │◀────────┘
          │  running:true serving:false  │
          └──────────────────────────────┘
                   │ stopNode then startNode
                   └────────────▶ E3
```

**E6 is why a flow reading only `running` is wrong.** The Rust panic guard
reaches the FFI boundary, not the threads a running node spawns
(`radicle_impl.h:390-403`), so `Runtime::run` panicking leaves `running:true`
forever while the `local*` read path keeps answering — reads never touch the
daemon. A user in E6 sees repositories, sees "running", and fetches silently
never arrive. It must read as neither running nor stopped: *"The node is not
answering its control socket. It is still loaded but has stopped serving."*

**E3 and E6 share their fields.** A `getNodeStatus` poll during startup can
report `running:true, serving:false`, indistinguishable from E6. The
disambiguator is whether a start is outstanding, which only the view knows:
`startPending` → "Starting…", otherwise E6.

**Leaving Embedded** from any state: the surfaces disappear, the node keeps
running. That must be *said*, or a node left running while the user browses in
Local is invisible.

**A half-created home** reports `exists:false` exactly as an empty one does and
nothing in the reply distinguishes them (`radicle_impl.h:258-262`). So E1 is
one state, creation is offered, and the backend's refusal — the only surface
naming the `keys` path to remove — is what the user sees.

## 2. The surfaces

| Surface | Serves | Lives in |
|---|---|---|
| **A. Embedded empty state** | E0, E1, E2, E5, E6 | `RepoList.qml`, replacing `notImplementedState` |
| **B. Setup wizard** | the E1 → E2 → E4 walk, once | a modal over the view, hosted by `Main.qml` |
| **C. Settings › Node** | E2–E6 durably | a section in `SettingsPanel.qml` |
| **D. The header** | every state, at a glance | `SourceToggle` caption + mode-detail slot |

### Why B is an overlay, not a page or a Settings section

The module is navigated by one `StackLayout` with two pages driven by
`NavState`, plus one opaque overlay (`settingsOpen`). There is no router.

- **A page** would need a third `nav.view` value and a back-stack entry, and
  `nav.back()` would have to decide between step 5 and the repository list.
  `NavState` knows nothing about steps.
- **A Settings section** is wrong for first run: Settings is a flat form where
  every control is independently editable, and the wizard's whole value is that
  three consequences are stated **in order, at the moment each decision is
  made**. A user landing mid-form has not been told this is a new identity.
- **An overlay** reuses the existing pattern exactly — `Main.qml` owns
  `setupOpen`, the wizard emits `closed()`, the host lowers it. No new
  navigation concept, and `SetupWizard.closed()` finally gets a host.

### What splits between B and C

They are one subject at two tempos: one-time and consequential versus durable
and revisable.

| | Wizard (B) | Node panel (C) |
|---|---|---|
| alias | set once, baked into the identity | editable |
| passphrase | chosen once, irreversible here | not changeable |
| inbound | stated as off, no control | the opt-in, with a port |
| seeds | shown, prefilled | editable, per-RID |
| node | started once, to prove it works | start / stop / restart |
| DID + allow line | shown at confirm | permanent, copyable |
| diagnostics | none | status, `reason`, log tail |

**Setup is a first-run path into C, not a parallel universe.** Confirm ends
with *"You can change any of this in Settings › Node"* and a control that opens
it. That is what stops two vocabularies for one thing — a mistake
`SourceToggle.qml:14-22` records this repo already paying for once.

## 3. The entry points

1. **The Embedded empty state's primary action (A → B).** In E1 the list is
   replaced by one centred panel whose obvious next action is **"Set up the
   embedded node"**. This is the missing entry point.
2. **The header caption (D).** `SourceToggle.note`'s Embedded branch stops
   saying "not available in this version yet" — now false and on screen today —
   and becomes a state sentence pointing at Settings › Node. Text, not a
   control: the module has already been burned by two controls for one question.
3. **Settings › Node (C → B).** In E1 the panel is an explanation and the same
   button. This is what a user finds when they go looking.
4. **Nothing else. Selecting Embedded does not open the wizard.** Choosing a
   mode and configuring a node are different acts; auto-opening a modal on a
   segment click is the defect class already rejected in `design.md` under
   *Why the write is an explicit act*.

### Re-entry

- **Bad passphrase** → E5. The wizard stays on the start step, shows the
  sentence verbatim, keeps the control enabled. The passphrase field is **not**
  cleared — clearing is keyed on `nodeStarted` precisely so a retry still has it.
- **Closed part way** is always safe: every write is separately durable, so
  there is no half-committed state. On reopening the wizard **does not resume at
  the step it was closed on** — it re-runs the preflight and lands at the first
  step with work left, because durable state is the authority and a remembered
  index is a second opinion that can be wrong.
- **Module restarted between attempts** works for free, for the same reason.

This is the largest behavioural change to `SetupFlow`: `reset()` always lands on
step 0 today and there is no resume rule.

## 4. What each surface says

### A. The Embedded empty state

One centred panel replacing `notImplementedState`. Never a spinner, never "No
repositories matched" — that string claims a node exists and holds nothing.

| State | Says | Asks |
|---|---|---|
| E0 | the `pathsProblem` sentence verbatim | "Open Settings" |
| E1 | "Basecamp can run a Radicle node of its own. It will have **its own identity**, separate from any node you already run." | **"Set up the embedded node"** |
| E2 | "Set up but not running. Repositories are not being fetched." | "Start the node", "Settings › Node" |
| E3 | "Starting the node…" | nothing |
| E5 | the `startNode` error verbatim | "Try again", "Settings › Node" |
| E6 | "The node has stopped answering. Still loaded but no longer serving." | "Restart the node" |
| E4, empty | "No repositories yet. This node fetches what it is seeding." | "Settings › Node" |

**`RepoList.fetch()` must stop issuing `localListRepos` in E1/E2** — that call
is what produces the red banner, and there is nothing to ask. The guard is
currently keyed on `notImplemented`, now permanently false; it becomes a guard
on whether this mode has a node to ask.

### B. The wizard — six steps, almost intact

1. **Preflight** — unchanged. Reports, asks nothing.
2. **Embedded** — unchanged in substance. **One change:** arriving via the empty
   state means `mode` is already `embedded`, so this is a statement with a Next.
   That is already specified behaviour; it now describes the *common* path.
3. **Identity** — unchanged. Alias, passphrase, both halves of the trade.
4. **Network** — **one change:** "not available in this flow" becomes "not
   available here — you can turn it on in Settings › Node after setup", true
   once #47 lands. Today's wording implies the capability does not exist.
5. **Start** — unchanged.
6. **Confirm** — **three additions:** the restart consequence (§6), the
   allow-is-not-enough sentence, and a control into Settings › Node.

The allow-is-not-enough rule belongs at confirm because that is where the user
is about to go and try to clone something: a delegate allow-listing this DID is
**not** sufficient — every other node must also seed the RID with scope `all`.

### C. Settings › Node

A section in `SettingsPanel.qml`, visible only when `mode === "embedded"`.

- **Status**, always at the top: state name, `nodeId`, home, `reason` when there
  is one. Start / Stop / **Restart** — the only fix for stale gossiped addresses
  making a node dial a NAT address forever.
- **Passphrase prompt on start**, because the node is handed an
  already-decrypted key.
- **Identity**: alias editable, DID read-only and copyable, the allow line and
  its caveat.
- **Network**: inbound opt-in with port, defaulting off, saying what off means.
- **Seeding**: seeded RIDs with scope.
- **Diagnostics**: `reason`, plus a log tail when one exists.
- **`restartRequired`** renders as a banner with a Restart control beside it,
  mirroring the git-path note at `SettingsPanel.qml:379-387`.

### D. The header

- `SourceToggle.note`'s Embedded branch becomes a state sentence. **Note
  `captionSizer` measures the current string** for the bar's height reservation.
- The **mode-detail slot** shows the embedded DID through the existing
  `NodeIdentity` in E2–E6, closing `radicle_impl.h:153-158`'s "a view MUST
  always show `mode` and `nodeId`", which Embedded violates today.

## 5. The three non-negotiable statements

Each placed where the decision it affects is made. The repetition is the point.

| Statement | Where |
|---|---|
| **This is a new identity, not yours** | empty state (E1) · wizard step 2 · wizard step 6 with the DID · `ModePicker`'s blurb |
| **A passphrase means unlocking at every start** | wizard step 3 at the control · step 6 and the panel, where the *daily* consequence bites |
| **`listen: []` means peers cannot fetch from you** | step 4 as the setting in force · step 5 as empty `listening` · the panel, where it becomes changeable |

## 6. Restart of Basecamp

**The node does not start automatically, in any configuration.** On restart from
E4 the user is in E2.

`Runtime::init` takes an already-decrypted key, so an encrypted profile *cannot*
start unattended. Whether an **unencrypted** one should is the real choice, and
the answer is no:

1. It makes the passphrase choice silently change startup behaviour along an
   axis never stated at the control.
2. An autostart failing at module init has nowhere to report — the view is not
   up, and Basecamp swallows QML errors.
3. It splits E2 into two indistinguishable states.

**So: the node starts when a user asks it to, always.** In exchange E2 must be
loud and one click from fixed.

**Stated at confirm**, worded by the passphrase choice:

- encrypted: *"It will not start on its own when Basecamp restarts — an
  encrypted key has to be unlocked, so you will start it from Settings › Node."*
- unencrypted: *"It will not start on its own when Basecamp restarts; start it
  from Settings › Node."*

**Rejected: a "start automatically" setting** — a sixth module setting whose
only legal value for the secure default is off. Revisit when a passphrase store
exists. **Rejected: prompting at Basecamp startup** — an unasked-for modal on
launch, in a module the user may not be looking at.

## 7. Components

**Survives unchanged:** `SetupFlow.qml` (gains only a resume rule),
`CopyableCommand.qml` (the panel is its second consumer), `ModePicker.qml`,
`NodeIdentity.qml`, `SourceState.qml`, `NavState.qml`.

**Changes:**

- **`SetupFlow.qml`** — a `resumeFrom()` advancing `stepIndex` past every step
  the backend reports done. Derived from replies, never remembered. Set
  `stepIndex` once rather than looping `advance()`, or the epoch races the
  preflight replies that determined it.
- **`SetupWizard.qml`** — `closed()` gets a host (its `NO SPEC:` marker goes);
  step 4's pointer; step 6's three additions.
- **`Main.qml`** — the host: `setupOpen`, a `setupPane` overlay sibling to
  `settingsPane`, mutual exclusion, the mode-detail slot, and the stale comment
  at `Main.qml:656-658`.
- **`RepoList.qml`** — the largest change. `notImplementedState` becomes a
  state-driven `embeddedState`; `fetch()`'s bail-out re-keyed; **`sayingNothing`
  reads `notImplementedState.visible` by name** and goes blind if not updated.
- **`SourceToggle.qml`** — the Embedded caption, and its `captionSizer`.
- **`SettingsPanel.qml`** — the Node section.

**Deleted:** `RepoList.qml`'s `notImplementedState` block (dead, and its copy is
now false); `SetupWizard.qml`'s `NO SPEC:` marker on `closed()`.

**No component is discarded. The wizard was built right and hung on nothing.**

## 8. What the module cannot currently do

**Blocking:**

1. **A restart that reports what happened.** `stopNode` + `startNode` compose
   but nothing reports the pair. Prefer sequencing in QML — no transport change,
   and the two refusals are different sentences the user should see separately.
2. **Nothing distinguishes "started by this session" from "a node is answering
   the socket".** The panel's Start must handle `startNode` refusing because the
   socket is in use; today that surfaces only as an error string.

**Depends on #47 merging** (already built there): `getNodeConfig` /
`setNodeConfig`, `listSeeded` / `seedRepo` / `unseedRepo`, and `node.rs`
honouring `listen` rather than overriding it with `vec![]` — without which the
inbound opt-in is a control that records nothing.

**Not available; the flow must not pretend otherwise:**

- **No passphrase change** — out of #47's scope, because it rewrites key
  material. Say so rather than showing a disabled field.
- **No node log.** Ship `getNodeStatus().reason` only; a log section rendering
  nothing is worse than none.
- **No per-profile socket scoping.** Two Basecamp profiles now *bind* the same
  socket, so the second fails with an error about a socket in use rather than
  about profiles. **This will bite two-instance dogfooding — the exact flow this
  feature is for.**

## 9. Open questions

- **Whether the Embedded empty state belongs in `RepoList` at all.** E0–E6 are
  facts about the *module*, not a list of repositories, and `RepoView` has the
  same problem one level down — open a repo in E2 and what happens? Not traced.
  A shared `EmbeddedState.qml` may be right, but not speculatively.
- **Whether E6 is frequent enough to justify its own screen.** Real, and
  `radicle_impl.h` is emphatic, but there is no evidence on how often
  `Runtime::run` panics. Cost is one branch, so it is kept.
- **`sayingNothing`'s coupling**, and whether `tests/ui/local.yaml` asserts on
  `reposNotImplemented` in a way that needs rewriting. It almost certainly does.
- **Whether the passphrase must be re-asked when starting from the panel after a
  restart**, or whether anything could hold a decrypted key across a stop/start
  within one session. Check before building the panel's start control.
- **PR #47's merge order.** If the entry point must ship first, surfaces A, B
  and D are deliverable and C degrades to status-and-start-stop — coherent, but
  step 4's pointer to Settings › Node would be premature.
