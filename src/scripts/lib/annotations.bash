# Annotation lookup with KEELSON_CONFIG_MODE-aware dispatch.
# Sourced; not directly executable.
#
# annotation_get takes a flat "<full-key>=<value>" newline-separated string
# (one annotation per line) plus a *logical* key (the keelson-side short
# name like "policy" or "match-tag"). It resolves to the right prefix
# (keelson.pro/ vs keel.sh/) per KEELSON_CONFIG_MODE, applies any
# value-level translation, and leaves the result in ANNOTATION_VALUE.
#
# Results land in globals rather than on stdout. This is the hottest path in
# the poll: five lookups per container, each of which was a command
# substitution around four more, so a container cost thirty forks before a
# registry was contacted.
#
# Depends on log.bash being sourced first (for the "both" conflict warn).

ANNOTATION_VALUE=
ANNOTATION_RAW=
ANNOTATION_KEEL_KEY=

# annotation_get <annotation-lines> <logical-key> [<container-name>]
#                -> ANNOTATION_VALUE
# Empty if absent or rejected.
# When <container-name> is non-empty, the per-container key
# (e.g. keelson.pro/<key>.<container>) wins over the workload-wide key
# (keelson.pro/<key>). The same precedence applies on the keel.sh/ side.
# Special values:
#   "REJECT:<reason>"  - caller treats as a skip with that reason. Currently:
#     keel-policy-force-unsupported  - keel value not honoured by keelson
#     dual-prefix-conflict           - workload mixes keelson.pro/ and keel.sh/
#                                      under config-mode=both (pick one prefix
#                                      per workload, not both).
annotation_get() {
    local lines=$1 key=$2 container=${3:-}
    local mode=${KEELSON_CONFIG_MODE:?KEELSON_CONFIG_MODE required}

    local keelson_val="" keel_val="" keel_key
    if [ -n "$container" ]; then
        annotation_lookup_raw "$lines" "keelson.pro/$key.$container"
        keelson_val=$ANNOTATION_RAW
    fi
    if [ -z "$keelson_val" ]; then
        annotation_lookup_raw "$lines" "keelson.pro/$key"
        keelson_val=$ANNOTATION_RAW
    fi
    annotation_keel_key "$key"
    keel_key=$ANNOTATION_KEEL_KEY
    if [ -n "$keel_key" ]; then
        if [ -n "$container" ]; then
            annotation_lookup_raw "$lines" "keel.sh/$keel_key.$container"
            keel_val=$ANNOTATION_RAW
        fi
        if [ -z "$keel_val" ]; then
            annotation_lookup_raw "$lines" "keel.sh/$keel_key"
            keel_val=$ANNOTATION_RAW
        fi
    fi

    ANNOTATION_VALUE=
    case "$mode" in
        keelson)
            ANNOTATION_VALUE=$keelson_val
            ;;
        keel)
            annotation_translate_keel_value "$key" "$keel_val"
            ;;
        both)
            if annotation_has_prefix "$lines" "keelson.pro/" \
                    && annotation_has_prefix "$lines" "keel.sh/"; then
                ANNOTATION_VALUE='REJECT:dual-prefix-conflict'
                return 0
            fi
            if [ -n "$keelson_val" ]; then
                ANNOTATION_VALUE=$keelson_val
            else
                annotation_translate_keel_value "$key" "$keel_val"
            fi
            ;;
        *)
            return 2
            ;;
    esac
}

# annotation_has_prefix <annotation-lines> <prefix>
# Returns 0 if any line starts with the prefix, 1 otherwise.
annotation_has_prefix() {
    local lines=$1 prefix=$2 line
    while IFS= read -r line; do
        case "$line" in
            "$prefix"*) return 0 ;;
        esac
    done <<< "$lines"
    return 1
}

# annotation_keel_key <logical-key>  -> ANNOTATION_KEEL_KEY
# Maps a keelson-side logical key to the corresponding keel.sh short key.
# Empty result = no keel equivalent (the key is keelson-only).
annotation_keel_key() {
    case "$1" in
        policy)        ANNOTATION_KEEL_KEY='policy' ;;
        trigger)       ANNOTATION_KEEL_KEY='trigger' ;;
        poll-schedule) ANNOTATION_KEEL_KEY='pollSchedule' ;;
        match-tag)     ANNOTATION_KEEL_KEY='match-tag' ;;
        notify)        ANNOTATION_KEEL_KEY='notify' ;;
        *)             ANNOTATION_KEEL_KEY= ;;
    esac
}

# annotation_translate_keel_value <logical-key> <value> -> ANNOTATION_VALUE
# Translates a keel-side value into a keelson-equivalent.
# Yields "REJECT:<reason>" for keel values keelson refuses to honour.
annotation_translate_keel_value() {
    local key=$1 val=$2
    ANNOTATION_VALUE=
    [ -z "$val" ] && return 0
    case "$key" in
        policy)
            case "$val" in
                force) ANNOTATION_VALUE='REJECT:keel-policy-force-unsupported' ;;
                *)     ANNOTATION_VALUE=$val ;;
            esac
            ;;
        *)
            ANNOTATION_VALUE=$val
            ;;
    esac
}

# annotation_lookup_raw <annotation-lines> <full-key>  -> ANNOTATION_RAW
# Empty when the key is absent.
annotation_lookup_raw() {
    local lines=$1 key=$2 line
    ANNOTATION_RAW=
    while IFS= read -r line; do
        case "$line" in
            "$key="*)
                ANNOTATION_RAW=${line#"$key="}
                return 0
                ;;
        esac
    done <<< "$lines"
}
