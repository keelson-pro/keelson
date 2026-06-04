#!/usr/bin/env bats

# Tests for lib/state.bash. kubectl is shimmed via $TMP_BIN on PATH.

setup() {
    TMP_DIR=$(mktemp -d)
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    export PATH TMP_DIR

    KEELSON_SA_NAMESPACE_FILE="$TMP_DIR/ns"
    printf 'keelson-system' > "$KEELSON_SA_NAMESPACE_FILE"
    export KEELSON_SA_NAMESPACE_FILE
    unset KEELSON_STATE_NAMESPACE KEELSON_STATE_CONFIGMAP

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
        # Capture the --patch payload (positional, after --patch flag)
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

@test "state_container_key" {
    run state_container_key Deployment default app main
    [ "$output" = "c--Deployment--default--app--main" ]
}

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
    [[ "$output" == *"state-namespace-unknown"* ]]
}

@test "state_init: creates ConfigMap when absent" {
    install_default_kubectl
    run emit state_init
    [ "$status" -eq 0 ]
    [[ "$output" == *"state-configmap-created"* ]]
    [ -f "$TMP_DIR/cm.json" ]
}

@test "state_init: loads existing ConfigMap data into cache" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
    "get configmap")
        cat <<'JSON'
{"metadata":{"resourceVersion":"42"},"data":{"c--Deployment--default--app--main":"{\"checked-tag\":\"1.2.3\",\"checked-at\":\"2026-05-19T10:00:00Z\"}"}}
JSON
        exit 0
        ;;
esac
exit 0
SH
    state_init
    run state_get_container_field Deployment default app main checked-tag
    [ "$output" = "1.2.3" ]
    run state_get_container_field Deployment default app main checked-at
    [ "$output" = "2026-05-19T10:00:00Z" ]
}

# --- get/set ---

@test "state_set/get_container_field round-trips" {
    install_default_kubectl
    state_init
    state_set_container_field Deployment default app main checked-tag 1.0.0
    run state_get_container_field Deployment default app main checked-tag
    [ "$output" = "1.0.0" ]
}

@test "state_set/get_trigger_field round-trips" {
    install_default_kubectl
    state_init
    state_set_trigger_field CronJob default cron triggered-job cron-keelson-20260519
    run state_get_trigger_field CronJob default cron triggered-job
    [ "$output" = "cron-keelson-20260519" ]
}

@test "state_get_container_field: missing field returns empty" {
    install_default_kubectl
    state_init
    run state_get_container_field Deployment default app main checked-tag
    [ -z "$output" ]
}

@test "state_set marks the data-key dirty" {
    install_default_kubectl
    state_init
    state_set_container_field Deployment default app main checked-tag 1.0.0
    [ "${STATE_DIRTY[c--Deployment--default--app--main]}" = "1" ]
}

# --- state_clear_cache ---

@test "state_clear_cache wipes fields, keys, dirty" {
    install_default_kubectl
    state_init
    state_set_container_field Deployment default app main checked-tag 1.0.0
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
    state_set_container_field Deployment default app main checked-tag 1.0.0
    state_set_container_field Deployment default app main checked-at 2026-05-19T10:00:00Z
    run emit state_flush
    [ "$status" -eq 0 ]
    [[ "$output" == *"state-flushed"* ]]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"patch configmap keelson-state"* ]]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"--type=merge"* ]]
    grep -q '"c--Deployment--default--app--main"' "$TMP_DIR/patch.json"
    grep -q 'checked-tag' "$TMP_DIR/patch.json"
}

@test "state_flush: success clears the dirty set" {
    install_default_kubectl
    state_init
    state_set_container_field Deployment default app main checked-tag 1.0.0
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
    state_set_container_field Deployment default app main checked-tag 1.0.0
    run emit state_flush
    [ "$status" -eq 1 ]
    [[ "$output" == *"state-flush-failed"* ]]
    [ "${STATE_DIRTY[c--Deployment--default--app--main]}" = "1" ]
}

@test "state_flush: empty value fields are dropped from rendered JSON" {
    install_default_kubectl
    state_init
    state_set_container_field Deployment default app main checked-tag 1.0.0
    state_set_container_field Deployment default app main skip-reason ""
    state_flush
    ! grep -q "skip-reason" "$TMP_DIR/patch.json"
    grep -q "checked-tag" "$TMP_DIR/patch.json"
}

@test "state_flush: patch round-trips through yq to original value" {
    install_default_kubectl
    state_init
    state_set_container_field Deployment default app main error-detail 'has "quote" and \slash'
    state_flush
    # Outer patch is JSON; data value is itself a JSON string. yq -r once
    # gives us the inner JSON object, then again gives us the field value.
    local inner round_tripped
    inner=$(yq -p=json -r '.data["c--Deployment--default--app--main"]' \
        "$TMP_DIR/patch.json")
    round_tripped=$(printf '%s' "$inner" | yq -p=json -r '."error-detail"')
    [ "$round_tripped" = 'has "quote" and \slash' ]
}
