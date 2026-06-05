# Pod status file: heartbeat timestamp + one line per watched-kind PID.
# Sourced; not directly executable.
#
# The keelson controller writes this file every tick; keelson-probe reads
# it. Single writer (the loop), multiple readers (kube exec probes).
#
# File format (lines, key=value):
#   heartbeat=<unix-seconds>
#   <Kind>=<pid>
#   ...
#
# Tests override KEELSON_STATUS_FILE by exporting it before sourcing; the
# probe binary inherits its value the same way from the kubelet exec env.

KEELSON_STATUS_FILE=${KEELSON_STATUS_FILE:-/keelson/work/status}

declare -gA STATUS_PIDS=()
STATUS_HEARTBEAT=0

# status_write <heartbeat> <kind=pid> [<kind=pid> ...]
# Atomic via write-then-rename.
status_write() {
    local heartbeat=$1; shift
    local tmp="${KEELSON_STATUS_FILE}.tmp"
    mkdir -p "$(dirname "$KEELSON_STATUS_FILE")"
    {
        printf 'heartbeat=%s\n' "$heartbeat"
        local entry
        for entry in "$@"; do
            printf '%s\n' "$entry"
        done
    } > "$tmp"
    mv -f "$tmp" "$KEELSON_STATUS_FILE"
}

# status_read
# Populates STATUS_HEARTBEAT (0 if missing) and STATUS_PIDS["<kind>"]=<pid>.
# Returns 1 if the file is missing.
status_read() {
    STATUS_HEARTBEAT=0
    STATUS_PIDS=()
    [ -r "$KEELSON_STATUS_FILE" ] || return 1
    local line key value
    while IFS='=' read -r key value; do
        [ -z "$key" ] && continue
        case "$key" in
            heartbeat) STATUS_HEARTBEAT=$value ;;
            *) STATUS_PIDS["$key"]=$value ;;
        esac
    done < "$KEELSON_STATUS_FILE"
}

# status_heartbeat_fresh <max-age-seconds>
# True iff status file was last updated within max-age seconds.
status_heartbeat_fresh() {
    local max_age=$1
    status_read || return 1
    local now
    now=$(date -u +%s)
    [ $(( now - STATUS_HEARTBEAT )) -lt "$max_age" ]
}

# status_all_watchers_alive
# True iff every PID listed in the status file is still alive. False if the
# file is missing or empty of kind entries.
status_all_watchers_alive() {
    status_read || return 1
    [ "${#STATUS_PIDS[@]}" -gt 0 ] || return 1
    local kind pid
    for kind in "${!STATUS_PIDS[@]}"; do
        pid=${STATUS_PIDS[$kind]}
        # kill -0 0 targets the process group, not pid 0 itself.
        [ "$pid" -gt 0 ] 2>/dev/null || return 1
        kill -0 "$pid" 2>/dev/null || return 1
    done
}
