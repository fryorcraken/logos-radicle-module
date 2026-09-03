import QtQuick

/*
 * Cache-first list loader with background revalidation.
 *
 * Switching between "open" and "closed" issues, or between tabs, used to clear
 * the list and refetch from scratch every time — so a view you had already
 * looked at came back empty and made you wait again.
 *
 * The policy here is local-first:
 *   - a cached page is shown IMMEDIATELY, with no loading state;
 *   - a refetch runs in the background anyway, so new issues/patches/commits
 *     still appear;
 *   - the list is only replaced when the fresh reply differs, so the view does
 *     not flicker when nothing has changed.
 *
 * Keys are supplied by the caller and must include everything that changes the
 * result — repository, filter, page. A key that omits one of those serves the
 * wrong data, which is how one repository's README ended up under another's.
 */
QtObject {
    id: cache

    /// key -> { items: [...], fetchedAt: <ms> }
    property var store: ({})
    /// Keys with a request currently in flight, so a rapid filter toggle does
    /// not queue several identical fetches.
    property var inFlight: ({})

    /// How long a cached page is served without revalidating, in ms. A short
    /// window is enough to make toggling filters feel instant while still
    /// picking up changes within a session.
    property int freshMs: 30000

    /// True when `key` has data that can be shown right now.
    function has(key) {
        return store[key] !== undefined;
    }

    function items(key) {
        var e = store[key];
        return e ? e.items : [];
    }

    /// True when the entry is old enough to be worth revalidating.
    function isStale(key) {
        var e = store[key];
        if (!e) return true;
        return (Date.now() - e.fetchedAt) > freshMs;
    }

    function put(key, items) {
        store[key] = { items: items, fetchedAt: Date.now() };
    }

    function begin(key) {
        if (inFlight[key]) return false;
        inFlight[key] = true;
        return true;
    }

    function end(key) {
        delete inFlight[key];
    }

    function busy(key) {
        return !!inFlight[key];
    }

    function clear() {
        store = ({});
        inFlight = ({});
    }

    /// Cheap comparison so an unchanged reply does not rebuild the list model
    /// and lose the user's scroll position.
    function sameIds(a, b) {
        if (!a || !b || a.length !== b.length) return false;
        for (var i = 0; i < a.length; i++) {
            var x = a[i], y = b[i];
            var xi = x.id !== undefined ? x.id : x.rid;
            var yi = y.id !== undefined ? y.id : y.rid;
            if (xi !== yi) return false;
        }
        return true;
    }
}
