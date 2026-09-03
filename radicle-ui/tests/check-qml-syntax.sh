#!/usr/bin/env sh
# Compile every QML file, so a syntax error cannot reach a package.
#
# qmllint does NOT catch an unbalanced brace — it reported "lint ok" on a file
# that Qt then refused with "Unexpected token `}'". Basecamp logs that failure
# nowhere the user can see: the app simply does nothing when clicked. So this
# compiles each file for real.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
qml_dir="$here/../src/qml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# qmlformat parses the file and exits non-zero on a syntax error. qmlcachegen
# would also work but insists on a resource path, and qmllint does NOT catch
# this class at all.
compiler=""
for cand in qmlformat6 /usr/lib64/qt6/bin/qmlformat \
            /usr/lib/qt6/bin/qmlformat \
            /usr/lib/x86_64-linux-gnu/qt6/bin/qmlformat qmlformat; do
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then compiler="$cand"; break; fi
done

status=0

if [ -n "$compiler" ]; then
    for f in "$qml_dir"/*.qml; do
        if ! out=$("$compiler" "$f" 2>&1 >/dev/null); then
            echo "::error file=$f::QML syntax error"
            echo "$out"
            status=1
        fi
    done
    [ "$status" -eq 0 ] && echo "ok: all QML files parse ($compiler)"
else
    echo "no qmlformat found; falling back to a brace-balance check" >&2
fi

# Cheap structural check that needs no Qt at all, and catches exactly the
# failure above. Runs regardless, as a second opinion.
for f in "$qml_dir"/*.qml; do
    [ -e "$f" ] || continue
    python3 - "$f" <<'PY' || status=1
import sys, re
path = sys.argv[1]
src = open(path).read()
# Strip strings and comments so braces inside them do not count.
src = re.sub(r'//[^\n]*', '', src)
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
src = re.sub(r'"(?:[^"\\]|\\.)*"', '""', src)
src = re.sub(r"'(?:[^'\\]|\\.)*'", "''", src)
depth = 0
for lineno, line in enumerate(src.split("\n"), 1):
    depth += line.count("{") - line.count("}")
    if depth < 0:
        print(f"::error file={path},line={lineno}::unbalanced '}}' — more closing than opening braces")
        raise SystemExit(1)
if depth != 0:
    print(f"::error file={path}::unbalanced braces — {depth} unclosed '{{'")
    raise SystemExit(1)
PY
done

[ "$status" -eq 0 ] && echo "ok: braces balanced in all QML files"
exit "$status"
