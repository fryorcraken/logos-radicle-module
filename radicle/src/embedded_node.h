#pragma once

#include <string>

namespace radicle {

/**
 * The Radicle node this module runs itself, started and stopped from the UI.
 *
 * The daemon half of Embedded mode. Steps 1 and 2 of M3 Phase 2 gave the mode an
 * identity and a home of its own; this is what runs a node in them.
 *
 * ## Why this is a class with no state
 *
 * Every method is static, because **the node is process-global and there is at
 * most one**. That is not an implementation shortcut — it is the isolation model:
 * two nodes writing one git storage is the corruption hazard the whole Embedded
 * design exists to prevent, and the Rust side holds a single slot so "already
 * running" is an answer this module can give rather than an invariant every call
 * site has to remember.
 *
 * Giving this class instances would misrepresent that. Two `EmbeddedNode`
 * objects would read as two nodes, and the second `start()` would be refused for
 * reasons the object model gave no hint of. `LocalReader::gitProbe` and
 * `initProfile` are static for the neighbouring reason — they answer questions
 * about the machine rather than about an instance's profile — and this is the
 * same grouping: it is about the process, not about a home this object holds.
 *
 * ## `home` and `socket` are passed in, never resolved here
 *
 * `LocalStore` owns path resolution — `resolvePaths()` — and exactly one place
 * deciding is what keeps the read path, the write path's announce step and the
 * node itself on one socket. They have already drifted apart once: `cobwrite`'s
 * announce hardcoded `<home>/node/control.sock` while the read path probed
 * `$XDG_RUNTIME_DIR`, and because an unannounced write is legitimately not an
 * error, nothing surfaced. A node that bound a socket `LocalStore` was not
 * watching would be the same bug in its worst form — `localNodeRunning` would
 * report false forever about a node running perfectly.
 *
 * ## What it does not do
 *
 * It does not decide *whether* a node should run, which mode is in force, or
 * where the home is. `RadicleImpl` does that, because those are questions about
 * settings; this class only knows how to start, stop and report on one.
 */
class EmbeddedNode {
public:
    /**
     * Start a node against `home`, with its control socket at `socket`.
     *
     * -> {"started":true,"home":"…","socket":"…","nodeId":"did:key:z6Mk…",
     *     "listening":[]}
     * -> {"error":"…"}
     *
     * **An encrypted identity needs its passphrase here, at start.** The node is
     * handed a decrypted signing key when it is constructed, so there is no
     * later point at which one could be supplied — a caller that creates an
     * identity with a passphrase is choosing a node it must unlock every time.
     * An empty `passphrase` is correct, and the only correct value, for an
     * identity created without one.
     *
     * **Returns only once the control socket answers.** A spawned thread is not
     * a started node, and reporting one would hand the UI a success it has to
     * discover was false.
     *
     * The node binds no TCP port: it can fetch and announce, but peers cannot
     * fetch from it. `listening` reports that (empty today) so a view states the
     * limitation rather than implying a full node.
     */
    static std::string start(const std::string& home, const std::string& socket,
                             const std::string& passphrase);

    /**
     * Stop the node this process started.
     *
     * -> {"stopped":bool[,"reason":"…"]} or {"error":"…"}
     *
     * Stopping a node that is not running is an **answer**, not an error — the
     * caller has got what it asked for, and making it a failure means every
     * shutdown path special-cases the ordinary case. An `{"error":…}` here means
     * a node was running and did not stop cleanly, which is worth reporting: it
     * may still hold its socket and storage.
     */
    static std::string stop();

    /**
     * What this process's node is doing.
     *
     * -> {"running":bool,"home":"…","socket":"…","serving":bool,"reason":"…"}
     *
     * **A view must read `serving`, not just `running`.** They answer different
     * questions — bookkeeping versus a live probe of the control socket — and
     * agree in every ordinary state. The two moments they disagree are the ones
     * a user cannot otherwise account for: mid-startup, and after the node has
     * failed internally. The Rust side's panic guard does not reach the threads a
     * running node spawns, so a reactor that dies leaves `running` true forever;
     * `serving` is the only field that notices.
     */
    static std::string status();
};

} // namespace radicle
