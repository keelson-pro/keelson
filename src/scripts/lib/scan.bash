# Scan orchestration for Keelson.
# Sourced; not directly executable.
#
# Depends on (must be sourced first):
#   lib/log.bash, lib/policy.bash, lib/image.bash, lib/annotations.bash,
#   lib/workload.bash, lib/registry.bash, lib/eligibility.bash, lib/update.bash,
#   lib/state.bash
#
# scan_run runs one full pass over all watched kinds. apply=0 is the
# original dry-run (Stage 3); apply=1 applies patches via update_apply
# (Stage 5). Counters live in the function frame; logging surfaces
# per-resource detail and a final scan-summary.
#
# Log dedupe (Stage 8): scan-level skip/error logs are suppressed when the
# per-container state in lib/state.bash already records the same (event,
# detail). Reads always touch the in-memory cache; writes are gated on
# apply mode so dry-run never mutates the ConfigMap.

scan_run() {
    local _scan_apply=${1:-0}
    local mode=dry-run
    [ "$_scan_apply" -eq 1 ] && mode=apply

    log_info scan-start \
        mode="$mode" \
        scope="$KEELSON_SCOPE" \
        config-mode="$KEELSON_CONFIG_MODE"

    registry_init

    local _scan_total=0 _scan_would_update=0 _scan_updated=0 \
          _scan_no_change=0 _scan_skip=0 _scan_error=0
    local kind
    for kind in $KEELSON_WATCHED_KINDS; do
        scan_kind "$kind"
    done

    log_info scan-summary \
        resources="$_scan_total" \
        would-update="$_scan_would_update" \
        updated="$_scan_updated" \
        no-change="$_scan_no_change" \
        skip="$_scan_skip" \
        error="$_scan_error"
}

scan_kind() {
    local kind=$1 list_json count i
    if ! list_json=$(workload_list_kind "$kind" 2>/dev/null); then
        log_error kubectl-list-failed kind="$kind"
        _scan_error=$((_scan_error + 1))
        return 0
    fi
    count=$(printf '%s' "$list_json" | yq -p=json '.items | length // 0')
    if [ -z "$count" ] || [ "$count" = "null" ]; then
        count=0
    fi
    [ "$count" -eq 0 ] && return 0
    for ((i=0; i<count; i++)); do
        scan_workload "$list_json" "$kind" "$i"
    done
}

scan_workload() {
    local list_json=$1 kind=$2 i=$3
    local ns name annotations containers_path ips_path sa_path \
          containers_json ips_json mf_json suspend sa_name

    ns=$(printf '%s' "$list_json" | yq -p=json ".items[$i].metadata.namespace")
    name=$(printf '%s' "$list_json" | yq -p=json ".items[$i].metadata.name")
    annotations=$(scan_flatten_annotations "$list_json" "$i")
    mf_json=$(printf '%s' "$list_json" \
        | yq -p=json -o=json ".items[$i].metadata.managedFields // []")

    suspend=""
    if [ "$kind" = "CronJob" ]; then
        suspend=$(printf '%s' "$list_json" \
            | yq -p=json ".items[$i].spec.suspend // false")
    fi

    containers_path=$(workload_containers_path "$kind")
    ips_path=$(workload_image_pull_secrets_path "$kind")
    sa_path=$(workload_service_account_name_path "$kind")
    containers_json=$(printf '%s' "$list_json" \
        | yq -p=json -o=json ".items[$i]$containers_path // []")
    ips_json=$(printf '%s' "$list_json" \
        | yq -p=json -o=json ".items[$i]$ips_path // []")
    # Default to "default" when serviceAccountName is unset - matches
    # kubelet behaviour at pod admission. Drives the SA-imagePullSecrets
    # walk that is gated by KEELSON_RESPECT_SA_PULL_SECRETS.
    sa_name=$(printf '%s' "$list_json" \
        | yq -p=json ".items[$i]$sa_path // \"default\"")

    local n j cname cimage _workload_updated=0
    n=$(printf '%s' "$containers_json" | yq -p=json 'length')
    for ((j=0; j<n; j++)); do
        cname=$(printf '%s' "$containers_json" | yq -p=json ".[$j].name")
        cimage=$(printf '%s' "$containers_json" | yq -p=json ".[$j].image")
        _scan_total=$((_scan_total + 1))
        scan_container "$kind" "$ns" "$name" "$cname" "$cimage" \
            "$annotations" "$ips_json" "$mf_json" "$sa_name"
    done

    if [ "$kind" = "CronJob" ] && [ "$_scan_apply" -eq 1 ]; then
        scan_check_cronjob_trigger "$ns" "$name" "$annotations" \
            "$suspend" "$_workload_updated"
    fi
}

