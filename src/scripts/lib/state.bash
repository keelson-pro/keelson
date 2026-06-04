# State ConfigMap for Keelson.
# Sourced; not directly executable.
#
# Backs log-dedupe (skip-reason, error-event) and the CronJob always-once
# trigger gate. One ConfigMap per Keelson installation, in Keelson's own
# namespace, with two data-key shapes:
#
#   c--<kind>--<ns>--<name>--<container>   per-container scan state
#   j--<kind>--<ns>--<name>                per-workload trigger state (CronJob)
#
# Per-container fields:
#   checked-tag, checked-at         last observed tag, when
#   update-tag, update-at           last applied tag, when
#   skip-reason, skip-at            last skip, when
#   error-event, error-detail, error-at
#
# Per-workload trigger fields:
#   triggered-job, triggered-at     last manual Job, when
#   error-event, error-detail, error-at
#
# Cache:
#   STATE_FIELDS["<data-key>:<field>"] = string
#   STATE_KEYS["<data-key>"]           = 1 if known
#   STATE_DIRTY["<data-key>"]          = 1 if changed since last flush
#
# ConfigMap.data values are JSON object strings, one per data-key. Single
# writer assumption: state_flush uses a merge patch with no resourceVersion
# check. Introduce leader election before lifting that assumption.
#
# Configuration:
#   KEELSON_STATE_CONFIGMAP     ConfigMap name (default keelson-state)
#   KEELSON_STATE_NAMESPACE     override (default: read SA mount)
#   KEELSON_SA_NAMESPACE_FILE   override of SA namespace path (tests)
#
# Depends on: lib/log.bash

declare -gA STATE_FIELDS=()
declare -gA STATE_KEYS=()
declare -gA STATE_DIRTY=()
STATE_NAMESPACE=""
STATE_CONFIGMAP_NAME=""

# state_container_key <kind> <ns> <name> <container>
state_container_key() {
    printf 'c--%s--%s--%s--%s' "$1" "$2" "$3" "$4"
}

# state_trigger_key <kind> <ns> <name>
state_trigger_key() {
    printf 'j--%s--%s--%s' "$1" "$2" "$3"
}

# state_init
# Discover own namespace, ensure ConfigMap exists, load it into the cache.
state_init() {
    STATE_CONFIGMAP_NAME="${KEELSON_STATE_CONFIGMAP:-keelson-state}"
    if [ -n "${KEELSON_STATE_NAMESPACE:-}" ]; then
        STATE_NAMESPACE="$KEELSON_STATE_NAMESPACE"
    else
        local ns_file="${KEELSON_SA_NAMESPACE_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/namespace}"
        if [ -r "$ns_file" ]; then
            STATE_NAMESPACE=$(cat "$ns_file")
        else
            log_error state-namespace-unknown ns-file="$ns_file"
            return 1
        fi
    fi
    STATE_FIELDS=()
    STATE_KEYS=()
    STATE_DIRTY=()
    state_load
}

# state_load
# Fetches the ConfigMap (creating an empty one if absent) and rebuilds the
# in-memory cache from its data map.
state_load() {
    local cm_json
    if ! cm_json=$(kubectl get configmap "$STATE_CONFIGMAP_NAME" \
            -n "$STATE_NAMESPACE" -o json 2>/dev/null); then
        if ! kubectl create configmap "$STATE_CONFIGMAP_NAME" \
                -n "$STATE_NAMESPACE" >/dev/null 2>&1; then
            log_error state-configmap-create-failed \
                configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE"
            return 1
        fi
        log_info state-configmap-created \
            configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE"
        return 0
    fi
    local keys key val
    keys=$(printf '%s' "$cm_json" \
        | yq -p=json '.data // {} | keys | .[]' 2>/dev/null)
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        val=$(printf '%s' "$cm_json" \
            | yq -p=json '.data["'"$key"'"]' 2>/dev/null)
        state_load_value "$key" "$val"
    done <<< "$keys"
}

