import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Radicle.js" as R
import "Theme.js" as Theme

/*
 * Radicle browser.
 *
 * The view holds no Radicle logic: every call is a pass-through to the
 * radicle_ui backend (C++/QtRO), which forwards to the `radicle` core module.
 * QML does navigation and rendering only.
 *
 * Two sources, kept visibly distinct because they answer different questions:
 *   Any repo — any public repo on a seed node, no local node needed.
 *   My node  — this machine's own node, including private repos.
 *
 * Layout rule: the top bar, status strip and repo chrome have FIXED heights
 * from Theme, and both screens live in a StackLayout that fills what is left.
 * Nothing below the chrome reflows when a request starts or a screen changes.
 */
Item {
    id: root

    implicitWidth: 1000
    implicitHeight: 700

    // Basecamp sizes the root itself (QQuickWidget + SizeRootObjectToView),
    // and parents it into a *widget* layout, so QML Layout attached properties
    // on the root have no attachee and are inert. Kept only for the case where
    // this view is embedded in a QML layout instead.
    Layout.fillWidth: true
    Layout.fillHeight: true

    // ---- backend wiring ---------------------------------------------------

    readonly property var backend: (typeof logos !== "undefined" && logos)
                                   ? logos.module("radicle_ui") : null
    property bool ready: false

    readonly property string capsJson: backend ? backend.capabilities : ""
    property var caps: ({})

    // Which mode the module is in, and the method routing that follows from it.
    // Both live in SourceState so they can be tested as a unit — inside this
    // file they could only be covered by a stub reproducing them, which is a
    // copy asserted against itself. See SourceState.qml.
    //
    // `mode` is BOUND to capabilities rather than owned here: the backend is
    // the authority on what is in force, and a UI holding its own copy could
    // show a mode the module is not actually in. That is the identity confusion
    // this milestone exists to prevent, one level up.
    // The `|| "explore"` is the pre-capabilities guess. It matters because
    // `onBackendReady()` calls `repoList.reload()` without waiting for the
    // first `getCapabilities` reply, so whatever this evaluates to in that
    // window decides which backend surface the very first list call reaches.
    // It was `|| "local"`, and on a machine with no Radicle profile that
    // issued `localListRepos`, got the "no local profile" error, and left the
    // list empty with the seed never asked. `explore` is the inert guess and
    // matches SettingsStore's own default — see SourceState.mode.
    readonly property SourceState sourceState: SourceState {
        mode: root.caps.mode || "explore"
        localAvailable: root.caps.localAvailable === true
        startableModes: root.caps.startableModes !== undefined
                        ? root.caps.startableModes : []

        // A repo id from one source is meaningless to the other, so the whole
        // navigation stack resets on the click — immediately, because the
        // screen must stop showing the previous mode's data the moment the
        // user asks for a different one.
        //
        // It does NOT reload here. `nav.reset()` clears state but does not
        // refetch (NavState is a pure holder and the caller owns reloading),
        // and the reload belongs on `settled()` instead — the click happens
        // while the write is still in flight, so nothing derived from the mode
        // describes the mode being switched TO yet. SourceState.settled()
        // carries the full reasoning and the three defects it fixed.
        onChanged: nav.reset()

        // The mode the module is actually in has changed. Reset again — an
        // in-flight reply from the previous mode may have latched an error
        // after the click's reset — and then reload.
        //
        // Deferred by one turn because `repoList.reload()` reads `app.source`
        // and `app.modeStartable`, bindings derived from `mode` that have NOT
        // been re-evaluated inside this handler. That is the branch-switch trap
        // CLAUDE.md documents, and the same remedy.
        onSettled: {
            nav.reset();
            sourceReload.restart();
        }
    }

    readonly property Timer sourceReload: Timer {
        interval: 0
        repeat: false
        onTriggered: {
            // Ask what Embedded's home and node are doing BEFORE reloading, so
            // the replies are on their way while the reload runs. The reload
            // itself declines to fetch until one of them says there is a node —
            // see `embeddedSettled` for the ordering that closes.
            //
            // Both run from the deferred timer rather than from `onSettled`
            // itself, because `root.mode` is a binding to `sourceState.mode` and
            // inside that handler it has not been re-evaluated: the same trap
            // that made branch switching a dead feature for a whole milestone.
            root.refreshEmbedded();
            repoList.reload();
        }
    }

    /// Convenience aliases. Views read these rather than reaching through
    /// `sourceState`, so moving the state again does not touch every consumer.
    ///
    /// `source` is the backend METHOD PREFIX ("remote"/"local"), derived from
    /// the mode. `mode` is the persisted choice. They are different things even
    /// though `local` is spelled the same in both — see SourceState.qml.
    readonly property string source: sourceState.current
    readonly property string mode: sourceState.mode
    readonly property bool localAvailable: sourceState.localAvailable

    /// Whether the mode in force is one the user operates as an identity in —
    /// what gates the header's DID. Derived there rather than here, from one
    /// rule covering every mode; see `SourceState.modeHasIdentity` for why it
    /// is not a list of mode names.
    readonly property bool modeHasIdentity: sourceState.modeHasIdentity

    /// Whether this build can start the mode in force. Read by RepoList to
    /// decide whether to fetch at all — see SourceState.modeStartable for why
    /// that is derived from the startable SET rather than compared against a
    /// mode name.
    readonly property bool modeStartable: sourceState.modeStartable

    /// Whether a write could actually succeed, and why not when it could not.
    ///
    /// Separate from `localAvailable` on purpose, and the core module's header
    /// states the rule: a profile can exist while its key stays locked, so
    /// gating a compose box on `localAvailable` would offer one that cannot be
    /// submitted. `canWriteLocal` is a real probe for a usable signing key.
    ///
    /// The reason is carried because the absence has to be explained — "no
    /// node" and "node, but locked" prompt different actions, and a missing
    /// button explains neither.
    readonly property bool canWrite: caps.canWriteLocal === true
    readonly property string writeUnavailableReason: caps.writeUnavailableReason || ""

    // ---- what Embedded's state panel reads --------------------------------
    //
    // Seven states, derived in `EmbeddedState.qml` from three backend replies.
    // `getCapabilities()` pushes itself, so `pathsProblem` needs no call;
    // `getEmbeddedIdentity()` and `getNodeStatus()` are slots, so they are asked.
    //
    // **These are reply FIELDS, not a state.** Nothing here decides which state
    // is in force — that derivation lives in one place, and holding a decided
    // state here would be a second opinion that is wrong the moment a node dies
    // or a passphrase is refused.

    /// `getCapabilities().pathsProblem` — the socket path problem, verbatim.
    readonly property string embeddedPathsProblem: caps.pathsProblem || ""

    /// The last `getEmbeddedIdentity()` reply's fields.
    ///
    /// `embeddedEncrypted` defaults TRUE, unlike its neighbours, and the
    /// asymmetry is the point: before any reply has landed, `true` means the
    /// surface asks for a passphrase nobody needs — visible, one dismissal —
    /// while `false` means it starts a node unasked on a reply nobody supplied.
    property string embeddedHome: ""
    property bool embeddedIdentityExists: false
    property bool embeddedEncrypted: true

    /// The last `getNodeStatus()` reply's fields.
    property bool embeddedRunning: false
    property bool embeddedServing: false

    /// Whether a `startNode` this view issued is outstanding, the last refusal,
    /// and whether one of this view's own starts has ever succeeded.
    ///
    /// None of the three is in any reply — the node cannot tell you whether you
    /// are waiting for it, nor who started it — so all three are the view's.
    /// `startPending` is cleared by the REPLY rather than by the call having
    /// been made, or a node that never answers would settle into "not serving"
    /// while its start is genuinely still in flight.
    ///
    /// `embeddedStartSucceeded` is what keeps a node THIS MODULE started from
    /// being reported as one in the way. `getNodeStatus()` reports the same two
    /// fields either way, so without it the surface would warn about socket
    /// contention over its own success — which is exactly what the setup flow's
    /// step 5 shipped.
    property bool embeddedStartPending: false
    property string embeddedStartError: ""
    property bool embeddedStartSucceeded: false

    // ---- which Embedded requests this host routes -------------------------
    //
    // The state panel names an action per state; these say which of those
    // requests actually reach something able to carry them out. A panel keyed on
    // these renders an unhosted act as named-but-disabled with a sentence, which
    // is the whole point: an enabled control that does nothing reads as a broken
    // module rather than an unbuilt feature.

    /// "setup" is routed: `onEmbeddedActionTaken` raises the setup overlay.
    readonly property bool embeddedSetupHosted: true

    /// "start" is routed now, and what unblocked it was a core change.
    ///
    /// It was unhosted because nothing could determine whether a passphrase was
    /// needed: only `createEmbeddedIdentity`'s reply carried an `encrypted`
    /// field, and that is a reply no later session holds. `getEmbeddedIdentity()`
    /// reports one now, observed from the key on disk — so the surface knows
    /// whether to ask, asks where it must, and starts by itself where it need
    /// not.
    ///
    /// **The flag alone was never the whole change**, and the routing below
    /// reads this same property so the two cannot disagree. Arming it without
    /// writing the branch would have shipped an enabled control whose click was
    /// dropped on the floor.
    ///
    /// Note `RepoList` does not route a start through
    /// `embeddedActionTaken`/`takeEmbeddedAction` at all: the passphrase field
    /// is on that surface, and handing the value out through a signal would put
    /// a plaintext secret in a host with no other use for it. This flag governs
    /// the panel's ENABLEMENT, and `routesEmbeddedAction` keeps the table
    /// honest for any caller that does route one.
    readonly property bool embeddedStartHosted: true

    /// "restart" is NOT routed, and this is structural rather than unfinished
    /// wiring.
    ///
    /// A restart is a stop followed by a start, whose two refusals are different
    /// sentences a user should see separately, and nothing here sequences the
    /// pair. It belongs to the node's configuration panel.
    ///
    /// **Split from `embeddedStartHosted`, which it shared until this change.**
    /// One flag was right while both acts were unhosted for one shared reason;
    /// with start hosted, one flag would have enabled a restart that reaches
    /// nobody — the dead end `embedded-state` exists to remove, re-created one
    /// state along.
    readonly property bool embeddedRestartHosted: false

    /// Re-read what Embedded's home and node are doing.
    ///
    /// Only in Embedded: in the other two modes the answers describe a node
    /// nothing is showing, and `getNodeStatus` probes a control socket. Called
    /// on mode settle and on backend ready rather than polled — the panel is a
    /// state a user acts on, not a live monitor, and polling belongs with node
    /// control in Settings › Node.
    function refreshEmbedded() {
        if (!backend || mode !== "embedded") return;
        callPlain("getEmbeddedIdentity", [], function (reply) {
            root.embeddedHome = reply.home || "";
            root.embeddedIdentityExists = reply.exists === true;
            // Read as `!== false` rather than `=== true`, so a reply from a
            // build that predates this field does not read as an unencrypted
            // key and start a node unasked. An absent answer means "assume one
            // is needed", which is the direction that costs a dismissal rather
            // than a start nobody asked for.
            root.embeddedEncrypted = reply.encrypted !== false;
        });
        callPlain("getNodeStatus", [], function (reply) {
            root.embeddedRunning = reply.running === true;
            root.embeddedServing = reply.serving === true;
        });
    }

    /// Start the embedded node, with `passphrase` — empty for an unencrypted
    /// key.
    ///
    /// **The one act this host performs on the Embedded surface's behalf rather
    /// than routing.** `RepoList` calls it directly, both for the start it
    /// issues by itself and for the one a typed passphrase submits, because the
    /// passphrase lives on that surface: handing it out through
    /// `embeddedActionTaken(kind)` would either widen that signal to carry a
    /// plaintext secret or make this host hold one it has no other use for.
    ///
    /// `callSettings`, not `callPlain`: a refused start is the useful result —
    /// it names the passphrase that did not unlock the key, the socket in use
    /// or the home in the way — and the panel displays it verbatim.
    ///
    /// `startPending` is cleared by the REPLY, never by the call having been
    /// made, so a node that never answers stays `starting` rather than settling
    /// into "not serving" with its start still in flight.
    ///
    /// `startSucceeded` latches on the first success and is never cleared here.
    /// It answers "did this module put a node on that socket", and stopping or
    /// crashing afterwards does not make the answer no — while clearing it would
    /// make this surface warn about contention with a node it started itself,
    /// which is the defect the field exists to prevent.
    function startEmbeddedNode(passphrase) {
        if (!backend || embeddedStartPending) return;
        embeddedStartPending = true;
        embeddedStartError = "";
        callSettings("startNode", [passphrase], function (reply) {
            root.embeddedStartPending = false;
            if (reply && reply.error) {
                root.embeddedStartError = reply.error;
                return;
            }
            // Only a `started:true` reply counts. A reply that merely arrived is
            // not a started node.
            if (reply && reply.started === true) {
                root.embeddedStartSucceeded = true;
            } else {
                root.embeddedStartError = "the node did not report itself started";
            }
            // The node's own report is the authority on what happened; this
            // asks rather than assuming the start moved `running` and `serving`.
            root.refreshEmbedded();
        });
    }

    /// Reload once Embedded gains a node worth asking.
    ///
    /// **The ordering this closes.** `sourceReload` fires one event-loop turn
    /// after the mode settles, while the identity and status replies are a
    /// backend round trip away — so a reload issued there runs against defaults.
    /// The defaults derive to `blocked`, which declines to fetch, and that is the
    /// safe direction: no request goes out against a home nothing has described.
    /// But it means a serving node would never be listed at all, because nothing
    /// else asks again.
    ///
    /// So the trigger is the derived answer moving, not a reply landing: whatever
    /// combination of the two replies first makes a node askable is what reloads.
    /// This is the same rule as `SourceState.settled()` — fetch on the value that
    /// decides WHETHER to fetch, not on an input to it.
    readonly property Connections embeddedSettled: Connections {
        target: repoList
        function onHasNodeToAskChanged() {
            if (root.mode === "embedded" && repoList.hasNodeToAsk)
                repoList.reload();
        }
    }

    /// Switch mode, and PERSIST it.
    ///
    /// This is what makes the toggle a real control rather than a decorative
    /// one: the mode is a stored setting, the backend rebuilds its LocalStore
    /// from it, and `getCapabilities()` then reports the new mode, home and
    /// `localAvailable`. `sourceState.mode` is a binding to that reply, so the
    /// segment that lights up is the mode actually in force — never one the UI
    /// merely hoped for.
    ///
    /// A refusal is surfaced rather than swallowed. `callSettings` exists for
    /// exactly this: the message names what was wrong, and a user who clicks a
    /// segment and sees nothing happen has no way to tell "refused" from
    /// "broken".
    function setMode(next) {
        if (!sourceState.select(next)) return;
        callSettings("setSetting", ["mode", next], function (reply) {
            if (reply && reply.error) nav.error = reply.error;
        });
    }

    /// Whether the settings pane is showing. Deliberately NOT part of NavState:
    /// settings overlay the current screen rather than replacing it in the
    /// navigation stack, so closing them returns you to exactly where you were
    /// without a back-stack entry that has nothing to go back to.
    ///
    /// Two ways in — the header's Settings chip and the node identity beside
    /// the toggle — and, since the pane is opaque and covers both of them,
    /// there must be a way OUT that lives inside the pane. There was not, and
    /// it shipped: the panel was a one-way door and the user had to restart the
    /// app. `SettingsPanel.closed()` is that way out; see its Back control.
    property bool settingsOpen: false

    /// Whether the guided setup is RAISED over the view.
    ///
    /// The same shape as `settingsOpen`, and for the same reason stated one
    /// level harder by `embedded-setup`: hosted as a navigation destination,
    /// going back from the setup would have to choose between the step the user
    /// was on and the screen they came from, and `NavState` knows nothing about
    /// steps — while the setup's own Back already moves between them, so there
    /// would be two controls for one word. Raised over the view, lowering it
    /// restores exactly the screen underneath with no decision to make.
    property bool setupOpen: false

    /// Raise the setup, lowering the settings surface if it is up.
    ///
    /// **The exclusion is enforced at the raise, not by a binding**, so lowering
    /// one raises nothing: a user who closes the setup is returned to the screen
    /// underneath, not handed a surface they did not ask for. Two opaque
    /// surfaces raised at once leaves one unreachable behind the other with no
    /// control to lower it, which is the one-way door this module has already
    /// shipped once.
    ///
    /// `show()` restarts the flow: the landing step is derived from the
    /// preflight this raise is about to run, never from what a previous showing
    /// left behind. The wizard is not destroyed when it is lowered, so its
    /// `Component.onCompleted` fires for the first showing only — which is why
    /// the host says "begin" explicitly rather than relying on construction.
    function openSetup() {
        settingsOpen = false;
        setupOpen = true;
        setupWizard.show();
    }

    /// Act on the Embedded state panel's request.
    ///
    /// **Routes on the KIND, not on the state**, which is what makes "a start
    /// request does not raise the setup" a property of this function rather than
    /// of which states happen to be reachable today. A host that raised the
    /// setup for every request alike would satisfy every scenario a module in
    /// the no-identity state can produce, and be wrong on the day a start
    /// request becomes routable.
    ///
    /// `restart` reaches nothing, deliberately — see `embeddedRestartHosted`.
    /// The panel renders it not-enabled and says so, so this is belt and braces
    /// rather than the only guard.
    ///
    /// `start` is hosted and has a branch here, although the panel does not use
    /// it: `RepoList` calls `startEmbeddedNode` directly, because the passphrase
    /// a start may need lives on that surface and this signal carries only a
    /// kind. The branch exists because the flag says the kind is routed, and a
    /// hosted kind with no branch is the disagreement `routesEmbeddedAction`
    /// was written to make impossible. It starts with an empty passphrase,
    /// which is the only value a caller carrying no secret can mean.
    ///
    /// **Routed via `routesEmbeddedAction()` rather than by an `if` per kind**,
    /// because the enablement the panel renders and the routing this performs
    /// are two readings of the same question and were free to disagree. They
    /// disagreed by construction: `embeddedStartHosted` gated the control while
    /// a bare `if (kind === "setup")` gated the act, so arming the flag alone
    /// would have shipped an enabled control whose click was dropped on the
    /// floor — the dead end `embedded-state`'s spec names as the reason this
    /// capability exists. Both now read the same table.
    function takeEmbeddedAction(kind) {
        if (!routesEmbeddedAction(kind)) return;
        if (kind === "setup") openSetup();
        else if (kind === "start") startEmbeddedNode("");
    }

    /// Whether this host routes a request of this kind — the same question the
    /// panel's `actionHosted` asks, answered from the same flags.
    ///
    /// Kept as its own function rather than folded into `takeEmbeddedAction`
    /// because it is a different job: this decides *whether* an act reaches
    /// anybody, and the caller decides *what happens* when it does. Separating
    /// them is what lets a test ask "is every hosted kind routed?" without
    /// performing any of the acts — which is the question that was previously
    /// unaskable, and therefore untested.
    ///
    /// A kind absent from this table routes nowhere whatever a control does, so
    /// a programmatic `.clicked()` past a disabled control still cannot provoke
    /// an unhosted act.
    function routesEmbeddedAction(kind) {
        switch (kind) {
        case "setup":              return embeddedSetupHosted;
        case "start":              return embeddedStartHosted;
        case "restart":            return embeddedRestartHosted;
        default:                   return false;
        }
    }

    /// The Settings chip's act: raise the settings surface, lowering the setup
    /// if it is up; or lower settings, raising nothing.
    ///
    /// A function rather than `settingsOpen = !settingsOpen` at the chip,
    /// because the exclusion has to hold for BOTH raises and a second inline
    /// copy of it is the shape this repo keeps paying for — four hand-written
    /// staleness guards, each dropping a different term.
    function toggleSettings() {
        if (settingsOpen) {
            settingsOpen = false;
            return;
        }
        setupOpen = false;
        settingsOpen = true;
    }

    onCapsJsonChanged: {
        var r = R.parse(capsJson);
        if (r.ok) caps = r.data;
    }

    Connections {
        target: (typeof logos !== "undefined" && logos) ? logos : null
        ignoreUnknownSignals: true
        function onViewModuleReadyChanged(moduleName, isReady) {
            if (moduleName === "radicle_ui") {
                root.ready = isReady && root.backend !== null;
                if (root.ready) root.onBackendReady();
            }
        }
    }

    Component.onCompleted: {
        ready = backend !== null
                && (typeof logos !== "undefined")
                && logos.isViewModuleReady("radicle_ui");
        if (ready) onBackendReady();
    }

    /// Everything that needs a live QtRO replica. The seed picker's own load
    /// triggers (Component.onCompleted, onFetchSeedsChanged) all fire before
    /// the replica exists, so its fetch bails out and the dropdown stays empty
    /// forever — it has to be retried from here.
    function onBackendReady() {
        seedPicker.loaded = false;
        seedPicker.reload();
        nav.reset();
        refreshEmbedded();
        repoList.reload();
    }

    /// Source-routed backend call. `method` is the suffix after remote/local.
    ///
    /// The optional `source` argument overrides `root.source` for one call.
    /// No caller uses it today — the toggle moves every view at once, which is
    /// the point — but it is the seam for a future screen that wants to show
    /// both sources side by side.
    function call(method, args, onOk, onFail, source) {
        if (!backend) return;
        var name = sourceState.methodFor(method, source);
        if (typeof backend[name] !== "function") {
            // No request was started (inflight was never incremented), so
            // this sets the error directly rather than going through fail(),
            // which also decrements the counter.
            nav.error = "unsupported operation: " + name;
            if (onFail) onFail();
            return;
        }
        // Deliberately does NOT clear nav.error on the way in — see
        // NavState.begin()'s doc comment.
        nav.begin();

        // The mode this request was issued FOR. A failure is only news if the
        // module is still in it.
        //
        // Without this, a request that was perfectly legitimate when it was
        // made paints an error over whatever the user switched to. The case
        // that shipped: a `localListRepos` in flight when the user clicks
        // Embedded is refused by the backend (Embedded resolves no home), and
        // the refusal latched into `nav.error` beneath a screen explaining that
        // Embedded is not implemented — an error about something nothing had
        // asked for. `tests/ui/local.yaml` asserts exactly that it does not.
        //
        // The MODE, not `source`: `local` and `embedded` share a method prefix
        // (see SourceState.qml), so a `source` comparison is blind to the one
        // switch this needs to catch. That is the same blindness that made the
        // reload trigger wrong, arriving here from the other direction.
        //
        // The counter is still decremented either way — the request really did
        // finish, and leaking `inflight` would leave the busy strip up for ever.
        // Only the user-visible message is suppressed, and only for a mode that
        // is no longer in force. `succeed()` needs no such guard: clearing a
        // stale error is never wrong, and the per-view staleness guards already
        // drop the DATA (see RepoList.fetch()).
        var wantMode = root.mode;
        function reportFailure(message) {
            if (root.mode === wantMode) nav.fail(message);
            else nav.settle();
            if (onFail) onFail();
        }

        logos.watch(backend[name].apply(backend, args), function (text) {
            var r = R.parse(text);
            if (r.ok) {
                nav.succeed();
                onOk(r.data);
            } else {
                reportFailure(r.error);
            }
        }, function (err) {
            reportFailure(String(err));
        });
    }

    /// Switch the remote seed, surfacing a failure instead of silently
    /// keeping the old data under the new seed's name.
    function setSeed(url) {
        if (!backend) return;
        nav.begin();
        logos.watch(backend.setRemoteSeed(url), function (text) {
            var r = R.parse(text);
            if (r.ok) {
                nav.succeed();
                nav.reset();
                repoList.reload();
            } else {
                nav.fail("Cannot use " + url + ": " + r.error);
                // Snap the picker back to the seed actually in use.
                seedPicker.currentSeed = Qt.binding(function () {
                    return root.caps.remoteSeed || "";
                });
                seedPicker.syncSelection();
            }
        }, function (err) {
            nav.fail(String(err));
        });
    }

    /// Source-neutral call (getCapabilities, listKnownSeeds, setRemoteSeed).
    function callPlain(method, args, onOk) {
        if (!backend) return;
        logos.watch(backend[method].apply(backend, args), function (text) {
            var r = R.parse(text);
            if (r.ok) onOk(r.data);
        }, function () {});
    }

    /// Source-neutral call that reports failures to its callback rather than
    /// swallowing them.
    ///
    /// `callPlain` drops errors on purpose — a failed capabilities probe should
    /// not paint the status strip red on every poll. A settings write is the
    /// opposite: the refusal IS the useful result, since it names the path that
    /// was tried or the limit that was exceeded, and a user who typed something
    /// wrong must see why rather than watch the field silently revert.
    function callSettings(method, args, onDone) {
        if (!backend) return;
        logos.watch(backend[method].apply(backend, args), function (text) {
            var r = R.parse(text);
            onDone(r.ok ? r.data : { error: r.error });
        }, function (err) {
            onDone({ error: String(err) });
        });
    }

    // ---- test-observable state -------------------------------------------
    // Read by the UI tests (radicle-ui/tests/ui/*.yaml). Cheap bindings that
    // say what the app believes is true, so assertions do not have to infer it
    // from rendered text.
    readonly property string navView: nav.view
    readonly property bool   navBusy:  nav.busy
    readonly property string navError: nav.error
    readonly property int    repoCount: repoList.count
    readonly property int    seedCount: seedPicker.count
    readonly property int    repoTab:   repoPage.tab
    readonly property int    treeCount: repoPage.treeCount
    readonly property string treeNames: repoPage.treeNames
    readonly property int    commitCount: repoPage.commitCount
    readonly property int    issueCount:  repoPage.issueCount
    readonly property int    patchCount:  repoPage.patchCount
    readonly property string patchStatus: repoPage.patchStatus

    // Which source is selected, and whether the local one is offerable at all.
    // `capsRaw` is the whole capabilities reply verbatim: when the local
    // segment does not appear, the question is always "what did
    // getCapabilities actually say", and reading it out of the app beats
    // guessing from a screenshot.
    readonly property string sourceName:  source
    readonly property bool   hasLocal:    localAvailable
    readonly property string capsRaw:     capsJson

    // Which node, and which identity. Asserted from outside because the
    // failure worth catching is the UI showing one mode while the backend is
    // in another — which a screenshot cannot distinguish from working.
    readonly property string nodeMode:      caps.mode || ""
    readonly property string nodeIdentity:  caps.nodeId || ""
    readonly property string nodeHome:      caps.radHome || ""
    readonly property bool   gitFound:      caps.gitFound === true
    /// Whether each opaque surface is RAISED, read off the pane's own `visible`
    /// rather than off the flag it is keyed on.
    ///
    /// `settingsShown` was the flag, and is moved onto the item for the reason
    /// `reposEmbeddedPanel` documents: a copy of a condition agrees with the
    /// item whether or not the item draws, so an assertion on it cannot see a
    /// surface that was raised and never rendered — which is the defect worth
    /// catching, and the one a screenshot cannot distinguish either.
    ///
    /// Both are asserted together in `tests/ui/local.yaml`, because the
    /// requirement they carry is a RELATION: raising one lowers the other, and
    /// lowering one raises nothing. Neither observable alone can see that.
    readonly property bool   settingsShown: settingsPane.visible
    readonly property bool   setupShown:    setupPane.visible

    // ---- state only the end-to-end layer can assert on --------------------
    //
    // Every property below exists because a defect this module actually
    // shipped was invisible to every other assertion. They are read by
    // tests/ui/local.yaml; see that spec for what each one catches.

    /// Whether the Embedded state panel is ACTUALLY on screen, and which state
    /// it is rendering.
    ///
    /// These replace `reposNotImplemented`, which named the panel this one
    /// supersedes. That flag could not be kept: with all three modes startable it
    /// was false everywhere, so `local.yaml`'s assertion on it was one nothing
    /// could fail — and CLAUDE.md's rule is that a check which cannot fail is
    /// worth no more than one that cannot pass. Deleting it without a
    /// replacement would have been worse still, leaving the one state a user
    /// actually lands in with nothing asserting anything about it.
    ///
    /// `reposEmbeddedPanel` is read off the rendered item's own `visible`, not
    /// recomputed from the conditions it is keyed on, for the same reason
    /// `reposSayingNothing` is: a recomputed copy agrees with the item whether or
    /// not the item draws.
    readonly property bool reposEmbeddedPanel: repoList.embeddedPanelShown

    /// Which of the seven states is in force: "blocked" | "noIdentity" |
    /// "stopped" | "starting" | "startFailed" | "notServing" | "runningEmpty".
    ///
    /// Asserted alongside the flag above rather than instead of it: the panel
    /// rendering and the panel rendering the RIGHT state are different facts,
    /// and a spec running against a real embedded home with no identity can
    /// check both.
    readonly property string reposEmbeddedState: repoList.embedded.current

    /// Whether the repository screen is blank with no explanation at all.
    ///
    /// Never correct, in any mode, at any window size — which is what makes it
    /// assertable unconditionally rather than only where a count is known. See
    /// RepoList.sayingNothing for why it is read off the placeholder items
    /// rather than recomputed from their conditions.
    readonly property bool reposSayingNothing: repoList.sayingNothing

    /// Whether the node identity told the user it copied.
    ///
    /// The confirmation is the ONLY feedback that click produces — the
    /// clipboard is not observable from a spec — so this is what distinguishes
    /// a copy that happened from a click that landed on nothing. It is earned
    /// rather than assumed: NodeIdentity only raises it after reading the
    /// clipboard back, so it cannot be true for a copy that silently failed.
    readonly property bool identityCopied: nodeIdentity.confirmShown

    /// Whether the identity is showing less than the whole DID.
    ///
    /// The user reported it eliding at a width where it need not. There is no
    /// single correct value here — it SHOULD elide in a narrow window — so a
    /// spec asserts it against a known width rather than absolutely.
    readonly property bool identityShortened: nodeIdentity.shortened

    // Sync button: its three idle labels ("Download All" / "Re-sync" /
    // "Update") plus the in-progress percentage are the whole of that
    // feature's user-visible behaviour, so the specs assert on all of them.
    readonly property bool   syncing:         repoPage.syncing
    readonly property real   syncProgress:    repoPage.syncProgress
    readonly property bool   syncedOnce:      repoPage.syncedOnce
    readonly property bool   updateAvailable: repoPage.updateAvailable
    readonly property string syncLabel:       repoPage.syncLabel

    /// See RepoView.sourceTabItem: the sync spec sets the real
    /// `lastSyncedCommit` and calls the real `checkForUpdate()` through this,
    /// rather than through a test-only hook that would fake the outcome.
    readonly property var    sourceTabItem:  repoPage.sourceTabItem

    // File tree and viewer.
    readonly property string treePath:       repoPage.treePath
    readonly property string selectedFile:   repoPage.selectedFile
    readonly property string fileTitle:      repoPage.fileTitle
    readonly property int    fileBodyLength: repoPage.fileBodyLength

    // Branch picker.
    readonly property string repoBranch:        repoPage.branch
    readonly property string repoDefaultBranch: repoPage.defaultBranch
    readonly property int    branchCount:       repoPage.branchCount
    /// True when the picker split the list into this node's branches and other
    /// peers' — only ever the case on the local source, and only for a repo
    /// that has some of each.
    readonly property bool   branchesGrouped:   repoPage.branchesGrouped
    readonly property string branchLabel:       repoPage.branchLabel
    /// See RepoView.branchPickerItem: a ComboBox's popup delegates live in a
    /// separate window and cannot be clicked by objectName, so the branch spec
    /// emits the picker's own `activated` signal instead.
    readonly property var    branchPickerItem:  repoPage.branchPickerItem

    // Detail views. "" when the tabs are showing.
    readonly property string openThread: repoPage.openThread
    readonly property string openCommit: repoPage.openCommit

    /// Whether the comment box is offered. The failure worth asserting on from
    /// outside is the box appearing where it should not — on a seed-hosted
    /// repo, or with no signing key — because that is the one that loses text.
    readonly property bool composerVisible: repoPage.composerVisible

    /// The "New issue" affordance and its form. Same reasoning: the failure
    /// worth catching from outside is the button appearing where its form
    /// could not be submitted.
    readonly property bool canCreateIssue: repoPage.canCreateIssue
    readonly property bool newIssueOpen:   repoPage.newIssueOpen

    /// The open thread's comment count, and the composer itself. Both are for
    /// tests/ui/write.yaml; see ThreadView.qml for why each is needed and what
    /// the count in particular proves. The count is the one assertion that can
    /// distinguish a write that landed from one that only looked like it did.
    readonly property int threadCommentCount: repoPage.threadCommentCount
    readonly property var composerItem: repoPage.composerItem
    readonly property var newIssueFormItem: repoPage.newIssueFormItem

    /// Open a repository object directly (deep links and testing).
    function openRepoExternal(repo) {
        if (repo && repo.rid) nav.openRepo(repo);
    }

    // ---- navigation state -------------------------------------------------
    // See NavState.qml for the counter/error semantics — pulled into its own
    // component so that logic is directly testable, the same way
    // ListCache.qml is tested without a live backend.

    NavState { id: nav }

    // ---- chrome -----------------------------------------------------------

    Rectangle {
        anchors.fill: parent
        color: Theme.bg

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- top bar (grows to fit; see headerFlow) ----
            Rectangle {
                Layout.fillWidth: true
                // Normally the fixed chrome height — the layout rule above
                // still holds for everything driven by REQUESTS, and nothing
                // reflows as they come and go.
                //
                // Two things are allowed to grow it, both of them properties of
                // the WINDOW rather than of any request:
                //
                //  - The source toggle's caption. That is the point rather than
                //    an exception: the caption exists BECAUSE the previous
                //    design put this text in an overlay anchored past the bottom
                //    of a fixed-height bar, where `z` cannot lift it over another
                //    parent's later sibling and it rendered as an unreadable
                //    sliver. A bar that clips its own explanation reintroduces
                //    exactly that bug, so the bar yields to the text instead.
                //  - The header wrapping onto a second line at a narrow width.
                //    See headerFlow for why it wraps at all; the consequence here
                //    is that the bar can no longer be pinned to one control line,
                //    because a bar that wrapped its content and kept its height
                //    would paint the second line straight over the status strip.
                //
                // Neither changes while a user is doing anything except resizing
                // the window or switching mode, so the no-reflow rule survives.
                //
                // `captionReserve`, NOT `reservedHeight` and NOT
                // `implicitHeight`, and the distinction is load-bearing three
                // ways. `implicitHeight` varies by mode (the caption shows only
                // in Embedded), and budgeting from it made the bar 44px taller
                // in Embedded and slid the whole body on the click that
                // switched. `reservedHeight` fixed that but INCLUDES the segment
                // strip, which `headerFlow.height` now already accounts for —
                // adding it here would double-count the strip and leave the bar
                // 28px too tall in every mode. `captionReserve` is exactly the
                // overhang below the flow: constant across modes, counted once.
                // See SourceToggle.qml.
                Layout.preferredHeight: Math.max(
                    Theme.barHeight,
                    headerFlow.height + headerFlow.y + Theme.gap
                    + sourceToggle.captionReserve)
                color: Theme.surface

                // A `Flow`, not a `RowLayout` — the header WRAPS rather than
                // squeezing, and this is the whole of that change.
                //
                // The previous version was a RowLayout in which the Settings
                // chip was incompressible and two items yielded: the identity
                // elided its DID down to a 120px floor and the search field
                // shrank 260→120. That kept Settings on screen and was rejected
                // on sight — at ~630px the user got the whole header on one line
                // with the DID cut in half, and asked for the opposite trade:
                // *"can you instead make it go on the next line?"*. Nothing here
                // is squeezed or truncated now; what does not fit moves down.
                //
                // QtQuick.Layouts has no wrapping row, so the choice was Flow or
                // a GridLayout with a computed column count. Flow, because the
                // column count is not knowable: these items have wildly
                // different and CONTENT-DEPENDENT widths — a DID is ~411px, the
                // title 58px — so any column count is wrong for some mode, and
                // computing one in script would mean re-deriving in JS what the
                // layout already measures. Flow asks each child for its natural
                // width and breaks where the next one does not fit, which is
                // exactly "one line while it fits, a second line when it does
                // not" and needs no arithmetic to stay true when a component's
                // content changes.
                //
                // What Flow costs is `Layout.fillWidth`, so there is no flexible
                // spacer and the Settings chip cannot be pinned to the right
                // edge. It sits at the END OF THE FLOW instead, and that is
                // better rather than merely acceptable: as the last item placed
                // it is the one wrapping protects first — it either fits on the
                // current line or starts a new one, and in neither case can it
                // be pushed past an edge. The requirement was that Settings stay
                // reachable at every width, not that it stay right-aligned.
                //
                // A second consequence, and it closes a trap rather than opening
                // one: a Flow SKIPS invisible children outright, where a
                // RowLayout reserves a declared `Layout.minimumWidth` even for a
                // child that is not visible. That is what had the identity
                // holding 120px in Explore and the search field holding 120px
                // back in Local — ~240px permanently spoken for by two items
                // never both on screen. There is nothing to gate on `visible`
                // here because there is nothing being reserved.
                Flow {
                    id: headerFlow
                    objectName: "headerFlow"
                    x: Theme.gap
                    // The control line's own offset within the CHROME budget
                    // (Theme.barHeight), not within the bar — the bar is taller
                    // than that whenever the caption is budgeted for or the flow
                    // has wrapped, and centring in it would push the first line
                    // down as either grew.
                    y: (Theme.barHeight - Theme.rowHeightSm) / 2
                    width: parent.width - Theme.gap * 2
                    spacing: Theme.gap

                    // Always present now, at every width.
                    //
                    // It used to disappear below 520px — the row's minimums
                    // genuinely exceeded a narrow window, so something had to
                    // yield entirely or the Settings chip went off the edge, and
                    // the title was the only element here whose loss costs the
                    // user nothing (Basecamp's own chrome already says which
                    // module this is). With a wrapping header that trade is
                    // gone: a word that does not fit on the first line goes to
                    // the second like everything else, and there is no width at
                    // which dropping it buys anything.
                    //
                    // Given the control line's height explicitly so the Flow
                    // aligns it with the chip and the toggle. A bare Text is
                    // font-height tall — a few pixels shorter — and a Flow tops
                    // its items rather than centring them, so without this the
                    // word sits visibly high on its own line.
                    Text {
                        objectName: "headerTitle"
                        text: "Radicle"
                        color: Theme.text
                        font.pixelSize: Theme.fontXl
                        font.bold: true
                        height: Theme.rowHeightSm
                        verticalAlignment: Text.AlignVCenter
                    }

                    // ONE control for "what am I browsing" — exactly three
                    // segments, one per mode, and nothing else in it.
                    //
                    // The mode used to be chosen only in Settings while this
                    // bar carried a two-segment `source` toggle AND a separate
                    // "Attached · z6Mko…" badge. Two vocabularies for one
                    // question, side by side, which a user read as a single
                    // control with a dead third segment. The badge is gone, the
                    // vocabularies are one, and the segment IS the mode.
                    SourceToggle {
                        id: sourceToggle
                        objectName: "sourceToggle"
                        // The toggle occupies exactly the control LINE in the
                        // flow, and its caption hangs below that line into the
                        // space the bar reserves for it.
                        //
                        // Pinned with a plain `height`, where the RowLayout
                        // version used `Layout.preferredHeight` +
                        // `Layout.maximumHeight` + `Layout.alignment` to say the
                        // same thing. Attached `Layout.*` properties are INERT
                        // inside a Flow — it positions children by their own
                        // `width`/`height` — so leaving them here would have been
                        // three lines of dead configuration guarding a real
                        // constraint. Silent, and exactly the shape of defect
                        // this file keeps being bitten by.
                        //
                        // The constraint itself is unchanged and still
                        // load-bearing: without it the Embedded caption makes
                        // this item ~72px tall, a Flow gives the whole line that
                        // height, and every other item on it drops to centre in
                        // a box four times too tall. The toggle draws from its
                        // own top downward, so a fixed height keeps the segment
                        // strip on the line and lets the caption overhang.
                        //
                        // The caption drawing outside the flow is deliberate and
                        // safe: nothing here sets `clip`, and the bar is sized to
                        // contain it — see the bar's `captionReserve` term.
                        // tst_mode_switch.qml asserts that it lands inside the
                        // bar rather than past its edge.
                        height: Theme.rowHeightSm
                        mode:           root.mode
                        // Passed straight through, `undefined` included, and
                        // that is the point rather than a shortcut. This used
                        // to substitute `[]` for a missing value, which told
                        // the toggle "this build starts nothing" during the
                        // window before the first getCapabilities reply — an
                        // amber border and an unavailable marker on all three
                        // segments, Local included, on every launch. `[]` and
                        // "not yet known" are different claims and the toggle
                        // now distinguishes them; collapsing them here would
                        // put the regression back on this side of the
                        // boundary. See SourceToggle.startableModes.
                        startableModes: root.caps.startableModes
                        modeReason:     root.caps.modeUnavailableReason || ""
                        localAvailable: root.localAvailable
                        pathsProblem:   root.caps.pathsProblem || ""
                        reason: "No Radicle profile on this machine — "
                                + "install Radicle and run `rad auth` to browse local repositories."
                        onModeChosen: function (next) { root.setMode(next); }
                    }

                    // ---- the mode-detail slot -------------------------
                    //
                    // Immediately right of the toggle, showing exactly one
                    // thing at a time: the detail of whichever mode is
                    // selected. One rule a user learns once, instead of a
                    // header whose contents have to be memorised element by
                    // element.
                    //
                    //   Explore  -> which seed is being proxied to
                    //   Local    -> which identity you are operating as
                    //   Embedded -> nothing; there is no node yet, and the
                    //               toggle's own caption already explains that
                    //
                    // `SeedPicker` already worked this way (`visible:` keyed on
                    // the source), so this extends an existing pattern rather
                    // than inventing a parallel one.

                    SeedPicker {
                        id: seedPicker
                        objectName: "seedPicker"
                        // Which seed is proxied to is Explore's detail. Showing
                        // the picker in any other mode would imply it affects
                        // what is on screen, which it does not.
                        visible: root.mode === "explore"
                        currentSeed: root.caps.remoteSeed || ""
                        fetchSeeds: function (cb) {
                            root.callPlain("listKnownSeeds", [], cb);
                        }
                        onSeedChosen: function (url) {
                            // setRemoteSeed validates the seed and reverts to
                            // the previous one if it does not answer. Report
                            // that and put the picker back, rather than leaving
                            // it naming a seed whose data is not on screen —
                            // plenty of preferred seeds run the p2p node
                            // without the HTTP API.
                            root.setSeed(url);
                        }
                    }

                    // The detail of any mode that HAS an identity — Local and
                    // Embedded both. Absent, not blank and not a placeholder,
                    // in a mode that has none: in Explore you are not operating
                    // as anyone, so an empty slot there is noise and a
                    // placeholder is worse, because it suggests a value that is
                    // loading. Same reasoning as the Local segment being absent
                    // rather than disabled when there is no profile.
                    NodeIdentity {
                        id: nodeIdentity
                        objectName: "nodeIdentity"
                        // Two conditions, and they are different questions:
                        // this MODE is one that has an identity, AND there is
                        // an identity to describe. The component already hides
                        // itself for the second (it must, or a caller could
                        // render an empty slot); this adds the first.
                        //
                        // **`modeHasIdentity`, never a list of modes**, and
                        // that is the fix rather than a tidy-up. This read
                        // `root.mode === "local"`, so Embedded showed nothing —
                        // in the mode where the confusion is most likely,
                        // because its identity is one this module created
                        // rather than one the user made, and where
                        // `radicle_impl.h` most needs a view to say which DID it
                        // is acting as. A list is one somebody has to notice and
                        // extend; the rule is right for a mode added later
                        // without anyone editing this line. See
                        // `SourceState.modeHasIdentity`.
                        visible: root.modeHasIdentity && nodeIdentity.nodeId !== ""
                        nodeId: root.caps.nodeId || ""
                        // The WHOLE DID, at every width. This element used to be
                        // the one that yielded — `ElideMiddle` down to a 120px
                        // floor — and that is exactly what the user rejected:
                        // at ~630px they got the entire header on one line with
                        // the identity cut to `did:key:z6Mkowuny…EnhaDE8JH3MbLnDBe`,
                        // and asked for the second line instead.
                        //
                        // So `minimumWidth` is left at its default 0, which
                        // NodeIdentity documents as "do not yield at all", and
                        // this asks the Flow for exactly the room its full text
                        // needs. If that does not fit beside the toggle, the Flow
                        // gives it its own line, where it always does fit — a
                        // full DID is ~411px and the narrowest window worth
                        // supporting is wider than that.
                        //
                        // The elide mechanism is still IN NodeIdentity, unused,
                        // and deliberately so rather than ripped out: it is
                        // opt-in, costs nothing while `minimumWidth` is 0, and
                        // is the honest last resort for the one case wrapping
                        // cannot help — a window narrower than the string
                        // itself. What was removed is this caller opting in at a
                        // width where a second line was available.
                        //
                        // No `Layout.*` here, and none needed: a Flow reads
                        // `implicitWidth` directly, and it SKIPS invisible
                        // children rather than reserving their declared minimums
                        // the way a RowLayout does. The `visible ? … : 0` gates
                        // that used to be on every constraint existed only to
                        // work around that, and there is nothing left for them
                        // to guard.
                    }

                    FilterField {
                        id: searchField
                        // The local surface takes a scope, not a search string
                        // — see RepoList.fetch(). A search box that silently
                        // did nothing would be worse than no search box. Keyed
                        // on the derived method prefix rather than the mode,
                        // because it is the SURFACE that lacks search:
                        // `embedded` would have the same limitation.
                        visible: nav.view === "repos" && root.source === "remote"
                        // Its full width, always. This was the other yielder,
                        // shrinking 260→120 to keep the row on one line in
                        // Explore, and it goes for the same reason the
                        // identity's elide does: a field squeezed to half its
                        // width shows half a placeholder, and the second line it
                        // would otherwise wrap onto was there the whole time.
                        //
                        // A plain `width` rather than an implicit one, because
                        // FilterField is a TextField and its natural width is
                        // its content's — an empty field would collapse to a few
                        // pixels and grow as the user typed, which is a control
                        // that moves the layout under the pointer.
                        width: 260
                        placeholder: "Search repositories"
                        onAccepted: repoList.reload()
                    }

                    // Settings, LAST in the flow, and its position is the one
                    // deliberate compromise in this change.
                    //
                    // It used to be pinned to the right edge by a flexible
                    // spacer (`Item { Layout.fillWidth: true }`), which a Flow
                    // has no equivalent of — a Flow packs its children and stops.
                    // The spacer is gone rather than replaced, so the chip now
                    // sits immediately after the mode detail instead of against
                    // the right edge.
                    //
                    // That is a real change in appearance, and it is the right
                    // trade: the requirement is that Settings stay REACHABLE at
                    // every width, not that it stay right-aligned. As the last
                    // item placed it is the one wrapping protects best — it
                    // either fits on the current line or starts a new one, and
                    // in neither case can it be pushed past an edge, which is
                    // precisely how it became unreachable below ~750px before.
                    //
                    // Nothing here is incompressible any more, because nothing
                    // needs to be: the previous version made this chip
                    // unshrinkable so the row would squeeze its neighbours
                    // instead of overflowing. With wrapping there is no
                    // overflow to protect against.
                    Rectangle {
                        objectName: "settingsChip"
                        height: Theme.rowHeightSm
                        width: settingsLabel.implicitWidth + Theme.gap * 2
                        radius: Theme.radiusSm
                        color: root.settingsOpen ? Theme.accentSoft : Theme.bg
                        border.width: 1
                        border.color: Theme.border

                        Text {
                            id: settingsLabel
                            anchors.centerIn: parent
                            text: "Settings"
                            color: root.settingsOpen ? Theme.text : Theme.textDim
                            font.pixelSize: Theme.fontSm
                        }

                        MouseArea {
                            objectName: "settingsToggle"
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleSettings()
                        }
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 1
                    color: Theme.border
                }
            }

            // ---- status strip (always present, fixed height) ----
            StatusStrip {
                Layout.fillWidth: true
                busy: nav.busy
                error: nav.error
            }

            // ---- body ----
            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: nav.view === "repos" ? 0 : 1

                RepoList {
                    id: repoList
                    app: root
                    query: searchField.text
                    onRepoActivated: function (r) { nav.openRepo(r); }
                    // The Embedded panel's action. It requests; this decides.
                    // `takeEmbeddedAction` routes on the kind, so a start
                    // request cannot raise a setup that could not perform it.
                    onEmbeddedActionTaken: function (kind) {
                        root.takeEmbeddedAction(kind);
                    }
                }

                RepoView {
                    id: repoPage
                    app: root
                    rid: nav.rid
                    repo: nav.repo
                    active: nav.view === "repo"
                    onBack: nav.back()
                }
            }
        }

        // Settings overlay the body rather than replacing a StackLayout page:
        // they are orthogonal to where you are in the repository navigation,
        // and putting them in the stack would mean "back" from settings had to
        // decide which screen to restore.
        Rectangle {
            id: settingsPane
            objectName: "settingsPane"
            visible: root.settingsOpen
            anchors.fill: parent
            color: Theme.bg

            SettingsPanel {
                id: settingsPanel
                objectName: "settingsPanel"
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width - Theme.gapLg * 2, 640)
                caps: root.caps
                fetchSettings: function (cb) {
                    root.callPlain("getSettings", [], cb);
                }
                saveSetting: function (key, value, cb) {
                    root.callSettings("setSetting", [key, value], cb);
                }
                // Closing just lowers the overlay. Because settings were never
                // pushed onto the navigation stack, the screen underneath is
                // untouched and the user lands exactly where they were — deep
                // inside a repository if that is where they came from. This is
                // the payoff for keeping `settingsOpen` out of NavState, and it
                // is why closing needs no decision about which screen to
                // restore.
                onClosed: root.settingsOpen = false
            }
        }

        // The guided setup, raised over the view exactly as settings are, and a
        // SIBLING of that pane rather than a section inside it.
        //
        // Three things follow from being an overlay rather than a navigation
        // destination, and all three are requirements rather than styling:
        //
        //  - lowering it restores whatever screen was underneath, with no
        //    decision to make. A `nav.view` destination would have to choose
        //    between the step the user was on and the screen they came from, and
        //    NavState knows nothing about steps.
        //  - it adds no navigation history, so `nav.back()` keeps one meaning.
        //  - it is mutually exclusive with `settingsPane`: both are opaque and
        //    cover the same screen, so two raised at once leaves one unreachable
        //    behind the other. `openSetup()` and `toggleSettings()` enforce that
        //    at the raise — never by a binding, because lowering one must raise
        //    nothing.
        Rectangle {
            id: setupPane
            objectName: "setupPane"
            visible: root.setupOpen
            anchors.fill: parent
            color: Theme.bg

            SetupWizard {
                id: setupWizard
                objectName: "setupWizard"
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width - Theme.gapLg * 2, 640)
                height: Math.min(parent.height, implicitHeight)

                // The same injection SettingsPanel uses. Every call the flow
                // makes goes through this file's own helpers, so the wizard
                // reaches the backend without knowing there is one.
                //
                // `callPlain` for the reads (a failed probe must not paint the
                // status strip red) and `callSettings` for the writes, whose
                // refusal IS the useful result — it names the home in the way,
                // the `keys` path to remove, or the alias rule that was broken.
                flow.fetchCapabilities: function (cb) {
                    root.callPlain("getCapabilities", [], cb);
                }
                flow.fetchIdentity: function (cb) {
                    root.callPlain("getEmbeddedIdentity", [], cb);
                }
                flow.fetchNodeStatus: function (cb) {
                    root.callPlain("getNodeStatus", [], cb);
                }
                flow.fetchSeeds: function (cb) {
                    root.callPlain("listKnownSeeds", [], cb);
                }
                flow.createIdentity: function (alias, passphrase, cb) {
                    root.callSettings("createEmbeddedIdentity",
                                      [alias, passphrase], cb);
                }
                flow.saveSetting: function (key, value, cb) {
                    root.callSettings("setSetting", [key, value], cb);
                }

                // The surface REPORTS; this module lowers it. A surface that
                // closed itself would leave whatever raised it still believing
                // it is up.
                //
                // Lowering changes nothing underneath — not the view in force,
                // not the repository, not the tab — for the same reason closing
                // settings does not: neither was ever pushed onto the stack.
                //
                // It re-reads what Embedded's home and node are doing, because
                // the flow may have created an identity or started a node and
                // the panel behind this is derived from those replies. That is a
                // refresh of the screen underneath, not a change to it.
                onClosed: {
                    root.setupOpen = false;
                    root.refreshEmbedded();
                }
            }
        }

        // Pre-connection placeholder.
        Rectangle {
            anchors.fill: parent
            visible: !root.ready
            color: Theme.bg
            Text {
                anchors.centerIn: parent
                text: "Connecting to the Radicle module…"
                color: Theme.textDim
                font.pixelSize: Theme.fontLg
            }
        }
    }
}
