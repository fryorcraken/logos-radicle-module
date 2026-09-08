#pragma once

#include <nlohmann/json.hpp>

#include <string>
#include <vector>

namespace radicle {

/**
 * The module's own persistent settings.
 *
 * Before this existed the module persisted **nothing**: `setRemoteSeed`
 * mutated an in-memory field that was lost on restart, and the seed list was
 * three compile-time constants. Mode, the chosen home, the git path and the
 * seed all have to survive a restart or every one of them is a thing the user
 * re-chooses on every launch.
 *
 * ## Where the file lives, and why not `~/.radicle/config.json`
 *
 * Under Basecamp's per-profile XDG data directory, so `alice` and `bob` keep
 * separate settings — matching the isolation the rest of the stack already has.
 *
 * Deliberately **not** `~/.radicle/config.json`. That file belongs to the node:
 * the node rewrites it, its schema is the node's to change, and its lifetime is
 * the profile's. Which mode this module is in, and where it should look for
 * git, are facts about the *module* — a different owner and a different
 * lifetime. Writing them into the node's file would mean this module editing a
 * document another program owns, and would tie settings to a profile that, in
 * Explore mode, does not exist at all.
 *
 * ## Validation on write, not on use
 *
 * `set()` validates and refuses, returning the module's standard
 * `{"error":"..."}`. The alternative — store anything, validate when something
 * reads it — defers the failure to a moment the user has no context for, which
 * is the deferred-failure shape this repo keeps getting bitten by. A bad git
 * path should be refused while the user is looking at the field they just
 * typed it into, not when they push their first patch.
 *
 * Unknown keys are refused for the same reason: a typo'd key that is silently
 * accepted reads as a setting that does not work.
 */
class SettingsStore {
public:
    /// Node lifecycle modes. Stored as the strings below.
    ///
    /// - `explore`   — no local node at all; browse a seed over HTTP.
    /// - `local`     — use an existing Radicle home; the node is not ours.
    /// - `embedded`  — a Basecamp-owned home whose node we start. **Selectable
    ///                 but not startable** until Phase 2 lands the daemon; see
    ///                 `modeIsStartable()`.
    ///
    /// **These are the same words the UI shows**, deliberately. They used to be
    /// `attach`/`seedOnly` while the view called the same things "Local" and
    /// "Explore", and that gap was not cosmetic: the view carried a SECOND
    /// vocabulary — a `source` of `remote`/`local` — for the same question, the
    /// two leaked into the same header bar, and a user reported the result as
    /// unintelligible. One vocabulary end to end is what stops that recurring,
    /// so a rename here is a rename of the label too, and vice versa.
    ///
    /// Note the deliberate near-collision: `local` is a mode value AND the
    /// prefix of the `local*` backend methods. They are different things that
    /// happen to share a word — `SourceState.qml` derives the method prefix
    /// from the mode rather than passing one off as the other, and nothing
    /// should conflate them just because the strings match.
    static constexpr const char* kModeExplore  = "explore";
    static constexpr const char* kModeLocal    = "local";
    static constexpr const char* kModeEmbedded = "embedded";

    /// Settings keys. Named constants rather than bare strings so a typo is a
    /// compile error on this side of the boundary.
    static constexpr const char* kKeyMode       = "mode";
    static constexpr const char* kKeyRadHome    = "radHome";
    static constexpr const char* kKeyRadSocket  = "radSocket";
    static constexpr const char* kKeyGitPath    = "gitPath";
    static constexpr const char* kKeyRemoteSeed = "remoteSeed";

    /// `path` is the settings file. Reading a missing or malformed file yields
    /// defaults rather than an error: a user whose settings file was corrupted
    /// should get a working module with default settings, not a dead one.
    explicit SettingsStore(std::string path);

    const std::string& path() const { return m_path; }

    /// Every setting, with defaults filled in for anything unset.
    /// -> {"mode":"...","radHome":"...","radSocket":"...","gitPath":"...",
    ///     "remoteSeed":"..."}
    nlohmann::json all() const;

    /// One setting's current value, or "" when unset.
    std::string get(const std::string& key) const;

    /// Validate and persist one setting.
    ///
    /// -> the full settings object on success, `{"error":"..."}` on refusal.
    /// Returning everything rather than just the changed key means a caller
    /// re-renders from one reply and cannot show a stale view of the rest.
    nlohmann::json set(const std::string& key, const std::string& value);

    /// Whether `mode` names a mode this build can actually start.
    ///
    /// Embedded is selectable and persisted now, but its daemon is Phase 2, so
    /// this returns false for it. Kept as a function rather than a constant so
    /// the place that has to change when Phase 2 lands is one line, and so the
    /// UI can ask rather than hardcoding its own copy of the answer.
    ///
    /// **This answers a question about ONE mode.** A picker offering three rows
    /// needs `startableModes()` instead — see the warning there.
    static bool modeIsStartable(const std::string& mode);

    /// Every mode this build can actually start, in the order they are offered.
    ///
    /// **This exists because `modeIsStartable(currentMode)` cannot substitute
    /// for it, and a UI that tried to derive one from the other shipped a real
    /// bug.** The boolean is a fact about the mode in force; a picker needs the
    /// fact for every row it draws. In `local` — the default, and where every
    /// first-time user is — the boolean is true, from which nothing at all
    /// follows about Embedded. Deriving the set from it therefore annotated
    /// nothing, and the user learned Embedded could not run only *after*
    /// selecting it and having the choice persisted: a control that silently
    /// does nothing, which is precisely what `ModePicker` promises never to be.
    ///
    /// So the set is reported directly and consumed directly. When Phase 2
    /// lands its daemon this and `modeIsStartable` change together — they are
    /// two views of one fact, and keeping them beside each other is what makes
    /// that obvious.
    static std::vector<std::string> startableModes();

    /// True when `mode` is one of the three known modes.
    static bool isKnownMode(const std::string& mode);

private:
    nlohmann::json load() const;
    bool save(const nlohmann::json& settings) const;

    std::string m_path;
};

/**
 * Where the settings file belongs, given the environment.
 *
 * A pure function of its inputs so the precedence is testable without setenv.
 * `xdgDataHome` empty falls back to `$HOME/.local/share`, matching the XDG
 * spec — and matching what Basecamp itself does, which is what keeps two
 * Basecamp profiles' settings apart without this module needing to know
 * anything about Basecamp's own directory layout.
 */
std::string settingsPathFor(const std::string& xdgDataHome,
                            const std::string& userHome);

/// `settingsPathFor` with the environment read from the process.
std::string settingsPathFromEnv();

} // namespace radicle
