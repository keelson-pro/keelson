# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
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

# Set by scan_extract_workload, read by scan_workload.
SCAN_WL_NS=
SCAN_WL_NAME=
SCAN_WL_ANNOTATIONS=
SCAN_WL_MANAGED_FIELDS=
SCAN_WL_SUSPEND=
# Both container lists in one block, each line "<list> <name>=<image>", so
# everything downstream keeps a single loop and still knows which array to
# write an update back to.
SCAN_WL_CONTAINER_PAIRS=
SCAN_WL_IPS_JSON=
SCAN_WL_SA_NAME=

# Set by scan_extract_kind, consumed by scan_each_workload.
SCAN_KIND_RECORDS=
SCAN_KIND_COUNT=0
SCAN_POLL_OVERRUNS=0

# scan_run <apply> [poll-all]
#
# poll-all defaults to 1: a scan scans, which is what a one-shot
# keelson-user-recheck wants. The controller passes 0, because its scan only
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

    scan_each_workload "$list_json" "$kind"
    count=$SCAN_KIND_COUNT

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
    # No length query: the extraction reports what it found, and a workload
    # that has gone yields no records at all.
    scan_each_workload "$obj_json" "$kind"
}

# scan_each_workload <list-json> <kind>
# Extracts every workload in a kubectl List with one yq, then hands each to
# scan_workload. Sets SCAN_KIND_COUNT to how many were seen.
#
# One extraction per kind rather than per workload. Extracting per workload
# re-parsed the whole list document every time, which on fifty workloads was
# ~850 forks and ~3 CPU-seconds every reconcile -- a constant cost whether the
# estate was asleep or saturated, and two thirds of all CPU. It is the same
# shape that was removed from state_load one layer down.
scan_each_workload() {
    local list_json=$1 kind=$2
    SCAN_KIND_COUNT=0
    scan_extract_kind "$list_json" "$kind" || return 0
    [ -n "$SCAN_KIND_RECORDS" ] || return 0

    # Records are separated by a W| line, so the records themselves say how
    # many there are and the separate length query goes away with the rest.
    local rest=$SCAN_KIND_RECORDS block
    rest=${rest#*W|$'\n'}
    while [ -n "$rest" ]; do
        case "$rest" in
            *$'\n'W\|$'\n'*)
                block=${rest%%$'\n'W|$'\n'*}
                rest=${rest#*$'\n'W|$'\n'}
                ;;
            *)
                block=$rest
                rest=
                ;;
        esac
        SCAN_KIND_COUNT=$(( SCAN_KIND_COUNT + 1 ))
        scan_workload "$block" "$kind"
    done
    return 0
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

    # One yq for the whole kind, not one per workload. Extracting per workload
    # re-parsed the entire list document every time, which on fifty workloads
    # was ~850 forks and ~3 CPU-seconds every reconcile -- a constant cost
    # whether the estate was asleep or saturated, and two thirds of all CPU.
    # It is the same shape that was removed from state_load one layer down.
    #
    # No separate count call either: the records themselves say how many there
    # are, so the length query goes with it.
    scan_each_workload "$list_json" "$kind"
}

