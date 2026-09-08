import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

/*
 * Repository browser. Under "Any repo" this searches every repo the seed
 * replicates; under "My node" it lists this machine's own repos, private ones
 * included.
 */
Item {
    id: page

    // Placed directly in Main.qml's StackLayout. A plain Item has no
    // implicit size, so without these the layout hands it 0x0 and every
    // row draws at y=0 — the whole view collapses onto one line.
    Layout.fillWidth: true
    Layout.fillHeight: true

    /// Injected by Main.qml: owns backend call routing and source selection.
    property var app: null

    property string query: ""
    property int page_: 0
    property bool hasMore: false
    property bool loading: false
    property bool loadedOnce: false

    signal repoActivated(var repo)

    /// Rows currently listed — read by the UI tests.
    readonly property int count: repos.count

    /// Whether this mode has no node to list at all.
    ///
    /// Keyed on the MODE, not on `app.source`, and that distinction is the
    /// whole fix. `source` is the derived method prefix, and `local` and
    /// `embedded` both derive to `"local"` (see SourceState.qml) — so every
    /// staleness guard in this file, which compares `source`, is blind to the
    /// difference between them. A `localListRepos` reply issued in Local
    /// passes that guard unchanged after a switch to Embedded, and the
    /// ATTACHED node's repositories land under a segment reading "Embedded".
    ///
    /// That is the identity confusion this milestone exists to prevent, and
    /// the backend was already fixed for the same lie once: `storeForSettings()`
    /// used to let `embedded` fall through to the attached profile's home.
    /// This is that lie one layer up, so it is refused the same way — by
    /// naming the mode explicitly rather than inheriting Local's behaviour.
    readonly property bool notImplemented: !!app && app.mode === "embedded"

    ListModel { id: repos }

    function reload() {
        page_ = 0;
        repos.clear();
        loadedOnce = false;
        hasMore = false;
        loading = false;
        fetch();
    }

    function fetch() {
        if (!app) return;
        // Embedded has no node to ask, so it asks nothing. Fetching and then
        // hiding the result is how this bug returns: the reply would still be
        // in flight, would still pass the prefix-based guard below, and would
        // still repopulate the model behind the placeholder.
        if (page.notImplemented) {
            page.loading = false;
            page.hasMore = false;
            return;
        }
        // The first argument means different things per source: a search
        // `query` for the seed, a `scope` ("all"|"delegate"|"private"|
        // "seeded") for the local node. Passing the search box's text as a
        // scope would silently narrow to nothing, so local browsing always
        // asks for "all" and the search field is hidden for it.
        var first = (app.source === "local") ? "all" : page.query;
        var args = [first, page_, 50];
        page.loading = true;

        // Same guard idiom as every other loader in this codebase (see
        // IssuesTab/CommitsTab/ThreadView/CommitView/SourceTab): capture the
        // inputs this request was made for, and drop a reply that no longer
        // matches. reload() (triggered by the source toggle, setSeed(), and
        // Enter in the search field) clears the model and calls fetch()
        // again while a previous fetch() may still be in flight — without
        // this, the old reply's items get appended into the new list.
        //
        // `wantMode` is captured ALONGSIDE `wantSource` rather than instead of
        // it, because they answer different questions and neither implies the
        // other: `source` catches explore<->local (a different backend), and
        // `mode` catches local<->embedded (the same backend, a different node).
        // Capturing only the prefix is what let a Local reply land in Embedded.
        var wantSource = app.source;
        var wantMode = app.mode;
        var wantQuery = page.query;
        var wantPage = page_;
        app.call("ListRepos", args, function (data) {
            if (app.source !== wantSource || app.mode !== wantMode
                || page.query !== wantQuery || page_ !== wantPage)
                return;
            page.loading = false;
            page.loadedOnce = true;
            var items = data.items || [];
            for (var i = 0; i < items.length; i++)
                repos.append({ repo: items[i] });
            page.hasMore = !!data.hasMore;
        }, function () {
            if (app.source !== wantSource || app.mode !== wantMode
                || page.query !== wantQuery || page_ !== wantPage)
                return;
            page.loading = false;
            page.loadedOnce = true;
        });
    }

    ListView {
        id: list
        anchors.fill: parent
        model: repos
        clip: true
        spacing: 0
        // Keep rows alive around the viewport so scrolling does not re-create
        // (and visibly re-lay-out) delegates constantly.
        cacheBuffer: Theme.rowHeight * 12
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
            required property var repo
            required property int index

            width: list.width
            height: Theme.rowHeight
            color: mouse.containsMouse ? Theme.surfaceAlt : Theme.bg
            Behavior on color { ColorAnimation { duration: Theme.animFast } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.gap
                spacing: Theme.gap

                Avatar {
                    seed: repo.rid
                    size: 32
                    Layout.alignment: Qt.AlignVCenter
                }

                // Name + description. Takes all the slack so the stat columns
                // that follow are pushed to a consistent right-hand edge.
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                        spacing: Theme.gapSm
                        Layout.fillWidth: true

                        Text {
                            text: R.repoName(repo)
                            color: Theme.text
                            font.pixelSize: Theme.fontLg
                            font.bold: true
                            elide: Text.ElideRight
                            Layout.maximumWidth: 320
                        }

                        StatusBadge {
                            status: (repo.visibility && repo.visibility.type === "private")
                                    ? "private" : ""
                        }

                        Item { Layout.fillWidth: true }
                    }

                    Text {
                        text: R.repoDescription(repo)
                        color: Theme.textDim
                        font.pixelSize: Theme.fontSm
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        visible: text !== ""
                    }
                }

                // Stat columns. Each occupies a FIXED width and is always
                // present (an absent value renders as a dash), so the three
                // columns land on the same x on every row and read as a table.
                // Sizing them to content, or hiding empty ones, made every row
                // place them differently.
                Repeater {
                    model: [
                        { label: "issues",  value: R.projectMeta(repo).issues
                                                   ? R.projectMeta(repo).issues.open : -1 },
                        { label: "patches", value: R.projectMeta(repo).patches
                                                   ? R.projectMeta(repo).patches.open : -1 },
                        { label: "seeds",   value: repo.seeding !== undefined
                                                   ? repo.seeding : -1 }
                    ]
                    delegate: ColumnLayout {
                        required property var modelData
                        spacing: 0
                        Layout.preferredWidth: Theme.statColumn
                        Layout.minimumWidth: Theme.statColumn
                        Layout.maximumWidth: Theme.statColumn
                        Layout.alignment: Qt.AlignVCenter

                        Text {
                            text: modelData.value >= 0 ? modelData.value : "–"
                            color: modelData.value > 0 ? Theme.text : Theme.textFaint
                            font.pixelSize: Theme.fontMd
                            horizontalAlignment: Text.AlignRight
                            Layout.fillWidth: true
                        }
                        Text {
                            text: modelData.label
                            color: Theme.textFaint
                            font.pixelSize: Theme.fontXs
                            horizontalAlignment: Text.AlignRight
                            Layout.fillWidth: true
                        }
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.border
            }

            MouseArea {
                id: mouse
                // On the MouseArea, not the delegate Rectangle above.
                //
                // A selector resolves a non-clickable node by climbing to an
                // ANCESTOR that is clickable, and failing that by searching
                // each ancestor's descendants for a mouse handler. For a list
                // delegate there is no clickable ancestor, so every row
                // climbed to the shared ListView and found the SAME first
                // MouseArea — the matches then deduplicated onto one target
                // and `nth: 1` reported "out of range, matched 1 element",
                // making every row but the first unaddressable by a spec.
                //
                // Same trap SectionTabs.qml documents. The name is unchanged,
                // so specs that already select "repoRow" keep working; only
                // which element carries it moves.
                objectName: "repoRow"
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: page.repoActivated(repo)
            }
        }

        footer: Item {
            width: list.width
            height: page.hasMore ? 52 : 0
            visible: page.hasMore
            Button {
                anchors.centerIn: parent
                text: "Load more"
                onClicked: { page.page_++; page.fetch(); }
                background: Rectangle {
                    implicitWidth: 110; implicitHeight: 28
                    radius: Theme.radius
                    color: parent.hovered ? Theme.surfaceAlt : Theme.surface
                    border.color: Theme.border
                    border.width: 1
                }
                contentItem: Text {
                    text: parent.text
                    color: Theme.text
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    LoadingState {
        anchors.fill: parent
        // Silenced entirely in Embedded. "No repositories matched" is a
        // DIFFERENT false claim, not a milder one: it says an embedded node
        // exists and holds nothing, when none exists at all. A spinner would
        // be worse still — it promises an answer that is not coming.
        visible: !page.notImplemented && count === 0
        loading: page.loading
        loaded: page.loadedOnce
        count: repos.count
        emptyText: "No repositories matched"
        loadingText: "Loading repositories…"
    }

    // ---- Embedded: not implemented ------------------------------------
    //
    // A state of its own rather than an empty list, because the two say
    // different things and only one of them is true. The wording is lifted
    // from the toggle's own caption ("not available in this version yet") so
    // the header and the body agree — this module has already shipped one bug
    // from having two vocabularies for one fact.
    Column {
        objectName: "notImplementedState"
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.gapLg * 2, Theme.captionWidth)
        spacing: Theme.gapSm
        visible: page.notImplemented

        Text {
            objectName: "notImplementedNote"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Embedded runs a node inside Basecamp with its own separate "
                + "identity — it is not available in this version yet."
            color: Theme.textDim
            font.pixelSize: Theme.fontLg
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
        }

        // Says what to do instead, so the state is not merely a dead end. It
        // names the other two modes by the words on their segments.
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Choose Explore to browse a seed node, or Local to use the "
                + "Radicle node on this machine."
            color: Theme.textFaint
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
        }
    }
}
