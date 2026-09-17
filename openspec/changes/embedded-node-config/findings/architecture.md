# Architecture review — `embedded-node-config`

Scope: architecture only, per dispatch. Correctness, security and
readability are covered by other instances.

## Findings

- [x] **`dev-writer`** — `radicle/src/embedded_node.h:66-68` — a fourth copy of
      the "node binds no TCP port" claim was left uncorrected when the other
      three were fixed
      **Scenario:** `tasks.md` records "Correct the now-false 'binds no TCP
      port' claims in `node.rs`, `radicle_impl.h` and `radicle_ffi.h`" as done,
      and all three of those are indeed now accurate — `radicle_impl.h:362-367`
      and `radicle_ffi.h:277-283` both say the node binds what `config.json`'s
      `listen` names, empty by default. `embedded_node.h`'s `EmbeddedNode::start`
      doc comment is a fourth restatement of the same fact
      ("`EmbeddedNode::start` binds `home`'s `listen`, defaulting to nothing")
      and it still reads: "The node binds no TCP port: it can fetch and
      announce, but peers cannot fetch from it." That is no longer true once
      `setNodeConfig` can set `listen` — a reader of this file alone would
      believe inbound is structurally impossible, when this same change makes it
      configurable. This is exactly the class of bug CLAUDE.md's guard-copying
      section describes, applied to a doc comment restating a fact rather than
      to a hand-written check: the same true statement lived in four places, and
      the fourth was the one nobody re-checked.
      **Measured:** `grep -rn "binds no TCP port" radicle/` finds exactly one
      remaining hit, at `embedded_node.h:66`, after the other three sites named
      in `tasks.md` were confirmed corrected by reading them directly.

      **Fixed**, and your framing — the same true statement in four places, and
      the fourth is the one nobody re-checked — turned out to understate it.
      There were **five**. Sweeping for the claim rather than the phrase found a
      fifth at `node.rs:797-799`, the comment on `listening` in the start reply:
      "Reported so a caller can state that peers cannot fetch from this node
      rather than implying a full one. **Empty is the expected value today.**"
      That last sentence is false for exactly the same reason, and a grep for
      "binds no TCP port" does not reach it.

      Both now state the conditional fact rather than the absolute one —
      `embedded_node.h` says the node binds what `home`'s `config.json` names in
      `listen`, empty until something sets it, and names `setNodeConfig` as what
      changes it; `node.rs` says `listening` is what the reactor actually bound,
      from `runtime.local_addrs`, not an echo of `config.listen`.

      Re-swept afterwards: `grep -rn "binds no TCP port\|peers cannot fetch from
      it\|empty today"` over `radicle/` and `radicle-ui/` leaves two hits, both
      the corrected conditional form (`radicle_ffi.h:279`, `embedded_node.h:68`).

      A sixth stale reference turned up in the same sweep and is fixed with them:
      `radicle_impl.cpp`'s section header pointed at "`nodeMayRead` and
      `nodeMayWrite`", names that never existed in any commit — the functions are
      `nodeReadRefusal`/`nodeWriteRefusal`, now
      `nodeReadRefusalForMode`/`nodeWriteRefusalForMode` after the next finding.