# Flatten one workload's annotations object to lines of "<key>=<value>",
# stable for downstream annotation_get. yq's props output escapes dots in
# keys with backslashes; we strip only those (iteratively, anchored to the
# key portion) and leave value-side backslashes intact (regexes need them).
scan_flatten_annotations() {
    local list_json=$1 i=$2
    printf '%s' "$list_json" \
        | yq -p=json -o=props ".items[$i].metadata.annotations // {}" 2>/dev/null \
        | sed -E ':a; s/^([^=]*)\\\./\1./; ta; s/ = /=/'
}

scan_container() {
    local kind=$1 ns=$2 name=$3 cname=$4 cimage=$5 ann=$6 ips_json=$7 \
          mf_json=${8:-} sa_name=${9:-}

    local result
    result=$(eligibility_check "$ann" "$cimage" "$cname") || true
    case "$result" in
        SKIP\ *)
            scan_emit_skip "$kind" "$ns" "$name" "$cname" "$cimage" \
                "${result#SKIP }"
            _scan_skip=$((_scan_skip + 1))
            return 0
            ;;
    esac

    local policy position
    policy=$(printf '%s' "$result" | awk '{print $2}')
    position=$(printf '%s' "$result" | awk '{print $3}')

    local creds
    if ! creds=$(registry_resolve_creds "$cimage" "$ips_json" "$ns" "$ann" "$sa_name" "$cname"); then
        scan_emit_container_error "$kind" "$ns" "$name" "$cname" \
            registry-creds-failed "$cimage"
        _scan_error=$((_scan_error + 1))
        return 0
    fi

    local tags_raw
    if ! tags_raw=$(registry_list_tags "$cimage" "$creds"); then
        scan_emit_container_error "$kind" "$ns" "$name" "$cname" \
            registry-list-tags-failed "$cimage"
        _scan_error=$((_scan_error + 1))
        return 0
    fi

    local match_tag match_mode current_tag winner candidate
    match_tag=$(annotation_get "$ann" match-tag "$cname")
    match_mode=$(annotation_get "$ann" match-mode "$cname")
    match_mode=${match_mode:-glob}
    current_tag=$(image_tag "$cimage")
    winner=$current_tag

    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        scan_tag_passes_filter "$candidate" "$match_tag" "$match_mode" || continue
        case "$candidate" in
            *[!0-9.]*) continue ;;
        esac
        if tag_is_newer "$winner" "$candidate" "$position"; then
            winner=$candidate
        fi
    done <<< "$tags_raw"

    if [ "$winner" = "$current_tag" ]; then
        if [ "$_scan_apply" -eq 1 ]; then
            log_info no-change \
                kind="$kind" ns="$ns" name="$name" container="$cname" \
                current="$current_tag" policy="$policy" position="$position"
            scan_record_no_change "$kind" "$ns" "$name" "$cname" "$current_tag"
        else
            log_info dry-run-no-change \
                kind="$kind" ns="$ns" name="$name" container="$cname" \
                current="$current_tag" policy="$policy" position="$position"
        fi
        _scan_no_change=$((_scan_no_change + 1))
        return 0
    fi

    if [ "$_scan_apply" -ne 1 ]; then
        log_info dry-run-would-update \
            kind="$kind" ns="$ns" name="$name" container="$cname" \
            current="$current_tag" candidate="$winner" \
            policy="$policy" position="$position"
        _scan_would_update=$((_scan_would_update + 1))
        return 0
    fi

    local new_image
    new_image="$(image_repo "$cimage"):$winner"
    if update_apply "$kind" "$ns" "$name" "$cname" "$new_image" "$mf_json"; then
        _scan_updated=$((_scan_updated + 1))
        _workload_updated=1
        scan_record_update "$kind" "$ns" "$name" "$cname" "$winner"
    else
        scan_emit_container_error "$kind" "$ns" "$name" "$cname" \
            update-failed "$new_image"
        _scan_error=$((_scan_error + 1))
    fi
}

