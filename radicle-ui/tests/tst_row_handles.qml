import QtQuick
import QtTest
import "../src/qml" as Ui

/*
 * Every list row's objectName sits on the row's own MouseArea.
 *
 * This is not a style rule — it is what makes rows addressable by an
 * end-to-end spec at all, and getting it wrong fails in a way that reads as
 * the spec's fault rather than the app's.
 *
 * How it fails: sitometres resolves a selector to something clickable. A node
 * that is not itself clickable is resolved by climbing to a clickable
 * ANCESTOR, and failing that by searching each ancestor's descendants for a
 * mouse handler. A list delegate has no clickable ancestor, so EVERY row
 * climbs to the shared ListView and finds the same first MouseArea. The
 * matches then deduplicate onto that one target, and the whole list collapses
 * to a single addressable element:
 *
 *     nth: 1 is out of range — objectName "repoRow" matched 1 element(s)
 *
 * That is exactly what `repoRow` did. It had been declared on the delegate
 * Rectangle, so browse.yaml's `repoRow, nth: 0` worked by accident (index 0 of
 * one match) and no spec could ever open the SECOND repository — which is what
 * a branch-switching spec needs, to prove a branch picked on one repository
 * does not leak into another.
 *
 * SectionTabs.qml had already hit this and documents it at the site; the rule
 * was recorded in CLAUDE.md and then not applied to the other lists. So this
 * test asserts the rule itself across every row type, rather than pinning the
 * one instance that was found broken.
 *
 * The check is "the node carrying the name is a MouseArea", which is the
 * property that makes resolution find one target per row. Asserting the
 * resolver's own deduplication would mean reimplementing it here.
 */
