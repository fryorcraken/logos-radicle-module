#!/usr/bin/env sh
# Run the local-node end-to-end spec (tests/ui/local.yaml) against this
# machine's own ~/.radicle.
#
# WHY THIS SCRIPT EXISTS AT ALL
# -----------------------------
# `local.yaml` is the only spec that exercises the `local*` half of the module,
# and without this wrapper it CANNOT PASS ON ANY MACHINE — including one with a
# perfectly good Radicle profile.
#
# sitometres deliberately gives every run a throwaway $HOME ("so your real
# wallets, keys and settings are never touched"). `LocalStore` resolves the
# Radicle home from RAD_HOME, else $HOME/.radicle — so under a throwaway HOME
# there is no profile, `getCapabilities` reports localAvailable=false, the
# toggle hides its "Local" segment, and the spec fails at step 3 with
#
#     state "root.localAvailable === true" — evaluated to false
#
# which reads as "this machine has no Radicle profile" and is wrong. The spec's
# own header used to say exactly that, so the one automated check covering
# local browsing was guaranteed-red for a reason that had nothing to do with
# the code under test. A permanently-red check is a check nobody runs, which is
# how the local path came to have no working end-to-end coverage at all.
#
# The fix is one flag. `LocalStore` already prefers RAD_HOME over HOME, so
# pointing it at the real profile restores local browsing while leaving the
# throwaway HOME — and therefore the wallet and settings isolation — intact.
# `--real-home` would also work and is deliberately NOT used: it hands the app
# every credential in $HOME to make one directory readable.
#
# Reads only. Nothing in the local path writes, signs, or contacts the node
# daemon, so running this against your real profile cannot modify it.
#
# The spec ALSO runs in CI, against a profile seeded for the run — see
# ui-tests.yml's matrix and local.yaml's own header. This wrapper is the local
# route: same spec, pointed at your own node instead. Almost every assertion
# holds either way; local.yaml names the one step that does not.
#
# Takes no arguments and sets its own environment, matching run-qml-tests.sh
# and check-qml-syntax.sh beside it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

# Same resolution order the C++ side uses, so this script and the module agree
# on which profile is under test.
rad_home=${RAD_HOME:-"$HOME/.radicle"}

if [ ! -d "$rad_home/storage" ]; then
    echo "local e2e: no Radicle profile at $rad_home" >&2
    echo "           (looked for a storage/ directory, the same marker" >&2
    echo "            LocalStore uses to decide a profile is real)" >&2
    echo "           Install Radicle and run \`rad auth\`, or set RAD_HOME." >&2
    exit 1
fi

# Pinned to what ui-tests.yml pins, and deliberately NOT to the published
# version.
#
# This script used to invoke `@paradoxcomputer/sitometres@0.1.0`, with a
# comment saying that was "to match CI". It had stopped matching, and the drift
# was invisible because nothing runs this script in CI: published 0.1.0 REFUSES
# the bundle outright with "no Basecamp with the QML inspector compiled in",
# since its probe looks for `bin/.LogosBasecamp` and never at the
# `bin/.LogosBasecamp.elf` that nix's dirBundler actually ships. So this wrapper
# could not run on any machine — the same permanently-red shape the RAD_HOME
# note above exists to document, arriving a second time in the same file.
# Keep in step with ui-tests.yml's SITOMETRES.
SITOMETRES="github:fryorcraken/sitometres#ab6b3ea20fa74bd480705856660defdbd4160fd9"

# `lgs basecamp setup --inspector` records the binary it built here rather than
# leaving a ./result symlink. Parsed, not sourced: `. file` would EXECUTE it,
# and basecamp_bin is a path, so a value carrying $(...) would run.
#
# This used to look for "$root/basecamp/bin/LogosBasecamp" — a copy-and-symlink
# layout that existed only to work around the 0.1.0 probe bug above, and that
# was deleted when the workaround was dropped. The path had not existed for
# some time and nothing noticed, for the same reason as the pin.
state="$root/.scaffold/state/basecamp.state"
if [ ! -f "$state" ]; then
    echo "local e2e: no $state" >&2
    echo "           Run \`lgs basecamp setup --inspector\` first — it builds the" >&2
    echo "           inspector Basecamp and records where it put it. That is the" >&2
    echo "           expensive one-time step; see docs/e2e.md." >&2
    exit 1
fi
basecamp_bin=$(sed -n 's/^basecamp_bin=//p' "$state")
if [ -z "$basecamp_bin" ] || [ ! -x "$basecamp_bin" ]; then
    echo "local e2e: $state names no usable basecamp_bin" >&2
    echo "           Re-run \`lgs basecamp setup --inspector\`." >&2
    exit 1
fi

app_dir="$root/.scaffold/basecamp/portable"
if [ ! -d "$app_dir" ]; then
    echo "local e2e: no portable build at $app_dir" >&2
    echo "           Run \`lgs basecamp build-portable\` first." >&2
    exit 1
fi

echo "local e2e: reading $rad_home"

# --strict because without it sitometres exits 0 on INCONCLUSIVE, and a green
# tick on no evidence is worse than a red one.
exec npx --yes "$SITOMETRES" run "$here/ui/local.yaml" \
    --app radicle_ui \
    --app-dir "$app_dir" \
    --basecamp "$basecamp_bin" \
    --variant linux-amd64 \
    --env "RAD_HOME=$rad_home" \
    --strict
