# Scan orchestration for Keelson.
# Sourced; not directly executable.
#
# Depends on (must be sourced first):
#   lib/log.bash, lib/clock.bash, lib/policy.bash, lib/image.bash,
#   lib/annotations.bash, lib/workload.bash, lib/registry.bash,
#   lib/eligibility.bash, lib/update.bash, lib/state.bash, lib/inventory.bash
#
# scan_run runs one full pass over all watched kinds. apply=0 is dry-run;
# apply=1 applies patches via update_apply.
#
# Log dedupe is handled in-memory by lib/log.bash's per-level rate limiter
# (KEELSON_LOG_<LEVEL>_REPEAT_INTERVAL). The scan keeps no per-container
# state. The only persisted state is the CronJob always-once trigger gate,
# read once per scan via state_get_trigger_field.

# scan_run <apply> [poll-all]
#
# poll-all defaults to 1: a scan scans, which is what a one-shot
# keelson-boot-scan wants. The controller passes 0, because its scan only
# refreshes the cache and evicts; registry work is driven off next-due by the
# tick, so a workload's cadence is its own rather than the scan's.
scan_run() {
    local _scan_apply=${1:-0}
    local _scan_poll_all=${2:-1}
    local mode=dry-run
    [ "$_scan_apply" -eq 1 ] && mode=apply

    log_debug scan-start \
        mode="$mode" \
        scope="$KEELSON_SCOPE" \
        config-mode="$KEELSON_CONFIG_MODE" \
        msg="Scan starting in $mode mode (scope='$KEELSON_SCOPE', config-mode='$KEELSON_CONFIG_MODE')."

    registry_init

    local _scan_total=0 _scan_would_update=0 _scan_updated=0 \
          _scan_no_change=0 _scan_skip=0 _scan_error=0 _scan_managed=0

    # Inventory bookkeeping for this pass. SCAN_SEEN is what the cluster
    # still has; SCAN_LISTED is the kinds we actually managed to list, which
    # gates eviction so a transient API error is never read as "everything
    # was deleted". Both are locals: bash's dynamic scoping makes them
    # visible to scan_kind and scan_workload without leaking globals.
    local -A SCAN_SEEN=()
    local -A SCAN_LISTED=()
    local _scan_now _scan_interval=${KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT:-60}
    clock_read
    _scan_now=$(( CLOCK_NOW_US / 1000000 ))

    local kind
    for kind in $KEELSON_WATCHED_KINDS; do
        scan_kind "$kind"
    done

    scan_reconcile_inventory

    log_debug scan-summary \
        resources="$_scan_total" \
        would-update="$_scan_would_update" \
        updated="$_scan_updated" \
        no-change="$_scan_no_change" \
        skip="$_scan_skip" \
        error="$_scan_error" \
        msg="Scan complete: $_scan_total containers examined, $_scan_updated updated, $_scan_would_update would-update, $_scan_no_change no-change, $_scan_skip skipped, $_scan_error errored."
}

# scan_reconcile_inventory
# Forgets cached workloads the cluster no longer has. The scan is the only
# thing that sees the whole cluster, so it owns eviction; watch events handle
# individual deletes.
#
# Eviction is confined to kinds this pass listed successfully. A kind whose
# list call failed is left entirely alone, because "kubectl errored" and "all
# of them were deleted" are indistinguishable from here and only one of those
# should empty the cache.
scan_reconcile_inventory() {
    inventory_enabled || return 0
    local entry ekind ens ename
    inventory_list
    for entry in "${INVENTORY_ALL[@]}"; do
        ekind=${entry%% *}
        [ -n "${SCAN_LISTED[$ekind]:-}" ] || continue
        [ -n "${SCAN_SEEN[$entry]:-}" ] && continue
        read -r ekind ens ename <<<"$entry"
        inventory_evict "$ekind" "$ens" "$ename"
        # The ledger has to forget it too, or a workload's schedule and its
        # CronJob trigger entry outlive the workload and the ConfigMap only
        # ever grows.
        state_forget_workload "$ekind" "$ens" "$ename"
        log_debug inventory-evicted kind="$ekind" ns="$ens" name="$ename" \
            msg="Forgot $ekind '$ename' in '$ens': no longer present in the cluster."
    done
    return 0
}

