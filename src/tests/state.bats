#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# Tests for lib/state.bash. kubectl is shimmed via $TMP_BIN on PATH.
# The state ConfigMap carries the CronJob always-once trigger ledger and
# each workload's next-due, the one part of the cache worth surviving a restart.

load helper

setup() {
    tmp_dir_init
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    export PATH TMP_DIR

    KEELSON_SA_NAMESPACE_FILE="$TMP_DIR/ns"
    printf 'keelson-system' > "$KEELSON_SA_NAMESPACE_FILE"
    KEELSON_STATE_CONFIGMAP=keelson-state
    export KEELSON_SA_NAMESPACE_FILE KEELSON_STATE_CONFIGMAP
    KEELSON_FIRST_POLL_DELAY_MAX=300
    export KEELSON_FIRST_POLL_DELAY_MAX
    unset KEELSON_STATE_NAMESPACE

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/state.bash
    source "$SCRIPT_DIR/lib/state.bash"
}

emit() { "$@" 2>&1; }

install_shim() {
    local name=$1
    cat > "$TMP_BIN/$name"
    chmod +x "$TMP_BIN/$name"
}

# Default kubectl shim: ConfigMap absent, create succeeds, patch logs and succeeds.
install_default_kubectl() {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
    "get configmap")
        if [ -f "$TMP_DIR/cm.json" ]; then
            cat "$TMP_DIR/cm.json"
            exit 0
        fi
        exit 1
        ;;
    "create configmap")
        printf '{"data":{}}' > "$TMP_DIR/cm.json"
        exit 0
        ;;
    "patch configmap")
        echo "$@" >>"$TMP_DIR/kubectl.log"
        while [ $# -gt 0 ]; do
            if [ "$1" = "--patch" ]; then
                printf '%s' "$2" >"$TMP_DIR/patch.json"
                break
            fi
            shift
        done
        exit 0
        ;;
esac
exit 0
SH
}

# --- keys ---

@test "state_trigger_key" {
    run state_trigger_key CronJob default cron
    [ "$output" = "j--CronJob--default--cron" ]
}

# --- state_init ---

@test "state_init: reads namespace from SA mount file" {
    install_default_kubectl
    state_init
    [ "$STATE_NAMESPACE" = "keelson-system" ]
    [ "$STATE_CONFIGMAP_NAME" = "keelson-state" ]
}

@test "state_init: KEELSON_STATE_NAMESPACE overrides SA mount" {
    install_default_kubectl
    KEELSON_STATE_NAMESPACE=other-ns state_init
    [ "$STATE_NAMESPACE" = "other-ns" ]
}

@test "state_init: KEELSON_STATE_CONFIGMAP overrides default name" {
    install_default_kubectl
    KEELSON_STATE_CONFIGMAP=custom state_init
    [ "$STATE_CONFIGMAP_NAME" = "custom" ]
}

@test "state_init: missing SA mount file -> error and non-zero" {
    install_default_kubectl
    rm -f "$KEELSON_SA_NAMESPACE_FILE"
    run emit state_init
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not read Keelson's own namespace"* ]]
}

@test "state_init: creates ConfigMap when absent" {
    install_default_kubectl
    run emit state_init
    [ "$status" -eq 0 ]
    [[ "$output" == *"State ConfigMap 'keelson-state' created in 'keelson-system'."* ]]
    [ -f "$TMP_DIR/cm.json" ]
}

@test "state_init: loads existing ConfigMap trigger data into cache" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
    "get configmap")
        cat <<'JSON'
{"metadata":{"resourceVersion":"42"},"data":{"j--CronJob--default--cron":"{\"triggered-job\":\"2026-05-19T10:00:00Z\",\"triggered-at\":\"2026-05-19T10:00:00Z\"}"}}
JSON
        exit 0
        ;;
esac
exit 0
SH
    state_init
    run state_get_trigger_field CronJob default cron triggered-job
    [ "$output" = "2026-05-19T10:00:00Z" ]
    run state_get_trigger_field CronJob default cron triggered-at
    [ "$output" = "2026-05-19T10:00:00Z" ]
}

