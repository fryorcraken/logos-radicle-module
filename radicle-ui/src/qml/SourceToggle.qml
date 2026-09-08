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
 * ## Embedded is offered, and says what it will do
 *
 * Embedded cannot start a node until Phase 2, and a segment that silently does
 * nothing is the exact bug review already caught in this PR. It is neither
 * hidden (which would misrepresent the module as never intending to support it)
 * nor silently inert: the caption states the consequence in words, always
 * visible, and it does so BEFORE the segment is chosen — because a user has to
 * be able to see the caveat while deciding, not discover it afterwards.
 *
 * That is why the caveat is keyed on `startableModes` (a fact about the build)
 * rather than on `modeStartable` (a fact about the mode in force, which is true
 * in the default `local` state and says nothing whatever about Embedded).
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

        // The caveat for a mode this build cannot start. Keyed on the mode a
        // user is LOOKING AT choosing, not only on the one in force, so it is
        // readable while deciding. Embedded is that mode today.
        if (!isStartable("embedded"))
            return "Embedded runs a node inside Basecamp with its own separate "
                 + "identity — it is not available in this version yet, so "
                 + "choosing it will not start a node. "
                 + (isStartable(mode) || modeReason === "" ? "" : modeReason + " ")
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
    implicitWidth: Math.max(frame.width, noteText.visible ? noteText.width : 0)
    implicitHeight: frame.height
                    + (noteText.visible ? captionGap + noteText.height : 0)

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
                    implicitWidth: sizer.implicitWidth + Theme.gap * 2
                    implicitHeight: Theme.rowHeightSm - 6
                    radius: Theme.radiusSm - 1
                    color: selected ? Theme.accentSoft : "transparent"

                    Text {
                        id: sizer
                        visible: false
                        text: parent.modelData.label
                        font.pixelSize: Theme.fontSm
                        font.bold: true
                    }

                    Text {
                        id: label
                        objectName: "sourceToggleLabel_" + parent.modelData.key
                        anchors.centerIn: parent
                        text: parent.modelData.label
                        // Dimmed for a mode this build cannot start, so the
                        // caption below has something on screen to refer to —
                        // but NOT amber, and NOT disabled: it is still a real,
                        // persistable choice, and the caption says what
                        // choosing it will and will not do.
                        color: parent.selected ? Theme.text
                             : parent.startable ? Theme.textDim
                             : Theme.textFaint
                        font.pixelSize: Theme.fontSm
                        font.bold: parent.selected
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
