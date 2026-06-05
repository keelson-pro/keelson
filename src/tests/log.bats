#!/usr/bin/env bats

setup() {
    TMP_DIR=$(mktemp -d)
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # The default path is /keelson/work/log/keelson.log which is unwritable
    # outside a container; redirect under TMP_DIR before sourcing.
    KEELSON_LOG_FILE_PATH="$TMP_DIR/keelson.log"
    export KEELSON_LOG_FILE_PATH

    # shellcheck source=../scripts/lib/log.bash
    source "${SCRIPT_DIR}/lib/log.bash"

    unset KEELSON_LOG_FORMAT KEELSON_LOG_LEVEL
    unset KEELSON_LOG_DEBUG_REPEAT_INTERVAL \
          KEELSON_LOG_INFO_REPEAT_INTERVAL \
          KEELSON_LOG_WARN_REPEAT_INTERVAL \
          KEELSON_LOG_ERROR_REPEAT_INTERVAL
    LOG_THROTTLE_LAST=()
}

teardown() {
    rm -rf "$TMP_DIR"
}

# Logs are emitted on stderr; merge to stdout so `run` captures them.
emit() { "$@" 2>&1; }

@test "log_info plain: emits level, event, and k=v fields" {
    run emit log_info scan-summary kind=Deployment count=3
    [ "$status" -eq 0 ]
    [[ "$output" =~ INFO ]]
    [[ "$output" =~ scan-summary ]]
    [[ "$output" =~ kind=Deployment ]]
    [[ "$output" =~ count=3 ]]
}

