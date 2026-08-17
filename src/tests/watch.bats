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
    # shellcheck source=../scripts/lib/watch.bash
    source "$SCRIPT_DIR/lib/watch.bash"

    KEELSON_QUEUE_DIR="$TMP_DIR/queue"

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
    printf 'default app\nns2 other\n' | watch_handle_events Deployment
    run queue_size
    [ "$output" = "2" ]
    [ -f "$KEELSON_QUEUE_DIR/Deployment--default--app" ]
    [ -f "$KEELSON_QUEUE_DIR/Deployment--ns2--other" ]
}

@test "watch_handle_events: blank lines are ignored" {
    printf '\ndefault app\n\n' | watch_handle_events Deployment
    run queue_size
    [ "$output" = "1" ]
}

@test "watch_handle_events: duplicate events dedupe to one queue entry" {
    printf 'default app\ndefault app\ndefault app\n' | watch_handle_events Deployment
    run queue_size
    [ "$output" = "1" ]
}

@test "watch_handle_events: line with only namespace (no name) is skipped" {
    printf 'default \n' | watch_handle_events Deployment
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
printf 'default app\n'
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
