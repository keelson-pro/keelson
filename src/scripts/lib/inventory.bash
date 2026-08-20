# Local workload cache: everything Keelson needs to poll a workload's image
# repository and decide about it, plus when that is next due.
# Sourced; not directly executable.
#
# One file per workload identity, on the pod's writable volume:
#
#   /keelson/work/inventory/<Kind>--<ns>--<name>
#
# Same shape as the work queue, for the same reasons: a file per identity
# gives collision-free concurrent writes, implicit dedupe, and survives the
# backgrounded scan child, which inherits the parent's memory but cannot
# write back to it.
#
# An entry holds the whole decision input, not just a summary, so a due
# workload can be polled straight from cache with no read of the cluster.
# The tick asks what is due and acts; listing the cluster is a separate,
# slower reconcile that refreshes these entries.
#
# This is derived state. Every field can be rebuilt from the cluster by one
# list per kind, so it lives here rather than in the state ConfigMap, which
# is capped near 1 MiB and would be rewritten in full on every update. Only
# next-due is worth persisting, and that is the ConfigMap's job.
#
# Entry format (lines, key=value; the value keeps any further '=' it holds,
# which image references and annotation values both need). Repeated keys
# build lists, in file order:
#
#   kind=<Kind>
#   namespace=<ns>
#   name=<name>
#   next-due=<unix seconds>       when this workload's repo is next polled
#   interval=<seconds>            its own polling cadence
#   suspend=<true|false|>         CronJob only; empty otherwise
#   service-account=<name>
#   image-pull-secrets=<compact json>
#   annotation=<full-key>=<value> one per annotation, verbatim from the
#                                 flattener so annotation_get sees exactly
#                                 what it would have seen from the cluster
#   container=<name>=<image>      one per container
#   fingerprint=<derived>
#
# Values must be single-line. JSON has to be compact (yq -I=0); a pretty
# printed value would be read back as several truncated entries.
#
# The fingerprint covers every field except next-due, so a changed image,
# annotation, credential or cadence all read as "this changed" and force a
# poll rather than waiting out the old schedule. It is a plain concatenation
# rather than a hash: comparing it is a string compare, and hashing it would
# cost work per workload per pass for no gain.
#
# Tests override KEELSON_INVENTORY_DIR by reassigning it after sourcing;
# every path here is resolved at call time.

KEELSON_INVENTORY_DIR=${KEELSON_INVENTORY_DIR:-/keelson/work/inventory}

INVENTORY_PATH=
INVENTORY_KIND=
INVENTORY_NAMESPACE=
INVENTORY_NAME=
INVENTORY_NEXT_DUE=0
INVENTORY_INTERVAL=0
INVENTORY_SUSPEND=
INVENTORY_SERVICE_ACCOUNT=
INVENTORY_IMAGE_PULL_SECRETS=
INVENTORY_ANNOTATIONS=
INVENTORY_FINGERPRINT=
INVENTORY_COMPUTED_FINGERPRINT=
INVENTORY_HASH=0
INVENTORY_FIRST_DUE=0
declare -ga INVENTORY_CONTAINER_NAMES=()
declare -ga INVENTORY_CONTAINER_IMAGES=()
declare -ga INVENTORY_DUE=()
declare -ga INVENTORY_ALL=()

# inventory_init
# Ensures the inventory directory exists. Idempotent, and keeps whatever is
# already there: a restart rebuilds from the cluster, it does not wipe.
inventory_init() {
    mkdir -p "$KEELSON_INVENTORY_DIR"
}

# inventory_enabled
# True when there is an inventory to maintain. The controller calls
# inventory_init at boot; one-shot entry points run outside a controller pod
# have no cache to keep current, so they skip the bookkeeping rather than
# leaving a half-populated directory behind.
inventory_enabled() {
    [ -d "$KEELSON_INVENTORY_DIR" ]
}

# inventory_path <kind> <ns> <name>
# Sets INVENTORY_PATH. A function rather than a command substitution so the
# hot paths below cost no fork.
inventory_path() {
    INVENTORY_PATH="${KEELSON_INVENTORY_DIR}/${1}--${2}--${3}"
}

