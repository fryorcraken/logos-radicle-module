#include "settings_store.h"

#include "local_reader.h"
// For kSunPathMax — the 108-byte cap the radSocket setting is validated
// against, named in one place so this file and resolvePaths() cannot disagree
// about the number.
#include "local_store.h"
#include "seed_client.h"

#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace radicle {

namespace {

std::string envOr(const char* name, const std::string& fallback)
{
    const char* v = std::getenv(name);
    return (v && *v) ? std::string(v) : fallback;
}

/// Create every directory along `path` (the file's parent). Best-effort: a
/// failure here surfaces as a failed write, which `set()` reports.
void makeParentDirs(const std::string& path)
{
    const size_t lastSlash = path.rfind('/');
    if (lastSlash == std::string::npos || lastSlash == 0) return;

    const std::string dir = path.substr(0, lastSlash);
    std::string sofar;
    size_t pos = 0;
    while (pos < dir.size()) {
        const size_t next = dir.find('/', pos + 1);
        sofar = (next == std::string::npos) ? dir : dir.substr(0, next);
        ::mkdir(sofar.c_str(), 0755);
        if (next == std::string::npos) break;
        pos = next;
    }
}

/// This module's own directory under Basecamp's per-profile XDG data dir.
///
/// Both module-owned paths — the settings file and the embedded home — are
/// derived from this one function rather than each spelling out the base, so
/// they cannot come to disagree about which Basecamp profile they belong to.
/// That agreement is the whole reason the embedded home is safe to place here:
/// it inherits the per-profile separation the settings file already has, and it
/// inherits it by construction rather than by two functions being kept in step.
///
/// Empty when nothing can be resolved, which both callers propagate rather than
/// substituting a plausible-looking path relative to nothing.
std::string moduleDataDir(const std::string& xdgDataHome,
                          const std::string& userHome)
{
    // XDG's own fallback, which is also what Basecamp uses to derive its
    // per-profile data dir. Following the same rule is what keeps two Basecamp
    // profiles apart without this module knowing anything about Basecamp's
    // directory layout: whatever XDG_DATA_HOME the profile was launched with is
    // the one this lands under.
    std::string base = xdgDataHome;
    if (base.empty()) {
        if (userHome.empty()) return {};
        base = userHome + "/.local/share";
    }
    return base + "/radicle-module";
}

} // namespace

// ---------------------------------------------------------------------------
// Where the file lives.
// ---------------------------------------------------------------------------

std::string settingsPathFor(const std::string& xdgDataHome,
                            const std::string& userHome)
{
    const std::string dir = moduleDataDir(xdgDataHome, userHome);
    if (dir.empty()) return {};
    return dir + "/settings.json";
}

std::string settingsPathFromEnv()
{
    return settingsPathFor(envOr("XDG_DATA_HOME", ""), envOr("HOME", ""));
}

std::string embeddedHomeFor(const std::string& xdgDataHome,
                            const std::string& userHome)
{
    const std::string dir = moduleDataDir(xdgDataHome, userHome);
    if (dir.empty()) return {};
    return dir + "/embedded-home";
}

std::string embeddedHomeFromEnv()
{
    return embeddedHomeFor(envOr("XDG_DATA_HOME", ""), envOr("HOME", ""));
}

// ---------------------------------------------------------------------------
// SettingsStore
// ---------------------------------------------------------------------------

SettingsStore::SettingsStore(std::string path)
    : m_path(std::move(path))
{
}

bool SettingsStore::isKnownMode(const std::string& mode)
{
    return mode == kModeExplore || mode == kModeLocal || mode == kModeEmbedded;
}

std::vector<std::string> SettingsStore::startableModes()
{
    // All three. Embedded joined this list when `embeddedHomeFor()` gave it a
    // home to point at — and the two had to land together, which is worth
    // recording because they look separable.
    //
    // The whole UI derives from this list: `RepoList.notImplemented`,
    // `SourceToggle`'s per-segment marker and caption, `ModePicker`'s per-row
    // caveat and `SourceState.modeStartable` all read it rather than comparing
    // against the word "embedded" — which was itself a deliberate Phase 1
    // change, so that this line would be the only edit. Adding the mode here
    // BEFORE it had a home would therefore have told all four screens at once
    // that Embedded is startable, while `storeForSettings()` still handed it no
    // home: a repository list fetching against nothing, a segment with no
    // caveat, and a wizard-shaped hole where the identity should be. That is the
    // identity confusion `storeForSettings()`'s Embedded paragraph exists to
    // prevent, arriving one layer up.
    //
    // "Startable" here means the mode resolves a home this module owns and can
    // create an identity into — NOT that a node daemon runs. The daemon is step
    // 3 (`radicle-node`, +111 crates and a vendor rehash) and nothing in this
    // list claims otherwise; `localNodeRunning` is the field that answers that,
    // and it is a live socket probe rather than a build fact.
    //
    // THIS list stays the single source of truth: `modeIsStartable` is derived
    // from it below rather than repeating the condition, so the boolean and the
    // set cannot drift into disagreeing.
    return {kModeExplore, kModeLocal, kModeEmbedded};
}

