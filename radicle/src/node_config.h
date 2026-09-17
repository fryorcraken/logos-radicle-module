#pragma once

#include <string>

namespace radicle {

/**
 * The node's own configuration and seeding policies, under one Radicle home.
 *
 * ## Why this is a class of its own, and not a member of an existing one
 *
 * Three candidates were considered and each was wrong for a different reason.
 *
 * `LocalReader` reads *repository storage*, and its own doc comment says so.
 * Three of the five methods here write, and two of those write to a SQLite
 * database rather than to git storage at all — putting them there would make a
 * class named for reading own a write path, which is the kind of drift that
 * ends with nobody able to say what a class is for.
 *
 * `LocalWriter` is closer, but it is constructed with a home **and a socket**
 * and every method on it needs a signing key: a write there appends to a COB's
 * operation DAG and announces it. None of that applies to editing a JSON file
 * or a policy row — neither signs anything, neither touches the node — so the
 * socket would be an unused member and the signer requirement a false one.
 *
 * `EmbeddedNode` is static because **the node is process-global and there is at
 * most one**. That is a real property of a running daemon and not a property of
 * these: a configuration and a policy store belong to a *home*, and two homes
 * have two of each. Making these static would say the opposite of what is true,
 * and would drop the one thing an instance is good for here — being bound to
 * the home `LocalStore` resolved, so no call site can pass a different one.
 *
 * ## `home` is a constructor argument and never a method parameter
 *
 * The same rule as everywhere else in this layer: `LocalStore` resolves the
 * home, and a reader or writer is built from it. It matters more here than for
 * a read, because these WRITE — a home arriving from a sandboxed view across
 * the QtRO boundary would be a way to rewrite the configuration and seeding
 * policies of a node this module does not own. `RadicleImpl` is what decides
 * which mode may call which method; this class only knows how.
 *
 * ## No socket, deliberately
 *
 * Neither store is reached through the node. `config.json` is a file the node
 * reads when it is constructed; `policies.db` is a SQLite database the node
 * reads as it works. Both are edited on disk with the node running or stopped,
 * and neither edit is announced. A socket member would imply a round trip that
 * does not happen.
 */
class NodeConfig {
public:
    /// `home` is the Radicle home — normally `LocalStore::home()`, which owns
    /// path resolution. An empty home yields an error object from every method
    /// rather than a crash.
    explicit NodeConfig(std::string home);

    const std::string& home() const { return m_home; }

    /**
     * The node's configuration, as a panel renders it.
     *
     * -> {"alias","listen":[…],"externalAddresses":[…],"connect":[…],"peers",
     *     "inboundReachable":bool,"restartRequired":bool} or {"error":"…"}
     *
     * `restartRequired` is true exactly when a node is running against this home
     * and `config.json` no longer says what that node was started with — a
     * comparison, not a flag, so a change that is undone clears it and a restart
     * clears it without anything being reset.
     */
    std::string get();

    /**
     * Change one or more fields. `changes` is a JSON object naming a subset of
     * `alias`, `listen`, `externalAddresses`, `connect` and `peers`.
     *
     * -> the same shape `get()` returns, or {"error":"…"}
     *
     * Returns the **whole** configuration so a view re-renders from what was
     * stored rather than from what it submitted, and leaves every field the
     * call did not name — including ones this build has no name for — as it
     * found them.
     *
     * The reply's `restartRequired` is read after the write, so a change made
     * while a node is running comes back with the banner already raised.
     */
    std::string set(const std::string& changes);

    /**
     * Every repository this node is seeding, with each entry's scope.
     *
     * -> {"items":[{"rid":"rad:…","scope":"all"|"followed"}]} or {"error":"…"}
     *
     * A different question from `LocalReader::listRepos("seeded", …)`, which
     * reports what is in storage. Neither is derived from the other.
     */
    std::string listSeeded();

    /**
     * Seed `rid` with `scope` — `all` or `followed`.
     *
     * -> {"rid":"rad:…","scope":"…"} or {"error":"…"}
     */
    std::string seed(const std::string& rid, const std::string& scope);

    /**
     * Stop seeding `rid`. Unseeding what is not seeded is an answer, not an
     * error, and nothing is deleted from storage.
     *
     * -> {"unseeded":bool} or {"error":"…"}
     */
    std::string unseed(const std::string& rid);

private:
    std::string m_home;
};

} // namespace radicle
