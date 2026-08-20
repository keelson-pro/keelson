#!/usr/bin/env bats

# Watcher tests. kubectl is shimmed via $TMP_BIN on PATH.

setup() {
    TMP_DIR=$(mktemp -d)
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    KEELSON_WATCHED_KINDS=Deployment
    KEELSON_SCOPE=cluster
    KEELSON_WATCHER_RECONNECT_INITIAL=2
    KEELSON_WATCHER_RECONNECT_MAX=60
    KEELSON_WATCHER_RECONNECT_RESET=30
    export PATH TMP_DIR KEELSON_WATCHED_KINDS KEELSON_SCOPE \
        KEELSON_WATCHER_RECONNECT_INITIAL KEELSON_WATCHER_RECONNECT_MAX \
        KEELSON_WATCHER_RECONNECT_RESET

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/clock.bash
    source "$SCRIPT_DIR/lib/clock.bash"
    # shellcheck source=../scripts/lib/queue.bash
    source "$SCRIPT_DIR/lib/queue.bash"
    # shellcheck source=../scripts/lib/inventory.bash
    source "$SCRIPT_DIR/lib/inventory.bash"
    # shellcheck source=../scripts/lib/status.bash
    source "$SCRIPT_DIR/lib/status.bash"
    # shellcheck source=../scripts/lib/watch.bash
    source "$SCRIPT_DIR/lib/watch.bash"

    KEELSON_QUEUE_DIR="$TMP_DIR/queue"
    KEELSON_STATUS_DIR="$TMP_DIR/status"
    KEELSON_INVENTORY_DIR="$TMP_DIR/inventory"
    export KEELSON_STATUS_DIR KEELSON_INVENTORY_DIR
    inventory_init

    queue_init
}

teardown() {
    rm -rf "$TMP_DIR"
}

emit() { "$@" 2>&1; }

install_shim() {
    local name=$1
    cat > "$TMP_BIN/$name"
    chmod +x "$TMP_BIN/$name"
}

# --- watch_handle_events: pure stdin → queue ---

@test "watch_handle_events: enqueues one line per event" {
    printf 'MODIFIED default app\nMODIFIED ns2 other\n' \
        | watch_handle_events Deployment 2>/dev/null
    run queue_size
    [ "$output" = "2" ]
    [ -f "$KEELSON_QUEUE_DIR/Deployment--default--app" ]
    [ -f "$KEELSON_QUEUE_DIR/Deployment--ns2--other" ]
}

@test "watch_handle_events: blank lines are ignored" {
    printf '\nMODIFIED default app\n\n' \
        | watch_handle_events Deployment 2>/dev/null
    run queue_size
    [ "$output" = "1" ]
}

@test "watch_handle_events: duplicate events dedupe to one queue entry" {
    printf 'MODIFIED default app\nMODIFIED default app\n' \
        | watch_handle_events Deployment 2>/dev/null
    run queue_size
    [ "$output" = "1" ]
}

@test "watch_handle_events: line with only namespace (no name) is skipped" {
    printf 'MODIFIED default \n' | watch_handle_events Deployment 2>/dev/null
    run queue_size
    [ "$output" = "0" ]
}

# --- watch_kubectl_stream ---

@test "watch_kubectl_stream: cluster scope uses --all-namespaces" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.args"
exit 0
SH
    KEELSON_SCOPE=cluster watch_kubectl_stream Deployment >/dev/null
    grep -q -- "--all-namespaces" "$TMP_DIR/kubectl.args"
    grep -q -- "--watch" "$TMP_DIR/kubectl.args"
}

@test "watch_kubectl_stream: namespace scope passes -n" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.args"
exit 0
SH
    KEELSON_SCOPE=namespace KEELSON_NAMESPACE=team-a \
        watch_kubectl_stream Deployment >/dev/null
    grep -q -- "-n team-a" "$TMP_DIR/kubectl.args"
    ! grep -q -- "--all-namespaces" "$TMP_DIR/kubectl.args"
}

@test "watch_kubectl_stream: emits namespace + name lines from a kubectl shim" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf 'default app\ndefault other\n'
SH
    run watch_kubectl_stream Deployment
    [ "$status" -eq 0 ]
    [[ "$output" == *"default app"* ]]
    [[ "$output" == *"default other"* ]]
}