Item {
    id: root
    width: 900
    height: 700

    function call(method, args, onOk, onFail) {
        if (method === "ListRepos")
            onOk({ items: [{ rid: "rad:zA", payload: { "xyz.radicle.project":
                              { data: { name: "one", defaultBranch: "main" } } } },
                           { rid: "rad:zB", payload: { "xyz.radicle.project":
                              { data: { name: "two", defaultBranch: "main" } } } }],
                   hasMore: false });
        else if (method === "ListIssues" || method === "ListPatches")
            onOk({ items: [{ id: "i1", title: "One", state: { status: "open" },
                             author: { alias: "someone" } },
                           { id: "i2", title: "Two", state: { status: "open" },
                             author: { alias: "someone" } }],
                   hasMore: false });
        else if (method === "ListCommits")
            onOk({ items: [{ id: "0123456789abcdef0123456789abcdef01234567",
                             summary: "One", author: { name: "A" },
                             committer: { time: 1700000000 } },
                           { id: "89abcdef0123456789abcdef0123456789abcdef",
                             summary: "Two", author: { name: "B" },
                             committer: { time: 1700000001 } }],
                   hasMore: false });
        else if (method === "GetTree")
            onOk({ entries: [{ name: "src",       kind: "tree", path: "src" },
                             { name: "README.md", kind: "blob", path: "README.md" }] });
        else if (method === "GetReadme")
            onOk({ path: "README.md", content: "hello" });
        else if (method === "GetIssue" || method === "GetPatch")
            onOk({ id: "i1", title: "One", state: { status: "open" },
                   author: { alias: "someone" }, discussion: [] });
        else if (method === "GetCommit")
            onOk({ commit: { id: "0123456789abcdef0123456789abcdef01234567",
                             summary: "One", author: { name: "A" },
                             committer: { time: 1700000000 } },
                   diff: { files: [] } });
        else if (method === "ListBranches")
            onOk({ items: [{ name: "main", head: "abc" }] });
        else onOk({ items: [], hasMore: false });
    }

    Ui.RepoList  { id: repos;   anchors.fill: parent; app: parent }
    Ui.IssuesTab { id: issues;  anchors.fill: parent; app: parent; rid: "rad:zTEST" }
    Ui.CommitsTab { id: commits; anchors.fill: parent; app: parent
                    rid: "rad:zTEST"; branch: "main" }
    Ui.PatchesTab { id: patches; anchors.fill: parent; app: parent; rid: "rad:zTEST" }
    Ui.SourceTab  { id: source;  anchors.fill: parent; app: parent
                    rid: "rad:zTEST"; branch: "main" }

    // The single buttons live on these three. Given an explicit size of their
    // own rather than anchors.fill, and parented into a separate container, so
    // they cannot perturb the layout the list components above are realising
    // their delegates into — sharing `parent` with them made every ListView
    // size to zero and render no rows at all.
    Item {
        width: 900
        height: 700
        Ui.RepoView   { id: repoView; width: 900; height: 700
                        app: root }
        Ui.ThreadView { id: thread;   width: 900; height: 700
                        app: root; rid: "rad:zTEST"; kind: "Issues"; itemId: "i1" }
        Ui.CommitView { id: commit;   width: 900; height: 700
                        app: root; rid: "rad:zTEST"
                        sha: "0123456789abcdef0123456789abcdef01234567" }
    }

    /// Every descendant carrying `name` as its objectName.
    function findAllByName(node, name, out) {
        if (!node) return out;
        if (node.objectName === name) out.push(node);
        for (var i = 0; i < node.children.length; i++)
            findAllByName(node.children[i], name, out);
        return out;
    }

    TestCase {
        name: "RowHandlesAreOnTheClickableElement"
        when: windowShown

        /// A row handle must be declared on a MouseArea. See the file comment:
        /// on any other element, every row in the list resolves to the same
        /// click target and only one of them is addressable.
        function check(container, name, expectedRows) {
            var found = findAllByName(container, name, []);
            compare(found.length, expectedRows,
                    name + ": expected one element per row");
            for (var i = 0; i < found.length; i++) {
                // A MouseArea reports itself as such; a Rectangle or Item does
                // not. This is the property the selector's clickability test
                // keys on.
                verify(found[i] instanceof Object,
                       name + ": row " + i + " is not an object");
                verify(found[i].hasOwnProperty("containsMouse"),
                       name + ": row " + i + " carries the objectName but is a "
                       + "non-clickable element — put it on the row's MouseArea "
                       + "(see this file's comment for why)");
            }
        }

        function test_repo_rows_are_addressable_one_per_row() {
            repos.reload();
            wait(50);
            // The regression: repoRow used to sit on the delegate Rectangle,
            // so a spec could reach row 0 only, and `nth: 1` reported "out of
            // range — matched 1 element".
            check(repos, "repoRow", 2);
        }

        function test_issue_rows_are_addressable_one_per_row() {
            issues.load();
            wait(50);
            check(issues, "threadRow", 2);
        }

        function test_patch_rows_are_addressable_one_per_row() {
            patches.load();
            wait(50);
            check(patches, "threadRow", 2);
        }

        function test_commit_rows_are_addressable_one_per_row() {
            commits.load();
            wait(50);
            check(commits, "commitRow", 2);
        }

        function test_file_rows_are_addressable_one_per_row() {
            source.load();
            wait(50);
            // fileRow is new with the end-to-end source spec; pinned here so
            // it cannot regress to the delegate the way repoRow had.
            check(source, "fileRow", 2);
        }

        /*
         * The same rule for the single buttons, where getting it wrong is
         * worse than being unaddressable.
         *
         * `syncButton` was declared on its Rectangle. The ancestor search
         * therefore climbed to the header RowLayout and took the FIRST mouse
         * handler under it — the back button's. A spec clicking "syncButton"
         * reported a successful click and navigated to the repository list,
         * so sync.yaml's first attempt failed with "syncing never became
         * true" while the real symptom was that the sync button cannot be
         * clicked by a spec at all.
         *
         * `backButton` had the identical shape and worked only because it
         * happens to be the first handler in that header — correct by sibling
         * order, which is not a property worth relying on.
         */
        function test_single_button_handles_are_on_their_mouse_areas() {
            repoView.rid = "rad:zTEST";
            repoView.active = true;
            wait(50);
            check(repoView, "backButton", 1);
            check(repoView, "syncButton", 1);
        }

        function test_detail_view_back_buttons_are_on_their_mouse_areas() {
            // Both detail views had the same shape as the two above.
            check(thread, "threadBackButton", 1);
            check(commit, "commitBackButton", 1);
        }
    }
}