bool SettingsStore::modeIsStartable(const std::string& mode)
{
    for (const auto& m : startableModes())
        if (m == mode) return true;
    return false;
}

nlohmann::json SettingsStore::load() const
{
    nlohmann::json defaults{
        // **Explore, because the default is what a user with NO settings file
        // gets, and that is overwhelmingly a first run.**
        //
        // This was `local`, on the argument that it preserved what the module
        // did before modes existed — read whatever Radicle home the environment
        // names — so an existing user would not find the module behaving
        // differently. That argument is about a user who ALREADY has a working
        // profile, and it answers the wrong question: nobody who used a
        // pre-settings build HAS a settings file, so every reader of this
        // default is a fresh start, and a fresh start may have no Radicle home
        // at all.
        //
        // In `local` with no profile the module can show nothing. The UI
        // derives its method prefix from the mode, so `localListRepos` is the
        // only list call it will issue; that returns the "no local profile"
        // error, the repository list stays empty, and the seed is never asked.
        // A first-run user sees an empty app and no way to tell it apart from a
        // node with no repositories.
        //
        // Not hypothetical: every seed-browsing end-to-end spec runs under a
        // throwaway `$HOME` with no profile, and all of them broke at once when
        // the `local` default landed.
        //
        // The continuity that was being protected costs exactly one click, once
        // — picking Local persists, so a user with a node clicks it on first
        // launch and never again. Weighed against a first-run user who cannot
        // reach anything at all, that is not close.
        //
        // This also makes the file self-consistent: `load()` below sends an
        // uninterpretable stored mode to Explore too. Two different questions —
        // "what should a NEW user get" and "what should a user whose stored
        // choice is unreadable get" — that happen to have the same answer, for
        // different reasons. `the_default_and_the_unknown_mode_fallback_agree`
        // pins the coincidence so a future change to either is deliberate.
        {kKeyMode,       kModeExplore},
        {kKeyRadHome,    ""},
        {kKeyRadSocket,  ""},
        {kKeyGitPath,    ""},
        {kKeyRemoteSeed, ""},
    };

    if (m_path.empty()) return defaults;

    std::ifstream in(m_path);
    if (!in) return defaults;

    std::stringstream buffer;
    buffer << in.rdbuf();

    // A corrupted settings file yields defaults, not an error. The alternative
    // is a module that refuses to start because of a file the user cannot see
    // and did not knowingly write.
    auto parsed = nlohmann::json::parse(buffer.str(), nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object()) return defaults;

    for (auto& [key, value] : parsed.items()) {
        if (defaults.contains(key) && value.is_string()) defaults[key] = value;
    }

    // A mode this build does not know is replaced rather than passed through.
    //
    // `set()` validates, so nothing this module writes can be unknown — but the
    // file lives on disk under the user's own data directory, and a hand edit, a
    // torn write, or a settings file written by a NEWER build all produce one.
    // Without this the unknown string reached every consumer verbatim, and both
    // of them treated it as Local by falling through an else: `getCapabilities`
    // reported the attached profile's home, `localAvailable: true` and full read
    // access, all labelled with a mode string the UI has no segment for.
    //
    // **The fallback is Explore, and it must stay Explore on its own merits
    // even though the default above now agrees with it.** They answer different
    // questions — "what should a NEW user get" versus "what should a user whose
    // stored choice is uninterpretable get" — and the reasons are unrelated, so
    // a future change to one must not be applied to the other by assuming they
    // move together. An unknown mode means the file is in a state this build
    // cannot read; claiming a node identity on the strength of a file we have
    // just admitted we cannot interpret is exactly the identity confusion this
    // milestone exists to prevent, and falling back to `local` would do
    // precisely that, silently, for every corrupt file.
    //
    // Explore is the only mode whose definition is "do not touch a local
    // profile at all". It grants nothing, claims no identity, has a real segment
    // in the UI, and leaves the file's other settings — the seed above all —
    // intact and useful. The user can see which mode is in force and pick again.
    //
    // Nothing is REWRITTEN on disk here: this is a read. The stored string stays
    // as the user (or the newer build) left it, so switching back to a build
    // that understands it loses nothing.
    if (!isKnownMode(defaults[kKeyMode].get<std::string>()))
        defaults[kKeyMode] = kModeExplore;

    return defaults;
}

