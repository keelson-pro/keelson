#!/usr/bin/env bats

# Tests for lib/loop.bash. The supervisor + tick scheduler are exercised
# with shimmed sleep + date and a stubbed watch_run_kind that spawns a
# short-lived background sleeper. Scan is also stubbed.

load helper

setup() {
    tmp_dir_init
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    KEELSON_WATCHED_KINDS=Deployment
    KEELSON_TICK_INTERVAL=1
    KEELSON_RECONCILE_INTERVAL=60
    KEELSON_FULL_REFRESH_INTERVAL=3600
    KEELSON_WATCHER_RESPAWN_BACKOFF_MAX=300
    KEELSON_WATCHER_RESPAWN_HEALTHY_RESET=30
    export PATH TMP_DIR KEELSON_WATCHED_KINDS \
        KEELSON_TICK_INTERVAL KEELSON_RECONCILE_INTERVAL KEELSON_FULL_REFRESH_INTERVAL \
        KEELSON_WATCHER_RESPAWN_BACKOFF_MAX KEELSON_WATCHER_RESPAWN_HEALTHY_RESET

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/clock.bash
    source "$SCRIPT_DIR/lib/clock.bash"
    # shellcheck source=../scripts/lib/queue.bash
    source "$SCRIPT_DIR/lib/queue.bash"
    # shellcheck source=../scripts/lib/status.bash
    source "$SCRIPT_DIR/lib/status.bash"
    # shellcheck source=../scripts/lib/state.bash
    source "$SCRIPT_DIR/lib/state.bash"
    # shellcheck source=../scripts/lib/loop.bash
    source "$SCRIPT_DIR/lib/loop.bash"

    KEELSON_QUEUE_DIR="$TMP_DIR/queue"
    KEELSON_STATUS_DIR="$TMP_DIR/status"
    HEARTBEAT_FILE="$KEELSON_STATUS_DIR/heartbeat"
    WATCHERS_FILE="$KEELSON_STATUS_DIR/watchers"
    queue_init

    # Stub the heavy collaborators.
    scan_run() { printf '%s\n' "$1" >>"$TMP_DIR/scan.calls"; }
    scan_poll_due() { printf '%s\n' "$2" >>"$TMP_DIR/poll.calls"; }
    scan_refresh_kind() { printf '%s\n' "$2" >>"$TMP_DIR/refresh.calls"; }
    scan_refresh_queued() { printf '%s\n' "$1" >>"$TMP_DIR/queue.calls"; }
    inventory_evict_unwatched() { printf 'evict-unwatched\n' >>"$TMP_DIR/refresh.calls"; }
    state_reconcile_ledger() { printf 'reconcile-ledger\n' >>"$TMP_DIR/refresh.calls"; }
    state_flush() { printf 'flush\n' >>"$TMP_DIR/state.calls"; }
    state_clear_cache() { printf 'clear\n' >>"$TMP_DIR/state.calls"; }
    state_load() { printf 'load\n' >>"$TMP_DIR/state.calls"; }
    watch_run_kind() { sleep 10; }

    sleep() { :; }
}

teardown() {
    local kind pid
    for kind in "${!LOOP_WATCHER_PIDS[@]}"; do
        pid=${LOOP_WATCHER_PIDS[$kind]:-0}
        # Tests use $$ as a stand-in for "alive PID"; never kill the test runner.
        if [ "$pid" -gt 0 ] && [ "$pid" -ne "$$" ] && [ "$pid" -ne "$BASHPID" ]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    LOOP_WATCHER_PIDS=()
    LOOP_WATCHER_FAIL=()
    LOOP_WATCHER_STARTED=()
    LOOP_WATCHER_ELIGIBLE=()
    LOOP_SCAN_PID=0
    LOOP_QUEUE_PID=0
    LOOP_REFRESH_PID=0
    LOOP_REFRESH_PENDING=()
}

emit() { "$@" 2>&1; }

# --- loop_start_queue_refresh ---

@test "queue refresh: the child loads and flushes state" {
    loop_start_queue_refresh 1
    wait "$LOOP_QUEUE_PID"
    grep -q "load" "$TMP_DIR/state.calls"
    grep -q "flush" "$TMP_DIR/state.calls"
}

