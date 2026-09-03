#!/usr/bin/env sh
# Run the QML component tests.
#
# Finding the right runner matters: a `qmltestrunner` on PATH may well be the
# Qt5 one (Fedora's qt5-qtdeclarative-devel ships it as /usr/bin/qmltestrunner),
# and it fails against Qt6 QML with an empty error and a bare exit 1 — which
# reads exactly like "the tests are broken". So prefer an explicitly Qt6 binary
# and fall back to a bare `qmltestrunner` only after proving it can run a
# trivial test.
#
# Set REQUIRE_QML_TESTS=1 (CI does) to fail rather than skip when no usable
# runner is found. Skipping quietly in CI is a false green: the job passes
# while testing nothing.
set -eu

# Headless by default, set once here rather than prefixed onto every
# invocation: the tests never need a display, and a caller should not have to
# remember the variable.
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"

here=$(cd "$(dirname "$0")" && pwd)
qml_dir="$here/../src/qml"
require=${REQUIRE_QML_TESTS:-0}

find_runner() {
    # An explicit override wins.
    if [ -n "${QMLTESTRUNNER:-}" ]; then
        printf '%s\n' "$QMLTESTRUNNER"
        return 0
    fi
    # Qt6-specific names and locations first.
    for cand in qmltestrunner6 \
                /usr/lib64/qt6/bin/qmltestrunner \
                /usr/lib/qt6/bin/qmltestrunner \
                /usr/lib/x86_64-linux-gnu/qt6/bin/qmltestrunner; do
        if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    # Ambiguous fallback — verified below before use.
    if command -v qmltestrunner >/dev/null 2>&1; then
        printf '%s\n' qmltestrunner
        return 0
    fi
    return 1
}

no_runner() {
    if [ "$require" = "1" ]; then
        echo "qml tests: $1" >&2
        echo "           REQUIRE_QML_TESTS=1, so this is a failure rather than a skip." >&2
        exit 1
    fi
    echo "qml tests: $1 — skipping" >&2
    exit 0
}

runner=$(find_runner) || no_runner "no qmltestrunner found"

# Prove the runner works at all before trusting a pass or a failure from it.
smoke=$(mktemp -d)
trap 'rm -rf "$smoke"' EXIT
cat > "$smoke/tst_smoke.qml" <<'SMOKE'
import QtQuick
import QtTest
TestCase { name: "Smoke"; function test_ok() { compare(1 + 1, 2); } }
SMOKE

if ! "$runner" -input "$smoke/tst_smoke.qml" >/dev/null 2>&1; then
    no_runner "$runner cannot run even a trivial test (wrong Qt major version?)"
fi

echo "qml tests: using $runner"
# Every tst_*.qml in this directory, so a new test file is picked up without
# editing this script.
status=0
for spec in "$here"/tst_*.qml; do
    echo "--- $(basename "$spec")"
    "$runner" -input "$spec" -import "$qml_dir" || status=1
done
exit "$status"