bool SettingsStore::save(const nlohmann::json& settings) const
{
    if (m_path.empty()) return false;
    makeParentDirs(m_path);

    // Write to a temporary beside the target, then rename over it.
    //
    // The obvious version — open the real file with `trunc` and write — has a
    // window in which the file exists and is empty or half-written. Two
    // Basecamp profiles do not share this file, but one profile's module and a
    // second instance of it can (the repo has hit exactly that with two
    // Basecamps over one ~/.radicle), and a crash mid-write leaves the same
    // wreckage. The failure it produces is quiet: `load()` treats an
    // unparseable file as "use defaults", so the user's mode, home and seed
    // silently revert with nothing reported.
    //
    // `rename(2)` within one directory is atomic, so a reader sees either the
    // whole old file or the whole new one and never a partial third thing.
    // Same directory matters — across filesystems rename fails rather than
    // silently copying.
    const std::string temp = m_path + ".tmp";
    {
        std::ofstream out(temp, std::ios::trunc);
        if (!out) return false;
        out << settings.dump(2) << "\n";
        out.flush();
        if (!out.good()) {
            ::unlink(temp.c_str());
            return false;
        }
    } // closed here: the rename must not race the stream's own flush-on-close.

    // Force the temp file's CONTENTS to disk before the rename makes it the
    // settings file.
    //
    // `rename(2)` is atomic with respect to other processes, which is what the
    // comment above is about — but it says nothing about power loss. The rename
    // is a metadata operation and can reach the disk before the data blocks it
    // points at, so a crash in that window leaves the settings file present,
    // named correctly, and zero-length. `load()` then treats it as corrupt and
    // silently reverts the user's mode, home and seed — the exact quiet failure
    // the temp-and-rename dance exists to prevent, arriving through the half of
    // it that was missing.
    //
    // Opened separately rather than through the ofstream because C++ streams
    // expose no file descriptor. Failure is not fatal: the data is written and
    // the rename below still produces a correct file on every path except a
    // power loss in this window, so refusing the whole save would trade a rare
    // durability gap for a common, certain failure.
    const int fd = ::open(temp.c_str(), O_RDONLY);
    if (fd >= 0) {
        ::fsync(fd);
        ::close(fd);
    }

    if (::rename(temp.c_str(), m_path.c_str()) != 0) {
        ::unlink(temp.c_str());
        return false;
    }
    return true;
}

nlohmann::json SettingsStore::all() const
{
    return load();
}

std::string SettingsStore::get(const std::string& key) const
{
    const auto settings = load();
    if (!settings.contains(key)) return {};
    return settings.value(key, std::string{});
}

nlohmann::json SettingsStore::set(const std::string& key, const std::string& value)
{
    auto settings = load();

    // An unknown key is refused rather than stored. Silently accepting one
    // gives the user a setting that appears saved and does nothing, which is
    // strictly worse than being told the name is wrong.
    if (!settings.contains(key))
        return makeError("unknown setting '" + key + "'");

    if (key == kKeyMode) {
        // Built from the constants rather than spelled out: this sentence
        // listed the old names verbatim, and a rename would have left it
        // confidently naming modes that no longer exist while the validation
        // above rejected the ones that do.
        if (!isKnownMode(value))
            return makeError("unknown mode '" + value + "' — expected one of: "
                             + kModeExplore + ", " + kModeLocal + ", "
                             + kModeEmbedded);
    } else if (key == kKeyGitPath) {
        // Validated by RUNNING it, not by stat-ing it: an executable that
        // exists but is not git has to fail here, while the user is looking at
        // the field they typed it into, rather than at the moment they push
        // their first patch. An empty value means "find it on PATH" and is
        // always acceptable — that is the default, and a working one.
        if (!value.empty()) {
            const auto probe =
                nlohmann::json::parse(LocalReader::gitProbe(value), nullptr, false);
            if (probe.is_discarded())
                return makeError("could not validate the git path");
            if (!probe.value("found", false)) {
                return makeError("not a usable git: "
                                 + probe.value("reason", std::string("unknown reason")));
            }
        }
    } else if (key == kKeyRadSocket) {
        // The 108-byte sun_path cap, checked at set time for the same reason.
        // resolvePaths() checks it again when the paths are actually used —
        // this is not redundant, because a socket can also arrive from the
        // environment, which this store never sees.
        if (!value.empty() && value.size() + 1 > kSunPathMax) {
            return makeError("the node control socket path is too long: "
                             + value + " is " + std::to_string(value.size())
                             + " bytes, but a Unix socket path is capped at "
                             + std::to_string(kSunPathMax - 1) + " bytes");
        }
    } else if (key == kKeyRemoteSeed) {
        // Deliberately shape-only. Whether the seed actually answers is
        // setRemoteSeed's job — it probes and rolls back — and duplicating that
        // here would mean two places deciding what a good seed is, and a
        // settings write that blocks on the network.
        if (!value.empty() && value.rfind("http://", 0) != 0
            && value.rfind("https://", 0) != 0) {
            return makeError("a seed URL must start with http:// or https://");
        }
    }

    settings[key] = value;
    if (!save(settings))
        return makeError("could not write settings to " + m_path);

    return settings;
}

} // namespace radicle
