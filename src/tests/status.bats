#!/usr/bin/env bats

# Tests for lib/status.bash: the heartbeat and watcher-PID state files.

setup() {
    TMP_DIR=$(mktemp -d)
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/status.bash
    source "$SCRIPT_DIR/lib/status.bash"
    KEELSON_STATUS_DIR="$TMP_DIR/status"
    HEARTBEAT_FILE="$KEELSON_STATUS_DIR/heartbeat"
    WATCHERS_FILE="$KEELSON_STATUS_DIR/watchers"
}

teardown() {
    rm -rf "$TMP_DIR"
}

emit() { "$@" 2>&1; }

# --- status_write_heartbeat ---

@test "write_heartbeat: creates the directory and writes the stamp" {
    status_write_heartbeat 100
    grep -q '^heartbeat=100$' "$HEARTBEAT_FILE"
}

@test "write_heartbeat: overwrites the previous stamp" {
    status_write_heartbeat 100
    status_write_heartbeat 200
    grep -q '^heartbeat=200$' "$HEARTBEAT_FILE"
    ! grep -q '^heartbeat=100$' "$HEARTBEAT_FILE"
}

@test "write_heartbeat: leaves no temp file behind" {
    status_write_heartbeat 100
    [ ! -e "${HEARTBEAT_FILE}.tmp" ]
}

# --- status_write_watchers ---

@test "write_watchers: one line per entry" {
    status_write_watchers Deployment=11 CronJob=22
    grep -q '^Deployment=11$' "$WATCHERS_FILE"
    grep -q '^CronJob=22$' "$WATCHERS_FILE"
}

@test "write_watchers: overwrites the previous map" {
    status_write_watchers Deployment=11
    status_write_watchers Deployment=99
    grep -q '^Deployment=99$' "$WATCHERS_FILE"
    ! grep -q '^Deployment=11$' "$WATCHERS_FILE"
}

# --- the two files are independent ---

@test "the writers do not touch each other's file" {
    status_write_heartbeat 100
    status_write_watchers Deployment=11
    grep -q '^heartbeat=100$' "$HEARTBEAT_FILE"
    ! grep -q 'Deployment' "$HEARTBEAT_FILE"
    ! grep -q 'heartbeat' "$WATCHERS_FILE"
}

@test "write_watchers alone does not create a heartbeat file" {
    status_write_watchers Deployment=11
    [ ! -e "$HEARTBEAT_FILE" ]
}

@test "write_heartbeat alone does not create a watchers file" {
    status_write_heartbeat 100
    [ ! -e "$WATCHERS_FILE" ]
}

# --- readers ---

@test "read_heartbeat: missing file returns 1" {
    run status_read_heartbeat
    [ "$status" -eq 1 ]
}

@test "read_heartbeat: populates STATUS_HEARTBEAT" {
    status_write_heartbeat 555
    status_read_heartbeat
    [ "$STATUS_HEARTBEAT" = "555" ]
}

@test "read_watchers: missing file returns 1" {
    run status_read_watchers
    [ "$status" -eq 1 ]
}

@test "read_watchers: populates STATUS_PIDS" {
    status_write_watchers Deployment=11 CronJob=22
    status_read_watchers
    [ "${STATUS_PIDS[Deployment]}" = "11" ]
    [ "${STATUS_PIDS[CronJob]}" = "22" ]
}

@test "read_watchers: succeeds on a file it has already read once" {
    status_write_watchers Deployment=11
    status_read_watchers
    run status_read_watchers
    [ "$status" -eq 0 ]
}

# --- status_heartbeat_fresh ---

@test "heartbeat_fresh: missing file fails" {
    run status_heartbeat_fresh 5
    [ "$status" -eq 1 ]
}

@test "heartbeat_fresh: recent heartbeat passes" {
    status_write_heartbeat "$(date -u +%s)"
    run status_heartbeat_fresh 5
    [ "$status" -eq 0 ]
}

@test "heartbeat_fresh: stale heartbeat fails" {
    status_write_heartbeat "$(( $(date -u +%s) - 100 ))"
    run status_heartbeat_fresh 5
    [ "$status" -eq 1 ]
}

@test "heartbeat_fresh: ignores the watchers file entirely" {
    status_write_watchers Deployment=0
    status_write_heartbeat "$(date -u +%s)"
    run status_heartbeat_fresh 5
    [ "$status" -eq 0 ]
}

# --- status_all_watchers_alive ---

@test "all_watchers_alive: missing file fails" {
    run status_all_watchers_alive
    [ "$status" -eq 1 ]
}

@test "all_watchers_alive: no entries fails" {
    status_write_watchers
    run status_all_watchers_alive
    [ "$status" -eq 1 ]
}

@test "all_watchers_alive: pid 0 fails" {
    status_write_watchers Deployment=0
    run status_all_watchers_alive
    [ "$status" -eq 1 ]
}

@test "all_watchers_alive: all live PIDs pass" {
    status_write_watchers self=$$
    run status_all_watchers_alive
    [ "$status" -eq 0 ]
}

@test "all_watchers_alive: any dead PID fails" {
    ( exec true ) &
    local dead=$!
    wait "$dead" 2>/dev/null || true
    status_write_watchers Deployment=$$ CronJob="$dead"
    run status_all_watchers_alive
    [ "$status" -eq 1 ]
}

@test "all_watchers_alive: ignores the heartbeat file entirely" {
    status_write_heartbeat "$(( $(date -u +%s) - 100 ))"
    status_write_watchers self=$$
    run status_all_watchers_alive
    [ "$status" -eq 0 ]
}