# inventory_hash <string>
# Sets INVENTORY_HASH to a small stable number. Character-sum rather than a
# real digest because it only has to spread identities across a window, and
# shelling out to sha256sum would cost a fork per new workload.
inventory_hash() {
    local s=$1 h=0 i c
    for (( i = 0; i < ${#s}; i++ )); do
        printf -v c '%d' "'${s:i:1}"
        h=$(( (h * 31 + c) % 1000003 ))
    done
    INVENTORY_HASH=$h
}

# inventory_first_due <kind> <ns> <name> <interval> <now>
# Sets INVENTORY_FIRST_DUE for a workload being cached for the first time.
#
# Offset by a hash of the identity so workloads on the same cadence do not
# all fall due together. Without it every workload cached in the same pass
# (which at boot is all of them) shares a next-due forever after, and the
# registry sees the whole estate arrive at once every interval.
#
# Derived from the name rather than stored or randomised, so it is stable
# across restarts and needs no state of its own.
inventory_first_due() {
    inventory_hash "$1 $2 $3"
    INVENTORY_FIRST_DUE=$(( $5 + INVENTORY_HASH % $4 ))
}

# inventory_fingerprint <interval> <suspend> <sa> <ips> <annotations>
#                       <containers>
# Sets INVENTORY_COMPUTED_FINGERPRINT: everything a decision depends on
# except next-due, so a change to any of it reads as "this changed".
#
# One formula, used by inventory_put when writing and by callers wanting to
# know whether what they just read from the cluster differs from what is
# cached. Deriving it twice would let the two drift.
#
# The multi-line inputs are stripped of a trailing newline first. Whether one
# is present depends on how the caller built the list, and without this a
# rebuilt-but-identical record fingerprints differently, which reads as a
# change on every pass and resyncs forever.
inventory_fingerprint() {
    local annotations=${5%$'\n'} containers=${6%$'\n'}
    INVENTORY_COMPUTED_FINGERPRINT="${1}|${2}|${3}|${4}|${annotations//$'\n'/;}|${containers//$'\n'/;}"
}

# inventory_put <kind> <ns> <name> <next-due> <interval> <suspend>
#               <service-account> <image-pull-secrets> <annotations>
#               <containers>
#
# <annotations> is the flattened newline-separated "<key>=<value>" block.
# <containers> is newline-separated "<name>=<image>".
inventory_put() {
    local kind=$1 ns=$2 name=$3 next_due=$4 interval=$5 suspend=$6 \
          sa=$7 ips=$8 annotations=$9 containers=${10}
    local line fp

    inventory_fingerprint "$interval" "$suspend" "$sa" "$ips" \
        "$annotations" "$containers"
    fp=$INVENTORY_COMPUTED_FINGERPRINT

    inventory_path "$kind" "$ns" "$name"
    local tmp="${INVENTORY_PATH}.tmp"
    {
        printf 'kind=%s\n' "$kind"
        printf 'namespace=%s\n' "$ns"
        printf 'name=%s\n' "$name"
        printf 'next-due=%s\n' "$next_due"
        printf 'interval=%s\n' "$interval"
        printf 'suspend=%s\n' "$suspend"
        printf 'service-account=%s\n' "$sa"
        printf 'image-pull-secrets=%s\n' "$ips"
        while IFS= read -r line; do
            [ -n "$line" ] && printf 'annotation=%s\n' "$line"
        done <<< "$annotations"
        while IFS= read -r line; do
            [ -n "$line" ] && printf 'container=%s\n' "$line"
        done <<< "$containers"
        printf 'fingerprint=%s\n' "$fp"
    } > "$tmp"
    mv -f "$tmp" "$INVENTORY_PATH"
}

# inventory_get <kind> <ns> <name>
# Populates the INVENTORY_* globals, including the container arrays and the
# annotation block in the form annotation_get expects. Returns 1 if the
# workload is unknown.
inventory_get() {
    inventory_path "$1" "$2" "$3"
    [ -r "$INVENTORY_PATH" ] || return 1
    INVENTORY_KIND=
    INVENTORY_NAMESPACE=
    INVENTORY_NAME=
    INVENTORY_NEXT_DUE=0
    INVENTORY_INTERVAL=0
    INVENTORY_SUSPEND=
    INVENTORY_SERVICE_ACCOUNT=
    INVENTORY_IMAGE_PULL_SECRETS=
    INVENTORY_ANNOTATIONS=
    INVENTORY_FINGERPRINT=
    INVENTORY_CONTAINER_NAMES=()
    INVENTORY_CONTAINER_IMAGES=()
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            kind)               INVENTORY_KIND=$value ;;
            namespace)          INVENTORY_NAMESPACE=$value ;;
            name)               INVENTORY_NAME=$value ;;
            next-due)           INVENTORY_NEXT_DUE=$value ;;
            interval)           INVENTORY_INTERVAL=$value ;;
            suspend)            INVENTORY_SUSPEND=$value ;;
            service-account)    INVENTORY_SERVICE_ACCOUNT=$value ;;
            image-pull-secrets) INVENTORY_IMAGE_PULL_SECRETS=$value ;;
            fingerprint)        INVENTORY_FINGERPRINT=$value ;;
            annotation)
                if [ -z "$INVENTORY_ANNOTATIONS" ]; then
                    INVENTORY_ANNOTATIONS=$value
                else
                    INVENTORY_ANNOTATIONS="${INVENTORY_ANNOTATIONS}"$'\n'"${value}"
                fi
                ;;
            container)
                INVENTORY_CONTAINER_NAMES+=("${value%%=*}")
                INVENTORY_CONTAINER_IMAGES+=("${value#*=}")
                ;;
        esac
    done < "$INVENTORY_PATH"
    return 0
}