@test "queue refresh: dry-run passes apply=0 and does not flush" {
    loop_start_queue_refresh 0
    wait "$LOOP_QUEUE_PID" || true
    [ "$(cat "$TMP_DIR/queue.calls")" = "0" ]
    [ ! -f "$TMP_DIR/state.calls" ] || ! grep -q "flush" "$TMP_DIR/state.calls"
}

# --- loop_supervise_watchers ---

@test "supervisor: spawns initial watcher when none exists" {
    loop_supervise_watchers 100 300 30
    [ "${LOOP_WATCHER_PIDS[Deployment]}" -gt 0 ]
    [ "${LOOP_WATCHER_STARTED[Deployment]}" = "100" ]
    [ "${LOOP_WATCHER_FAIL[Deployment]:-0}" = "0" ]
}

@test "supervisor: alive watcher past healthy_reset clears fail count" {
    LOOP_WATCHER_PIDS[Deployment]=$$  # current shell PID, definitely alive
    LOOP_WATCHER_STARTED[Deployment]=0
    LOOP_WATCHER_FAIL[Deployment]=3
    loop_supervise_watchers 100 300 30
    [ "${LOOP_WATCHER_FAIL[Deployment]}" = "0" ]
}

@test "supervisor: alive watcher inside healthy_reset window keeps fail count" {
    LOOP_WATCHER_PIDS[Deployment]=$$
    LOOP_WATCHER_STARTED[Deployment]=90
    LOOP_WATCHER_FAIL[Deployment]=2
    loop_supervise_watchers 100 300 30
    [ "${LOOP_WATCHER_FAIL[Deployment]}" = "2" ]
}

@test "supervisor: dead watcher increments fail count and sets eligible" {
    # Spawn then kill a real child to get a dead PID.
    sleep() { command sleep "$@"; }
    ( exec sleep 0.01 ) &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true
    LOOP_WATCHER_PIDS[Deployment]=$dead_pid
    LOOP_WATCHER_STARTED[Deployment]=0
    LOOP_WATCHER_FAIL[Deployment]=0
    sleep() { :; }

    loop_supervise_watchers 100 300 30
    [ "${LOOP_WATCHER_FAIL[Deployment]}" = "1" ]
    # 1 << (1-1) = 1; eligible = 100 + 1
    [ "${LOOP_WATCHER_ELIGIBLE[Deployment]}" = "101" ]
}

@test "supervisor: respawn waits until eligible time" {
    LOOP_WATCHER_PIDS[Deployment]=0
    LOOP_WATCHER_ELIGIBLE[Deployment]=200
    loop_supervise_watchers 100 300 30
    # Still pid=0 because 100 < 200
    [ "${LOOP_WATCHER_PIDS[Deployment]}" = "0" ]
}

@test "supervisor: backoff caps at backoff_max" {
    LOOP_WATCHER_PIDS[Deployment]=0
    LOOP_WATCHER_FAIL[Deployment]=20  # 2^19 way above any reasonable cap
    LOOP_WATCHER_ELIGIBLE[Deployment]=0
    # Spawn then kill to simulate a dead PID we just noticed.
    sleep() { command sleep "$@"; }
    ( exec sleep 0.01 ) &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true
    LOOP_WATCHER_PIDS[Deployment]=$dead_pid
    sleep() { :; }

    loop_supervise_watchers 100 50 30
    [ "$(( LOOP_WATCHER_ELIGIBLE[Deployment] - 100 ))" = "50" ]
}

# --- loop_publish_watchers ---

@test "publish_watchers: one line per kind" {
    LOOP_WATCHER_PIDS[Deployment]=42
    KEELSON_WATCHED_KINDS=Deployment loop_publish_watchers
    [ -f "$WATCHERS_FILE" ]
    grep -q '^Deployment=42$' "$WATCHERS_FILE"
}

@test "publish_watchers: missing kind PID is written as 0" {
    KEELSON_WATCHED_KINDS="Deployment CronJob" loop_publish_watchers
    grep -q '^CronJob=0$' "$WATCHERS_FILE"
}

@test "publish_watchers: does not write the heartbeat" {
    LOOP_WATCHER_PIDS[Deployment]=42
    loop_publish_watchers
    [ ! -e "$HEARTBEAT_FILE" ]
}

# --- the supervisor publishes its own map, when it changes ---

@test "supervisor: publishes the map when it spawns a watcher" {
    loop_supervise_watchers 100 300 30
    [ -f "$WATCHERS_FILE" ]
    grep -q "^Deployment=${LOOP_WATCHER_PIDS[Deployment]}\$" "$WATCHERS_FILE"
}