# --- get/set ---

@test "state_set/get_trigger_field round-trips" {
    install_default_kubectl
    state_init
    state_set_trigger_field CronJob default cron triggered-job cron-keelson-20260519
    run state_get_trigger_field CronJob default cron triggered-job
    [ "$output" = "cron-keelson-20260519" ]
}

@test "state_get_trigger_field: missing field returns empty" {
    install_default_kubectl
    state_init
    run state_get_trigger_field CronJob default cron triggered-job
    [ -z "$output" ]
}

@test "state_set marks the data-key dirty" {
    install_default_kubectl
    state_init
    state_set_trigger_field CronJob default cron triggered-job val
    [ "${STATE_DIRTY[j--CronJob--default--cron]}" = "1" ]
}

# --- state_clear_cache ---

@test "state_clear_cache wipes fields, keys, dirty" {
    install_default_kubectl
    state_init
    state_set_trigger_field CronJob default cron triggered-job val
    state_clear_cache
    [ "${#STATE_FIELDS[@]}" -eq 0 ]
    [ "${#STATE_KEYS[@]}" -eq 0 ]
    [ "${#STATE_DIRTY[@]}" -eq 0 ]
}

# --- state_flush ---

@test "state_flush: no dirty keys -> no kubectl call" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
    "get configmap") printf '{"data":{}}'; exit 0 ;;
    "patch configmap") echo "patched" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
exit 0
SH
    state_init
    state_flush
    [ ! -f "$TMP_DIR/kubectl.log" ]
}

@test "state_flush: dirty keys -> kubectl patch with merge patch" {
    install_default_kubectl
    state_init
    state_set_trigger_field CronJob default cron triggered-job cron-keelson-1
    state_set_trigger_field CronJob default cron triggered-at 2026-05-19T10:00:00Z
    run emit state_flush
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"patch configmap keelson-state"* ]]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"--type=merge"* ]]
    grep -q '"j--CronJob--default--cron"' "$TMP_DIR/patch.json"
    grep -q 'triggered-job' "$TMP_DIR/patch.json"
}

@test "state_flush: success clears the dirty set" {
    install_default_kubectl
    state_init
    state_set_trigger_field CronJob default cron triggered-job v
    state_flush
    [ "${#STATE_DIRTY[@]}" -eq 0 ]
}

@test "state_flush: kubectl failure logs state-flush-failed and keeps dirty" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
    "get configmap") printf '{"data":{}}'; exit 0 ;;
    "patch configmap") exit 1 ;;
esac
exit 0
SH
    state_init
    state_set_trigger_field CronJob default cron triggered-job v
    run emit state_flush
    [ "$status" -eq 1 ]
    [[ "$output" == *"State flush failed:"* ]]
    [ "${STATE_DIRTY[j--CronJob--default--cron]}" = "1" ]
}

@test "state_flush: empty value fields are dropped from rendered JSON" {
    install_default_kubectl
    state_init
    state_set_trigger_field CronJob default cron triggered-job v
    state_set_trigger_field CronJob default cron triggered-at ""
    state_flush
    ! grep -q "triggered-at" "$TMP_DIR/patch.json"
    grep -q "triggered-job" "$TMP_DIR/patch.json"
}

@test "state_flush: patch round-trips through yq to original value" {
    install_default_kubectl
    state_init
    state_set_trigger_field CronJob default cron triggered-job 'has "quote" and \slash'
    state_flush
    local inner round_tripped
    inner=$(yq -p=json -r '.data["j--CronJob--default--cron"]' \
        "$TMP_DIR/patch.json")
    round_tripped=$(printf '%s' "$inner" | yq -p=json -r '."triggered-job"')
    [ "$round_tripped" = 'has "quote" and \slash' ]
}

