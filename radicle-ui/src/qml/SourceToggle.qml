import QtQuick
import QtQuick.Layouts
import "Theme.js" as Theme

/**
 * What you are browsing: one segmented control, exactly three segments.
 *
 * ## One question per control
 *
 * The header used to carry a two-segment source toggle (`Explore`/`Local`), a
 * separate `NodeStatus` badge reading "Attached · z6Mko…", and the seed picker,
 * butted together with no separation. A user read the run of them as ONE
 * segmented control with a dead third segment, reported it as *"the attached is
 * still garbage, and I dont understand it"*, and read the badge's amber styling
 * as a warning on Local — a feature that works fine on their machine.
 *
 * The layout was only the visible half. The real fault was that the module had
 * **two overlapping vocabularies for one question**: a UI `source`
 * (`remote`/`local`) the user picked here, and a persisted backend `mode`
 * (`attach`/`embedded`/`seedOnly`) picked in Settings. They said the same thing
 * twice, in different words, and the badge was the mode vocabulary leaking onto
 * a screen that otherwise spoke source.
 *
 * So there is one setting now — the mode — and the SEGMENT IS THE MODE, using
 * the same word the user reads:
 *
 *     explore   ->  Explore     a seed node over HTTPS, no local profile touched
 *     local     ->  Local       the Radicle node already on this machine
 *     embedded  ->  Embedded    a node Basecamp runs itself (Phase 2)
 *
 * The method prefix (`remote*`/`local*`) is derived from it — see
 * SourceState.qml — so there is no second thing to keep in sync.
 *
 * ## The identity is NOT in here, deliberately
 *
 * An earlier attempt at this fix put the DID inside the Local segment's label.
 * That was wrong for two reasons the user named directly:
 *
 *  - It conflates a CHOICE with INFORMATION ABOUT the current choice. "What am
 *    I browsing" and "who am I" are different questions, and a segment is an
 *    answer to the first.
 *  - It makes segment widths follow the identity, so the control's geometry
 *    moves for reasons that have nothing to do with the control.
 *
 * The identity lives beside this control, in `NodeIdentity.qml`. That is close
 * to where the old badge sat, and the difference is the point: the objection to
 * the badge was never that identity was shown — it was that the badge looked
 * like a button, did nothing when clicked, and restated the mode in a second
 * vocabulary. `NodeIdentity` is clickable, opens Settings, and shows the
 * identity only.
 *
 * ## Why there is no tooltip
 *
 * There was one, and it did not work: a `Rectangle` anchored to `parent.bottom`
 * with `z: 100`, inside a fixed-height header bar. `z` orders siblings within
 * ONE parent; it cannot lift an item above a later sibling of a DIFFERENT
 * parent, so the tip rendered as a clipped, unreadable sliver — and it was
 * `Theme.textDim` on `Theme.raised`, which is low contrast even unclipped.
 *
 * The right fix was not a better tooltip. Everything that was in it is
 * information the user needs in order to understand the control at all, so it
 * is on screen unconditionally, as a caption line that is part of this item's
 * own layout and therefore cannot be clipped by a parent it does not overflow.
 * `tst_source.qml` asserts that on geometry rather than by clicking — a click
 * test structurally cannot see a clipped overlay, which is what CommitView's
 * back button taught this repo.
 *
 * ## Embedded is offered, and says what it will do — in two places, on purpose
 *
 * Embedded cannot start a node until Phase 2, and a segment that silently does
 * nothing is the exact bug review already caught in this PR. It is neither
 * hidden (which would misrepresent the module as never intending to support it)
 * nor silently inert.
 *
 * The first version said so in ONE place: the caption, shown unconditionally.
 * That met the honesty requirement and failed a different one — the user asked
 * for it gone (*"remove the text under the toggle when embeded is NOT
 * selected"*), and rightly: a paragraph about a mode you have not chosen, on
 * every screen, pushing the content down, is noise. But deleting it outright
 * would have put the caveat back behind the choice, which is the original bug.
 *
 * So the one message is split by who needs it and when:
 *
 *  - **The segment carries a marker**, always, for any mode this build cannot
 *    start. Small enough to be chrome, present while DECIDING, and not behind
 *    a hover — the user rejected tooltips here, and this repo's last one
 *    rendered as a clipped, unreadable sliver.
 *  - **The caption carries the paragraph**, and only while that mode is
 *    SELECTED. The consequence that actually matters — a separate identity —
 *    needs a sentence, and the moment it is worth a sentence is the moment the
 *    user has committed to the mode.
 *
 * The marker's styling is deliberately not the error colour: Embedded is not
 * broken, it is not built yet, and this repo has already taken the complaint
 * from the other direction (*"why the warning sign for local????"* on a feature
 * that works).
 *
 * Both are keyed on `startableModes` (a fact about the build) rather than on
 * `modeStartable` (a fact about the mode in force, which is true in the default
 * `local` state and says nothing whatever about Embedded).
 *
 * ## One vocabulary, top to bottom
 *
 * `explore`/`local`/`embedded` are the values `settings_store.h` defines, the
 * values written to the settings file, the strings `getCapabilities()` reports
 * — and, capitalised, the words on the segments. That is deliberate: they used
 * to differ, and the gap is how the module ended up with two names for one
 * thing on one screen. A rename on either side is a rename on both.
 */
