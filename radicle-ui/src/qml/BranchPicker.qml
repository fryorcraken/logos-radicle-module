import QtQuick
import QtQuick.Controls
import "Theme.js" as Theme

/*
 * Which branch the Source and Commits tabs are showing.
 *
 * A Button + Popup, NOT a ComboBox, and that is the whole point of this
 * component's shape. ComboBox models one flat list of interchangeable options.
 * This data is a two-level tree — peer, then that peer's branches — with a
 * distinguished root (the repository default), and it runs to 84 entries
 * across 5 peers on a real repository. Every workaround the ComboBox version
 * accumulated came from bending a flat control around a tree: a separator
 * smuggled in as a fake model row (so `count` lied and needed a `branchCount`
 * correction), `hoverEnabled: !isSeparator` to stop the fake row lighting up,
 * `activated` having to undo a click on it, and a hand-measured popup width
 * because the delegate could not see its own view.
 *
 * Three things drive the design, all learned from getting it wrong:
 *
 * 1. THE REPOSITORY DEFAULT IS A REAL BRANCH AND IS PINNED AT THE TOP.
 *    In Radicle every branch lives under a peer's namespace, but
 *    `refs/heads/<name>` also exists as a delegate-consensus ref — and it is
 *    what the view actually renders on first load. `list_branches` returns
 *    only per-peer entries, so the current branch was not a member of the
 *    list and nothing could be selected: on a repository where the user owns
 *    no branches (3 of 9 on the machine this was built against) the control
 *    rendered COMPLETELY BLANK. It is synthesised here rather than matched
 *    against a peer's same-named branch, because `refs/heads/master` and
 *    `<nid>/master` are different refs that can point at different commits —
 *    aliasing them is the "wrong branch's files under the right branch's
 *    name" failure `resolve_commit` exists to prevent.
 *
 * 2. THE NODE ID APPEARS ONCE PER PEER, IN A SECTION HEADER — NEVER PER ROW.
 *    Rows carried `gFq6z5…/cli/cob-migrate`, so six characters of noise led
 *    every row, in the leftmost position where the eye scans, and no two rows
 *    shared a left edge. It is constant within a group; show it once.
 *
 * 3. THE PANEL IS A FIXED WIDTH. Measuring it from the widest label is what
 *    produced a 480px popup hanging off a 140px control, which read as a
 *    detached floating panel. Hoisting the node id out of the rows removed
 *    the content that demanded the width.
 *
 * Follows SeedPicker's dependency-injection shape (`fetchBranches` assigned by
 * the parent) so this stays testable with no backend and no network.
 */