@test "supervisor: republishes the map as soon as a watcher dies" {
    sleep() { command sleep "$@"; }
    ( exec sleep 0.01 ) &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true
    sleep() { :; }

    LOOP_WATCHER_PIDS[Deployment]=$dead_pid
    loop_publish_watchers
    grep -q "^Deployment=$dead_pid\$" "$WATCHERS_FILE"

    # Death noticed at now=100, respawn deferred to 101, so the published
    # map must drop the dead PID on this very tick rather than carry it.
    loop_supervise_watchers 100 300 30
    grep -q '^Deployment=0$' "$WATCHERS_FILE"
}

@test "supervisor: does not rewrite the map when nothing changed" {
    LOOP_WATCHER_PIDS[Deployment]=$$
    LOOP_WATCHER_STARTED[Deployment]=100
    loop_publish_watchers
    rm -f "$WATCHERS_FILE"

    loop_supervise_watchers 100 300 30
    [ ! -e "$WATCHERS_FILE" ]
}

@test "supervisor: returns success when nothing changed" {
    LOOP_WATCHER_PIDS[Deployment]=$$
    LOOP_WATCHER_STARTED[Deployment]=100
    run loop_supervise_watchers 100 300 30
    [ "$status" -eq 0 ]
}

# --- loop_run scheduling ---

@test "loop_run: triggers scan on first tick" {
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    # last_scan_start starts at 0, now-0 >= 60 → scan fires
    [ -f "$TMP_DIR/scan.calls" ]
    [ "$(cat "$TMP_DIR/scan.calls")" = "1" ]
}

@test "loop_run: dry-run passes apply=0 to scan" {
    KEELSON_DRY_RUN=1 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$(cat "$TMP_DIR/scan.calls")" = "0" ]
}

@test "loop_run: writes the heartbeat each tick" {
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ -f "$HEARTBEAT_FILE" ]
    grep -q '^heartbeat=' "$HEARTBEAT_FILE"
}

@test "loop_run: first tick publishes the watcher map too" {
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ -f "$WATCHERS_FILE" ]
    grep -q "^Deployment=${LOOP_WATCHER_PIDS[Deployment]}\$" "$WATCHERS_FILE"
}

# --- log rotation ownership ---

@test "loop_run: rotates the log file when it is oversize" {
    KEELSON_LOG_FILE_PATH="$TMP_DIR/keelson.log"
    KEELSON_LOG_FILE_MAX_BYTES=10
    KEELSON_LOG_FILE_KEEP=3
    printf 'XXXXXXXXXXXXXXXXXXXX\n' > "$KEELSON_LOG_FILE_PATH"
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ -f "$KEELSON_LOG_FILE_PATH.1" ]
    grep -q "XXXX" "$KEELSON_LOG_FILE_PATH.1"
}

@test "loop_run: leaves an under-size log file alone" {
    KEELSON_LOG_FILE_PATH="$TMP_DIR/keelson.log"
    KEELSON_LOG_FILE_MAX_BYTES=100000
    printf 'small\n' > "$KEELSON_LOG_FILE_PATH"
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ ! -f "$KEELSON_LOG_FILE_PATH.1" ]
}

# --- heartbeat publication point ---

@test "loop_run: publishes the heartbeat before the tick's work" {
    # The stamp must be readable by a probe that fires while the tick is
    # still working, not only after the work is done.
    # The supervisor is the first synchronous work after the stamp is
    # written, so it stands in for "the tick's work" here.
    loop_supervise_watchers() {
        [ -f "$HEARTBEAT_FILE" ] && : > "$TMP_DIR/heartbeat-was-first"
        return 0
    }
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ -f "$TMP_DIR/heartbeat-was-first" ]
}

@test "loop_run: the stamp is the moment it was published" {
    local before after stamp
    clock_read
    before=$CLOCK_NOW_US
    loop_supervise_watchers() { command sleep 2; return 0; }
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    clock_read
    after=$CLOCK_NOW_US
    clock_parse "$(sed -n 's/^heartbeat=//p' "$HEARTBEAT_FILE")"
    stamp=$CLOCK_PARSED_US
    # Published before the 2s of work, so the stamp cannot have absorbed it.
    [ "$stamp" -ge "$before" ]
    [ "$(( after - stamp ))" -ge 2000000 ]
}