# --- forgetting a key ---
#
# Nothing ever removed a key before, so a workload's entry outlived the
# workload and the ConfigMap only grew. At roughly 1 MiB per object that
# eventually fails as a mystery rather than as a bug.

@test "forget: renders an unquoted null, which is what removes a merge key" {
    state_set_trigger_field CronJob ops backup triggered-job 111
    STATE_DIRTY=(); STATE_DELETED=()
    state_forget "$(state_trigger_key CronJob ops backup)"
    local patch
    patch=$(state_build_patch)
    [[ "$patch" == *'"j--CronJob--ops--backup":null'* ]]
    [[ "$patch" != *'"null"'* ]]
}

@test "forget: the key's fields are gone" {
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_forget "$(state_trigger_key CronJob ops backup)"
    [ -z "$(state_get_trigger_field CronJob ops backup triggered-job)" ]
    [ -z "${STATE_KEYS[j--CronJob--ops--backup]:-}" ]
}

@test "forget: a deleted key does not resurrect from its old fields" {
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_forget "$(state_trigger_key CronJob ops backup)"
    local patch
    patch=$(state_build_patch)
    [[ "$patch" != *"111"* ]]
}

@test "forget: deletions and writes go in the same patch" {
    STATE_DIRTY=(); STATE_DELETED=()
    state_set_trigger_field CronJob ops keep triggered-job 700
    state_set_trigger_field CronJob ops gone triggered-job 800
    state_forget "$(state_trigger_key CronJob ops gone)"
    local patch
    patch=$(state_build_patch)
    [[ "$patch" == *'"j--CronJob--ops--gone":null'* ]]
    [[ "$patch" == *"700"* ]]
}

@test "forget: a successful flush clears the deletion set" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_forget "$(state_trigger_key CronJob ops backup)"
    state_flush
    [ "${#STATE_DELETED[@]}" -eq 0 ]
    [ "${#STATE_DIRTY[@]}" -eq 0 ]
}

@test "clear_cache resets the deletion set too" {
    state_forget "$(state_trigger_key CronJob ops backup)"
    state_clear_cache
    [ "${#STATE_DELETED[@]}" -eq 0 ]
}

@test "forget: a failed flush keeps the deletion for the next attempt" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 1
SH
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_forget "$(state_trigger_key CronJob ops backup)"
    run state_flush
    [ "$status" -eq 1 ]
    [ -n "${STATE_DELETED[j--CronJob--ops--backup]:-}" ]
    [ -n "${STATE_DIRTY[j--CronJob--ops--backup]:-}" ]
}

@test "state_init: starts with an empty deletion set" {
    # A forget left over from a previous cache must not delete a key that
    # the fresh load just brought in.
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) printf '{"data":{}}' ;;
    *) exit 0 ;;
esac
SH
    state_forget "$(state_trigger_key CronJob ops backup)"
    state_init
    [ "${#STATE_DELETED[@]}" -eq 0 ]
}

# --- per-workload schedule ---
#
# The cache is derived and rebuilt from the cluster on any restart, but a
# The schedule itself is derived, not stored: inventory_first_due hashes the
# identity, so a cold start spreads the estate without a ledger. What the
# ledger records is that Keelson has seen the workload at all, written once.

@test "record: a workload gets a first-seen stamp" {
    state_record_workload Deployment default web
    [ -n "$(state_get w--Deployment--default--web first-seen)" ]
}

@test "record: an unrecorded workload reads empty" {
    [ -z "$(state_get w--Deployment--default--nope first-seen)" ]
}

@test "record: written once, never rewritten" {
    # A restart must not churn the ConfigMap re-stamping what it already knows.
    state_record_workload Deployment default web
    local first
    first=$(state_get w--Deployment--default--web first-seen)
    STATE_DIRTY=()
    state_record_workload Deployment default web
    [ "$(state_get w--Deployment--default--web first-seen)" = "$first" ]
    [ -z "${STATE_DIRTY[w--Deployment--default--web]:-}" ]
}

