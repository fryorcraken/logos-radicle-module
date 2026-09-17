# Readability review — embedded-node-wizard

Scope: `radicle-ui/src/qml/SetupFlow.qml`, `SetupWizard.qml`,
`CopyableCommand.qml`, and the two test files
(`tst_setup_wizard.qml`, `tst_setup_wizard_view.qml`). Readability only —
correctness, security and architecture are covered by other instances.

## Findings

- [x] **`dev-writer`** — `SetupFlow.qml:323-334` — three different nouns for
      three different counts, in the same ten lines, with no comment
      reconciling them
      **Scenario:** `runPreflight()`'s own doc comment (line 273) says "Ask all
      **four** questions" — it issues `fetchCapabilities`, `fetchIdentity`,
      `fetchNodeStatus` and `fetchSeeds`. Fifty lines later, `preflightAnswers`'s
      doc comment (line 323) says "How many of the **three** preflight probes
      have answered", and `notePreflightAnswer()` (line 332-335) sets
      `preflightDone` once `preflightAnswers >= 3`. Meanwhile the file's own
      section header two lines above (line 92) calls these "the **four**
      preflight findings". A reader has to work out for themselves that: (a)
      "four questions" (calls) and "four findings" (git/identity/socket/home)
      are not the same four as "three probes" (calls that gate `preflightDone`),
      and (b) the reason there are only three gating calls is that the home
      finding piggybacks on data already returned by `fetchCapabilities` and
      `fetchIdentity`, so `fetchSeeds` is the one call of the four that
      deliberately does not call `notePreflightAnswer()`. Nothing in the code
      says this last part — the reader has to trace `homeResolved`'s definition
      (line 130, `embeddedHome !== "" && pathsProblem === ""`) back to the two
      callbacks that set those two properties, and separately notice that
      `fetchSeeds`'s callback (line 315-320) is the only one of the four that
      omits the `notePreflightAnswer()` call, to reconstruct why 3 is correct
      and not 4.
      **Measured:** read `runPreflight()` (lines 276-321) and
      `notePreflightAnswer()` (lines 332-335) together — the logic is correct
      (verified against `tst_setup_wizard.qml`'s
      `test_the_four_findings_are_reported_separately`, which passes), but the
      comments describing it disagree on the count in three different ways
      within one screen of code, and none says "seeds does not count toward
      `preflightDone`, deliberately."

      **Fixed** in `f471999` and `8152bcc`. The three counts are genuinely
      three different numbers, so the fix is to say that rather than to
      reconcile them into one. `runPreflight()`'s doc comment now carries a
      section — "Three counts that are deliberately not the same number" —
      spelling out all three and the reason each differs: the home finding has
      no call of its own (derived from capabilities' `pathsProblem` and
      identity's `home`), and `listKnownSeeds` feeds the network step's seed
      list, which is not a finding and gates nothing. The `fetchSeeds` block
      also carries an inline "the one call that marks no answer" comment at the
      site, so a reader tracing the omission finds the reason there rather than
      reconstructing it.

      The count itself is gone: `preflightAnswers >= 3` became three named
      booleans conjoined into `allProbesAnswered`, which answers
      `architecture.md`'s finding on the same lines. There is no longer a
      number to disagree with a comment about.

- [x] **`dev-writer`** — `SetupFlow.qml:281-289` and `SetupFlow.qml:378-386` —
      the same seven-property capabilities-reply mapping is written out twice,
      in the same order, with the same fallbacks
      **Scenario:** the `fetchCapabilities` callback inside `runPreflight()`
      (lines 281-289) assigns `gitFound`, `gitProblem`, `pathsProblem`,
      `modeInForce`, `startableModes`, `modeUnavailableReason` and
      conditionally `nodeId` from a `caps` object. `refreshCapabilities()`
      (lines 375-388) assigns the same seven properties from the same shape of
      reply, in the same order, with the same `|| ""` / `|| []` fallbacks —
      the only difference being that `runPreflight`'s copy also calls
      `flow.notePreflightAnswer()`. CLAUDE.md's own stated pattern for this
      repo ("Put the complexity in the data structure, not the logic") is
      built around exactly this shape: a guard or reply-mapping hand-written a
      second time is the signal to reshape, because the next copy tends to
      drop something. Here there are two copies already, and nothing pulls the
      seven-line assignment into one function the two callers share (e.g.
      `applyCapabilities(caps)`), so a third caller — plausible, since
      `getCapabilities()` is re-read in at least two places already — is the
      likely fourth copy CLAUDE.md warns about.
      **Measured:** side-by-side, lines 283-289 and 380-386 differ only in
      that the first block ends with `if (flow.nodeId === "") flow.nodeId = …`
      followed by `flow.notePreflightAnswer();`, and the second block has the
      same `if (flow.nodeId === "") …` line with no trailing call. Every other
      line is character-for-character identical.

      **Fixed** in `f471999`: `applyCapabilities(caps)` is now the single copy,
      called by both the preflight callback and `refreshCapabilities()`. Each
      call site is one line plus whatever is genuinely its own — the preflight
      also sets `capabilitiesAnswered`.

      Your read of the risk is the one I acted on: two copies is where the
      `wantRid`/`syncEpoch` story starts, and the cost of waiting for the third
      is a dropped field plus a regression test per omission.

      One thing worth naming for whoever reads `applyCapabilities` next, and
      recorded in `design.md`: the `nodeId` line is the only conditional
      assignment in it, and deliberately so — capabilities carries a DID only
      as a fallback, so a more specific one already reported by
      `createEmbeddedIdentity` or `startNode` must not be overwritten. That is
      the field a third hand-written copy would most plausibly get wrong.

- [x] **`dev-writer`** — `tasks.md:65,67` — the recorded test counts do not
      match the files
      **Scenario:** `tasks.md`'s Tests section states `tst_setup_wizard.qml`
      has "**34** assertions against `SetupFlow`" and `tst_setup_wizard_view.qml`
      has "**14** assertions against the rendered screen". Counting
      `function test_` definitions in each file gives 32 and 13 respectively —
      off by two and one. This is the exact failure mode CLAUDE.md names as a
      recurring defect in this repo ("A number in a comment is a claim, and
      this repo fabricates them... the worst were quantities, because a
      quantity reads as though someone measured it"), and `tasks.md` is a
      tracked, reviewed document, not scratch prose.
      **Measured:** `grep -c "function test_" radicle-ui/tests/tst_setup_wizard.qml`
      → 32; `grep -c "function test_" radicle-ui/tests/tst_setup_wizard_view.qml`
      → 13. (Not strictly one of the three named QML files in this dispatch,
      but it is the same class of defect this dimension is asked to hunt, in a
      file this piece's own tasks track.)

      **Fixed** in `8152bcc`. Re-measured rather than adjusted by your delta,
      and your figures reproduce exactly: `grep -c "function test_"` gives 32
      and 13.

      Worth recording, because it makes the defect slightly different from a
      plain fabrication: 34 and 15 are what `qmltestrunner` reports as its
      totals for those files, because it counts `initTestCase` and
      `cleanupTestCase` alongside the real tests. So "34" was measured — just
      by a metric nobody wrote down, which is how it ended up unfalsifiable at
      a glance. (14 is not either total; that one looks like drift.)

      Both numbers are removed rather than corrected. `tasks.md` now names the
      command and the +2 discrepancy, so a reader gets a figure that cannot go
      stale and knows which of the two numbers a runner will show them. Fixing
      the digits would have left the same trap for the next person to add a
      test.

## What was clean

- **The `SetupFlow`/`SetupWizard` split.** `SetupFlow.qml` contains zero layout
  or rendering concerns; `SetupWizard.qml` reads `setupFlow.*` properties and
  computes nothing itself (blocking reasons, step index, findings are all read,
  never recomputed). This matches the `NavState.qml`/`SourceState.qml`
  precedent CLAUDE.md cites, and each file is independently readable — a
  reader of `SetupFlow.qml` never needs to know a `Column` exists, and a reader
  of `SetupWizard.qml` never needs to re-derive a blocking rule.
- **The two `NO SPEC:` markers** (`SetupWizard.qml:61-65`'s `closed()`,
  `SetupFlow.qml:100-105`'s `preflightDone`) are present, accurate against
  `design.md`'s "Open questions" section, and each is backed by a named test
  (`test_an_unanswered_finding_is_not_reported_as_a_failure` for the second).
  No third unmarked silent choice was found in the files read.
- **The `stepMoved` (not `stepChanged`) naming trap** is caught and explained
  in-line (`SetupFlow.qml:245-252`) — the only `on*`-family or
  built-in-shadowing risk found in either file; no second instance turned up.
- **Comments earn their place.** The bulk of both files' commentary is "why",
  not "what" — e.g. why `epoch` exists, why two separate `TextEdit`s in
  `CopyableCommand.qml`, why `exists:false` is not "empty". `CopyableCommand.qml`
  in particular was read closely for the same fabricated-number risk (the
  `confirmMs: 1600` constant) and carries no comment making a quantitative claim
  about it, so nothing to check it against.
