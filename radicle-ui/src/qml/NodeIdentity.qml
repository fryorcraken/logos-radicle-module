import QtQuick
import "Theme.js" as Theme

/*
 * Which identity you are operating as — the detail slot's content while the
 * `local` mode is selected.
 *
 * ## Why this exists at all
 *
 * `radicle_impl.h` states the requirement: the failure this milestone is most
 * exposed to is a user believing they are operating as their existing DID when
 * they are operating as a different one, at which point their repositories are
 * simply "missing" with nothing on screen explaining why. So the identity has
 * to be legible, without hover, on every screen where it applies.
 *
 * ## Why it is here and not in the toggle
 *
 * An earlier attempt put the DID inside the Local segment's label. Two things
 * were wrong with that, and the user named both: it conflates a CHOICE with
 * INFORMATION ABOUT the current choice, and it makes the segmented control's
 * geometry move whenever capabilities change.
 *
 * The rule the header follows instead is one a user can learn once: **the thing
 * beside the toggle is the detail of whichever mode is selected.** Explore's
 * detail is the seed being proxied to (`SeedPicker`, which already worked this
 * way); `local`'s detail is the identity; Embedded has no identity to show
 * until Phase 2, so its detail is the explanation in the toggle's own caption.
 *
 * That is also why this is absent rather than blank when there is no identity:
 * in Explore you are not operating as anyone, so an empty identity slot there
 * would be noise, and a placeholder would be worse — the same reasoning that
 * makes the Local segment's absence better than a disabled one.
 *
 * ## Why it is clickable
 *
 * The badge this replaces looked like a button and did nothing, which is what
 * made it read as broken. The two honest options were "style it as plain text"
 * or "make it do the obvious thing"; this does the second, because there IS an
 * obvious thing — the full DID, the resolved home and the mode picker all live
 * in Settings, and a user who is looking at a truncated identity is exactly the
 * user who wants them.
 */
Item {
    id: identity

    /// The local node's DID. "" means there is nothing to show, and this item
    /// then occupies no space at all.
    property string nodeId: ""

    /// Emitted when the user asks to see the identity in full.
    signal activated()

    /// A DID is far too long for chrome and its middle carries no meaning to a
    /// reader. The head is what people recognise and quote.
    readonly property string shortId: {
        if (nodeId === "") return "";
        // 14 characters. Shorter saves a little chrome and costs the id its only
        // job: two peers can share a `z6Mk` prefix, and a head too short to tell
        // them apart is decoration.
        var bare = nodeId.indexOf("did:key:") === 0 ? nodeId.substring(8) : nodeId;
        return bare.length > 14 ? bare.substring(0, 14) + "…" : bare;
    }

    visible: nodeId !== ""
    implicitWidth: visible ? label.implicitWidth : 0
    implicitHeight: Theme.rowHeightSm

    Text {
        id: label
        objectName: "nodeIdentityLabel"
        anchors.verticalCenter: parent.verticalCenter
        // No border, no background, no pill — this is a label that happens to
        // be actionable, not a button. The old badge had all three and did
        // nothing, which is the combination the user objected to.
        //
        // It states the identity and NOT the mode: the segment already says
        // "Local", and the badge saying "Attached" beside it was the duplicated
        // vocabulary that made the header unreadable.
        text: identity.shortId
        color: Theme.textDim
        font.pixelSize: Theme.fontSm
        font.family: Theme.mono
    }

    MouseArea {
        objectName: "nodeIdentity"
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        // Underline on hover, so the one affordance says "this does something"
        // without borrowing button chrome.
        hoverEnabled: true
        onEntered: label.font.underline = true
        onExited: label.font.underline = false
        onClicked: identity.activated()
    }
}
