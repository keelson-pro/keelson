# State ConfigMap for Keelson.
# Sourced; not directly executable.
#
# Backs the CronJob always-once trigger gate. Log dedupe is NOT persisted:
# lib/log.bash handles repeat suppression in memory via per-level intervals.
# A pod restart re-emits everything, which is the intended baseline.
#
# Data-key shape:
#   j--<kind>--<ns>--<name>     per-workload trigger state (CronJob only)
#   s--<kind>--<ns>--<name>     per-workload schedule: next-due
#
# Per-workload trigger fields:
#   triggered-job, triggered-at    last manual Job, when (the scan reads
#                                  triggered-job to gate the always-once
#                                  trigger; triggered-at is informational)
#
# Cache:
#   STATE_FIELDS["<data-key>:<field>"] = string
#   STATE_KEYS["<data-key>"]           = 1 if known
#   STATE_DIRTY["<data-key>"]          = 1 if changed since last flush
#   STATE_DELETED["<data-key>"]        = 1 if to be removed on next flush
#
# ConfigMap.data values are JSON object strings, one per data-key. Single
# writer assumption: state_flush uses a merge patch with no resourceVersion
# check. Introduce leader election before lifting that assumption.
#
# Configuration:
#   KEELSON_STATE_CONFIGMAP     ConfigMap name
#   KEELSON_STATE_NAMESPACE     override (default: read SA mount)
#   KEELSON_SA_NAMESPACE_FILE   override of SA namespace path (tests)
#
# Depends on: lib/log.bash

declare -gA STATE_FIELDS=()
declare -gA STATE_KEYS=()
declare -gA STATE_DIRTY=()
declare -gA STATE_DELETED=()
STATE_NAMESPACE=""
STATE_CONFIGMAP_NAME=""

# state_trigger_key <kind> <ns> <name>
state_trigger_key() {
    printf 'j--%s--%s--%s' "$1" "$2" "$3"
}

# state_schedule_key <kind> <ns> <name>
# Separate from the trigger key so the CronJob ledger keeps its shape. A
# schedule applies to every kind; the trigger gate only to CronJobs.
state_schedule_key() {
    printf 's--%s--%s--%s' "$1" "$2" "$3"
}

# state_get_next_due <kind> <ns> <name>
# Echoes the persisted next-due, or empty if this workload has none.
state_get_next_due() {
    state_get "$(state_schedule_key "$1" "$2" "$3")" next-due
}

# state_set_next_due <kind> <ns> <name> <unix-seconds>
#
# Persisted because it is the one piece of the cache worth surviving a
# restart. Everything else is rebuilt by one list per kind, but a schedule
# is not derivable: without this, a pod restart resets every workload to due
# now, and every watched workload polls its repository at once on every
# restart.
state_set_next_due() {
    state_set "$(state_schedule_key "$1" "$2" "$3")" next-due "$4"
}

# state_forget_workload <kind> <ns> <name>
# Drops both of a workload's keys on the next flush.
state_forget_workload() {
    state_forget "$(state_schedule_key "$1" "$2" "$3")"
    state_forget "$(state_trigger_key "$1" "$2" "$3")"
}

# state_forget <data-key>
# Marks a key for removal on the next flush.
#
# A merge patch removes a key by setting it null, so the field-level "empty
# value is omitted" rule in state_render_data_value cannot do this: dropping
# every field leaves the key present with an empty object.
state_forget() {
    local data_key=$1 pair
    for pair in "${!STATE_FIELDS[@]}"; do
        case "$pair" in
            "$data_key:"*) unset 'STATE_FIELDS[$pair]' ;;
        esac
    done
    unset 'STATE_KEYS[$data_key]'
    STATE_DELETED["$data_key"]=1
    STATE_DIRTY["$data_key"]=1
}

