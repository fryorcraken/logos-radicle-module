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
    property string mode: "local"

    /// Whether this machine has a Radicle profile the CURRENT mode can read.
    ///
    /// Comes from `getCapabilities().localAvailable`, which already accounts
    /// for the mode: explore and embedded both report false because their
    /// store has no home. So this is not a second opinion about the mode — it
    /// is the backend's answer about the mode in force.
    property bool localAvailable: false

    /// The backend METHOD PREFIX the current mode implies — "remote" or
    /// "local". NOT settable: it is derived, and that is the whole point of
    /// collapsing the two models.
    ///
    /// Note this is a prefix, not a mode, even though `local` is spelled the
    /// same in both vocabularies. `embedded` mapping to the `local` prefix is
    /// what shows they are separate things.
    readonly property string current: mode === "explore" ? "remote" : "local"

    /// Emitted when the mode actually changed. Main.qml responds by resetting
    /// navigation AND refetching the list — both, because NavState is a pure
    /// state holder that does not reload on reset. Omitting the refetch is a
    /// bug that shipped once: the toggle flipped, the screen cleared, and no
    /// request was ever issued, which reads as "your node has no repositories".
    signal changed()

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
