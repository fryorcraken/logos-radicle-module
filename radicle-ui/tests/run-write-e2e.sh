#!/usr/bin/env sh
# Run the write end-to-end spec (tests/ui/write.yaml) against a Radicle profile
# built for it, and delete that profile afterwards.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# `write.yaml` is the only spec that CHANGES anything — it comments on an issue
# and creates one — and that makes it the only one that cannot be pointed at a
# real profile. Aimed at `~/.radicle` it would append a comment AND a whole new
# issue to a real repository on every run — COBs have no delete, so those
# accumulate forever — and it would depend on that repository happening to
# contain an issue to comment on. Neither is acceptable for something meant to
# run unattended.
#
# So the profile is created here, per run:
#
#   1. `cargo run --example seed_write_profile` builds a keystore, one
#      repository and one issue with one comment, through the radicle crate's
#      public API. No network, no `rad` binary, no daemon — a COB write is
#      local (see CLAUDE.md, "A COB write is local").
#   2. the spec runs with RAD_HOME pointed at it.
#   3. the whole directory is removed, whatever the spec's verdict.
#
# Idempotency therefore is not something the spec manages — it is a property of
# there never being a second run against the same state. Running this twice is
# indistinguishable from running it once, and a run killed half way leaves
# nothing for the next one to trip over.
#
# The seeded keystore is PLAINTEXT, which is what makes `canWriteLocal` true
# without a passphrase prompt or a passphrase in the environment. The key is
# generated from a fixed seed into a directory deleted on the way out and signs
# nothing that leaves it; it is a fixture, not a credential. See
# docs/M2.2-write-actions-design.md for the four signer rows and which one this
# is.
#
# RAD_HOME is still needed for the reason run-local-e2e.sh documents: sitometres
# gives every run a throwaway $HOME, so without the flag the module finds no
# profile at all and reports localAvailable=false on every machine, including
# this one. `--real-home` would also work and is deliberately not used — it
# would hand the app every credential in $HOME to make one directory readable,
# which for a spec that has its OWN profile would be gratuitous.
#
# Takes no arguments and sets its own environment, matching run-qml-tests.sh,
# check-qml-syntax.sh and run-local-e2e.sh beside it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

# Pinned to what ui-tests.yml pins. Published sitometres (0.1.0) refuses the
# bundle with "no Basecamp with the QML inspector compiled in": its probe never
# looks at the `.LogosBasecamp.elf` that nix's dirBundler actually ships. This
# build probes that sibling, which is why there is no copy-and-symlink step
# here. Keep in step with ui-tests.yml's SITOMETRES.
SITOMETRES="github:fryorcraken/sitometres#ab6b3ea20fa74bd480705856660defdbd4160fd9"

# `lgs basecamp setup --inspector` records the binary it built here rather than
# leaving a ./result symlink. Parsed, not sourced: `. file` would EXECUTE it,
# and basecamp_bin is a path, so a value carrying $(...) would run.
state="$root/.scaffold/state/basecamp.state"
if [ ! -f "$state" ]; then
    echo "write e2e: no $state" >&2
    echo "           Run \`lgs basecamp setup --inspector\` first — it builds the" >&2
    echo "           inspector Basecamp and records where it put it. That is the" >&2
    echo "           expensive one-time step; see CLAUDE.md, \"Running the" >&2
    echo "           end-to-end layer\"." >&2
    exit 1
fi
basecamp_bin=$(sed -n 's/^basecamp_bin=//p' "$state")
if [ -z "$basecamp_bin" ] || [ ! -x "$basecamp_bin" ]; then
    echo "write e2e: $state names no usable basecamp_bin" >&2
    echo "           Re-run \`lgs basecamp setup --inspector\`." >&2
    exit 1
fi

app_dir="$root/.scaffold/basecamp/portable"
if [ ! -d "$app_dir" ]; then
    echo "write e2e: no portable build at $app_dir" >&2
    echo "           Run \`lgs basecamp build-portable\` first." >&2
    exit 1
fi

# Under the crate's own gitignored tmp/, not /tmp: everything a run writes
# stays inside the working directory, which is the convention tests/fixture
# already follows. The PID keeps two concurrent runs from colliding.
scratch="$root/radicle/rust-ffi/tmp/write-e2e-$$"

cleanup() {
    # Unconditional, and registered BEFORE the profile is created, so a seeder
    # that dies half way through still leaves nothing behind.
    rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

echo "write e2e: seeding a throwaway profile under $scratch"
# Three lines, in a fixed order: home, rid, issue id. Only the first is needed
# here — the spec finds the repository and the issue by opening the only ones
# there — but the seeder prints all three because a failing run is much easier
# to read when the ids are in the log.
seeded=$(cd "$root/radicle/rust-ffi" && cargo run --quiet --example seed_write_profile -- "$scratch")
rad_home=$(printf '%s\n' "$seeded" | sed -n '1p')

if [ ! -d "$rad_home/storage" ]; then
    echo "write e2e: the seeder produced no storage/ under $rad_home" >&2
    echo "           (that directory is the marker LocalStore uses to decide a" >&2
    echo "            profile is real, so the spec would fail at step 3)" >&2
    exit 1
fi

echo "write e2e: rid   $(printf '%s\n' "$seeded" | sed -n '2p')"
echo "write e2e: issue $(printf '%s\n' "$seeded" | sed -n '3p')"
echo "write e2e: RAD_HOME=$rad_home"

# Not `exec`: the EXIT trap has to run, so the profile is removed whether the
# spec passes or fails. --strict because without it sitometres exits 0 on
# INCONCLUSIVE, and a green tick on no evidence is worse than a red one.
npx --yes "$SITOMETRES" run "$here/ui/write.yaml" \
    --app radicle_ui \
    --app-dir "$app_dir" \
    --basecamp "$basecamp_bin" \
    --variant linux-amd64 \
    --env "RAD_HOME=$rad_home" \
    --strict