# scan_refresh_kind <apply> <kind>
# Rebuilds one kind's cache from the cluster, from nothing.
#
# The cluster is listed *before* anything is dropped, so a failed list leaves
# the cache exactly as it was. Only once the list is in hand is the kind's
# cache wiped and rebuilt, which keeps the window where those workloads are
# invisible to the due-poll inside a single child rather than spanning ticks.
#
# next-due comes back from the ledger, not from the local file that was just
# thrown away, so a refresh corrects local drift without resetting schedules
# and triggering a poll of everything at once.
#
# No registry calls: this is a cache rebuild, and polling stays on each
# workload's own cadence.
scan_refresh_kind() {
    local _scan_apply=${1:-0} kind=$2
    local _scan_poll_all=0
    inventory_enabled || return 0

    local _scan_total=0 _scan_would_update=0 _scan_updated=0 \
          _scan_no_change=0 _scan_skip=0 _scan_error=0 _scan_managed=0
    local -A SCAN_SEEN=()
    local -A SCAN_LISTED=()
    local _scan_now _scan_interval=${KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT:-60}
    clock_read
    _scan_now=$(( CLOCK_NOW_US / 1000000 ))

    local list_json count i
    if ! list_json=$(workload_list_kind "$kind" 2>/dev/null); then
        log_error kubectl-list-failed kind="$kind" \
            msg="Full refresh of $kind skipped: could not list from kubectl. The cache is left as it was."
        return 0
    fi

    inventory_evict_kind "$kind"

    count=$(printf '%s' "$list_json" | yq -p=json '.items | length // 0')
    if [ -z "$count" ] || [ "$count" = "null" ]; then
        count=0
    fi
    for ((i=0; i<count; i++)); do
        scan_workload "$list_json" "$kind" "$i"
    done

    log_info_always inventory-refreshed kind="$kind" workloads="$count" \
        managed="$_scan_managed" \
        msg="Rebuilt the cache for $kind: $_scan_managed of $count are Keelson managed."
    return 0
}

# scan_refresh_queued
# Re-reads every identity the watchers queued and rewrites its cache record.
#
# This is what makes a watch event mean anything. The event carries only
# coordinates, so the cluster is the only place that can say what changed, and
# scan_workload already knows how to read it: annotations, containers, service
# account, pull secrets, suspend. The fingerprint it writes decides the rest.
# A workload whose decision inputs moved comes back due now, so the next tick
# polls it; one that only wrote its status fingerprints identically and keeps
# its schedule.
#
# Reads are per workload up to SCAN_QUEUE_LIST_THRESHOLD identities and one
# list per kind beyond it. A reconnect replays the entire cluster as ADDED, so
# the large case is routine rather than exceptional, and past a couple of
# dozen a single list is both fewer round trips and less total data than the
# gets it replaces.
#
# No registry calls and no eviction: a delete is handled by the watcher when
# it sees one, and anything missed there is the reconcile scan's job.
SCAN_QUEUE_LIST_THRESHOLD=25
scan_refresh_queued() {
    local _scan_apply=${1:-0}
    local _scan_poll_all=0
    inventory_enabled || return 0

    local _scan_total=0 _scan_would_update=0 _scan_updated=0 \
          _scan_no_change=0 _scan_skip=0 _scan_error=0 _scan_managed=0
    local -A SCAN_SEEN=()
    local -A SCAN_LISTED=()
    local _scan_now _scan_interval=${KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT:-60}
    clock_read
    _scan_now=$(( CLOCK_NOW_US / 1000000 ))

    local line kind ns name count=0
    local -a queued=()
    local -A kinds=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        queued+=("$line")
        kinds["${line%% *}"]=1
        count=$(( count + 1 ))
    done < <(queue_drain)
    [ "$count" -eq 0 ] && return 0

    if [ "$count" -ge "$SCAN_QUEUE_LIST_THRESHOLD" ]; then
        log_debug queue-refresh-listing kinds="${!kinds[*]}" queued="$count" \
            msg="Re-reading $count queued workloads by listing ${#kinds[@]} kinds rather than one get each."
        for kind in "${!kinds[@]}"; do
            scan_kind "$kind"
        done
        return 0
    fi

    for line in "${queued[@]}"; do
        read -r kind ns name <<<"$line"
        scan_refresh_workload "$kind" "$ns" "$name"
    done
    log_debug queue-refreshed queued="$count" \
        msg="Re-read $count queued workloads from the cluster."
    return 0
}

