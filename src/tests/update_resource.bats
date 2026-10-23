#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# Tests for src/scripts/keelson-update-resource, the one-workload CLI. The
# script is sourced (its main is guarded) with validate_config stubbed, since
# validation has its own tests, and kubectl shimmed.

load helper

setup() {
    tmp_dir_init
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    KEELSON_CONFIG_MODE=keelson
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=mimic
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=mimic
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-patch
    KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED=true
    export PATH TMP_DIR KEELSON_CONFIG_MODE \
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED \
        KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED \
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED \
        KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED
    # shellcheck source=../scripts/keelson-update-resource
    source "${BATS_TEST_DIRNAME}/../scripts/keelson-update-resource"
    # Its own set -u would trip on bats internals; -e must stay, or no
    # assertion here could fail.
    set +u
    validate_config() { return 0; }
    # A Deployment running main at 1.2.3 and an image volume, unowned.
    printf '%s' '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"app","namespace":"default","resourceVersion":"8","uid":"u-1","annotations":{"note":"x"}},"spec":{"template":{"spec":{"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.3"}],"volumes":[{"name":"models","image":{"reference":"ghcr.io/x/v:1"}}]}}}}' >"$TMP_DIR/obj.json"
    cat >"$TMP_BIN/kubectl" <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
# Only the object in obj.json exists: a read or patch naming another kind,
# name or namespace, or no namespace at all, finds nothing. It is asked for
# by its group-qualified resource, never a bare kind.
want="$(yq -p=json -oy '.kind + " " + .metadata.name + " " + .metadata.namespace' "$TMP_DIR/obj.json")"
want_kind=${want%% *}
case "$want_kind" in
    Deployment) want="deployments.apps ${want#* }" ;;
    StatefulSet) want="statefulsets.apps ${want#* }" ;;
    DaemonSet) want="daemonsets.apps ${want#* }" ;;
    CronJob) want="cronjobs.batch ${want#* }" ;;
    Rollout) want="rollouts.argoproj.io ${want#* }" ;;
esac
ns=""
args=("$@")
for i in "${!args[@]}"; do [ "${args[i]}" = "-n" ] && ns=${args[i+1]-}; done
case "$1" in
    get|patch)
        if [ "$2 $3 $ns" != "$want" ]; then
            echo "Error from server (NotFound): $2 \"$3\" not found" >&2
            exit 1
        fi
        ;;
esac
case "$*" in
    get*jsonpath-as-json*) yq -p=json -o=json -I0 '.metadata.managedFields // []' "$TMP_DIR/obj.json" ;;
    get*) cat "$TMP_DIR/obj.json" ;;
    patch*)
        while [ $# -gt 0 ]; do [ "$1" = "--patch" ] && printf '%s' "$2" >"$TMP_DIR/patch.body"; shift; done
        ;;
esac
SH
    chmod +x "$TMP_BIN/kubectl"
}

emit() { "$@" 2>&1; }

@test "update_resource: the running tag becomes the from-tag and the update is written" {
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"updated from 1.2.3 to 1.2.4 by claim-patch (as configured) for image 'ghcr.io/x/y'"* ]]
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"op":"test","path":"/spec/template/spec/containers/0/image","value":"ghcr.io/x/y:1.2.3"'* ]]
}

@test "update_resource: --volume updates an image volume's reference" {
    run emit main Deployment default app models ghcr.io/x/v:2 --volume
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"op":"replace","path":"/spec/template/spec/volumes/0/image/reference","value":"ghcr.io/x/v:2"'* ]]
}

@test "update_resource: another repository is refused" {
    run emit main Deployment default app main ghcr.io/other/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"it runs 'ghcr.io/x/y:1.2.3', and only the tag may change. Nothing was written."* ]]
    [ ! -e "$TMP_DIR/patch.body" ]
}

@test "update_resource: a target that is not there is refused" {
    run emit main Deployment default app absent ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no single containers entry named 'absent' with an image. Nothing was written."* ]]
}

@test "update_resource: the workload's strategy annotation is honoured" {
    yq -p=json -o=json -I0 '.metadata.annotations["keelson.pro/field-manager-strategy"] = "claim-apply"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"by claim-apply (as annotated)"* ]]
}

