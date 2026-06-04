#!/usr/bin/env bats

# Tests for lib/loop.bash. The loop calls scan_run; we shim scan_run to a
# trace function so the test asserts on call count and arg without
# bringing in the whole scan dependency chain.

setup() {
    TMP_DIR=$(mktemp -d)
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    export PATH TMP_DIR

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/queue.bash
    source "$SCRIPT_DIR/lib/queue.bash"
    # shellcheck source=../scripts/lib/state.bash
    source "$SCRIPT_DIR/lib/state.bash"
    # shellcheck source=../scripts/lib/loop.bash
    source "$SCRIPT_DIR/lib/loop.bash"

    KEELSON_QUEUE_DIR="$TMP_DIR/queue"
    KEELSON_READY_FILE="$TMP_DIR/ready"

    queue_init

    # scan_run is heavy and brings in registry/skopeo etc. Replace it with
    # a trace function that records each call's apply flag.
    scan_run() {
        printf '%s\n' "$1" >>"$TMP_DIR/scan.calls"
    }

    # Trace state lifecycle without needing a real ConfigMap.
    state_flush() {
        printf 'flush\n' >>"$TMP_DIR/state.calls"
    }
    state_clear_cache() {
        printf 'clear\n' >>"$TMP_DIR/state.calls"
    }
    state_load() {
        printf 'load\n' >>"$TMP_DIR/state.calls"
    }

    # Avoid real delays; sleep with the loop interval would block tests.
    sleep() { :; }
}

teardown() {
    rm -rf "$TMP_DIR"
}

emit() { "$@" 2>&1; }

# --- loop_mark_ready ---

@test "loop_mark_ready: creates the ready file" {
    loop_mark_ready
    [ -f "$KEELSON_READY_FILE" ]
}

@test "loop_mark_ready: creates parent directory if missing" {
    KEELSON_READY_FILE="$TMP_DIR/nested/path/ready" loop_mark_ready
    [ -f "$TMP_DIR/nested/path/ready" ]
}

@test "loop_mark_ready: logs the ready event" {
    run emit loop_mark_ready
    [[ "$output" == *"ready"* ]]
    [[ "$output" == *"file=$KEELSON_READY_FILE"* ]]
}

# --- loop_drain_queue ---

@test "loop_drain_queue: empty queue logs count=0" {
    run emit loop_drain_queue
    [ "$status" -eq 0 ]
    [[ "$output" == *"queue-drained count=0"* ]]
}

@test "loop_drain_queue: drains existing entries and reports count" {
    queue_enqueue Deployment default app
    queue_enqueue CronJob ns2 cron
    run emit loop_drain_queue
    [ "$status" -eq 0 ]
    [[ "$output" == *"queue-drained count=2"* ]]
    [ "$(queue_size)" = "0" ]
}

# --- loop_run ---

@test "loop_run: calls scan_run with apply=1 by default" {
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$(cat "$TMP_DIR/scan.calls")" = "1" ]
}

@test "loop_run: KEELSON_DRY_RUN=1 forces apply=0" {
    KEELSON_DRY_RUN=1 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$(cat "$TMP_DIR/scan.calls")" = "0" ]
}

@test "loop_run: iterates KEELSON_LOOP_MAX_ITERATIONS times" {
    KEELSON_LOOP_MAX_ITERATIONS=3 loop_run
    [ "$(wc -l <"$TMP_DIR/scan.calls" | tr -d ' ')" = "3" ]
}

@test "loop_run: drains queue before each scan" {
    queue_enqueue Deployment default app
    KEELSON_LOOP_MAX_ITERATIONS=1 run emit loop_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"queue-drained count=1"* ]]
    [ "$(queue_size)" = "0" ]
}

# --- state flush + full-refresh ---

@test "loop_run apply: state_flush is called once per iteration" {
    KEELSON_LOOP_MAX_ITERATIONS=3 loop_run
    [ "$(grep -c '^flush$' "$TMP_DIR/state.calls")" = "3" ]
}

@test "loop_run dry-run: state_flush is NOT called" {
    KEELSON_DRY_RUN=1 KEELSON_LOOP_MAX_ITERATIONS=3 loop_run
    [ ! -f "$TMP_DIR/state.calls" ] || ! grep -q '^flush$' "$TMP_DIR/state.calls"
}

@test "loop_run apply: full-refresh tick clears cache and reloads" {
    # Force every iteration to count as a refresh tick.
    KEELSON_FULL_REFRESH_INTERVAL=0 KEELSON_LOOP_MAX_ITERATIONS=2 \
        run emit loop_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"state-full-refresh"* ]]
    [ "$(grep -c '^clear$' "$TMP_DIR/state.calls")" = "2" ]
    [ "$(grep -c '^load$' "$TMP_DIR/state.calls")" = "2" ]
}

@test "loop_run: long full-refresh interval keeps cache across iterations" {
    KEELSON_FULL_REFRESH_INTERVAL=3600 KEELSON_LOOP_MAX_ITERATIONS=3 loop_run
    [ ! -f "$TMP_DIR/state.calls" ] || ! grep -q '^clear$' "$TMP_DIR/state.calls"
}
