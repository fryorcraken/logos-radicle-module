import QtQuick
import QtQuick.Controls

// Which seed node the remote source proxies to. The list comes from the core
// module, which merges the built-in public seeds with any preferredSeeds found
// in this machine's Radicle config.
ComboBox {
    id: control

    /// Seed currently in use, as reported by the module's capabilities.
    property string currentSeed: ""
    /// Injected by the parent: fetchSeeds(callback) -> callback(dataObject).
    property var fetchSeeds: null
    /// Guards against the two load triggers both firing.
    property bool loaded: false

    signal seedChosen(string url)

    implicitWidth: 220
    textRole: "label"
    valueRole: "url"

    model: ListModel { id: seedModel }

    // `fetchSeeds` is assigned by the parent, which can happen after this
    // component completes. Loading only from Component.onCompleted therefore
    // raced and usually lost, leaving the list permanently empty — so load on
    // whichever of the two happens last.
    Component.onCompleted: reload()
    onFetchSeedsChanged: reload()

    function reload() {
        if (!fetchSeeds || loaded)
            return;
        loaded = true;
        fetchSeeds(function (data) {
            seedModel.clear();
            var items = (data && data.items) ? data.items : [];
            for (var i = 0; i < items.length; i++)
                seedModel.append({ label: items[i].alias || items[i].url,
                                   url: items[i].url });
            if (seedModel.count === 0)
                control.loaded = false;   // allow a retry
            control.syncSelection();
        });
    }

    function syncSelection() {
        for (var i = 0; i < seedModel.count; i++) {
            if (seedModel.get(i).url === control.currentSeed) {
                control.currentIndex = i;
                return;
            }
        }
    }

    onCurrentSeedChanged: syncSelection()

    onActivated: function (index) {
        var url = seedModel.get(index).url;
        if (url !== control.currentSeed)
            control.seedChosen(url);
    }

    implicitHeight: 30

    background: Rectangle {
        radius: Theme.radius
        color: Theme.bg
        border.color: control.activeFocus ? Theme.accent : Theme.border
        border.width: 1
    }
    contentItem: Text {
        leftPadding: Theme.gapSm
        rightPadding: 24
        text: control.displayText
        color: control.currentIndex >= 0 ? Theme.text : Theme.textFaint
        font.pixelSize: Theme.fontMd
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    delegate: ItemDelegate {
        required property var model
        required property int index
        width: control.width
        height: 28
        highlighted: control.highlightedIndex === index
        background: Rectangle {
            color: parent.highlighted ? Theme.surfaceAlt : Theme.surface
        }
        contentItem: Text {
            leftPadding: Theme.gapSm
            text: model.label
            color: Theme.text
            font.pixelSize: Theme.fontMd
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
    popup: Popup {
        y: control.height + 2
        width: control.width
        implicitHeight: Math.min(contentItem.implicitHeight, 240)
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
