#!/usr/bin/env bash
# Logging primitives for Keelson. Source-only - do not execute.
#
# Configuration via env:
#   KEELSON_LOG_FORMAT   plain (default) | json
#   KEELSON_LOG_LEVEL    debug | info (default) | warn | error
#
# Public API:
#   log_debug <event> [k=v ...]
#   log_info  <event> [k=v ...]
#   log_warn  <event> [k=v ...]
#   log_error <event> [k=v ...]

log_level_num() {
    case "$1" in
        debug) printf '0' ;;
        info)  printf '1' ;;
        warn)  printf '2' ;;
        error) printf '3' ;;
        *)     printf '1' ;;
    esac
}

log_should_emit() {
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

log_emit() {
    local level=$1
    local event=$2
    shift 2
    log_should_emit "$level" || return 0

    local ts level_uc
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    level_uc=$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')

    # Logs go to stderr so pure functions can use stdout for return values
    # (annotation_get etc.) without their callers having to disentangle the two.
    if [ "${KEELSON_LOG_FORMAT:-plain}" = "json" ]; then
        local out k v pair
        out='{"ts":"'$ts'","level":"'$level_uc'","event":"'$(log_json_escape "$event")'"'
        for pair in "$@"; do
            k=${pair%%=*}
            v=${pair#*=}
            out+=',"'$(log_json_escape "$k")'":"'$(log_json_escape "$v")'"'
        done
        out+='}'
        printf '%s\n' "$out" >&2
    else
        local line="$ts $level_uc $event"
        local pair
        for pair in "$@"; do
            line+=" $pair"
        done
        printf '%s\n' "$line" >&2
    fi
}

log_debug() { log_emit debug "$@"; }
log_info()  { log_emit info  "$@"; }
log_warn()  { log_emit warn  "$@"; }
log_error() { log_emit error "$@"; }
