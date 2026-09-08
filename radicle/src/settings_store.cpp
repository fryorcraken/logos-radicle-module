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

} // namespace

// ---------------------------------------------------------------------------
// Where the file lives.
// ---------------------------------------------------------------------------

std::string settingsPathFor(const std::string& xdgDataHome,
                            const std::string& userHome)
{
    // XDG's own fallback, which is also what Basecamp uses to derive its
    // per-profile data dir. Following the same rule is what keeps two Basecamp
    // profiles' settings apart without this module knowing anything about
    // Basecamp's directory layout: whatever XDG_DATA_HOME the profile was
    // launched with is the one this lands under.
    std::string base = xdgDataHome;
    if (base.empty()) {
        if (userHome.empty()) return {};
        base = userHome + "/.local/share";
    }
    return base + "/radicle-module/settings.json";
}

std::string settingsPathFromEnv()
{
    return settingsPathFor(envOr("XDG_DATA_HOME", ""), envOr("HOME", ""));
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
    // Embedded is selectable and persisted, but its node lifecycle is Phase 2.
    // Reporting it as not-startable is what lets the UI say so plainly instead
    // of offering a control that silently does nothing.
    //
    // THIS list is the single source of truth: `modeIsStartable` is derived
    // from it below rather than repeating the condition, so the boolean and the
    // set cannot drift into disagreeing, and Phase 2 adds `kModeEmbedded` here
    // and nowhere else.
    return {kModeExplore, kModeLocal};
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
        // Local is the default because it is what M2.1 already did: read
        // whatever Radicle home the environment names. A user who had a working
        // module before this change must not find it behaving differently
        // after it. (This mode was called `attach` before the vocabulary was
        // unified with the UI's; the meaning is unchanged.)
        {kKeyMode,       kModeLocal},
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
    // **The fallback is Explore, not the `local` default, and that is the whole
    // point of the fix rather than an incidental choice.** The default exists to
    // answer "what should a NEW user get", and for that Local is right: it is
    // what the module did before modes existed. This is a different question —
    // "what should a user whose stored choice is uninterpretable get" — and the
    // answers differ because the risk does. An unknown mode means the file is in
    // a state this build cannot read; claiming a node identity on the strength
    // of a file we have just admitted we cannot interpret is exactly the
    // identity confusion this milestone exists to prevent, and falling back to
    // `local` would do precisely that, silently, for every corrupt file.
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
