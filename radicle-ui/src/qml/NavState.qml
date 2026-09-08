import QtQuick

/*
 * Top-level navigation and request-tracking state for Main.qml.
 *
 * Pulled out of Main.qml so the counter/error logic — the part that a
 * pre-release architecture review flagged as undertested — is a standalone
 * unit that can be driven directly in a component test, the same way
 * ListCache.qml is tested without a live backend.
 *
 * `inflight` is a COUNTER, not a flag: concurrent requests are the norm here
 * (SourceTab.load() fires two, syncAll() fires dozens), and with a boolean
 * the first reply to land cleared the busy strip while the rest were still
 * in flight.
 *
 * `error` is deliberately NOT cleared when a new request starts (see
 * begin()) — clearing on every request start meant a later request erased an
 * earlier one's error, so during a sync (dozens of parallel fetches) an
 * error was effectively unobservable. It clears only on success (succeed())
 * and on navigation (reset()/back()).
 */
QtObject {
    id: nav

    property string view: "repos"      // repos | repo
    property string rid: ""
    property var repo: null

    property int inflight: 0
    readonly property bool busy: inflight > 0
    property string error: ""

    /// Call when a request starts. Does not touch `error` — see the note
    /// above.
    function begin() {
        inflight++;
    }

    /// Call when a request finishes successfully.
    function succeed() {
        inflight--;
        error = "";
    }

    /// Call when a request fails. `message` replaces whatever error was
    /// there before, so the most recent failure is always what is shown.
    function fail(message) {
        inflight--;
        error = message;
    }

    /// Call when a request finished but its outcome is no longer worth
    /// reporting — the state it was issued against has since moved on.
    ///
    /// The counter must still come down: the request really did finish, and
    /// leaking `inflight` leaves the busy strip up for ever. What is skipped is
    /// only the user-visible message.
    ///
    /// Distinct from `succeed()` on purpose, and the difference is not
    /// cosmetic. `succeed()` CLEARS `error`, which is right for a request that
    /// worked — the condition it was reporting is demonstrably over. A stale
    /// request proves nothing either way, so it must not clear a live error
    /// belonging to the screen the user is actually on. Neither existing
    /// function has this shape, which is why this is a third one rather than a
    /// flag on one of them.
    ///
    /// See Main.call(): a reply for a mode the module has left comes here.
    function settle() {
        inflight--;
    }

    function reset() {
        view = "repos"; rid = ""; repo = null; error = ""; inflight = 0;
    }

    function openRepo(r) {
        rid = r.rid; repo = r; view = "repo";
    }

    function back() {
        view = "repos"; rid = ""; repo = null; error = "";
    }
}
