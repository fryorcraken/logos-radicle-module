import QtQuick

/*
 * The mode this module is in, and the method-name routing that FOLLOWS from it.
 *
 * ## One setting, not two
 *
 * This used to hold a `source` (`remote`/`local`) that the user picked with a
 * toggle, while the backend separately persisted a `mode`
 * (`attach`/`embedded`/`seedOnly`). Two overlapping vocabularies for one
 * question, in two different sets of words, and they said the same thing twice:
 *
 *     mode        source     the user saw
 *     seedOnly    remote     "Explore"
 *     attach      local      "Local", plus a stray "Attached · z6Mko…" badge
 *     embedded    —          nothing coherent
 *
 * That duplication is the root cause of the header being unreadable, not a
 * side effect of it. The badge was the MODE vocabulary leaking onto a screen
 * that otherwise spoke SOURCE, which is why it read as a dead control saying
 * something the user could not connect to anything else on the bar.
 *
 * So there is now one three-valued setting — the mode — and `source` is
 * DERIVED from it. Picking a segment persists a mode; the routing follows.
 * There is no second thing to keep in sync, and no way for them to drift.
 *
 * This mirrors the shape review already forced on the backend, where
 * `startableModes()` is the single source of truth and `modeIsStartable()` is
 * derived from it rather than repeating the condition.
 *
 * ## One vocabulary, top to bottom
 *
 * The stored values were renamed to the words the user reads — `explore`,
 * `local`, `embedded` — so the constant in `settings_store.h`, the value in
 * the settings file, the string in `getCapabilities()`, the property here and
 * the segment label are all the same word. Keeping "keys are the contract,
 * labels are a UI decision" would have been defensible in the abstract and was
 * exactly how the two vocabularies got a whole milestone apart in practice.
 *
 * ## The one genuine collision, and why it is not a conflation
 *
 * `local` is now BOTH a mode value and the prefix of the `local*` backend
 * methods. They are different things that happen to share a word, and nothing
 * here treats one as the other: `current` below is a METHOD PREFIX computed
 * from the mode, not the mode passed through. The `embedded` mode routing to
 * the `local` prefix is what makes that plain — if the two were the same thing,
 * that line could not exist.
 *
 * ## Why the derivation is what it is
 *
 * `remote*` proxies to a seed over HTTPS; `local*` reads this machine's
 * Radicle home in process. Explore means exactly "do not touch a local
 * profile" — `radicle_impl.cpp`'s `storeForSettings` gives that mode a store
 * with no home at all — so it routes remote. Local and Embedded both name a
 * node on this machine, so both route local.
 *
 * The two surfaces return identical JSON, which is the contract
 * `radicle_impl.h` states. That is what lets this be one switch rather than a
 * second set of views.
 */
