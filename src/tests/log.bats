#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

load helper

setup() {
    tmp_dir_init
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
    KEELSON_LOG_LEVEL=DEBUG run emit log_debug some-event k=v
    [ "$status" -eq 0 ]
    [[ "$output" =~ DEBUG ]]
}

@test "log_info: hidden at warn level" {
    KEELSON_LOG_LEVEL=WARN run emit log_info some-event
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "log_error: visible at error level" {
    KEELSON_LOG_LEVEL=ERROR run emit log_error oh-no k=v
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
    KEELSON_LOG_LEVEL=DEBUG
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
    KEELSON_LOG_LEVEL=ERROR
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

# --- the file channel can be switched off ---

@test "file channel: an empty path writes no file at all" {
    KEELSON_LOG_FILE_PATH=
    log_info evt k=v 2>/dev/null
    [ -z "$(find "$TMP_DIR" -type f)" ]
}

@test "file channel: an empty path still emits on stderr" {
    KEELSON_LOG_FILE_PATH=
    run emit log_error evt k=v
    [[ "$output" == *"evt"* ]]
}

@test "file channel: an empty path survives sourcing" {
    # :- would treat empty as unset and hand back the default path, which
    # would silently re-enable the file for a caller that switched it off.
    KEELSON_LOG_FILE_PATH= bash -c '
        KEELSON_LOG_FILE_PATH=
        source "'"$SCRIPT_DIR"'/lib/log.bash"
        [ -z "$KEELSON_LOG_FILE_PATH" ]
    '
}

# --- rotation ---
#
# Appending is safe from any number of processes; the mv-shuffle is not.
# Rotation therefore has one owner (the controller loop) and never happens
# on the write path, which every watcher and scan child also runs.

@test "rotation: writing does NOT rotate, however oversize the file is" {
    KEELSON_LOG_FILE_MAX_BYTES=10
    KEELSON_LOG_FILE_KEEP=3
    mkdir -p "$(dirname "$KEELSON_LOG_FILE_PATH")"
    printf 'XXXXXXXXXXXXXXXXXXXX\n' > "$KEELSON_LOG_FILE_PATH"
    log_info evt k=v 2>/dev/null
    [ ! -f "$KEELSON_LOG_FILE_PATH.1" ]
    # The line still lands, it just lands in the current file.
    grep -q "XXXX" "$KEELSON_LOG_FILE_PATH"
    grep -q "evt" "$KEELSON_LOG_FILE_PATH"
}

@test "rotate_if_needed: oversize file rotates to .1" {
    KEELSON_LOG_FILE_MAX_BYTES=10
    KEELSON_LOG_FILE_KEEP=3
    mkdir -p "$(dirname "$KEELSON_LOG_FILE_PATH")"
    printf 'XXXXXXXXXXXXXXXXXXXX\n' > "$KEELSON_LOG_FILE_PATH"
    log_file_rotate_if_needed
    [ -f "$KEELSON_LOG_FILE_PATH.1" ]
    grep -q "XXXX" "$KEELSON_LOG_FILE_PATH.1"
    [ ! -s "$KEELSON_LOG_FILE_PATH" ] || [ ! -f "$KEELSON_LOG_FILE_PATH" ]
}

@test "rotate_if_needed: cascades .1 -> .2 -> .3 and drops past keep" {
    KEELSON_LOG_FILE_MAX_BYTES=10
    KEELSON_LOG_FILE_KEEP=2
    mkdir -p "$(dirname "$KEELSON_LOG_FILE_PATH")"
    printf 'one\n' > "$KEELSON_LOG_FILE_PATH.1"
    printf 'two\n' > "$KEELSON_LOG_FILE_PATH.2"
    printf 'XXXXXXXXXXXXXXXXXXXX\n' > "$KEELSON_LOG_FILE_PATH"
    log_file_rotate_if_needed
    grep -q "XXXX" "$KEELSON_LOG_FILE_PATH.1"
    grep -q "one"  "$KEELSON_LOG_FILE_PATH.2"
    [ ! -f "$KEELSON_LOG_FILE_PATH.3" ]
}

@test "rotate_if_needed: under-size file is NOT rotated" {
    KEELSON_LOG_FILE_MAX_BYTES=10000
    mkdir -p "$(dirname "$KEELSON_LOG_FILE_PATH")"
    printf 'small\n' > "$KEELSON_LOG_FILE_PATH"
    log_file_rotate_if_needed
    [ ! -f "$KEELSON_LOG_FILE_PATH.1" ]
    grep -q "small" "$KEELSON_LOG_FILE_PATH"
}

@test "rotate_if_needed: missing file is a no-op and succeeds" {
    KEELSON_LOG_FILE_MAX_BYTES=10
    run log_file_rotate_if_needed
    [ "$status" -eq 0 ]
    [ ! -f "$KEELSON_LOG_FILE_PATH.1" ]
}

@test "rotate_if_needed: appends after rotation land in the fresh file" {
    KEELSON_LOG_FILE_MAX_BYTES=10
    KEELSON_LOG_FILE_KEEP=3
    mkdir -p "$(dirname "$KEELSON_LOG_FILE_PATH")"
    printf 'XXXXXXXXXXXXXXXXXXXX\n' > "$KEELSON_LOG_FILE_PATH"
    log_file_rotate_if_needed
    log_info evt k=v 2>/dev/null
    grep -q "evt" "$KEELSON_LOG_FILE_PATH"
    ! grep -q "XXXX" "$KEELSON_LOG_FILE_PATH"
}

# --- flatten and hint: what a tool's output may cost a log line ---

@test "flatten: newlines, tabs and carriage returns become single spaces" {
    log_flatten "$(printf 'one\ntwo\tthree\r\nfour')"
    [ "$LOG_FLAT" = "one two three four" ]
}

@test "flatten: runs of spaces are squeezed" {
    log_flatten "a     b"
    [ "$LOG_FLAT" = "a b" ]
}

@test "flatten: leaves an already-flat string alone" {
    log_flatten "already flat"
    [ "$LOG_FLAT" = "already flat" ]
}

@test "flatten: empty in, empty out" {
    log_flatten ""
    [ -z "$LOG_FLAT" ]
}

@test "hint: a short string is passed through whole, no ellipsis" {
    log_hint "connection refused"
    [ "$LOG_HINT" = "connection refused" ]
}

@test "hint: a long string is clipped to LOG_HINT_MAX plus an ellipsis" {
    log_hint "$(printf 'x%.0s' {1..500})"
    [ "${#LOG_HINT}" -eq $(( LOG_HINT_MAX + 3 )) ]
    [[ "$LOG_HINT" == *"..." ]]
}

@test "hint: a multi-line blob is flattened before it is clipped" {
    # log_json_escape would keep the JSON valid either way; flattening is
    # what keeps the clip from spending its budget on a line break.
    log_hint "$(printf 'first\nsecond\tthird\n')"
    [[ "$LOG_HINT" != *$'\n'* ]]
    [[ "$LOG_HINT" != *$'\t'* ]]
}

@test "hint: JSON output stays one valid line for a multi-line blob" {
    KEELSON_LOG_FORMAT=json
    log_hint "$(printf 'a\nb\nc')"
    run emit log_error evt detail="$LOG_HINT"
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    [[ "$output" == *'"detail":"a b c"'* ]]
}

# --- the file channel is on every log line's path ---

@test "file channel: writing a line forks nothing" {
    # The directory is on the Pod's emptyDir for the life of the Pod, so
    # checking for it per line cost two forks on a path that cannot change.
    local mkdirs=0 dirnames=0
    mkdir() { mkdirs=$(( mkdirs + 1 )); command mkdir "$@"; }
    dirname() { dirnames=$(( dirnames + 1 )); command dirname "$@"; }

    log_info one k=v 2>/dev/null
    log_info two k=v 2>/dev/null
    log_info three k=v 2>/dev/null

    unset -f mkdir dirname
    [ "$mkdirs" -eq 0 ]
    [ "$dirnames" -eq 0 ]
    [ "$(grep -c . "$KEELSON_LOG_FILE_PATH")" = "3" ]
}

@test "file_init: creates the log directory" {
    KEELSON_LOG_FILE_PATH="$TMP_DIR/fresh/keelson.log"
    log_file_init
    [ -d "$TMP_DIR/fresh" ]
}

@test "file_init: an empty path creates nothing" {
    KEELSON_LOG_FILE_PATH=
    run log_file_init
    [ "$status" -eq 0 ]
}

# --- throttle helpers ---
#
# Both land in globals: they run on every emitted line, and a command
# substitution forks a subshell before the line is even known to be wanted.

@test "throttle interval: each level reads its own variable" {
    KEELSON_LOG_DEBUG_REPEAT_INTERVAL=1 KEELSON_LOG_INFO_REPEAT_INTERVAL=2 \
    KEELSON_LOG_WARN_REPEAT_INTERVAL=3 KEELSON_LOG_ERROR_REPEAT_INTERVAL=4 \
    bash -c '
        source "'"${BATS_TEST_DIRNAME}"'/../scripts/lib/log.bash"
        for l in DEBUG INFO WARN ERROR; do
            log_throttle_interval "$l"; printf "%s " "$LOG_THROTTLE_INTERVAL"
        done' > "$BATS_TEST_TMPDIR/out"
    [ "$(cat "$BATS_TEST_TMPDIR/out")" = "1 2 3 4 " ]
}

@test "throttle interval: an unset variable means never throttle" {
    unset KEELSON_LOG_INFO_REPEAT_INTERVAL
    log_throttle_interval INFO
    [ "$LOG_THROTTLE_INTERVAL" = "0" ]
}

@test "throttle interval: an unknown level means never throttle" {
    log_throttle_interval NOPE
    [ "$LOG_THROTTLE_INTERVAL" = "0" ]
}

@test "throttle hash: same level, event and pairs give the same identity" {
    log_throttle_hash INFO ev a=1 b=2
    local first=$LOG_THROTTLE_HASH
    log_throttle_hash INFO ev a=1 b=2
    [ "$LOG_THROTTLE_HASH" = "$first" ]
}

@test "throttle hash: argument order does not change the identity" {
    log_throttle_hash INFO ev a=1 b=2 c=3
    local ordered=$LOG_THROTTLE_HASH
    log_throttle_hash INFO ev c=3 a=1 b=2
    [ "$LOG_THROTTLE_HASH" = "$ordered" ]
    log_throttle_hash INFO ev b=2 c=3 a=1
    [ "$LOG_THROTTLE_HASH" = "$ordered" ]
}

@test "throttle hash: a different level is a different identity" {
    log_throttle_hash INFO ev a=1
    local info=$LOG_THROTTLE_HASH
    log_throttle_hash WARN ev a=1
    [ "$LOG_THROTTLE_HASH" != "$info" ]
}

@test "throttle hash: a different event is a different identity" {
    log_throttle_hash INFO one a=1
    local one=$LOG_THROTTLE_HASH
    log_throttle_hash INFO two a=1
    [ "$LOG_THROTTLE_HASH" != "$one" ]
}

@test "throttle hash: a different value is a different identity" {
    log_throttle_hash INFO ev a=1
    local one=$LOG_THROTTLE_HASH
    log_throttle_hash INFO ev a=2
    [ "$LOG_THROTTLE_HASH" != "$one" ]
}

@test "throttle hash: no pairs at all is still an identity" {
    log_throttle_hash INFO ev
    [ -n "$LOG_THROTTLE_HASH" ]
    log_throttle_hash INFO other
    [ -n "$LOG_THROTTLE_HASH" ]
}

@test "throttle hash: a pair holding a space survives" {
    log_throttle_hash INFO ev 'msg=two words' a=1
    local first=$LOG_THROTTLE_HASH
    log_throttle_hash INFO ev a=1 'msg=two words'
    [ "$LOG_THROTTLE_HASH" = "$first" ]
}

# --- control characters in JSON values ---
#
# Flattening at the call site is the tidy answer, not the safe one: a raw
# newline reaching a JSON value produces a line no parser will take, and the
# only thing stopping that was every author remembering.

@test "json escape: a newline becomes \\n, not a raw break" {
    log_json_escape "$(printf 'a\nb')"
    [ "$LOG_ESCAPED" = 'a\nb' ]
    [[ "$LOG_ESCAPED" != *$'\n'* ]]
}

@test "json escape: a tab becomes \\t" {
    log_json_escape "$(printf 'a\tb')"
    [ "$LOG_ESCAPED" = 'a\tb' ]
}

@test "json escape: a carriage return becomes \\r" {
    log_json_escape "$(printf 'a\rb')"
    [ "$LOG_ESCAPED" = 'a\rb' ]
}

@test "json escape: quotes and backslashes still escape" {
    log_json_escape 'say "hi" c:\path'
    [ "$LOG_ESCAPED" = 'say \"hi\" c:\\path' ]
}

@test "json escape: an escaped newline is not double-escaped" {
    # The backslash pass runs first, so the backslash this inserts must stay
    # single or the value decodes as a literal backslash-n.
    log_json_escape "$(printf 'a\nb')"
    [ "$LOG_ESCAPED" = 'a\nb' ]
    [[ "$LOG_ESCAPED" != *'\\n'* ]]
}

@test "json escape: a literal backslash-n in the input stays literal" {
    log_json_escape 'a\nb'
    [ "$LOG_ESCAPED" = 'a\\nb' ]
}

@test "json escape: plain text is untouched" {
    log_json_escape 'nothing special here'
    [ "$LOG_ESCAPED" = 'nothing special here' ]
}

@test "json output: an unflattened multi-line value stays one valid line" {
    KEELSON_LOG_FORMAT=json
    run emit log_error evt detail="$(printf 'first\nsecond')"
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    [[ "$output" == *'"detail":"first\nsecond"'* ]]
}

@test "json output: an unflattened value with a tab stays one valid line" {
    KEELSON_LOG_FORMAT=json
    run emit log_error evt detail="$(printf 'a\tb')"
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    [[ "$output" == *'"detail":"a\tb"'* ]]
}
