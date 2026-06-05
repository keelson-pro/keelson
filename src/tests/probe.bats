#!/usr/bin/env bats

# Integration tests for the keelson-probe entry script.

setup() {
    TMP_DIR=$(mktemp -d)
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    PROBE="$SCRIPT_DIR/keelson-probe"
    export KEELSON_STATUS_FILE="$TMP_DIR/status"
    export KEELSON_HEARTBEAT_MAX_AGE=5
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_status() {
    local heartbeat=$1; shift
    {
        printf 'heartbeat=%s\n' "$heartbeat"
        local e
        for e in "$@"; do printf '%s\n' "$e"; done
    } > "$KEELSON_STATUS_FILE"
}

now() { date -u +%s; }

# --- liveness ---

@test "liveness: missing status file fails" {
    rm -f "$KEELSON_STATUS_FILE"
    run "$PROBE" liveness
    [ "$status" -eq 1 ]
}

@test "liveness: fresh heartbeat passes" {
    write_status "$(now)"
    run "$PROBE" liveness
    [ "$status" -eq 0 ]
}

@test "liveness: stale heartbeat fails" {
    write_status "$(( $(now) - 60 ))"
    run "$PROBE" liveness
    [ "$status" -eq 1 ]
}

# --- readiness ---

@test "readiness: missing status file fails" {
    rm -f "$KEELSON_STATUS_FILE"
    run "$PROBE" readiness
    [ "$status" -eq 1 ]
}

@test "readiness: all live PIDs passes" {
    write_status 0 "Deployment=$$"
    run "$PROBE" readiness
    [ "$status" -eq 0 ]
}

@test "readiness: dead PID fails" {
    ( exec true ) &
    local dead=$!
    wait "$dead" 2>/dev/null || true
    write_status 0 "Deployment=$dead"
    run "$PROBE" readiness
    [ "$status" -eq 1 ]
}

# --- startup ---

@test "startup: fresh + alive passes" {
    write_status "$(now)" "Deployment=$$"
    run "$PROBE" startup
    [ "$status" -eq 0 ]
}

@test "startup: stale heartbeat fails even if PIDs alive" {
    write_status "$(( $(now) - 60 ))" "Deployment=$$"
    run "$PROBE" startup
    [ "$status" -eq 1 ]
}

@test "startup: dead PID fails even if heartbeat fresh" {
    ( exec true ) &
    local dead=$!
    wait "$dead" 2>/dev/null || true
    write_status "$(now)" "Deployment=$dead"
    run "$PROBE" startup
    [ "$status" -eq 1 ]
}

# --- arg handling ---

@test "unknown subcommand exits 64" {
    write_status "$(now)" "Deployment=$$"
    run "$PROBE" bogus
    [ "$status" -eq 64 ]
}

@test "--help prints usage" {
    run "$PROBE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"keelson-probe"* ]]
}
