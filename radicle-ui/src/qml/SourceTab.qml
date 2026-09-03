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

    /// Sync: walk the whole tree up front and pull every file into the cache,
    /// so navigation afterwards is instant rather than a request per click.
    property bool syncing: false
    property int syncQueued: 0
    property int syncDone: 0
    readonly property real syncProgress: syncQueued > 0 ? syncDone / syncQueued : 0

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
        syncing = false;
        syncQueued = 0;
        syncDone = 0;
        treeLoading = false;
        treeLoaded = false;
        viewer.title = "";
        viewer.body = "";
        viewer.loading = false;
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
            // A README arriving after the user switched repos belongs to the
            // old one — this is what put radicle.xyz's README under
            // radicle-tui's header.
            if (tab.rid !== wantRid) return;
            var path = data.path || "README";
            var body = data.content || "";
            // Store it under the same key GetBlob would use, so clicking the
            // README in the tree is a cache hit instead of a second fetch.
            if (data.path)
                blobCache[cacheKey(data.path)] = body;
            viewer.loading = false;
            viewer.title = path;
            viewer.body = body;
        }, function () {
            if (tab.rid !== wantRid) return;
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
        syncing = true;
        syncQueued = 0;
        syncDone = 0;
        syncDir("");
    }

    function cancelSync() {
        syncing = false;
    }

    function syncDir(dirPath) {
        if (!syncing) return;
        syncQueued++;
        var wantRid = rid;
        var tkey = cacheKey(dirPath);

        var handle = function (list) {
            syncDone++;
            if (!syncing || tab.rid !== wantRid) return;
            for (var i = 0; i < list.length; i++) {
                var e = list[i];
                if (e.kind === "tree") syncDir(e.path);
                else                   syncBlob(e);
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
        }, function () { syncDone++; finishSyncIfDone(); });
    }

    function syncBlob(entry) {
        if (!syncing) return;
        var bkey = cacheKey(entry.path);
        if (blobCache[bkey] !== undefined || inFlight[bkey]) return;

        syncQueued++;
        inFlight[bkey] = true;
        var wantRid = rid;
        app.call("GetBlob", [rid, branch, entry.path], function (data) {
            delete inFlight[bkey];
            syncDone++;
            if (tab.rid === wantRid) {
                blobCache[bkey] = data.binary
                    ? "(binary file — " + (data.name || entry.name) + ")"
                    : (data.content || "");
            }
            finishSyncIfDone();
        }, function () {
            delete inFlight[bkey];
            syncDone++;
            finishSyncIfDone();
        });
    }

    function finishSyncIfDone() {
        if (syncing && syncDone >= syncQueued) syncing = false;
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
