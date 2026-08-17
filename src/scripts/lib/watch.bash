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
#   lib/log.bash, lib/clock.bash, lib/queue.bash, lib/status.bash

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
    local iter=0 opened held rc fails=0 err errfile rcfile
    errfile="${KEELSON_STATUS_DIR}/watcher-${kind}.stderr"
    rcfile="${KEELSON_STATUS_DIR}/watcher-${kind}.rc"
    mkdir -p "$KEELSON_STATUS_DIR" 2>/dev/null || true
    status_write_watcher_health "$kind" 0 ""
    while [ "$max_iter" -eq 0 ] || [ "$iter" -lt "$max_iter" ]; do
        log_info watch-start kind="$kind" \
            msg="Watching kind '$kind' for changes."
        clock_read
        opened=$CLOCK_NOW_US
        # kubectl's own exit code, recorded inside the pipeline's left-hand
        # subshell. Two reasons not to read the pipeline's status instead:
        # it reflects watch_handle_events, which returns 0 whenever stdin
        # closes, and reading kubectl's through it would depend on pipefail
        # being set by whoever sourced us. Recording it here is explicit and
        # keeps the whole thing clear of set -e, which would otherwise kill
        # this subshell on exactly the failures the loop exists to handle
        # (denied RBAC, unknown kind, refused connection).
        rc=0
        # `|| rc=$?` inside the subshell as well as outside: set -e applies
        # in there too, and would otherwise tear the subshell down the moment
        # kubectl fails, before the code could be recorded. The newline
        # matters too, or read hits EOF and returns 1.
        { watch_kubectl_stream "$kind" 2>"$errfile" || rc=$?; \
          printf '%s\n' "$rc" >"$rcfile"; } \
            | watch_handle_events "$kind"
        read -r rc <"$rcfile" 2>/dev/null || rc=0
        clock_read
        held=$(( (CLOCK_NOW_US - opened) / 1000000 ))
        if [ "$rc" -ne 0 ]; then
            err=$(watch_last_error "$errfile")
            fails=$(( fails + 1 ))
            status_write_watcher_health "$kind" "$fails" "$err"
            log_warn watch-failed kind="$kind" rc="$rc" fails="$fails" \
                backoff="$backoff" \
                msg="Watch for kind '$kind' failed (exit $rc, $fails in a row): ${err:-no error output}. Retrying in ${backoff}s."
        else
            if [ "$held" -ge "$reset" ]; then
                backoff=$initial
                fails=0
                status_write_watcher_health "$kind" 0 ""
            fi
            log_warn watch-disconnected kind="$kind" backoff="$backoff" held="$held" \
                msg="Watch for kind '$kind' held ${held}s then disconnected; reconnecting in ${backoff}s."
        fi
        sleep "$backoff"
        backoff=$(( backoff * 2 ))
        [ "$backoff" -gt "$cap" ] && backoff=$cap
        iter=$(( iter + 1 ))
    done
}

# watch_last_error <file>
# Last non-blank line of kubectl's stderr, or empty. One line is enough to
# tell RBAC from a bad kind from a refused connection.
watch_last_error() {
    local file=$1 line last=
    [ -r "$file" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] && last=$line
    done < "$file"
    printf '%s' "$last"
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
                --watch -o jsonpath="$jp"
            ;;
        cluster|*)
            kubectl get "$kind" --all-namespaces \
                --watch -o jsonpath="$jp"
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