@test "update_resource: already that image exits 3, nothing written" {
    run emit main Deployment default app main ghcr.io/x/y:1.2.3
    [ "$status" -eq 3 ]
    [ ! -e "$TMP_DIR/patch.body" ]
}

@test "update_resource: a failed validation stops it before any read" {
    validate_config() { return 1; }
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [ ! -e "$TMP_DIR/kubectl.log" ]
}

@test "update_resource: bad usage exits 64" {
    run main Deployment default app
    [ "$status" -eq 64 ]
    run main Deployment default app main
    [ "$status" -eq 64 ]
    run main Deployment default app main ghcr.io/x/y:1.2.4 --init extra
    [ "$status" -eq 64 ]
    run main Deployment default app main ghcr.io/x/y:1.2.4 --bogus
    [ "$status" -eq 64 ]
}

@test "update_resource: asking for the image it runs writes nothing, even to claim" {
    yq -p=json -o=json -I0 '.metadata.annotations["keelson.pro/field-manager-strategy"] = "claim-apply"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment default app main ghcr.io/x/y:1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *"already runs 'ghcr.io/x/y:1.2.3'; nothing to write."* ]]
    if grep -q "^apply \|^patch " "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_resource: a new image without a tag, or with a digest, is refused before any read" {
    local img
    for img in ghcr.io/x/y reg:5000/x/y ghcr.io/x/y:2@sha256:def; do
        rm -f "$TMP_DIR/kubectl.log"
        run emit main Deployment default app main "$img"
        [ "$status" -eq 1 ] || { echo "$img: $output"; return 1; }
        [[ "$output" == *"the new image needs a tag and no digest. Nothing was written."* ]]
        [ ! -e "$TMP_DIR/kubectl.log" ]
    done
}

@test "update_resource: a running image with a digest or no tag is refused" {
    local running
    for running in 'ghcr.io/x/y:1@sha256:abc' 'ghcr.io/x/y'; do
        RUNNING=$running yq -p=json -o=json -I0 '.spec.template.spec.containers[0].image = strenv(RUNNING)' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
        mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
        run emit main Deployment default app main ghcr.io/x/y:2
        [ "$status" -eq 1 ] || { echo "$running: $output"; return 1; }
        [[ "$output" == *"which has no tag to compare, or a digest. Nothing was written."* ]]
    done
}

@test "update_resource: an unsupported kind is refused before any read" {
    run emit main deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"kind not supported"* ]]
    [ ! -e "$TMP_DIR/kubectl.log" ]
}

@test "update_resource: only Keelson's annotations are passed, one line each" {
    # A line break inside another annotation's value must not smuggle in a
    # strategy line.
    yq -p=json -o=json -I0 '.metadata.annotations.other = "line1\nkeelson.pro/field-manager-strategy=claim-apply"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"by claim-patch (as configured)"* ]]
}

@test "update_resource: --init updates an init container" {
    yq -p=json -o=json -I0 '.spec.template.spec.initContainers = [{"name": "migrate", "image": "ghcr.io/x/m:1"}]' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment default app migrate ghcr.io/x/m:2 --init
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"op":"replace","path":"/spec/template/spec/initContainers/0/image","value":"ghcr.io/x/m:2"'* ]]
}

@test "update_resource: a failed read exits 1, nothing written" {
    cat >"$TMP_BIN/kubectl" <<'SH'
#!/usr/bin/env bash
echo 'Unable to connect to the server' >&2
exit 1
SH
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not read Deployment 'app' in 'default'. Nothing was written."* ]]
}

@test "update_resource: a line break in a Keelson annotation's value stays in that value" {
    yq -p=json -o=json -I0 '.metadata.annotations["keelson.pro/policy"] = "minor\nkeelson.pro/field-manager-strategy=claim-apply"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"by claim-patch (as configured)"* ]]
}

@test "update_resource: two containers by the one name are refused" {
    yq -p=json -o=json -I0 '.spec.template.spec.containers += [{"name": "main", "image": "ghcr.io/x/y:1.2.3"}]' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no single containers entry named 'main' with an image. Nothing was written."* ]]
    [ ! -e "$TMP_DIR/patch.body" ]
}

