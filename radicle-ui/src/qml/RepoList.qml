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

    /// The Embedded state panel's action was taken. `kind` is "setup", "start"
    /// or "restart".
    ///
    /// **A request, not the act.** This screen creates no identity, starts no
    /// node and writes no mode — it names what the user asked for and lets the
    /// host decide, which is what keeps "rendering the state writes nothing" a
    /// structural property rather than a promise.
    ///
    /// **Only "setup" reaches a host today**, and that is expressed as data
    /// rather than as a rule this file knows: `app.embeddedSetupHosted` and
    /// `app.embeddedStartHosted` say which requests are routed, and an action
    /// whose request is not routed is rendered not-enabled with a sentence
    /// saying so. Hosting start therefore means flipping one property on the
    /// host — no edit here, and nothing for a future reader to notice.
    ///
    /// The signal is emitted only from an ENABLED control, so an unhosted act
    /// cannot be requested even by a caller reaching past the button.
    signal embeddedActionTaken(string kind)

    /// Rows currently listed — read by the UI tests.
    readonly property int count: repos.count

    /// Whether the reported startable set OMITS the mode in force.
    ///
    /// **This is no longer the fetch guard** — see `hasNodeToAsk`, which is.
    /// Startability and "has a node to ask" are different questions, and reading
    /// the first as the second is what lost the Embedded surface: a mode is
    /// startable when it resolves a workable home, not when a node is running in
    /// it. This property now decides one thing only, the unstartable
    /// explanation, and is one of the two terms `hasNodeToAsk` conjoins.
    ///
    /// Keyed on the MODE rather than on `app.source`, and that distinction is
    /// the whole fix. `source` is the derived method prefix, and `local` and
    /// `embedded` both derive to `"local"` (see SourceState.qml) — so every
    /// staleness guard in this file, which compares `source`, is blind to the
    /// difference between them. A `localListRepos` reply issued in Local
    /// passes that guard unchanged after a switch to Embedded, and the
    /// ATTACHED node's repositories land under a segment reading "Embedded".
    ///
    /// That is the identity confusion this milestone exists to prevent, and
    /// the backend was already fixed for the same lie once: `storeForSettings()`
    /// used to let `embedded` fall through to the attached profile's home.
    /// This is that lie one layer up.
    ///
    /// **But it is not `app.mode === "embedded"`, and that mattered.** Written
    /// that way this was a THIRD place encoding "which mode cannot start",
    /// beside `SettingsStore::startableModes()` and `modeIsStartable()`. Phase 2
    /// makes Embedded startable by adding one entry to that list — and this
    /// screen would have gone on saying "not implemented" afterwards, with no
    /// gate failing and nothing to point at. Deriving it from the capability the
    /// backend already reports means Phase 2 changes one list and this follows.
    readonly property bool notImplemented: !!app && app.modeStartable === false

    /// The Embedded state in force, derived from what the backend reports.
    ///
    /// Inputs come from `app` — capabilities, identity and node status — and are
    /// bound rather than copied, so a later reply moves the state without
    /// anything here being told. A `null` app leaves every default in place,
    /// which derives to `blocked`; that is only reachable before wiring exists,
    /// and it is the inert direction (no fetch, no action).
    ///
    /// Held unconditionally rather than only in Embedded: it is a pure function
    /// of its inputs, `embeddedShown` is what gates the rendering, and a
    /// conditional instantiation would make the state unreadable from a test in
    /// any other mode — which is exactly how a blank pane hides.
    readonly property EmbeddedState embedded: EmbeddedState {
        pathsProblem:   app ? (app.embeddedPathsProblem || "") : ""
        home:           app ? (app.embeddedHome || "") : ""
        identityExists: !!app && app.embeddedIdentityExists === true
        running:        !!app && app.embeddedRunning === true
        serving:        !!app && app.embeddedServing === true
        startPending:   !!app && app.embeddedStartPending === true
        startError:     app ? (app.embeddedStartError || "") : ""
        // Which requests the host actually routes. Absent means false, which is
        // the inert direction: a named but disabled action, never an enabled
        // one reaching nobody.
        setupHosted:    !!app && app.embeddedSetupHosted === true
        startHosted:    !!app && app.embeddedStartHosted === true
    }

    /// Whether the Embedded state panel is the thing standing where a repository
    /// list would be.
    ///
    /// In Embedded with nothing listed. NOT "in Embedded" alone: a serving node
    /// with repositories renders the rows, and the panel would cover them.
    readonly property bool embeddedShown:
        !!app && app.mode === "embedded" && !notImplemented && count === 0

    /// Whether this mode has a node that could answer a list request.
    ///
    /// **Keyed on whether there is a node to ask, never on whether the mode is
    /// startable** — that is the requirement `source-modes` was re-keyed to and
    /// the defect `embedded-state` exists to repair. `embedded` resolves a
    /// workable home, so it is startable; a guard keyed on startability
    /// therefore stopped firing for it at the same moment the panel behind it
    /// stopped rendering, and the request went out against a home with no
    /// identity.
    ///
    /// Both terms are live. `notImplemented` covers a mode the reported startable
    /// set omits — no mode in this build, and the property is about the view for
    /// any set it is given. `embedded.hasNodeToAsk` covers a startable mode whose
    /// node does not exist or is not loaded.
    readonly property bool hasNodeToAsk:
        !notImplemented
        && (!app || app.mode !== "embedded" || embedded.hasNodeToAsk)

    /// Whether this screen is currently saying NOTHING AT ALL: no rows, and no
    /// rendered explanation of why there are none.
    ///
    /// Read off the three placeholder items' OWN `visible`, not recomputed from
    /// the same terms they are keyed on. That is the whole point: a copy of
    /// their conditions would agree with them whether or not either actually
    /// renders, which is the "fixture that answers the same for every input"
    /// trap. Asking the items themselves means this can only be false when
    /// something is genuinely on screen.
    ///
    /// It exists because "blank pane" is a real defect this module shipped —
    /// the repository list went blank with no rows, no empty state, no error
    /// and nothing in the log — and no other assertion can see it.
    /// `repoCount === 0` is equally true of a legitimately empty node, and a
    /// screenshot cannot tell a blank pane from one whose message failed to
    /// render. This combination is never correct, at any window size, in any
    /// mode, so a spec can assert against it unconditionally.
    ///
    /// `loadedOnce` is the term that keeps it honest: before the first reply
    /// there is legitimately nothing to say yet, and without it this would fire
    /// on every launch.
    ///
    /// **`embeddedState.visible` is carried here from the `notImplementedState`
    /// this replaced, and that carrying is a requirement rather than tidiness.**
    /// An observable naming an item that no longer exists silently reduces to a
    /// constant: `!undefined` is `true`, so this would go on reporting "nothing
    /// is rendered" whatever the panel did, and `tests/ui/local.yaml`'s
    /// blank-pane assertion — the only assertion that can see a blank pane at
    /// all — would stop being able to fail while continuing to pass.
    ///
    /// **`loadedOnce` is deliberately not required where a state panel is the
    /// thing that should be rendering.** Four of the seven Embedded states issue
    /// no request at all, so `loadedOnce` never becomes true in them — and a
    /// version that required it would be false in every one of those states
    /// whether or not the panel rendered. That is the fixture-that-answers-the-
    /// same-for-every-input trap in the observable itself: the spec's scenario
    /// "the observable follows the rendered item, not a recomputed copy"
    /// prevents the panel from rendering and requires this to go TRUE, and it
    /// could not.
    ///
    /// So `expectingAPanel` splits the two situations. Where a panel is what
    /// should be on screen, its absence is the defect and there is nothing to
    /// wait for. Where a list is, `loadedOnce` still keeps this quiet until the
    /// first reply lands.
    readonly property bool expectingAPanel: embeddedShown || notImplemented

    /// Whether the Embedded state panel is ACTUALLY rendering.
    ///
    /// Read off the item's own `visible` rather than from `embeddedShown`, which
    /// is the condition it is keyed on. The distinction is the one
    /// `sayingNothing` documents: a copy of the condition agrees whether or not
    /// the item draws, so an assertion on it cannot see the panel failing to
    /// render — which is precisely the defect worth catching.
    readonly property bool embeddedPanelShown: embeddedState.visible

    readonly property bool sayingNothing:
        count === 0 && !loading
        && !embeddedState.visible && !notImplementedState.visible
        && !placeholder.emptyShown
        && (expectingAPanel || loadedOnce)

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
        // A mode with no node to ask asks nothing. Fetching and then hiding the
        // result is how this bug returns: the reply would still be in flight,
        // would still pass the prefix-based guard below, and would still
        // repopulate the model behind the panel — rows appearing under a
        // sentence saying no node exists.
        //
        // The guard was keyed on `notImplemented` — on STARTABILITY — and that
        // is what lost this surface. `embedded` became startable, so the guard
        // stopped firing for it at the same moment the panel it protected
        // stopped rendering, and `localListRepos` went out against a home with
        // no identity. See `hasNodeToAsk`.
        if (!page.hasNodeToAsk) {
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
        id: placeholder
        anchors.fill: parent
        // Silenced wherever no node answered. "No repositories matched" is a
        // DIFFERENT false claim, not a milder one: it says an embedded node
        // exists and holds nothing, when none exists, none is loaded, or its
        // start was refused. A spinner would be worse still — it promises an
        // answer that is not coming.
        //
        // The one state where the wording WOULD be true — `runningEmpty`, a
        // serving node whose list came back with nothing — is covered by the
        // panel's own sentence instead, which says the same thing and adds what
        // the generic string cannot: that this node lists what it is SEEDING, so
        // an empty list reads as a node with nothing seeded rather than as a
        // node that has lost something. Two centred messages over one pane is
        // one too many, so the panel stands down this placeholder in all seven
        // states rather than in six.
        visible: !page.notImplemented && count === 0 && !page.embeddedShown
        loading: page.loading
        loaded: page.loadedOnce
        count: repos.count
        emptyText: "No repositories matched"
        loadingText: "Loading repositories…"
    }

    // ---- a mode this build cannot start -------------------------------
    //
    // A state of its own rather than an empty list, because the two say
    // different things and only one of them is true.
    //
    // **It no longer names Embedded**, and that is the point rather than a
    // tidy-up. This copy was written when Embedded was the one unstartable mode
    // and read "Embedded … is not available in this version yet"; Embedded is
    // startable now, so naming it here would be a false sentence rendered for
    // whichever mode the backend actually declines. `source-modes` requires this
    // state to be derived from the reported startable SET rather than from a
    // mode name, and the wording has to follow the derivation or it re-encodes
    // the mode name one layer up in prose.
    //
    // No mode in this build reports as unstartable, so this is the state a
    // FOURTH mode — or a build where one of the three cannot run — inherits
    // without a line of new UI. It also still renders during the window before
    // the first `getCapabilities` reply, if that reply ever reports a set
    // omitting the mode in force.
    Column {
        id: notImplementedState
        objectName: "notImplementedState"
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.gapLg * 2, Theme.captionWidth)
        spacing: Theme.gapSm
        visible: page.notImplemented

        Text {
            objectName: "notImplementedNote"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "This version cannot start the selected mode, so there is no "
                + "node to list repositories from."
            color: Theme.textDim
            font.pixelSize: Theme.fontLg
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
        }

        // Says what to do instead, so the state is not merely a dead end. It
        // names the other modes by the words on their segments.
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

    // ---- Embedded: the state panel ------------------------------------
    //
    // One centred panel standing where the repository list would be, saying
    // which of the seven states is in force and offering that state's own next
    // action. Never a spinner, and never "No repositories matched" — see
    // `EmbeddedState.qml` for why each state is its own sentence rather than one
    // banner with one button.
    //
    // **This replaces `notImplementedState` as the thing `sayingNothing`
    // watches**, and that carrying is a requirement in its own right: an
    // observable naming an item that no longer exists reduces to a constant,
    // and the end-to-end assertion consuming it stops being able to fail while
    // continuing to pass.
    Column {
        id: embeddedState
        objectName: "embeddedState"
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.gapLg * 2, Theme.captionWidth)
        spacing: Theme.gap
        visible: page.embeddedShown

        Text {
            objectName: "embeddedStateNote"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            // The state's sentence, verbatim where the backend wrote it. Bound
            // rather than assigned, so a later reply moves the words with the
            // state and the two cannot disagree.
            text: page.embedded.sentence
            color: Theme.textDim
            font.pixelSize: Theme.fontLg
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
        }

        // The state's own action. Absent — not disabled-and-unexplained — where
        // the state offers none: `blocked` offers nothing that would write,
        // because nothing could succeed, and the sentence above already names
        // the obstacle.
        Button {
            objectName: "embeddedStateAction"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: page.embedded.actionKind !== ""
            enabled: page.embedded.actionEnabled
            text: page.embedded.actionLabel
            // Requests the act; performs none of it. A state panel that acted
            // because it was displayed would act without being asked, so nothing
            // here creates an identity, starts a node or writes the mode — the
            // signal leaves and the host decides.
            //
            // Guarded on `actionEnabled` as well as by `enabled`, so an act
            // whose request reaches nobody cannot be requested by a test or a
            // caller invoking `clicked()` directly. `enabled:false` stops a
            // pointer, not a programmatic emit, and "an action that is not
            // enabled emits no request" is the requirement rather than a
            // property of the mouse.
            onClicked: {
                if (!page.embedded.actionEnabled) return;
                page.embeddedActionTaken(page.embedded.actionKind);
            }

            background: Rectangle {
                implicitWidth: 180; implicitHeight: 30
                radius: Theme.radius
                color: parent.enabled
                       ? (parent.hovered ? Theme.accentSoft : Theme.surface)
                       : Theme.surface
                border.color: Theme.border
                border.width: 1
                opacity: parent.enabled ? 1.0 : 0.5
            }
            contentItem: Text {
                text: parent.text
                color: Theme.text
                font.pixelSize: Theme.fontMd
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                opacity: parent.enabled ? 1.0 : 0.5
            }
        }

        // Why the action above cannot be taken. A disabled control with nothing
        // beside it reads as a module that is broken and gives the user no other
        // thing to try; this says which surface the act is waiting on.
        Text {
            objectName: "embeddedStateUnavailable"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: page.embedded.actionUnavailableNote !== ""
            text: page.embedded.actionUnavailableNote
            color: Theme.textDim
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
        }
    }
}
