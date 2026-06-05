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
#   KEELSON_WATCH_MAX_ITERATIONS       0 = loop forever (default); >0 for tests
#
# Depends on (must be sourced first):
#   lib/log.bash, lib/queue.bash

# watch_run_kind <kind>
# Long-running reconnect loop. Each iteration runs one kubectl --watch
# until it exits, then sleeps with exponential backoff before retrying.
watch_run_kind() {
    local kind=$1
    local backoff=${KEELSON_WATCHER_RECONNECT_INITIAL:?KEELSON_WATCHER_RECONNECT_INITIAL required}
    local cap=${KEELSON_WATCHER_RECONNECT_MAX:?KEELSON_WATCHER_RECONNECT_MAX required}
    local max_iter=${KEELSON_WATCH_MAX_ITERATIONS:-0}
    local iter=0
    while [ "$max_iter" -eq 0 ] || [ "$iter" -lt "$max_iter" ]; do
        log_info watch-start kind="$kind"
        watch_kubectl_stream "$kind" | watch_handle_events "$kind"
        log_warn watch-disconnected kind="$kind" backoff="$backoff"
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
