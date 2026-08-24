# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
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
ANNOTATION_ALT_KEY=

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
#                                      annotations. Rejected in every mode: a
#                                      keel.sh/ annotation is evidence keel may
#                                      be running, and two controllers writing
#                                      one image field is worse than neither.
annotation_get() {
    local lines=$1 key=$2 container=${3:-}
    local mode=${KEELSON_CONFIG_MODE:?KEELSON_CONFIG_MODE required}

    case "$mode" in
        keelson|keel|both) ;;
        *) return 2 ;;
    esac

    # Both prefixes on one workload, in any mode. Ignoring the other one is
    # only safe if nothing is acting on it, and a keel.sh/ annotation is
    # evidence that keel may well be running too. Two controllers writing the
    # same image field is worse than either doing nothing, so neither does.
    if annotation_has_prefix "$lines" "keelson.pro/" \
            && annotation_has_prefix "$lines" "keel.sh/"; then
        ANNOTATION_VALUE='REJECT:dual-prefix-conflict'
        return 0
    fi

    local keelson_val="" keel_val="" keel_key alt
    annotation_alt_key "$key"
    alt=$ANNOTATION_ALT_KEY

    if [ -n "$container" ]; then
        annotation_pick "$lines" "keelson.pro/$key.$container" \
            "${alt:+keelson.pro/$alt.$container}"
        keelson_val=$ANNOTATION_RAW
    fi
    if [ -z "$keelson_val" ]; then
        annotation_pick "$lines" "keelson.pro/$key" "${alt:+keelson.pro/$alt}"
        keelson_val=$ANNOTATION_RAW
    fi
    case "$keelson_val" in REJECT:*) ANNOTATION_VALUE=$keelson_val; return 0 ;; esac

    annotation_keel_key "$key"
    keel_key=$ANNOTATION_KEEL_KEY
    if [ -n "$keel_key" ]; then
        annotation_alt_key "$keel_key"
        alt=$ANNOTATION_ALT_KEY
        if [ -n "$container" ]; then
            annotation_pick "$lines" "keel.sh/$keel_key.$container" \
                "${alt:+keel.sh/$alt.$container}"
            keel_val=$ANNOTATION_RAW
        fi
        if [ -z "$keel_val" ]; then
            annotation_pick "$lines" "keel.sh/$keel_key" "${alt:+keel.sh/$alt}"
            keel_val=$ANNOTATION_RAW
        fi
        case "$keel_val" in REJECT:*) ANNOTATION_VALUE=$keel_val; return 0 ;; esac
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
            if [ -n "$keelson_val" ]; then
                ANNOTATION_VALUE=$keelson_val
            else
                annotation_translate_keel_value "$key" "$keel_val"
            fi
            ;;
    esac
}

# annotation_has_prefix <annotation-lines> <prefix>
# Returns 0 if any line starts with the prefix, 1 otherwise.
#
# The leading newline makes "start of a line" expressible as a substring, so
# the whole set is one glob match. Reading it line by line meant a here-string,
# and every here-string is a temp file created, written, read and unlinked.
annotation_has_prefix() {
    local lines=$1 prefix=$2
    case $'\n'"$lines" in
        *$'\n'"$prefix"*) return 0 ;;
    esac
    return 1
}

# annotation_alt_key <key>  -> ANNOTATION_ALT_KEY
# The hyphenated spelling of a camelCase key, empty when there is no second
# spelling. camelCase is canonical; the hyphenated form is accepted because
# keel's own surface mixes the two and a workload moving between them should
# not have to be rewritten.
annotation_alt_key() {
    case "$1" in
        matchTag)             ANNOTATION_ALT_KEY='match-tag' ;;
        matchMode)            ANNOTATION_ALT_KEY='match-mode' ;;
        pollSchedule)         ANNOTATION_ALT_KEY='poll-schedule' ;;
        triggerJobOnUpdate)   ANNOTATION_ALT_KEY='trigger-job-on-update' ;;
        fieldManagerStrategy) ANNOTATION_ALT_KEY='field-manager-strategy' ;;
        *)                    ANNOTATION_ALT_KEY= ;;
    esac
}

# annotation_pick <lines> <key> <alt-key>  -> ANNOTATION_RAW
# One scope, both spellings. Empty <alt-key> means the key has only one.
#
# Both spellings on the same workload with different values is a rejection,
# not a precedence puzzle: whichever we picked would be someone's surprise.
# The same value twice is merely untidy, so it warns and carries on.
annotation_pick() {
    local lines=$1 key=$2 alt=$3 primary secondary
    annotation_lookup_raw "$lines" "$key"
    primary=$ANNOTATION_RAW
    if [ -z "$alt" ]; then
        ANNOTATION_RAW=$primary
        return 0
    fi
    annotation_lookup_raw "$lines" "$alt"
    secondary=$ANNOTATION_RAW
    if [ -n "$primary" ] && [ -n "$secondary" ]; then
        if [ "$primary" != "$secondary" ]; then
            log_error annotation-spelling-conflict key="$key" alt="$alt" \
                value="$primary" alt-value="$secondary" \
                msg="Both '$key' and '$alt' are set with different values ('$primary' and '$secondary'); pick one spelling."
            ANNOTATION_RAW='REJECT:annotation-spelling-conflict'
            return 0
        fi
        log_warn annotation-spelling-duplicate key="$key" alt="$alt" \
            msg="Both '$key' and '$alt' are set to the same value; '$alt' is the older spelling and can be removed."
    fi
    [ -n "$primary" ] && ANNOTATION_RAW=$primary
    return 0
}

# annotation_keel_key <logical-key>  -> ANNOTATION_KEEL_KEY
# Maps a keelson-side logical key to the corresponding keel.sh short key.
# Empty result = no keel equivalent (the key is keelson-only).
annotation_keel_key() {
    case "$1" in
        policy)       ANNOTATION_KEEL_KEY='policy' ;;
        trigger)      ANNOTATION_KEEL_KEY='trigger' ;;
        pollSchedule) ANNOTATION_KEEL_KEY='pollSchedule' ;;
        matchTag)     ANNOTATION_KEEL_KEY='matchTag' ;;
        initContainers)    ANNOTATION_KEEL_KEY='initContainers' ;;
        monitorContainers) ANNOTATION_KEEL_KEY='monitorContainers' ;;
        notify)       ANNOTATION_KEEL_KEY='notify' ;;
        *)            ANNOTATION_KEEL_KEY= ;;
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
    local lines=$1 key=$2
    ANNOTATION_RAW=
    local hay=$'\n'$lines
    case "$hay" in
        *$'\n'"$key="*) ;;
        *) return 0 ;;
    esac
    local rest=${hay#*$'\n'"$key="}
    ANNOTATION_RAW=${rest%%$'\n'*}
}
