#!/usr/bin/env bash
# Logging primitives for Keelson. Source-only - do not execute.
#
# Two channels per emission:
#   stdout/stderr — filtered by KEELSON_LOG_LEVEL and by per-level rate limit.
#   File          — /keelson/work/log/keelson.log, plain, every emission, no
#                   throttle, size-rotated. The verbose verification trail.
#
# Configuration via env (all required, validated at boot):
#   KEELSON_LOG_FORMAT                   plain | json
#   KEELSON_LOG_LEVEL                    debug | info | warn | error
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

KEELSON_LOG_FILE_PATH=${KEELSON_LOG_FILE_PATH:-/keelson/work/log/keelson.log}

declare -gA LOG_THROTTLE_LAST=()

log_level_num() {
    case "$1" in
        debug) printf '0' ;;
        info)  printf '1' ;;
        warn)  printf '2' ;;
        error) printf '3' ;;
        *)     printf '1' ;;
    esac
}

log_should_emit_stdout() {
    local lvl_num threshold
    lvl_num=$(log_level_num "$1")
    threshold=$(log_level_num "${KEELSON_LOG_LEVEL:-info}")
    [ "$lvl_num" -ge "$threshold" ]
}

log_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# log_throttle_interval <level>
# Echoes the configured repeat-interval (seconds) for <level>. 0 means never
# throttle. Missing var also means 0 so older deploys don't break.
log_throttle_interval() {
    case "$1" in
        debug) printf '%s' "${KEELSON_LOG_DEBUG_REPEAT_INTERVAL:-0}" ;;
        info)  printf '%s' "${KEELSON_LOG_INFO_REPEAT_INTERVAL:-0}" ;;
        warn)  printf '%s' "${KEELSON_LOG_WARN_REPEAT_INTERVAL:-0}" ;;
        error) printf '%s' "${KEELSON_LOG_ERROR_REPEAT_INTERVAL:-0}" ;;
        *)     printf '0' ;;
    esac
}

# log_throttle_hash <level> <event> <kv...>
# Stable identity for the rate limiter: level + event + sorted kv pairs.
# Sorting keeps order-of-arguments from creating spurious cache misses.
log_throttle_hash() {
    local level=$1 event=$2; shift 2
    local pairs
    pairs=$(printf '%s\n' "$@" | sort | tr '\n' '|')
    printf '%s|%s|%s' "$level" "$event" "$pairs"
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
            printf '%s %s %s\n' "$ts" "$level" "${pair#msg=}"
            return
        fi
    done
    local line="$ts $level $event"
    for pair in "$@"; do
        line+=" $pair"
    done
    printf '%s\n' "$line"
}

# log_render_json <ts> <LEVEL> <event> <kv...>
log_render_json() {
    local ts=$1 level=$2 event=$3; shift 3
    local out k v pair
    out='{"ts":"'$ts'","level":"'$level'","event":"'$(log_json_escape "$event")'"'
    for pair in "$@"; do
        k=${pair%%=*}
        v=${pair#*=}
        out+=',"'$(log_json_escape "$k")'":"'$(log_json_escape "$v")'"'
    done
    out+='}'
    printf '%s\n' "$out"
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

# log_file_write <plain-line>
# Append to the rotated file. Always plain format. Always emits regardless
# of stdout level or throttle. Best-effort: a write failure here must not
# break the caller.
log_file_write() {
    local line=$1
    local max=${KEELSON_LOG_FILE_MAX_BYTES:-10485760}
    local dir
    dir=$(dirname "$KEELSON_LOG_FILE_PATH")
    mkdir -p "$dir" 2>/dev/null || return 0

    if [ -f "$KEELSON_LOG_FILE_PATH" ]; then
        local size
        size=$(wc -c <"$KEELSON_LOG_FILE_PATH" 2>/dev/null || printf '0')
        if [ "$size" -ge "$max" ]; then
            log_file_rotate
        fi
    fi
    printf '%s' "$line" >> "$KEELSON_LOG_FILE_PATH" 2>/dev/null || true
}

# log_emit <level> <throttle: 0|1> <event> [k=v ...]
# The one path every log_* function funnels through.
log_emit() {
    local level=$1 throttle=$2 event=$3
    shift 3

    local ts level_uc
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    level_uc=$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')

    local plain_line
    plain_line=$(log_render_plain "$ts" "$level_uc" "$event" "$@")

    # File channel: always, regardless of stdout level or throttle.
    log_file_write "$plain_line"$'\n'

    # Stdout channel: filtered by level, then by throttle.
    log_should_emit_stdout "$level" || return 0

    if [ "$throttle" = "1" ]; then
        local interval now hash last
        interval=$(log_throttle_interval "$level")
        if [ "$interval" -gt 0 ]; then
            now=$(date -u +%s)
            hash=$(log_throttle_hash "$level" "$event" "$@")
            last=${LOG_THROTTLE_LAST[$hash]:-0}
            if [ $(( now - last )) -lt "$interval" ]; then
                return 0
            fi
            LOG_THROTTLE_LAST[$hash]=$now
        fi
    fi

    local out
    if [ "${KEELSON_LOG_FORMAT:-plain}" = "json" ]; then
        out=$(log_render_json "$ts" "$level_uc" "$event" "$@")
    else
        out=$plain_line
    fi
    # Logs go to stderr so pure functions can use stdout for return values
    # (annotation_get etc.) without their callers having to disentangle the two.
    printf '%s\n' "$out" >&2
}

log_debug()        { log_emit debug 1 "$@"; }
log_info()         { log_emit info  1 "$@"; }
log_warn()         { log_emit warn  1 "$@"; }
log_error()        { log_emit error 1 "$@"; }

log_debug_always() { log_emit debug 0 "$@"; }
log_info_always()  { log_emit info  0 "$@"; }
log_warn_always()  { log_emit warn  0 "$@"; }
log_error_always() { log_emit error 0 "$@"; }