# scan_emit_skip <kind> <ns> <name> <container> <image> <reason>
# Logs skip-not-eligible only when the cached skip-reason differs (or is
# empty). Writes the new reason+timestamp to state in apply mode.
scan_emit_skip() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5 reason=$6
    local cached
    cached=$(state_get_container_field "$kind" "$ns" "$name" "$container" skip-reason)
    if [ "$cached" != "$reason" ]; then
        log_info skip-not-eligible \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" reason="$reason"
        if [ "$_scan_apply" -eq 1 ]; then
            state_set_container_field "$kind" "$ns" "$name" "$container" \
                skip-reason "$reason"
            state_set_container_field "$kind" "$ns" "$name" "$container" \
                skip-at "$(state_now)"
        fi
    fi
}

# scan_emit_container_error <kind> <ns> <name> <container> <event> <detail>
# Logs an error event only when (event, detail) differs from cached state.
# Writes new error fields to state in apply mode.
scan_emit_container_error() {
    local kind=$1 ns=$2 name=$3 container=$4 event=$5 detail=$6
    local cached_event cached_detail
    cached_event=$(state_get_container_field "$kind" "$ns" "$name" "$container" error-event)
    cached_detail=$(state_get_container_field "$kind" "$ns" "$name" "$container" error-detail)
    if [ "$cached_event" != "$event" ] || [ "$cached_detail" != "$detail" ]; then
        log_error "$event" \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            detail="$detail"
        if [ "$_scan_apply" -eq 1 ]; then
            state_set_container_field "$kind" "$ns" "$name" "$container" \
                error-event "$event"
            state_set_container_field "$kind" "$ns" "$name" "$container" \
                error-detail "$detail"
            state_set_container_field "$kind" "$ns" "$name" "$container" \
                error-at "$(state_now)"
        fi
    fi
}

# scan_record_no_change <kind> <ns> <name> <container> <tag>
# Records the observed tag and clears any prior skip/error markers so the
# next ineligible/erroneous transition re-emits its log.
scan_record_no_change() {
    local kind=$1 ns=$2 name=$3 container=$4 tag=$5
    state_set_container_field "$kind" "$ns" "$name" "$container" checked-tag "$tag"
    state_set_container_field "$kind" "$ns" "$name" "$container" checked-at "$(state_now)"
    state_set_container_field "$kind" "$ns" "$name" "$container" skip-reason ""
    state_set_container_field "$kind" "$ns" "$name" "$container" error-event ""
    state_set_container_field "$kind" "$ns" "$name" "$container" error-detail ""
}

# scan_record_update <kind> <ns> <name> <container> <tag>
# Records a successful update: checked- and update- fields refresh; prior
# skip and error markers clear.
scan_record_update() {
    local kind=$1 ns=$2 name=$3 container=$4 tag=$5
    local now
    now=$(state_now)
    state_set_container_field "$kind" "$ns" "$name" "$container" checked-tag "$tag"
    state_set_container_field "$kind" "$ns" "$name" "$container" checked-at "$now"
    state_set_container_field "$kind" "$ns" "$name" "$container" update-tag "$tag"
    state_set_container_field "$kind" "$ns" "$name" "$container" update-at "$now"
    state_set_container_field "$kind" "$ns" "$name" "$container" skip-reason ""
    state_set_container_field "$kind" "$ns" "$name" "$container" error-event ""
    state_set_container_field "$kind" "$ns" "$name" "$container" error-detail ""
}

