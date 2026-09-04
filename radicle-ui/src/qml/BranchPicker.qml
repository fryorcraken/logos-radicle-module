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
            var items = (data && data.items) ? data.items : [];
            for (var i = 0; i < items.length; i++)
                branchModel.append({ label: items[i].name, name: items[i].name });
            if (branchModel.count === 0)
                control.loaded = false;   // allow a retry
            control.syncSelection();
        });
    }

    function syncSelection() {
        for (var i = 0; i < branchModel.count; i++) {
            if (branchModel.get(i).name === control.currentBranch) {
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
        var name = branchModel.get(index).name;
        if (name !== control.currentBranch)
            control.branchChosen(name);
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
        required property var model
        required property int index
        width: control.width
        height: 26
        highlighted: control.highlightedIndex === index
        background: Rectangle {
            color: parent.highlighted ? Theme.surfaceAlt : Theme.surface
        }
        contentItem: Text {
            leftPadding: Theme.gapSm
            text: model.label
            color: Theme.text
            font.pixelSize: Theme.fontSm
            font.family: Theme.mono
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
    popup: Popup {
        y: control.height + 2
        width: Math.max(control.width, 160)
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