@test "update_resource: the kind and the new image are checked before the settings" {
    validate_config() { echo "validate" >>"$TMP_DIR/calls"; return 1; }
    run emit main deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"kind not supported"* ]]
    run emit main Deployment default app main ghcr.io/x/y
    [ "$status" -eq 1 ]
    [[ "$output" == *"the new image needs a tag and no digest"* ]]
    [ ! -e "$TMP_DIR/calls" ]
}

@test "update_resource: a look-alike prefix is not read as the strategy annotation" {
    # A look-alike prefix must not be read as the strategy annotation.
    yq -p=json -o=json -I0 '.metadata.annotations["x.keelson.pro/field-manager-strategy"] = "claim-apply"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"by claim-patch (as configured)"* ]]
}

@test "update_resource: the log directory is made before the first line is logged" {
    export KEELSON_LOG_FILE_PATH="$TMP_DIR/logs/keelson.log"
    run emit main deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    grep -q "kind not supported" "$KEELSON_LOG_FILE_PATH"
}

@test "update_resource: a workload in another namespace is read and patched there" {
    yq -p=json -o=json -I0 '.metadata.namespace = "prod"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment prod app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    grep -q -- "^patch deployments.apps app -n prod " "$TMP_DIR/kubectl.log"
}

@test "update_resource: a CronJob's container is found under its job template" {
    printf '%s' '{"apiVersion":"batch/v1","kind":"CronJob","metadata":{"name":"cron","namespace":"default","resourceVersion":"8"},"spec":{"suspend":true,"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"worker","image":"ghcr.io/x/y:1.2.3"}]}}}}}}' >"$TMP_DIR/obj.json"
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"op":"replace","path":"/spec/jobTemplate/spec/template/spec/containers/0/image","value":"ghcr.io/x/y:1.2.4"'* ]]
}

@test "update_resource: Keel's annotations are passed on, so both prefixes together are refused" {
    yq -p=json -o=json -I0 '.metadata.annotations["keel.sh/policy"] = "minor" | .metadata.annotations["keelson.pro/policy"] = "minor"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"carries both keelson.pro/ and keel.sh/ annotations"* ]]
    [ ! -e "$TMP_DIR/patch.body" ]
}

@test "update_resource: an image another manager owns is written as that owner" {
    yq -p=json -o=json -I0 '.metadata.managedFields = [{"manager": "helm", "operation": "Update", "fieldsV1": {"f:spec": {"f:template": {"f:spec": {"f:containers": {"k:{\"name\":\"main\"}": {"f:image": {}}}}}}}}]' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"by mimic (as configured)"* ]]
    grep -q -- "^patch deployments.apps app -n default --type=json --field-manager=helm " "$TMP_DIR/kubectl.log"
}

@test "update_resource: -h and --help both print usage and exit 0" {
    local flag
    for flag in -h --help; do
        run main "$flag"
        [ "$status" -eq 0 ]
        [[ "$output" == *"Usage: keelson-update-resource"* ]]
    done
}

@test "update_resource: a target that is not a container name is refused before any read" {
    local t
    for t in 'm*' 'ma?n' 'Main' '-main' '*main' 'main-' 'ma_in' 'ma.in' "$(printf 'x%.0s' {1..64})"; do
        rm -f "$TMP_DIR/kubectl.log"
        run emit main Deployment default app "$t" ghcr.io/x/y:1.2.4
        [ "$status" -eq 1 ] || { echo "$t: $output"; return 1; }
        [[ "$output" == *"is not a container or volume name. Nothing was written."* ]]
        [ ! -e "$TMP_DIR/kubectl.log" ]
    done
}

@test "update_resource: a 63-character name is a name, and the name is checked before the settings" {
    local long
    long=$(printf 'x%.0s' {1..63})
    run emit main Deployment default app "$long" ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no single containers entry named '$long'"* ]]
    validate_config() { echo "validate" >>"$TMP_DIR/calls"; return 1; }
    run emit main Deployment default app 'm*' ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a container or volume name"* ]]
    [ ! -e "$TMP_DIR/calls" ]
}