# scan_refresh_workload <kind> <ns> <name>
# Re-reads one workload and rewrites its cache record. Runs inside a caller
# that has already set up the _scan_* locals scan_workload reads.
#
# A workload that has gone returns an empty list rather than an error, and is
# left alone: the DELETED event that follows is what evicts it.
scan_refresh_workload() {
    local kind=$1 ns=$2 name=$3 obj_json count
    if ! obj_json=$(workload_get_one "$kind" "$ns" "$name" 2>/dev/null); then
        log_debug queue-refresh-failed kind="$kind" ns="$ns" name="$name" \
            msg="Could not re-read $kind '$name' in '$ns'; leaving its cache record as it was."
        return 0
    fi
    count=$(printf '%s' "$obj_json" | yq -p=json '.items | length // 0')
    [ "$count" = "1" ] || return 0
    scan_workload "$obj_json" "$kind" 0
}

scan_kind() {
    local kind=$1 list_json count i
    if ! list_json=$(workload_list_kind "$kind" 2>/dev/null); then
        log_error kubectl-list-failed kind="$kind" \
            msg="Could not list $kind workloads from kubectl."
        _scan_error=$((_scan_error + 1))
        return 0
    fi
    # Only a kind we actually listed is a candidate for eviction below.
    SCAN_LISTED["$kind"]=1
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
    local ns name annotations containers_path init_containers_path \
          ips_path sa_path containers_json init_containers_json \
          ips_json mf_json suspend sa_name

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
    init_containers_path=$(workload_init_containers_path "$kind")
    ips_path=$(workload_image_pull_secrets_path "$kind")
    sa_path=$(workload_service_account_name_path "$kind")
    containers_json=$(printf '%s' "$list_json" \
        | yq -p=json -o=json ".items[$i]$containers_path // []")
    init_containers_json=$(printf '%s' "$list_json" \
        | yq -p=json -o=json ".items[$i]$init_containers_path // []")
    # -I=0 keeps this on one line: it goes into the inventory record, which
    # is read back a line at a time.
    ips_json=$(printf '%s' "$list_json" \
        | yq -p=json -o=json -I=0 ".items[$i]$ips_path // []")
    # Default to "default" when serviceAccountName is unset - matches
    # kubelet behaviour at pod admission. Drives the SA-imagePullSecrets
    # walk that is gated by KEELSON_RESPECT_SA_PULL_SECRETS.
    sa_name=$(printf '%s' "$list_json" \
        | yq -p=json ".items[$i]$sa_path // \"default\"")

    local n j clist cjson cname cimage _workload_updated=0 \
          _workload_last_from="" _workload_last_to="" _workload_last_repo=""

    # Cached before anything is polled, because an update records the image it
    # applied against this record and caching afterwards would write the
    # pre-update one back over it.
    # A workload whose record could not be written is one workload lost until
    # the next pass, not a reason to abandon the other thirty in this one.
    scan_cache_workload "$kind" "$ns" "$name" "$annotations" "$suspend" \
        "$sa_name" "$ips_json" "$containers_json" "$init_containers_json" || true

    if [ "$_scan_poll_all" -eq 1 ]; then
        for clist in containers initContainers; do
            if [ "$clist" = containers ]; then
                cjson=$containers_json
            else
                cjson=$init_containers_json
            fi
            n=$(printf '%s' "$cjson" | yq -p=json 'length')
            for ((j=0; j<n; j++)); do
                cname=$(printf '%s' "$cjson" | yq -p=json ".[$j].name")
                cimage=$(printf '%s' "$cjson" | yq -p=json ".[$j].image")
                _scan_total=$((_scan_total + 1))
                scan_container "$kind" "$ns" "$name" "$clist" "$cname" "$cimage" \
                    "$annotations" "$ips_json" "$mf_json" "$sa_name"
            done
        done
    fi

    # Only when this pass polled. The trigger's always-once rule fires on
    # "no prior triggered-job recorded", and every cache-refresh path -- the
    # reconcile scan, the full refresh, the queued re-read -- runs in its own
    # child with its own copy of the ledger, so two of them overlapping would
    # each read "never triggered" and each create a Job. The paths that poll
    # are scan_poll_due, which evaluates the trigger itself, and a one-shot
    # scan_run from the CLI, which has nothing to race.
    if [ "$kind" = "CronJob" ] && [ "$_scan_apply" -eq 1 ] \
            && [ "$_scan_poll_all" -eq 1 ]; then
        scan_check_cronjob_trigger "$ns" "$name" "$annotations" \
            "$suspend" "$_workload_updated" \
            "$_workload_last_from" "$_workload_last_to" "$_workload_last_repo"
    fi
}