QtObject {
    id: state

    /// The persisted mode: "explore" | "local" | "embedded".
    ///
    /// Bound to `getCapabilities().mode` by Main.qml rather than owned here,
    /// so the backend is the authority on what is actually in force. A UI that
    /// kept its own copy could show a mode the module is not in — which is the
    /// identity confusion this milestone exists to prevent, one level up.
    ///
    /// **The initial value is the PRE-CAPABILITIES guess, and it is `explore`
    /// for the same reason `current` falls through to `remote`: it is the one
    /// mode that touches no local profile.** It was `local`, which made the
    /// window before the first capabilities reply a window in which the UI
    /// asserted a local node it had not been told about — and, because
    /// `Main.qml` calls `repoList.reload()` from `onBackendReady()` without
    /// waiting for that reply, could actually issue `localListRepos` on the
    /// strength of the guess.
    ///
    /// It also matches `SettingsStore`'s own default, so the guess and the
    /// answer agree and there is no visible flip on a fresh profile. Guessing
    /// wrong is still cheap and self-correcting — the binding settles on the
    /// real mode and `onSourceChanged` reloads — but guessing towards the
    /// inert mode means a wrong guess reads a seed rather than a node.
    property string mode: "explore"

    /// Whether this machine has a Radicle profile the CURRENT mode can read.
    ///
    /// Comes from `getCapabilities().localAvailable`, which already accounts
    /// for the mode: explore and embedded both report false because their
    /// store has no home. So this is not a second opinion about the mode — it
    /// is the backend's answer about the mode in force.
    property bool localAvailable: false

    /// Every mode this BUILD can actually start, from
    /// `getCapabilities().startableModes`.
    ///
    /// A fact about the build, not about the mode in force — see
    /// `SettingsStore::startableModes()` for why the boolean `modeStartable`
    /// cannot substitute for it.
    property var startableModes: []

    /// Whether the mode in force is one this build can start.
    ///
    /// Derived from the set above rather than read from `caps.modeStartable`,
    /// and derived here rather than recomputed by each consumer. `RepoList`
    /// used to ask `app.mode === "embedded"` directly, which made it a THIRD
    /// place encoding "which mode cannot start" alongside `startableModes()`
    /// and `modeIsStartable()` in the core module. Phase 2 makes Embedded
    /// startable by adding one entry to that list; a hardcoded comparison here
    /// would have kept the not-implemented screen up afterwards with no gate
    /// failing — the silent drift `startableModes` was introduced to end.
    ///
    /// Defaults to true when the set is empty, which is the pre-capabilities
    /// state: an empty list means "we have not been told yet", not "nothing
    /// works", and treating it as the latter would flash a not-implemented
    /// screen on every start before the first capabilities reply lands.
    readonly property bool modeStartable: {
        if (!startableModes || startableModes.length === 0) return true;
        for (var i = 0; i < startableModes.length; i++)
            if (startableModes[i] === mode) return true;
        return false;
    }

    /// The backend METHOD PREFIX the current mode implies — "remote" or
    /// "local". NOT settable: it is derived, and that is the whole point of
    /// collapsing the two models.
    ///
    /// Note this is a prefix, not a mode, even though `local` is spelled the
    /// same in both vocabularies. `embedded` mapping to the `local` prefix is
    /// what shows they are separate things.
    ///
    /// **Every mode that routes local is named; the fall-through routes
    /// remote.** This was `mode === "explore" ? "remote" : "local"`, which made
    /// `local` the else — so an unrecognised mode routed to the `local*`
    /// methods, `RepoList` fetched, and the attached node's repositories
    /// rendered under a mode with no segment. That is the same else-shape, and
    /// the same failure, that `storeForSettings()` had in the core module.
    ///
    /// The backend's `load()` now refuses to hand out an unknown mode at all,
    /// so this should be unreachable — it is kept because the cost is one
    /// condition and the failure it prevents is a node identity being
    /// misattributed. Defaulting to `remote` is the safe direction for the same
    /// reason Explore is the backend's fallback: it asks a seed over HTTP and
    /// touches no local profile.
    readonly property string current: (mode === "local" || mode === "embedded")
                                      ? "local" : "remote"

    /// Emitted when the user PICKS a different mode — on the click, while the
    /// `setSetting` write is still in flight. Main.qml responds by resetting
    /// navigation, so the screen stops showing the previous mode's data
    /// immediately.
    ///
    /// It must NOT be used to refetch. See `settled()`.
    signal changed()

    /// Emitted when the mode the module is ACTUALLY IN has changed — i.e. when
    /// `mode`, a binding to `getCapabilities().mode`, moves. This is the signal
    /// to reload on.
    ///
    /// ## Why this exists rather than reloading on `changed()` or on `current`
    ///
    /// Both of those were tried, together, and both are wrong:
    ///
    ///  - **On `changed()`** — the click. The write is still in flight, so
    ///    `mode` is still the mode the user just LEFT, and everything derived
    ///    from it (`current`, `modeStartable`) still describes that mode. A
    ///    reload here fetches from the old surface. Deferring by an event-loop
    ///    turn does not help: the turn elapses long before a backend round trip.
    ///  - **On `current`** — the derived METHOD PREFIX. `local` and `embedded`
    ///    both derive to `"local"`, deliberately, so this does not move at all
    ///    on a `local <-> embedded` switch. Keying a reload on it treats the
    ///    prefix as a proxy for the mode, which it was only ever a faithful
    ///    proxy for while there were two modes.
    ///
    /// Between them those two shipped three defects with one root cause — a
    /// fetch issued against a mode not yet in force, and no second fetch once
    /// it was:
    ///
    ///  - **Switching to Embedded issued `localListRepos`** for a node that
    ///    does not exist. The backend refused it, `nav.fail()` latched the
    ///    refusal, and the user got an error banner beneath a screen explaining
    ///    that Embedded is not implemented — an error about something nothing
    ///    had asked for. (tests/ui/local.yaml, step "and nothing errored,
    ///    because nothing was asked".)
    ///  - **Switching Embedded -> Local listed nothing.** The click's reload
    ///    found Embedded still in force and correctly declined to fetch; the
    ///    prefix then did not change, so no reload followed, and this machine's
    ///    node rendered as an empty one.
    ///  - **Switching Explore -> Embedded** issued `remoteListRepos`, whose
    ///    reply landed after the reset and latched an error the same way.
    ///
    /// One trigger, on the one value that decides both WHAT to fetch and
    /// WHETHER to fetch at all.
    signal settled()

    /// Fires `settled()` when the mode in force changes.
    ///
    /// A handler on the property rather than a `Connections` block, and inside
    /// this component rather than in Main.qml, so that the rule and its reason
    /// live with the state they are about — and so a fixture can drive the real
    /// thing. Main.qml's copy could only ever be reproduced by a test, which is
    /// a copy asserted against itself.
    onModeChanged: settled()

    /// The backend method to invoke for `suffix` under the current mode —
    /// e.g. ("ListRepos") -> "localListRepos". `override` forces one call to a
    /// specific source, the seam for a screen showing both at once.
    function methodFor(suffix, override) {
        return (override || current) + suffix;
    }

    /// Whether `next` is a mode this UI knows. Guarded because a spec, or a
    /// future caller, can reach `select()` directly — and because persisting
    /// an unknown mode would be refused by the backend anyway, after the UI
    /// had already told the user it had switched.
    function isKnownMode(next) {
        return next === "explore" || next === "local" || next === "embedded";
    }

    /// Switch mode. Returns true when something changed, so a caller can tell
    /// a real switch from a no-op click on the already-selected segment.
    ///
    /// This does NOT persist: the caller owns the `setSetting("mode", …)` call,
    /// because a persisted write can be refused and only the caller can report
    /// that. `mode` here is a binding to capabilities, so a successful write
    /// updates it from the backend — which means the UI shows what is actually
    /// in force rather than what it hoped for.
    function select(next) {
        if (next === mode) return false;
        if (!isKnownMode(next)) return false;
        changed();
        return true;
    }
}