- [x] **`dev-writer`** — `radicle/src/radicle_impl.cpp:628-629,756-757,774-775,791-792,803-804,815-816`
      — the `pathsProblem()` early-return is six identical two-line copies,
      five of them new in this diff, sitting immediately beside a gate this same
      diff *did* factor into shared helpers
      **Scenario:** `getNodeConfig`, `setNodeConfig`, `listSeeded`, `seedRepo`
      and `unseedRepo` each open with `nodeReadRefusal`/`nodeWriteRefusal` — a
      shared function, called identically at every site, which is the one-shape
      gate CLAUDE.md asks for. Immediately after it, each of the five repeats
      `if (!m_local.pathsProblem().empty()) return
      dump(radicle::makeError(m_local.pathsProblem()));` verbatim (a sixth copy
      already existed in `startNode` before this change). The mode gate got the
      treatment the seeding-store correction in `design.md` singles out as the
      signal to reshape; the paths-problem guard, sitting in the exact same
      position at the exact same five call sites, did not. Nothing has drifted
      *yet* — the six copies are byte-identical — but that is true of every
      guard right up until the edit that changes one of them and not the other
      five, which is the failure mode the `wantRid`/`wantBranch` guard is cited
      for in `CLAUDE.md`.
      **Measured:** `grep -n "m_local.pathsProblem" radicle_impl.cpp` returns 6
      call-site occurrences (plus one read in `getCapabilities`'s JSON
      assembly), one pre-existing in `startNode` and five added by this piece
      in the five new methods.

      **Fixed.** The argument lands: these are one gate, not two, and the mode
      half was already shared while the paths half sitting directly beneath it at
      the same five sites was not. "Byte-identical today, and one edit away from
      five call sites where four agree" is the right way to put it.

      The two mode-only helpers are renamed `nodeReadRefusalForMode` /
      `nodeWriteRefusalForMode` and are no longer called from the methods.
      `nodeReadRefused(mode, local)` / `nodeWriteRefused(mode, local)` are what
      the five call now — one call each, carrying the mode check and the paths
      check in the order that was being hand-written. The paths-problem
      reasoning (this module's message names path, length and limit where the
      crate's names none of the three) moved into the shared function's doc
      comment, since it is now stated once.

      **`startNode`'s copy stays, deliberately, and now says why** rather than
      reading as the sixth one that was missed. Its gate is a different gate: it
      refuses `local` with "your node is already yours to run" where the config
      gate refuses it with "yours to configure", and it needs the `available()`
      check the config methods deliberately skip. Sharing only the paths half
      would mean a function taking a pre-computed refusal, which is the
      parameter-threading shape `design.md` rejects for `restartRequired`.

      **Measured after:** `grep -n "pathsProblem()" radicle_impl.cpp` returns 7
      occurrences across **3 guard sites** plus the `getCapabilities` read (each
      guard spends two occurrences, the `if` and the `makeError`). The three are
      `startNode` (line 637) and the two shared gates (780, 790, reading
      `local.pathsProblem` since they take the store by const reference). Your
      six call sites are now three, and five of them collapsed into two.

      Verified behaviour-preserving: the full core suite is green (172 passed),
      including all five mode-gating tests, which exercise the refusal messages
      the refactor moved.

## What was checked and found sound

- **The mode-gating is one shape, not five.** `nodeReadRefusal(mode)` and
  `nodeWriteRefusal(mode)` are free functions in an anonymous namespace, each
  called identically from all five relevant methods
  (`radicle_impl.cpp:702-743`, call sites at 749/787 and 770/799/811). This is
  the "one shape" CLAUDE.md's guard-copying section asks for, not a fourth
  hand-written copy — and the C++ test file mirrors it: `test_radicle_impl.cpp`
  iterates all five methods against one shared assertion per mode rather than
  writing five separate test bodies (lines ~1620-1654), so the shared shape is
  exercised as a shared shape at the test layer too.

- **The two-store split (`config.json` vs `policies.db`) is visible in the
  code's shape, not just asserted in prose.** `nodeconfig.rs` and `seeding.rs`
  are separate modules with separate `open`/`load_document` helpers; `node.rs`
  only ever calls `nodeconfig::fingerprint` (never anything from `seeding.rs`)
  for `restartRequired`; and `radicle_impl.cpp`'s `setNodeConfig` explicitly
  does *not* emit `localAvailabilityChanged` while a seeding-adjacent comment
  in the same file explains why a config write and a seeding write differ.
  `radicle_ui_backend.cpp`'s `setNodeConfig`/`seedRepo`/`unseedRepo` forwarders
  carry the same distinction in their own comments (no capability refresh,
  for different reasons each). The split is structural, not just documented.

- **`NodeConfig` binds a home at construction and takes no home as a method
  argument**, matching `LocalReader`/`LocalWriter`'s existing pattern.
  `node_config.h`'s constructor takes `std::string home`; `get()`, `set()`,
  `listSeeded()`, `seed()`, `unseed()` all take none. This makes "which home"
  a property of the object rather than a per-call decision, so no call site
  can pass a different one — the wrong-home case is unrepresentable at this
  layer, and the class comment states the reasoning against all three
  candidates (`LocalReader`, `LocalWriter`, `EmbeddedNode`) that were
  considered and rejected.

- **`restartRequired`'s ordering is now unrepresentable-wrong**, matching
  `design.md`'s claim. `nodeconfig::get_inner`/`set_inner` both call the
  shared `reply()` helper, which reads `crate::node::restart_required(home)`
  as its last step — after the write in `set_inner`'s case — so there is no
  parameter a caller could pass on the wrong side of a write. This is a real
  instance of "put the complexity in the data structure": the ordering bug
  described in `design.md` (an earlier draft threading the flag through as a
  bool parameter, with the first caller getting it wrong) is structurally
  closed rather than checked.

- **The FFI boundary stayed `std::string`/`QString` in, string out** for all
  five new methods, at every layer: `node_config.h`'s five methods, the five
  `extern "C"` functions in `radicle_ffi.h`/`lib.rs`, and the five `SLOT`s in
  `radicle_ui.rep` are all plain strings — no new non-string parameter and no
  home/socket/bool crossing the QtRO boundary. `design.md`'s claim that this
  change "removes the only non-string argument the FFI boundary would have
  had" checks out: no such argument exists in the merged code.

- **`guarded()` covers all five new entry points.**
  `panic_guard.rs`'s `the_node_config_and_seeding_entry_points_are_guarded_too`
  exercises `radicle_node_get_config`, `radicle_node_set_config`,
  `radicle_node_list_seeded`, `radicle_node_seed` and `radicle_node_unseed`
  directly through the `extern "C"` boundary, including inputs shaped to reach
  panics in `serde_json` and `sqlite`'s open path (a file where a directory is
  expected). No entry point skips the guard.

- **`rebuildFromSettings()`'s two callers want the same thing.**
  `setSetting` (mode/home/socket change) and `createEmbeddedIdentity`
  (embedded-mode identity created) both call it to rebuild every home-derived
  member — including the newly-added `m_nodeConfig` — and then both emit
  `localAvailabilityChanged`. `setDependenciesForTest` deliberately does not
  call it, and the doc comment correctly explains why (it derives the store
  *from* settings, which would discard an injected one) rather than leaving
  that as an implicit assumption.

- **`CMakeLists.txt` and `tests/CMakeLists.txt`** both register
  `node_config.h`/`node_config.cpp` in their source lists; nothing was left
  building against a stale file list.

## Not reviewed here

Correctness of the validation logic, security of the home/socket boundary,
and readability/naming are explicitly out of scope for this pass — see the
correctness, security and readability findings files for those.