@test "record: carries no next-due, the schedule is derived" {
    state_record_workload Deployment default web
    [ -z "$(state_get w--Deployment--default--web next-due)" ]
}

@test "record: uses its own key, leaving the trigger ledger alone" {
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_record_workload CronJob ops backup
    [ "$(state_get_trigger_field CronJob ops backup triggered-job)" = "111" ]
    [ -n "${STATE_KEYS[w--CronJob--ops--backup]:-}" ]
    [ -n "${STATE_KEYS[j--CronJob--ops--backup]:-}" ]
}

@test "record: marks the key dirty for the next flush" {
    STATE_DIRTY=()
    state_record_workload Deployment default web
    [ -n "${STATE_DIRTY[w--Deployment--default--web]:-}" ]
}

@test "forget_workload: drops both of a workload's keys" {
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_record_workload CronJob ops backup
    state_forget_workload CronJob ops backup
    [ -z "$(state_get w--CronJob--ops--backup first-seen)" ]
    [ -z "$(state_get_trigger_field CronJob ops backup triggered-job)" ]
}

@test "forget_workload: both keys go null in the same patch" {
    STATE_DIRTY=(); STATE_DELETED=()
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_record_workload CronJob ops backup
    state_forget_workload CronJob ops backup
    local patch
    patch=$(state_build_patch)
    [[ "$patch" == *'"w--CronJob--ops--backup":null'* ]]
    [[ "$patch" == *'"j--CronJob--ops--backup":null'* ]]
}

# --- ledger reconciliation, after a full refresh ---

@test "reconcile_ledger: forgets keys with no cached workload" {
    # shellcheck source=../scripts/lib/inventory.bash
    source "$SCRIPT_DIR/lib/inventory.bash"
    KEELSON_INVENTORY_DIR="$TMP_DIR/inventory"
    inventory_init
    inventory_put Deployment default web 1000 60 "" default '[]' '' 'containers main=a:1'

    state_record_workload Deployment default web
    state_record_workload Deployment default ghost
    state_set_trigger_field CronJob ops gone triggered-job 333

    state_reconcile_ledger
    [ -n "$(state_get w--Deployment--default--web first-seen)" ]
    [ -z "$(state_get w--Deployment--default--ghost first-seen)" ]
    [ -z "$(state_get_trigger_field CronJob ops gone triggered-job)" ]
}

@test "reconcile_ledger: does nothing without a cache to compare against" {
    # shellcheck source=../scripts/lib/inventory.bash
    source "$SCRIPT_DIR/lib/inventory.bash"
    KEELSON_INVENTORY_DIR="$TMP_DIR/absent"
    state_record_workload Deployment default web
    state_reconcile_ledger
    [ -n "$(state_get w--Deployment--default--web first-seen)" ]
}

# --- own namespace ---

@test "own_namespace: reads a SA file written without a trailing newline" {
    # The kubelet writes it that way, so read returns 1 at EOF having set the
    # variable anyway; treating that as a failure breaks boot in a real pod.
    printf '%s' 'team-a' > "$TMP_DIR/ns"
    unset KEELSON_STATE_NAMESPACE
    KEELSON_SA_NAMESPACE_FILE="$TMP_DIR/ns"
    state_own_namespace
    [ "$STATE_NAMESPACE" = "team-a" ]
}

@test "own_namespace: KEELSON_STATE_NAMESPACE wins over the file" {
    printf '%s' 'from-file' > "$TMP_DIR/ns"
    KEELSON_SA_NAMESPACE_FILE="$TMP_DIR/ns" KEELSON_STATE_NAMESPACE=explicit \
        state_own_namespace
    [ "$STATE_NAMESPACE" = "explicit" ]
}

@test "own_namespace: an unreadable file returns 1 and reports where it looked" {
    unset KEELSON_STATE_NAMESPACE
    KEELSON_SA_NAMESPACE_FILE="$TMP_DIR/absent"
    local rc=0
    state_own_namespace || rc=$?
    [ "$rc" -eq 1 ]
    [ "$STATE_NAMESPACE_FILE" = "$TMP_DIR/absent" ]
}

