#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# Tests for lib/status.bash: the heartbeat and watcher-PID state files.

load helper

setup() {
    tmp_dir_init
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/clock.bash
    source "$SCRIPT_DIR/lib/clock.bash"
    # shellcheck source=../scripts/lib/status.bash
    source "$SCRIPT_DIR/lib/status.bash"
    KEELSON_STATUS_DIR="$TMP_DIR/status"
    HEARTBEAT_FILE="$KEELSON_STATUS_DIR/heartbeat"
    WATCHERS_FILE="$KEELSON_STATUS_DIR/watchers"
}

emit() { "$@" 2>&1; }

# --- status_write_heartbeat ---
#
# The stamp is microseconds in, decimal seconds on disk: a reader sees an
# obvious Unix timestamp, and nothing is rounded away in either direction.

@test "write_heartbeat: writes the stamp at full precision" {
    status_write_heartbeat 1786867629967696
    grep -q '^heartbeat=1786867629\.967696$' "$HEARTBEAT_FILE"
}

@test "write_heartbeat: does not truncate the fraction" {
    status_write_heartbeat 1786867629000042
    grep -q '^heartbeat=1786867629\.000042$' "$HEARTBEAT_FILE"
}

@test "write_heartbeat: overwrites the previous stamp" {
    status_write_heartbeat 100000000
    status_write_heartbeat 200000000
    grep -q '^heartbeat=200\.000000$' "$HEARTBEAT_FILE"
    ! grep -q '^heartbeat=100\.000000$' "$HEARTBEAT_FILE"
}

@test "write_heartbeat: leaves no temp file behind" {
    status_write_heartbeat 100000000
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
    status_write_heartbeat 100000000
    status_write_watchers Deployment=11
    grep -q '^heartbeat=100\.000000$' "$HEARTBEAT_FILE"
    ! grep -q 'Deployment' "$HEARTBEAT_FILE"
    ! grep -q 'heartbeat' "$WATCHERS_FILE"
}

@test "write_watchers alone does not create a heartbeat file" {
    status_write_watchers Deployment=11
    [ ! -e "$HEARTBEAT_FILE" ]
}

@test "write_heartbeat alone does not create a watchers file" {
    status_write_heartbeat 100000000
    [ ! -e "$WATCHERS_FILE" ]
}

# --- readers ---

@test "read_heartbeat: missing file returns 1" {
    run status_read_heartbeat
    [ "$status" -eq 1 ]
}

@test "read_heartbeat: populates STATUS_HEARTBEAT_US in microseconds" {
    status_write_heartbeat 1786867629967696
    status_read_heartbeat
    [ "$STATUS_HEARTBEAT_US" = "1786867629967696" ]
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
    clock_read
    status_write_heartbeat "$CLOCK_NOW_US"
    run status_heartbeat_fresh 5
    [ "$status" -eq 0 ]
}

@test "heartbeat_fresh: stale heartbeat fails" {
    clock_read
    status_write_heartbeat "$(( CLOCK_NOW_US - 100000000 ))"
    run status_heartbeat_fresh 5
    [ "$status" -eq 1 ]
}

@test "heartbeat_fresh: sub-second age is not rounded up to stale" {
    # Whole-second arithmetic reads a 0.9s age as 1s whenever a second
    # boundary falls in the gap, which is most of the time.
    clock_read
    status_write_heartbeat "$(( CLOCK_NOW_US - 900000 ))"
    run status_heartbeat_fresh 1
    [ "$status" -eq 0 ]
}

@test "heartbeat_fresh: age just past the limit is stale" {
    clock_read
    status_write_heartbeat "$(( CLOCK_NOW_US - 1100000 ))"
    run status_heartbeat_fresh 1
    [ "$status" -eq 1 ]
}

@test "heartbeat_fresh: ignores the watchers file entirely" {
    clock_read
    status_write_watchers Deployment=0
    status_write_heartbeat "$CLOCK_NOW_US"
    run status_heartbeat_fresh 5
    [ "$status" -eq 0 ]
}

# --- watcher health, published per kind by the watcher itself ---

@test "write_watcher_health: one file per kind" {
    status_write_watcher_health Deployment 0 ""
    status_write_watcher_health CronJob 3 "forbidden"
    grep -q '^failures=0$' "$KEELSON_STATUS_DIR/watcher-Deployment"
    grep -q '^failures=3$' "$KEELSON_STATUS_DIR/watcher-CronJob"
    grep -q '^error=forbidden$' "$KEELSON_STATUS_DIR/watcher-CronJob"
}

@test "write_watcher_health: error text is flattened to one line" {
    status_write_watcher_health CronJob 1 "$(printf 'line one\nline two')"
    [ "$(grep -c . "$KEELSON_STATUS_DIR/watcher-CronJob")" = "2" ]
    grep -q '^error=line one line two$' "$KEELSON_STATUS_DIR/watcher-CronJob"
}

@test "read_watcher_health: missing file returns 1" {
    run status_read_watcher_health Deployment
    [ "$status" -eq 1 ]
}

@test "read_watcher_health: populates the failure count" {
    status_write_watcher_health Deployment 4 "boom"
    status_read_watcher_health Deployment
    [ "$STATUS_WATCHER_FAILURES" = "4" ]
    [ "$STATUS_WATCHER_ERROR" = "boom" ]
}

# --- status_all_watchers_streaming ---

@test "all_watchers_streaming: missing watcher map fails" {
    run status_all_watchers_streaming
    [ "$status" -eq 1 ]
}

@test "all_watchers_streaming: every kind at zero failures passes" {
    status_write_watchers Deployment=$$ CronJob=$$
    status_write_watcher_health Deployment 0 ""
    status_write_watcher_health CronJob 0 ""
    run status_all_watchers_streaming
    [ "$status" -eq 0 ]
}

@test "all_watchers_streaming: one failing kind fails the lot" {
    status_write_watchers Deployment=$$ CronJob=$$
    status_write_watcher_health Deployment 0 ""
    status_write_watcher_health CronJob 2 "forbidden"
    run status_all_watchers_streaming
    [ "$status" -eq 1 ]
}

@test "all_watchers_streaming: a kind with no health file yet fails" {
    status_write_watchers Deployment=$$ CronJob=$$
    status_write_watcher_health Deployment 0 ""
    run status_all_watchers_streaming
    [ "$status" -eq 1 ]
}

@test "all_watchers_streaming: an alive PID does not excuse a failing stream" {
    # The whole point: liveness of the process says nothing about the watch.
    status_write_watchers Deployment=$$
    status_write_watcher_health Deployment 5 "forbidden"
    status_all_watchers_alive
    run status_all_watchers_streaming
    [ "$status" -eq 1 ]
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
    clock_read
    status_write_heartbeat "$(( CLOCK_NOW_US - 100000000 ))"
    status_write_watchers self=$$
    run status_all_watchers_alive
    [ "$status" -eq 0 ]
}
