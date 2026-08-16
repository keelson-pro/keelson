#!/usr/bin/env bats

# Integration tests for the keelson-probe entry script.

setup() {
    TMP_DIR=$(mktemp -d)
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    PROBE="$SCRIPT_DIR/keelson-probe"
    export KEELSON_STATUS_DIR="$TMP_DIR/status"
    export KEELSON_HEARTBEAT_MAX_AGE=5
    mkdir -p "$KEELSON_STATUS_DIR"
    # Sourced only to build fixtures at the same precision the probe reads.
    # shellcheck source=../scripts/lib/clock.bash
    source "$SCRIPT_DIR/lib/clock.bash"
    HEARTBEAT_FILE="$KEELSON_STATUS_DIR/heartbeat"
    WATCHERS_FILE="$KEELSON_STATUS_DIR/watchers"
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_heartbeat() {
    printf 'heartbeat=%s\n' "$1" > "$HEARTBEAT_FILE"
}

write_watchers() {
    printf '%s\n' "$@" > "$WATCHERS_FILE"
}

now() { date -u +%s; }

# --- liveness ---

@test "liveness: missing heartbeat file fails" {
    run "$PROBE" liveness
    [ "$status" -eq 1 ]
}

@test "liveness: fresh heartbeat passes" {
    write_heartbeat "$(now)"
    run "$PROBE" liveness
    [ "$status" -eq 0 ]
}

@test "liveness: stale heartbeat fails" {
    write_heartbeat "$(( $(now) - 60 ))"
    run "$PROBE" liveness
    [ "$status" -eq 1 ]
}

@test "liveness: sub-second age is not rounded up to stale" {
    export KEELSON_HEARTBEAT_MAX_AGE=1
    clock_read
    clock_format "$(( CLOCK_NOW_US - 900000 ))"
    printf 'heartbeat=%s\n' "$CLOCK_TEXT" > "$HEARTBEAT_FILE"
    run "$PROBE" liveness
    [ "$status" -eq 0 ]
}

@test "liveness: age just past the limit is stale" {
    export KEELSON_HEARTBEAT_MAX_AGE=1
    clock_read
    clock_format "$(( CLOCK_NOW_US - 1100000 ))"
    printf 'heartbeat=%s\n' "$CLOCK_TEXT" > "$HEARTBEAT_FILE"
    run "$PROBE" liveness
    [ "$status" -eq 1 ]
}

@test "liveness: does not care about the watcher map" {
    write_heartbeat "$(now)"
    write_watchers "Deployment=0"
    run "$PROBE" liveness
    [ "$status" -eq 0 ]
}

# --- readiness ---

@test "readiness: missing watchers file fails" {
    run "$PROBE" readiness
    [ "$status" -eq 1 ]
}

@test "readiness: all live PIDs passes" {
    write_watchers "Deployment=$$"
    run "$PROBE" readiness
    [ "$status" -eq 0 ]
}

@test "readiness: dead PID fails" {
    ( exec true ) &
    local dead=$!
    wait "$dead" 2>/dev/null || true
    write_watchers "Deployment=$dead"
    run "$PROBE" readiness
    [ "$status" -eq 1 ]
}

@test "readiness: does not care about the heartbeat" {
    write_heartbeat "$(( $(now) - 600 ))"
    write_watchers "Deployment=$$"
    run "$PROBE" readiness
    [ "$status" -eq 0 ]
}

# --- startup ---

@test "startup: fresh + alive passes" {
    write_heartbeat "$(now)"
    write_watchers "Deployment=$$"
    run "$PROBE" startup
    [ "$status" -eq 0 ]
}

@test "startup: stale heartbeat fails even if PIDs alive" {
    write_heartbeat "$(( $(now) - 60 ))"
    write_watchers "Deployment=$$"
    run "$PROBE" startup
    [ "$status" -eq 1 ]
}

@test "startup: dead PID fails even if heartbeat fresh" {
    ( exec true ) &
    local dead=$!
    wait "$dead" 2>/dev/null || true
    write_heartbeat "$(now)"
    write_watchers "Deployment=$dead"
    run "$PROBE" startup
    [ "$status" -eq 1 ]
}

# --- the probe never writes the file trail ---
#
# It is a reader of the controller's state, not a writer of its log. The
# failure message reaches the operator as a kubelet event, and on a liveness
# kill the container restarts and takes the emptyDir with it, so the file
# would buy nothing while costing forks on the one path already closest to
# its exec timeout.

@test "liveness: a failure writes no log file" {
    export KEELSON_LOG_FILE_PATH="$TMP_DIR/keelson.log"
    run "$PROBE" liveness
    [ "$status" -eq 1 ]
    [ ! -e "$KEELSON_LOG_FILE_PATH" ]
}

@test "readiness: a failure writes no log file" {
    export KEELSON_LOG_FILE_PATH="$TMP_DIR/keelson.log"
    write_watchers "Deployment=0"
    run "$PROBE" readiness
    [ "$status" -eq 1 ]
    [ ! -e "$KEELSON_LOG_FILE_PATH" ]
}

@test "liveness: a failure does not append to an existing log file" {
    export KEELSON_LOG_FILE_PATH="$TMP_DIR/keelson.log"
    printf 'pre-existing\n' > "$KEELSON_LOG_FILE_PATH"
    run "$PROBE" liveness
    [ "$status" -eq 1 ]
    [ "$(cat "$KEELSON_LOG_FILE_PATH")" = "pre-existing" ]
}

@test "liveness: a failure still reports on stderr for the kubelet event" {
    run "$PROBE" liveness
    [ "$status" -eq 1 ]
    [[ "$output" == *"Liveness probe failed"* ]]
    [[ "$output" == *"ERROR"* ]]
}

@test "readiness: a failure still reports on stderr for the kubelet event" {
    write_watchers "Deployment=0"
    run "$PROBE" readiness
    [ "$status" -eq 1 ]
    [[ "$output" == *"Readiness probe failed"* ]]
}

# --- arg handling ---

@test "unknown subcommand exits 64" {
    write_heartbeat "$(now)"
    write_watchers "Deployment=$$"
    run "$PROBE" bogus
    [ "$status" -eq 64 ]
}

@test "--help prints usage" {
    run "$PROBE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"keelson-probe"* ]]
}