# --- watch_run_kind: reconnect loop with backoff ---

@test "watch_run_kind: streams events then reconnects on disconnect" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf 'MODIFIED default app\n'
exit 0
SH
    # Avoid real-time delays.
    install_shim sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=2 KEELSON_WATCHER_RECONNECT_INITIAL=1 \
        run emit watch_run_kind Deployment
    [ "$status" -eq 0 ]
    # Two iterations -> two "Watching kind" log lines.
    [ "$(printf '%s\n' "$output" | grep -c "Watching kind 'Deployment'")" = "2" ]
    [[ "$output" == *"Watch for kind 'Deployment' held"* ]]
    [[ "$output" == *"then disconnected"* ]]
    # Each iteration enqueued the same identity; dedupe leaves one file.
    [ -f "$KEELSON_QUEUE_DIR/Deployment--default--app" ]
}

@test "watch_run_kind: backoff caps at KEELSON_WATCHER_RECONNECT_MAX" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
echo "$1" >>"$TMP_DIR/sleeps"
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=5 \
    KEELSON_WATCHER_RECONNECT_INITIAL=8 \
    KEELSON_WATCHER_RECONNECT_MAX=10 \
        watch_run_kind Deployment 2>/dev/null
    # Sleeps observed: 8, 10, 10, 10, 10 (clamped after first double)
    [ "$(head -n 1 "$TMP_DIR/sleeps")" = "8" ]
    [ "$(tail -n 1 "$TMP_DIR/sleeps")" = "10" ]
}

# --- a failing kubectl must not take the watcher down with it ---

@test "watch_run_kind: survives a kubectl that exits non-zero" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "Error from server (Forbidden): cronjobs is forbidden" >&2
exit 1
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=3 run emit watch_run_kind CronJob
    [ "$status" -eq 0 ]
    # All three iterations ran: set -e did not kill the loop on the first.
    [ "$(printf '%s\n' "$output" | grep -c "Watching kind 'CronJob'")" = "3" ]
}

@test "watch_run_kind: publishes the failure outward" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "Error from server (Forbidden): cronjobs is forbidden" >&2
exit 1
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=2 watch_run_kind CronJob 2>/dev/null
    status_read_watcher_health CronJob
    [ "$STATUS_WATCHER_FAILURES" = "2" ]
    [[ "$STATUS_WATCHER_ERROR" == *"Forbidden"* ]]
}

@test "watch_run_kind: logs why kubectl failed instead of swallowing it" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "Error from server (Forbidden): cronjobs is forbidden" >&2
exit 1
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=1 run emit watch_run_kind CronJob
    [[ "$output" == *"Forbidden"* ]]
}

# --- the failure hint, and where the rest of it goes ---
#
# kubectl answers a jsonpath failure with its error and then the whole
# offending object in Go syntax, thousands of characters of it. Reading the
# last line of stderr picked exactly the dump and dropped the reason.

install_jsonpath_failure_shim() {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo 'error: error executing jsonpath "{.type} {.object.metadata.namespace} {.object.metadata.name}": name is not found. Printing more information for debugging the template:' >&2
echo '	object given to jsonpath engine was:' >&2
printf '\t\tmap[string]interface {}{"object":map[string]interface {}{"DUMPMARKER":"x"}}\n' >&2
exit 1
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
}

@test "watch_run_kind: the warn line hints at the error, without the object dump" {
    install_jsonpath_failure_shim
    KEELSON_WATCH_MAX_ITERATIONS=1 KEELSON_LOG_LEVEL=info \
        run emit watch_run_kind Deployment
    [[ "$output" == *"error: error executing jsonpath"* ]]
    [[ "$output" == *"Retrying in"* ]]
    [[ "$output" != *"DUMPMARKER"* ]]
}

@test "watch_run_kind: the full kubectl output is there at debug" {
    install_jsonpath_failure_shim
    KEELSON_WATCH_MAX_ITERATIONS=1 KEELSON_LOG_LEVEL=debug \
        run emit watch_run_kind Deployment
    [[ "$output" == *"DUMPMARKER"* ]]
}

@test "watch_error_hint: a short first line is passed through whole" {
    printf 'connection refused\n' >"$TMP_DIR/err"
    run watch_error_hint "$TMP_DIR/err"
    [ "$output" = 'connection refused' ]
}

