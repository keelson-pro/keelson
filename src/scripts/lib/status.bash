# Pod status files: the heartbeat and the watcher-PID map.
# Sourced; not directly executable.
#
# Two facts, two owners, so two files:
#
#   <dir>/heartbeat   heartbeat=<unix-seconds>   written by the controller loop
#                                                once per tick; that cadence is
#                                                the whole point of it
#   <dir>/watchers    <Kind>=<pid> per line      written by the watcher
#                                                supervisor at the moment it
#                                                changes the map, which is a
#                                                death or a respawn and so
#                                                almost never
#
# One writer per file, many readers (kube exec probes). They were one file
# once, which forced the rarely-changing map to be republished every tick and
# forced both facts to share a single publication point. Splitting them lets
# each be published when its owner knows the value.
#
# keelson-probe reads only what it needs: liveness the heartbeat, readiness
# the map.
#
# Tests override KEELSON_STATUS_DIR by reassigning it after sourcing; every
# path here is resolved at call time. The probe binary inherits the value
# from the kubelet exec env the same way.

KEELSON_STATUS_DIR=${KEELSON_STATUS_DIR:-/keelson/work/status}

declare -gA STATUS_PIDS=()
STATUS_HEARTBEAT_US=0
STATUS_WATCHER_FAILURES=0
STATUS_WATCHER_ERROR=

# status_write_file <path> [<line> ...]
# Atomic via write-then-rename, so a reader never sees a half-written file.
status_write_file() {
    local path=$1; shift
    local tmp="${path}.tmp"
    mkdir -p "${path%/*}"
    if [ "$#" -gt 0 ]; then
        printf '%s\n' "$@" > "$tmp"
    else
        : > "$tmp"
    fi
    mv -f "$tmp" "$path"
}

# status_write_heartbeat <unix-microseconds>
# Microseconds in, decimal seconds on disk: full precision kept, and an
# operator reading the file sees an obvious Unix timestamp.
status_write_heartbeat() {
    clock_format "$1"
    status_write_file "$KEELSON_STATUS_DIR/heartbeat" "heartbeat=$CLOCK_TEXT"
}

# status_write_watchers [<kind=pid> ...]
status_write_watchers() {
    status_write_file "$KEELSON_STATUS_DIR/watchers" "$@"
}

# status_read_heartbeat
# Populates STATUS_HEARTBEAT_US in microseconds (0 if the key is absent).
# Returns 1 if the file is missing.
status_read_heartbeat() {
    STATUS_HEARTBEAT_US=0
    local file="$KEELSON_STATUS_DIR/heartbeat"
    [ -r "$file" ] || return 1
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            heartbeat)
                clock_parse "$value"
                STATUS_HEARTBEAT_US=$CLOCK_PARSED_US
                ;;
        esac
    done < "$file"
    return 0
}

# status_read_watchers
# Populates STATUS_PIDS["<kind>"]=<pid>. Returns 1 if the file is missing.
status_read_watchers() {
    STATUS_PIDS=()
    local file="$KEELSON_STATUS_DIR/watchers"
    [ -r "$file" ] || return 1
    local key value
    while IFS='=' read -r key value; do
        [ -z "$key" ] && continue
        STATUS_PIDS["$key"]=$value
    done < "$file"
    return 0
}

# status_write_watcher_health <kind> <consecutive-failures> <error-text>
# Written by the watcher for that kind, and by nobody else: one writer per
# file, so watchers never contend. A live PID says the watcher process
# exists; this says whether its watch is actually streaming.
status_write_watcher_health() {
    local kind=$1 failures=$2 err=$3
    # The reader splits on the first '=' per line, so the error has to be a
    # single line. kubectl's messages are short; keep the first 200 chars.
    err=${err//$'\n'/ }
    err=${err//$'\r'/ }
    status_write_file "$KEELSON_STATUS_DIR/watcher-$kind" \
        "failures=$failures" "error=${err:0:200}"
}

# status_read_watcher_health <kind>
# Populates STATUS_WATCHER_FAILURES and STATUS_WATCHER_ERROR.
# Returns 1 if the kind has not published yet.
status_read_watcher_health() {
    local kind=$1
    STATUS_WATCHER_FAILURES=0
    STATUS_WATCHER_ERROR=
    local file="$KEELSON_STATUS_DIR/watcher-$kind"
    [ -r "$file" ] || return 1
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            failures) STATUS_WATCHER_FAILURES=$value ;;
            error)    STATUS_WATCHER_ERROR=$value ;;
        esac
    done < "$file"
    return 0
}

# status_all_watchers_streaming
# True iff every kind in the watcher map has published zero consecutive
# failures. A kind that has not published at all is not streaming yet.
status_all_watchers_streaming() {
    status_read_watchers || return 1
    [ "${#STATUS_PIDS[@]}" -gt 0 ] || return 1
    local kind
    for kind in "${!STATUS_PIDS[@]}"; do
        status_read_watcher_health "$kind" || return 1
        [ "$STATUS_WATCHER_FAILURES" -eq 0 ] 2>/dev/null || return 1
    done
}

# status_heartbeat_fresh <max-age-seconds>
# True iff the heartbeat was published within max-age seconds. Compared in
# microseconds at both ends, so the answer is not rounded across the limit
# by where a second boundary happened to fall.
status_heartbeat_fresh() {
    local max_age=$1
    status_read_heartbeat || return 1
    clock_read
    [ $(( CLOCK_NOW_US - STATUS_HEARTBEAT_US )) -lt $(( max_age * 1000000 )) ]
}

# status_all_watchers_alive
# True iff every PID in the map is still alive. False if the file is missing
# or holds no entries.
status_all_watchers_alive() {
    status_read_watchers || return 1
    [ "${#STATUS_PIDS[@]}" -gt 0 ] || return 1
    local kind pid
    for kind in "${!STATUS_PIDS[@]}"; do
        pid=${STATUS_PIDS[$kind]}
        # kill -0 0 targets the process group, not pid 0 itself.
        [ "$pid" -gt 0 ] 2>/dev/null || return 1
        kill -0 "$pid" 2>/dev/null || return 1
    done
}