# scan_cache_workload <kind> <ns> <name> <annotations> <suspend> <sa> <ips>
#                     <containers-json> <init-containers-json>
#
# Records everything a later poll needs, so a due workload can be handled
# straight from cache with no read of the cluster. Cached whether or not any
# container was eligible: Keelson still needs to know the workload exists, so
# an annotation added later is noticed.
scan_cache_workload() {
    local kind=$1 ns=$2 name=$3 annotations=$4 suspend=$5 sa=$6 ips=$7 \
          containers_json=$8 init_containers_json=${9:-'[]'}
    inventory_enabled || return 0

    SCAN_SEEN["$kind $ns $name"]=1
    if scan_is_keelson_managed "$annotations"; then
        _scan_managed=$(( _scan_managed + 1 ))
    fi

    # Both lists in one block, each entry carrying the list it came from, so
    # everything downstream keeps a single loop and still knows where to
    # write an update back.
    local containers init_containers
    containers=$(printf '%s' "$containers_json" \
        | yq -p=json '.[] | "containers " + .name + "=" + .image')
    init_containers=$(printf '%s' "$init_containers_json" \
        | yq -p=json '.[] | "initContainers " + .name + "=" + .image')
    if [ -n "$init_containers" ]; then
        if [ -n "$containers" ]; then
            containers="${containers}"$'\n'"${init_containers}"
        else
            containers=$init_containers
        fi
    fi

    local interval=$_scan_interval sched
    annotation_get "$annotations" poll-schedule
    sched=$ANNOTATION_VALUE
    if [ -n "$sched" ]; then
        if clock_parse_duration "$sched"; then
            interval=$CLOCK_DURATION
            if [ "$interval" -eq 0 ]; then
                # They asked for faster than Keelson schedules. One second is
                # far nearer that intent than the global default, which would
                # be the opposite extreme.
                interval=1
                log_warn poll-schedule-too-fast kind="$kind" ns="$ns" name="$name" \
                    value="$sched" \
                    msg="poll-schedule '$sched' on $kind '$name' in '$ns' is below the one-second resolution Keelson schedules at; using 1s."
            fi
        else
            log_warn poll-schedule-invalid kind="$kind" ns="$ns" name="$name" \
                value="$sched" fallback="$interval" \
                msg="Ignoring unparseable poll-schedule '$sched' on $kind '$name' in '$ns'; using ${interval}s. Durations look like 30s, 5m, 2h or 1d."
        fi
    fi

    inventory_fingerprint "$interval" "$suspend" "$sa" "$ips" \
        "$annotations" "$containers"
    local computed_fingerprint=$INVENTORY_COMPUTED_FINGERPRINT

    # A workload already cached keeps its place in the cycle; a new one gets
    # an offset inside its first interval, so workloads cached in the same
    # pass do not all fall due together forever after.
    local next_due persisted
    if inventory_get "$kind" "$ns" "$name"; then
        next_due=$INVENTORY_NEXT_DUE
        if [ "$INVENTORY_FINGERPRINT" != "$computed_fingerprint" ]; then
            # The one comparison that decides whether anything Keelson cares
            # about moved, wherever the read came from: a queued re-read after
            # a watch event, or this pass sweeping the whole cluster for what
            # the watchers missed while one was down. Making it due now is
            # what stops a workload on a long schedule sitting out of sync
            # until its next scheduled poll.
            next_due=$_scan_now
            log_info_always scan-resync kind="$kind" ns="$ns" name="$name" \
                msg="$kind '$name' in '$ns' changed; polling it now rather than waiting for its schedule."
        fi
    else
        # A restart empties the cache but not the ledger, so a workload
        # resumes its schedule rather than falling due immediately along with
        # everything else.
        persisted=$(state_get_next_due "$kind" "$ns" "$name")
        if [ -n "$persisted" ]; then
            next_due=$persisted
        else
            inventory_first_due "$kind" "$ns" "$name" "$interval" "$_scan_now"
            next_due=$INVENTORY_FIRST_DUE
            state_set_next_due "$kind" "$ns" "$name" "$next_due"
        fi
    fi

    inventory_put "$kind" "$ns" "$name" "$next_due" "$interval" "$suspend" \
        "$sa" "$ips" "$annotations" "$containers"
}

