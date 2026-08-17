# Watcher primitives: one kubectl --watch per kind, with reconnect/backoff.
# Sourced; not directly executable.
#
# Each event from kubectl produces one line of "<ns> <name>" via jsonpath;
# the per-line handler enqueues the identity into the directory queue.
# Eligibility is NOT evaluated here - the scanner does that at scan time
# from authoritative cluster state, so the watcher stays dumb.
#
# Configuration:
#   KEELSON_WATCHER_RECONNECT_INITIAL  first reconnect delay, seconds (required)
#   KEELSON_WATCHER_RECONNECT_MAX      cap, seconds                  (required)
#   KEELSON_WATCHER_RECONNECT_RESET    seconds a stream must hold to count as
#                                      healthy and clear the backoff (required)
#   KEELSON_WATCH_MAX_ITERATIONS       0 = loop forever (default); >0 for tests
#
# Depends on (must be sourced first):
#   lib/log.bash, lib/clock.bash, lib/queue.bash

# watch_run_kind <kind>
# Long-running reconnect loop. Each iteration runs one kubectl --watch
# until it exits, then sleeps with exponential backoff before retrying.
#
# A stream that held for KEELSON_WATCHER_RECONNECT_RESET clears the backoff.
# Streams end for routine reasons (API server rollout, resourceVersion
# expiry, load balancer idle timeout), so without a reset the backoff is a
# one-way ratchet: a perfectly healthy watcher climbs to the cap within a few
# hours and keeps the longest possible blind window between reconnects for
# the rest of the pod's life.
#
# Duration is the only signal available. The pipeline's exit status is
# watch_handle_events', which returns 0 whenever stdin closes, so a three
# hour stream ending and kubectl exiting instantly are indistinguishable by
# status. How long it lasted tells them apart.
watch_run_kind() {
    local kind=$1
    local initial=${KEELSON_WATCHER_RECONNECT_INITIAL:?KEELSON_WATCHER_RECONNECT_INITIAL required}
    local cap=${KEELSON_WATCHER_RECONNECT_MAX:?KEELSON_WATCHER_RECONNECT_MAX required}
    local reset=${KEELSON_WATCHER_RECONNECT_RESET:?KEELSON_WATCHER_RECONNECT_RESET required}
    local max_iter=${KEELSON_WATCH_MAX_ITERATIONS:-0}
    local backoff=$initial
    local iter=0 opened held
    while [ "$max_iter" -eq 0 ] || [ "$iter" -lt "$max_iter" ]; do
        log_info watch-start kind="$kind" \
            msg="Watching kind '$kind' for changes."
        clock_read
        opened=$CLOCK_NOW_US
        watch_kubectl_stream "$kind" | watch_handle_events "$kind"
        clock_read
        held=$(( (CLOCK_NOW_US - opened) / 1000000 ))
        [ "$held" -ge "$reset" ] && backoff=$initial
        log_warn watch-disconnected kind="$kind" backoff="$backoff" held="$held" \
            msg="Watch for kind '$kind' held ${held}s then disconnected; reconnecting in ${backoff}s."
        sleep "$backoff"
        backoff=$(( backoff * 2 ))
        [ "$backoff" -gt "$cap" ] && backoff=$cap
        iter=$(( iter + 1 ))
    done
}

# watch_kubectl_stream <kind>
# Emits one line per event as "<namespace> <name>". Honours KEELSON_SCOPE.
watch_kubectl_stream() {
    local kind=$1
    local jp='{.metadata.namespace} {.metadata.name}{"\n"}'
    case "${KEELSON_SCOPE:?KEELSON_SCOPE required}" in
        namespace)
            kubectl get "$kind" \
                -n "${KEELSON_NAMESPACE:?KEELSON_NAMESPACE required when KEELSON_SCOPE=namespace}" \
                --watch -o jsonpath="$jp" 2>/dev/null
            ;;
        cluster|*)
            kubectl get "$kind" --all-namespaces \
                --watch -o jsonpath="$jp" 2>/dev/null
            ;;
    esac
}

# watch_handle_events <kind>
# Reads lines of "<ns> <name>" from stdin and enqueues each as a work item.
watch_handle_events() {
    local kind=$1 ns name
    while read -r ns name; do
        [ -z "$ns" ] && continue
        [ -z "$name" ] && continue
        queue_enqueue "$kind" "$ns" "$name"
        log_debug watch-enqueued kind="$kind" ns="$ns" name="$name"
    done
}

# watch_start_all
# Spawns one watch_run_kind background job per watched kind. Echoes pids.
watch_start_all() {
    local kind pids=()
    for kind in $KEELSON_WATCHED_KINDS; do
        watch_run_kind "$kind" &
        pids+=($!)
    done
    printf '%s\n' "${pids[@]}"
}
