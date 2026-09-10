import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Embedded is a mode that WORKS now, and every screen must treat it as one.
 *
 * ## Why this file exists beside tst_embedded.qml
 *
 * That file pins what a screen does about a mode the backend reports as
 * unstartable, and uses Embedded as its example because that is the mode the
 * behaviour was written for. Its fixture therefore says Embedded is not
 * startable — deliberately, because the question needs an unstartable mode to
 * ask it of.
 *
 * Which means every assertion in it is equally true of a build where Embedded
 * never becomes startable at all. The flip that made it startable is one entry
 * in `SettingsStore::startableModes()`, and the whole point of Phase 1 wiring
 * the UI to derive from that list was that this entry would be the ONLY edit —
 * so the change that turns the mode on touches no QML, and consequently no
 * existing QML test can fail for it. A green suite proved nothing about the
 * mode being on.
 *
 * That is the gap: a suite that cannot fail for the change is not coverage of
 * it. These tests drive the capability the way the backend now reports it and
 * assert the mode behaves like the working mode it is.
 *
 * ## The fake answers differently per mode, on purpose
 *
 * `local` and `embedded` derive to the SAME method prefix (`"local"` — see
 * SourceState.qml), so a fake keyed on the prefix answers identically for both
 * and cannot tell "listed the embedded node" from "listed the user's node under
 * an Embedded badge". That is precisely the identity confusion this milestone
 * exists to prevent, and a fixture blind to it would certify the bug as fixed.
 *
 * So the fake answers from the MODE, with repository names carrying it. This is
 * CLAUDE.md's input-dependent-fake rule applied to the one input that matters
 * here, and it is what makes `test_embedded_lists_its_own_node_not_the_users`
 * an assertion rather than decoration.
 */
