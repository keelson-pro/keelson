# Long-running scanner loop. Periodic full scan with watch-queue drain at
# the start of each iteration.
# Sourced; not directly executable.
#
# Configuration:
#   KEELSON_POLL_INTERVAL          seconds between scans (default 60)
#   KEELSON_DRY_RUN                "1" forces apply=0 (default unset -> apply)
#   KEELSON_LOOP_MAX_ITERATIONS    0 = loop forever (default); >0 for tests
#   KEELSON_FULL_REFRESH_INTERVAL  seconds between dedupe-cache resets
#                                  (default 3600). On each tick, the state
#                                  cache is reloaded so deduped errors and
#                                  skips re-emit at least once an hour.
#
# Readiness sentinel path is hard-coded to /keelson/work/ready (the
# Deployment mounts emptyDir at /keelson/work). Tests override
# KEELSON_READY_FILE by reassigning it AFTER sourcing this file.
#
# Depends on (must be sourced first):
#   lib/log.bash, lib/queue.bash, lib/state.bash, lib/scan.bash
#   (and its own dependency chain)

KEELSON_READY_FILE=/keelson/work/ready

# loop_mark_ready
# Touches the readiness sentinel so an exec probe can succeed.
loop_mark_ready() {
    mkdir -p "$(dirname "$KEELSON_READY_FILE")"
    : > "$KEELSON_READY_FILE"
    log_info ready file="$KEELSON_READY_FILE"
}

# loop_drain_queue
# Drains the watch-queue, logs each work item, and reports total drained.
loop_drain_queue() {
    local count=0 line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        log_debug queue-item "$line"
        count=$(( count + 1 ))
    done < <(queue_drain)
    log_info queue-drained count="$count"
}

# loop_run
# Forever (or until KEELSON_LOOP_MAX_ITERATIONS): drain queue, run scan,
# flush state in apply mode, periodically reload state for the full-refresh
# tick, then sleep KEELSON_POLL_INTERVAL.
loop_run() {
    local interval=${KEELSON_POLL_INTERVAL:-60}
    local max_iter=${KEELSON_LOOP_MAX_ITERATIONS:-0}
    local full_refresh=${KEELSON_FULL_REFRESH_INTERVAL:-3600}
    local iter=0
    local apply=1
    [ "${KEELSON_DRY_RUN:-0}" = "1" ] && apply=0

    local last_refresh
    last_refresh=$(date -u +%s)

    while [ "$max_iter" -eq 0 ] || [ "$iter" -lt "$max_iter" ]; do
        loop_drain_queue
        scan_run "$apply"
        if [ "$apply" -eq 1 ]; then
            state_flush || true
        fi

        local now elapsed
        now=$(date -u +%s)
        elapsed=$(( now - last_refresh ))
        if [ "$elapsed" -ge "$full_refresh" ]; then
            log_info state-full-refresh elapsed="$elapsed"
            state_clear_cache
            if [ "$apply" -eq 1 ]; then
                state_load || true
            fi
            last_refresh=$now
        fi

        sleep "$interval"
        iter=$(( iter + 1 ))
    done
}
