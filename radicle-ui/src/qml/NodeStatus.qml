import QtQuick
import QtQuick.Layouts
import "Theme.js" as Theme

/*
 * Which node this module is talking to, and which identity it holds.
 *
 * This is not decoration, and it is deliberately always visible rather than
 * tucked into a settings pane. The M3 plan names the failure this design is
 * most exposed to: a user believing they are operating as their existing DID
 * when they are operating as a different one. When that happens their
 * repositories are simply "missing", with nothing on screen explaining why —
 * and the natural conclusion is that the module is broken rather than that it
 * is pointed somewhere else.
 *
 * So mode and identity are chrome, next to the source toggle, on every screen.
 *
 * Three states worth distinguishing, because they prompt different actions:
 *
 *  - a startable mode with an identity: show the mode and a short NID.
 *  - a mode this build cannot start (Embedded, until the daemon lands in
 *    Phase 2): show it as chosen, and say plainly that it is not running.
 *    Not hidden, because the user chose it and it IS persisted; not silently
 *    treated as working, because nothing would happen.
 *  - a resolved-paths problem (a control socket over the 108-byte cap, say):
 *    show it, because "the node is not running" and "we could never have
 *    talked to it" are different problems with different fixes.
 */
Item {
    id: status

    /// "attach" | "embedded" | "seedOnly" — the persisted mode.
    property string mode: "attach"
    /// Whether this build can actually start the chosen mode's node.
    property bool startable: true
    /// Why not, when `startable` is false. Shown verbatim.
    property string modeReason: ""
    /// The local node's DID, "" when there is no profile.
    property string nodeId: ""
    /// The Radicle home actually resolved, for the tooltip.
    property string radHome: ""
    /// A problem with the resolved paths, "" when there is none.
    property string pathsProblem: ""

    implicitWidth: row.implicitWidth
    implicitHeight: Theme.rowHeightSm

    /// Human label for the stored key. The KEY is the API contract and the
    /// LABEL is a UI decision — the same separation SourceToggle documents, so
    /// renaming what a user reads never touches what the backend stores.
    readonly property string modeLabel: mode === "embedded" ? "Embedded"
                                      : mode === "seedOnly" ? "Seed only"
                                      : "Attached"

    /// A DID is far too long for chrome, and the middle carries no meaning to
    /// a reader. The head is what people recognise and quote, so show that and
    /// put the whole thing in the tooltip.
    readonly property string shortId: {
        if (nodeId === "") return "";
        var bare = nodeId.indexOf("did:key:") === 0 ? nodeId.substring(8) : nodeId;
        return bare.length > 14 ? bare.substring(0, 14) + "…" : bare;
    }

    /// Whether anything here needs the user's attention. Drives the colour, so
    /// a problem is visible without reading the text.
    readonly property bool hasProblem: !startable || pathsProblem !== ""

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Theme.gapXs

        Rectangle {
            Layout.preferredHeight: Theme.rowHeightSm
            Layout.preferredWidth: label.implicitWidth + Theme.gap * 2
            radius: Theme.radiusSm
            color: Theme.bg
            border.width: 1
            border.color: status.hasProblem ? Theme.warn : Theme.border

            Text {
                id: label
                objectName: "nodeStatusLabel"
                anchors.centerIn: parent
                text: status.shortId !== ""
                      ? status.modeLabel + " · " + status.shortId
                      : status.modeLabel
                color: status.hasProblem ? Theme.warn : Theme.textDim
                font.pixelSize: Theme.fontSm
            }
        }
    }

    HoverHandler { id: hover }

    // Everything the badge could not fit. Shown on hover rather than always,
    // because the full DID and an absolute path are reference information, not
    // something to read on every glance.
    Rectangle {
        objectName: "nodeStatusTooltip"
        visible: hover.hovered
        anchors.top: parent.bottom
        anchors.topMargin: Theme.gapXs
        anchors.left: parent.left
        width: tip.implicitWidth + Theme.gap
        height: tip.implicitHeight + Theme.gapSm
        color: Theme.raised
        border.width: 1
        border.color: Theme.border
        radius: Theme.radiusSm
        z: 100

        Text {
            id: tip
            anchors.centerIn: parent
            color: Theme.textDim
            font.pixelSize: Theme.fontXs
            textFormat: Text.PlainText
            text: {
                var lines = [];
                if (status.nodeId !== "") lines.push("Identity: " + status.nodeId);
                if (status.radHome !== "") lines.push("Home: " + status.radHome);
                if (!status.startable && status.modeReason !== "")
                    lines.push(status.modeReason);
                if (status.pathsProblem !== "") lines.push(status.pathsProblem);
                if (lines.length === 0)
                    lines.push("Browsing a seed node — no local Radicle profile in use.");
                return lines.join("\n");
            }
        }
    }
}