Item {
    id: toggle

    /// The persisted mode: "explore" | "local" | "embedded".
    property string mode: "local"

    /// Which modes this build can actually start, from
    /// `getCapabilities().startableModes`.
    ///
    /// **Must come from that array, never from `modeStartable`.** The boolean
    /// answers "can the mode in force start?"; this control needs "which modes
    /// can start at all?", and one cannot be derived from the other. A caller
    /// that tried shipped a picker which, in the default state, offered
    /// Embedded with no caveat whatever — see SettingsPanel.qml.
    ///
    /// The default is conservative rather than "the two that work today": a
    /// caller that forgets to wire this gets over-annotation, which is visible,
    /// instead of under-annotation, which is exactly the bug.
    property var startableModes: []

    /// Why the chosen mode cannot start, from
    /// `getCapabilities().modeUnavailableReason`. Shown verbatim. Empty is
    /// normal — it is populated only for the mode IN FORCE, so the caption
    /// falls back to its own wording for an unstartable mode nobody selected.
    property string modeReason: ""

    /// Whether the current mode found a readable local profile, from
    /// `getCapabilities().localAvailable`. Already mode-aware: explore and
    /// embedded report false because their store has no home.
    property bool localAvailable: false

    /// Why local browsing is unavailable in a mode that wanted it — used only
    /// for `local`, where "you have no ~/.radicle" is the ordinary case.
    property string reason: ""

    /// A problem with the resolved paths (e.g. the control socket over the
    /// 108-byte cap), "" when there is none. Distinct from "the node is not
    /// running": different problem, different fix, so it gets its own sentence.
    property string pathsProblem: ""

    /// A mode was picked. The caller persists it — see SourceState.select().
    signal modeChosen(string mode)

    /// The three modes, in the order a user meets them: the one needing
    /// nothing, the one needing an existing node, the one that would run its
    /// own. A list rather than three branches, so a fourth mode is one entry.
    ///
    /// The KEY is the persisted value and the LABEL is what is read; after the
    /// rename they are the same word, which is the point — but they stay
    /// separate fields so a label can still gain a space or a capital without
    /// anyone thinking that changed what gets stored.
    readonly property var segments: [
        { key: "explore",  label: "Explore" },
        { key: "local",    label: "Local" },
        { key: "embedded", label: "Embedded" }
    ]

    function isStartable(key) {
        for (var i = 0; i < startableModes.length; i++)
            if (startableModes[i] === key) return true;
        return false;
    }

    /// Whether anything about the CURRENT mode needs attention.
    ///
    /// Deliberately NOT true merely because a profile is absent in `local`: a
    /// machine without Radicle installed is not in an error state, it just has
    /// nothing local to show. Flagging that was the regression the user hit
    /// from the other direction — a warning colour on a working feature.
    readonly property bool hasProblem: pathsProblem !== "" || !isStartable(mode)

    /// The one sentence the header owes the user, or "" when it owes none.
    ///
    /// Ordered by which problem blocks the others: unusable paths mean nothing
    /// local can work at all; a mode this build cannot start will never come
    /// up; and a missing profile in `local` is the ordinary "you have not set
    /// Radicle up" case. Only one is shown, because two stacked sentences in
    /// chrome is a paragraph nobody reads — the rest is in Settings.
    readonly property string note: {
        if (pathsProblem !== "")
            return pathsProblem + " — change it in Settings.";

        // The paragraph about Embedded, shown only while Embedded is SELECTED.
        //
        // It used to be unconditional, which put a caveat about a mode the user
        // had not chosen on every screen. What replaces it in the other modes is
        // the per-segment marker below — so the caveat is still visible BEFORE
        // the choice, which is the requirement, without the paragraph being
        // permanent chrome.
        if (mode === "embedded" && !isStartable("embedded"))
            return "Embedded runs a node inside Basecamp with its own separate "
                 + "identity — it is not available in this version yet, so "
                 + "choosing it will not start a node. "
                 + (modeReason === "" ? "" : modeReason + " ")
                 + "Modes are explained in Settings.";

        if (!isStartable(mode))
            return (modeReason !== ""
                    ? modeReason
                    : "This build cannot start the selected mode yet.")
                 + " Change it in Settings.";

        if (mode === "local" && !localAvailable && reason !== "")
            return reason;

        return "";
    }

    // Sized by its own content. Deliberately NOT `anchors.fill`-ing a child to
    // this item while also deriving this item's size from that child: that is a
    // binding loop, and QML resolves it by quietly giving something zero size —
    // after which `mouseClick` lands outside every segment and the control is
    // click-dead while still looking correct.
    /// Gap between the control and its caption.
    readonly property int captionGap: 2

    // Laid out by arithmetic rather than by a Column, and that is a fix rather
    // than a style preference.
    //
    // With a Column, this item's `implicitHeight` came from
    // `column.implicitHeight`, which came from the caption's wrapped height,
    // which the Column only republishes on its next polish. So for one frame
    // after the caption's text changed, the item reported a height that did not
    // contain its own content — a caption genuinely hanging outside its parent,
    // which is EXACTLY the clipping bug this caption exists to replace, just
    // arriving from a different direction. A test caught it; the honest fix is
    // to remove the lag, not to wait it out.
    //
    // Two children stacked vertically is arithmetic, so it is written as
    // arithmetic: every term below is a direct binding with no layout pass in
    // between, and the height is correct in the same frame the text changes.
    //
    // The caption is CONDITIONAL — only the selected Embedded mode has one —
    // and so is the space this item takes for it. **The reservation that stops
    // the header jumping lives on the BAR, not here**, and that split is the
    // whole point of `reservedHeight` below.
    //
    // The previous version put the reservation in this item's own
    // `implicitHeight`, so the control was 72px tall in every mode while only
    // its top 28px drew anything. Two user-visible faults came straight out of
    // that, and they are one defect seen twice:
    //
    //  - The header row centres what it is given. A 72px box whose content sits
    //    at the top centres 22px higher than the 28px items beside it, so the
    //    node identity and the title rendered on a visibly different line from
    //    the segments — reported as *"node id is not on the same line anymore"*.
    //  - The 44px of dead space is part of the control's hit area but draws
    //    nothing, so the strip a user aims at is not where the strip appears to
    //    be. Clicks that look like they land on a segment land under it.
    //
    // So this item is sized by what it actually renders, which is the rule the
    // rest of the file already follows, and the caption's budget is published
    // for the container to honour.
    implicitWidth: Math.max(frame.width, noteText.visible ? noteText.width : 0)
    implicitHeight: frame.height
                    + (noteText.visible ? captionGap + noteText.height : 0)

    /// The height this control needs when its caption IS showing — what a
    /// container must budget so the chrome does not resize between modes.
    ///
    /// Read by Main.qml's top bar instead of `implicitHeight`. The distinction
    /// matters and is why this is a second property rather than a taller
    /// `implicitHeight`: the BAR must be the same height in every mode, or the
    /// body below it slides on the very click that switched modes (a 44px jump
    /// that tst_layout.qml catches). The CONTROL must be the height of what it
    /// draws, or the row centres it against its empty half and the items beside
    /// it fall off its line.
    ///
    /// One number, consumed by whichever item the constraint actually belongs
    /// to. Putting both on `implicitHeight` is what made the two requirements
    /// look like one and traded a real jump for a real misalignment.
    readonly property int reservedHeight:
        frame.height + captionGap
        + Math.max(captionSizer.height,
                   noteText.visible ? noteText.height : 0)

    /// The tallest caption this control can render, measured off-screen.
    ///
    /// The Embedded paragraph is the longest of the branches in `note` that
    /// this component writes itself. The two it does not write — `pathsProblem`
    /// and `reason` — are injected sentences of unbounded length, so they are
    /// not measurable in advance; they are also the cases where a slightly
    /// taller bar is the correct outcome, since the alternative is clipping a
    /// message about something being broken. Hence Math.max below rather than
    /// this alone.
    Text {
        id: captionSizer
        visible: false
        width: Theme.captionWidth
        font.pixelSize: Theme.fontXs
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "Embedded runs a node inside Basecamp with its own separate "
            + "identity — it is not available in this version yet, so "
            + "choosing it will not start a node. Modes are explained in "
            + "Settings."
    }

    // ---- the segmented control ----------------------------------------
    Rectangle {
        id: frame
        x: 0
        y: 0
        width: row.implicitWidth + Theme.gapXs * 2
        height: Theme.rowHeightSm
        radius: Theme.radiusSm
        color: Theme.bg
        border.width: 1
        // Amber only for a REAL problem with the mode in force. A machine with
        // no Radicle profile is not a problem; see hasProblem.
        border.color: toggle.hasProblem ? Theme.warn : Theme.border

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: 2

            Repeater {
                model: toggle.segments

                // The MouseArea, not this Rectangle, is what a sitometres spec
                // clicks — naming the wrapper matches an element that is not
                // clickable. Hence objectName on the MouseArea.
                Rectangle {
                    required property var modelData

                    readonly property bool selected: toggle.mode === modelData.key
                    readonly property bool startable: toggle.isStartable(modelData.key)

                    // Sized from a PERMANENTLY BOLD measuring text, not from
                    // the visible label, so selecting a segment does not
                    // resize it.
                    //
                    // Not cosmetic. When the width followed the bold state,
                    // every click re-laid the row out: the segment just
                    // selected grew, its neighbour shifted, and a click
                    // computed against the old geometry landed on the WRONG
                    // segment. A test caught exactly that. A user clicking
                    // twice quickly hits the same window, and it reads as "the
                    // toggle sometimes ignores me". Making the test wait for a
                    // re-layout would have hidden a real defect behind a slower
                    // test, so the control is stable instead.
                    //
                    // This is also the second reason the identity is not in
                    // here: a label carrying a DID would move the geometry
                    // every time capabilities changed.
                    // The marker is part of the measured width, not an overlay
                    // on top of the label. An absolutely-positioned dot would
                    // have been fewer lines and would have sat ON the text of
                    // the longest label at small widths; including it in the
                    // arithmetic is what keeps the segment readable.
                    //
                    // It depends on `startable` — a fact about the BUILD — and
                    // never on `selected`, so it cannot reintroduce the
                    // width-follows-selection defect the sizer exists to
                    // prevent. Selecting a segment still changes nothing about
                    // its geometry.
                    implicitWidth: sizer.implicitWidth
                                   + (startable ? 0 : markerGap + marker.width)
                                   + Theme.gap * 2
                    implicitHeight: Theme.rowHeightSm - 6
                    radius: Theme.radiusSm - 1
                    color: selected ? Theme.accentSoft : "transparent"

                    readonly property int markerGap: Theme.gapXs

                    Text {
                        id: sizer
                        visible: false
                        text: parent.modelData.label
                        font.pixelSize: Theme.fontSm
                        font.bold: true
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: parent.markerGap

                        Text {
                            id: label
                            objectName: "sourceToggleLabel_" + parent.parent.modelData.key
                            anchors.verticalCenter: parent.verticalCenter
                            text: parent.parent.modelData.label
                            // Dimmed for a mode this build cannot start, so the
                            // marker beside it has something to qualify — but
                            // NOT amber, and NOT disabled: it is still a real,
                            // persistable choice.
                            color: parent.parent.selected ? Theme.text
                                 : parent.parent.startable ? Theme.textDim
                                 : Theme.textFaint
                            font.pixelSize: Theme.fontSm
                            font.bold: parent.parent.selected
                        }

                        // "Not built yet", said on the segment itself so it is
                        // legible while DECIDING — which is the requirement the
                        // caption used to meet by being permanent, and the one
                        // that would have been lost by simply deleting it.
                        //
                        // A hollow ring rather than a filled dot or a glyph: an
                        // outline reads as "nothing here yet", where a filled
                        // mark reads as a status light and a "!" reads as an
                        // error. Embedded is not broken.
                        //
                        // `Theme.textFaint`, deliberately NOT `Theme.bad` and
                        // not `Theme.warn`. The user's complaint from the other
                        // direction — a warning colour on Local, a feature that
                        // works — is the same mistake with the sign flipped.
                        Rectangle {
                            id: marker
                            objectName: "sourceToggleUnavailable_"
                                        + parent.parent.modelData.key
                            visible: !parent.parent.startable
                            anchors.verticalCenter: parent.verticalCenter
                            width: 7
                            height: 7
                            radius: width / 2
                            color: "transparent"
                            border.width: 1
                            border.color: Theme.textFaint
                        }
                    }

                    MouseArea {
                        objectName: "sourceToggle_" + parent.modelData.key
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: toggle.modeChosen(parent.modelData.key)
                    }
                }
            }
        }
    }

    // ---- the caption --------------------------------------------------
    // Always on screen when there is anything to say, never on hover. This is
    // the whole of the old tooltip's job, done where it can actually be read:
    // a child of this item, positioned by arithmetic, so it cannot be clipped
    // by a fixed-height bar the way an overflowing overlay was.
    //
    // `Theme.text` rather than `Theme.textDim`: the previous version was
    // dim-on-raised and effectively invisible even where it was not clipped.
    // A sentence worth showing is worth reading.
    Text {
        id: noteText
        objectName: "sourceToggleNote"
        visible: toggle.note !== ""
        x: 0
        y: frame.height + toggle.captionGap
        // A FIXED measure, not `frame.width`. Two reasons, and the second is
        // the one that bit:
        //
        //  - A caption is a paragraph. Sizing it to a segmented control that
        //    happens to be ~200px gives a column too narrow to read.
        //  - Tracking the frame made this height depend on a chain — text
        //    metrics, segment width, row width, frame width, wrap, height —
        //    that settles over several layout passes. The control's own
        //    `implicitHeight` therefore lagged its content, and for a frame
        //    the caption really was outside its parent. That is
        //    indistinguishable from the clipping bug this caption replaces,
        //    so the dependency is cut rather than waited out.
        width: Theme.captionWidth
        text: toggle.note
        color: toggle.hasProblem ? Theme.warn : Theme.text
        font.pixelSize: Theme.fontXs
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
    }
}
