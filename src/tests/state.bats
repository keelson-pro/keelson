#!/usr/bin/env bats

# Tests for lib/state.bash. kubectl is shimmed via $TMP_BIN on PATH.
# The state ConfigMap carries the CronJob always-once trigger ledger and
# each workload's next-due, the one part of the cache worth surviving a restart.

setup() {
    TMP_DIR=$(mktemp -d)
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    export PATH TMP_DIR

    KEELSON_SA_NAMESPACE_FILE="$TMP_DIR/ns"
    printf 'keelson-system' > "$KEELSON_SA_NAMESPACE_FILE"
    KEELSON_STATE_CONFIGMAP=keelson-state
    export KEELSON_SA_NAMESPACE_FILE KEELSON_STATE_CONFIGMAP
    unset KEELSON_STATE_NAMESPACE

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/state.bash
    source "$SCRIPT_DIR/lib/state.bash"
}

teardown() {
    rm -rf "$TMP_DIR"
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
# schedule is not derivable. Without persisting it, a restart makes every
# workload due at once and every repository gets polled the moment the pod
# comes back.

@test "next-due: round-trips through the ledger" {
    state_set_next_due Deployment default web 1786868000
    [ "$(state_get_next_due Deployment default web)" = "1786868000" ]
}

@test "next-due: unknown workload reads empty" {
    [ -z "$(state_get_next_due Deployment default nope)" ]
}

@test "next-due: uses its own key, leaving the trigger ledger alone" {
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_set_next_due CronJob ops backup 222
    [ "$(state_get_trigger_field CronJob ops backup triggered-job)" = "111" ]
    [ "$(state_get_next_due CronJob ops backup)" = "222" ]
    [ -n "${STATE_KEYS[s--CronJob--ops--backup]:-}" ]
    [ -n "${STATE_KEYS[j--CronJob--ops--backup]:-}" ]
}

@test "next-due: marks the key dirty for the next flush" {
    STATE_DIRTY=()
    state_set_next_due Deployment default web 500
    [ -n "${STATE_DIRTY[s--Deployment--default--web]:-}" ]
}

@test "forget_workload: drops both of a workload's keys" {
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_set_next_due CronJob ops backup 222
    state_forget_workload CronJob ops backup
    [ -z "$(state_get_next_due CronJob ops backup)" ]
    [ -z "$(state_get_trigger_field CronJob ops backup triggered-job)" ]
}

@test "forget_workload: both keys go null in the same patch" {
    STATE_DIRTY=(); STATE_DELETED=()
    state_set_trigger_field CronJob ops backup triggered-job 111
    state_set_next_due CronJob ops backup 222
    state_forget_workload CronJob ops backup
    local patch
    patch=$(state_build_patch)
    [[ "$patch" == *'"s--CronJob--ops--backup":null'* ]]
    [[ "$patch" == *'"j--CronJob--ops--backup":null'* ]]
}

# --- ledger reconciliation, after a full refresh ---

@test "reconcile_ledger: forgets keys with no cached workload" {
    # shellcheck source=../scripts/lib/inventory.bash
    source "$SCRIPT_DIR/lib/inventory.bash"
    KEELSON_INVENTORY_DIR="$TMP_DIR/inventory"
    inventory_init
    inventory_put Deployment default web 1000 60 "" default '[]' '' 'containers main=a:1'

    state_set_next_due Deployment default web 111
    state_set_next_due Deployment default ghost 222
    state_set_trigger_field CronJob ops gone triggered-job 333

    state_reconcile_ledger
    [ "$(state_get_next_due Deployment default web)" = "111" ]
    [ -z "$(state_get_next_due Deployment default ghost)" ]
    [ -z "$(state_get_trigger_field CronJob ops gone triggered-job)" ]
}

@test "reconcile_ledger: does nothing without a cache to compare against" {
    # shellcheck source=../scripts/lib/inventory.bash
    source "$SCRIPT_DIR/lib/inventory.bash"
    KEELSON_INVENTORY_DIR="$TMP_DIR/absent"
    state_set_next_due Deployment default web 111
    state_reconcile_ledger
    [ "$(state_get_next_due Deployment default web)" = "111" ]
}