# scan_extract_workload <list-json> <kind> <index>
# Pulls everything scan_workload needs out of one entry of a kubectl List,
# into SCAN_WL_* rather than onto stdout.
#
# One function so the reads have one place to be counted: this runs once per
# workload per scan, and a cluster of fifty makes whatever it costs the
# dominant cost of a pass.
scan_extract_kind() {
    local list_json=$1 kind=$2
    local base suspend_expr=''

    SCAN_KIND_RECORDS=
    base=$(workload_pod_spec_path "$kind") || return 1

    # Only CronJob carries suspend, and "no such field" has to stay
    # distinguishable from a CronJob that is not suspended.
    if [ "$kind" = "CronJob" ]; then
        suspend_expr='"suspend=" + ($w.spec.suspend // false | @json),'
    fi

    # -r keeps every scalar raw, so a serviceAccountName of "sa: weird" or a
    # match-tag of "*-rc" arrives as written rather than YAML-quoted.
    # @json holds each sub-object to one line, which the key=value framing
    # needs and which the inventory record needed anyway.
    # Default serviceAccountName to "default", matching kubelet at pod
    # admission. Drives the SA-imagePullSecrets walk gated by
    # KEELSON_RESPECT_SA_PULL_SECRETS.
    #
    # to_entries rather than yq's props output, which escapes backslashes in
    # values as well as dots in keys. Only the key side was ever unescaped, so
    # a match-tag of '^1\.' was stored as '^1\\.' and matched no tag at all:
    # the workload silently never updated and nothing said why.
    #
    # The select is what keeps foreign annotations out of the record, and it
    # has to stay. They belong to other people and move constantly: patching a
    # Deployment makes its controller bump deployment.kubernetes.io/revision,
    # and a rollout restart writes kubectl.kubernetes.io/restartedAt. Drop the
    # filter and those reach the fingerprint, where any change reads as "a
    # decision input moved" and forces a resync poll that can only return what
    # the schedule would have.
    #
    # sub("\n"; " ") on the value is what makes one document per kind safe.
    # Per workload, a newline in an annotation could only corrupt that
    # workload's own annotations; in a shared stream it could forge a W|
    # separator and split one record into two. A newline means nothing in any
    # key Keelson reads, so flattening it costs nothing and closes that.
    SCAN_KIND_RECORDS=$(printf '%s' "$list_json" | yq -p=json -o=y -r "
        .items[] as \$w | (
        \"W|\",
        \"ns=\" + \$w.metadata.namespace,
        \"name=\" + \$w.metadata.name,
        \"sa=\" + (\$w${base}.serviceAccountName // \"default\"),
        ${suspend_expr}
        \"mf=\" + (\$w.metadata.managedFields // [] | @json),
        \"ips=\" + (\$w${base}.imagePullSecrets // [] | @json),
        (\$w${base}.containers // [] | .[]
            | \"container=containers \" + .name + \"=\" + .image),
        (\$w${base}.initContainers // [] | .[]
            | \"container=initContainers \" + .name + \"=\" + .image),
        \"annotations=\",
        (\$w.metadata.annotations // {} | to_entries | .[]
            | select(.key | test(\"^(keelson\\.pro|keel\\.sh)/\"))
            | .key + \"=\" + (.value | sub(\"\n\"; \" \")))
        )")
}

# scan_extract_workload <record-block>
# Fills SCAN_WL_* from one workload's block of the kind-wide extraction.
# Pure string work: no yq, no fork, no subshell.
scan_extract_workload() {
    local out=$1
    local rest line in_annotations=0

    SCAN_WL_NS=
    SCAN_WL_NAME=
    SCAN_WL_ANNOTATIONS=
    SCAN_WL_MANAGED_FIELDS=
    SCAN_WL_SUSPEND=
    SCAN_WL_CONTAINER_PAIRS=
    SCAN_WL_IPS_JSON=
    SCAN_WL_SA_NAME=

    # Everything past the annotations= sentinel is annotation text, matched
    # against no key at all. An annotation value holding a newline can then
    # only corrupt the annotations, exactly as it could when they were read
    # by themselves, rather than forging a name or a service account.
    rest=$out
    while [ -n "$rest" ]; do
        line=${rest%%$'\n'*}
        if [ "$line" = "$rest" ]; then
            rest=
        else
            rest=${rest#*$'\n'}
        fi
        if [ "$in_annotations" -eq 1 ]; then
            [ -n "$line" ] || continue
            if [ -n "$SCAN_WL_ANNOTATIONS" ]; then
                SCAN_WL_ANNOTATIONS+=$'\n'$line
            else
                SCAN_WL_ANNOTATIONS=$line
            fi
            continue
        fi
        case "$line" in
            'annotations=')     in_annotations=1 ;;
            'ns='*)             SCAN_WL_NS=${line#ns=} ;;
            'name='*)           SCAN_WL_NAME=${line#name=} ;;
            'sa='*)             SCAN_WL_SA_NAME=${line#sa=} ;;
            'suspend='*)        SCAN_WL_SUSPEND=${line#suspend=} ;;
            'mf='*)             SCAN_WL_MANAGED_FIELDS=${line#mf=} ;;
            'ips='*)            SCAN_WL_IPS_JSON=${line#ips=} ;;
            'container='*)
                if [ -n "$SCAN_WL_CONTAINER_PAIRS" ]; then
                    SCAN_WL_CONTAINER_PAIRS+=$'\n'${line#container=}
                else
                    SCAN_WL_CONTAINER_PAIRS=${line#container=}
                fi
                ;;
        esac
    done
}

scan_workload() {
    local record=$1 kind=$2
    local ns name annotations container_pairs \
          ips_json mf_json suspend sa_name

    scan_extract_workload "$record"
    ns=$SCAN_WL_NS
    name=$SCAN_WL_NAME
    annotations=$SCAN_WL_ANNOTATIONS
    mf_json=$SCAN_WL_MANAGED_FIELDS
    suspend=$SCAN_WL_SUSPEND
    container_pairs=$SCAN_WL_CONTAINER_PAIRS
    ips_json=$SCAN_WL_IPS_JSON
    sa_name=$SCAN_WL_SA_NAME

    local rest line clist cname cimage _workload_updated=0 \
          _workload_last_from="" _workload_last_to="" _workload_last_repo=""

    # Cached before anything is polled, because an update records the image it
    # applied against this record and caching afterwards would write the
    # pre-update one back over it.
    # A workload whose record could not be written is one workload lost until
    # the next pass, not a reason to abandon the other thirty in this one.
    scan_cache_workload "$kind" "$ns" "$name" "$annotations" "$suspend" \
        "$sa_name" "$ips_json" "$container_pairs" || true

    if [ "$_scan_poll_all" -eq 1 ]; then
        rest=$container_pairs
        while [ -n "$rest" ]; do
            line=${rest%%$'\n'*}
            if [ "$line" = "$rest" ]; then
                rest=
            else
                rest=${rest#*$'\n'}
            fi
            clist=${line%% *}
            line=${line#* }
            cname=${line%%=*}
            cimage=${line#*=}
            _scan_total=$((_scan_total + 1))
            scan_container "$kind" "$ns" "$name" "$clist" "$cname" "$cimage" \
                "$annotations" "$ips_json" "$mf_json" "$sa_name"
        done
    fi

    # Only when this pass polled. The trigger's always-once rule fires on
    # "no prior firing recorded", and every cache-refresh path -- the
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

# scan_check_next_due <kind> <ns> <name> <next-due> <interval>
# True if a cached next-due is one a legitimate writer could have produced.
# Returns 1 having warned and left a replacement in INVENTORY_FIRST_DUE.
#
# next-due cannot legitimately be beyond one interval out: inventory_first_due
# is now + (hash % interval), inventory_mark_polled is exactly now + interval,
# a resync is now. Further out than that, or not a number at all, is corrupt,
# and nothing would ever correct it: inventory_due does not select a
# far-future entry, so inventory_mark_polled never runs on it and the workload
# is simply never polled again, silently, across restarts.
#
# Asked of the value read from disk, before anything downstream decides to
# replace it. A workload whose fingerprint moved has its next-due overwritten
# with "now", which is a correct schedule but a silent one: the corrupt value
# it replaced would never be reported, and reporting it is the whole point.
# The values computed below are right by construction and never needed asking.
#
# Against a clock read here rather than the one the pass started with. A poll
# child that marked this workload since then wrote its next-due against a
# later clock, so it can sit beyond _scan_now + interval quite legitimately,
# and comparing the two condemned valid schedules, warned about them and reset
# them. Read after the record, so whatever is in hand was written before this
# reading and one interval is a real bound again.
scan_check_next_due() {
    local kind=$1 ns=$2 name=$3 next_due=$4 interval=$5
    clock_read
    local now=$(( CLOCK_NOW_US / 1000000 ))
    local implausible=0
    case "$next_due" in
        ''|*[!0-9]*) implausible=1 ;;
        *)
            # An if, not a && chain: a false test would leave the case
            # returning 1, and set -e kills the pass before it writes back.
            if [ "$next_due" -gt $(( now + interval )) ]; then
                implausible=1
            fi
            ;;
    esac
    [ "$implausible" -eq 1 ] || return 0
    log_warn next-due-implausible kind="$kind" ns="$ns" name="$name" \
        next-due="$next_due" interval="$interval" \
        msg="$kind '$name' in '$ns' had a next-due of '$next_due', which is not within one ${interval}s interval of now; recomputing it."
    inventory_first_due "$kind" "$ns" "$name" "$interval" "$now"
    return 1
}

# scan_cache_workload <kind> <ns> <name> <annotations> <suspend> <sa> <ips>
#                     <container-pairs>
#
# Records everything a later poll needs, so a due workload can be handled
# straight from cache with no read of the cluster. Cached whether or not any
# container was eligible: Keelson still needs to know the workload exists, so
# an annotation added later is noticed.
scan_cache_workload() {
    local kind=$1 ns=$2 name=$3 annotations=$4 suspend=$5 sa=$6 ips=$7 \
          containers=$8
    inventory_enabled || return 0

    SCAN_SEEN["$kind $ns $name"]=1
    local managed=false
    if scan_is_keelson_managed "$annotations"; then
        managed=true
        _scan_managed=$(( _scan_managed + 1 ))
    fi
    # Every pass, not just the first sighting: annotations are edited on
    # workloads that are already cached, and that is the flip worth recording.
    # Both fields are compared before writing, so an unchanged workload costs
    # nothing.
    state_record_workload "$kind" "$ns" "$name" "$managed"

    local interval=$_scan_interval sched
    annotation_get "$annotations" pollSchedule
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
    local next_due cached=0
    if inventory_get "$kind" "$ns" "$name"; then
        cached=1
        next_due=$INVENTORY_NEXT_DUE
        scan_check_next_due "$kind" "$ns" "$name" "$next_due" "$interval" \
            || next_due=$INVENTORY_FIRST_DUE
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
        # Derived, never persisted. The offset is hashed off the identity, so
        # it is the same on every cold start and spreads the estate across the
        # window without a ledger to write, read or corrupt. All persisting it
        # ever bought was resuming the exact phase of a cycle, at the price of
        # a ConfigMap write per poll.
        inventory_first_due "$kind" "$ns" "$name" "$interval" "$_scan_now"
        next_due=$INVENTORY_FIRST_DUE
    fi

    # Nothing to write if the record already says exactly this. A reconcile
    # scan otherwise rewrites every workload it lists, every pass, to produce
    # the bytes already on disk: a temp file, a rename, and a process for the
    # rename, per workload per pass. On a steady estate that is the whole cost
    # of a scan, and none of it changes anything.
    #
    # The three compared are everything inventory_put is given that is not
    # already inside the fingerprint. Only valid against a record that was
    # actually read: inventory_get leaves the globals untouched when it finds
    # nothing, so a new workload would otherwise be compared against whatever
    # the previous one left behind.
    if [ "$cached" -eq 1 ] \
            && [ "$computed_fingerprint" = "$INVENTORY_FINGERPRINT" ] \
            && [ "$next_due" = "$INVENTORY_NEXT_DUE" ] \
            && [ "$managed" = "$INVENTORY_MANAGED" ]; then
        return 0
    fi

    inventory_put "$kind" "$ns" "$name" "$next_due" "$interval" "$suspend" \
        "$sa" "$ips" "$annotations" "$containers" "$managed"
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

# scan_container_monitored <annotations> <list> <container>
# True when this container is in scope for updates.
#
# initContainers gates the whole list; monitorContainers is a regex over the
# name, empty meaning all, which is keel's shape and default. An unusable
# regex is not a reason to fall back to monitoring everything: that would turn
# a typo into an estate-wide update, so nothing is monitored and it says why.
scan_container_monitored() {
    local ann=$1 clist=$2 cname=$3 want re rc=0

    # Init containers are out of scope unless a workload opts in, matching
    # keel's default in every mode. Anything but a literal true is out, so a
    # rejected value fails closed rather than quietly enabling them.
    if [ "$clist" = "initContainers" ]; then
        annotation_get "$ann" initContainers
        want=$ANNOTATION_VALUE
        [ "$want" = "true" ] || return 1
    fi

    annotation_get "$ann" monitorContainers
    re=$ANNOTATION_VALUE
    [ -n "$re" ] || return 0
    case "$re" in REJECT:*) return 1 ;; esac

    if [[ "$cname" =~ $re ]]; then
        return 0
    else
        rc=$?
    fi
    if [ "$rc" -gt 1 ]; then
        log_error annotation-monitor-containers-invalid pattern="$re" \
            container="$cname" \
            msg="monitorContainers pattern '$re' is not a usable regular expression; no container is monitored until it is fixed."
    fi
    return 1
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

# scan_container <kind> <ns> <name> <list> <container> <image> <annotations>
#                <ips-json> [managed-fields-json] [service-account]
#
# <list> is "containers" or "initContainers": which array the container lives
# in, carried through to the write so the patch lands in the right place.
scan_container() {
    local kind=$1 ns=$2 name=$3 clist=$4 cname=$5 cimage=$6 ann=$7 ips_json=$8 \
          mf_json=${9:-} sa_name=${10:-}

    if ! scan_container_monitored "$ann" "$clist" "$cname"; then
        log_debug skip-not-monitored \
            kind="$kind" ns="$ns" name="$name" container="$cname" list="$clist" \
            msg="Skipped $kind '$name'/$cname in '$ns': not selected for monitoring."
        _scan_skip=$((_scan_skip + 1))
        return 0
    fi

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

    # "OK <policy> <position>": policy is one of major/all/minor/patch and
    # position is an integer, so neither holds a space and splitting it here
    # costs nothing. Two awk forks per eligible container did.
    local policy position fields
    fields=${result#OK }
    policy=${fields%% *}
    position=${fields##* }

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
    annotation_get "$ann" matchTag "$cname"
    match_tag=$ANNOTATION_VALUE
    annotation_get "$ann" matchMode "$cname"
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
#   - nothing has ever been recorded for it (first-observation always-once).
scan_check_cronjob_trigger() {
    local ns=$1 name=$2 ann=$3 suspend=$4 updated=$5
    local from_tag=${6:-} to_tag=${7:-} repo=${8:-}
    local trigger
    annotation_get "$ann" triggerJobOnUpdate
    trigger=$ANNOTATION_VALUE
    [ "$trigger" = "true" ] || return 0

    if [ "$suspend" != "true" ]; then
        log_error cronjob-trigger-requires-suspend \
            kind=CronJob ns="$ns" name="$name" detail="$name" \
            msg="CronJob '$name' in '$ns' has trigger-job-on-update=true but spec.suspend is not true; refusing to trigger to avoid racing the scheduler."
        return 0
    fi

    # The image set as it stands after this pass: update_apply records what it
    # applied against the cache record, so reading it back is the one place
    # that sees the post-update truth for every container at once.
    scan_trigger_image_set "$ns" "$name"

    # Never fired: the bootstrap run, so a suspended CronJob adopted on its
    # newest tag still proves it runs rather than waiting for a future release.
    # Otherwise only our own update fires it, and only when it actually moved
    # an image: someone else's change is a new baseline, not an event.
    local prior
    prior=$(state_get_trigger_field CronJob "$ns" "$name" triggered-at)
    if [ -n "$prior" ]; then
        [ "$updated" -eq 1 ] || return 0
        scan_trigger_set_changed "$ns" "$name" || return 0
    fi

    if update_trigger_cronjob "$ns" "$name" "$from_tag" "$to_tag" "$repo"; then
        scan_record_trigger_success CronJob "$ns" "$name"
    else
        log_error cronjob-job-trigger-failed \
            kind=CronJob ns="$ns" name="$name" detail="$name" \
            msg="Could not trigger Job from CronJob '$name' in '$ns'."
    fi
}

# scan_trigger_image_set <ns> <name>  -> SCAN_TRIGGER_IMAGE_SET
# Every container's image, one "<list>/<name>=<image>" per line, from the cache
# record. Init containers included: Keelson updates them like any other, and an
# init container left a release behind is the skew this exists to prevent.
SCAN_TRIGGER_IMAGE_SET=
scan_trigger_image_set() {
    local i
    SCAN_TRIGGER_IMAGE_SET=
    inventory_get CronJob "$1" "$2" || return 0
    for (( i = 0; i < ${#INVENTORY_CONTAINER_NAMES[@]}; i++ )); do
        SCAN_TRIGGER_IMAGE_SET+="${INVENTORY_CONTAINER_LISTS[$i]}/${INVENTORY_CONTAINER_NAMES[$i]}=${INVENTORY_CONTAINER_IMAGES[$i]}"$'\n'
    done
}

# scan_trigger_set_changed <ns> <name>
# True when SCAN_TRIGGER_IMAGE_SET differs from what was recorded at the last
# firing. Compared container by container rather than as one string: the cache
# yields inventory order and STATE_FIELDS is an unordered associative array, so
# a string comparison would need a sort, and a sort is a fork on a path that
# now has none.
scan_trigger_set_changed() {
    local key line rest slot recorded n=0
    key=$(state_trigger_key CronJob "$1" "$2")
    rest=$SCAN_TRIGGER_IMAGE_SET
    while [ -n "$rest" ]; do
        line=${rest%%$'\n'*}
        if [ "$line" = "$rest" ]; then rest=; else rest=${rest#*$'\n'}; fi
        [ -n "$line" ] || continue
        n=$(( n + 1 ))
        slot="$key:${line%%=*}"
        recorded=${STATE_FIELDS[$slot]-}
        [ "$recorded" = "${line#*=}" ] || return 0
    done
    # A container dropped since the last firing is a change too, and matching
    # every current one would otherwise miss it.
    local field c=0
    for field in ${STATE_FIELDS[@]+"${!STATE_FIELDS[@]}"}; do
        case "$field" in
            "$key:containers/"*|"$key:initContainers/"*) c=$(( c + 1 )) ;;
        esac
    done
    [ "$c" -ne "$n" ]
}

scan_record_trigger_success() {
    local kind=$1 ns=$2 name=$3
    state_set_trigger_field "$kind" "$ns" "$name" triggered-at "$(state_now)"
    # Every container's image, not a timestamp in a field named triggered-job.
    # A CronJob can have several, and recording one of them left the others
    # undefined: updating container A then container B would compare against
    # whichever happened to be written.
    local line rest
    rest=$SCAN_TRIGGER_IMAGE_SET
    while [ -n "$rest" ]; do
        line=${rest%%$'\n'*}
        if [ "$line" = "$rest" ]; then rest=; else rest=${rest#*$'\n'}; fi
        [ -n "$line" ] || continue
        state_set_trigger_field "$kind" "$ns" "$name" "${line%%=*}" "${line#*=}"
    done
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
# scan_sum_tally <file>
# Adds up what the poll's children reported and leaves it in the _scan_*
# counters the summary reads. Each child is a subshell, so its counts die with
# it; without this the summary reports zero however much work was done.
scan_sum_tally() {
    local f=$1 t w u nc s e interval
    [ -r "$f" ] || return 0
    while read -r t w u nc s e interval; do
        [ -n "$interval" ] || continue
        _scan_total=$(( _scan_total + t ))
        _scan_would_update=$(( _scan_would_update + w ))
        _scan_updated=$(( _scan_updated + u ))
        _scan_no_change=$(( _scan_no_change + nc ))
        _scan_skip=$(( _scan_skip + s ))
        _scan_error=$(( _scan_error + e ))
        # The shortest cadence in the pass is the one the pass has to fit
        # inside; a workload on a daily schedule is not evidence of anything.
        if [ "$interval" -gt 0 ] 2>/dev/null && { [ "$_scan_min_interval" -eq 0 ] \
                || [ "$interval" -lt "$_scan_min_interval" ]; }; then
            _scan_min_interval=$interval
        fi
    done < "$f"
    rm -f "$f" 2>/dev/null || true
    return 0
}

# scan_poll_overrun_count <path> <overran>
# Sets SCAN_POLL_OVERRUNS to the number of consecutive passes that have
# overrun, this one included; a pass that fitted resets it to zero.
#
# On disk because each pass is its own subshell: a counter in memory dies
# with the child that incremented it, which is also why log.bash's rate
# limiter cannot throttle anything a poll child says. Only one poll runs at a
# time, gated on LOOP_POLL_PID, so there is no writer to race with.
scan_poll_overrun_count() {
    local path=$1 overran=$2 n=0
    if [ "$overran" -eq 1 ]; then
        [ -r "$path" ] && read -r n < "$path" 2>/dev/null
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        n=$(( n + 1 ))
    fi
    SCAN_POLL_OVERRUNS=$n
    printf '%s\n' "$n" > "$path" 2>/dev/null || true
    return 0
}

scan_poll_due() {
    local _scan_apply=${1:-0} now=$2
    inventory_enabled || return 0

    inventory_due "$now"
    [ "${#INVENTORY_DUE[@]}" -eq 0 ] && return 0

    local _scan_total=0 _scan_would_update=0 _scan_updated=0 \
          _scan_no_change=0 _scan_skip=0 _scan_error=0 _scan_managed=0 \
          _scan_min_interval=0
    registry_init

    clock_read
    local start_us=$CLOCK_NOW_US

    # One workload per child, at most KEELSON_REGISTRY_POLL_CONCURRENCY at a
    # time. A registry check is about two seconds of waiting for roughly sixty
    # milliseconds of work, so the serial loop spent almost all of its time
    # doing nothing while an estate waited behind it.
    #
    # Safe to run concurrently because the write paths were already made so:
    # inventory_put renames a BASHPID-named temp, and state mutations go to a
    # BASHPID-named spool the tick loop drains. Nothing here writes the
    # ConfigMap, and no two children touch the same workload.
    local conc=${KEELSON_REGISTRY_POLL_CONCURRENCY:?KEELSON_REGISTRY_POLL_CONCURRENCY required}
    local tally=${KEELSON_POLL_TALLY_FILE:-/keelson/work/poll-tally}
    : > "$tally" 2>/dev/null || true

    local entry kind ns name i inflight=0
    for entry in "${INVENTORY_DUE[@]}"; do
        (
            read -r kind ns name <<<"$entry"
            inventory_get "$kind" "$ns" "$name" || exit 0

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

            state_spool_commit || true
            # Counters are locals, so they die with this child. Appended for
            # the parent to add up, or the summary would report zero however
            # much work was done. One short line, so the append is atomic.
            printf '%d %d %d %d %d %d %d\n' "$_scan_total" "$_scan_would_update" \
                "$_scan_updated" "$_scan_no_change" "$_scan_skip" "$_scan_error" \
                "$INVENTORY_INTERVAL" \
                >>"$tally" 2>/dev/null || true
        ) &
        inflight=$(( inflight + 1 ))
        if [ "$inflight" -ge "$conc" ]; then
            # A child exiting non-zero must not take the poll down with it.
            wait -n 2>/dev/null || true
            inflight=$(( inflight - 1 ))
        fi
    done
    wait

    scan_sum_tally "$tally"

    clock_read
    local elapsed=$(( (CLOCK_NOW_US - start_us) / 1000000 ))

    log_debug poll-summary \
        workloads="${#INVENTORY_DUE[@]}" \
        resources="$_scan_total" \
        updated="$_scan_updated" \
        no-change="$_scan_no_change" \
        skip="$_scan_skip" \
        error="$_scan_error" \
        elapsed="$elapsed" \
        msg="Polled ${#INVENTORY_DUE[@]} due workloads in ${elapsed}s: $_scan_total containers examined, $_scan_updated updated, $_scan_no_change no-change, $_scan_skip skipped, $_scan_error errored."

    # A pass cannot hold a cadence it takes longer than. Nothing else notices:
    # the next pass simply starts late, every workload in it is polled late,
    # and the controller runs at a fraction of its configured rate saying
    # nothing about it. Reported against the shortest cadence in the pass
    # because that is the one being missed first.
    #
    # An if, not a && chain: a false test would leave this returning 1 and
    # set -e would take the pass down on a pass that merely fitted.
    local overran=0
    if [ "$_scan_min_interval" -gt 0 ] && [ "$elapsed" -gt "$_scan_min_interval" ]; then
        overran=1
    fi
    scan_poll_overrun_count \
        "${KEELSON_POLL_OVERRUN_FILE:-/keelson/work/poll-overrun}" "$overran"
    if log_backoff_should_emit "$SCAN_POLL_OVERRUNS" \
            "${KEELSON_POLL_OVERRUN_WARNING_BACKOFF_LIMIT:?KEELSON_POLL_OVERRUN_WARNING_BACKOFF_LIMIT required}"; then
        log_warn poll-pass-overrun elapsed="$elapsed" interval="$_scan_min_interval" \
            workloads="${#INVENTORY_DUE[@]}" consecutive="$SCAN_POLL_OVERRUNS" \
            msg="Polling ${#INVENTORY_DUE[@]} due workloads took ${elapsed}s, longer than the ${_scan_min_interval}s cadence of the most frequently polled of them, so the estate is being refreshed slower than it is configured to be. That is $SCAN_POLL_OVERRUNS passes in a row; this is reported with a widening gap between reports, not once per pass. Raise KEELSON_REGISTRY_POLL_CONCURRENCY, which needs memory raised with it, or lengthen the poll schedule."
    fi
    return 0
}
