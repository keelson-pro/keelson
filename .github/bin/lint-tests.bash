#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# Blocks bats assertions that can never fail, whatever bash runs them.
#
#   ! <cmd>             anywhere but the last line of a test. bash exempts a
#                       negated command from set -e, and bats only sees the
#                       status of the last one, so mid-test it checks nothing.
#   ! <cmd> || true     anywhere. Passes whatever <cmd> does.
#
# "! <cmd> || false" is fine anywhere: the false is what set -e sees.
# Heredoc bodies (the shims) are skipped, they are not test code.
#
# Lints src/tests/*.bats, or the files given. Runs from any CWD: resolves
# the repo root from this script's location.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [ $# -eq 0 ]; then
    set -- src/tests/*.bats
fi

awk '
function flag(file, line, text, why) {
    sub(/^[ \t]+/, "", text)
    printf "%s:%d: %s\n    %s\n", file, line, why, text
    bad++
}
FNR == 1 { in_test = 0; tag = ""; pending = 0 }
tag != "" {
    t = $0
    sub(/^[ \t]+/, "", t)
    if (t == tag) tag = ""
    next
}
/^@test / { in_test = 1; pending = 0; next }
in_test && /^}[ \t]*$/ { in_test = 0; pending = 0; next }
!in_test { next }
/^[ \t]*$/ || /^[ \t]*#/ { next }
{
    if (pending) {
        flag(FILENAME, pending_line, pending_text, "negated command is not the last line of its test, so it asserts nothing; use: if <cmd>; then false; fi")
        pending = 0
    }
    if ($0 ~ /^[ \t]*! / && $0 ~ /\|\|[ \t]*true[ \t]*$/) {
        flag(FILENAME, FNR, $0, "\"! <cmd> || true\" passes whatever <cmd> does")
    } else if ($0 ~ /^[ \t]*! / && $0 !~ /\|\|[ \t]*false[ \t]*$/) {
        pending = 1; pending_line = FNR; pending_text = $0
    }
    if (match($0, /<<-?[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
        tag = substr($0, RSTART, RLENGTH)
        sub(/^<<-?/, "", tag)
        gsub(/[\047"]/, "", tag)
    }
}
END {
    if (bad) {
        printf "%d assertion(s) that can never fail\n", bad
        exit 1
    }
}
' "$@"