@test "update_resource: the real validation and its helpers are there to call" {
    # setup stubs validate_config; this asks a fresh shell what the script
    # itself brings in.
    run bash -c 'source "$1"; declare -F validate_config registry_key_valid' _ "${BATS_TEST_DIRNAME}/../scripts/keelson-update-resource"
    [ "$status" -eq 0 ]
    [[ "$output" == *validate_config*registry_key_valid* ]]
}

@test "update_resource: a tag outside the reference grammar is refused before any read" {
    local img
    for img in 'ghcr.io/x/y:1.\x32' 'ghcr.io/x/y:1"2' 'ghcr.io/x/y:-1' 'ghcr.io/x/y:.1' 'ghcr.io/x/y:\1.2' "ghcr.io/x/y:$(printf 'x%.0s' {1..129})"; do
        rm -f "$TMP_DIR/kubectl.log"
        run emit main Deployment default app main "$img"
        [ "$status" -eq 1 ] || { echo "$img: $output"; return 1; }
        [[ "$output" == *"is not a valid tag. Nothing was written."* ]]
        [ ! -e "$TMP_DIR/kubectl.log" ]
    done
    # The grammar's own edges are tags, 128 characters the longest.
    run emit main Deployment default app main "ghcr.io/x/y:_A.b-1"
    [[ "$output" != *"is not a valid tag"* ]]
    run emit main Deployment default app main "ghcr.io/x/y:$(printf 'x%.0s' {1..128})"
    [[ "$output" != *"is not a valid tag"* ]]
}

@test "update_resource: the tag grammar is checked before the settings" {
    validate_config() { echo "validate" >>"$TMP_DIR/calls"; return 1; }
    run emit main Deployment default app main ghcr.io/x/y:-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a valid tag"* ]]
    [ ! -e "$TMP_DIR/calls" ]
}

@test "update_resource: a workload gone between its read and the write exits 3" {
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    cat >"$TMP_BIN/kubectl" <<SH
#!/usr/bin/env bash
if [[ "\$*" == *jsonpath-as-json* ]]; then echo 'Error from server (NotFound): deployments.apps "app" not found' >&2; exit 1; fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    chmod +x "$TMP_BIN/kubectl"
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 3 ]
    [[ "$output" == *"is gone since the poll; nothing to write."* ]]
    [ ! -e "$TMP_DIR/patch.body" ]
}

# A suspended CronJob annotated to trigger, running worker beside a sidecar
# and an init container. $1 sets spec.suspend, $2 the annotation's value.
trigger_cron() {
    printf '{"apiVersion":"batch/v1","kind":"CronJob","metadata":{"name":"cron","namespace":"default","resourceVersion":"8","uid":"u-1","annotations":{"keelson.pro/trigger-job-on-update":"%s"}},"spec":{"suspend":%s,"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"worker","image":"ghcr.io/x/y:1.2.3"},{"name":"side","image":"ghcr.io/x/s:9"}],"initContainers":[{"name":"init","image":"ghcr.io/x/i:4"}]}}}}}}' \
        "${2:-true}" "${1:-true}" >"$TMP_DIR/obj.json"
    # The ledger, as this process holds and writes it, stubbed: state_init
    # loads an empty one, state_flush writes what is set to ledger.out.
    KEELSON_STATE_CONFIGMAP=keelson-state
    state_init() { echo init >>"$TMP_DIR/calls"; STATE_LOADED=1; [ ! -e "$TMP_DIR/no-state" ]; }
    state_flush() {
        local k
        for k in "${!STATE_FIELDS[@]}"; do printf '%s=%s\n' "$k" "${STATE_FIELDS[$k]}"; done | sort >"$TMP_DIR/ledger.out"
        [ ! -e "$TMP_DIR/no-flush" ]
    }
}

