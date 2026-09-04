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

# The inspector-enabled Basecamp, built and patched by the one-time steps in
# CLAUDE.md's "Running the end-to-end layer". Checked for rather than rebuilt:
# it is a ~9-minute build and rebuilding it on every run is why a wrapper like
# this gets abandoned.
basecamp="$root/basecamp/bin/LogosBasecamp"
if [ ! -x "$basecamp" ]; then
    echo "local e2e: no inspector Basecamp at $basecamp" >&2
    echo "           Build it once with the two steps in CLAUDE.md," >&2
    echo "           \"Running the end-to-end layer\" (nix build + the" >&2
    echo "           .LogosBasecamp symlink the 0.1.0 probe expects)." >&2
    exit 1
fi

app_dir="$root/.scaffold/basecamp/portable"
if [ ! -d "$app_dir" ]; then
    echo "local e2e: no portable build at $app_dir" >&2
    echo "           Run \`lgs basecamp build-portable\` first." >&2
    exit 1
fi

echo "local e2e: reading $rad_home"

# Pinned to 0.1.0 to match CI: the inspector-probe workaround in CLAUDE.md is
# version-specific, so an unpinned npx can behave differently from what CI
# proved. --strict because without it sitometres exits 0 on INCONCLUSIVE.
exec npx --yes @paradoxcomputer/sitometres@0.1.0 run "$here/ui/local.yaml" \
    --app radicle_ui \
    --app-dir "$app_dir" \
    --basecamp "$basecamp" \
    --variant linux-amd64 \
    --env "RAD_HOME=$rad_home" \
    --strict