@test "loop_run: the stamp keeps its sub-second precision" {
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    # A whole-second stamp would end in six zeroes; one in a million odds
    # of a false pass, against a certain failure if precision is dropped.
    ! grep -q '^heartbeat=[0-9]*\.000000$' "$HEARTBEAT_FILE"
    grep -q '^heartbeat=[0-9]\{10,\}\.[0-9]\{6\}$' "$HEARTBEAT_FILE"
}

# --- cycle time ---

@test "loop_run: sleeps the tick remainder, not the whole tick" {
    # watch_run_kind's stub sleeps too; keep it off the real sleep stub.
    watch_run_kind() { command sleep 10; }
    sleep() { printf '%s\n' "$1" >>"$TMP_DIR/sleeps"; }
    loop_supervise_watchers() { command sleep 0.4; return 0; }
    KEELSON_TICK_INTERVAL=1 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    # ~0.6s left of the 1s cycle: definitely less than a full tick.
    awk '{ exit ($1 < 0.9 && $1 > 0.2) ? 0 : 1 }' "$TMP_DIR/sleeps"
}

@test "loop_run: a fast tick still sleeps nearly the whole tick" {
    # watch_run_kind's stub sleeps too; keep it off the real sleep stub.
    watch_run_kind() { command sleep 10; }
    sleep() { printf '%s\n' "$1" >>"$TMP_DIR/sleeps"; }
    KEELSON_TICK_INTERVAL=1 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    awk '{ exit ($1 > 0.9 && $1 <= 1) ? 0 : 1 }' "$TMP_DIR/sleeps"
}

@test "loop_run: sub-second work does not read as an overrun" {
    # Integer-second arithmetic would call this a 1s tick whenever the
    # second happened to roll over mid-work, and skip the sleep entirely.
    # watch_run_kind's stub sleeps too; keep it off the real sleep stub.
    watch_run_kind() { command sleep 10; }
    sleep() { printf '%s\n' "$1" >>"$TMP_DIR/sleeps"; }
    loop_supervise_watchers() { command sleep 0.3; return 0; }
    KEELSON_TICK_INTERVAL=1 KEELSON_LOOP_MAX_ITERATIONS=3 run emit loop_run
    [ "$status" -eq 0 ]
    [[ "$output" != *"longer than the"* ]]
    [ "$(wc -l <"$TMP_DIR/sleeps")" -eq 3 ]
}

@test "loop_run: overrunning tick does not sleep and warns" {
    # watch_run_kind's stub sleeps too; keep it off the real sleep stub.
    watch_run_kind() { command sleep 10; }
    sleep() { printf '%s\n' "$1" >>"$TMP_DIR/sleeps"; }
    loop_supervise_watchers() { command sleep 1.3; return 0; }
    KEELSON_TICK_INTERVAL=1 KEELSON_LOOP_MAX_ITERATIONS=1 run emit loop_run
    [ "$status" -eq 0 ]
    [ ! -f "$TMP_DIR/sleeps" ]
    [[ "$output" == *"longer than the 1s tick interval"* ]]
}

# --- the tick drives the due poll ---

@test "loop_run: asks what is due every tick" {
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$LOOP_POLL_PID" -gt 0 ] && wait "$LOOP_POLL_PID" 2>/dev/null || true
    [ -f "$TMP_DIR/poll.calls" ]
}

@test "loop_run: the poll child loads and flushes state" {
    # It is a subshell, so anything it records (a CronJob trigger, a new
    # next-due) is lost unless it flushes, and without loading first the
    # trigger gate reads empty and re-fires a Job that already ran.
    rm -f "$TMP_DIR/state.calls"
    scan_run() { :; }
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$LOOP_POLL_PID" -gt 0 ] && wait "$LOOP_POLL_PID" 2>/dev/null || true
    grep -q load "$TMP_DIR/state.calls"
    grep -q flush "$TMP_DIR/state.calls"
}

@test "loop_run: the poll is passed the tick's own clock" {
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$LOOP_POLL_PID" -gt 0 ] && wait "$LOOP_POLL_PID" 2>/dev/null || true
    clock_read
    local passed
    passed=$(head -n 1 "$TMP_DIR/poll.calls")
    [ "$passed" -gt 0 ]
    [ "$passed" -le "$(( CLOCK_NOW_US / 1000000 ))" ]
}

