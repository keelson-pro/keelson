# Controller loop: tick-driven heartbeat, supervised watchers, backgrounded scans.
# Sourced; not directly executable.
#
# Configuration (all required, validated at boot):
#   KEELSON_TICK_INTERVAL          seconds between supervisor ticks
#   KEELSON_RECONCILE_INTERVAL          seconds between scan starts (measured from
#                                  scan start time; long scans queue the next
#                                  for the very next tick, never overlap)
#   KEELSON_FULL_REFRESH_INTERVAL  seconds between dedupe-cache refreshes
#   KEELSON_WATCHER_RESPAWN_BACKOFF_MAX    cap on per-kind respawn delay (s)
#   KEELSON_WATCHER_RESPAWN_HEALTHY_RESET  alive duration that clears a kind's failure count
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
LOOP_POLL_PID=0
LOOP_REFRESH_PID=0
declare -ga LOOP_REFRESH_PENDING=()

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

# loop_start_scan <apply>
# Spawns a reconcile scan child. The child owns the state lifecycle: it
# reloads from the ConfigMap, runs the scan, and flushes deltas back. Parent
# state is not mutated.
loop_start_scan() {
    local apply=$1
    (
        state_load || log_warn state-reload-failed \
            configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
            msg="State reload from ConfigMap '$STATE_CONFIGMAP_NAME' in '$STATE_NAMESPACE' failed."
        # poll-all=0: this pass refreshes the cache and evicts. Registry
        # work belongs to the due-poll above, on each workload's own cadence.
        scan_run "$apply" 0
        [ "$apply" -eq 1 ] && { state_flush || true; }
    ) &
    LOOP_SCAN_PID=$!
}

# loop_start_poll <apply> <now>
# Spawns the due-poll child: registry lookups for whatever the cache says is
# due right now.
#
# Owns the same state lifecycle as the scan child, and for the same reason:
# it is a subshell, so anything it records (a CronJob trigger, a workload's
# new next-due) is lost unless it flushes before exiting, and without loading
# first the trigger gate reads empty and re-fires a Job that already ran.
#
# Backgrounded for the same reason the scan is: skopeo against a slow
# registry must not hold up the tick. Gated on LOOP_POLL_PID so a long poll
# never overlaps itself; the cache is on disk, so the child's next-due writes
# outlive it.
loop_start_poll() {
    local apply=$1 now=$2
    (
        state_load || log_warn state-reload-failed \
            configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
            msg="State reload from ConfigMap '$STATE_CONFIGMAP_NAME' in '$STATE_NAMESPACE' failed."
        scan_poll_due "$apply" "$now"
        [ "$apply" -eq 1 ] && { state_flush || true; }
    ) &
    LOOP_POLL_PID=$!
}

# loop_start_refresh <apply> <kind> <finish>
# Spawns the full-refresh child for one kind.
#
# One kind per tick rather than all of them at once: a full refresh lists the
# cluster kind by kind, and doing the lot in one pass is the long-running
# thing the tick exists to avoid. Spreading it costs nothing, since a refresh
# makes no registry calls.
#
# <finish> is 1 for the last kind of the cycle, which is when the cache is
# whole again and the ledger can safely be reconciled against it.
loop_start_refresh() {
    local apply=$1 kind=$2 finish=$3
    (
        state_load || log_warn state-reload-failed \
            configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
            msg="State reload from ConfigMap '$STATE_CONFIGMAP_NAME' in '$STATE_NAMESPACE' failed."
        scan_refresh_kind "$apply" "$kind"
        if [ "$finish" -eq 1 ]; then
            inventory_evict_unwatched "$KEELSON_WATCHED_KINDS"
            state_reconcile_ledger
            log_info_always full-refresh-complete kinds="$KEELSON_WATCHED_KINDS" \
                msg="Full refresh complete: the cache was rebuilt from the cluster and the ledger reconciled against it."
        fi
        [ "$apply" -eq 1 ] && { state_flush || true; }
    ) &
    LOOP_REFRESH_PID=$!
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
    [ "$LOOP_POLL_PID" -gt 0 ] && kill "$LOOP_POLL_PID" 2>/dev/null || true
    [ "$LOOP_REFRESH_PID" -gt 0 ] && kill "$LOOP_REFRESH_PID" 2>/dev/null || true
    return 0
}

