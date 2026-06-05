# Controller loop: tick-driven heartbeat, supervised watchers, backgrounded scans.
# Sourced; not directly executable.
#
# Configuration (all required, validated at boot):
#   KEELSON_TICK_INTERVAL          seconds between supervisor ticks
#   KEELSON_POLL_INTERVAL          seconds between scan starts (measured from
#                                  scan start time; long scans queue the next
#                                  for the very next tick, never overlap)
#   KEELSON_FULL_REFRESH_INTERVAL  seconds between dedupe-cache refreshes
#   KEELSON_WATCHER_BACKOFF_MAX    cap on per-kind respawn delay (s)
#   KEELSON_WATCHER_HEALTHY_RESET  alive duration that clears a kind's failure count
#
# Test overrides:
#   KEELSON_LOOP_MAX_ITERATIONS    0 = forever (default); >0 for tests
#
# Globals owned by this file:
#   LOOP_WATCHER_PIDS[<kind>]      current watcher PID (0 if none)
#   LOOP_WATCHER_FAIL[<kind>]      consecutive failures since last healthy reset
#   LOOP_WATCHER_STARTED[<kind>]   unix-seconds the current watcher started
#   LOOP_WATCHER_ELIGIBLE[<kind>]  earliest unix-seconds we may respawn this kind
#   LOOP_SCAN_PID                  current scan child PID (0 if none)
#
# Depends on (must be sourced first):
#   lib/log.bash, lib/queue.bash, lib/state.bash, lib/scan.bash, lib/watch.bash,
#   lib/status.bash

declare -gA LOOP_WATCHER_PIDS=()
declare -gA LOOP_WATCHER_FAIL=()
declare -gA LOOP_WATCHER_STARTED=()
declare -gA LOOP_WATCHER_ELIGIBLE=()
LOOP_SCAN_PID=0

# loop_drain_queue
# Drains watcher-enqueued work items, logs each.
loop_drain_queue() {
    local count=0 line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        log_debug queue-item "$line"
        count=$(( count + 1 ))
    done < <(queue_drain)
    [ "$count" -gt 0 ] && log_info queue-drained count="$count"
    return 0
}

# loop_supervise_watchers <now> <backoff_max> <healthy_reset>
# Respawns dead watchers respecting per-kind exponential backoff. Resets the
# failure count for any watcher that has stayed alive past <healthy_reset>.
loop_supervise_watchers() {
    local now=$1 backoff_max=$2 healthy_reset=$3
    local kind pid started fails delay new_pid
    for kind in $KEELSON_WATCHED_KINDS; do
        pid=${LOOP_WATCHER_PIDS[$kind]:-0}
        if [ "$pid" -gt 0 ]; then
            if kill -0 "$pid" 2>/dev/null; then
                started=${LOOP_WATCHER_STARTED[$kind]:-$now}
                if [ "${LOOP_WATCHER_FAIL[$kind]:-0}" -gt 0 ] && \
                        [ $(( now - started )) -ge "$healthy_reset" ]; then
                    LOOP_WATCHER_FAIL[$kind]=0
                fi
                continue
            fi
            log_warn watcher-died kind="$kind" pid="$pid"
            fails=$(( ${LOOP_WATCHER_FAIL[$kind]:-0} + 1 ))
            LOOP_WATCHER_FAIL[$kind]=$fails
            delay=$(( 1 << (fails - 1) ))
            [ "$delay" -gt "$backoff_max" ] && delay=$backoff_max
            LOOP_WATCHER_ELIGIBLE[$kind]=$(( now + delay ))
            LOOP_WATCHER_PIDS[$kind]=0
        fi
        [ "$now" -lt "${LOOP_WATCHER_ELIGIBLE[$kind]:-0}" ] && continue
        watch_run_kind "$kind" &
        new_pid=$!
        LOOP_WATCHER_PIDS[$kind]=$new_pid
        LOOP_WATCHER_STARTED[$kind]=$now
        log_info watcher-spawned kind="$kind" pid="$new_pid" \
            fails="${LOOP_WATCHER_FAIL[$kind]:-0}"
    done
}

