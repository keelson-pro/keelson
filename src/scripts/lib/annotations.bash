# Annotation lookup with KEELSON_CONFIG_MODE-aware dispatch.
# Sourced; not directly executable.
#
# annotation_get takes a flat "<full-key>=<value>" newline-separated string
# (one annotation per line) plus a *logical* key (the keelson-side short
# name like "policy" or "match-tag"). It resolves to the right prefix
# (keelson.pro/ vs keel.sh/) per KEELSON_CONFIG_MODE, applies any
# value-level translation, and echoes the result.
#
# Depends on log.bash being sourced first (for the "both" conflict warn).

# annotation_get <annotation-lines> <logical-key> [<container-name>]
# Echoes the resolved value, or empty if absent / rejected.
# When <container-name> is non-empty, the per-container key
# (e.g. keelson.pro/<key>.<container>) wins over the workload-wide key
# (keelson.pro/<key>). The same precedence applies on the keel.sh/ side.
# Special outputs:
#   "REJECT:<reason>"  - caller treats as a skip with that reason. Currently:
#     keel-policy-force-unsupported  - keel value not honoured by keelson
#     dual-prefix-conflict           - workload mixes keelson.pro/ and keel.sh/
#                                      under config-mode=both (pick one prefix
#                                      per workload, not both).
annotation_get() {
    local lines=$1 key=$2 container=${3:-}
    local mode=${KEELSON_CONFIG_MODE:?KEELSON_CONFIG_MODE required}

    local keelson_val keel_val keel_key
    keelson_val=""
    if [ -n "$container" ]; then
        keelson_val=$(annotation_lookup_raw "$lines" "keelson.pro/$key.$container")
    fi
    if [ -z "$keelson_val" ]; then
        keelson_val=$(annotation_lookup_raw "$lines" "keelson.pro/$key")
    fi
    keel_key=$(annotation_keel_key "$key")
    keel_val=""
    if [ -n "$keel_key" ]; then
        if [ -n "$container" ]; then
            keel_val=$(annotation_lookup_raw "$lines" "keel.sh/$keel_key.$container")
        fi
        if [ -z "$keel_val" ]; then
            keel_val=$(annotation_lookup_raw "$lines" "keel.sh/$keel_key")
        fi
    fi

    case "$mode" in
        keelson)
            printf '%s' "$keelson_val"
            ;;
        keel)
            annotation_translate_keel_value "$key" "$keel_val"
            ;;
        both)
            if annotation_has_prefix "$lines" "keelson.pro/" \
                    && annotation_has_prefix "$lines" "keel.sh/"; then
                printf 'REJECT:dual-prefix-conflict'
                return 0
            fi
            if [ -n "$keelson_val" ]; then
                printf '%s' "$keelson_val"
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

# Map a keelson-side logical key to the corresponding keel.sh short key.
# Empty result = no keel equivalent (the key is keelson-only).
annotation_keel_key() {
    case "$1" in
        policy)        printf 'policy' ;;
        trigger)       printf 'trigger' ;;
        poll-schedule) printf 'pollSchedule' ;;
        match-tag)     printf 'match-tag' ;;
        notify)        printf 'notify' ;;
        *)             printf '' ;;
    esac
}

# Translate a keel-side value into a keelson-equivalent.
# Returns "REJECT:<reason>" for keel values keelson refuses to honour.
annotation_translate_keel_value() {
    local key=$1 val=$2
    [ -z "$val" ] && { printf ''; return 0; }
    case "$key" in
        policy)
            case "$val" in
                force) printf 'REJECT:keel-policy-force-unsupported' ;;
                *)     printf '%s' "$val" ;;
            esac
            ;;
        *)
            printf '%s' "$val"
            ;;
    esac
}

# Lookup a full annotation key (with prefix) in the flat lines string.
# Echoes value or empty.
annotation_lookup_raw() {
    local lines=$1 key=$2 line
    while IFS= read -r line; do
        case "$line" in
            "$key="*)
                printf '%s' "${line#"$key="}"
                return 0
                ;;
        esac
    done <<< "$lines"
}