# scan_log_managed_workloads
# Lists the workloads Keelson will act on, grouped by namespace, from the
# cache rather than the cluster. Returns 1 while the cache is still empty, so
# the caller can try again once a scan has filled it.
scan_log_managed_workloads() {
    inventory_enabled || return 0
    inventory_list
    local total=${#INVENTORY_ALL[@]}
    [ "$total" -gt 0 ] || return 1

    local entry kind ns name pad last_ns=
    local -a rows=()
    for entry in "${INVENTORY_ALL[@]}"; do
        read -r kind ns name <<<"$entry"
        inventory_get "$kind" "$ns" "$name" || continue
        scan_is_keelson_managed "$INVENTORY_ANNOTATIONS" || continue
        rows+=("$ns $kind $name")
    done

    log_info_always managed-workloads managed="${#rows[@]}" cached="$total" \
        msg="Keelson is managing ${#rows[@]} of $total cached workloads:"
    [ "${#rows[@]}" -gt 0 ] || return 0

    while read -r ns kind name; do
        if [ "$ns" != "$last_ns" ]; then
            log_info_always managed-namespace ns="$ns" msg="  $ns"
            last_ns=$ns
        fi
        printf -v pad '%-11s' "$kind"
        log_info_always managed-workload kind="$kind" ns="$ns" name="$name" \
            msg="    $pad $name"
    done < <(printf '%s\n' "${rows[@]}" | sort)
    return 0
}

# scan_is_keelson_managed <annotations>
# True when the workload carries a policy annotation Keelson will act on,
# workload-wide or per-container, under the prefix the config mode honours.
#
# policy is the switch: a workload with only poll-schedule or match-tag has
# configured nothing that acts, and counting it would hide exactly that
# mistake from whoever made it.
scan_is_keelson_managed() {
    local ann=$1 line key
    local mode=${KEELSON_CONFIG_MODE:-keelson}
    while IFS= read -r line; do
        key=${line%%=*}
        case "$mode" in
            keelson)
                case "$key" in keelson.pro/policy|keelson.pro/policy.*) return 0 ;; esac
                ;;
            keel)
                case "$key" in keel.sh/policy|keel.sh/policy.*) return 0 ;; esac
                ;;
            *)
                case "$key" in
                    keelson.pro/policy|keelson.pro/policy.*|keel.sh/policy|keel.sh/policy.*)
                        return 0 ;;
                esac
                ;;
        esac
    done <<< "$ann"
    return 1
}