# --- full refresh, one kind per tick ---
#
# A refresh lists the cluster kind by kind. Doing all of them in one pass is
# the long-running thing the tick exists to avoid, so the queue is drained a
# kind at a time.
#
# The queue is seeded directly in most of these: last_refresh starts at now,
# and with sleep stubbed out no wall-clock time passes, so the interval can
# never elapse inside a test.

@test "full refresh: nothing is queued before the interval elapses" {
    KEELSON_FULL_REFRESH_INTERVAL=999999 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "${#LOOP_REFRESH_PENDING[@]}" -eq 0 ]
    [ ! -f "$TMP_DIR/refresh.calls" ]
}

@test "full refresh: an elapsed interval queues every watched kind" {
    KEELSON_WATCHED_KINDS="Deployment CronJob"
    # 0 is not a legal config value; it is the only way to make the interval
    # elapse on the first tick without waiting.
    KEELSON_FULL_REFRESH_INTERVAL=0 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$LOOP_REFRESH_PID" -gt 0 ] && wait "$LOOP_REFRESH_PID" 2>/dev/null || true
    # Two queued, one taken on that same tick.
    [ "${#LOOP_REFRESH_PENDING[@]}" -eq 1 ]
}

@test "full refresh: takes one kind per tick" {
    LOOP_REFRESH_PENDING=(Deployment CronJob)
    KEELSON_FULL_REFRESH_INTERVAL=999999 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$LOOP_REFRESH_PID" -gt 0 ] && wait "$LOOP_REFRESH_PID" 2>/dev/null || true
    [ "$(wc -l <"$TMP_DIR/refresh.calls" | tr -d ' ')" = "1" ]
    [ "${#LOOP_REFRESH_PENDING[@]}" -eq 1 ]
}

@test "full refresh: drains the queue over successive ticks" {
    LOOP_REFRESH_PENDING=(Deployment CronJob)
    KEELSON_FULL_REFRESH_INTERVAL=999999 KEELSON_LOOP_MAX_ITERATIONS=2 loop_run
    [ "$LOOP_REFRESH_PID" -gt 0 ] && wait "$LOOP_REFRESH_PID" 2>/dev/null || true
    grep -q Deployment "$TMP_DIR/refresh.calls"
    grep -q CronJob "$TMP_DIR/refresh.calls"
    [ "${#LOOP_REFRESH_PENDING[@]}" -eq 0 ]
}

@test "full refresh: only the last kind reconciles the ledger" {
    # The cache is only whole again once every kind has been rebuilt, so
    # anything comparing the ledger against it has to wait for the last one.
    LOOP_REFRESH_PENDING=(Deployment CronJob)
    KEELSON_FULL_REFRESH_INTERVAL=999999 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$LOOP_REFRESH_PID" -gt 0 ] && wait "$LOOP_REFRESH_PID" 2>/dev/null || true
    ! grep -q reconcile-ledger "$TMP_DIR/refresh.calls"

    KEELSON_FULL_REFRESH_INTERVAL=999999 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$LOOP_REFRESH_PID" -gt 0 ] && wait "$LOOP_REFRESH_PID" 2>/dev/null || true
    grep -q evict-unwatched "$TMP_DIR/refresh.calls"
    grep -q reconcile-ledger "$TMP_DIR/refresh.calls"
}

@test "full refresh: a cycle in flight is not queued again" {
    LOOP_REFRESH_PENDING=(Deployment CronJob StatefulSet)
    KEELSON_FULL_REFRESH_INTERVAL=0 KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ "$LOOP_REFRESH_PID" -gt 0 ] && wait "$LOOP_REFRESH_PID" 2>/dev/null || true
    # Still draining the original three, not re-seeded from the watched set.
    [ "${#LOOP_REFRESH_PENDING[@]}" -eq 2 ]
}

@test "loop_run: an empty queue spawns no refresh child" {
    # The child reads the ledger before it can find the queue empty, so
    # spawning it for nothing costs an API call every tick.
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ ! -f "$TMP_DIR/queue.calls" ]
}

@test "loop_run: a queued identity spawns the refresh child" {
    queue_enqueue Deployment default app
    KEELSON_LOOP_MAX_ITERATIONS=1 loop_run
    [ -f "$TMP_DIR/queue.calls" ]
}