Item {
    id: root
    width: 900
    height: 600

    QtObject {
        id: app

        /// The mode in force, as Main.qml binds it from capabilities.
        property string mode: "embedded"

        /// The derived method prefix. Identical for `local` and `embedded`,
        /// which is why the fake below must not key on it.
        readonly property string source: (mode === "local" || mode === "embedded")
                                         ? "local" : "remote"

        /// What the backend now reports: all three modes start.
        property var startableModes: ["explore", "local", "embedded"]

        readonly property bool modeStartable: {
            for (var i = 0; i < startableModes.length; i++)
                if (startableModes[i] === mode) return true;
            return false;
        }

        property var callLog: []
        property var pending: null

        function call(method, args, onOk, onFail) {
            callLog.push(source + method);
            // The MODE is captured at issue time, so a reply answers for the
            // node it was asked of rather than for whatever is in force when it
            // lands. Without this the fake could not stage a stale reply.
            pending = { mode: mode, args: args, onOk: onOk, onFail: onFail };
        }

        /// Answer the held request with rows named after the MODE it was issued
        /// for — so "which node answered" is readable off the list itself.
        function deliver() {
            if (pending === null) return false;
            var p = pending;
            pending = null;
            p.onOk({ items: [
                { rid: "rad:z" + p.mode + "1", name: p.mode + "-repo-one" },
                { rid: "rad:z" + p.mode + "2", name: p.mode + "-repo-two" }
            ], hasMore: false });
            return true;
        }

        /// Refuse, the way the backend refuses an embedded home with no
        /// identity in it yet: an error naming the absence, NOT an empty list.
        function refuseAsUnprovisioned() {
            if (pending === null) return false;
            var p = pending;
            pending = null;
            p.onFail("no embedded identity yet");
            return true;
        }

        function reset() {
            callLog = [];
            pending = null;
        }
    }

    Ui.RepoList {
        id: list
        anchors.fill: parent
        app: app
    }

    function findByName(node, name) {
        if (!node) return null;
        if (node.objectName === name) return node;
        for (var i = 0; i < node.children.length; i++) {
            var hit = findByName(node.children[i], name);
            if (hit) return hit;
        }
        return null;
    }

    TestCase {
        name: "EmbeddedIsAWorkingMode"
        when: windowShown

        function init() {
            app.mode = "embedded";
            app.startableModes = ["explore", "local", "embedded"];
            list.reload();
            app.reset();
        }

        /// **The flip itself.** With Embedded in the startable set, the screen
        /// must stop rendering the not-implemented state — the state that told
        /// the user, correctly until now, that the mode does not exist.
        ///
        /// Asserted on `notImplemented` AND on the rendered note, because the
        /// property going false while the note stayed on screen is a real
        /// possibility (they are separate bindings) and is the shape a user
        /// would actually see.
        function test_embedded_no_longer_renders_the_not_implemented_state() {
            list.reload();
            verify(!list.notImplemented,
                   "Embedded is startable now — the screen must not claim the "
                   + "mode is unavailable");

            var note = root.findByName(list, "notImplementedNote");
            verify(note === null || !note.visible,
                   "the not-implemented note must be off screen, not merely "
                   + "unbacked by the property");
        }

        /// And it actually asks. `notImplemented` going false while `fetch()`
        /// still returned early would leave a permanently blank pane — the
        /// failure `sayingNothing` exists to catch, arriving from the mode that
        /// just became real.
        function test_embedded_issues_a_list_request() {
            list.reload();
            compare(app.callLog.length, 1,
                    "Embedded must list its own node, calls issued: "
                    + JSON.stringify(app.callLog));
            compare(app.callLog[0], "localListRepos",
                    "through the local* surface, which is what the mode derives "
                    + "to — see SourceState.qml");
        }

        /// And renders what comes back.
        function test_embedded_shows_the_repositories_it_fetched() {
            list.reload();
            verify(app.deliver(), "the request must be answerable");
            compare(list.count, 2, "with the rows on screen");
            verify(!list.sayingNothing,
                   "and nothing blank: rows are showing");
        }

        /// **The identity assertion.** The rows on screen must be the EMBEDDED
        /// node's, not the user's — which only an input-dependent fake can show,
        /// since both modes route through the same method prefix.
        ///
        /// Without this, a `RepoList` that had somehow kept listing the mode it
        /// was previously in would pass every assertion above: two rows, no
        /// blank pane, one request. The names are the only thing that says which
        /// node answered.
        function test_embedded_lists_its_own_node_not_the_users() {
            app.mode = "local";
            list.reload();
            verify(app.deliver(), "precondition: Local answers");
            compare(list.count, 2, "precondition: Local populated the list");

            app.mode = "embedded";
            list.reload();
            compare(list.count, 0,
                    "switching must clear the previous node's rows before "
                    + "anything new arrives");
            verify(app.deliver(), "and Embedded's own request must be answerable");
            compare(list.count, 2, "with Embedded's rows on screen");
        }

        /// **A reply issued in Local must still be dropped when it lands in
        /// Embedded**, and this leg got HARDER with the flip rather than easier.
        ///
        /// While Embedded was unstartable, `fetch()` returned early for it, so
        /// no second request existed and `notImplemented` kept the pane clear
        /// whatever arrived. Both of those incidental protections are gone: the
        /// only thing left dropping a stale Local reply is the staleness guard
        /// comparing `app.mode`, which is the one term that distinguishes the
        /// two modes — `app.source` is `"local"` for both.
        ///
        /// The Local reply is HELD across the switch and delivered afterwards,
        /// which is the worst ordering rather than a convenient one. Delivering
        /// it before the switch would prove nothing.
        function test_a_local_reply_landing_after_the_switch_is_still_dropped() {
            app.mode = "local";
            list.reload();
            verify(app.pending !== null, "precondition: a Local request is in flight");
            var stale = app.pending;

            app.mode = "embedded";
            list.reload();
            compare(list.count, 0, "precondition: the switch cleared the list");

            // The Local reply arrives now, naming the node it was asked of.
            stale.onOk({ items: [
                { rid: "rad:zlocal1", name: "local-repo-one" },
                { rid: "rad:zlocal2", name: "local-repo-two" }
            ], hasMore: false });

            compare(list.count, 0,
                    "a reply issued in Local repopulated the list after the "
                    + "user switched to Embedded — the user's own repositories "
                    + "under an Embedded badge, which is the identity confusion "
                    + "this milestone exists to prevent");

            // And Embedded's own request, still pending, still answers.
            verify(app.deliver(), "Embedded's own request must be answerable");
            compare(list.count, 2, "with Embedded's rows, not Local's");
        }

        /// An embedded home with no identity in it yet is a REFUSAL, not an
        /// empty node — and the screen must render the refusal's own state
        /// rather than "No repositories matched", which claims a node exists
        /// and holds nothing.
        ///
        /// This is the state a user is in between choosing Embedded and running
        /// the wizard, so it is the state they will most often see.
        function test_an_unprovisioned_embedded_home_does_not_claim_to_be_empty() {
            list.reload();
            verify(app.refuseAsUnprovisioned(), "the request must be refusable");

            compare(list.count, 0, "there is nothing to list");
            // The screen must say SOMETHING. A blank pane with no rows, no
            // message and no error is never correct — see RepoList.sayingNothing.
            verify(!list.sayingNothing,
                   "an embedded home with no identity rendered a blank pane: no "
                   + "rows, no message, nothing for the user to act on");
        }

        /// Paging is offered again, because there is a node to page against.
        /// The mirror of tst_embedded.qml's `test_embedded_offers_no_paging`,
        /// which asserted the opposite for an unstartable mode.
        function test_embedded_pages_like_any_other_mode() {
            list.reload();
            verify(app.pending !== null, "a request is in flight");
            var p = app.pending;
            app.pending = null;
            p.onOk({ items: [{ rid: "rad:z1", name: "one" }], hasMore: true });

            compare(list.hasMore, true,
                    "Embedded must offer a further page when the backend says "
                    + "there is one");
        }
    }
}
