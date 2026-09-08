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
 * ## Why the WHOLE did, and why it keeps its `did:key:` prefix
 *
 * This was truncated to `z6Mkowunyxpkcg…` and the user asked for the full id.
 * Three separate spellings of one identity exist, and which one is shown is a
 * decision rather than a detail:
 *
 *   DID   did:key:z6Mkowunyxpkcg…   what `rad self` prints, and the form
 *                                   `rad id update --allow <DID>` takes
 *   NID   z6Mkowunyxpkcg…           what `rad node connect <NID>` and
 *                                   `rad clone --seed <NID>` take
 *   hash  SHA256:…                  the SSH agent's spelling, irrelevant here
 *
 * The DID is shown, complete. It is unambiguous, it is what `rad self` prints
 * so a user can match it against their terminal by eye, and it is the form
 * needed to authorise a second node — which is the thing a user actually does
 * with this string. Stripping `did:key:` to get a NID is trivial for a user;
 * guessing the prefix back is not.
 *
 * It is emphatically NOT prefixed with `rad:`. That namespaces REPOSITORY ids
 * (`rad:z39LLirsD1d4BvWMa9gFoi2B88413`); a node id is a different namespace,
 * and prefixing it would be actively wrong rather than merely redundant.
 *
 * ## Why clicking copies
 *
 * The badge this replaces looked like a button and did nothing, which is what
 * made it read as broken. It was then made to open Settings — and the user
 * asked for copying instead, which is the better answer for the same reason the
 * DID is shown in full: the one thing anyone does with this string is paste it
 * somewhere. Settings remains reachable through the header's Settings chip, so
 * nothing became unreachable.
 *
 * The clipboard is reached through a hidden TextEdit's `selectAll()`/`copy()`,
 * because plain QtQuick exposes no Clipboard singleton and Basecamp sandboxes
 * the QML engine away from anything else that could do it. `tst_source.qml`
 * asserts the round trip through the real clipboard rather than trusting the
 * call was made — a copy button that silently does nothing is precisely the
 * failure this element has already been corrected for twice.
 */
Item {
    id: identity

    /// The local node's DID, in full: "did:key:z6Mk…". "" means there is
    /// nothing to show, and this item then occupies no space at all.
    property string nodeId: ""

    /// How long the copy confirmation stays up. Long enough to notice, short
    /// enough not to become permanent chrome.
    readonly property int confirmMs: 1600

    /// Emitted after the identity has been copied. Not used to DO the copying —
    /// that happens here, so a caller cannot wire this up and get a button that
    /// looks like it copies and does not.
    signal copied()

    visible: nodeId !== ""
    // The label plus the confirmation's reserved width, so the row does not
    // reflow when the confirmation appears. See `confirmSizer`.
    implicitWidth: visible ? label.implicitWidth + confirmGap + confirmSizer.width
                           : 0
    implicitHeight: Theme.rowHeightSm

    readonly property int confirmGap: Theme.gapSm

    /// Take down the confirmation immediately.
    ///
    /// Exists because the confirmation is time-based, and time-based state
    /// leaks between tests: one test's 1.6s timer is still running when the
    /// next starts, so a "nothing to confirm yet" precondition would fail for
    /// reasons that have nothing to do with the behaviour under test. A caller
    /// clearing state explicitly is better than a test sleeping.
    function clearConfirmation() {
        confirmTimer.stop();
    }

    /// Put the identity on the system clipboard.
    ///
    /// Via a TextEdit because there is no other route from sandboxed QML: no
    /// Clipboard singleton exists in QtQuick, and the engine cannot reach the
    /// filesystem or the network. The editor is invisible and read-only, so it
    /// is a clipboard handle rather than a control.
    function copyToClipboard() {
        if (nodeId === "") return;
        clip.text = nodeId;
        clip.selectAll();
        clip.copy();
        // Deselect so a stray focus event cannot overwrite what was copied.
        clip.deselect();
        confirmTimer.restart();
        identity.copied();
    }

    /// The clipboard handle. Never shown, never focusable, never in the layout.
    TextEdit {
        id: clip
        objectName: "nodeIdentityClipboard"
        visible: false
        activeFocusOnPress: false
        readOnly: true
    }

    Timer {
        id: confirmTimer
        interval: identity.confirmMs
        repeat: false
    }

    Text {
        id: label
        objectName: "nodeIdentityLabel"
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        // No border, no background, no pill — this is a label that happens to
        // be actionable, not a button. The old badge had all three and did
        // nothing, which is the combination the user objected to.
        //
        // It states the identity and NOT the mode: the segment already says
        // "Local", and the badge saying "Attached" beside it was the duplicated
        // vocabulary that made the header unreadable.
        //
        // The FULL did, with no elide: `elide` would reintroduce the truncation
        // the user asked to remove, silently, at whatever width the row
        // happened to give it. Monospace so the key-like tail is scannable and
        // so its width is predictable from its length.
        text: identity.nodeId
        color: Theme.textDim
        font.pixelSize: Theme.fontSm
        font.family: Theme.mono
    }

    /// Measures the widest confirmation this can show, so the space is
    /// RESERVED rather than claimed when the confirmation appears.
    ///
    /// Without this the row reflows on click: the identity grows, the flexible
    /// spacer beside it shrinks, and everything to its right shifts. The header
    /// has already regressed onto two lines once and the user complained, so
    /// nothing here is allowed to change size in response to a click.
    Text {
        id: confirmSizer
        visible: false
        text: "Copied"
        font.pixelSize: Theme.fontXs
    }

    /// Inline confirmation. Not a tooltip: the user has rejected hover
    /// affordances here twice, and this repo's last tooltip rendered as a
    /// clipped, unreadable sliver inside a fixed-height bar.
    Text {
        id: confirmText
        objectName: "nodeIdentityCopied"
        anchors.left: label.right
        anchors.leftMargin: identity.confirmGap
        anchors.verticalCenter: parent.verticalCenter
        visible: confirmTimer.running
        text: "Copied"
        // The one green in the header, and only for ~1.6s. A confirmation that
        // matched the label's own dim grey would be easy to miss, which defeats
        // the point of having one.
        color: Theme.good
        font.pixelSize: Theme.fontXs
    }

    MouseArea {
        objectName: "nodeIdentity"
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        // Underline on hover, so the one affordance says "this does something"
        // without borrowing button chrome. It is NOT the only signal that this
        // is actionable — the pointing-hand cursor and the confirmation carry
        // that too, because hover-only affordances have been rejected here.
        hoverEnabled: true
        onEntered: label.font.underline = true
        onExited: label.font.underline = false
        onClicked: identity.copyToClipboard()
    }
}
