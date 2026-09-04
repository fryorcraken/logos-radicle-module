import QtQuick

/*
 * Which source browsing calls go to, and the method-name routing that follows
 * from it.
 *
 * Pulled out of Main.qml for the same reason NavState was: the logic is four
 * lines, but it decides whether the entire local-node backend is reachable at
 * all, and inside Main.qml it could only be tested by a stub that reproduced
 * it — which is a copy asserted against itself, not a test. A regression that
 * hardcoded "remote" again would leave the toggle visibly working and the
 * local source silently unreachable, and that is precisely what a stub cannot
 * see. Here it is a real object a component test drives directly.
 *
 * The two sources answer different questions — a seed sees only public repos
 * it replicates, the local node sees your private ones and works offline —
 * but they return identical JSON, which is the contract radicle_impl.h states.
 * That is what lets this be one switch rather than a second set of views.
 */
QtObject {
    id: state

    /// "remote" (a seed node over HTTPS) or "local" (this machine's
    /// ~/.radicle, read in process).
    property string current: "remote"

    /// Whether this machine has a Radicle profile at all. When false, `local`
    /// is refused: there would be nothing to read.
    property bool localAvailable: false

    /// Emitted when the source actually changed. Main.qml responds by
    /// resetting navigation AND refetching the list — both, because NavState
    /// is a pure state holder that does not reload on reset. Omitting the
    /// refetch is a bug that shipped once: the toggle flipped, the screen
    /// cleared, and no request was ever issued, which reads as "your node has
    /// no repositories".
    signal changed()

    /// The backend method to invoke for `suffix` under the current source —
    /// e.g. ("ListRepos") -> "localListRepos". `override` forces one call to
    /// a specific source, the seam for a screen showing both at once.
    function methodFor(suffix, override) {
        return (override || current) + suffix;
    }

    /// Switch source. Returns true when something changed, so a caller can
    /// tell a real switch from a no-op click on the already-selected segment.
    function select(next) {
        if (next === current) return false;
        // Guarded here as well as by hiding the segment: a spec, or a future
        // caller, can reach this directly.
        if (next === "local" && !localAvailable) return false;
        current = next;
        changed();
        return true;
    }
}
