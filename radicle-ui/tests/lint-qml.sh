#!/usr/bin/env sh
# Run qmllint over the QML sources and fail on the warnings that are real.
#
# This exists because the CI step it replaces was a no-op for its whole life.
# It ran `qmllint6 … || qmllint … || true` against a runner where neither
# binary exists, so `$out` held two "command not found" lines, the grep for
# "error" matched nothing, and the step reported green while linting zero
# files. A gate that passes while measuring nothing is worse than no gate: it
# is a green tick that a reviewer believes.
#
# What it missed, concretely: `flow.startNode:` was left in Main.qml assigning
# to a property deliberately deleted from SetupFlow.qml. qmllint names that
# exact file, line and column in two minutes. Instead every one of the six e2e
# specs failed at "the app opens", ten minutes each, because the QML would not
# compile.
#
# Set REQUIRE_QML_LINT=1 (CI does) to fail rather than skip when no qmllint is
# found, matching run-qml-tests.sh's REQUIRE_QML_TESTS. Skipping quietly in CI
# is how this gate died the first time.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
qml_dir="$here/../src/qml"
require=${REQUIRE_QML_LINT:-0}

# Same resolution shape as check-qml-syntax.sh's qmlformat lookup, because
# qmllint is not on PATH on either distro this runs on:
#
#   Fedora  qt6-qtdeclarative-devel   -> /usr/lib64/qt6/bin/qmllint
#   Debian/Ubuntu qt6-declarative-dev-tools -> /usr/lib/qt6/bin/qmllint
#
# Note there is NO multiarch-triplet path for Qt6. The
# /usr/lib/x86_64-linux-gnu/qt*/bin form exists only for Qt5
# (qtdeclarative5-dev-tools), so listing it here would be a candidate that can
# never match. The Qt5 binary must not be found anyway: it fails on Qt6 QML the
# same way the Qt5 qmltestrunner does, which run-qml-tests.sh documents.
#
# No apt package needs adding for this: qt6-declarative-dev-tools is already
# installed by ci.yml's "Install Qt" step and ships qmllint beside the
# qmlformat that check-qml-syntax.sh uses. (Same story on Fedora, where
# `rpm -qf` puts both in qt6-qtdeclarative-devel.)
linter=""
for cand in qmllint6 /usr/lib64/qt6/bin/qmllint \
            /usr/lib/qt6/bin/qmllint qmllint; do
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then linter="$cand"; break; fi
done

if [ -z "$linter" ]; then
    if [ "$require" = "1" ]; then
        echo "qmllint: no qmllint binary found" >&2
        echo "         REQUIRE_QML_LINT=1, so this is a failure rather than a skip." >&2
        echo "         Debian/Ubuntu: qt6-declarative-dev-tools (/usr/lib/qt6/bin)." >&2
        echo "         Fedora:        qt6-qtdeclarative-devel (/usr/lib64/qt6/bin)." >&2
        exit 1
    fi
    echo "qmllint: no qmllint binary found — skipping" >&2
    exit 0
fi

echo "qmllint: using $linter"
# qmllint exits non-zero on warnings, and this repo has warnings it does not
# intend to fix (see below), so its exit code cannot be the verdict. The
# output is.
out=$("$linter" -I "$qml_dir" "$qml_dir"/*.qml 2>&1 || true)
printf '%s\n' "$out"

status=0

# Errors always fail. Nothing in the tree emits one today; it is the category
# that means qmllint could not even analyse the file.
if printf '%s\n' "$out" | grep -qE '^Error:'; then
    echo "::error::qmllint reported errors"
    status=1
fi

# `Could not find property "X".` — an assignment to a property the target type
# does not declare. This is the one that broke the app, and it is always a real
# defect: the property is named literally at the assignment site, so qmllint
# resolved the type and the name genuinely is not on it.
#
# It is NOT the same check as failing on the whole [missing-property] category,
# which would be red on arrival. That category carries a second, far more
# common message — `Member "X" not found on type "QQuickItem"` — emitted when a
# delegate reaches `modelData` / `selected` / `hovered` on an untyped
# `delegate:` or `contentItem:`. qmllint cannot infer a delegate's real type,
# so every one of those is a false positive, and there are dozens. Counted at
# the commit that added this script: 34 of that form, 1 of the form below.
#
# So the discriminator is the message, not the category. Both forms are tagged
# [missing-property]; only this one means something is wrong.
if printf '%s\n' "$out" | grep -q 'Could not find property'; then
    echo "::error::qmllint found an assignment to a non-existent property"
    echo "  This breaks the app at load time: Basecamp refuses the whole file"
    echo "  and the UI opens to nothing. Remove the assignment, or declare the"
    echo "  property on the target type."
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "ok: qmllint found no errors and no non-existent-property assignments"
fi
exit "$status"