# Flatten one workload's annotations object to lines of "<key>=<value>",
# stable for downstream annotation_get. yq's props output escapes dots in
# keys with backslashes; we strip only those (iteratively, anchored to the
# key portion) and leave value-side backslashes intact (regexes need them).
#
# Only Keelson's own prefixes survive, which is all annotation_get ever asks
# for. The rest belong to other people and move constantly: patching a
# Deployment makes its controller bump deployment.kubernetes.io/revision, and
# a rollout restart writes kubectl.kubernetes.io/restartedAt. Carried into the
# record they end up in the fingerprint, where each one reads as "a decision
# input moved" and forces a poll that can only return what the schedule would.
scan_flatten_annotations() {
    local list_json=$1 i=$2
    printf '%s' "$list_json" \
        | yq -p=json -o=props ".items[$i].metadata.annotations // {}" 2>/dev/null \
        | sed -E ':a; s/^([^=]*)\\\./\1./; ta; s/ = /=/' \
        | grep -E '^(keelson\.pro|keel\.sh)/' || true
}

# scan_container <kind> <ns> <name> <list> <container> <image> <annotations>
#                <ips-json> [managed-fields-json] [service-account]
#
# <list> is "containers" or "initContainers": which array the container lives
# in, carried through to the write so the patch lands in the right place.
scan_container() {
    local kind=$1 ns=$2 name=$3 clist=$4 cname=$5 cimage=$6 ann=$7 ips_json=$8 \
          mf_json=${9:-} sa_name=${10:-}

    local result
    eligibility_check "$ann" "$cimage" "$cname" || true
    result=$ELIGIBILITY_RESULT
    case "$result" in
        SKIP\ *)
            log_debug skip-not-eligible \
                kind="$kind" ns="$ns" name="$name" container="$cname" \
                image="$cimage" reason="${result#SKIP }" \
                msg="Skipped $kind '$name'/$cname in '$ns' (image '$cimage'): ${result#SKIP }."
            _scan_skip=$((_scan_skip + 1))
            return 0
            ;;
    esac

    local policy position
    policy=$(printf '%s' "$result" | awk '{print $2}')
    position=$(printf '%s' "$result" | awk '{print $3}')

    local creds
    if ! creds=$(registry_resolve_creds "$cimage" "$ips_json" "$ns" "$ann" "$sa_name" "$cname"); then
        log_error registry-creds-failed \
            kind="$kind" ns="$ns" name="$name" container="$cname" \
            detail="$cimage" \
            msg="Could not resolve registry credentials for $kind '$name'/$cname in '$ns' (image '$cimage')."
        _scan_error=$((_scan_error + 1))
        return 0
    fi

    local tags_raw
    if ! tags_raw=$(registry_list_tags "$cimage" "$creds"); then
        local reason=${REGISTRY_LAST_ERROR:-}
        log_flatten "$reason"
        log_debug registry-list-tags-detail \
            kind="$kind" ns="$ns" name="$name" container="$cname" \
            msg="Listing tags for image '$cimage' failed, full output: ${LOG_FLAT:-no error output}"
        log_hint "$reason"
        reason=$LOG_HINT
        local reason_clause=""
        [ -n "$reason" ] && reason_clause=": $reason"
        log_error registry-list-tags-failed \
            kind="$kind" ns="$ns" name="$name" container="$cname" \
            detail="$cimage" reason="$reason" \
            msg="Could not list tags for $kind '$name'/$cname in '$ns' (image '$cimage')${reason_clause}."
        _scan_error=$((_scan_error + 1))
        return 0
    fi

    local match_tag match_mode current_tag winner candidate
    annotation_get "$ann" match-tag "$cname"
    match_tag=$ANNOTATION_VALUE
    annotation_get "$ann" match-mode "$cname"
    match_mode=$ANNOTATION_VALUE
    match_mode=${match_mode:-glob}
    image_tag "$cimage"
    current_tag=$IMAGE_TAG
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
            log_debug no-change \
                kind="$kind" ns="$ns" name="$name" container="$cname" \
                current="$current_tag" policy="$policy" position="$position" \
                msg="No change for $kind '$name'/$cname in '$ns': current tag '$current_tag' is the winner (policy '$policy', position '$position')."
        else
            log_debug dry-run-no-change \
                kind="$kind" ns="$ns" name="$name" container="$cname" \
                current="$current_tag" policy="$policy" position="$position" \
                msg="Dry-run: no change for $kind '$name'/$cname in '$ns': current tag '$current_tag' is the winner (policy '$policy', position '$position')."
        fi
        _scan_no_change=$((_scan_no_change + 1))
        return 0
    fi

    if [ "$_scan_apply" -ne 1 ]; then
        log_info dry-run-would-update \
            kind="$kind" ns="$ns" name="$name" container="$cname" \
            current="$current_tag" candidate="$winner" \
            policy="$policy" position="$position" \
            msg="Dry-run: would update $kind '$name'/$cname in '$ns' from $current_tag to $winner (policy '$policy', position '$position')."
        _scan_would_update=$((_scan_would_update + 1))
        return 0
    fi

    local new_image repo
    image_repo "$cimage"
    repo=$IMAGE_REPO
    new_image="$repo:$winner"
    if update_apply "$kind" "$ns" "$name" "$clist" "$cname" "$new_image" "$current_tag" "$mf_json" "$ann"; then
        inventory_set_container_image "$kind" "$ns" "$name" "$clist" "$cname" "$new_image" \
            || log_warn inventory-image-not-recorded \
                kind="$kind" ns="$ns" name="$name" container="$cname" \
                msg="Could not record the applied image for $kind '$name'/$cname in '$ns' against its cache record; the re-read after this update will resync it instead."
        _scan_updated=$((_scan_updated + 1))
        _workload_updated=1
        _workload_last_from=$current_tag
        _workload_last_to=$winner
        _workload_last_repo=$repo
    else
        log_error update-failed \
            kind="$kind" ns="$ns" name="$name" container="$cname" \
            detail="$new_image" \
            msg="Update failed for $kind '$name'/$cname in '$ns' to image '$new_image'."
        _scan_error=$((_scan_error + 1))
    fi
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
scan_check_cronjob_trigger() {
    local ns=$1 name=$2 ann=$3 suspend=$4 updated=$5
    local from_tag=${6:-} to_tag=${7:-} repo=${8:-}
    local trigger
    annotation_get "$ann" trigger-job-on-update
    trigger=$ANNOTATION_VALUE
    [ "$trigger" = "true" ] || return 0

    if [ "$suspend" != "true" ]; then
        log_error cronjob-trigger-requires-suspend \
            kind=CronJob ns="$ns" name="$name" detail="$name" \
            msg="CronJob '$name' in '$ns' has trigger-job-on-update=true but spec.suspend is not true; refusing to trigger to avoid racing the scheduler."
        return 0
    fi

    local prior
    prior=$(state_get_trigger_field CronJob "$ns" "$name" triggered-job)
    if [ "$updated" -ne 1 ] && [ -n "$prior" ]; then
        return 0
    fi

    if update_trigger_cronjob "$ns" "$name" "$from_tag" "$to_tag" "$repo"; then
        scan_record_trigger_success CronJob "$ns" "$name"
    else
        log_error cronjob-job-trigger-failed \
            kind=CronJob ns="$ns" name="$name" detail="$name" \
            msg="Could not trigger Job from CronJob '$name' in '$ns'."
    fi
}

