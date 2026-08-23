#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# Logging primitives for Keelson. Source-only - do not execute.
#
# Two channels per emission:
#   stdout/stderr — filtered by KEELSON_LOG_LEVEL and by per-level rate limit.
#   File          — /keelson/work/log/keelson.log, plain, every emission, no
#                   throttle, size-rotated. The verbose verification trail.
#
# Configuration via env (all required, validated at boot):
#   KEELSON_LOG_FORMAT                   plain | json
#   KEELSON_LOG_LEVEL                    DEBUG | INFO | WARN | ERROR
#   KEELSON_LOG_DEBUG_REPEAT_INTERVAL    seconds; 0 = never throttle
#   KEELSON_LOG_INFO_REPEAT_INTERVAL     seconds; 0 = never throttle
#   KEELSON_LOG_WARN_REPEAT_INTERVAL     seconds; 0 = never throttle
#   KEELSON_LOG_ERROR_REPEAT_INTERVAL    seconds; 0 = never throttle
#   KEELSON_LOG_FILE_MAX_BYTES           rotate the file when it grows past this
#   KEELSON_LOG_FILE_KEEP                number of rotated files to retain
#
# Public API:
#   log_debug  <event> [k=v ...]   throttled per KEELSON_LOG_DEBUG_REPEAT_INTERVAL
#   log_info   <event> [k=v ...]   throttled per KEELSON_LOG_INFO_REPEAT_INTERVAL
#   log_warn   <event> [k=v ...]   throttled per KEELSON_LOG_WARN_REPEAT_INTERVAL
#   log_error  <event> [k=v ...]   throttled per KEELSON_LOG_ERROR_REPEAT_INTERVAL
#
#   log_debug_always <event> [k=v ...]   bypass the rate limiter
#   log_info_always  <event> [k=v ...]   bypass the rate limiter
#   log_warn_always  <event> [k=v ...]   bypass the rate limiter
#   log_error_always <event> [k=v ...]   bypass the rate limiter
#
# The _always variants are for events that are intrinsically unique per
# occurrence (an applied update, a job we created) - we want every one of
# them logged. If a bug causes them to repeat, the repetition is the signal.
#
# The file log path is convention, not configuration:
#   /keelson/work/log/keelson.log         active
#   /keelson/work/log/keelson.log.1..N    rotated, oldest = highest N
#
# Many processes append to that file: the controller loop, one watcher per
# watched kind, and every backgrounded scan child. Appending concurrently is
# safe; rotating concurrently is not. Rotation therefore has exactly one
# owner, the controller loop, via log_file_rotate_if_needed once per tick.
# A process that only appends never rotates, so the file grows unbounded
# while the controller is not running (one-shot entry points, tests).
#
# keelson-probe writes no file at all. It reads the controller's state; it
# does not author the controller's trail. Its failure message reaches the
# operator as a kubelet event, and on a liveness kill the container restarts
# and takes the emptyDir with it, so a file write would buy nothing while
# costing forks on the one path already closest to its exec timeout.

# Set this to the empty string before sourcing to switch the file channel
# off entirely; keelson-probe does. Note the `-` rather than `:-`: an empty
# value must survive, or a caller that deliberately switched the file off
# would silently get the default path back.
KEELSON_LOG_FILE_PATH=${KEELSON_LOG_FILE_PATH-/keelson/work/log/keelson.log}

declare -gA LOG_THROTTLE_LAST=()

# Results land in globals rather than on stdout. Every one of these is called
# for every log line, and a command substitution forks a subshell each time:
# eight or so processes per line, before the level filter has even decided
# whether the line will be printed. loop_drain_queue pays that per queue item.
LOG_LEVEL_NUM=0
LOG_LINE=
LOG_ESCAPED=
LOG_THROTTLE_INTERVAL=0
LOG_THROTTLE_HASH=

