import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

/*
 * File tree on the left, README or the selected file on the right.
 *
 * Two things keep this from jumping the way it used to:
 *  - The sidebar is a FIXED width and rows are a FIXED height, so the tree
 *    does not resize itself as names or directory depth change.
 *  - Blob contents are cached and directories are prefetched on hover, so
 *    clicking a file usually paints from cache with no intermediate
 *    empty-then-fill flash.
 */
Item {
    id: tab

    // A StackLayout child: must fill, or it is sized 0x0.
    Layout.fillWidth: true
    Layout.fillHeight: true

    property var app: null
    property string rid: ""
    property string branch: ""

    /// Current directory, "" for the repository root.
    property string path: ""
    property string selectedFile: ""

    /// Caches are keyed by rid + branch + path, never by path alone: a bare
    /// path collides across repositories, which served one repo's README as
    /// another's. Clearing on repo change is not sufficient by itself, because
    /// a reply already in flight lands after the clear.
    property var blobCache: ({})
    property var treeCache: ({})

    /// Keys currently being fetched, so a click during a hover-prefetch does
    /// not start a second identical request.
    property var inFlight: ({})

    function cacheKey(path) {
        return rid + "\u0000" + branch + "\u0000" + path;
    }

    ListModel { id: entries }

    /// Entries in the current directory — read by the UI tests.
    readonly property int entryCount: entries.count

    /// The viewer pane's state, surfaced so RepoView (and through it the
    /// end-to-end specs) can assert on what the right-hand pane is showing
    /// without reaching into a nested id. Aliases, not a second copy: the
    /// viewer remains the only thing that sets them.
    readonly property string viewerTitle: viewer.title
    /// The length, not the text — a spec asks whether content arrived, and a
    /// whole blob pasted into a test report is noise.
    readonly property int viewerBodyLength: viewer.body.length

    /// Sync: walk the whole tree up front and pull every file into the cache,
    /// so navigation afterwards is instant rather than a request per click.
    property bool syncing: false
    /// Bumped whenever a sync starts, is cancelled, or the repository
    /// changes. Every in-flight request carries the epoch it began under and
    /// ignores its own reply once that epoch has moved on.
    property int syncEpoch: 0
    property int syncQueued: 0
    property int syncDone: 0
    // syncQueued grows as the tree is discovered breadth-first, so the raw
    // ratio can drop after a reply whose own children turn out to add more
    // to the denominator than they immediately finish — reported live as
    // the progress bar jumping backwards mid-sync. syncProgress is a ceiling
    // over the raw ratio, updated explicitly (see bumpSyncProgress()) rather
    // than computed inline, so the displayed value only ever advances.
    property real syncProgress: 0

    function bumpSyncProgress() {
        var raw = syncQueued > 0 ? syncDone / syncQueued : 0;
        if (raw > syncProgress) syncProgress = raw;
    }
    /// True once a sync has completed for this repository, so the idle button
    /// label can read "first download" vs "refresh" differently.
    property bool syncedOnce: false

    /// The branch's head commit at the moment the last sync completed, so a
    /// later poll (see checkForUpdate() / pollTimer below) has something to
    /// compare a fresh head against. "" until a sync has completed.
    property string lastSyncedCommit: ""
    /// True once a poll finds the branch's head has moved past
    /// lastSyncedCommit. Deliberately does NOT disable or relabel the sync
    /// button — re-syncing is never wrong, just sometimes unnecessary — it
    /// only flags that one is worth doing. Cleared by any syncAll() the same
    /// tick it starts, since a fresh sync makes the flag's answer moot until
    /// it completes and repolls.
    property bool updateAvailable: false
    /// Bumped on reset() (repo/branch change) and cancelled polls, mirroring
    /// syncEpoch's role for sync requests: a poll reply that lands after the
    /// repository or branch has moved on must not flip updateAvailable for
    /// data nobody is looking at anymore.
    property int pollEpoch: 0

    /// True while a directory listing is in flight.
    property bool treeLoading: false
    /// True once a listing has completed at least once for this repo.
    property bool treeLoaded: false

    /// Drop everything from the previous repository without fetching.
    /// Called when the repo changes, so no stale tree or file is on screen
    /// while the new repo's data is in flight.
    function reset() {
        path = "";
        selectedFile = "";
        blobCache = ({});
        treeCache = ({});
        inFlight = ({});
        entries.clear();
        // Orphan any sync still running for the previous repository, so its
        // replies cannot corrupt the counters of a sync started here.
        syncEpoch++;
        syncing = false;
        syncQueued = 0;
        syncDone = 0;
        syncProgress = 0;
        syncedOnce = false;
        treeLoading = false;
        treeLoaded = false;
        viewer.title = "";
        viewer.body = "";
        viewer.loading = false;
        // Orphan any poll in flight for the previous repository/branch, the
        // same way syncEpoch orphans a running sync's requests above — a
        // reply landing after this reset must not flip updateAvailable for
        // data nobody is looking at anymore.
        pollEpoch++;
        lastSyncedCommit = "";
        updateAvailable = false;
        pendingSyncHead = "";
    }

    function load() {
        // Clear everything from the previous repository BEFORE fetching. The
        // caches are keyed by path only, so carrying them across repos would
        // serve one repo's file under another's name; and leaving the old
        // tree and README on screen made a new repo look like it had the
        // previous one's contents until the replies landed.
        path = "";
        selectedFile = "";
        blobCache = ({});
        treeCache = ({});
        inFlight = ({});
        entries.clear();
        treeLoading = true;
        treeLoaded = false;
        viewer.title = "";
        viewer.body = "";
        viewer.loading = true;

        loadTree("");
        loadReadme();
    }

    function applyEntries(list) {
        entries.clear();
        // Directories first, then files; each alphabetical.
        var sorted = list.slice().sort(function (a, b) {
            if (a.kind !== b.kind) return a.kind === "tree" ? -1 : 1;
            return a.name.localeCompare(b.name);
        });
        for (var i = 0; i < sorted.length; i++)
            entries.append(sorted[i]);
    }

    function loadTree(p) {
        if (!app || rid === "") return;

        var tkey = cacheKey(p);
        if (treeCache[tkey] !== undefined) {
            tab.path = p;
            applyEntries(treeCache[tkey]);
            tab.treeLoading = false;
            tab.treeLoaded = true;
            return;
        }
        tab.treeLoading = true;
        var wantRid = rid;
        app.call("GetTree", [rid, branch, p], function (data) {
            var list = data.entries || [];
            treeCache[tkey] = list;
            // Drop a reply that arrived after the user moved to another repo.
            if (tab.rid !== wantRid) return;
            tab.treeLoading = false;
            tab.treeLoaded = true;
            tab.path = p;
            applyEntries(list);
        }, function () {
            if (tab.rid !== wantRid) return;
            tab.treeLoading = false;
            tab.treeLoaded = true;
        });
    }

    function loadReadme() {
        if (!app || rid === "") return;
        viewer.loading = true;
        var wantRid = rid;
        app.call("GetReadme", [rid, branch], function (data) {
            var path = data.path || "README";
            var body = data.content || "";

            // Cache it under the key GetBlob would use, so clicking the README
            // in the tree is a hit rather than a second fetch. Worth doing even
            // when we do not display it.
            if (data.path && tab.rid === wantRid)
                blobCache[cacheKey(data.path)] = body;

            // Only paint if this reply is still what the user is looking at.
            // Two ways it might not be:
            //   - they moved to another repository, or
            //   - they clicked a file while the README was still in flight.
            // The second is the one that bit: the README landed afterwards and
            // relabelled the pane, leaving the clicked file's contents under
            // "README.md".
            if (tab.rid !== wantRid || tab.selectedFile !== "") return;

            viewer.loading = false;
            viewer.title = path;
            viewer.body = body;
        }, function () {
            if (tab.rid !== wantRid || tab.selectedFile !== "") return;
            // Plenty of repos have no README; not an error worth showing.
            viewer.loading = false;
            viewer.title = "";
            viewer.body = "";
        });
    }

    function openEntry(entry) {
        if (entry.kind === "tree") {
            loadTree(entry.path);
            return;
        }

        tab.selectedFile = entry.path;

        // Retitle immediately so the header names the file being opened, not
        // the one still on screen.
        viewer.title = entry.path;

        var bkey = cacheKey(entry.path);
        var cached = blobCache[bkey];
        if (cached !== undefined) {
            viewer.loading = false;
            viewer.body = cached;
            return;
        }

        // Clear the previous file's text while the new one is in flight.
        // Leaving it up made a slow load look like the wrong file had opened.
        viewer.body = "";
        viewer.loading = true;

        // A hover-prefetch for this same file may already be running; let it
        // finish and paint rather than issuing a duplicate request.
        if (inFlight[bkey]) return;
        inFlight[bkey] = true;

        var wantRid = rid;
        app.call("GetBlob", [rid, branch, entry.path], function (data) {
            var body = data.binary
                     ? "(binary file — " + (data.name || entry.name) + ")"
                     : (data.content || "");
            blobCache[bkey] = body;
            delete inFlight[bkey];
            // Only paint if this is still the file the user wants, in the repo
            // they are still looking at; a slow reply for an earlier click
            // must not overwrite a later one.
            if (tab.rid === wantRid && tab.selectedFile === entry.path) {
                viewer.loading = false;
                viewer.body = body;
            }
        }, function () {
            delete inFlight[bkey];
            if (tab.rid === wantRid && tab.selectedFile === entry.path)
                viewer.loading = false;
        });
    }

    /// Warm the cache for a row the pointer is resting on, so the click that
    /// usually follows paints immediately.
    function prefetch(entry) {
        if (!app || rid === "" || entry.kind === "tree") return;
        var pkey = cacheKey(entry.path);
        if (blobCache[pkey] !== undefined || inFlight[pkey]) return;
        inFlight[pkey] = true;
        var wantRid = rid;
        app.call("GetBlob", [rid, branch, entry.path], function (data) {
            var body = data.binary
                ? "(binary file — " + (data.name || entry.name) + ")"
                : (data.content || "");
            blobCache[pkey] = body;
            delete inFlight[pkey];
            // If the user clicked this file while the prefetch was in flight,
            // the click found no cache entry and started waiting. Nothing else
            // will paint it, so this reply must — otherwise the pane sits on
            // "Loading…" until the file is clicked a second time.
            if (tab.rid === wantRid && tab.selectedFile === entry.path) {
                viewer.loading = false;
                viewer.body = body;
            }
        }, function () { delete inFlight[pkey]; });
    }

    /// Fetch every directory and file in the repository into the local cache.
    /// Directories are walked breadth-first; each blob is fetched once and
    /// stored under the same key an on-demand click would use, so a synced
    /// repo needs no further requests to browse.
    function syncAll() {
        if (!app || rid === "" || syncing) return;
        syncEpoch++;
        syncing = true;
        syncQueued = 0;
        syncDone = 0;
        syncProgress = 0;
        // Whatever prompted this sync, it is about to catch up to the
        // branch's current head — the stale flag from a previous poll no
        // longer means anything the moment fresh data starts arriving.
        updateAvailable = false;

        // Capture the branch's head SHA now, under this sync's own epoch, so
        // finishSyncIfDone() can record it as lastSyncedCommit once the sync
        // actually completes. ListBranches is the same lightweight call
        // checkForUpdate() polls with — one request either way, no dedicated
        // "get branch head" endpoint needed.
        var epoch = syncEpoch;
        app.call("ListBranches", [rid], function (data) {
            if (epoch !== syncEpoch) return;   // sync already abandoned
            var items = (data && data.items) ? data.items : [];
            for (var i = 0; i < items.length; i++) {
                if (items[i].name === branch) { pendingSyncHead = items[i].head || ""; break; }
            }
        }, function () { /* head unknown; lastSyncedCommit stays as-is */ });

        syncDir("", syncEpoch);
    }

    /// Set by syncAll()'s ListBranches lookup, consumed by
    /// finishSyncIfDone(). A plain property rather than a local closure
    /// variable so it survives being read from a different call stack (the
    /// ListBranches reply and the last GetTree/GetBlob reply usually land in
    /// either order).
    property string pendingSyncHead: ""

    function cancelSync() {
        // Bumping the epoch orphans every request already in flight, so their
        // replies cannot touch the counters of a later sync.
        syncEpoch++;
        syncing = false;
    }

    function syncDir(dirPath, epoch) {
        if (!syncing || epoch !== syncEpoch) return;
        syncQueued++;
        var tkey = cacheKey(dirPath);

        var handle = function (list) {
            // Count only while this reply still belongs to the running sync.
            // Counting unconditionally let a previous repository's replies
            // push syncDone past syncQueued, so a fresh sync reported itself
            // finished while it was still fetching.
            if (epoch !== syncEpoch) return;
            syncDone++;
            if (!syncing) return;
            for (var i = 0; i < list.length; i++) {
                var e = list[i];
                if (e.kind === "tree") syncDir(e.path, epoch);
                else                   syncBlob(e, epoch);
            }
            finishSyncIfDone();
        };

        if (treeCache[tkey] !== undefined) {
            handle(treeCache[tkey]);
            return;
        }
        app.call("GetTree", [rid, branch, dirPath], function (data) {
            var list = data.entries || [];
            treeCache[tkey] = list;
            handle(list);
        }, function () {
            if (epoch !== syncEpoch) return;
            syncDone++;
            finishSyncIfDone();
        });
    }

    function syncBlob(entry, epoch) {
        if (!syncing || epoch !== syncEpoch) return;
        var bkey = cacheKey(entry.path);
        if (blobCache[bkey] !== undefined || inFlight[bkey]) return;

        syncQueued++;
        inFlight[bkey] = true;
        app.call("GetBlob", [rid, branch, entry.path], function (data) {
            delete inFlight[bkey];
            // The cache key already carries the rid, so storing a late reply
            // is harmless and saves a refetch; only the counters are epoch
            // sensitive.
            blobCache[bkey] = data.binary
                ? "(binary file — " + (data.name || entry.name) + ")"
                : (data.content || "");
            if (epoch !== syncEpoch) return;
            syncDone++;
            finishSyncIfDone();
        }, function () {
            delete inFlight[bkey];
            if (epoch !== syncEpoch) return;
            syncDone++;
            finishSyncIfDone();
        });
    }

    function finishSyncIfDone() {
        bumpSyncProgress();
        if (syncing && syncDone >= syncQueued) {
            syncing = false;
            syncedOnce = true;
            // pendingSyncHead may still be "" if its ListBranches lookup is
            // slower than every GetTree/GetBlob in the sync (a small repo)
            // or failed outright — lastSyncedCommit then simply stays at
            // whatever it was, and the next poll (or the next sync) gets
            // another chance to record it. Leaving it stale for one cycle is
            // harmless: it can only make updateAvailable fire a little late,
            // never wrongly claim a repo is up to date.
            if (pendingSyncHead !== "") lastSyncedCommit = pendingSyncHead;
        }
    }

    /// Lightweight staleness check: ask what the branch's head is right now
    /// and compare against the commit captured at the last completed sync.
    /// Does NOT fetch the tree or any file — one ListBranches call, the same
    /// one syncAll() itself makes to record lastSyncedCommit in the first
    /// place. Never touches syncing/syncQueued/syncDone: a sync in progress
    /// and a staleness poll are independent questions answered by
    /// independent requests, and the button stays clickable regardless of
    /// either.
    function checkForUpdate() {
        if (!app || rid === "" || lastSyncedCommit === "") return;
        var epoch = pollEpoch;
        var wantRid = rid, wantBranch = branch;
        app.call("ListBranches", [rid], function (data) {
            // Drop a reply for a repository/branch/sync the user has already
            // moved on from — the same guard shape as every other loader
            // here, just against pollEpoch instead of syncEpoch.
            if (epoch !== pollEpoch || tab.rid !== wantRid || tab.branch !== wantBranch) return;
            var items = (data && data.items) ? data.items : [];
            for (var i = 0; i < items.length; i++) {
                if (items[i].name === wantBranch) {
                    tab.updateAvailable = (items[i].head || "") !== lastSyncedCommit;
                    return;
                }
            }
        }, function () { /* transient failure: leave updateAvailable as-is */ });
    }

    /// Polls checkForUpdate() every five minutes while this tab has synced
    /// data to compare against. Deliberately not started until the first
    /// sync completes — polling before there is a lastSyncedCommit to
    /// compare against has nothing to report, and would just be a periodic
    /// no-op request against every repository ever opened, synced or not.
    Timer {
        interval: 5 * 60 * 1000
        running: tab.lastSyncedCommit !== ""
        repeat: true
        onTriggered: tab.checkForUpdate()
    }

    function goUp() {
        var i = path.lastIndexOf("/");
        loadTree(i < 0 ? "" : path.substring(0, i));
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---- tree (fixed width) ----
        Rectangle {
            Layout.preferredWidth: Theme.sidebarWidth
            Layout.minimumWidth: Theme.sidebarWidth
            Layout.maximumWidth: Theme.sidebarWidth
            Layout.fillHeight: true
            color: Theme.surface

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // Breadcrumb (fixed height).
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.rowHeightSm
                    color: Theme.surfaceAlt
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.gapSm
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.gapSm
                        text: tab.path === "" ? "/" : "/" + tab.path
                        color: Theme.textDim
                        font.pixelSize: Theme.fontXs
                        font.family: Theme.mono
                        elide: Text.ElideLeft
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width; height: 1
                        color: Theme.border
                    }
                }

                LoadingState {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: entries.count === 0
                    loading: tab.treeLoading
                    loaded: tab.treeLoaded
                    count: entries.count
                    emptyText: "Empty directory"
                    loadingText: "Loading files…"
                }

                ListView {
                    id: treeList
                    visible: entries.count > 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: entries
                    clip: true
                    spacing: 0
                    cacheBuffer: Theme.rowHeightSm * 40
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    header: Item {
                        width: treeList.width
                        height: tab.path === "" ? 0 : Theme.rowHeightSm
                        visible: tab.path !== ""
                        Rectangle {
                            anchors.fill: parent
                            color: upMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.gapSm
                            text: "../"
                            color: Theme.textDim
                            font.pixelSize: Theme.fontMd
                            font.family: Theme.mono
                        }
                        MouseArea {
                            id: upMouse
                            objectName: "fileUpRow"
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tab.goUp()
                        }
                    }

                    delegate: Rectangle {
                        required property string name
                        required property string kind
                        required property string path

                        readonly property bool selected: tab.selectedFile === path

                        width: treeList.width
                        height: Theme.rowHeightSm
                        color: selected ? Theme.raised
                             : (rowMouse.containsMouse ? Theme.surfaceAlt : "transparent")
                        Behavior on color { ColorAnimation { duration: Theme.animFast } }

                        // Selection marker on the left edge.
                        Rectangle {
                            anchors.left: parent.left
                            width: 2
                            height: parent.height
                            color: parent.selected ? Theme.accent : "transparent"
                        }

                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.gapSm
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.gapSm
                            spacing: Theme.gapSm

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 10
                                text: kind === "tree" ? "▸" : "·"
                                color: kind === "tree" ? Theme.accent : Theme.textFaint
                                font.pixelSize: Theme.fontSm
                            }
                            Text {
                                // Named so a spec can address a row by the
                                // file's NAME and still be sure it hit the
                                // tree: the viewer's title bar shows the same
                                // string once a file is open, and a bare text
                                // selector matched that instead.
                                objectName: "fileRowName"
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 26
                                text: name
                                color: parent.parent.selected ? Theme.text : Theme.textDim
                                font.pixelSize: Theme.fontMd
                                font.family: Theme.mono
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: rowMouse
                            // Named on the MouseArea, not the delegate Rectangle:
                            // UI specs select by objectName AND clickability, and
                            // naming a non-clickable parent matches one element
                            // instead of one per row (see SectionTabs.qml).
                            objectName: "fileRow"
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tab.openEntry({ name: name, kind: kind, path: path })
                            onEntered: prefetchTimer.restart()
                            onExited: prefetchTimer.stop()

                            Timer {
                                id: prefetchTimer
                                interval: 220     // don't fetch on a passing cursor
                                onTriggered: tab.prefetch({ name: rowMouse.parent.name,
                                                            kind: rowMouse.parent.kind,
                                                            path: rowMouse.parent.path })
                            }
                        }
                    }
                }
            }
        }

        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.border }

        // ---- file / readme ----
        FileViewer {
            id: viewer
            Layout.fillWidth: true
            Layout.fillHeight: true
        }
    }
}
