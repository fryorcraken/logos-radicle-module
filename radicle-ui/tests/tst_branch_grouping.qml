import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * BranchPicker: the repository default, peer grouping, filtering, and the
 * cases where the control must not behave like a dropdown at all.
 *
 * In Radicle every branch lives under a peer's namespace — including the
 * user's own — while `refs/heads/<default>` exists separately as a
 * delegate-consensus ref. So the picker's list is a two-level tree with a
 * distinguished root, and these tests are mostly about that shape rather than
 * about pixels.
 *
 * The seed source sends a FLAT list with no peer information at all, and must
 * come through ungrouped. That is what stops peer grouping from being a
 * local-only feature that quietly reshapes the remote picker too.
 */
Item {
    id: harness
    width: 400
    height: 300

    // A local-source reply: two of this node's branches, then two peers'.
    // Deliberately NOT alphabetical overall — `aaa` sorts before `main` — so a
    // test asserting local-first cannot pass by accident on a flat sort.
    readonly property var localReply: ({
        items: [
            { name: "main",   label: "main",   head: "a1aaaaaaaa",
              remote: "z6MkSelfAAAA", isLocal: true },
            // A LOCAL branch with a slash in it. Ordinary in real repos, and
            // the reason nothing may infer "peer" from a slash — the backend
            // sends `isLocal`, and `remote` says whose it is.
            { name: "feature/login", label: "feature/login", head: "a2aaaaaaaa",
              remote: "z6MkSelfAAAA", isLocal: true },
            { name: "zzz",    label: "zzz",    head: "a3aaaaaaaa",
              remote: "z6MkSelfAAAA", isLocal: true },
            { name: "z6MkPeerOne/aaa",  label: "z6MkPeer…/aaa",  head: "b1bbbbbbbb",
              remote: "z6MkPeerOne", isLocal: false },
            { name: "z6MkPeerTwo/main", label: "z6MkPeer…/main", head: "b2bbbbbbbb",
              remote: "z6MkPeerTwo", isLocal: false }
        ],
        default: "main"
    })

    // A seed reply: the pre-existing shape, no isLocal and no remote anywhere.
    readonly property var remoteReply: ({
        items: [{ name: "main", head: "a1aaaaaaaa" },
                { name: "dev", head: "a2aaaaaaaa" }],
        default: "main"
    })

    // Every branch belongs to a peer — the common case for a repo this node
    // replicates but is not a delegate of. 3 of 9 repos on a real machine.
    readonly property var peersOnlyReply: ({
        items: [
            { name: "z6MkPeerOne/main", label: "z6MkPeer…/main", head: "b1bbbbbbbb",
              remote: "z6MkPeerOne", isLocal: false }
        ],
        default: "main"
    })

    // The single-branch repo: 5 of 9 on a real machine.
    readonly property var soloReply: ({
        items: [], default: "main"
    })

    // Enough branches to cross the filter threshold.
    readonly property var manyReply: ({
        items: (function () {
            var out = [];
            for (var i = 0; i < 12; i++)
                out.push({ name: "z6MkPeerOne/branch-" + i,
                           head: "c" + i + "cccccccc",
                           remote: "z6MkPeerOne", isLocal: false });
            return out;
        })(),
        default: "main"
    })

    Ui.BranchPicker {
        id: picker
        rid: "rad:zLOCAL"
        currentBranch: "main"
        fetchBranches: function (cb) { cb(localReply); }
    }

    Ui.BranchPicker {
        id: remotePicker
        rid: "rad:zREMOTE"
        currentBranch: "main"
        fetchBranches: function (cb) { cb(remoteReply); }
    }

    Ui.BranchPicker {
        id: peersOnlyPicker
        rid: "rad:zPEERS"
        currentBranch: "main"
        fetchBranches: function (cb) { cb(peersOnlyReply); }
    }

    Ui.BranchPicker {
        id: soloPicker
        rid: "rad:zSOLO"
        currentBranch: "main"
        fetchBranches: function (cb) { cb(soloReply); }
    }

    Ui.BranchPicker {
        id: manyPicker
        rid: "rad:zMANY"
        currentBranch: "main"
        fetchBranches: function (cb) { cb(manyReply); }
    }

    /// The picker's rows as plain objects, so assertions talk about structure
    /// rather than poking at model indices.
    function rows(p) {
        var out = [];
        for (var i = 0; i < p.branchCount; i++) {
            var r = p.rowAt(i);
            out.push({ kind: r.kind, name: r.name, label: r.label,
                       peer: r.peer, head: r.head, section: r.section });
        }
        return out;
    }

    TestCase {
        name: "BranchGrouping"
        when: windowShown

        // ---- the repository default ---------------------------------------
        //
        // THE regression this redesign exists for. `list_branches` returns only
        // per-peer entries, but the view renders `refs/heads/<default>` — a
        // delegate-consensus ref that is a different ref from any peer's
        // same-named branch. On a repo where the user owns no branches, the
        // current branch was therefore not in the list, nothing matched, and
        // the closed control rendered COMPLETELY BLANK.

        function test_the_repository_default_is_pinned_first() {
            var r = rows(picker);
            verify(r.length > 0, "expected rows");
            compare(r[0].kind, "default", "the default is the first row");
            compare(r[0].name, "main");
        }

        function test_a_repo_with_no_branches_of_your_own_still_shows_a_branch() {
            // peersOnlyPicker owns nothing; before the pinned default this
            // showed an empty chip.
            verify(peersOnlyPicker.displayLabel !== "",
                   "the closed control must never be blank: got \""
                   + peersOnlyPicker.displayLabel + "\"");
            compare(peersOnlyPicker.displayLabel, "main");
        }

        // The pinned default and a peer's same-named branch are DIFFERENT
        // refs that can point at different commits. Collapsing them is the
        // "wrong branch's files under the right branch's name" failure.
        function test_the_default_and_a_peers_same_named_branch_are_distinct() {
            var r = rows(picker);
            var def = null, peerMain = null;
            for (var i = 0; i < r.length; i++) {
                if (r[i].kind === "default") def = r[i];
                if (r[i].name === "z6MkPeerTwo/main") peerMain = r[i];
            }
            verify(def !== null, "expected the pinned default");
            verify(peerMain !== null, "expected the peer's main");
            verify(def.name !== peerMain.name,
                   "they must select different values: " + def.name
                   + " vs " + peerMain.name);
        }

        // ---- peer grouping -------------------------------------------------

        function test_the_node_id_is_not_repeated_on_every_row() {
            var r = rows(picker);
            for (var i = 0; i < r.length; i++) {
                if (r[i].kind !== "branch") continue;
                verify(r[i].label.indexOf("z6Mk") !== 0,
                       "a row label must not lead with a node id — that "
                       + "belongs in the section header: " + r[i].label);
            }
        }

        function test_a_peer_branch_is_sectioned_by_its_peer() {
            var r = rows(picker);
            var found = null;
            for (var i = 0; i < r.length; i++)
                if (r[i].name === "z6MkPeerOne/aaa") found = r[i];
            verify(found !== null, "expected the peer branch");
            compare(found.label, "aaa", "the row shows the bare branch name");
            verify(found.section !== "" && found.section !== "your node",
                   "and is grouped under its peer: " + found.section);
        }

        function test_your_own_branches_are_sectioned_as_yours() {
            var r = rows(picker);
            var found = null;
            for (var i = 0; i < r.length; i++)
                if (r[i].name === "zzz") found = r[i];
            verify(found !== null, "expected the local branch");
            compare(found.section, "your node",
                    "your own key is not shown back to you");
        }

        // The slash is not the signal — `remote`/`isLocal` are. A local branch
        // whose name contains a slash keeps its whole name.
        function test_a_slashed_local_branch_keeps_its_name() {
            var r = rows(picker);
            var found = null;
            for (var i = 0; i < r.length; i++)
                if (r[i].name === "feature/login") found = r[i];
            verify(found !== null, "expected the slashed local branch");
            compare(found.label, "feature/login",
                    "nothing may be stripped from a local branch's name");
            compare(found.section, "your node");
        }

        function test_every_branch_survives_the_grouping() {
            var r = rows(picker);
            var names = [];
            for (var i = 0; i < r.length; i++) names.push(r[i].name);
            // 5 from the reply + the pinned default.
            compare(names.length, 6, "got " + names);
            verify(names.indexOf("feature/login") >= 0, "local slashed: " + names);
            verify(names.indexOf("z6MkPeerOne/aaa") >= 0, "peer aaa: " + names);
            verify(names.indexOf("z6MkPeerTwo/main") >= 0, "peer main: " + names);
        }

        // ---- the seed source must be untouched ------------------------------

        function test_a_seed_reply_is_not_grouped_by_peer() {
            compare(remotePicker.peerCount, 0,
                    "the seed sends no peer information, so there are no peers");
            compare(remotePicker.hasSeparator, false);
            var r = rows(remotePicker);
            for (var i = 0; i < r.length; i++)
                verify(r[i].section === "" || r[i].section === "branches",
                       "no peer sections for a flat reply: " + r[i].section);
        }

        function test_a_seed_reply_still_gets_its_pinned_default() {
            compare(remotePicker.displayLabel, "main");
            compare(rows(remotePicker)[0].kind, "default");
        }

        // ---- the cases that are not a dropdown ------------------------------

        // A dropdown holding one already-selected item offers no choice. 5 of
        // 9 repos on a real node are in this state.
        function test_a_single_branch_repo_is_not_interactive() {
            compare(soloPicker.branchCount, 1, "just the default");
            compare(soloPicker.interactive, false,
                    "no chevron, no popup — it is a label");
            compare(soloPicker.displayLabel, "main");
        }

        function test_a_multi_branch_repo_is_interactive() {
            compare(picker.interactive, true);
        }

        // ---- filtering -------------------------------------------------------

        function test_the_filter_narrows_to_matching_branches() {
            manyPicker.filterText = "branch-1";
            // branch-1, branch-10, branch-11
            verify(manyPicker.visibleCount > 0, "expected matches");
            verify(manyPicker.visibleCount < manyPicker.branchCount,
                   "and fewer than everything: " + manyPicker.visibleCount
                   + " of " + manyPicker.branchCount);
            manyPicker.filterText = "";
        }

        // The node id is searchable even though it is not on any row — that is
        // what makes hoisting it into the header lossless.
        function test_the_filter_matches_the_peer_section_too() {
            manyPicker.filterText = "PeerOne";
            verify(manyPicker.visibleCount > 0,
                   "typing a peer id should narrow to that peer's branches");
            manyPicker.filterText = "";
        }

        function test_a_filter_matching_nothing_reports_zero() {
            manyPicker.filterText = "no-such-branch-anywhere";
            compare(manyPicker.visibleCount, 0);
            manyPicker.filterText = "";
        }

        function test_clearing_the_filter_restores_every_row() {
            var before = manyPicker.branchCount;
            manyPicker.filterText = "branch-1";
            manyPicker.filterText = "";
            compare(manyPicker.visibleCount, before,
                    "filtering must not destroy the underlying list");
        }

        // The filter is offered only when scanning is hard; below the
        // threshold it is furniture. Same rule for both sources.
        function test_search_is_offered_only_for_long_lists() {
            verify(manyPicker.searchable,
                   "13 branches should offer a filter");
            verify(!picker.searchable,
                   "6 branches should not");
            verify(!remotePicker.searchable,
                   "and neither should a small seed repo");
        }

        // ---- selection --------------------------------------------------------

        function test_choosing_a_row_emits_its_qualified_name() {
            var seen = [];
            function grab(name) { seen.push(name); }
            picker.branchChosen.connect(grab);
            picker.selectByIndex(indexOfName(picker, "z6MkPeerOne/aaa"));
            picker.branchChosen.disconnect(grab);

            compare(seen.length, 1, "expected one signal");
            compare(seen[0], "z6MkPeerOne/aaa",
                    "the QUALIFIED name is emitted, not the displayed label — "
                    + "every downstream read is keyed on it");
        }

        function test_choosing_the_current_branch_emits_nothing() {
            var seen = [];
            function grab(name) { seen.push(name); }
            picker.branchChosen.connect(grab);
            picker.selectByIndex(indexOfName(picker, "main"));
            picker.branchChosen.disconnect(grab);
            compare(seen.length, 0, "already on it");
        }

        function indexOfName(p, name) {
            for (var i = 0; i < p.visibleCount; i++)
                if (p.visibleRowAt(i).name === name) return i;
            return -1;
        }

        // ---- switching repos ---------------------------------------------------

        function test_switching_repos_rebuilds_the_grouping() {
            var reply = localReply;
            var p = Qt.createQmlObject(
                'import "../src/qml" as Ui; Ui.BranchPicker { rid: "rad:zA" }',
                harness);
            p.fetchBranches = function (cb) { cb(reply); };
            verify(p.peerCount > 0, "the first repo has peers");

            reply = remoteReply;
            p.rid = "rad:zB";

            compare(p.peerCount, 0,
                    "peer grouping must not survive a switch to a flat repo");
            p.destroy();
        }
    }
}
