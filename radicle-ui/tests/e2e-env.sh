#!/bin/sh
# Shared setup for the e2e wrapper scripts, sourced by run-local-e2e.sh and
# run-write-e2e.sh.
#
# WHY THIS FILE EXISTS: those two scripts differ only in which profile they
# point the run at — local uses your own, write seeds a throwaway one. Every
# other value is the same, and keeping two copies in step by hand failed
# twice. The second time, `run-write-e2e.sh` was left naming
# `lgs basecamp setup --inspector` after that flag had been dropped everywhere
# else, so following its own error message got you an unrecognised-flag error.
# Neither script runs in CI, so nothing caught it either time.
#
# Sourced, not executed: it sets variables the caller uses. The caller is
# expected to have run `set -eu` and to have defined:
#   root  - the repository root
#   label - a short name for messages, e.g. "local e2e"

# Keep in step with ui-tests.yml's SITOMETRES.
#
# A published release. This was pinned to a fork commit for the inspector-probe
# bug, which only ever affected the BUNDLE: the released probe looks for
# `bin/.LogosBasecamp`, and a nix dirBundler bundle ships
# `bin/.LogosBasecamp.elf`. The dev `#app` these scripts use ships the former,
# so a published version works again.
SITOMETRES="@paradoxcomputer/sitometres@0.1.2"

# The dev Basecamp — the QML inspector is ON in `#app` and off in the shipping
# bundles; see docs/e2e.md. Built to a local out-link rather than through
# `lgs basecamp setup`, which would also seed profiles and rewrite
# scaffold.toml.
basecamp_bin="$root/result-basecamp/bin/LogosBasecamp"
if [ ! -x "$basecamp_bin" ]; then
    echo "$label: no Basecamp at $basecamp_bin" >&2
    echo "        Build it first — the expensive one-time step:" >&2
    echo "          nix build \"github:logos-co/logos-basecamp/\$(tomlq -r '.repos.basecamp.pin' scaffold.toml)#app\" \\" >&2
    echo "            -o result-basecamp --accept-flake-config" >&2
    echo "        See docs/e2e.md." >&2
    exit 1
fi

# The DEV modules, matching the dev Basecamp. Mismatching the two halves gets
# you a UI that opens to nothing and a timeout on step 1 — see docs/e2e.md.
app_dir="$root/.scaffold/basecamp/lgx"
if [ ! -d "$app_dir" ]; then
    echo "$label: no dev build at $app_dir" >&2
    echo "        Run \`lgs basecamp build --variant lgx\` first." >&2
    exit 1
fi

# No --variant is passed by either caller: sitometres' hostVariant() default is
# `linux-amd64-dev`, which is exactly what `.#lgx` produces. Passing
# `--variant linux-amd64` here would BREAK the run rather than fix it — that
# flag belonged to the portable bundle.
