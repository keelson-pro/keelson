#!/usr/bin/env bats

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "${SCRIPT_DIR}/lib/log.bash"
    unset KEELSON_LOG_FORMAT KEELSON_LOG_LEVEL
}

# Logs are emitted on stderr; merge to stdout so `run` captures them.
emit() { "$@" 2>&1; }

@test "log_info plain: emits level, event, and k=v fields" {
    run emit log_info scan-summary kind=Deployment count=3
    [ "$status" -eq 0 ]
    [[ "$output" =~ INFO ]]
    [[ "$output" =~ scan-summary ]]
    [[ "$output" =~ kind=Deployment ]]
    [[ "$output" =~ count=3 ]]
}

@test "log_info json: emits valid JSON-shape line with quoted fields" {
    KEELSON_LOG_FORMAT=json run emit log_info scan-summary kind=Deployment count=3
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"level\":\"INFO\" ]]
    [[ "$output" =~ \"event\":\"scan-summary\" ]]
    [[ "$output" =~ \"kind\":\"Deployment\" ]]
    [[ "$output" =~ \"count\":\"3\" ]]
}

@test "log_debug: hidden at default (info) level" {
    run emit log_debug some-event k=v
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "log_debug: visible at debug level" {
    KEELSON_LOG_LEVEL=debug run emit log_debug some-event k=v
    [ "$status" -eq 0 ]
    [[ "$output" =~ DEBUG ]]
}

@test "log_info: hidden at warn level" {
    KEELSON_LOG_LEVEL=warn run emit log_info some-event
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "log_error: visible at error level" {
    KEELSON_LOG_LEVEL=error run emit log_error oh-no k=v
    [ "$status" -eq 0 ]
    [[ "$output" =~ ERROR ]]
}

@test "log_info: timestamp prefix is ISO8601 UTC" {
    run emit log_info boot
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z[[:space:]] ]]
}

@test "log_info json: JSON escapes embedded quotes" {
    KEELSON_LOG_FORMAT=json run emit log_info evt note='say "hi"'
    [ "$status" -eq 0 ]
    # The emitted JSON contains: "note":"say \"hi\""
    [[ "$output" == *'"note":"say \"hi\""'* ]]
}

@test "log_info: emits to stderr, not stdout" {
    output=$(log_info evt 2>/dev/null)
    [ -z "$output" ]
}