scan_record_trigger_success() {
    local kind=$1 ns=$2 name=$3
    local now
    now=$(state_now)
    state_set_trigger_field "$kind" "$ns" "$name" triggered-at "$now"
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

# scan_poll_due <apply> <now>
# Polls every workload whose next-due has arrived, straight from the cache.
#
# This is what the tick asks each second, so a workload's cadence is its own
# and not the scan's. Nothing here lists the cluster: the record already
# holds the containers, annotations and credentials a decision needs.
#
# managedFields is the one thing deliberately not cached. It changes whenever
# anyone writes the object, so a cached copy could be hours stale and drive
# the field-manager strategy to the wrong owner.
#
# Nor is it fetched here. Only update_apply reads it, and only when a write is
# actually about to happen, which almost no poll reaches: fetching it per due
# workload spent a kubectl process on every one of them to throw the answer
# away. update_apply fetches its own when handed nothing.
scan_poll_due() {
    local _scan_apply=${1:-0} now=$2
    inventory_enabled || return 0

    inventory_due "$now"
    [ "${#INVENTORY_DUE[@]}" -eq 0 ] && return 0

    local _scan_total=0 _scan_would_update=0 _scan_updated=0 \
          _scan_no_change=0 _scan_skip=0 _scan_error=0 _scan_managed=0
    registry_init

    local entry kind ns name i
    for entry in "${INVENTORY_DUE[@]}"; do
        read -r kind ns name <<<"$entry"
        inventory_get "$kind" "$ns" "$name" || continue

        local _workload_updated=0 \
              _workload_last_from="" _workload_last_to="" _workload_last_repo=""
        for (( i = 0; i < ${#INVENTORY_CONTAINER_NAMES[@]}; i++ )); do
            _scan_total=$((_scan_total + 1))
            scan_container "$kind" "$ns" "$name" \
                "${INVENTORY_CONTAINER_LISTS[$i]}" \
                "${INVENTORY_CONTAINER_NAMES[$i]}" "${INVENTORY_CONTAINER_IMAGES[$i]}" \
                "$INVENTORY_ANNOTATIONS" "$INVENTORY_IMAGE_PULL_SECRETS" \
                "" "$INVENTORY_SERVICE_ACCOUNT"
        done

        if [ "$kind" = "CronJob" ] && [ "$_scan_apply" -eq 1 ]; then
            scan_check_cronjob_trigger "$ns" "$name" "$INVENTORY_ANNOTATIONS" \
                "$INVENTORY_SUSPEND" "$_workload_updated" \
                "$_workload_last_from" "$_workload_last_to" "$_workload_last_repo"
        fi

        inventory_mark_polled "$kind" "$ns" "$name" "$now" \
            || log_warn inventory-not-rescheduled kind="$kind" ns="$ns" name="$name" \
                msg="Could not push $kind '$name' in '$ns' out to its next poll; it left the cache between being read as due and being polled."
        inventory_get "$kind" "$ns" "$name" \
            && state_set_next_due "$kind" "$ns" "$name" "$INVENTORY_NEXT_DUE"
    done

    log_debug poll-summary \
        workloads="${#INVENTORY_DUE[@]}" \
        resources="$_scan_total" \
        updated="$_scan_updated" \
        no-change="$_scan_no_change" \
        skip="$_scan_skip" \
        error="$_scan_error" \
        msg="Polled ${#INVENTORY_DUE[@]} due workloads: $_scan_total containers examined, $_scan_updated updated, $_scan_no_change no-change, $_scan_skip skipped, $_scan_error errored."
    return 0
}
