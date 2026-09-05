import QtQuick
import QtQuick.Controls
import "Theme.js" as Theme

/*
 * Which branch the Source and Commits tabs are showing.
 *
 * Unlike SeedPicker, this is a closed set — a repo's branches, not an
 * arbitrary typed endpoint — so it is not editable. Follows the same
 * dependency-injection shape as SeedPicker (fetchBranches assigned by the
 * parent rather than fetched here) for the same reason: it keeps this
 * component testable with no backend and no network.
 */
ComboBox {
    id: control

    /// Branch currently selected (usually the repo's default on first load).
    property string currentBranch: ""
    /// Injected by the parent: fetchBranches(callback) -> callback(dataObject).
    property var fetchBranches: null
    /// Guards against re-fetching for a repo already loaded.
    property bool loaded: false
    /// Identifies which repo `loaded` refers to, so switching repos (even
    /// back to one already fetched once) reliably reloads rather than
    /// showing a stale list under a `loaded` flag that never got cleared.
    property string rid: ""

    signal branchChosen(string name)

    /// Selectable branches, excluding any local/peer divider row.
    ///
    /// `count` is the ComboBox's own model size and includes the divider, so
    /// anything asserting on "how many branches" — the e2e specs do — would be
    /// off by one for a repo that has both local and peer branches. Kept as a
    /// separate property rather than by making the divider a non-model
    /// decoration, because a ComboBox draws its popup from the model and has
    /// no notion of a header row between items.
    readonly property int branchCount: count - (hasSeparator ? 1 : 0)
    /// Whether a divider was inserted; also lets a test assert the grouping
    /// happened at all, rather than inferring it from a count.
    property bool hasSeparator: false

    implicitWidth: 140
    implicitHeight: 26
    textRole: "label"
    valueRole: "name"

    model: ListModel { id: branchModel }

    onRidChanged: { loaded = false; reload(); }
    onFetchBranchesChanged: reload()

    function reload() {
        if (!fetchBranches || loaded || rid === "")
            return;
        loaded = true;
        fetchBranches(function (data) {
            branchModel.clear();
            // Cleared with the model, not left from the previous repo — a
            // repo with peers followed by one without would otherwise keep
            // reporting a divider that is no longer there.
            control.hasSeparator = false;
            var items = (data && data.items) ? data.items : [];
            // The local source groups the list: this node's own branches, then
            // every other peer's. A divider row is inserted at the boundary so
            // "mine" and "theirs" are not one undifferentiated list — peer
            // entries are already labelled `<nid…>/<branch>`, but a label
            // prefix alone reads as a naming convention rather than a
            // grouping. The seed source sends neither `isLocal` nor any peer
            // rows, so nothing is inserted there and its list is unchanged.
            var seenPeer = false;
            for (var i = 0; i < items.length; i++) {
                var it = items[i];
                // `isLocal === false` specifically, not a falsy test: the seed
                // omits the field entirely and must not be read as "peer".
                if (it.isLocal === false && !seenPeer) {
                    seenPeer = true;
                    // Only when something sits above it. A repo this node
                    // merely replicates has no branches of its own, and a
                    // divider at the top of the list separates nothing — it
                    // just reads as a stray caption. Common in practice: of
                    // nine repos on the machine this was developed against,
                    // three had zero local branches.
                    if (branchModel.count > 0) {
                        branchModel.append({
                            label: "other peers",
                            name: "",
                            isSeparator: true,
                            isLocal: false
                        });
                        control.hasSeparator = true;
                    }
                }
                branchModel.append({
                    label: it.label ? it.label : it.name,
                    name: it.name,
                    isSeparator: false,
                    // Carried into the model rather than re-derived from the
                    // name. A test (or a future delegate) that wants to know
                    // whose branch a row is must read the flag the backend
                    // sent, not guess from whether the name has a slash in it
                    // — a local branch may legitimately be `feature/login`.
                    isLocal: it.isLocal === true
                });
            }
            if (branchModel.count === 0)
                control.loaded = false;   // allow a retry
            control.syncSelection();
        });
    }

    function syncSelection() {
        for (var i = 0; i < branchModel.count; i++) {
            var row = branchModel.get(i);
            // A separator has an empty name. Skipping it explicitly matters
            // when currentBranch is "" — a repo whose payload omits
            // defaultBranch — which would otherwise select the divider and
            // display "other peers" as the current branch.
            if (row.isSeparator)
                continue;
            if (row.name === control.currentBranch) {
                control.currentIndex = i;
                return;
            }
        }
        // The current branch is not (yet) in the list — most commonly
        // because it is still loading, or the picker has not fetched for
        // this repo yet. Leave currentIndex where Qt defaults it (0) rather
        // than forcing a value the model does not contain.
    }

    onCurrentBranchChanged: syncSelection()

    onActivated: function (index) {
        var row = branchModel.get(index);
        // Clicking the divider must not switch branch — and must not leave the
        // box displaying it either, so the selection is put back where it was.
        if (row.isSeparator) {
            control.syncSelection();
            return;
        }
        if (row.name !== control.currentBranch)
            control.branchChosen(row.name);
    }

    background: Rectangle {
        radius: Theme.radiusPill
        color: Theme.surfaceAlt
        border.color: control.activeFocus ? Theme.accent : Theme.border
        border.width: 1
    }
    contentItem: Text {
        leftPadding: Theme.gapSm
        rightPadding: 20
        text: control.displayText
        color: Theme.textDim
        font.pixelSize: Theme.fontSm
        font.family: Theme.mono
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    delegate: ItemDelegate {
        id: branchDelegate
        required property var model
        required property int index
        readonly property bool isSeparator: model.isSeparator === true
        width: control.width
        height: isSeparator ? 20 : 26
        enabled: !isSeparator
        // Not merely `highlighted: false` — an ItemDelegate still tracks hover
        // and would light up under the cursor as though it were pickable.
        hoverEnabled: !isSeparator
        highlighted: !isSeparator && control.highlightedIndex === index
        background: Rectangle {
            color: branchDelegate.highlighted ? Theme.surfaceAlt : Theme.surface
            // A hairline above the divider row is what actually reads as a
            // break in the list; the caption alone looks like another entry.
            Rectangle {
                visible: branchDelegate.isSeparator
                width: parent.width
                height: 1
                color: Theme.border
            }
        }
        contentItem: Text {
            leftPadding: Theme.gapSm
            text: branchDelegate.model.label
            color: branchDelegate.isSeparator ? Theme.textDim : Theme.text
            font.pixelSize: branchDelegate.isSeparator ? Theme.fontXs : Theme.fontSm
            font.family: Theme.mono
            font.italic: branchDelegate.isSeparator
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
    popup: Popup {
        y: control.height + 2
        // Wider than the closed control on purpose. A peer branch reads
        // `z6MkireR…/cloudhead/user-agent`, which elides to uselessness at the
        // control's own 140px — and the elision is in the middle of the part
        // that distinguishes one entry from another. The closed box still
        // elides (it shows one already-chosen branch, so there is nothing to
        // tell apart), but the open list is where the choosing happens.
        width: Math.max(control.width, 280)
        implicitHeight: Math.min(contentItem.implicitHeight, 200)
        padding: 1
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            ScrollIndicator.vertical: ScrollIndicator {}
        }
        background: Rectangle {
            color: Theme.surface
            border.color: Theme.border
            border.width: 1
            radius: Theme.radius
        }
    }
}
