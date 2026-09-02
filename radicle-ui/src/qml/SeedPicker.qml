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

    signal seedChosen(string url)

    implicitWidth: 220
    textRole: "label"
    valueRole: "url"

    model: ListModel { id: seedModel }

    Component.onCompleted: reload()

    function reload() {
        if (!fetchSeeds)
            return;
        fetchSeeds(function (data) {
            seedModel.clear();
            var items = (data && data.items) ? data.items : [];
            for (var i = 0; i < items.length; i++)
                seedModel.append({ label: items[i].alias || items[i].url,
                                   url: items[i].url });
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

    background: Rectangle {
        color: Theme.panelAlt
        radius: Theme.radius
        border.color: Theme.border
        border.width: 1
    }
    contentItem: Text {
        leftPadding: 8
        text: control.displayText
        color: Theme.text
        font.pixelSize: 12
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