@test "update_resource: a suspended CronJob annotated to trigger gets a Job, recorded with every image it now runs" {
    trigger_cron
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    grep -q -- "^create job cron-[0-9]* --from=cronjobs.batch/cron -n default$" "$TMP_DIR/kubectl.log"
    [[ "$output" == *"created from CronJob 'cron' in 'default' with update from 1.2.3 to 1.2.4 for image 'ghcr.io/x/y'."* ]]
    # The update is written before the Job is created.
    [ "$(grep -n '^patch ' "$TMP_DIR/kubectl.log" | cut -d: -f1)" -lt "$(grep -n '^create job ' "$TMP_DIR/kubectl.log" | cut -d: -f1)" ]
    key=$(state_trigger_key CronJob default cron)
    grep -qx "$key:containers/worker=ghcr.io/x/y:1.2.4" "$TMP_DIR/ledger.out"
    grep -qx "$key:containers/side=ghcr.io/x/s:9" "$TMP_DIR/ledger.out"
    grep -qx "$key:initContainers/init=ghcr.io/x/i:4" "$TMP_DIR/ledger.out"
    grep -q "^$key:triggered-at=" "$TMP_DIR/ledger.out"
}

@test "update_resource: a CronJob not annotated to trigger, or a Deployment, gets no Job" {
    trigger_cron true false
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    if grep -q '^create ' "$TMP_DIR/kubectl.log"; then false; fi
    [ ! -e "$TMP_DIR/calls" ]
    rm -f "$TMP_DIR/kubectl.log"
    printf '%s' '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"app","namespace":"default","resourceVersion":"8","uid":"u-1","annotations":{"keelson.pro/trigger-job-on-update":"true"}},"spec":{"template":{"spec":{"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}' >"$TMP_DIR/obj.json"
    run emit main Deployment default app main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    if grep -q '^create ' "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_resource: a CronJob not suspended is written but not triggered, and exits 1" {
    trigger_cron false
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    grep -q '^patch ' "$TMP_DIR/kubectl.log"
    if grep -q '^create ' "$TMP_DIR/kubectl.log"; then false; fi
    [[ "$output" == *"spec.suspend is not true; refusing to trigger to avoid racing the scheduler. Its image was written."* ]]
}

@test "update_resource: nothing written, or a failed write, triggers nothing" {
    trigger_cron
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.3
    [ "$status" -eq 3 ]
    if grep -q '^create ' "$TMP_DIR/kubectl.log"; then false; fi
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    cat >"$TMP_BIN/kubectl" <<SH
#!/usr/bin/env bash
if [ "\$1" = patch ]; then echo "\$@" >>"$TMP_DIR/kubectl.log"; echo 'Error from server (Forbidden): no' >&2; exit 1; fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    chmod +x "$TMP_BIN/kubectl"
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    if grep -q '^create ' "$TMP_DIR/kubectl.log"; then false; fi
    [ ! -e "$TMP_DIR/calls" ]
}

@test "update_resource: a Job that cannot be created exits 1 and records no firing" {
    trigger_cron
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    cat >"$TMP_BIN/kubectl" <<SH
#!/usr/bin/env bash
if [ "\$1" = create ]; then echo 'Error from server (Forbidden): jobs.batch is forbidden' >&2; exit 1; fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    chmod +x "$TMP_BIN/kubectl"
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    [[ "$output" == *"updated from 1.2.3 to 1.2.4"* ]]
    [[ "$output" == *"Could not create Job 'cron-"*"' from CronJob 'cron' in 'default': Error from server (Forbidden): jobs.batc"* ]]
    [ ! -e "$TMP_DIR/ledger.out" ]
}

@test "update_resource: a ledger that cannot be read still triggers, and it or one that cannot be written exits 1" {
    trigger_cron
    touch "$TMP_DIR/no-state"
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    grep -q '^create job cron-' "$TMP_DIR/kubectl.log"
    [[ "$output" == *"triggering without recording it, so the controller may trigger CronJob 'cron' in 'default' once more."* ]]
    [ ! -e "$TMP_DIR/ledger.out" ]

    trigger_cron
    rm -f "$TMP_DIR/no-state" "$TMP_DIR/kubectl.log"
    touch "$TMP_DIR/no-flush"
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    grep -q '^create job cron-' "$TMP_DIR/kubectl.log"
}

@test "update_resource: no ledger ConfigMap named still triggers, without recording, and exits 1" {
    trigger_cron
    unset KEELSON_STATE_CONFIGMAP
    run emit main CronJob default cron worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 1 ]
    grep -q '^create job cron-' "$TMP_DIR/kubectl.log"
    [ ! -e "$TMP_DIR/calls" ]
    [ ! -e "$TMP_DIR/ledger.out" ]
}
