#!/usr/bin/env bats

# Tests for lib/clock.bash: microsecond Unix time, no forks.

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/clock.bash
    source "$SCRIPT_DIR/lib/clock.bash"
}

# --- clock_parse ---

@test "clock_parse: decimal point" {
    clock_parse 1786867629.967696
    [ "$CLOCK_PARSED_US" = "1786867629967696" ]
}

@test "clock_parse: decimal comma (locales that render one)" {
    clock_parse 1786867629,967696
    [ "$CLOCK_PARSED_US" = "1786867629967696" ]
}

@test "clock_parse: whole seconds with no fraction" {
    clock_parse 1786867629
    [ "$CLOCK_PARSED_US" = "1786867629000000" ]
}

@test "clock_parse: short fraction is scaled, not read as microseconds" {
    clock_parse 1786867629.5
    [ "$CLOCK_PARSED_US" = "1786867629500000" ]
}

@test "clock_parse: leading-zero fraction is not read as octal" {
    clock_parse 1786867629.098765
    [ "$CLOCK_PARSED_US" = "1786867629098765" ]
}

@test "clock_parse: over-long fraction is truncated to microseconds" {
    clock_parse 1786867629.9676969999
    [ "$CLOCK_PARSED_US" = "1786867629967696" ]
}

# --- clock_format ---

@test "clock_format: renders seconds and a six-digit fraction" {
    clock_format 1786867629967696
    [ "$CLOCK_TEXT" = "1786867629.967696" ]
}

@test "clock_format: pads a small fraction" {
    clock_format 1786867629000042
    [ "$CLOCK_TEXT" = "1786867629.000042" ]
}

@test "clock_format: round-trips through clock_parse" {
    clock_format 1786867629098765
    clock_parse "$CLOCK_TEXT"
    [ "$CLOCK_PARSED_US" = "1786867629098765" ]
}

# --- clock_read ---

@test "clock_read: sets a plausible microsecond timestamp" {
    clock_read
    # Later than 2020 and earlier than 2100, in microseconds.
    [ "$CLOCK_NOW_US" -gt 1577836800000000 ]
    [ "$CLOCK_NOW_US" -lt 4102444800000000 ]
}

@test "clock_read: has sub-second resolution" {
    local first second
    clock_read
    first=$CLOCK_NOW_US
    command sleep 0.05
    clock_read
    second=$CLOCK_NOW_US
    # A 50ms gap must be visible; whole-second reads would show 0 or 1000000.
    [ "$(( second - first ))" -gt 10000 ]
    [ "$(( second - first ))" -lt 1000000 ]
}

@test "clock_read: agrees with date to the second" {
    local from_date
    from_date=$(date -u +%s)
    clock_read
    [ "$(( CLOCK_NOW_US / 1000000 - from_date ))" -ge 0 ]
    [ "$(( CLOCK_NOW_US / 1000000 - from_date ))" -le 1 ]
}