Item {
    id: control

    // ---- public interface (unchanged from the ComboBox version) ----------

    /// Branch currently selected. Seeded by RepoView from the repo's default.
    property string currentBranch: ""
    /// Injected by the parent: fetchBranches(callback) -> callback(dataObject).
    property var fetchBranches: null
    /// Guards against re-fetching for a repo already loaded.
    property bool loaded: false
    /// Identifies which repo `loaded` refers to, so switching repos (even back
    /// to one already fetched once) reliably reloads rather than showing a
    /// stale list under a `loaded` flag that never got cleared.
    property string rid: ""

    signal branchChosen(string name)

    /// Selectable branches, including the pinned default.
    readonly property int branchCount: rows.count
    /// Rows surviving the current filter.
    readonly property int visibleCount: visibleRows.count
    /// Whether a filter field is offered. Below the threshold it is furniture.
    readonly property bool searchable: branchCount > Theme.pickerSearchThreshold

    /// Row accessors, so a test can assert on structure without reaching into
    /// a private ListModel — and so the model stays free to change shape.
    function rowAt(i) { return rows.get(i); }
    function visibleRowAt(i) { return visibleRows.get(i); }
    /// Whether the list is grouped by peer at all — false for the seed source,
    /// which sends no peer information. Retained from the previous version so
    /// RepoView and the specs keep their property.
    property bool hasSeparator: peerCount > 0
    /// How many distinct peers contributed branches.
    property int peerCount: 0

    implicitWidth: Theme.pickerTrigger
    implicitHeight: 26

    // ---- model ------------------------------------------------------------
    //
    // One FLAT ListModel with a `kind` role rather than a tree: QML has no
    // tree view worth using here, and a flat model with section-shaped rows
    // is what ListView.section consumes. `kind` is "default", "header" or
    // "branch"; only "branch" and "default" rows are selectable.

    ListModel { id: rows }

    /// Rows currently shown, after the filter. Kept separate from `rows` so
    /// filtering never destroys the full list — retyping a shorter query has
    /// to widen the results again, which a destructive filter cannot do.
    ListModel { id: visibleRows }

    property string filterText: ""

    onRidChanged: { loaded = false; reload(); }
    onFetchBranchesChanged: reload()

    function reload() {
        if (!fetchBranches || loaded || rid === "")
            return;
        loaded = true;
        fetchBranches(function (data) {
            rebuild(data);
        });
    }

    function rebuild(data) {
        rows.clear();
        var items = (data && data.items) ? data.items : [];
        var def = (data && data.default) ? data.default : "";

        // The repository default, pinned. Synthesised rather than taken from
        // `items` — see (1) in the header comment. Its `head` is unknown here
        // (list_branches reports per-peer heads), which is why it shows a
        // badge instead of a sha.
        if (def !== "") {
            rows.append({ kind: "default", name: def, label: def,
                          peer: "", head: "", section: "" });
        }

        // Group by peer, preserving the backend's order: it already sorts
        // local-node branches first, then peers, each group sorted by name.
        var peers = [];
        for (var i = 0; i < items.length; i++) {
            var it = items[i];
            // The default is already pinned above; a peer's same-named branch
            // is a DIFFERENT ref and is deliberately still listed below.
            var peer = it.remote ? it.remote : "";
            var isLocal = it.isLocal === true;
            var section = peer === "" ? "branches"
                                      : (isLocal ? "your node" : abbreviate(peer));
            if (peers.indexOf(section) === -1)
                peers.push(section);
            rows.append({
                kind: "branch",
                name: it.name,
                // The bare branch name. Peer rows arrive as `<nid>/<branch>`;
                // the nid is in the section header, so strip it from the row.
                label: bareName(it, isLocal),
                peer: peer,
                head: it.head ? String(it.head).substring(0, 7) : "",
                section: section
            });
        }
        // "branches" is the flat/seed case, not a peer — see hasSeparator.
        peerCount = (peers.length === 1 && peers[0] === "branches")
                    ? 0 : peers.length;

        if (rows.count === 0)
            control.loaded = false;   // allow a retry
        applyFilter();
    }

    /// A row's display name, with any `<nid>/` qualifier removed — the node id
    /// belongs to the section header. Uses the row's own `remote`, so a local
    /// branch legitimately named `feature/login` is never mistaken for a
    /// qualified one.
    function bareName(item, isLocal) {
        if (isLocal || !item.remote)
            return item.name;
        var prefix = item.remote + "/";
        return item.name.indexOf(prefix) === 0
               ? item.name.substring(prefix.length)
               : item.name;
    }

    function abbreviate(nid) {
        var s = nid.indexOf("z6Mk") === 0 ? nid.substring(4) : nid;
        return s.length > 6 ? s.substring(0, 6) + "…" : s;
    }

    // ---- filtering --------------------------------------------------------

    function applyFilter() {
        visibleRows.clear();
        var q = filterText.toLowerCase();
        for (var i = 0; i < rows.count; i++) {
            var r = rows.get(i);
            if (q === ""
                || r.label.toLowerCase().indexOf(q) >= 0
                // Matched against the FULL node id, not the section label:
                // the label is truncated for display (`PeerOn…`), so filtering
                // on it would fail for any query longer than the truncation —
                // including the full id a user is most likely to paste.
                // Matching the peer at all is what keeps hoisting the id into
                // the header lossless rather than hiding it.
                || r.peer.toLowerCase().indexOf(q) >= 0
                || r.section.toLowerCase().indexOf(q) >= 0) {
                visibleRows.append({
                    kind: r.kind, name: r.name, label: r.label,
                    peer: r.peer, head: r.head, section: r.section
                });
            }
        }
    }

    onFilterTextChanged: applyFilter()

    // ---- selection --------------------------------------------------------

    /// Index into `rows` of the current branch, or -1. Matches on `name`, the
    /// fully-qualified value every downstream read is keyed on — never on the
    /// display label, which is deliberately ambiguous between peers.
    readonly property int currentRow: {
        for (var i = 0; i < rows.count; i++)
            if (rows.get(i).name === currentBranch)
                return i;
        return -1;
    }

    /// What the closed control shows.
    readonly property string displayLabel:
        currentRow >= 0 ? rows.get(currentRow).label
                        : (currentBranch !== "" ? currentBranch : "")
    /// The peer owning the current branch, "" for the default or a local one.
    readonly property string displayPeer:
        currentRow >= 0 ? rows.get(currentRow).peer : ""
    /// True when `currentBranch` names something not in this repo's list —
    /// shown explicitly rather than blanked, so a stale value is visible.
    readonly property bool unresolved:
        currentBranch !== "" && currentRow < 0 && rows.count > 0

    /// A dropdown holding exactly one already-selected item offers no choice,
    /// so it is rendered as a label instead. True for 5 of 9 repos on a real
    /// node, where the default branch is the only branch.
    readonly property bool interactive: branchCount > 1

    function choose(name) {
        popup.close();
        if (name !== control.currentBranch)
            control.branchChosen(name);
    }

    /// Select by index into the VISIBLE rows. The e2e specs drive the picker
    /// through this because popup delegates live in a separate window that
    /// the QML inspector cannot address by objectName. It routes through the
    /// same `choose()` a real click uses — a spec that bypassed the handler
    /// would go green while testing nothing.
    function selectByIndex(i) {
        if (i < 0 || i >= visibleRows.count) return;
        var r = visibleRows.get(i);
        if (r.kind === "header") return;
        choose(r.name);
    }

    /// Retained for the existing specs, which emit `activated(index)`.
    signal activated(int index)
    onActivated: function (i) { selectByIndex(i); }

    // ---- closed control ---------------------------------------------------

    Rectangle {
        id: chip
        anchors.fill: parent
        radius: Theme.radiusPill
        color: mouse.containsMouse && control.interactive
               ? Theme.raised : Theme.surfaceAlt
        border.color: popup.opened ? Theme.accent : Theme.border
        border.width: 1
        Behavior on color { ColorAnimation { duration: Theme.animFast } }

        Row {
            anchors.fill: parent
            anchors.leftMargin: Theme.gapSm
            anchors.rightMargin: Theme.gapSm
            spacing: Theme.gapXs

            // Says "this is a branch" — nothing else on the chip does.
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "⑂"
                color: Theme.textFaint
                font.pixelSize: Theme.fontSm
            }
            // Peer provenance as a dot, not a prefix: the closed state answers
            // "which branch am I on", not "whose".
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: control.displayPeer !== ""
                width: 6; height: 6; radius: 3
                color: control.displayPeer !== ""
                       ? Theme.peerColor(control.displayPeer) : "transparent"
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: chip.width - 2 * Theme.gapSm - 34
                text: control.unresolved ? control.displayLabel + " !"
                                         : (control.displayLabel !== ""
                                            ? control.displayLabel : "no branches")
                color: control.unresolved || control.displayLabel === ""
                       ? Theme.textFaint : Theme.textDim
                font.italic: control.unresolved
                font.pixelSize: Theme.fontSm
                font.family: Theme.mono
                verticalAlignment: Text.AlignVCenter
                // Middle, not right: `releases/1.9` and `releases/1.5` differ
                // only in the tail, which ElideRight would eat.
                elide: Text.ElideMiddle
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: control.interactive
                text: "▾"
                color: Theme.textFaint
                font.pixelSize: Theme.fontSm
            }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: control.interactive ? Qt.PointingHandCursor
                                             : Qt.ArrowCursor
            onClicked: {
                if (!control.interactive) return;
                if (popup.opened) popup.close();
                else popup.open();
            }
        }

        ToolTip.visible: mouse.containsMouse && control.displayPeer !== ""
        ToolTip.text: control.displayLabel + " — " + control.displayPeer
        ToolTip.delay: 400
    }

    // ---- open panel -------------------------------------------------------

    Popup {
        id: popup
        y: control.height + 4
        // Right-aligned: the picker sits at the far right of the repo header,
        // so a panel anchored at x:0 and wider than the chip runs off the
        // window edge and is clipped there.
        x: control.width - width
        width: Theme.pickerWidth
        implicitHeight: Math.min(panel.implicitHeight, Theme.pickerMaxHeight)
        padding: 1
        onOpened: {
            control.filterText = "";
            if (search.visible) search.forceActiveFocus();
            scrollToCurrent();
        }

        function scrollToCurrent() {
            for (var i = 0; i < visibleRows.count; i++) {
                if (visibleRows.get(i).name === control.currentBranch) {
                    list.positionViewAtIndex(i, ListView.Center);
                    list.currentIndex = i;
                    return;
                }
            }
            list.currentIndex = 0;
        }

        background: Rectangle {
            color: Theme.surface
            border.color: Theme.border
            border.width: 1
            radius: Theme.radius
        }

        contentItem: Column {
            id: panel
            spacing: 0

            // Filter. Only when scanning is actually hard — below the
            // threshold it is furniture, and the same rule serves both
            // sources so a small seed repo is not special-cased.
            Item {
                id: search
                visible: control.searchable
                width: parent.width
                height: visible ? 30 : 0

                function forceActiveFocus() { field.forceActiveFocus(); }

                TextField {
                    id: field
                    anchors.fill: parent
                    anchors.margins: Theme.gapXs
                    placeholderText: "Filter branches…"
                    color: Theme.text
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.mono
                    background: Rectangle {
                        color: Theme.bg
                        border.color: field.activeFocus ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusSm
                    }
                    onTextChanged: control.filterText = text
                    Keys.onEscapePressed: popup.close()
                    Keys.onDownPressed: list.forceActiveFocus()
                    Keys.onReturnPressed: control.selectByIndex(list.currentIndex)
                }
            }

            Rectangle {
                visible: search.visible
                width: parent.width; height: 1
                color: Theme.border
            }

            ListView {
                id: list
                objectName: "branchList"
                width: parent.width
                height: Math.min(contentHeight,
                                 Theme.pickerMaxHeight - (search.visible ? 55 : 24))
                clip: true
                model: visibleRows
                currentIndex: 0
                keyNavigationEnabled: true
                ScrollIndicator.vertical: ScrollIndicator {}

                // Peer grouping. `ListView.section` is the native affordance
                // for this two-level shape — it is what removes the fake
                // divider row the ComboBox version had to fabricate, and with
                // it the `count`/`branchCount` discrepancy that leaked into
                // the e2e specs.
                section.property: "section"
                section.criteria: ViewSection.FullString
                section.labelPositioning:
                    ViewSection.InlineLabels | ViewSection.CurrentLabelAtStart
                section.delegate: Rectangle {
                    required property string section
                    width: list.width
                    height: section === "" ? 0 : 20
                    visible: section !== ""
                    color: Theme.raised

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.gapSm
                        spacing: Theme.gapXs
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: parent.parent.section !== "your node"
                                     && parent.parent.section !== "branches"
                            width: 6; height: 6; radius: 3
                            color: Theme.peerColor(parent.parent.section)
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: parent.parent.section
                            color: Theme.textFaint
                            font.pixelSize: Theme.fontXs
                            font.family: Theme.mono
                        }
                    }
                }

                delegate: Rectangle {
                    id: row
                    required property var model
                    required property int index
                    width: list.width
                    height: Theme.rowHeightXs
                    color: list.currentIndex === index ? Theme.surfaceAlt
                                                       : "transparent"

                    readonly property bool isCurrent:
                        model.name === control.currentBranch

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.gapSm
                        anchors.rightMargin: Theme.gapSm
                        spacing: Theme.gapXs

                        // Fixed gutter. The check survives hover and keyboard
                        // traversal, which the row fill does not — three keys
                        // down the list, the fill says "here" and the check
                        // says "this is the one you are on".
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 10
                            text: row.isCurrent ? "✓" : ""
                            color: Theme.accent
                            font.pixelSize: Theme.fontXs
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: row.width - 2 * Theme.gapSm - 10
                                   - (badge.visible ? badge.width : 0)
                                   - 2 * Theme.gapXs
                            text: row.model.label
                            color: row.isCurrent ? Theme.accent : Theme.text
                            font.pixelSize: Theme.fontSm
                            font.family: Theme.mono
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideMiddle
                        }
                        // The commit sha, or a `default` badge for the pinned
                        // row. Two peers both having `master` is common; the
                        // sha is the only thing on screen saying they are
                        // different commits.
                        Text {
                            id: badge
                            anchors.verticalCenter: parent.verticalCenter
                            visible: text !== ""
                            text: row.model.kind === "default"
                                  ? "default" : row.model.head
                            color: Theme.textFaint
                            font.pixelSize: Theme.fontXs
                            font.family: Theme.mono
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: list.currentIndex = row.index
                        onClicked: control.choose(row.model.name)
                    }
                }

                Keys.onReturnPressed: control.selectByIndex(list.currentIndex)
                Keys.onEscapePressed: popup.close()
            }

            // Empty state. A filter matching nothing must say so — an empty
            // panel is indistinguishable from a failed load.
            Text {
                visible: visibleRows.count === 0
                width: parent.width
                height: visible ? 40 : 0
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: control.filterText !== ""
                      ? "no branch matches \"" + control.filterText + "\""
                      : "no branches"
                color: Theme.textFaint
                font.pixelSize: Theme.fontSm
                font.family: Theme.mono
            }

            Rectangle {
                width: parent.width; height: 1
                color: Theme.border
            }

            // Footer: count, and the keyboard contract. One row, and it is
            // the only thing telling a keyboard user the panel is navigable.
            Item {
                width: parent.width
                height: 22
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.gapSm
                    anchors.verticalCenter: parent.verticalCenter
                    text: control.filterText !== ""
                          ? visibleRows.count + " of " + control.branchCount
                          : control.branchCount + " branches"
                            + (control.peerCount > 0
                               ? " · " + control.peerCount + " peers" : "")
                    color: Theme.textFaint
                    font.pixelSize: Theme.fontXs
                    font.family: Theme.mono
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.gapSm
                    anchors.verticalCenter: parent.verticalCenter
                    visible: search.visible
                    text: "↑↓ move  ⏎ select  esc close"
                    color: Theme.textFaint
                    font.pixelSize: Theme.fontXs
                }
            }
        }
    }
}
