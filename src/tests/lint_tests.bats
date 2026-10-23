#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# The test lint (.github/bin/lint-tests.bash) on fixture files: each finding
# where it belongs, and nothing on code that is fine. The fixtures are
# .bats.in, so neither bats nor the lint's own scan takes them for tests.

setup() {
    LINT="${BATS_TEST_DIRNAME}/../../.github/bin/lint-tests.bash"
    FIXTURES="${BATS_TEST_DIRNAME}/fixtures/lint"
}

@test "lint: each line that can never fail is flagged where it is" {
    run "$LINT" "$FIXTURES/bad.bats.in"
    [ "$status" -eq 1 ]
    local want
    for want in \
        "5: return 0 before the end of a test" \
        "10: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "15: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "20: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "25: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "30: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "35: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "40: an assertion followed by || true" \
        "45: an assertion followed by || true" \
        "51: a test sent to the background with &" \
        "56: a test before && is not the last line of its test" \
        "62: an assertion followed by || true" \
        "68: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "73: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "78: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "83: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "88: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "94: an assertion followed by || true" \
        "102: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "107: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "112: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "120: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "127: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "137: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "146: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "151: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "157: exit 0 (or a bare exit, or exit \$?) before the end of a test" \
        "163: exit 0 (or a bare exit, or exit \$?) before the end of a test"; do
        [[ "$output" == *"bad.bats.in:$want"* ]] || { echo "missing $want in: $output"; return 1; }
    done
    [[ "$output" == *$'\n28 assertion(s) that can never fail' ]]
}

@test "lint: a quoted string open at the next test is reported there, and that test linted" {
    run "$LINT" "$FIXTURES/unclosed.bats.in"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unclosed.bats.in:6: a quoted string opened here never closes"* ]]
    [[ "$output" == *"unclosed.bats.in:11: an assertion followed by || true"* ]]
    [[ "$output" == *$'\n2 assertion(s) that can never fail' ]]
}

@test "lint: a quoted string open at the end of the file is reported where it opened" {
    run "$LINT" "$FIXTURES/unclosed-eof.bats.in"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unclosed-eof.bats.in:5: a quoted string opened here never closes"* ]]
    [[ "$output" == *$'\n1 assertion(s) that can never fail' ]]
}

@test "lint: heredocs, child scripts, subshells, local functions and cleanup are not flagged" {
    run "$LINT" "$FIXTURES/clean.bats.in"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