# --- state_load parsing ---
#
# The ledger is re-read by every scan, poll, queue-refresh and full-refresh
# child, so how it parses is worth pinning independently of how it is stored.

load_cm() {
    install_shim kubectl <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
    "get configmap") cat <<'JSON'
$1
JSON
        exit 0 ;;
esac
exit 0
SH
    STATE_CONFIGMAP_NAME=keelson-state
    STATE_NAMESPACE=keelson-system
    state_clear_cache
    state_load
}

@test "state_load: a single key with a single field" {
    load_cm '{"data":{"k1":"{\"next-due\":\"1787000060\"}"}}'
    [ "$(state_get k1 next-due)" = "1787000060" ]
    [ -n "${STATE_KEYS[k1]:-}" ]
}

@test "state_load: several keys each land separately" {
    load_cm '{"data":{"k1":"{\"next-due\":\"111\"}","k2":"{\"next-due\":\"222\"}","k3":"{\"next-due\":\"333\"}"}}'
    [ "$(state_get k1 next-due)" = "111" ]
    [ "$(state_get k2 next-due)" = "222" ]
    [ "$(state_get k3 next-due)" = "333" ]
}

@test "state_load: several fields under one key" {
    load_cm '{"data":{"k1":"{\"triggered-job\":\"job-a\",\"triggered-at\":\"2026-05-19T10:00:00Z\"}"}}'
    [ "$(state_get k1 triggered-job)" = "job-a" ]
    [ "$(state_get k1 triggered-at)" = "2026-05-19T10:00:00Z" ]
}

@test "state_load: an empty object registers the key with no fields" {
    load_cm '{"data":{"k1":"{}"}}'
    [ -n "${STATE_KEYS[k1]:-}" ]
    [ -z "$(state_get k1 next-due)" ]
}

@test "state_load: a null value registers the key with no fields" {
    load_cm '{"data":{"k1":"null"}}'
    [ -n "${STATE_KEYS[k1]:-}" ]
    [ -z "$(state_get k1 next-due)" ]
}

@test "state_load: absent data section loads nothing and does not fail" {
    load_cm '{"metadata":{"resourceVersion":"42"}}'
    [ "${#STATE_KEYS[@]}" -eq 0 ]
}

@test "state_load: an empty data section loads nothing" {
    load_cm '{"data":{}}'
    [ "${#STATE_KEYS[@]}" -eq 0 ]
}

@test "state_load: a key containing dots survives intact" {
    load_cm '{"data":{"j--CronJob--ns--my.app":"{\"next-due\":\"999\"}"}}'
    [ "$(state_get 'j--CronJob--ns--my.app' next-due)" = "999" ]
}

@test "state_load: a backslash in a value is not doubled" {
    load_cm '{"data":{"k1":"{\"note\":\"a\\\\b\"}"}}'
    [ "$(state_get k1 note)" = 'a\b' ]
}

@test "state_load: an empty field value reads back empty" {
    load_cm '{"data":{"k1":"{\"next-due\":\"\"}"}}'
    [ -n "${STATE_KEYS[k1]:-}" ]
    [ -z "$(state_get k1 next-due)" ]
}

@test "state_load: a value with a space survives" {
    load_cm '{"data":{"k1":"{\"note\":\"two words\"}"}}'
    [ "$(state_get k1 note)" = "two words" ]
}

@test "state_load: many keys all load" {
    local d='' i
    for i in $(seq 1 30); do
        [ -n "$d" ] && d="$d,"
        d="$d\"k$i\":\"{\\\"next-due\\\":\\\"$i\\\"}\""
    done
    load_cm "{\"data\":{$d}}"
    [ "${#STATE_KEYS[@]}" -eq 30 ]
    [ "$(state_get k1 next-due)" = "1" ]
    [ "$(state_get k30 next-due)" = "30" ]
}