@test "watch_error_hint: a long first line is clipped with an ellipsis" {
    local long
    long=$(printf 'x%.0s' {1..300})
    printf '%s\n' "$long" >"$TMP_DIR/err"
    run watch_error_hint "$TMP_DIR/err"
    [ "${#output}" -eq $(( LOG_HINT_MAX + 3 )) ]
    [[ "$output" == *"..." ]]
}

@test "watch_error_hint: takes the first line, not the last" {
    printf 'the reason\nthe dump\n' >"$TMP_DIR/err"
    run watch_error_hint "$TMP_DIR/err"
    [ "$output" = "the reason" ]
}

@test "watch_error_hint: leading blank lines are skipped" {
    printf '\n\nthe reason\n' >"$TMP_DIR/err"
    run watch_error_hint "$TMP_DIR/err"
    [ "$output" = "the reason" ]
}

@test "watch_error_hint: a missing file yields nothing" {
    run watch_error_hint "$TMP_DIR/absent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "watch_run_kind: marks itself healthy while a stream is open" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf 'MODIFIED default app\n'
exit 0
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=1 \
    KEELSON_WATCHER_RECONNECT_RESET=0 \
        watch_run_kind Deployment 2>/dev/null
    status_read_watcher_health Deployment
    [ "$STATUS_WATCHER_FAILURES" = "0" ]
}

@test "watch_run_kind: a good stream clears an earlier failure" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
n=$(cat "$TMP_DIR/kcount" 2>/dev/null || echo 0)
n=$(( n + 1 ))
echo "$n" > "$TMP_DIR/kcount"
if [ "$n" -le 2 ]; then
    echo "Error from server (Forbidden)" >&2
    exit 1
fi
/bin/sleep 1.2
exit 0
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=3 \
    KEELSON_WATCHER_RECONNECT_RESET=1 \
        watch_run_kind Deployment 2>/dev/null
    status_read_watcher_health Deployment
    [ "$STATUS_WATCHER_FAILURES" = "0" ]
}

# --- backoff reset on a stream that held ---
#
# Without a reset the backoff is a one-way ratchet: routine disconnects
# (API server rollout, resourceVersion expiry) climb it to the cap and it
# never comes back down, so a perfectly healthy watcher ends up with the
# longest possible blind window between reconnects for the pod's whole life.

@test "watch_run_kind: a stream that held past the reset clears the backoff" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
/bin/sleep 1.2
exit 0
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
echo "$1" >>"$TMP_DIR/sleeps"
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=3 \
    KEELSON_WATCHER_RECONNECT_INITIAL=1 \
    KEELSON_WATCHER_RECONNECT_MAX=10 \
    KEELSON_WATCHER_RECONNECT_RESET=1 \
        watch_run_kind Deployment 2>/dev/null
    # Every stream held 1.2s >= 1s, so every reconnect is back at initial.
    [ "$(tr '\n' ' ' <"$TMP_DIR/sleeps")" = "1 1 1 " ]
}

@test "watch_run_kind: a stream that died instantly does not clear the backoff" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
echo "$1" >>"$TMP_DIR/sleeps"
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=3 \
    KEELSON_WATCHER_RECONNECT_INITIAL=1 \
    KEELSON_WATCHER_RECONNECT_MAX=10 \
    KEELSON_WATCHER_RECONNECT_RESET=30 \
        watch_run_kind Deployment 2>/dev/null
    [ "$(tr '\n' ' ' <"$TMP_DIR/sleeps")" = "1 2 4 " ]
}

@test "watch_run_kind: backoff escalates, then recovers once a stream holds" {
    # First two streams die instantly, the third and fourth hold.
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
n=$(cat "$TMP_DIR/kcount" 2>/dev/null || echo 0)
n=$(( n + 1 ))
echo "$n" > "$TMP_DIR/kcount"
[ "$n" -ge 3 ] && /bin/sleep 1.2
exit 0
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
echo "$1" >>"$TMP_DIR/sleeps"
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=4 \
    KEELSON_WATCHER_RECONNECT_INITIAL=1 \
    KEELSON_WATCHER_RECONNECT_MAX=10 \
    KEELSON_WATCHER_RECONNECT_RESET=1 \
        watch_run_kind Deployment 2>/dev/null
    # 1, 2 while failing; back to 1 as soon as a stream held.
    [ "$(tr '\n' ' ' <"$TMP_DIR/sleeps")" = "1 2 1 1 " ]
}

