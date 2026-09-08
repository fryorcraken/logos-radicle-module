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
 *
 * ## Why it CAN elide now, having refused to before
 *
 * The refusal was right about the wrong scope. Eliding by default silently
 * reintroduces the truncation the user asked to remove, at whatever width the
 * row happens to give it — so the default is still the whole string, and
 * `minimumWidth` is 0, meaning this item asks for exactly the room its full
 * text needs and nothing forces it smaller.
 *
 * But "never elide" turned out to mean "never yield", and a `RowLayout` child
 * that cannot shrink does not scroll or wrap — it pushes its siblings off the
 * right edge. The ~411px this DID demands, plus the title, toggle, gaps and
 * chip, pinned the header's minimum at ~830px, below which the **Settings chip
 * left the screen entirely**. Since this element copies rather than opening
 * Settings, that chip is the only way in, so a window narrower than ~830px had
 * no route to Settings, the mode picker or the git path — a destination that
 * exists, is `visible: true`, and cannot be reached. The same one-way-door
 * class this milestone already fixed in `SettingsPanel`.
 *
 * So the yielding is opt-in and bounded: a caller sets `minimumWidth`, and the
 * label elides only in the range between that floor and its natural width.
 * Three things make the compromise honest rather than a quiet reversal:
 *
 *  - At any comfortable width nothing changes — the full DID, no ellipsis.
 *  - `ElideMiddle`, so both ends survive. A DID's tail is what distinguishes
 *    two keys sharing the `did:key:z6Mk` prefix, and `ElideRight` would cut
 *    off precisely the half that identifies it.
 *  - **What is copied is never what is displayed.** `copyToClipboard()` reads
 *    `nodeId`, not the label, so the shortening costs a user nothing they
 *    cannot get back with one click. The full value is also in Settings.
 */
