import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

/*
 * One repository: source tree, commits, issues and patches.
 *
 * Chrome (header + tab bar) has fixed heights from Theme, so switching tabs
 * changes only the content area — the header never moves.
 */
Item {
    id: page

    // Placed directly in Main.qml's StackLayout. A plain Item has no
    // implicit size, so without these the layout hands it 0x0 and every
    // row draws at y=0 — the whole view collapses onto one line.
    Layout.fillWidth: true
    Layout.fillHeight: true

    property var app: null
    property string rid: ""
    property var repo: null
    /// True while this page is the visible one; gates lazy tab loading.
    property bool active: false

    signal back()

    readonly property var meta: repo ? R.projectMeta(repo) : ({})
    readonly property string defaultBranch: repo ? (R.project(repo).defaultBranch || "") : ""

    /// The branch Source and Commits are currently showing. Starts out bound
    /// to defaultBranch; picking a branch (see BranchPicker below) replaces
    /// that binding with a plain value, and onRidChanged restores it (see
    /// there) so a new repository does not inherit the old one's pick.
    property string branch: defaultBranch

    property int tab: 0
    property var loadedTabs: ({})

    /// When set, the detail view for one issue or patch replaces the tabs.
    property string openThreadId: ""
    property string openThreadKind: "Issues"
    /// When set, the commit detail view replaces the tabs.
    property string openCommitSha: ""
    /// When true, the new-issue form replaces the tabs.
    property bool composingIssue: false

    /// Positions of the detail views in the StackLayout below, named so that
    /// inserting a tab cannot silently point currentIndex at the wrong child.
    readonly property int threadIndex: 4
    readonly property int commitIndex: 5
    readonly property int newIssueIndex: 6

    /// True while any detail view is covering the tabs.
    readonly property bool showingDetail: openThreadId !== "" || openCommitSha !== ""
                                          || composingIssue

    /// Whether the comment box is on screen. Re-exported for the UI specs,
    /// which cannot reach into a StackLayout child by id — and this is the one
    /// piece of state worth asserting from outside, because "the box appeared
    /// when it should not have" is the failure that loses a user's text.
    readonly property bool composerVisible: thread.commentable

    /// Whether the "New issue" button is offered, and whether its form is up.
    /// Same reasoning as composerVisible: the failure worth catching from
    /// outside is the affordance appearing where it cannot work.
    readonly property bool canCreateIssue: newIssueButton.visible
    readonly property bool newIssueOpen: composingIssue

    /// How many comments the open thread shows, and the composer itself — both
    /// re-exported for tests/ui/write.yaml. See ThreadView, where they are
    /// defined and where the reasoning lives.
    readonly property int threadCommentCount: thread.commentCount
    readonly property var composerItem: thread.composerItem
    /// The new-issue form, for the same reason as composerItem: sitometres has
    /// no typing verb, so a spec fills the fields through the item and then
    /// clicks the REAL submit button.
    readonly property var newIssueFormItem: newIssue

    /// State the end-to-end UI specs assert on. Kept here, and re-exported by
    /// Main.qml, because a spec's `state:` expressions evaluate against the
    /// app's QML root and cannot reach into a StackLayout child by id.
    ///
    /// These are readonly aliases of state that already exists; nothing here
    /// is a second implementation of anything, so a spec asserting on them is
    /// asserting on what the UI itself uses.
    readonly property int treeCount:   source.entryCount
    readonly property int commitCount: commits.count
    readonly property int issueCount:  issues.count
    readonly property int patchCount:  patches.count
    /// Which state filter the Patches tab is on ("open"/"merged"/…).
    readonly property string patchStatus: patches.status

    // ---- source tab / sync ----
    readonly property bool   syncing:         source.syncing
    readonly property real   syncProgress:    source.syncProgress
    readonly property bool   syncedOnce:      source.syncedOnce
    readonly property bool   updateAvailable: syncButton.updateAvailable
    /// The sync button's label, read off the Text item that actually renders
    /// it rather than recomputed from the same inputs. Recomputing would let a
    /// spec assert "the label says Re-sync" and still pass with the button's
    /// own binding deleted — the assertion would be checking a copy of the
    /// logic instead of the button.
    readonly property string syncLabel: syncLabelText.text
    /// The SourceTab itself, so an end-to-end spec can reach the real
    /// `lastSyncedCommit` and the real `checkForUpdate()`.
    ///
    /// The "Update" state is only reachable when the branch head has moved
    /// past the commit captured at the last sync, which cannot be arranged
    /// against a public repository on demand. Rather than add a test-only
    /// hook that fakes the outcome, the spec sets the real property the real
    /// comparison reads and then calls the real poll — so the request, the
    /// parse, the comparison and the re-label are all genuinely exercised.
    readonly property var sourceTabItem: source
    /// Directory the file tree is showing; "" is the repository root.
    readonly property string treePath:        source.path
    /// Path of the file open in the viewer; "" while the README is showing.
    readonly property string selectedFile:    source.selectedFile
    /// What the viewer pane is titled — the README's path until a file is
    /// clicked, then that file's path.
    readonly property string fileTitle:       source.viewerTitle
    /// Length rather than the text itself: a spec only needs to know that
    /// content arrived, and a whole blob in a report is noise.
    readonly property int    fileBodyLength:  source.viewerBodyLength

    // ---- branch ----
    /// Selectable branches. Deliberately the picker's `branchCount`, not its
    /// `count`: in local mode the model also holds a local/peer divider row,
    /// which is not a branch anyone can pick.
    readonly property int    branchCount:  branchPicker.branchCount
    /// Whether the list is split into "this node's" and "other peers'".
    readonly property bool   branchesGrouped: branchPicker.hasSeparator
    readonly property string branchLabel:  branchPicker.displayText
    /// The picker itself, so an end-to-end spec can emit its `activated`
    /// signal — which is exactly what a click on a popup delegate emits.
    ///
    /// A ComboBox's list lives in a Popup, i.e. a separate window, and the
    /// inspector's snapshot is scoped to the app's own item tree, so those
    /// delegates cannot be addressed by objectName the way every other
    /// control here can. Emitting the real signal keeps `onActivated` — the
    /// handler under test — in the path; assigning `branch` directly would
    /// skip it and prove nothing about the picker.
    readonly property var branchPickerItem: branchPicker

    /// True while a detail view (issue/patch thread, or a commit) covers the
    /// tabs — the spec's way of asserting a row click actually opened it.
    readonly property string openThread: openThreadId
    readonly property string openCommit: openCommitSha

    onRidChanged: {
        tab = 0;
        loadedTabs = ({});
        // Re-bind to the new repo's default branch. A plain assignment
        // (branch = defaultBranch) would only copy today's value and leave
        // `branch` a dead literal from then on; Qt.binding restores the live
        // binding declared above, so a repo picked before its own repo
        // object (and therefore defaultBranch) has arrived still ends up on
        // the right branch once it does. Without this, picking a non-default
        // branch on one repository and then opening a different one carried
        // the old repo's branch NAME into the new repo — silently wrong
        // rather than merely stale, since two repos rarely share branch
        // names on purpose.
        branch = Qt.binding(function () { return page.defaultBranch; });
        // Drop every tab's contents up front. Without this, switching repos
        // left the previous repo's commits/issues/patches on screen under the
        // new repo's header until each tab was re-opened.
        openThreadId = "";
        openCommitSha = "";
        // A half-written issue belongs to the repository it was written
        // against. Leaving the form up across a repo switch would let it be
        // filed against a different repo than the one the user was looking at
        // when they started typing.
        composingIssue = false;
        newIssue.reset();
        source.reset();
        commits.reset();
        issues.reset();
        patches.reset();
        branchPicker.rid = rid;
        maybeLoad();
    }

    onBranchChanged: {
        // Same principle as switching repository, one level down: the
        // previously loaded tree/commits belong to the OLD branch and must
        // not linger on screen — or worse, look current — while the new
        // branch's data is in flight. Only source (tab 0) and commits
        // (tab 1) are branch-scoped — issues and patches are repository-wide
        // COBs with no branch concept — so only their loadedTabs entries are
        // cleared, and only they refetch. Clearing all four would refetch
        // issues/patches for no reason on every branch switch.
        // Rebuilt as a NEW object rather than mutated with `delete
        // loadedTabs[0]`. `loadedTabs` is a `property var`, and an in-place
        // delete on one does not reliably write back through the property —
        // the entries survived, loadTab() below took its early return, and
        // switching branch silently left the OLD branch's tree and commits on
        // screen with no refetch at all. onRidChanged has always reassigned
        // the whole object (loadedTabs = ({})), which is why the repository
        // switch worked while the branch switch did not.
        var keep = ({});
        for (var k in loadedTabs)
            if (k !== "0" && k !== "1" && loadedTabs[k]) keep[k] = true;
        loadedTabs = keep;
        source.reset();
        commits.reset();
        // Reload on the next event-loop turn, NOT synchronously here.
        //
        // SourceTab.branch and CommitsTab.branch are bindings to this
        // property. Inside this handler those bindings have not been
        // re-evaluated yet, so calling maybeLoad() directly made the two tabs
        // refetch using the branch they were ALREADY on — the request went out
        // for the old branch, its reply repopulated the pane, and switching
        // branch appeared to do nothing at all. Deferring by one turn lets the
        // bindings settle so the refetch asks for the branch just picked.
        branchReload.restart();
    }

    /// Drives onBranchChanged's reload one event-loop turn later, so the
    /// branch bindings on SourceTab/CommitsTab have been re-evaluated before
    /// either is asked to fetch. See onBranchChanged for what went wrong when
    /// this was a direct call.
    Timer {
        id: branchReload
        interval: 0
        repeat: false
        onTriggered: maybeLoad()
    }

    // The page can receive a rid before it becomes visible, and `active` can
    // flip before the rid arrives. Load on whichever happens last.
    onActiveChanged: maybeLoad()
    onTabChanged: maybeLoad()

    function maybeLoad() {
        if (active && rid !== "") loadTab(tab);
    }

    // Tabs fetch on first view rather than all at once, so opening a repo
    // costs one request instead of four.
    function loadTab(index) {
        if (rid === "" || loadedTabs[index]) return;
        loadedTabs[index] = true;
        if (index === 0)      source.load();
        else if (index === 1) commits.load();
        else if (index === 2) issues.load();
        else if (index === 3) patches.load();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- header (fixed height) ----
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.headerHeight
            color: Theme.surface

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.gap
                spacing: Theme.gap

                Rectangle {
                    Layout.preferredWidth: 68
                    Layout.preferredHeight: 28
                    radius: Theme.radius
                    color: backMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                    border.color: Theme.border
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: Theme.animFast } }

                    Text {
                        anchors.centerIn: parent
                        text: "‹  Back"
                        color: Theme.text
                        font.pixelSize: Theme.fontMd
                    }
                    MouseArea {
                        id: backMouse
                        // Same move as syncButton below. This one HAPPENED to
                        // work from the Rectangle — the back button is the
                        // first handler in the header, so the ancestor search
                        // landed on it by luck — but it was one reordering
                        // away from the same silent misfire, and relying on
                        // sibling order for which control a click hits is not
                        // something to leave in place once it is understood.
                        objectName: "backButton"
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.back()
                    }
                }

                Avatar { seed: page.rid; size: 30; Layout.alignment: Qt.AlignVCenter }

                ColumnLayout {
                    spacing: 1
                    Layout.fillWidth: true

                    Text {
                        text: page.repo ? R.repoName(page.repo) : ""
                        color: Theme.text
                        font.pixelSize: Theme.fontLg
                        font.bold: true
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        text: page.rid
                        color: Theme.textFaint
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.mono
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                    }
                }

                // Sync: pull the whole repository into the local cache so
                // browsing afterwards needs no further requests.
                //
                // Shown ONLY for the remote source, and the test is positive
                // (`=== "remote"`) rather than "not local" on purpose. Caching
                // is worth doing exactly when the data is behind a network
                // round trip; every other source reads storage this machine
                // already has, so a new one — an embedded node, say — should
                // inherit "no sync button" by default rather than silently
                // acquire one that copies local files into a cache of
                // themselves. Adding a source must not require remembering to
                // come back here.
                //
                // Hidden rather than disabled, the same reasoning as the
                // toggle's own local segment: a control that can only do
                // something pointless reads as a broken feature.
                Rectangle {
                    id: syncButton
                    visible: page.app && page.app.source === "remote"
                    // "Update available" is a colour/label change only — the
                    // button stays exactly as clickable as always. Re-syncing
                    // is never wrong, just sometimes unnecessary, so this
                    // must never gate onClicked below.
                    readonly property bool updateAvailable:
                        !source.syncing && source.updateAvailable
                    Layout.preferredWidth: 92
                    Layout.preferredHeight: 26
                    radius: Theme.radius
                    color: syncMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                    border.color: source.syncing ? Theme.accent
                                : updateAvailable  ? Theme.warn
                                                    : Theme.border
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: Theme.animFast } }

                    // Fills left-to-right as files are fetched.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * source.syncProgress
                        radius: Theme.radius
                        visible: source.syncing
                        color: Qt.rgba(0.35, 0.65, 1.0, 0.18)
                    }

                    Text {
                        id: syncLabelText
                        objectName: "syncLabel"
                        anchors.centerIn: parent
                        text: source.syncing
                              ? Math.round(source.syncProgress * 100) + "%"
                              : (syncButton.updateAvailable ? "Update"
                                 : source.syncedOnce         ? "Re-sync"
                                                              : "Download All")
                        color: source.syncing ? Theme.accent
                             : syncButton.updateAvailable ? Theme.warn
                                                           : Theme.text
                        font.pixelSize: Theme.fontMd
                    }

                    MouseArea {
                        id: syncMouse
                        // On the MouseArea, not the Rectangle above — and this
                        // one was not merely unaddressable but actively
                        // dangerous.
                        //
                        // A selector resolves a non-clickable node by climbing
                        // to a clickable ancestor, then by searching each
                        // ancestor's DESCENDANTS for a mouse handler — never
                        // the node's own. The sync button's nearest ancestor
                        // is the header RowLayout, whose first handler in tree
                        // order belongs to the BACK BUTTON. So a spec clicking
                        // "syncButton" reported a successful click and
                        // navigated to the repository list instead, which read
                        // as "the sync never started".
                        objectName: "syncButton"
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: source.syncing ? source.cancelSync() : source.syncAll()
                    }

                    ToolTip.visible: syncMouse.containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: source.syncing
                                  ? "Cancel — " + source.syncDone + " of "
                                    + source.syncQueued + " fetched"
                                  : syncButton.updateAvailable
                                    ? "The remote has new commits — re-sync to fetch them"
                                    : (source.syncedOnce
                                       ? "Re-download every file to refresh the local cache"
                                       : "Download every file so browsing is instant")
                }

                // Branch picker: which branch Source and Commits show.
                BranchPicker {
                    id: branchPicker
                    objectName: "branchPicker"
                    Layout.alignment: Qt.AlignVCenter
                    visible: page.rid !== ""
                    currentBranch: page.branch
                    fetchBranches: function (cb) {
                        if (!page.app || page.rid === "") return;
                        page.app.call("ListBranches", [page.rid], cb);
                    }
                    onBranchChosen: function (name) { page.branch = name; }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.border
            }
        }

        // ---- tabs (fixed height) ----
        // Layout.maximumHeight is load-bearing, not belt-and-braces. A
        // RowLayout whose child asks for Layout.fillHeight reports an
        // unbounded maximum of its own, so the ColumnLayout above honoured
        // fillHeight over preferredHeight and grew this strip to fill the
        // page — leaving the StackLayout below it 15px. The tabs still drew
        // and the tree still loaded, so the only visible symptom was that
        // clicking a file row reached nothing.
        RowLayout {
            Layout.fillWidth: true
            visible: !page.showingDetail
            Layout.preferredHeight: visible ? Theme.tabHeight : 0
            Layout.maximumHeight: visible ? Theme.tabHeight : 0
            spacing: 0

            SectionTabs {
                Layout.fillWidth: true
                Layout.fillHeight: true
                current: page.tab
                tabs: [
                    { label: "Source",  count: -1 },
                    { label: "Commits", count: -1 },
                    { label: "Issues",  count: page.meta.issues  ? page.meta.issues.open  : -1 },
                    { label: "Patches", count: page.meta.patches ? page.meta.patches.open : -1 }
                ]
                onPicked: function (i) { page.tab = i; }
            }

            // ---- New issue ----
            // Offered only on the Issues tab, only while browsing the local
            // source, and only when a write could actually succeed. The last
            // of those three is the one that matters: `canWrite` is a real
            // probe for a signing key, and a button that opens a form whose
            // submit cannot work would waste whatever the user typed into it.
            //
            // The source check is not defensive duplication of the backend's
            // refusal — a repo open from a seed may not exist in local storage
            // at all, so there would be nothing to file against.
            Rectangle {
                id: newIssueButton
                visible: page.tab === 2
                         && page.app !== null
                         && page.app.source === "local"
                         && page.app.canWrite
                Layout.preferredWidth: visible ? 104 : 0
                Layout.preferredHeight: 28
                Layout.rightMargin: visible ? Theme.gap : 0
                Layout.alignment: Qt.AlignVCenter
                radius: Theme.radius
                color: newIssueMouse.containsMouse ? Theme.accent : Theme.accentSoft

                Text {
                    anchors.centerIn: parent
                    text: "New issue"
                    color: Theme.textOnAccent
                    font.pixelSize: Theme.fontMd
                    font.bold: true
                }

                MouseArea {
                    id: newIssueMouse
                    // On the MouseArea, not the Rectangle — see backButton
                    // above for why naming the parent makes which control a
                    // click reaches depend on sibling order.
                    objectName: "newIssueButton"
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: page.composingIssue = true
                }
            }
        }

        // ---- content ----
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Detail views replace the tab bodies rather than sitting beside
            // them, so the repository header above stays put. The indices are
            // named rather than written as literals: inserting a tab used to
            // silently point the detail view at the wrong child.
            currentIndex: page.composingIssue ? page.newIssueIndex
                        : page.openThreadId !== "" ? page.threadIndex
                        : page.openCommitSha !== "" ? page.commitIndex
                        : page.tab

            SourceTab  { id: source;  app: page.app; rid: page.rid; branch: page.branch }

            CommitsTab {
                id: commits
                app: page.app
                rid: page.rid
                branch: page.branch
                onCommitActivated: function (sha) { page.openCommitSha = sha; }
            }

            IssuesTab {
                id: issues
                app: page.app
                rid: page.rid
                onItemActivated: function (id) {
                    page.openThreadKind = "Issues";
                    page.openThreadId = id;
                }
            }

            PatchesTab {
                id: patches
                app: page.app
                rid: page.rid
                onItemActivated: function (id) {
                    page.openThreadKind = "Patches";
                    page.openThreadId = id;
                }
            }

            ThreadView {
                id: thread
                app: page.app
                rid: page.rid
                kind: page.openThreadKind
                itemId: page.openThreadId
                // Read off `app` rather than threaded through RepoView as two
                // more properties: nothing between here and Main.qml has an
                // opinion about them, and a pass-through property that only
                // ever forwards is a place for the two to drift apart.
                canWrite: page.app ? page.app.canWrite : false
                writeUnavailableReason: page.app ? page.app.writeUnavailableReason : ""
                onBack: page.openThreadId = ""
            }

            CommitView {
                app: page.app
                rid: page.rid
                sha: page.openCommitSha
                onBack: page.openCommitSha = ""
            }

            NewIssueForm {
                id: newIssue
                objectName: "newIssueForm"
                app: page.app
                rid: page.rid
                canWrite: page.app ? page.app.canWrite : false
                unavailableReason: page.app ? page.app.writeUnavailableReason : ""

                onCancelled: {
                    page.composingIssue = false;
                    newIssue.reset();
                }

                onCreated: function (id) {
                    page.composingIssue = false;

                    // Drop the cached page before reloading. IssuesTab is
                    // cache-first, so a plain load() would serve the list from
                    // before the create and the new issue would simply not be
                    // there — a "working" screen showing stale data, which is
                    // the failure mode this codebase keeps re-learning.
                    issues.reset();
                    issues.load();

                    // Open what was just created, so the user lands on their
                    // issue rather than hunting for it in the list.
                    if (id !== "") {
                        page.openThreadKind = "Issues";
                        page.openThreadId = id;
                    }
                }
            }
        }
    }
}