# state_load_value <data-key> <json-object-string>
# Parses one data value's fields into the cache.
state_load_value() {
    local data_key=$1 json=$2
    STATE_KEYS["$data_key"]=1
    [ -z "$json" ] && return 0
    [ "$json" = "null" ] && return 0
    local fields field val
    fields=$(printf '%s' "$json" | yq -p=json 'keys | .[]' 2>/dev/null)
    while IFS= read -r field; do
        [ -z "$field" ] && continue
        val=$(printf '%s' "$json" | yq -p=json '."'"$field"'"' 2>/dev/null)
        [ "$val" = "null" ] && val=""
        STATE_FIELDS["$data_key:$field"]="$val"
    done <<< "$fields"
}

# state_get <data-key> <field>
state_get() {
    local k="$1:$2"
    printf '%s' "${STATE_FIELDS[$k]-}"
}

# state_set <data-key> <field> <value>
state_set() {
    local data_key=$1 field=$2 value=$3
    STATE_FIELDS["$data_key:$field"]=$value
    STATE_KEYS["$data_key"]=1
    STATE_DIRTY["$data_key"]=1
}

state_get_container_field() {
    state_get "$(state_container_key "$1" "$2" "$3" "$4")" "$5"
}

state_set_container_field() {
    state_set "$(state_container_key "$1" "$2" "$3" "$4")" "$5" "$6"
}

state_get_trigger_field() {
    state_get "$(state_trigger_key "$1" "$2" "$3")" "$4"
}

state_set_trigger_field() {
    state_set "$(state_trigger_key "$1" "$2" "$3")" "$4" "$5"
}

# state_clear_cache
# Wipes the in-memory cache. Use on the full-refresh tick to force re-emit
# of deduped logs. Does NOT touch the ConfigMap (next state_load repopulates).
state_clear_cache() {
    STATE_FIELDS=()
    STATE_KEYS=()
    STATE_DIRTY=()
}

# state_json_escape <string>
# Escapes a string for inclusion as a JSON string literal value.
state_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    printf '%s' "$s"
}

# state_render_data_value <data-key>
# Renders a JSON object string of the data-key's non-empty fields.
state_render_data_value() {
    local data_key=$1
    local pair field value items="" first=1
    for pair in "${!STATE_FIELDS[@]}"; do
        case "$pair" in
            "$data_key:"*)
                field=${pair#"$data_key:"}
                value=${STATE_FIELDS[$pair]}
                [ -z "$value" ] && continue
                if [ "$first" -eq 1 ]; then
                    first=0
                else
                    items="$items,"
                fi
                items="$items\"$(state_json_escape "$field")\":\"$(state_json_escape "$value")\""
                ;;
        esac
    done
    printf '{%s}' "$items"
}

# state_build_patch
# Builds the strategic-merge patch body for state_flush.
state_build_patch() {
    local entries="" first=1 key value
    for key in "${!STATE_DIRTY[@]}"; do
        value=$(state_render_data_value "$key")
        if [ "$first" -eq 1 ]; then
            first=0
        else
            entries="$entries,"
        fi
        entries="$entries\"$(state_json_escape "$key")\":\"$(state_json_escape "$value")\""
    done
    printf '{"data":{%s}}' "$entries"
}

# state_flush
# Writes all dirty keys back to the ConfigMap via a single merge patch.
# Clears the dirty set on success; leaves it intact for the next attempt
# on failure.
state_flush() {
    if [ "${#STATE_DIRTY[@]}" -eq 0 ]; then
        return 0
    fi
    local patch
    patch=$(state_build_patch)
    if kubectl patch configmap "$STATE_CONFIGMAP_NAME" \
            -n "$STATE_NAMESPACE" --type=merge \
            --patch "$patch" >/dev/null 2>&1; then
        local count=${#STATE_DIRTY[@]}
        STATE_DIRTY=()
        log_info state-flushed \
            configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
            keys="$count"
        return 0
    fi
    log_error state-flush-failed \
        configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
        keys="${#STATE_DIRTY[@]}"
    return 1
}

# state_now
# Echoes the current time as an ISO-8601 UTC timestamp.
state_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}