# state_reconcile_ledger
# Forgets ledger keys whose workload is no longer cached.
#
# Runs at the end of a full refresh, when the cache has just been rebuilt
# from the cluster and is therefore authoritative. Eviction during a normal
# reconcile only fires for a workload the scan saw disappear; anything that
# went while Keelson was down, or under a kind since dropped from the watched
# set, would otherwise keep its keys forever.
#
# Keys are snapshotted first: state_forget unsets entries in STATE_KEYS, and
# iterating a map while deleting from it skips entries.
state_reconcile_ledger() {
    inventory_enabled || return 0
    local keys=("${!STATE_KEYS[@]}")
    local key rest kind ns name
    for key in ${keys[@]+"${keys[@]}"}; do
        case "$key" in
            j--*|s--*) ;;
            *) continue ;;
        esac
        rest=${key#*--}
        kind=${rest%%--*}; rest=${rest#*--}
        ns=${rest%%--*}; name=${rest#*--}
        [ -n "$kind" ] && [ -n "$ns" ] && [ -n "$name" ] || continue
        inventory_get "$kind" "$ns" "$name" && continue
        state_forget "$key"
        log_debug ledger-forgotten key="$key" \
            msg="Dropped ledger key '$key': no such workload after a full refresh."
    done
    return 0
}

# state_init
# Discover own namespace, ensure ConfigMap exists, load it into the cache.
state_init() {
    STATE_CONFIGMAP_NAME="${KEELSON_STATE_CONFIGMAP:?KEELSON_STATE_CONFIGMAP required}"
    if [ -n "${KEELSON_STATE_NAMESPACE:-}" ]; then
        STATE_NAMESPACE="$KEELSON_STATE_NAMESPACE"
    else
        local ns_file="${KEELSON_SA_NAMESPACE_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/namespace}"
        if [ -r "$ns_file" ]; then
            STATE_NAMESPACE=$(cat "$ns_file")
        else
            log_error state-namespace-unknown ns-file="$ns_file" \
                msg="State init failed: could not read Keelson's own namespace from '$ns_file' and KEELSON_STATE_NAMESPACE is not set."
            return 1
        fi
    fi
    STATE_FIELDS=()
    STATE_KEYS=()
    STATE_DIRTY=()
    STATE_DELETED=()
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
                configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
                msg="Could not create state ConfigMap '$STATE_CONFIGMAP_NAME' in '$STATE_NAMESPACE'."
            return 1
        fi
        log_info_always state-configmap-created \
            configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
            msg="State ConfigMap '$STATE_CONFIGMAP_NAME' created in '$STATE_NAMESPACE'."
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

state_get_trigger_field() {
    state_get "$(state_trigger_key "$1" "$2" "$3")" "$4"
}

state_set_trigger_field() {
    state_set "$(state_trigger_key "$1" "$2" "$3")" "$4" "$5"
}

# state_clear_cache
# Wipes the in-memory cache. Currently called from the full-refresh tick
# even though log dedupe has moved to lib/log.bash - the trigger ledger
# benefits from a periodic ConfigMap reload to pick up any out-of-band
# edits a human made.
state_clear_cache() {
    STATE_FIELDS=()
    STATE_KEYS=()
    STATE_DIRTY=()
    STATE_DELETED=()
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
        if [ "$first" -eq 1 ]; then
            first=0
        else
            entries="$entries,"
        fi
        if [ -n "${STATE_DELETED[$key]:-}" ]; then
            # Unquoted null: that is what removes a key from a merge patch.
            entries="$entries\"$(state_json_escape "$key")\":null"
            continue
        fi
        value=$(state_render_data_value "$key")
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
        STATE_DELETED=()
        log_debug state-flushed \
            configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
            keys="$count" \
            msg="State flush wrote $count keys to ConfigMap '$STATE_CONFIGMAP_NAME' in '$STATE_NAMESPACE'."
        return 0
    fi
    log_error state-flush-failed \
        configmap="$STATE_CONFIGMAP_NAME" ns="$STATE_NAMESPACE" \
        keys="${#STATE_DIRTY[@]}" \
        msg="State flush failed: could not patch ConfigMap '$STATE_CONFIGMAP_NAME' in '$STATE_NAMESPACE' (${#STATE_DIRTY[@]} dirty keys)."
    return 1
}

# state_now
# Echoes the current time as an ISO-8601 UTC timestamp.
state_now() {
    printf '%(%Y-%m-%dT%H:%M:%SZ)T\n' -1
}