@test "log_info json: emits valid JSON-shape line with quoted fields" {
    KEELSON_LOG_FORMAT=json run emit log_info scan-summary kind=Deployment count=3
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"level\":\"INFO\" ]]
    [[ "$output" =~ \"event\":\"scan-summary\" ]]
    [[ "$output" =~ \"kind\":\"Deployment\" ]]
    [[ "$output" =~ \"count\":\"3\" ]]
}

@test "log_debug: hidden at default (info) level" {
    run emit log_debug some-event k=v
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "log_debug: visible at debug level" {
    KEELSON_LOG_LEVEL=debug run emit log_debug some-event k=v
    [ "$status" -eq 0 ]
    [[ "$output" =~ DEBUG ]]
}

@test "log_info: hidden at warn level" {
    KEELSON_LOG_LEVEL=warn run emit log_info some-event
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "log_error: visible at error level" {
    KEELSON_LOG_LEVEL=error run emit log_error oh-no k=v
    [ "$status" -eq 0 ]
    [[ "$output" =~ ERROR ]]
}

@test "log_info: timestamp prefix is ISO8601 UTC" {
    run emit log_info boot
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z[[:space:]] ]]
}

@test "log_info json: JSON escapes embedded quotes" {
    KEELSON_LOG_FORMAT=json run emit log_info evt note='say "hi"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"note":"say \"hi\""'* ]]
}

@test "log_info: emits to stderr, not stdout" {
    output=$(log_info evt 2>/dev/null)
    [ -z "$output" ]
}

# --- rate limiting ---

@test "rate limit: second emit of same level+event+args inside interval is suppressed" {
    KEELSON_LOG_INFO_REPEAT_INTERVAL=600
    log_info evt k=v 2>"$TMP_DIR/a.err"
    log_info evt k=v 2>"$TMP_DIR/b.err"
    grep -q "evt" "$TMP_DIR/a.err"
    [ ! -s "$TMP_DIR/b.err" ]
}

@test "rate limit: different event hashes are tracked independently" {
    KEELSON_LOG_INFO_REPEAT_INTERVAL=600
    log_info evt-one  k=v 2>"$TMP_DIR/a.err"
    log_info evt-two  k=v 2>"$TMP_DIR/b.err"
    grep -q "evt-one" "$TMP_DIR/a.err"
    grep -q "evt-two" "$TMP_DIR/b.err"
}

@test "rate limit: different kv args produce different hashes" {
    KEELSON_LOG_INFO_REPEAT_INTERVAL=600
    log_info evt k=one 2>"$TMP_DIR/a.err"
    log_info evt k=two 2>"$TMP_DIR/b.err"
    grep -q "k=one" "$TMP_DIR/a.err"
    grep -q "k=two" "$TMP_DIR/b.err"
}

@test "rate limit: argument order does not affect the hash" {
    KEELSON_LOG_INFO_REPEAT_INTERVAL=600
    log_info evt a=1 b=2 2>"$TMP_DIR/a.err"
    log_info evt b=2 a=1 2>"$TMP_DIR/b.err"
    grep -q "evt" "$TMP_DIR/a.err"
    [ ! -s "$TMP_DIR/b.err" ]
}

@test "rate limit: interval 0 means never throttle" {
    KEELSON_LOG_INFO_REPEAT_INTERVAL=0
    log_info evt k=v 2>"$TMP_DIR/a.err"
    log_info evt k=v 2>"$TMP_DIR/b.err"
    grep -q "evt" "$TMP_DIR/a.err"
    grep -q "evt" "$TMP_DIR/b.err"
}

@test "rate limit: each level has its own interval" {
    KEELSON_LOG_LEVEL=debug
    KEELSON_LOG_INFO_REPEAT_INTERVAL=600
    KEELSON_LOG_ERROR_REPEAT_INTERVAL=0
    log_info  evt k=v 2>"$TMP_DIR/i1.err"
    log_info  evt k=v 2>"$TMP_DIR/i2.err"
    log_error evt k=v 2>"$TMP_DIR/e1.err"
    log_error evt k=v 2>"$TMP_DIR/e2.err"
    grep -q evt "$TMP_DIR/i1.err"
    [ ! -s "$TMP_DIR/i2.err" ]
    grep -q evt "$TMP_DIR/e1.err"
    grep -q evt "$TMP_DIR/e2.err"
}

# --- _always variants bypass the rate limiter ---

@test "_always bypasses the rate limiter even at long intervals" {
    KEELSON_LOG_INFO_REPEAT_INTERVAL=600
    log_info_always evt k=v 2>"$TMP_DIR/a.err"
    log_info_always evt k=v 2>"$TMP_DIR/b.err"
    grep -q "evt" "$TMP_DIR/a.err"
    grep -q "evt" "$TMP_DIR/b.err"
}

@test "_always still honors KEELSON_LOG_LEVEL (debug_always hidden at info)" {
    run emit log_debug_always evt k=v
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- file channel ---

@test "file channel: always writes regardless of stdout level" {
    KEELSON_LOG_LEVEL=error
    log_debug some-event k=v 2>/dev/null
    [ -f "$KEELSON_LOG_FILE_PATH" ]
    grep -q "some-event" "$KEELSON_LOG_FILE_PATH"
    grep -q "DEBUG" "$KEELSON_LOG_FILE_PATH"
}

@test "file channel: writes even when rate-limited on stdout" {
    KEELSON_LOG_INFO_REPEAT_INTERVAL=600
    log_info evt k=v 2>/dev/null
    log_info evt k=v 2>/dev/null
    # File channel sees both, stdout sees only the first.
    [ "$(grep -c evt "$KEELSON_LOG_FILE_PATH")" = "2" ]
}

@test "file channel: format is plain even when stdout is JSON" {
    KEELSON_LOG_FORMAT=json
    log_info evt k=v 2>/dev/null
    grep -q "INFO evt k=v" "$KEELSON_LOG_FILE_PATH"
}

@test "file channel: write failure does not break the caller" {
    # Point at a path whose parent is a file, so mkdir -p fails silently.
    : > "$TMP_DIR/blocker"
    KEELSON_LOG_FILE_PATH="$TMP_DIR/blocker/keelson.log"
    run emit log_info evt k=v
    [ "$status" -eq 0 ]
    [[ "$output" =~ evt ]]
}

# --- msg= field: plain renders the sentence, JSON keeps structure ---

@test "msg field: plain drops event and other fields, emits only the sentence" {
    run emit log_info_always update-applied \
        kind=Deployment ns=default name=app \
        msg="Deployment 'app' in 'default' updated from 1.2.3 to 1.2.4 for image 'ghcr.io/x/y'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ INFO\ Deployment\ \'app\'\ in\ \'default\'\ updated\ from\ 1.2.3\ to\ 1.2.4\ for\ image\ \'ghcr.io/x/y\' ]]
    [[ "$output" != *"update-applied"* ]]
    [[ "$output" != *"kind=Deployment"* ]]
    [[ "$output" != *"msg="* ]]
}

@test "msg field: JSON keeps event and every k=v including msg" {
    KEELSON_LOG_FORMAT=json run emit log_info_always update-applied \
        kind=Deployment ns=default name=app \
        msg="Deployment 'app' in 'default' updated from 1.2.3 to 1.2.4 for image 'ghcr.io/x/y'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"event":"update-applied"'* ]]
    [[ "$output" == *'"kind":"Deployment"'* ]]
    [[ "$output" == *'"name":"app"'* ]]
    [[ "$output" == *'"msg":"Deployment '\''app'\'' in '\''default'\'' updated from 1.2.3 to 1.2.4 for image '\''ghcr.io/x/y'\''"'* ]]
}

@test "msg field: file channel writes the sentence (plain mirror of stdout)" {
    log_info_always update-applied kind=Deployment msg="hello world" 2>/dev/null
    grep -q "INFO hello world" "$KEELSON_LOG_FILE_PATH"
    ! grep -q "update-applied" "$KEELSON_LOG_FILE_PATH"
}

# --- rotation ---

@test "rotation: oversize file rotates to .1 before append" {
    KEELSON_LOG_FILE_MAX_BYTES=10
    KEELSON_LOG_FILE_KEEP=3
    # Seed with content > max.
    mkdir -p "$(dirname "$KEELSON_LOG_FILE_PATH")"
    printf 'XXXXXXXXXXXXXXXXXXXX\n' > "$KEELSON_LOG_FILE_PATH"
    log_info evt k=v 2>/dev/null
    [ -f "$KEELSON_LOG_FILE_PATH.1" ]
    grep -q "XXXX" "$KEELSON_LOG_FILE_PATH.1"
    grep -q "evt" "$KEELSON_LOG_FILE_PATH"
}

@test "rotation: cascades .1 -> .2 -> .3 and drops past keep" {
    KEELSON_LOG_FILE_MAX_BYTES=10
    KEELSON_LOG_FILE_KEEP=2
    mkdir -p "$(dirname "$KEELSON_LOG_FILE_PATH")"
    printf 'one\n' > "$KEELSON_LOG_FILE_PATH.1"
    printf 'two\n' > "$KEELSON_LOG_FILE_PATH.2"
    printf 'XXXXXXXXXXXXXXXXXXXX\n' > "$KEELSON_LOG_FILE_PATH"
    log_info evt k=v 2>/dev/null
    # After rotation: current = new, .1 = old current (oversize), .2 = previous .1
    grep -q "evt" "$KEELSON_LOG_FILE_PATH"
    grep -q "XXXX" "$KEELSON_LOG_FILE_PATH.1"
    grep -q "one"  "$KEELSON_LOG_FILE_PATH.2"
    # KEEP=2 means .3 should not exist after the cascade.
    [ ! -f "$KEELSON_LOG_FILE_PATH.3" ]
}

@test "rotation: under-size file is NOT rotated" {
    KEELSON_LOG_FILE_MAX_BYTES=10000
    mkdir -p "$(dirname "$KEELSON_LOG_FILE_PATH")"
    printf 'small\n' > "$KEELSON_LOG_FILE_PATH"
    log_info evt k=v 2>/dev/null
    [ ! -f "$KEELSON_LOG_FILE_PATH.1" ]
    grep -q "small" "$KEELSON_LOG_FILE_PATH"
    grep -q "evt"   "$KEELSON_LOG_FILE_PATH"
}
