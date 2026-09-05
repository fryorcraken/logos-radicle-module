#pragma once

#include <cstdint>
#include <string>

namespace radicle {

/**
 * Reads the local node's storage (~/.radicle) through the Rust backend.
 *
 * This is the local counterpart of `SeedClient`: it owns one boundary (the
 * `extern "C"` surface in `radicle_ffi.h`) so nothing else in the module has
 * to think about raw pointers or who frees what. Every method returns the same
 * JSON string the corresponding `local*` module method returns, so
 * `radicle_impl.cpp` is a one-line forward.
 *
 * The shapes match `remote*`'s byte for byte — that is the contract
 * `radicle_impl.h` states and the reason a view renders either source without
 * branching. They are pinned by tests in `radicle/rust-ffi/tests/` (against a
 * real profile) and in `radicle/tests/test_local_reader.cpp` (at this layer).
 *
 * Every call is synchronous and reads from disk. There is no network and no
 * daemon involved: local browsing works with the node stopped.
 */
class LocalReader {
public:
    /// `home` is the Radicle home — normally `LocalStore::home()`, which owns
    /// the RAD_HOME/HOME resolution. An empty home yields an error object from
    /// every method rather than a crash.
    explicit LocalReader(std::string home);

    const std::string& home() const { return m_home; }

    std::string listRepos(const std::string& scope, int64_t page, int64_t perPage);
    std::string getRepo(const std::string& rid);
    std::string listBranches(const std::string& rid);
    std::string getTree(const std::string& rid, const std::string& sha,
                        const std::string& path);
    std::string getBlob(const std::string& rid, const std::string& sha,
                        const std::string& path);
    std::string getReadme(const std::string& rid, const std::string& sha);
    std::string listCommits(const std::string& rid, const std::string& sha,
                            int64_t page, int64_t perPage);
    std::string getCommit(const std::string& rid, const std::string& sha);
    std::string listIssues(const std::string& rid, const std::string& status,
                           int64_t page, int64_t perPage);
    std::string getIssue(const std::string& rid, const std::string& id);
    std::string listPatches(const std::string& rid, const std::string& status,
                            int64_t page, int64_t perPage);
    std::string getPatch(const std::string& rid, const std::string& id);

private:
    std::string m_home;
};

} // namespace radicle