# log_level_num <level>  -> LOG_LEVEL_NUM
log_level_num() {
    case "$1" in
        DEBUG) LOG_LEVEL_NUM=0 ;;
        INFO)  LOG_LEVEL_NUM=1 ;;
        WARN)  LOG_LEVEL_NUM=2 ;;
        ERROR) LOG_LEVEL_NUM=3 ;;
        *)     LOG_LEVEL_NUM=1 ;;
    esac
}

log_should_emit_stdout() {
    local lvl_num
    log_level_num "$1"
    lvl_num=$LOG_LEVEL_NUM
    log_level_num "${KEELSON_LOG_LEVEL:-INFO}"
    [ "$lvl_num" -ge "$LOG_LEVEL_NUM" ]
}

# log_json_escape <string>  -> LOG_ESCAPED
log_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    # A raw control character inside a JSON string is invalid, and callers
    # that flatten first are the tidy answer rather than the safe one: the
    # one who forgets emits a line no parser will take. Guarded so text
    # without any pays a single test, and run after the backslash pass so
    # the backslashes inserted here stay single.
    case "$s" in
        *[$'\n\r\t']*)
            s=${s//$'\n'/\\n}
            s=${s//$'\r'/\\r}
            s=${s//$'\t'/\\t}
            ;;
    esac
    LOG_ESCAPED=$s
}

# How much of a tool's output may ride along in an info, warn or error line.
# Small on purpose: the line has to stay readable in a terminal, and the whole
# of it is one level down.
LOG_HINT_MAX=40
LOG_FLAT=
LOG_HINT=

# log_flatten <text>  -> LOG_FLAT
# One line, single-spaced. An event is a line, and a blob spread over several
# is one to read rather than to grep. log_json_escape will turn a stray
# newline into \n rather than emit invalid JSON, so this is about the shape of
# the line, not its validity.
log_flatten() {
    local s=$1
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'\t'/ }
    while [ "${s}" != "${s//  / }" ]; do
        s=${s//  / }
    done
    LOG_FLAT=$s
}

# log_hint <text>  -> LOG_HINT
# Flattened and clipped to LOG_HINT_MAX. Enough of a tool's output to
# recognise what happened, never enough to bury the line carrying it.
#
# Every caller pairs this with a log_debug of the whole text, emitted
# immediately before. kubectl answers a jsonpath failure with the entire
# offending object in Go syntax, and a rejected server-side apply can run to
# paragraphs; either one pasted into a warn costs you the rest of the log.
log_hint() {
    log_flatten "$1"
    if [ "${#LOG_FLAT}" -gt "$LOG_HINT_MAX" ]; then
        LOG_HINT="${LOG_FLAT:0:$LOG_HINT_MAX}..."
    else
        LOG_HINT=$LOG_FLAT
    fi
}

# log_throttle_interval <level>  -> LOG_THROTTLE_INTERVAL
# The configured repeat-interval (seconds) for <level>. 0 means never
# throttle. Missing var also means 0 so older deploys don't break.
log_throttle_interval() {
    case "$1" in
        DEBUG) LOG_THROTTLE_INTERVAL=${KEELSON_LOG_DEBUG_REPEAT_INTERVAL:-0} ;;
        INFO)  LOG_THROTTLE_INTERVAL=${KEELSON_LOG_INFO_REPEAT_INTERVAL:-0} ;;
        WARN)  LOG_THROTTLE_INTERVAL=${KEELSON_LOG_WARN_REPEAT_INTERVAL:-0} ;;
        ERROR) LOG_THROTTLE_INTERVAL=${KEELSON_LOG_ERROR_REPEAT_INTERVAL:-0} ;;
        *)     LOG_THROTTLE_INTERVAL=0 ;;
    esac
}

