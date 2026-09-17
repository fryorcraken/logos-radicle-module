# Design review — embedded-node-wizard

## Summary

The code takes every decision `design.md` records. Spot-checked in particular:
the epoch guard (`SetupFlow.qml`) is applied at all seven callback sites with
no partial application — unlike the historical `wantRid`/`syncEpoch` guard
CLAUDE.md warns about, this one was written once and inherited everywhere;
the index-based `stepIndex`, the four separate findings (not one
`preflightPassed`), the `canCreateIdentity`/`canStartNode` split, the
verified two-editor clipboard in `CopyableCommand.qml`, and the reply-is-
authority rule (`identityExists`, `nodeId`, `modeInForce`, `nodeServing` all
set from replies, never from a call having been issued) all match their
recorded decisions and are exercised by the corresponding tests
(`tst_setup_wizard.qml`, `tst_setup_wizard_view.qml`). This piece made no
change to `radicle_ui.rep` or `radicle/src/radicle_impl.h` (confirmed by
diffing this piece's base commit against its tip), which supports the "QML
only" correction recorded in both `design.md` and `docs/PLAN.md`.

One gap found, below.

- [ ] **`dev-writer`** — `docs/PLAN.md:94-100` duplicates `design.md`'s "The
      network step has no inbound control, and says so" decision, rather than
      shedding to a one-line pointer
      **Scenario:** a future reader of `PLAN.md` hits a full paragraph of
      reasoning — "Nothing persists a listen address, so a toggle in the
      wizard would record nothing and the node would keep binding no port...
      The wizard therefore states the outbound-only default and says the
      control is not available there" — that restates, almost sentence for
      sentence, the reasoning already recorded under `design.md`'s "The
      network step has no inbound control, and says so" (design.md:159-175).
      Two copies of the same rationale, one of which (PLAN.md's) is not the
      canonical location per this repo's own document model: PLAN.md sheds
      reasoning to `design.md` and keeps only a one-line summary plus a
      pointer once the reasoning is acted on and recorded. `tasks.md` claims
      "the passphrase paragraph shed to `design.md`" was done, and it was —
      compare the passphrase paragraph at PLAN.md:138-142, which is
      correctly reduced to "answered, and acted on... The reasoning is in the
      `embedded-node-wizard` change's `design.md`" with no restated
      reasoning. The inbound paragraph at PLAN.md:94-100 was not given the
      same treatment: it keeps the full argument instead of shrinking to
      something like "the inbound opt-in is the panel's, not the wizard's —
      see `embedded-node-wizard`'s `design.md`." If the two drift (for
      example, if the panel's design later finds a different reason inbound
      belongs there), it is not obvious which one is current.
      **Measured:** `design.md:159-175` ("The network step has no inbound
      control, and says so") is the canonical entry, with the added "Where
      the inbound opt-in went" pointer to `embedded-node-config`.
      `docs/PLAN.md:94-100` should be cut to the same one-line-plus-pointer
      shape the passphrase paragraph at `docs/PLAN.md:138-142` already uses.
      Note `docs/PLAN.md:154-158` (the `listen: []` paragraph) is a
      *different*, legitimately-retained forward-looking statement — it is
      the panel's own not-yet-built requirement (the opt-in's port field,
      defaulting off) and was correctly left alone per `tasks.md`'s note that
      it "belongs to the parallel `embedded-node-config` piece." The finding
      here is only about the lines 94-100 paragraph, which duplicates
      `design.md` rather than pointing to it.

No other gaps found. The two-tests-initially-failed detail
(`test_advancing_walks_the_sequence_without_skipping` and
`test_going_back_returns_to_the_previous_step` both call `flow.runPreflight()`
first, with a comment explaining why) is test methodology rather than a
design decision and does not need a `design.md` entry; the actual decision it
protects — "advancing past mode requires `getCapabilities().mode ===
"embedded"`" — is recorded in `design.md`'s Open questions section with its
own test name, as the prompt describes.
