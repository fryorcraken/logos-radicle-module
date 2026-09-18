import QtQuick

/*
 * Which of the seven Embedded states is in force, derived from what the backend
 * reports — never stored, never remembered.
 *
 * ## Why this is a component rather than seven conditions in RepoList
 *
 * Same reason `NavState` and `SourceState` are components: the behaviour is
 * otherwise untestable without a window. Every rule here — the ordering, the
 * `startPending` disambiguation, which states have a node to ask — is a
 * question about values, and asking it of a `QtObject` beats hunting a panel in
 * a scene graph.
 *
 * It also gives the rule ONE home. The screen needs the same facts three times
 * over (which sentence, which action, whether to fetch), and three copies of a
 * seven-way condition is the shape CLAUDE.md records this repo paying for with
 * the `wantRid`/`syncEpoch` guards — four hand-written copies, each dropping a
 * different term.
 *
 * ## Derived, not stored
 *
 * There is no `property string state` that a reply assigns. Every input below
 * is a FIELD FROM A REPLY, and `state` is a pure function of them. That is the
 * difference between "the backend says running:false" and "we decided we were
 * stopped once" — the second is a second opinion, and it is wrong the moment a
 * node dies, a passphrase is refused, or the mode is changed from elsewhere.
 *
 * `startPending` and `startError` look like exceptions and are not: both are
 * facts about a call THIS VIEW issued, which no backend reply carries. The node
 * cannot tell you whether you are waiting for it.
 *
 * ## The ordering is the whole point
 *
 * More than one condition can hold at once — a start can be refused in a home
 * that later reports a `pathsProblem` — so the table is read top to bottom and
 * the first match wins. It runs from the most fundamental obstacle to the least,
 * so a user is told there is nowhere to write BEFORE being told a start failed,
 * rather than being sent to retry a start that cannot succeed.
 *
 * ## E3 and E6 report the same two fields
 *
 * A `getNodeStatus()` poll taken during startup reports `running:true` with
 * `serving:false` — exactly what a node whose threads have died reports. The
 * panic guard at the FFI boundary does not reach the threads a running node
 * spawns (`radicle_impl.h:396-403`), so `Runtime::run` panicking leaves
 * `running:true` indefinitely while the `local*` read path keeps answering.
 *
 * The one fact that separates them is whether a start THIS VIEW issued is still
 * outstanding, which is the fact the backend reply cannot carry. Hence
 * `startPending`, and hence its clearing being keyed on the REPLY rather than on
 * the call having been made — a node that never answers would otherwise settle
 * into "not serving" while its start is genuinely still in flight.
 */