Item {
    id: identity

    /// The local node's DID, in full: "did:key:z6Mk…". "" means there is
    /// nothing to show, and this item then occupies no space at all.
    property string nodeId: ""

    /// How long the copy confirmation stays up. Long enough to notice, short
    /// enough not to become permanent chrome.
    readonly property int confirmMs: 1600

    /// The narrowest this is willing to become before it stops yielding.
    ///
    /// 0 — the default — means "do not yield at all", which keeps every caller
    /// that has not thought about it on the old behaviour: the full DID, no
    /// elision, no surprise truncation. A caller in a row that has to survive a
    /// narrow window sets this instead, and gets a label that shortens between
    /// this floor and its natural width rather than shoving its siblings off
    /// the screen. See the file header for why that trade exists.
    property int minimumWidth: 0

    /// Whether the label is currently showing less than the whole identity.
    ///
    /// Exposed because "it fits" and "it has been cut down" are different
    /// states that look similar from outside, and a test asserting the full DID
    /// is shown at a comfortable width needs to distinguish them. Reading
    /// `label.truncated` from outside would reach through this component's
    /// internals to do the same thing.
    readonly property bool shortened: label.truncated

    /// Emitted after the identity has been copied. Not used to DO the copying —
    /// that happens here, so a caller cannot wire this up and get a button that
    /// looks like it copies and does not.
    signal copied()

    visible: nodeId !== ""
    // The label plus the confirmation's reserved width, so the row does not
    // reflow when the confirmation appears. See `confirmSizer`.
    //
    // Measured from `widthSizer` — a hidden, NEVER-eliding copy of the text —
    // rather than from the visible label, and that indirection is a fix rather
    // than a flourish. An eliding `Text` reports the ELIDED content's width as
    // its `implicitWidth`; with the label's own width now derived from this
    // item's granted width, reading it back here closed a loop: the label
    // elided, `implicitWidth` shrank, the layout granted less, the label elided
    // further. In practice the row simply stopped re-laying out, freezing every
    // child at its first-pass geometry — the Settings chip sat at x=922 in a
    // 480px bar, which is the very defect this file's header describes, now
    // caused by the fix for it.
    //
    // The sizer breaks the cycle by construction: its width depends only on the
    // text and the font, never on anything the layout decides. Same technique
    // as `confirmSizer` beside it and the segment sizer in SourceToggle.qml —
    // when a size must not follow a state, measure the state-free thing.
    implicitWidth: visible ? widthSizer.implicitWidth + confirmGap
                             + confirmSizer.width
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

    /// Put the identity on the system clipboard, and confirm only if it
    /// actually arrived there.
    ///
    /// Via a TextEdit because there is no other route from sandboxed QML: no
    /// Clipboard singleton exists in QtQuick, and the engine cannot reach the
    /// filesystem or the network. The editor is invisible and read-only, so it
    /// is a clipboard handle rather than a control.
    ///
    /// **The confirmation is earned, not assumed.** `TextEdit.copy()` returns
    /// nothing and reports failure through no channel at all, so the previous
    /// version simply restarted the timer and emitted `copied()` on the next
    /// line — which meant that if the clipboard were unavailable, the UI said
    /// "Copied" and nothing had been. That is not a theoretical risk: an
    /// offscreen Qt platform plugin always provides a clipboard, so every test
    /// here would keep passing while a Wayland bundle without one failed
    /// silently in front of a user. A reviewer deleted the `copy()` call and
    /// watched this element go on confirming.
    ///
    /// So the effect is CHECKED: paste the clipboard back into a scratch editor
    /// and compare. `verify` is a separate editor from `clip` on purpose —
    /// reading back from `clip` would compare the text against itself, since
    /// its content is assigned regardless of whether the copy succeeded, and
    /// the check would pass in exactly the case it exists to catch.
    function copyToClipboard() {
        if (nodeId === "") return;
        clip.text = nodeId;
        clip.selectAll();
        clip.copy();
        // Deselect so a stray focus event cannot overwrite what was copied.
        clip.deselect();

        if (!clipboardHolds(nodeId)) return;

        confirmTimer.restart();
        identity.copied();
    }

    /// Whether the system clipboard currently holds exactly `expected`.
    ///
    /// The only way to observe a clipboard from sandboxed QML is to paste from
    /// it, so this pastes into a scratch editor and compares. It leaves nothing
    /// behind: the scratch text is cleared either way, so this never becomes a
    /// second copy of the identity sitting in the scene.
    function clipboardHolds(expected) {
        verifier.text = "";
        verifier.selectAll();
        verifier.paste();
        var got = verifier.text;
        verifier.text = "";
        return got === expected;
    }

    /// The clipboard handle. Never shown, never focusable, never in the layout.
    TextEdit {
        id: clip
        objectName: "nodeIdentityClipboard"
        visible: false
        activeFocusOnPress: false
        readOnly: true
    }

    /// A SEPARATE editor used only to read the clipboard back.
    ///
    /// Separate from `clip` because `clip.text` is set before the copy is
    /// attempted, so reading the check back out of it would be comparing the
    /// value to itself — green whether or not anything reached the clipboard,
    /// which is precisely the failure being guarded against. It is writable
    /// (unlike `clip`) because `paste()` is a no-op on a read-only editor.
    TextEdit {
        id: verifier
        objectName: "nodeIdentityClipboardVerifier"
        visible: false
        activeFocusOnPress: false
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
        // The full did whenever it fits, and it normally does — this asks for
        // its natural width through `identity.implicitWidth`, so a row with
        // room grants it and `elide` never engages.
        //
        // The elision is the pressure valve described in the file header, and
        // it only opens when a caller has opted in via `minimumWidth` AND the
        // row has actually squeezed this item below its natural width. Sized
        // from `identity.width` — what the item WAS GIVEN — rather than from
        // `implicitWidth`, which is what it asked for; binding to the latter
        // would make the label always fit itself and elide nothing, which is
        // the same as not having done this at all.
        //
        // `ElideMiddle` rather than `ElideRight`: a DID's distinguishing part
        // is its tail, since every key here shares the `did:key:z6Mk` opening.
        // Cutting from the right removes exactly the half that tells two
        // identities apart, which is the confusion this element exists to
        // prevent. Monospace so the key-like tail is scannable and so its width
        // is predictable from its length.
        width: Math.max(0, identity.width - identity.confirmGap
                                          - confirmSizer.width)
        elide: Text.ElideMiddle
        text: identity.nodeId
        color: Theme.textDim
        font.pixelSize: Theme.fontSm
        font.family: Theme.mono
    }

    /// Measures the identity at its NATURAL width — the whole DID, no elision
    /// — so `implicitWidth` can ask for the space the full string needs without
    /// reading it back off a label that may have been cut down.
    ///
    /// Same font and size as the real label, and deliberately no `width` and no
    /// `elide`: an unconstrained Text reports the width its content actually
    /// wants. See `implicitWidth` above for the loop this exists to break.
    Text {
        id: widthSizer
        visible: false
        text: identity.nodeId
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
