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

# --- clock_parse_duration ---
#
# poll-schedule is a per-workload cadence. A duration says what an operator
# means directly and, unlike cron, can express sub-minute intervals.

@test "parse_duration: bare seconds" {
    clock_parse_duration 45
    [ "$CLOCK_DURATION" = "45" ]
}

@test "parse_duration: seconds suffix" {
    clock_parse_duration 30s
    [ "$CLOCK_DURATION" = "30" ]
}

@test "parse_duration: minutes" {
    clock_parse_duration 5m
    [ "$CLOCK_DURATION" = "300" ]
}

@test "parse_duration: hours" {
    clock_parse_duration 2h
    [ "$CLOCK_DURATION" = "7200" ]
}

@test "parse_duration: days" {
    clock_parse_duration 1d
    [ "$CLOCK_DURATION" = "86400" ]
}

@test "parse_duration: uppercase suffix" {
    clock_parse_duration 5M
    [ "$CLOCK_DURATION" = "300" ]
}

@test "parse_duration: leading zeroes are not read as octal" {
    clock_parse_duration 010s
    [ "$CLOCK_DURATION" = "10" ]
}

@test "parse_duration: compound duration" {
    clock_parse_duration 2h45m
    [ "$CLOCK_DURATION" = "9900" ]
}

@test "parse_duration: fractional hours" {
    clock_parse_duration 1.5h
    [ "$CLOCK_DURATION" = "5400" ]
}

@test "parse_duration: fractional with two places" {
    clock_parse_duration 0.25h
    [ "$CLOCK_DURATION" = "900" ]
}

@test "parse_duration: fractional minutes" {
    clock_parse_duration 1.5m
    [ "$CLOCK_DURATION" = "90" ]
}

@test "parse_duration: rounds down below the half second" {
    clock_parse_duration 1.4s
    [ "$CLOCK_DURATION" = "1" ]
}

@test "parse_duration: rounds up at the half second" {
    clock_parse_duration 1.5s
    [ "$CLOCK_DURATION" = "2" ]
}

@test "parse_duration: rounds up from just under a second" {
    clock_parse_duration 900ms
    [ "$CLOCK_DURATION" = "1" ]
}

@test "parse_duration: sub-second units round into the total" {
    clock_parse_duration 1h500ms
    [ "$CLOCK_DURATION" = "3601" ]
}

@test "parse_duration: a sub-second-only duration rounds to zero" {
    # Not an error: the caller decides what "faster than I go" means.
    clock_parse_duration 300ms
    [ "$CLOCK_DURATION" = "0" ]
}

@test "parse_duration: zero parses as zero, for the caller to rule on" {
    clock_parse_duration "0"
    [ "$CLOCK_DURATION" = "0" ]
}

# --- Keel compatibility ---

@test "parse_duration: keel @every form" {
    clock_parse_duration "@every 10m"
    [ "$CLOCK_DURATION" = "600" ]
}

@test "parse_duration: @every with no space" {
    clock_parse_duration "@every5m"
    [ "$CLOCK_DURATION" = "300" ]
}

@test "parse_duration: @every with a compound duration" {
    clock_parse_duration "@every 1h30m10s"
    [ "$CLOCK_DURATION" = "5410" ]
}

@test "parse_duration: predefined @hourly" {
    clock_parse_duration "@hourly"
    [ "$CLOCK_DURATION" = "3600" ]
}

@test "parse_duration: predefined @daily" {
    clock_parse_duration "@daily"
    [ "$CLOCK_DURATION" = "86400" ]
}

@test "parse_duration: predefined @weekly" {
    clock_parse_duration "@weekly"
    [ "$CLOCK_DURATION" = "604800" ]
}

@test "parse_duration: @monthly is rejected as calendar-based" {
    run clock_parse_duration "@monthly"
    [ "$status" -eq 1 ]
}

@test "parse_duration: a raw cron expression is rejected" {
    run clock_parse_duration "0 */6 * * *"
    [ "$status" -eq 1 ]
}

@test "parse_duration: empty is rejected" {
    run clock_parse_duration ""
    [ "$status" -eq 1 ]
}

@test "parse_duration: rubbish is rejected" {
    run clock_parse_duration "soon"
    [ "$status" -eq 1 ]
}

@test "parse_duration: a negative value is rejected" {
    run clock_parse_duration "-5m"
    [ "$status" -eq 1 ]
}

@test "parse_duration: a trailing unit with no number is rejected" {
    run clock_parse_duration "h"
    [ "$status" -eq 1 ]
}

@test "parse_duration: an unknown unit is rejected" {
    run clock_parse_duration "5w"
    [ "$status" -eq 1 ]
}