# scan_check_cronjob_trigger <ns> <name> <ann> <suspend> <updated>
# Apply-mode CronJob trigger gate.
#
# Preconditions to trigger:
#   trigger-job-on-update == "true"
#   spec.suspend          == "true"   (otherwise the scheduler would race us)
#
# Then trigger when EITHER:
#   - this scan updated a container in the workload, or
#   - no prior triggered-job is recorded (first-observation always-once).
#
# When trigger=true but suspend!=true, log cronjob-trigger-requires-suspend
# (deduped via state error-event) and do NOT create the Job.
scan_check_cronjob_trigger() {
    local ns=$1 name=$2 ann=$3 suspend=$4 updated=$5
    local trigger
    trigger=$(annotation_get "$ann" trigger-job-on-update)
    [ "$trigger" = "true" ] || return 0

    if [ "$suspend" != "true" ]; then
        scan_emit_trigger_error CronJob "$ns" "$name" \
            cronjob-trigger-requires-suspend "$name"
        return 0
    fi

    local prior
    prior=$(state_get_trigger_field CronJob "$ns" "$name" triggered-job)
    if [ "$updated" -ne 1 ] && [ -n "$prior" ]; then
        return 0
    fi

    if update_trigger_cronjob "$ns" "$name"; then
        scan_record_trigger_success CronJob "$ns" "$name"
    else
        scan_emit_trigger_error CronJob "$ns" "$name" \
            cronjob-job-trigger-failed "$name"
    fi
}

# scan_emit_trigger_error <kind> <ns> <name> <event> <detail>
scan_emit_trigger_error() {
    local kind=$1 ns=$2 name=$3 event=$4 detail=$5
    local cached_event cached_detail
    cached_event=$(state_get_trigger_field "$kind" "$ns" "$name" error-event)
    cached_detail=$(state_get_trigger_field "$kind" "$ns" "$name" error-detail)
    if [ "$cached_event" != "$event" ] || [ "$cached_detail" != "$detail" ]; then
        log_error "$event" kind="$kind" ns="$ns" name="$name" detail="$detail"
        state_set_trigger_field "$kind" "$ns" "$name" error-event "$event"
        state_set_trigger_field "$kind" "$ns" "$name" error-detail "$detail"
        state_set_trigger_field "$kind" "$ns" "$name" error-at "$(state_now)"
    fi
}

scan_record_trigger_success() {
    local kind=$1 ns=$2 name=$3
    local now
    now=$(state_now)
    state_set_trigger_field "$kind" "$ns" "$name" triggered-at "$now"
    state_set_trigger_field "$kind" "$ns" "$name" error-event ""
    state_set_trigger_field "$kind" "$ns" "$name" error-detail ""
    # The job name is generated inside update_trigger_cronjob; we record the
    # most recent invocation timestamp here. The Job creation log carries
    # the generated name for forensic lookup. A future improvement could
    # plumb the name back if a single canonical record per-CronJob is needed.
    state_set_trigger_field "$kind" "$ns" "$name" triggered-job "$now"
}

scan_tag_passes_filter() {
    local tag=$1 pattern=${2:-} mode=${3:-glob}
    [ -z "$pattern" ] && return 0
    case "$mode" in
        regex)
            [[ "$tag" =~ $pattern ]]
            ;;
        glob|*)
            # shellcheck disable=SC2254
            case "$tag" in
                $pattern) return 0 ;;
                *) return 1 ;;
            esac
            ;;
    esac
}
