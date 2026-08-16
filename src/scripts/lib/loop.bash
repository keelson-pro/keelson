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
#   lib/log.bash, lib/clock.bash, lib/queue.bash, lib/state.bash, lib/scan.bash,
#   lib/watch.bash, lib/status.bash

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
    [ "$count" -gt 0 ] && log_debug queue-drained count="$count"
    return 0
}

# loop_publish_watchers
# Publishes the current PID map for keelson-probe's readiness check.
loop_publish_watchers() {
    local kind args=()
    for kind in $KEELSON_WATCHED_KINDS; do
        args+=("${kind}=${LOOP_WATCHER_PIDS[$kind]:-0}")
    done
    status_write_watchers "${args[@]}"
}

# loop_supervise_watchers <now> <backoff_max> <healthy_reset>
# Respawns dead watchers respecting per-kind exponential backoff. Resets the
# failure count for any watcher that has stayed alive past <healthy_reset>.
#
# The supervisor owns LOOP_WATCHER_PIDS, so the supervisor publishes it, and
# it publishes the moment the map changes rather than leaving a stale map on
# disk until the end of the tick. Nothing changed means nothing written: the
# map moves on a death or a respawn, not on a schedule.
loop_supervise_watchers() {
    local now=$1 backoff_max=$2 healthy_reset=$3
    local kind pid started fails delay new_pid changed=0
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
            log_warn watcher-died kind="$kind" pid="$pid" \
                msg="Watcher for kind '$kind' died (pid $pid)."
            fails=$(( ${LOOP_WATCHER_FAIL[$kind]:-0} + 1 ))
            LOOP_WATCHER_FAIL[$kind]=$fails
            delay=$(( 1 << (fails - 1) ))
            [ "$delay" -gt "$backoff_max" ] && delay=$backoff_max
            LOOP_WATCHER_ELIGIBLE[$kind]=$(( now + delay ))
            LOOP_WATCHER_PIDS[$kind]=0
            changed=1
        fi
        [ "$now" -lt "${LOOP_WATCHER_ELIGIBLE[$kind]:-0}" ] && continue
        watch_run_kind "$kind" &
        new_pid=$!
        LOOP_WATCHER_PIDS[$kind]=$new_pid
        LOOP_WATCHER_STARTED[$kind]=$now
        changed=1
        fails=${LOOP_WATCHER_FAIL[$kind]:-0}
        if [ "$fails" -eq 0 ]; then
            log_info_always watcher-spawned kind="$kind" pid="$new_pid" fails="$fails" \
                msg="Watcher for kind '$kind' started (pid $new_pid)."
        else
            log_warn watcher-respawned kind="$kind" pid="$new_pid" fails="$fails" \
                msg="Watcher for kind '$kind' respawned (pid $new_pid, fail count $fails)."
        fi
    done
    [ "$changed" -eq 1 ] && loop_publish_watchers
    return 0
}

# loop_start_scan <apply> <force_refresh>
# Spawns a scan child. The child owns the state lifecycle: it reloads from
# the ConfigMap, optionally wipes the cache to force dedupe re-emit, runs
# the scan, and flushes deltas back. Parent state is not mutated.
loop_start_scan() {
    local apply=$1 force_refresh=$2
    (
        state_load || log_warn state-reload-failed \
            configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
            msg="State reload from ConfigMap '$STATE_CONFIGMAP_NAME' in '$STATE_NAMESPACE' failed."
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
# Tick once per KEELSON_TICK_INTERVAL: publish the heartbeat, supervise
# watchers, drain queue, kick a backgrounded scan when due. The watcher map
# is published by the supervisor itself, not from here. Long scans overlap
# ticks but never each other (gated on LOOP_SCAN_PID).
#
# Two properties the ordering here exists to hold:
#
#   The heartbeat is read and written in the same breath, at the top, so the
#   value on disk is the moment it was published. Nothing in the tick can age
#   it before a probe reads it, and the file can never claim a time the loop
#   was not at.
#
#   KEELSON_TICK_INTERVAL is the cycle time, not the idle time. The sleep is
#   the tick minus the work already done, so ticks start on a fixed cadence
#   instead of drifting by however long the last one took. Work that outruns
#   the tick gets no sleep and a warning: the next tick starts immediately,
#   and the cadence is reported as broken rather than silently stretched.
loop_run() {
    local tick=${KEELSON_TICK_INTERVAL:?KEELSON_TICK_INTERVAL required}
    local poll=${KEELSON_POLL_INTERVAL:?KEELSON_POLL_INTERVAL required}
    local full_refresh=${KEELSON_FULL_REFRESH_INTERVAL:?KEELSON_FULL_REFRESH_INTERVAL required}
    local backoff_max=${KEELSON_WATCHER_BACKOFF_MAX:?KEELSON_WATCHER_BACKOFF_MAX required}
    local healthy_reset=${KEELSON_WATCHER_HEALTHY_RESET:?KEELSON_WATCHER_HEALTHY_RESET required}
    local max_iter=${KEELSON_LOOP_MAX_ITERATIONS:-0}
    local apply=1
    [ "${KEELSON_DRY_RUN:-0}" = "1" ] && apply=0

    local tick_us=$(( tick * 1000000 ))
    local now cycle_start_us remaining_us over_us over
    local last_scan_start=0 last_refresh force_refresh_next=0 iter=0
    clock_read
    last_refresh=$(( CLOCK_NOW_US / 1000000 ))

    while [ "$max_iter" -eq 0 ] || [ "$iter" -lt "$max_iter" ]; do
        clock_read
        cycle_start_us=$CLOCK_NOW_US
        now=$(( cycle_start_us / 1000000 ))
        status_write_heartbeat "$cycle_start_us"

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
            local elapsed=$(( now - last_refresh ))
            log_debug state-full-refresh elapsed="$elapsed" \
                msg="State full refresh due (${elapsed}s elapsed), proceeding to refresh..."
            force_refresh_next=1
            last_refresh=$now
        fi

        clock_read
        remaining_us=$(( tick_us - (CLOCK_NOW_US - cycle_start_us) ))
        if [ "$remaining_us" -gt 0 ]; then
            clock_format "$remaining_us"
            sleep "$CLOCK_TEXT"
        else
            over_us=$(( CLOCK_NOW_US - cycle_start_us ))
            clock_format "$over_us"
            over=$CLOCK_TEXT
            log_warn tick-overrun tick="$tick" elapsed="$over" \
                msg="Tick took ${over}s, longer than the ${tick}s tick interval; starting the next tick immediately."
        fi
        iter=$(( iter + 1 ))
    done
}
