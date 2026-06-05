#!/usr/bin/env bats

# Tests for lib/status.bash: heartbeat + watcher-PID state file.

setup() {
    TMP_DIR=$(mktemp -d)
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/status.bash
    source "$SCRIPT_DIR/lib/status.bash"
    KEELSON_STATUS_FILE="$TMP_DIR/status"
}

teardown() {
    rm -rf "$TMP_DIR"
}

emit() { "$@" 2>&1; }

# --- status_write ---

@test "status_write: writes heartbeat and entries to the file" {
    status_write 100 Deployment=11 CronJob=22
    grep -q '^heartbeat=100$' "$KEELSON_STATUS_FILE"
    grep -q '^Deployment=11$' "$KEELSON_STATUS_FILE"
    grep -q '^CronJob=22$' "$KEELSON_STATUS_FILE"
}

@test "status_write: overwrites existing file atomically" {
    status_write 100 Deployment=11
    status_write 200 Deployment=99
    grep -q '^heartbeat=200$' "$KEELSON_STATUS_FILE"
    grep -q '^Deployment=99$' "$KEELSON_STATUS_FILE"
    ! grep -q '^heartbeat=100$' "$KEELSON_STATUS_FILE"
}

@test "status_write: heartbeat alone is valid" {
    status_write 42
    grep -q '^heartbeat=42$' "$KEELSON_STATUS_FILE"
}

# --- status_read ---

@test "status_read: missing file returns 1" {
    run status_read
    [ "$status" -eq 1 ]
}

@test "status_read: populates globals from file" {
    status_write 555 Deployment=11 CronJob=22
    status_read
    [ "$STATUS_HEARTBEAT" = "555" ]
    [ "${STATUS_PIDS[Deployment]}" = "11" ]
    [ "${STATUS_PIDS[CronJob]}" = "22" ]
}

# --- status_heartbeat_fresh ---

@test "heartbeat_fresh: missing file fails" {
    run status_heartbeat_fresh 5
    [ "$status" -eq 1 ]
}

@test "heartbeat_fresh: recent heartbeat passes" {
    local now
    now=$(date -u +%s)
    status_write "$now"
    run status_heartbeat_fresh 5
    [ "$status" -eq 0 ]
}

@test "heartbeat_fresh: stale heartbeat fails" {
    local now
    now=$(date -u +%s)
    status_write "$(( now - 100 ))"
    run status_heartbeat_fresh 5
    [ "$status" -eq 1 ]
}

# --- status_all_watchers_alive ---

@test "all_watchers_alive: missing file fails" {
    run status_all_watchers_alive
    [ "$status" -eq 1 ]
}

@test "all_watchers_alive: no kind entries fails" {
    status_write 100
    run status_all_watchers_alive
    [ "$status" -eq 1 ]
}

@test "all_watchers_alive: pid 0 fails" {
    status_write 100 Deployment=0
    run status_all_watchers_alive
    [ "$status" -eq 1 ]
}

@test "all_watchers_alive: all live PIDs pass" {
    status_write 100 self=$$
    run status_all_watchers_alive
    [ "$status" -eq 0 ]
}

@test "all_watchers_alive: any dead PID fails" {
    ( exec true ) &
    local dead=$!
    wait "$dead" 2>/dev/null || true
    status_write 100 Deployment=$$ CronJob="$dead"
    run status_all_watchers_alive
    [ "$status" -eq 1 ]
}