# loop_write_status <now>
# Refreshes the heartbeat + watcher PID map for keelson-probe.
loop_write_status() {
    local now=$1 kind args=()
    for kind in $KEELSON_WATCHED_KINDS; do
        args+=("${kind}=${LOOP_WATCHER_PIDS[$kind]:-0}")
    done
    status_write "$now" "${args[@]}"
}

# loop_start_scan <apply> <force_refresh>
# Spawns a scan child. The child owns the state lifecycle: it reloads from
# the ConfigMap, optionally wipes the cache to force dedupe re-emit, runs
# the scan, and flushes deltas back. Parent state is not mutated.
loop_start_scan() {
    local apply=$1 force_refresh=$2
    (
        state_load || log_warn state-reload-failed
        [ "$force_refresh" = "1" ] && state_clear_cache
        scan_run "$apply"
        [ "$apply" -eq 1 ] && { state_flush || true; }
    ) &
    LOOP_SCAN_PID=$!
}

# loop_kill_children
# Best-effort kill of every spawned child. Called from the shutdown trap.
loop_kill_children() {
    local kind pid
    for kind in "${!LOOP_WATCHER_PIDS[@]}"; do
        pid=${LOOP_WATCHER_PIDS[$kind]}
        [ "$pid" -gt 0 ] && kill "$pid" 2>/dev/null || true
    done
    [ "$LOOP_SCAN_PID" -gt 0 ] && kill "$LOOP_SCAN_PID" 2>/dev/null || true
}

# loop_run
# Tick once per KEELSON_TICK_INTERVAL: supervise watchers, drain queue,
# kick a backgrounded scan when due, refresh the status file. Long scans
# overlap ticks but never each other (gated on LOOP_SCAN_PID).
loop_run() {
    local tick=${KEELSON_TICK_INTERVAL:?KEELSON_TICK_INTERVAL required}
    local poll=${KEELSON_POLL_INTERVAL:?KEELSON_POLL_INTERVAL required}
    local full_refresh=${KEELSON_FULL_REFRESH_INTERVAL:?KEELSON_FULL_REFRESH_INTERVAL required}
    local backoff_max=${KEELSON_WATCHER_BACKOFF_MAX:?KEELSON_WATCHER_BACKOFF_MAX required}
    local healthy_reset=${KEELSON_WATCHER_HEALTHY_RESET:?KEELSON_WATCHER_HEALTHY_RESET required}
    local max_iter=${KEELSON_LOOP_MAX_ITERATIONS:-0}
    local apply=1
    [ "${KEELSON_DRY_RUN:-0}" = "1" ] && apply=0

    local now last_scan_start=0 last_refresh force_refresh_next=0 iter=0
    last_refresh=$(date -u +%s)

    while [ "$max_iter" -eq 0 ] || [ "$iter" -lt "$max_iter" ]; do
        now=$(date -u +%s)

        loop_supervise_watchers "$now" "$backoff_max" "$healthy_reset"
        loop_drain_queue

        if [ "$LOOP_SCAN_PID" -gt 0 ] && ! kill -0 "$LOOP_SCAN_PID" 2>/dev/null; then
            wait "$LOOP_SCAN_PID" 2>/dev/null || true
            LOOP_SCAN_PID=0
        fi
        if [ "$LOOP_SCAN_PID" -eq 0 ] && [ $(( now - last_scan_start )) -ge "$poll" ]; then
            loop_start_scan "$apply" "$force_refresh_next"
            last_scan_start=$now
            force_refresh_next=0
        fi

        if [ $(( now - last_refresh )) -ge "$full_refresh" ]; then
            log_info state-full-refresh elapsed=$(( now - last_refresh ))
            force_refresh_next=1
            last_refresh=$now
        fi

        loop_write_status "$now"

        sleep "$tick"
        iter=$(( iter + 1 ))
    done
}