QtObject {
    id: state

    // ---- what the backend reports ----------------------------------------

    /// `getCapabilities().pathsProblem`, verbatim. Non-empty means there is
    /// nowhere to write — typically the 108-byte `sun_path` cap on the control
    /// socket. Displayed verbatim because it names the path that was tried and
    /// the limit that was exceeded, neither of which a view can reconstruct.
    property string pathsProblem: ""

    /// `getEmbeddedIdentity().home` — "" when no home could be resolved at all.
    property string home: ""

    /// `getEmbeddedIdentity().exists`. False covers BOTH an empty home and a
    /// half-created one; nothing in the reply distinguishes them, and
    /// `createEmbeddedIdentity` is the only surface that names the `keys` path
    /// to remove. So both are the no-identity state. See `SetupFlow.qml`.
    property bool identityExists: false

    /// `getNodeStatus().running` — the module's own bookkeeping.
    property bool running: false

    /// `getNodeStatus().serving` — a live probe of the control socket. The only
    /// field that notices a node whose threads have died.
    property bool serving: false

    // ---- what only this view knows ----------------------------------------

    /// True between issuing a `startNode` and its reply landing. Cleared by the
    /// reply — success or `{"error":…}` — never by the call having been issued.
    property bool startPending: false

    /// The last `startNode` refusal, verbatim, or "" when the last start
    /// succeeded or none has been attempted. The module's refusals name the
    /// socket in use, the passphrase that did not unlock the key and the home in
    /// the way; a summary in the view's own words drops each of those, and a
    /// wrong passphrase is only actionable when it is named.
    property string startError: ""

    // ---- which requests reach somebody ------------------------------------
    //
    // An action whose request reaches nobody must not be enabled: a control that
    // is enabled, looks ordinary and does nothing when taken reads as a module
    // that is broken rather than as one that has not built this yet, which is
    // the dead end this whole surface exists to remove.
    //
    // **Held as inputs rather than hard-coded per state**, because the
    // requirement is that hosting an action enables it with nothing else
    // changed. A component that knew "setup is hosted, start is not" would have
    // to be edited again — by someone who has to notice it — on the day the
    // durable settings surface appears. Here the host says what it hosts.
    //
    // Both default to FALSE, so a caller that forgets to wire one gets a named
    // but disabled action, which is visible, rather than an enabled one that
    // silently reaches nobody, which is the defect.

    /// Whether the request to open the guided setup reaches a host.
    property bool setupHosted: false

    /// Whether the requests to start or restart the node reach a host.
    ///
    /// One flag for both: they route to the same surface for the same reason —
    /// both need a passphrase, and `getEmbeddedIdentity()` reports no field
    /// saying whether an existing identity's key is encrypted, so nothing can
    /// even determine whether one is needed. A host able to carry out one is
    /// able to carry out the other.
    property bool startHosted: false

    // ---- the derivation ---------------------------------------------------

    /// Whether a home resolved at all. Two sources because they fail
    /// differently: no home, versus a home whose socket path is unusable.
    readonly property bool homeResolved: pathsProblem === "" && home !== ""

    /// Which state is in force. One of:
    ///
    ///   "blocked"  "noIdentity"  "stopped"  "starting"
    ///   "startFailed"  "notServing"  "runningEmpty"
    ///
    /// Read top to bottom; the first condition that holds wins.
    /// **The order is the spec's, read literally**, and two places in it are
    /// worth knowing before anyone reorders them.
    ///
    /// `stopped` sits ABOVE `starting`, so a start issued against a node still
    /// reporting `running:false` renders as stopped rather than as starting. The
    /// backend's own report wins over what this view is waiting for — telling a
    /// user "starting…" about a node the backend says is not running is the
    /// second-opinion failure this component exists to avoid, and the real
    /// `startNode` returns only once the control socket answers, so the window
    /// is a poll wide. The control is withheld anyway: `actionEnabled` reads
    /// `startPending` directly rather than through the state.
    ///
    /// `startFailed` sits BELOW `stopped` for the same reason — a refused start
    /// that also left the node stopped is a stopped node, and the refusal is
    /// still rendered as the state's own sentence, see `sentence`.
    readonly property string current: {
        if (!homeResolved) return "blocked";
        if (!identityExists) return "noIdentity";
        if (!running && !serving) return startError !== "" ? "startFailed"
                                                           : "stopped";
        if (startPending) return "starting";
        if (startError !== "") return "startFailed";
        if (!serving) return "notServing";
        return "runningEmpty";
    }

    /// Whether the mode in force has a node that could answer a list request.
    ///
    /// **Keyed on whether there is a node, NOT on whether the mode is
    /// startable.** That distinction is the defect this capability exists to
    /// repair: `embedded` is a startable mode — it resolves a workable home — so
    /// a guard keyed on startability never fires for it, and the request went
    /// out against a home with no identity at the same moment the panel behind
    /// it stopped rendering.
    ///
    /// A refused start left no node loaded, so `startFailed` is asked nothing
    /// for exactly the reason `stopped` is. `starting` and `notServing` ARE
    /// asked: a node that is loaded can be read, and a node that has stopped
    /// serving still answers reads, because reads never touch the daemon.
    readonly property bool hasNodeToAsk:
        current === "starting" || current === "notServing"
        || current === "runningEmpty"

    // ---- what the panel says ---------------------------------------------

    /// The sentence for the state in force. Verbatim backend text where the
    /// backend has one, this view's words only where it does not.
    readonly property string sentence: {
        switch (current) {
        case "blocked":
            // The `pathsProblem` sentence verbatim — it names the path and the
            // limit. Falls back only when the home is empty with no problem
            // reported, which is a home that resolved to nothing.
            return pathsProblem !== ""
                 ? pathsProblem
                 : "No Radicle home could be resolved for the embedded node, "
                 + "so there is nowhere to write.";
        case "noIdentity":
            return "Basecamp can run a Radicle node of its own. It will have "
                 + "its own identity — a new one this module creates, separate "
                 + "from any Radicle node you already run.";
        case "stopped":
            return "The embedded node is set up but not running. "
                 + "Repositories are not being fetched.";
        case "starting":
            return "Starting the node…";
        case "startFailed":
            return startError;
        case "notServing":
            return "The node has stopped answering its control socket. "
                 + "It is still loaded but no longer serving.";
        default:
            return "No repositories yet. This node lists what it is seeding.";
        }
    }

    /// The label of the action offered, or "" where none is.
    ///
    /// Each state offers its OWN action rather than one banner with one button:
    /// a home with no identity offers to open the setup, a stopped node offers a
    /// start, a node that has stopped serving offers a RESTART — a bare start
    /// would be refused, because the runtime still holds the socket — and a
    /// blocked home offers nothing that would write, because none can succeed.
    readonly property string actionLabel: {
        switch (current) {
        case "blocked":       return "";
        case "noIdentity":    return "Set up the embedded node";
        case "stopped":       return "Start the node";
        case "starting":      return "";
        case "startFailed":   return "Try again";
        case "notServing":    return "Restart the node";
        default:              return "";
        }
    }

    /// Which act the offered action performs: "" | "setup" | "start" |
    /// "restart". Held separately from the label so a caller routes on the act
    /// rather than on the words, and so the two cannot drift.
    readonly property string actionKind: {
        switch (current) {
        case "noIdentity":    return "setup";
        case "stopped":       return "start";
        case "startFailed":   return "start";
        case "notServing":    return "restart";
        default:              return "";
        }
    }

    /// Whether the act this action names reaches a host that can carry it out.
    /// "" is `false` rather than a third answer: there is nothing to route.
    readonly property bool actionHosted: {
        switch (actionKind) {
        case "setup":              return setupHosted;
        case "start":
        case "restart":            return startHosted;
        default:                   return false;
        }
    }

    /// Whether the offered action may be taken.
    ///
    /// `startPending` is read here rather than folded into `current`, and that
    /// separation is deliberate: withholding the control while a start is in
    /// flight is true whatever the node is reporting, including the window in
    /// which it still reports `running:false` and the state is therefore
    /// `stopped`. Folding it into the state would make "a second node cannot be
    /// started over the first" depend on which of two states a poll happened to
    /// land in.
    ///
    /// **Deleting the `!startPending` term turns
    /// `test_an_outstanding_start_withholds_a_hosted_start_control` red** — the
    /// test that arms `startHosted` deliberately, because with start unhosted
    /// every start action is disabled anyway and the term is unobservable.
    /// Deleting `actionHosted` turns `test_hosting_an_action_is_what_enables_it`
    /// red.
    ///
    /// There is deliberately **no `actionKind !== ""` term here**, and an
    /// earlier version of this comment claimed there was one that reddened
    /// `test_a_blocked_home_offers_no_action_that_would_write`. It did not, and
    /// could not: `actionHosted` switches on `actionKind` and its `default:`
    /// branch already returns `false` for `""`, so the extra term could not
    /// change the result for any input. Review caught the false claim by
    /// mutation — removing the term reddened nothing. Stating the redundancy is
    /// worth more than the term was: a reader who adds a fifth `actionKind`
    /// needs to know the guard lives in `actionHosted`'s `default:`, not here.
    readonly property bool actionEnabled: actionHosted && !startPending

    /// Why the named action cannot be taken, or "" when it can.
    ///
    /// Stated rather than left as a disabled control with no explanation: a
    /// control that is greyed with nothing beside it gives the user no other
    /// thing to try, and reads as broken.
    ///
    /// The wording is careful about which of three claims it makes. It says
    /// starting is **not yet available from here** — not that a start *failed*
    /// (nothing was attempted) and not that the node **cannot be started** (it
    /// can, from a command line, and will be from the settings surface once that
    /// exists). Naming the surface it will live on is what turns a dead end into
    /// a wait.
    ///
    /// NO SPEC: the spec requires only that unavailability be stated
    /// (`embedded-state/spec.md`, "Only an action something can carry out is
    /// offered as enabled"). It says nothing about **where** the text renders or
    /// whether it is silent mid-flight, and both were chosen here:
    ///
    ///   - **Below the button** rather than beside it (`RepoList.qml`'s
    ///     `embeddedStateUnavailable`), so the explanation reads as belonging to
    ///     the disabled control rather than to the state sentence above it.
    ///   - **Silent while a start is outstanding**: the action is then withheld
    ///     because this view is waiting for a reply, which the `starting`
    ///     sentence already says, and reporting "not available" over it would be
    ///     false — it is not unavailable, it is in progress.
    ///     `test_no_unavailability_is_claimed_while_a_start_is_outstanding`
    ///     turns red if the `!startPending` term goes.
    ///
    /// The `actionKind !== ""` term IS load-bearing here, unlike in
    /// `actionEnabled` above: this reads `!actionHosted`, which is `true` when
    /// no act is named at all, so without the term a blocked home would claim
    /// "starting is not yet available from here" when the obstacle is that the
    /// home does not resolve and no act is offered at all.
    /// `test_a_blocked_home_claims_no_unavailability` covers that.
    readonly property string actionUnavailableNote:
        (actionKind !== "" && !actionHosted && !startPending)
            ? "Starting the node is not yet available from here. It needs the "
            + "passphrase that unlocks the key, which this surface has no way "
            + "to ask for."
            : ""
}