# loop_run
# Tick once per KEELSON_TICK_INTERVAL: publish the heartbeat, supervise
# watchers, drain queue, poll whatever the cache says is due, kick a
# backgrounded reconcile scan when due. The watcher map
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
    local poll=${KEELSON_RECONCILE_INTERVAL:?KEELSON_RECONCILE_INTERVAL required}
    local full_refresh=${KEELSON_FULL_REFRESH_INTERVAL:?KEELSON_FULL_REFRESH_INTERVAL required}
    local backoff_max=${KEELSON_WATCHER_RESPAWN_BACKOFF_MAX:?KEELSON_WATCHER_RESPAWN_BACKOFF_MAX required}
    local healthy_reset=${KEELSON_WATCHER_RESPAWN_HEALTHY_RESET:?KEELSON_WATCHER_RESPAWN_HEALTHY_RESET required}
    local max_iter=${KEELSON_LOOP_MAX_ITERATIONS:-0}
    local apply=1
    [ "${KEELSON_DRY_RUN:-0}" = "1" ] && apply=0

    local tick_us=$(( tick * 1000000 ))
    local now cycle_start_us remaining_us over_us over
    local last_scan_start=0 last_refresh iter=0
    clock_read
    last_refresh=$(( CLOCK_NOW_US / 1000000 ))

    while [ "$max_iter" -eq 0 ] || [ "$iter" -lt "$max_iter" ]; do
        clock_read
        cycle_start_us=$CLOCK_NOW_US
        now=$(( cycle_start_us / 1000000 ))
        status_write_heartbeat "$cycle_start_us"

        loop_supervise_watchers "$now" "$backoff_max" "$healthy_reset"
        loop_drain_queue

        # Every tick: what needs polling now? The cache answers without
        # touching the cluster, so this costs nothing when nothing is due.
        if [ "$LOOP_POLL_PID" -gt 0 ] && ! kill -0 "$LOOP_POLL_PID" 2>/dev/null; then
            wait "$LOOP_POLL_PID" 2>/dev/null || true
            LOOP_POLL_PID=0
        fi
        if [ "$LOOP_POLL_PID" -eq 0 ]; then
            loop_start_poll "$apply" "$now"
        fi

        if [ "$LOOP_SCAN_PID" -gt 0 ] && ! kill -0 "$LOOP_SCAN_PID" 2>/dev/null; then
            wait "$LOOP_SCAN_PID" 2>/dev/null || true
            LOOP_SCAN_PID=0
        fi
        if [ "$LOOP_SCAN_PID" -eq 0 ] && [ $(( now - last_scan_start )) -ge "$poll" ]; then
            loop_start_scan "$apply"
            last_scan_start=$now
        fi

        if [ $(( now - last_refresh )) -ge "$full_refresh" ] \
                && [ "${#LOOP_REFRESH_PENDING[@]}" -eq 0 ]; then
            local elapsed=$(( now - last_refresh ))
            # Queue every watched kind. One is taken per tick below, so the
            # refresh is spread rather than being one long pass.
            LOOP_REFRESH_PENDING=($KEELSON_WATCHED_KINDS)
            last_refresh=$now
            log_info_always full-refresh-due elapsed="$elapsed" \
                kinds="$KEELSON_WATCHED_KINDS" \
                msg="Full refresh due after ${elapsed}s: rebuilding the cache from the cluster, one kind per tick."
        fi

        if [ "$LOOP_REFRESH_PID" -gt 0 ] && ! kill -0 "$LOOP_REFRESH_PID" 2>/dev/null; then
            wait "$LOOP_REFRESH_PID" 2>/dev/null || true
            LOOP_REFRESH_PID=0
        fi
        if [ "$LOOP_REFRESH_PID" -eq 0 ] && [ "${#LOOP_REFRESH_PENDING[@]}" -gt 0 ]; then
            local refresh_kind=${LOOP_REFRESH_PENDING[0]}
            LOOP_REFRESH_PENDING=("${LOOP_REFRESH_PENDING[@]:1}")
            local refresh_finish=0
            [ "${#LOOP_REFRESH_PENDING[@]}" -eq 0 ] && refresh_finish=1
            loop_start_refresh "$apply" "$refresh_kind" "$refresh_finish"
        fi

        # Sole owner of log rotation. Watchers and scan children append to
        # the same file but must never rotate it; concurrent rename shuffles
        # lose rotated files. Last thing in the tick, so it accounts for
        # everything this tick logged.
        log_file_rotate_if_needed

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