# inventory_evict <kind> <ns> <name>
# Forgets a workload. Succeeds whether or not it was known, so a DELETE for
# something we never cached is not an error.
inventory_evict() {
    inventory_path "$1" "$2" "$3"
    rm -f "$INVENTORY_PATH"
    return 0
}

# inventory_set_next_due <kind> <ns> <name> <next-due>
# Reschedules an entry without disturbing anything else. Returns 1 if the
# workload is unknown.
inventory_set_next_due() {
    local kind=$1 ns=$2 name=$3 next_due=$4
    inventory_get "$kind" "$ns" "$name" || return 1
    local containers= i
    for (( i = 0; i < ${#INVENTORY_CONTAINER_NAMES[@]}; i++ )); do
        containers="${containers}${INVENTORY_CONTAINER_NAMES[$i]}=${INVENTORY_CONTAINER_IMAGES[$i]}"$'\n'
    done
    inventory_put "$kind" "$ns" "$name" "$next_due" "$INVENTORY_INTERVAL" \
        "$INVENTORY_SUSPEND" "$INVENTORY_SERVICE_ACCOUNT" \
        "$INVENTORY_IMAGE_PULL_SECRETS" "$INVENTORY_ANNOTATIONS" "$containers"
}

# inventory_mark_polled <kind> <ns> <name> <now>
# Pushes next-due out by the entry's own interval. Returns 1 if unknown.
inventory_mark_polled() {
    inventory_get "$1" "$2" "$3" || return 1
    inventory_set_next_due "$1" "$2" "$3" "$(( $4 + INVENTORY_INTERVAL ))"
}

# inventory_evict_kind <kind>
# Forgets every cached workload of one kind. Used by the full refresh, which
# rebuilds a kind from the cluster rather than merely overwriting what it
# finds: an entry that is corrupt, or whose file the reconcile pass would
# never revisit, only goes away if something drops it.
inventory_evict_kind() {
    local kind=$1 f
    shopt -s nullglob
    for f in "$KEELSON_INVENTORY_DIR/${kind}--"*; do
        rm -f "$f"
    done
    shopt -u nullglob
    return 0
}

# inventory_evict_unwatched <watched-kinds>
# Forgets cached workloads of any kind no longer in KEELSON_WATCHED_KINDS.
#
# The reconcile pass cannot do this: it only evicts within the kinds it
# listed, so dropping a kind from the watched set leaves its entries behind
# forever, still being polled.
inventory_evict_unwatched() {
    local watched=" $1 " entry ekind ens ename
    inventory_list
    for entry in "${INVENTORY_ALL[@]}"; do
        ekind=${entry%% *}
        case "$watched" in
            *" $ekind "*) continue ;;
        esac
        read -r ekind ens ename <<<"$entry"
        inventory_evict "$ekind" "$ens" "$ename"
    done
    return 0
}

# inventory_due <now>
# Populates INVENTORY_DUE with "<kind> <ns> <name>" for every workload whose
# next-due has arrived. This is what the tick asks each second; a quiet
# cluster on long schedules does no registry work at all in between.
inventory_due() {
    local now=$1 f key value kind ns name due
    INVENTORY_DUE=()
    shopt -s nullglob
    for f in "$KEELSON_INVENTORY_DIR"/*; do
        case "$f" in *.tmp) continue ;; esac
        kind=; ns=; name=; due=0
        while IFS='=' read -r key value; do
            case "$key" in
                kind)      kind=$value ;;
                namespace) ns=$value ;;
                name)      name=$value ;;
                next-due)  due=$value ;;
            esac
        done < "$f"
        [ -n "$kind" ] || continue
        [ "$now" -ge "$due" ] 2>/dev/null || continue
        INVENTORY_DUE+=("$kind $ns $name")
    done
    shopt -u nullglob
    return 0
}

# inventory_list
# Populates INVENTORY_ALL with "<kind> <ns> <name>" for every known workload,
# due or not. Used by the reconcile pass to spot entries the cluster no
# longer has.
inventory_list() {
    local f key value kind ns name
    INVENTORY_ALL=()
    shopt -s nullglob
    for f in "$KEELSON_INVENTORY_DIR"/*; do
        case "$f" in *.tmp) continue ;; esac
        kind=; ns=; name=
        while IFS='=' read -r key value; do
            case "$key" in
                kind)      kind=$value ;;
                namespace) ns=$value ;;
                name)      name=$value ;;
            esac
        done < "$f"
        [ -n "$kind" ] || continue
        INVENTORY_ALL+=("$kind $ns $name")
    done
    shopt -u nullglob
    return 0
}
