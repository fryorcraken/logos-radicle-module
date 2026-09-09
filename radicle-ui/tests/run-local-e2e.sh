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

# Keep in step with ui-tests.yml's SITOMETRES.
#
# This was pinned to a fork commit for the inspector-probe bug, which only ever
# affected the BUNDLE: the released probe looks for `bin/.LogosBasecamp`, and a
# nix dirBundler bundle ships `bin/.LogosBasecamp.elf`. The dev `#app` this
# script now uses ships the former, so a published version works again.
#
# The drift this file previously recorded is still the lesson: it once claimed
# to match CI while naming a version that could not run at all, and nothing
# noticed because nothing runs this script in CI. If you change the pin in
# ui-tests.yml, change it here, and actually run this once.
SITOMETRES="@paradoxcomputer/sitometres@0.1.2"

# The dev Basecamp — the inspector is ON in `#app` and off in the shipping
# bundles; see docs/e2e.md. Built to a local out-link rather than through
# `lgs basecamp setup`, which would also seed profiles and rewrite
# scaffold.toml.
basecamp_bin="$root/result-basecamp/bin/LogosBasecamp"
if [ ! -x "$basecamp_bin" ]; then
    echo "local e2e: no Basecamp at $basecamp_bin" >&2
    echo "           Build it first — the expensive one-time step:" >&2
    echo "             nix build \"github:logos-co/logos-basecamp/\$(tomlq -r '.repos.basecamp.pin' scaffold.toml)#app\" \\" >&2
    echo "               -o result-basecamp --accept-flake-config" >&2
    echo "           See docs/e2e.md." >&2
    exit 1
fi

# The DEV modules, matching the dev Basecamp. Mismatching the two halves gets
# you a UI that opens to nothing and a timeout on step 1 — see docs/e2e.md.
app_dir="$root/.scaffold/basecamp/lgx"
if [ ! -d "$app_dir" ]; then
    echo "local e2e: no dev build at $app_dir" >&2
    echo "           Run \`lgs basecamp build --variant lgx\` first." >&2
    exit 1
fi

echo "local e2e: reading $rad_home"

# No --variant: sitometres' hostVariant() default is `linux-amd64-dev`, which
# is exactly what `.#lgx` produces.
#
# --strict because without it sitometres exits 0 on INCONCLUSIVE, and a green
# tick on no evidence is worse than a red one.
exec npx --yes "$SITOMETRES" run "$here/ui/local.yaml" \
    --app radicle_ui \
    --app-dir "$app_dir" \
    --basecamp "$basecamp_bin" \
    --env "RAD_HOME=$rad_home" \
    --strict