@test "watch_run_kind: reports how long the stream held" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    install_shim sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_WATCH_MAX_ITERATIONS=1 \
    KEELSON_WATCHER_RECONNECT_RESET=30 \
        run emit watch_run_kind Deployment
    [[ "$output" == *"held"* ]]
}

# --- events become work, not conclusions ---
#
# A watch fires on every write to the object and cannot say which write it
# was. The handler evicts on a delete and queues everything else; the tick
# re-reads the cluster and decides from that.

cache_one() {
    local images=${1:-'containers main=ghcr.io/x/y:1.0'} next_due=${2:-5000}
    inventory_put Deployment default app "$next_due" 300 "" default '[]' \
        'keelson.pro/policy=minor' "$images"
}

@test "events: an event queues the identity for re-reading" {
    cache_one
    printf 'MODIFIED default app\n' \
        | watch_handle_events Deployment 2>/dev/null
    [ -f "$KEELSON_QUEUE_DIR/Deployment--default--app" ]
}

@test "events: an event does not touch the cache itself" {
    # The event says nothing about what changed, so acting on it here could
    # only ever be a guess. The re-read is what writes.
    cache_one 'containers main=ghcr.io/x/y:1.0' 5000
    printf 'MODIFIED default app\n' \
        | watch_handle_events Deployment 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "5000" ]
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io/x/y:1.0" ]
}

@test "events: churn on one identity collapses to a single queue entry" {
    cache_one
    printf 'MODIFIED default app\nMODIFIED default app\nMODIFIED default app\n' \
        | watch_handle_events Deployment 2>/dev/null
    run queue_size
    [ "$output" = "1" ]
}

@test "events: an uncached workload is queued too" {
    # First sight of a workload is exactly the case the re-read exists for.
    printf 'ADDED default fresh\n' \
        | watch_handle_events Deployment 2>/dev/null
    [ -f "$KEELSON_QUEUE_DIR/Deployment--default--fresh" ]
}

@test "events: a delete evicts the entry" {
    cache_one
    printf 'DELETED default app\n' \
        | watch_handle_events Deployment 2>/dev/null
    run inventory_get Deployment default app
    [ "$status" -eq 1 ]
}

@test "events: a delete is not queued, there is nothing left to read" {
    cache_one
    printf 'DELETED default app\n' \
        | watch_handle_events Deployment 2>/dev/null
    run queue_size
    [ "$output" = "0" ]
}

@test "events: a delete for something never cached is not an error" {
    printf 'DELETED default ghost\n' \
        | watch_handle_events Deployment 2>/dev/null
    run inventory_get Deployment default ghost
    [ "$status" -eq 1 ]
}

@test "events: a blank line is ignored" {
    printf '\n' | watch_handle_events Deployment 2>/dev/null
    run queue_size
    [ "$output" = "0" ]
}

# --- the stream template ---

@test "stream: asks for watch event types" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.args"
exit 0
SH
    watch_kubectl_stream Deployment >/dev/null
    grep -q -- "--output-watch-events=true" "$TMP_DIR/kubectl.args"
}

@test "stream: template carries the type and the identity" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.args"
exit 0
SH
    watch_kubectl_stream Deployment >/dev/null
    grep -q -- "{.type}" "$TMP_DIR/kubectl.args"
    grep -q -- "{.object.metadata.namespace}" "$TMP_DIR/kubectl.args"
    grep -q -- "{.object.metadata.name}" "$TMP_DIR/kubectl.args"
}

@test "stream: the template carries nothing else" {
    # Anything beyond the coordinates would be a second, weaker source of
    # truth about a workload, competing with the re-read.
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.args"
exit 0
SH
    watch_kubectl_stream Deployment >/dev/null
    ! grep -q -- "containers" "$TMP_DIR/kubectl.args"
    ! grep -q -- "annotations" "$TMP_DIR/kubectl.args"
}

@test "stream: CronJob needs no path of its own any more" {
    # The kind's nesting only ever mattered for reaching its containers.
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.args"
exit 0
SH
    watch_kubectl_stream CronJob >/dev/null
    ! grep -q -- "jobTemplate" "$TMP_DIR/kubectl.args"
}
