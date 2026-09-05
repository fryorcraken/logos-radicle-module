import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * BranchPicker's local/peer grouping.
 *
 * In local mode a repo's branches come from every peer whose refs this node
 * holds — including the node's own. `local::list_branches` returns them with
 * the local node's first, each carrying `isLocal`, and the picker inserts one
 * "other peers" divider at the boundary.
 *
 * The seed source sends neither `isLocal` nor peer rows, so its list must come
 * through completely unchanged. That is what stops this from being a local-only
 * feature that quietly reshapes the remote picker too.
 */
Item {
    width: 400
    height: 300

    // A local-source reply: two of this node's branches, then two peers'.
    // Deliberately NOT alphabetical overall — `aaa` sorts before `main` — so a
    // test asserting local-first cannot pass by accident on a flat sort.
    readonly property var localReply: ({
        items: [
            { name: "main",   label: "main",   head: "a1", remote: "z6MkSelf", isLocal: true },
            // A LOCAL branch with a slash in it. Ordinary in real repos, and
            // the reason nothing here may infer "peer" from the presence of a
            // slash — the backend sends `isLocal` for exactly this reason.
            { name: "feature/login", label: "feature/login", head: "a2",
              remote: "z6MkSelf", isLocal: true },
            { name: "zzz",    label: "zzz",    head: "a3", remote: "z6MkSelf", isLocal: true },
            { name: "z6MkPeerOne/aaa",  label: "z6MkPeer…/aaa",  head: "b1",
              remote: "z6MkPeerOne", isLocal: false },
            { name: "z6MkPeerTwo/main", label: "z6MkPeer…/main", head: "b2",
              remote: "z6MkPeerTwo", isLocal: false }
        ],
        default: "main"
    })

    // A seed reply: the pre-existing shape, no isLocal anywhere.
    readonly property var remoteReply: ({
        items: [{ name: "main", head: "a1" }, { name: "dev", head: "a2" }],
        default: "main"
    })

    // Every branch belongs to a peer — the common case for a repo this node
    // replicates but is not a delegate of. There is nothing above the divider.
    readonly property var peersOnlyReply: ({
        items: [
            { name: "z6MkPeerOne/main", label: "z6MkPeer…/main", head: "b1",
              remote: "z6MkPeerOne", isLocal: false }
        ],
        default: "main"
    })

    Ui.BranchPicker {
        id: picker
        rid: "rad:zLOCAL"
        fetchBranches: function (cb) { cb(localReply); }
    }

    Ui.BranchPicker {
        id: remotePicker
        rid: "rad:zREMOTE"
        fetchBranches: function (cb) { cb(remoteReply); }
    }

    Ui.BranchPicker {
        id: peersOnlyPicker
        rid: "rad:zPEERS"
        fetchBranches: function (cb) { cb(peersOnlyReply); }
    }

    /// Read the picker's model back as plain rows, so assertions can talk
    /// about order and separators rather than poking at indices.
    function rows(p) {
        var out = [];
        for (var i = 0; i < p.count; i++) {
            var r = p.model.get(i);
            out.push({ label: r.label, name: r.name,
                       isSeparator: r.isSeparator === true,
                       isLocal: r.isLocal === true });
        }
        return out;
    }

    TestCase {
        name: "BranchGrouping"
        when: windowShown

        // Asserts on `isLocal`, NOT on whether the name contains a slash.
        // Those are different questions: `feature/login` is a perfectly
        // ordinary LOCAL branch, and the fixture includes one precisely so a
        // slash-based check cannot creep back in. A slash test would also fail
        // to catch the regression it names — a peer row sorted above a local
        // one would still satisfy it as long as the naming convention held.
        function test_local_branches_come_before_the_divider_and_peers_after() {
            var r = rows(picker);
            var sep = -1;
            for (var i = 0; i < r.length; i++)
                if (r[i].isSeparator) { sep = i; break; }

            verify(sep >= 0, "expected a divider row: " + JSON.stringify(r));

            for (var j = 0; j < sep; j++)
                verify(r[j].isLocal,
                       "row above the divider must be local: " + JSON.stringify(r[j]));
            for (var k = sep + 1; k < r.length; k++)
                verify(!r[k].isLocal,
                       "row below the divider must be a peer's: " + JSON.stringify(r[k]));
        }

        // The slash is not the signal — the flag is. A local branch whose name
        // contains a slash must still sit above the divider.
        function test_a_slashed_local_branch_is_still_local() {
            var r = rows(picker);
            var slashed = null;
            for (var i = 0; i < r.length; i++)
                if (r[i].name === "feature/login") { slashed = r[i]; break; }

            verify(slashed !== null, "fixture should contain a slashed local branch");
            verify(slashed.isLocal, "a slashed local branch is still local: "
                                    + JSON.stringify(slashed));
        }

        function test_exactly_one_divider_is_inserted() {
            var r = rows(picker);
            var n = 0;
            for (var i = 0; i < r.length; i++)
                if (r[i].isSeparator) n++;
            compare(n, 1, "one divider, not one per peer: " + JSON.stringify(r));
        }

        function test_every_branch_survives_the_grouping() {
            var r = rows(picker);
            var names = [];
            for (var i = 0; i < r.length; i++)
                if (!r[i].isSeparator) names.push(r[i].name);
            compare(names.length, 5);
            verify(names.indexOf("main") >= 0, "local main: " + names);
            verify(names.indexOf("feature/login") >= 0, "local slashed: " + names);
            verify(names.indexOf("zzz") >= 0, "local zzz: " + names);
            verify(names.indexOf("z6MkPeerOne/aaa") >= 0, "peer aaa: " + names);
            verify(names.indexOf("z6MkPeerTwo/main") >= 0, "peer main: " + names);
        }

        // Two branches are called `main` — one local, one a peer's. If the
        // picker keyed on the display label they would collide, and picking
        // one could load the other's commits.
        function test_a_peer_branch_named_like_a_local_one_stays_distinct() {
            var r = rows(picker);
            var mains = [];
            for (var i = 0; i < r.length; i++)
                if (!r[i].isSeparator && r[i].label.indexOf("main") >= 0)
                    mains.push(r[i].name);
            compare(mains.length, 2, "both mains present: " + mains);
            verify(mains[0] !== mains[1], "their names must differ: " + mains);
        }

        // The divider is not a branch. Selecting it would display "other
        // peers" as the current branch and, worse, emit it as one.
        function test_choosing_the_divider_does_not_switch_branch() {
            picker.currentBranch = "main";
            var sep = -1;
            var r = rows(picker);
            for (var i = 0; i < r.length; i++)
                if (r[i].isSeparator) { sep = i; break; }
            verify(sep >= 0, "expected a divider row");

            var seen = [];
            function grab(name) { seen.push(name); }
            picker.branchChosen.connect(grab);
            picker.activated(sep);
            picker.branchChosen.disconnect(grab);

            compare(seen.length, 0, "the divider must not emit branchChosen");
            compare(picker.model.get(picker.currentIndex).name, "main",
                    "selection stays on the real branch");
        }

        // Regression guard for the seed path: this change must not reshape the
        // remote picker, which sends no isLocal at all. A falsy check
        // (`!isLocal`) instead of `isLocal === false` would insert a divider
        // above every remote branch.
        function test_a_seed_reply_gets_no_divider() {
            var r = rows(remotePicker);
            for (var i = 0; i < r.length; i++)
                verify(!r[i].isSeparator,
                       "no divider for a source that sends no isLocal: " + JSON.stringify(r));
            compare(r.length, 2);
        }

        // A repo this node only replicates has no local branches. The divider
        // would then sit at the very top with nothing above it, which reads as
        // a stray caption rather than a grouping.
        function test_peers_only_repo_gets_no_leading_divider() {
            var r = rows(peersOnlyPicker);
            verify(r.length > 0, "expected the peer branch");
            verify(!r[0].isSeparator,
                   "a divider must not lead the list: " + JSON.stringify(r));
        }

        // `count` is the ComboBox's model size and includes the divider. The
        // e2e specs assert on "how many branches", so they need the number of
        // things a user can actually pick — off by one is the whole bug here.
        function test_branchCount_excludes_the_divider() {
            compare(picker.count, 6, "5 branches + 1 divider in the model");
            compare(picker.branchCount, 5, "but only 5 are selectable");
            compare(picker.hasSeparator, true);
        }

        // Without a divider the two must agree, or every remote repo would
        // report one branch too few.
        function test_branchCount_equals_count_when_there_is_no_divider() {
            compare(remotePicker.hasSeparator, false);
            compare(remotePicker.branchCount, remotePicker.count);
            compare(remotePicker.branchCount, 2);
        }

        // A peers-only repo inserts no divider, so its count is unadjusted.
        function test_a_peers_only_repo_reports_no_grouping() {
            compare(peersOnlyPicker.hasSeparator, false);
            compare(peersOnlyPicker.branchCount, 1);
        }

        // hasSeparator is set during a reload and must be cleared by the next
        // one. Switching from a grouped repo to an ungrouped one is the case
        // that catches a flag that is only ever set and never reset — it would
        // keep reporting a divider that is no longer in the model, and
        // branchCount would then be one too few for the rest of the session.
        function test_switching_to_an_ungrouped_repo_clears_the_grouping_flag() {
            var reply = localReply;
            var switcher = Qt.createQmlObject(
                'import "../src/qml" as Ui; Ui.BranchPicker { rid: "rad:zA" }',
                parent);
            switcher.fetchBranches = function (cb) { cb(reply); };
            compare(switcher.hasSeparator, true, "the grouped repo groups");

            // A different repo whose branches are all local: no divider.
            reply = { items: [{ name: "solo", label: "solo", head: "c1",
                                remote: "z6MkSelf", isLocal: true }],
                      default: "solo" };
            switcher.rid = "rad:zB";

            compare(switcher.hasSeparator, false,
                    "the flag must not survive the switch");
            compare(switcher.branchCount, 1);
            switcher.destroy();
        }
    }
}