# log_throttle_hash <level> <event> <kv...>  -> LOG_THROTTLE_HASH
# Stable identity for the rate limiter: level + event + sorted kv pairs.
# Sorting keeps order-of-arguments from creating spurious cache misses.
#
# Insertion sort rather than a pipe to sort(1). The key only has to be
# consistent within this process, never to match anything on disk, and the
# pipeline cost four process creations on every throttled line. Callers pass
# a handful of pairs, so the quadratic comparison count stays far below what
# one fork costs. LC_ALL=C is enforced at boot, so > collates bytewise.
log_throttle_hash() {
    local level=$1 event=$2; shift 2
    local -a pairs=("$@")
    local i j held
    for ((i = 1; i < ${#pairs[@]}; i++)); do
        held=${pairs[i]}
        j=$((i - 1))
        # [[ ]] and not (( )): these are strings, and an arithmetic context
        # reads "a=1 > b=2" as an assignment.
        while [ "$j" -ge 0 ] && [[ ${pairs[j]} > $held ]]; do
            pairs[j + 1]=${pairs[j]}
            j=$((j - 1))
        done
        pairs[j + 1]=$held
    done
    LOG_THROTTLE_HASH="$level|$event|"
    for held in ${pairs[@]+"${pairs[@]}"}; do
        LOG_THROTTLE_HASH+="$held|"
    done
}

# log_render_plain <ts> <LEVEL> <event> <kv...>
# If a `msg=<value>` kv is present, render `<ts> LEVEL <value>` and drop the
# event tag and all other fields — the sentence is the line. JSON output is
# unaffected, so structured pipelines keep every field.
log_render_plain() {
    local ts=$1 level=$2 event=$3; shift 3
    local pair
    for pair in "$@"; do
        if [[ "$pair" == msg=* ]]; then
            LOG_LINE="$ts $level ${pair#msg=}"
            return
        fi
    done
    LOG_LINE="$ts $level $event"
    for pair in "$@"; do
        LOG_LINE+=" $pair"
    done
}

# log_render_json <ts> <LEVEL> <event> <kv...>
log_render_json() {
    local ts=$1 level=$2 event=$3; shift 3
    local out k v pair
    log_json_escape "$event"
    out='{"ts":"'$ts'","level":"'$level'","event":"'$LOG_ESCAPED'"'
    for pair in "$@"; do
        k=${pair%%=*}
        v=${pair#*=}
        log_json_escape "$k"; k=$LOG_ESCAPED
        log_json_escape "$v"; v=$LOG_ESCAPED
        out+=',"'$k'":"'$v'"'
    done
    out+='}'
    LOG_LINE=$out
}

# log_file_rotate
# Move keelson.log -> keelson.log.1, keelson.log.1 -> keelson.log.2, etc.
# Drops anything past KEELSON_LOG_FILE_KEEP.
log_file_rotate() {
    local keep=${KEELSON_LOG_FILE_KEEP:-5}
    local base=$KEELSON_LOG_FILE_PATH
    local i
    for (( i = keep - 1; i >= 1; i-- )); do
        [ -f "$base.$i" ] && mv -f "$base.$i" "$base.$((i+1))" 2>/dev/null || true
    done
    [ -f "$base" ] && mv -f "$base" "$base.1" 2>/dev/null || true
    # Drop anything past keep.
    local stale
    for stale in "$base".*; do
        case "$stale" in
            "$base.[0-9]"|"$base.[0-9][0-9]")
                local n=${stale##*.}
                [ "$n" -gt "$keep" ] && rm -f "$stale"
                ;;
        esac
    done
    return 0
}

# log_file_rotate_if_needed
# Rotate when the active file has grown past KEELSON_LOG_FILE_MAX_BYTES.
#
# THE ONLY CALLER IS THE CONTROLLER LOOP, once per tick. Do not call this
# from the write path: see the note above log_file_write.
log_file_rotate_if_needed() {
    local max=${KEELSON_LOG_FILE_MAX_BYTES:-10485760}
    [ -f "$KEELSON_LOG_FILE_PATH" ] || return 0
    local size
    size=$(wc -c <"$KEELSON_LOG_FILE_PATH" 2>/dev/null || printf '0')
    [ "$size" -ge "$max" ] || return 0
    log_file_rotate
}

# log_file_write <plain-line>
# Append to the log file. Always plain format. Always emits regardless of
# stdout level or throttle. Best-effort: a write failure here must not break
# the caller.
#
# Appends only. This runs in every process that logs, and there are many:
# the controller loop, one watcher per watched kind, and each backgrounded
# scan child. Concurrent appends are safe (the fd is O_APPEND and a line is
# one short write), but the rename shuffle in log_file_rotate is not: two
# processes running it at once lose or duplicate rotated files. So rotation
# is not decided here. It has a single owner, the controller loop, which
# calls log_file_rotate_if_needed once per tick.
log_file_write() {
    local line=$1
    [ -n "$KEELSON_LOG_FILE_PATH" ] || return 0
    # stderr is silenced before the append, not after: bash applies
    # redirections left to right, so a failing >> reports itself to whatever
    # stderr is at that point. The file channel must never contaminate the
    # console it is a copy of.
    printf '%s' "$line" 2>/dev/null >> "$KEELSON_LOG_FILE_PATH" || true
}

# log_file_init
# Creates the log directory. Called once at startup by every entry point that
# logs, so log_file_write never has to: it lives on the Pod's emptyDir for the
# life of the Pod, and checking per line cost a fork on a path that cannot
# change.
log_file_init() {
    [ -n "$KEELSON_LOG_FILE_PATH" ] || return 0
    local dir=${KEELSON_LOG_FILE_PATH%/*}
    [ "$dir" = "$KEELSON_LOG_FILE_PATH" ] && return 0
    mkdir -p "$dir" 2>/dev/null || return 0
}

# log_emit <level> <throttle: 0|1> <event> [k=v ...]
# The one path every log_* function funnels through.
log_emit() {
    local level=$1 throttle=$2 event=$3
    shift 3

    local ts
    # Built-in time formatting rather than a date fork on every line. The Z is
    # literal because the image sets TZ=UTC, which validate_config enforces.
    printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1

    # Copied out of the shared global: log_render_json overwrites LOG_LINE,
    # and the plain line is still needed after it for the non-JSON branch.
    local plain_line
    log_render_plain "$ts" "$level" "$event" "$@"
    plain_line=$LOG_LINE

    # File channel: always, regardless of stdout level or throttle.
    log_file_write "$plain_line"$'\n'

    # Stdout channel: filtered by level, then by throttle.
    log_should_emit_stdout "$level" || return 0

    if [ "$throttle" = "1" ]; then
        local now last
        log_throttle_interval "$level"
        if [ "$LOG_THROTTLE_INTERVAL" -gt 0 ]; then
            printf -v now '%(%s)T' -1
            log_throttle_hash "$level" "$event" "$@"
            last=${LOG_THROTTLE_LAST[$LOG_THROTTLE_HASH]:-0}
            if [ $(( now - last )) -lt "$LOG_THROTTLE_INTERVAL" ]; then
                return 0
            fi
            LOG_THROTTLE_LAST[$LOG_THROTTLE_HASH]=$now
        fi
    fi

    if [ "${KEELSON_LOG_FORMAT:-plain}" = "json" ]; then
        log_render_json "$ts" "$level" "$event" "$@"
    else
        LOG_LINE=$plain_line
    fi
    # Logs go to stderr so pure functions can use stdout for return values
    # (annotation_get etc.) without their callers having to disentangle the two.
    printf '%s\n' "$LOG_LINE" >&2
}

log_debug()        { log_emit DEBUG 1 "$@"; }
log_info()         { log_emit INFO  1 "$@"; }
log_warn()         { log_emit WARN  1 "$@"; }
log_error()        { log_emit ERROR 1 "$@"; }

log_debug_always() { log_emit DEBUG 0 "$@"; }
log_info_always()  { log_emit INFO  0 "$@"; }
log_warn_always()  { log_emit WARN  0 "$@"; }
log_error_always() { log_emit ERROR 0 "$@"; }
