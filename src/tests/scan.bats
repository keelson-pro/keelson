#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# Tests for lib/scan.bash orchestration. Network tooling (kubectl, skopeo) is
# provided via PATH-prepended shim scripts in $TMP_BIN. Real yq is used.
# To keep cases focused we set KEELSON_WATCHED_KINDS to a single kind per test.

load helper

setup() {
    tmp_dir_init
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    export PATH TMP_DIR

    KEELSON_WATCHED_KINDS=Deployment
    KEELSON_SCOPE=cluster
    KEELSON_CONFIG_MODE=keelson
    KEELSON_RESPECT_SA_PULL_SECRETS=false
    KEELSON_REGISTRIES_FILE="$TMP_DIR/registries.yaml"
    rm -f "$KEELSON_REGISTRIES_FILE"
    # Most events the scan emits are at debug level now (scan-start, summary,
    # skip-not-eligible, no-change). Run at debug so assertions can see them.
    KEELSON_LOG_LEVEL=DEBUG
    # Plain format collapses to the msg= sentence and drops event/field tags.
    # Tests assert on both sentences and structured fields, so use JSON.
    KEELSON_LOG_FORMAT=json
    export KEELSON_WATCHED_KINDS KEELSON_SCOPE KEELSON_CONFIG_MODE \
        KEELSON_RESPECT_SA_PULL_SECRETS KEELSON_REGISTRIES_FILE \
        KEELSON_LOG_LEVEL KEELSON_LOG_FORMAT

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/policy.bash
    source "$SCRIPT_DIR/lib/policy.bash"
    # shellcheck source=../scripts/lib/image.bash
    source "$SCRIPT_DIR/lib/image.bash"
    # shellcheck source=../scripts/lib/annotations.bash
    source "$SCRIPT_DIR/lib/annotations.bash"
    # shellcheck source=../scripts/lib/workload.bash
    source "$SCRIPT_DIR/lib/workload.bash"
    # shellcheck source=../scripts/lib/registry.bash
    source "$SCRIPT_DIR/lib/registry.bash"
    # shellcheck source=../scripts/lib/eligibility.bash
    source "$SCRIPT_DIR/lib/eligibility.bash"
    # shellcheck source=../scripts/lib/managedfields.bash
    source "$SCRIPT_DIR/lib/managedfields.bash"
    # shellcheck source=../scripts/lib/update.bash
    source "$SCRIPT_DIR/lib/update.bash"
    # shellcheck source=../scripts/lib/state.bash
    source "$SCRIPT_DIR/lib/state.bash"
    # shellcheck source=../scripts/lib/clock.bash
    source "$SCRIPT_DIR/lib/clock.bash"
    # shellcheck source=../scripts/lib/inventory.bash
    source "$SCRIPT_DIR/lib/inventory.bash"
    # shellcheck source=../scripts/lib/queue.bash
    source "$SCRIPT_DIR/lib/queue.bash"
    # shellcheck source=../scripts/lib/scan.bash
    source "$SCRIPT_DIR/lib/scan.bash"

    KEELSON_INVENTORY_DIR="$TMP_DIR/inventory"
    KEELSON_FIRST_POLL_DELAY_MAX=300
    export KEELSON_FIRST_POLL_DELAY_MAX
    KEELSON_QUEUE_DIR="$TMP_DIR/queue"
    KEELSON_RECONCILE_INTERVAL=60
    export KEELSON_RECONCILE_INTERVAL
}

# Logs are emitted on stderr; merge to stdout so `run` captures them.
emit() { "$@" 2>&1; }

install_shim() {
    local name=$1
    cat > "$TMP_BIN/$name"
    chmod +x "$TMP_BIN/$name"
}

# kubectl shim that emits the contents of $KUBECTL_FIXTURE on any get call.
kubectl_returns() {
    local fixture=$1
    cat > "$TMP_BIN/kubectl" <<SH
#!/usr/bin/env bash
cat <<'JSON'
$fixture
JSON
SH
    chmod +x "$TMP_BIN/kubectl"
}

# Helper: emit a Deployment list with a single container.
single_deployment_json() {
    local image=$1 policy=${2:-} match=${3:-}
    local ann='{}'
    if [ -n "$policy" ] && [ -n "$match" ]; then
        ann=$(printf '{"keelson.pro/policy":"%s","keelson.pro/match-tag":"%s"}' "$policy" "$match")
    elif [ -n "$policy" ]; then
        ann=$(printf '{"keelson.pro/policy":"%s"}' "$policy")
    fi
    cat <<JSON
{
  "items": [
    {
      "metadata": {
        "namespace": "default",
        "name": "app",
        "annotations": $ann
      },
      "spec": {
        "template": {
          "spec": {
            "containers": [
              {"name": "main", "image": "$image"}
            ]
          }
        }
      }
    }
  ]
}
JSON
}

# --- empty / no workloads ---

@test "scan_run: no workloads anywhere → summary all zeros" {
    kubectl_returns '{"items": []}'
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"scan-start"* ]]
    [[ "$output" == *"scan-summary"* ]]
    [[ "$output" == *'"resources":"0"'* ]]
    [[ "$output" == *'"would-update":"0"'* ]]
    [[ "$output" == *'"no-change":"0"'* ]]
    [[ "$output" == *'"skip":"0"'* ]]
}

# --- skip reasons surface as skip-not-eligible ---

@test "scan_run: container with no policy annotation → skip-not-eligible" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3)"
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"skip-not-eligible"* ]]
    [[ "$output" == *'"reason":"no-policy-annotation"'* ]]
    [[ "$output" == *'"skip":"1"'* ]]
}

@test "scan_run: container with policy=never → skip-not-eligible policy-never" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 never)"
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"reason":"policy-never"'* ]]
}

@test "scan_run: digest-pinned image → skip tag-is-digest-pinned" {
    kubectl_returns "$(single_deployment_json 'ghcr.io/x/y@sha256:deadbeef' major)"
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"reason":"tag-is-digest-pinned"'* ]]
}

@test "scan_run: latest tag → skip tag-is-latest" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:latest minor)"
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"reason":"tag-is-latest"'* ]]
}

# --- eligible workloads ---

@test "scan_run: eligible workload, no newer tag → dry-run-no-change" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.0","1.2.1","1.2.3"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run-no-change"* ]]
    [[ "$output" == *'"no-change":"1"'* ]]
    [[ "$output" == *'"would-update":"0"'* ]]
}

@test "scan_run: eligible workload, newer minor candidate → dry-run-would-update" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0","1.4.0"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run-would-update"* ]]
    [[ "$output" == *'"would-update":"1"'* ]]
}

@test "scan_run: patch policy ignores newer minor" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 patch)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.2.4","1.3.0"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run-would-update"* ]]
    [[ "$output" == *'"candidate":"1.2.4"'* ]]
}

@test "scan_run: non-numeric candidates are rejected" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","v1.3.0","1.3.0-rc1","latest"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run-no-change"* ]]
}

@test "scan_run: match-tag filter drops non-matching candidates" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 all '1.*')"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","2.0.0","1.4.0"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"candidate":"1.4.0"'* ]]
}

# --- error paths ---

@test "scan_run: kubectl failure increments error counter" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 1
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"kubectl-list-failed"* ]]
    [[ "$output" == *'"error":"1"'* ]]
}

@test "scan_run: skopeo failure increments error counter for that container" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
exit 1
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"registry-list-tags-failed"* ]]
    [[ "$output" == *'"error":"1"'* ]]
}

# --- scan-start emits the configured mode ---

@test "scan_run: scan-start mode is dry-run when apply=0" {
    kubectl_returns '{"items": []}'
    run emit scan_run 0
    [[ "$output" == *'"event":"scan-start"'* ]]
    [[ "$output" == *'"mode":"dry-run"'* ]]
}

@test "scan_run: scan-start mode is apply when apply=1" {
    kubectl_returns '{"items": []}'
    run emit scan_run 1
    [[ "$output" == *'"event":"scan-start"'* ]]
    [[ "$output" == *'"mode":"apply"'* ]]
}

# --- apply mode ---

# kubectl shim that returns the fixture on `get` and records other verbs to
# $TMP_DIR/kubectl.log. Exit codes for patch/create are overridable via
# KUBECTL_PATCH_EXIT / KUBECTL_CREATE_EXIT (default 0).
kubectl_apply_shim() {
    local fixture=$1
    cat > "$TMP_BIN/kubectl" <<SH
#!/usr/bin/env bash
case "\$1" in
    get)
        cat <<'JSON'
$fixture
JSON
        ;;
    patch)
        printf '%s\n' "\$*" >>"$TMP_DIR/kubectl.log"
        exit \${KUBECTL_PATCH_EXIT:-0}
        ;;
    create)
        printf '%s\n' "\$*" >>"$TMP_DIR/kubectl.log"
        exit \${KUBECTL_CREATE_EXIT:-0}
        ;;
    *)
        exit 0
        ;;
esac
SH
    chmod +x "$TMP_BIN/kubectl"
}

# Helper: emit a CronJob list with a single container.
# trigger="" -> no trigger annotation; trigger="true" -> annotated.
# suspend defaults to "true" (the only valid configuration for
# trigger-job-on-update); pass "false" to test the requires-suspend gate.
single_cronjob_json() {
    local image=$1 policy=$2 trigger=${3:-} suspend=${4:-true}
    local kv="\"keelson.pro/policy\":\"$policy\""
    if [ -n "$trigger" ]; then
        kv="$kv,\"keelson.pro/trigger-job-on-update\":\"$trigger\""
    fi
    cat <<JSON
{
  "items": [
    {
      "metadata": {
        "namespace": "default",
        "name": "cron",
        "annotations": {$kv}
      },
      "spec": {
        "suspend": $suspend,
        "jobTemplate": {
          "spec": {
            "template": {
              "spec": {
                "containers": [
                  {"name": "worker", "image": "$image"}
                ]
              }
            }
          }
        }
      }
    }
  ]
}
JSON
}

@test "scan_run apply: newer candidate emits update sentence + updated counter" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deployment 'app' in 'default' updated from 1.2.3 to 1.3.0 for image 'ghcr.io/x/y'"* ]]
    [[ "$output" == *'"updated":"1"'* ]]
    [[ "$output" == *'"would-update":"0"'* ]]
}

@test "scan_run apply: kubectl patch failure → update-failed and error counter" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    KUBECTL_PATCH_EXIT=1
    export KUBECTL_PATCH_EXIT
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"update-failed"* ]]
    [[ "$output" == *'"error":"1"'* ]]
    [[ "$output" == *'"updated":"0"'* ]]
}

@test "scan_run apply: no newer candidate logs no-change (not dry-run-no-change)" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *'"event":"no-change"'* ]]
    [[ "$output" != *'"event":"dry-run-no-change"'* ]]
    [[ "$output" == *'"no-change":"1"'* ]]
}

@test "scan_run apply: CronJob with trigger-job-on-update=true creates a Job" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    KEELSON_WATCHED_KINDS=CronJob run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"CronJob 'cron' in 'default' updated from 1.2.3 to 1.3.0 for image 'ghcr.io/x/y'"* ]]
    [[ "$output" =~ Job\ \'cron-[0-9]+\'\ created\ from\ CronJob\ \'cron\'\ in\ \'default\'\ with\ update\ from\ 1.2.3\ to\ 1.3.0\ for\ image\ \'ghcr.io/x/y\' ]]
    grep -q "create job" "$TMP_DIR/kubectl.log"
    grep -q -- "--from=cronjob/cron" "$TMP_DIR/kubectl.log"
}

@test "scan_run apply: CronJob without trigger-job-on-update does not create a Job" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    KEELSON_WATCHED_KINDS=CronJob run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"CronJob 'cron' in 'default' updated from 1.2.3 to 1.3.0 for image 'ghcr.io/x/y'"* ]]
    [[ "$output" != *"created from CronJob"* ]]
    ! grep -q "create job" "$TMP_DIR/kubectl.log" 2>/dev/null || false
}

@test "scan_run dry-run: no kubectl patch calls" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run-would-update"* ]]
    ! grep -q "^patch" "$TMP_DIR/kubectl.log" 2>/dev/null || false
}

# --- CronJob trigger gate: suspend required ---

@test "scan_run apply: CronJob trigger=true + suspend=false logs requires-suspend, no Job" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true false)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    KEELSON_WATCHED_KINDS=CronJob run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"cronjob-trigger-requires-suspend"* ]]
    [[ "$output" != *"created from CronJob"* ]]
    ! grep -q "create job" "$TMP_DIR/kubectl.log" 2>/dev/null || false
}

@test "scan_run apply: CronJob trigger=true + suspend=true + no update -> always-once triggers Job (concise sentence)" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true true)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    KEELSON_WATCHED_KINDS=CronJob run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" != *"updated from"* ]]
    [[ "$output" =~ Job\ \'cron-[0-9]+\'\ created\ from\ CronJob\ \'cron\'\ in\ \'default\' ]]
    [[ "$output" != *"with update from"* ]]
    grep -q "create job" "$TMP_DIR/kubectl.log"
}

# Log dedupe is handled in lib/log.bash's rate limiter (covered by log.bats);
# the scan no longer carries any per-container persisted state. Old tests for
# state-backed skip/error/no-change dedupe have been removed accordingly.

# --- inventory maintenance (the reconcile pass fills the local cache) ---
#
# The scan is the authority: it lists the cluster, so it both records what it
# found and forgets what has gone. Everything here is derived, so a rebuild
# from one pass is always enough.

@test "inventory: a scan with no inventory directory touches nothing" {
    # keelson-user-recheck run outside a controller pod has no inventory to keep.
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    [ ! -d "$KEELSON_INVENTORY_DIR" ]
}

@test "inventory: a scan records every workload it saw" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NAME" = "app" ]
    [ "$INVENTORY_INTERVAL" = "60" ]
}

@test "inventory: an ineligible workload is still recorded" {
    # No policy annotation means no updates, but Keelson still needs to know
    # it exists: an event can make it eligible later.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0)"
    scan_run 0 2>/dev/null
    run inventory_get Deployment default app
    [ "$status" -eq 0 ]
}

@test "inventory: a new workload is scheduled inside its first interval" {
    # Offset by a hash of the identity rather than all landing on now+interval,
    # so an estate cached in one pass does not fall due in lockstep after.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    clock_read
    local before=$(( CLOCK_NOW_US / 1000000 ))
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" -ge "$before" ]
    [ "$INVENTORY_NEXT_DUE" -lt "$(( before + 60 ))" ]
}

@test "inventory: a workload already cached keeps its place in the cycle" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    local first=$INVENTORY_NEXT_DUE
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "$first" ]
}

@test "inventory: the record carries what a poll needs" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "${INVENTORY_CONTAINER_NAMES[0]}" = "main" ]
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io/x/y:1.0" ]
    [ "$INVENTORY_SERVICE_ACCOUNT" = "default" ]
    printf '%s' "$INVENTORY_ANNOTATIONS" | grep -q 'policy=minor'
}

@test "inventory: image-pull-secrets are cached on one line" {
    # A pretty-printed value would be read back as several truncated entries.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "$(printf '%s' "$INVENTORY_IMAGE_PULL_SECRETS" | grep -c .)" = "1" ]
}

# --- poll-schedule, per workload ---

deployment_with_schedule() {
    local image=$1 schedule=$2
    cat <<JSON
{
  "items": [
    {
      "metadata": {
        "namespace": "default",
        "name": "app",
        "annotations": {
          "keelson.pro/policy": "minor",
          "keelson.pro/poll-schedule": "$schedule"
        }
      },
      "spec": {
        "template": {
          "spec": {
            "containers": [ {"name": "main", "image": "$image"} ]
          }
        }
      }
    }
  ]
}
JSON
}

@test "poll-schedule: sets the workload's own interval" {
    inventory_init
    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:1.0 2h)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_INTERVAL" = "7200" ]
}

@test "poll-schedule: keel's @every form is honoured" {
    inventory_init
    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:1.0 '@every 10m')"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_INTERVAL" = "600" ]
}

@test "poll-schedule: absent falls back to the global default" {
    inventory_init
    KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT=900
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_INTERVAL" = "900" ]
}

@test "poll-schedule: an unparseable value falls back and warns" {
    inventory_init
    KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT=900
    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:1.0 '*/5 * * * *')"
    run emit scan_run 0
    [[ "$output" == *"poll-schedule-invalid"* ]]
    inventory_get Deployment default app
    [ "$INVENTORY_INTERVAL" = "900" ]
}

@test "poll-schedule: a sub-second value clamps to 1s and warns" {
    inventory_init
    KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT=900
    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:1.0 300ms)"
    run emit scan_run 0
    [[ "$output" == *"poll-schedule-too-fast"* ]]
    inventory_get Deployment default app
    [ "$INVENTORY_INTERVAL" = "1" ]
}

@test "inventory: the fingerprint carries the image" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [[ "$INVENTORY_FINGERPRINT" == *"ghcr.io/x/y:1.0"* ]]
}

@test "inventory: the fingerprint carries the decision annotations" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [[ "$INVENTORY_FINGERPRINT" == *"minor"* ]]
}

@test "inventory: the fingerprint changes when the cadence changes" {
    inventory_init
    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:1.0 5m)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    local first=$INVENTORY_FINGERPRINT
    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:1.0 10m)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_FINGERPRINT" != "$first" ]
}

@test "inventory: the fingerprint changes when the image changes" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    local first=$INVENTORY_FINGERPRINT
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:2.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_FINGERPRINT" != "$first" ]
}

@test "inventory: a workload gone from the cluster is evicted" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null
    inventory_get Deployment default app

    kubectl_returns '{"items": []}'
    scan_run 0 2>/dev/null
    run inventory_get Deployment default app
    [ "$status" -eq 1 ]
}

@test "inventory: a failed list does NOT evict that kind's entries" {
    # A transient API error must never be read as "everything was deleted".
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null

    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "the server was unable to return a response" >&2
exit 1
SH
    scan_run 0 2>/dev/null
    run inventory_get Deployment default app
    [ "$status" -eq 0 ]
}

@test "inventory: entries of an unwatched kind survive a scan" {
    # Only kinds this pass actually listed are candidates for eviction.
    inventory_init
    inventory_put CronJob ops backup 1000 60 "fp"
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    KEELSON_WATCHED_KINDS=Deployment scan_run 0 2>/dev/null
    run inventory_get CronJob ops backup
    [ "$status" -eq 0 ]
}

@test "inventory: an evicted workload is forgotten in the ledger too" {
    local due=$(( $(date -u +%s) + 30 ))
    # Otherwise a CronJob's trigger entry outlives the CronJob and the state
    # ConfigMap only ever grows.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null

    kubectl_returns '{"items": []}'
    scan_run 0 2>/dev/null
    # Apply removes what it omits, so a forgotten key is one that has left
    # the cache rather than one carrying a deletion marker.
    [ -z "${STATE_KEYS[j--Deployment--default--app]:-}" ]
}

# --- next-due drives the registry, not the scan ---
#
# The tick asks the cache what is due and polls only that, so a workload's
# cadence is its own. The controller's scan makes no registry calls at all;
# it refreshes the cache and evicts. A one-shot boot scan passes poll-all=1
# and behaves as it always did.

# A skopeo shim that records every invocation, so a test can assert on the
# absence of registry traffic rather than merely the absence of an update.
skopeo_counting() {
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
echo call >> "$TMP_DIR/skopeo.calls"
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
}

skopeo_call_count() {
    [ -f "$TMP_DIR/skopeo.calls" ] || { printf '0'; return 0; }
    wc -l < "$TMP_DIR/skopeo.calls" | tr -d ' '
}

# now, far enough past any next-due the cache holds
LATE=99999999999

@test "poll: the controller's scan makes no registry calls" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    skopeo_counting
    scan_run 0 0 2>/dev/null
    [ "$(skopeo_call_count)" = "0" ]
}

@test "poll: a boot scan with poll-all still polls everything" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    skopeo_counting
    scan_run 0 1 2>/dev/null
    [ "$(skopeo_call_count)" = "1" ]
}

@test "poll: a due workload is polled from cache, with no cluster read" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    scan_run 0 0 2>/dev/null
    skopeo_counting
    # kubectl now fails: a poll must need nothing from the cluster except
    # managedFields, which is allowed to come back empty.
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 1
SH
    scan_poll_due 0 "$LATE" 2>/dev/null
    [ "$(skopeo_call_count)" = "1" ]
}

@test "poll: nothing due means no registry calls" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    scan_run 0 0 2>/dev/null
    skopeo_counting
    # Its next-due is at most one interval out, and this is now.
    scan_poll_due 0 1 2>/dev/null
    [ "$(skopeo_call_count)" = "0" ]
}

@test "poll: a polled workload drops out until its interval elapses" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    scan_run 0 0 2>/dev/null
    skopeo_counting
    scan_poll_due 0 "$LATE" 2>/dev/null
    scan_poll_due 0 "$LATE" 2>/dev/null
    [ "$(skopeo_call_count)" = "1" ]
}

@test "poll: next-due advances by the workload's own interval" {
    inventory_init
    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:1.2.3 2h)"
    skopeo_counting
    scan_run 0 0 2>/dev/null
    scan_poll_due 0 "$LATE" 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "$(( LATE + 7200 ))" ]
}

@test "poll: an empty cache polls nothing" {
    inventory_init
    skopeo_counting
    scan_poll_due 0 "$LATE" 2>/dev/null
    [ "$(skopeo_call_count)" = "0" ]
}

@test "poll: with no cache at all it does nothing" {
    skopeo_counting
    run scan_poll_due 0 "$LATE"
    [ "$status" -eq 0 ]
    [ "$(skopeo_call_count)" = "0" ]
}

@test "poll: a cached update is applied" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    scan_run 0 0 2>/dev/null
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    run emit scan_poll_due 0 "$LATE"
    [[ "$output" == *"dry-run-would-update"* ]]
}

# --- the scan is the safety net for what events missed ---
#
# A watch stream can gap while a watcher is down, and it cannot carry
# annotation changes at all. The reconcile pass is the only thing that sees
# the whole cluster, so a record it finds changed has to become due now
# rather than waiting out a schedule that could be a day long.

@test "resync: an image changed behind our back makes the workload due now" {
    inventory_init
    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:1.0 1d)"
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    # A day's schedule, but the first poll is capped, so it is not yet due.
    [ "$INVENTORY_NEXT_DUE" -gt "$(date -u +%s)" ]

    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:2.0 1d)"
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" -le "$(date -u +%s)" ]
}

@test "resync: an annotation change makes the workload due now" {
    local due=$(( $(date -u +%s) + 30 ))
    # The watch stream cannot see these at all, so only the scan can.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app "$due"

    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 patch)"
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" -le "$(date -u +%s)" ]
}

@test "resync: an unchanged workload keeps its place in the cycle" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    local due=$(( $(date -u +%s) + 30 ))
    inventory_set_next_due Deployment default app "$due"

    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "$due" ]
}

@test "resync: it says so, so an operator knows the watch missed something" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:2.0 minor)"
    run emit scan_run 0 0
    [[ "$output" == *"scan-resync"* ]]
}

# --- schedules survive a restart ---
#
# The cache dies with the pod. The schedule is derived from the identity, so a
# cold start spreads the estate without persisting anything; the ledger only
# records that Keelson has seen the workload.

@test "restart: a cold cache derives its offset inside the window" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    local before=$(date -u +%s)
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" -ge "$before" ]
    [ "$INVENTORY_NEXT_DUE" -le "$(( before + 60 ))" ]
}

@test "restart: a cold cache records the workload in the ledger" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    [ -n "$(state_get w--Deployment--default--app first-seen)" ]
}

@test "poll: polling writes nothing to the ledger" {
    # The whole point: a next-due written per poll was a ConfigMap patch per
    # tick once workloads actually came due.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    scan_run 0 0 2>/dev/null
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    STATE_DIRTY=()
    scan_poll_due 0 "$LATE" 2>/dev/null
    [ "${#STATE_DIRTY[@]}" -eq 0 ]
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" -gt "$LATE" ]
}

@test "evict: a workload gone from the cluster is forgotten in the ledger too" {
    # Otherwise the ConfigMap accumulates keys for workloads that no longer
    # exist and walks into its size limit over months.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    [ -n "$(state_get w--Deployment--default--app first-seen)" ]

    kubectl_returns '{"items": []}'
    scan_run 0 0 2>/dev/null
    [ -z "$(state_get w--Deployment--default--app first-seen)" ]
    [ -z "${STATE_KEYS[w--Deployment--default--app]:-}" ]
}

# --- the queued re-read: what a watch event actually turns into ---
#
# The event carries coordinates only, so the cluster is the only thing that
# can say what changed. These cover the read itself and the one comparison
# that decides whether a workload's schedule is brought forward.

@test "queue refresh: an empty queue reads nothing" {
    inventory_init
    queue_init
    kubectl_returns '{"items": []}'
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$TMP_DIR/kubectl.calls"
printf '{"items": []}'
SH
    scan_refresh_queued 0 2>/dev/null
    [ ! -f "$TMP_DIR/kubectl.calls" ]
}

@test "queue refresh: a queued identity is read and cached" {
    inventory_init
    queue_init
    kubectl_returns "$(single_deployment_json 'ghcr.io/x/y:1.0' minor)"
    queue_enqueue Deployment default app
    scan_refresh_queued 0 2>/dev/null
    inventory_get Deployment default app
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io/x/y:1.0" ]
    [ "$(queue_size)" = "0" ]
}

@test "queue refresh: the read is scoped to the one workload" {
    inventory_init
    queue_init
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMP_DIR/kubectl.calls"
printf '{"items": []}'
SH
    queue_enqueue Deployment default app
    scan_refresh_queued 0 2>/dev/null
    grep -q -- "--field-selector metadata.name=app" "$TMP_DIR/kubectl.calls"
    grep -q -- "-n default" "$TMP_DIR/kubectl.calls"
}

@test "queue refresh: a changed annotation brings the poll forward" {
    local due=$(( $(date -u +%s) + 30 ))
    # The case the whole re-read exists for: nothing about the image moved,
    # but the decision Keelson would make did.
    inventory_init
    queue_init
    kubectl_returns "$(single_deployment_json 'ghcr.io/x/y:1.0' minor)"
    queue_enqueue Deployment default app
    scan_refresh_queued 0 2>/dev/null
    inventory_get Deployment default app
    inventory_set_next_due Deployment default app "$due"

    kubectl_returns "$(single_deployment_json 'ghcr.io/x/y:1.0' major)"
    queue_enqueue Deployment default app
    scan_refresh_queued 0 2>/dev/null
    inventory_get Deployment default app
    clock_read
    [ "$INVENTORY_NEXT_DUE" -le "$(( CLOCK_NOW_US / 1000000 ))" ]
}

@test "queue refresh: an unchanged workload keeps its schedule" {
    local due=$(( $(date -u +%s) + 30 ))
    # Status churn is most of what a watch delivers and must cost nothing
    # beyond the read itself.
    inventory_init
    queue_init
    kubectl_returns "$(single_deployment_json 'ghcr.io/x/y:1.0' minor)"
    queue_enqueue Deployment default app
    scan_refresh_queued 0 2>/dev/null
    inventory_set_next_due Deployment default app "$due"

    queue_enqueue Deployment default app
    scan_refresh_queued 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "$due" ]
}

@test "queue refresh: a workload that has gone is left for the delete event" {
    inventory_init
    queue_init
    kubectl_returns "$(single_deployment_json 'ghcr.io/x/y:1.0' minor)"
    queue_enqueue Deployment default app
    scan_refresh_queued 0 2>/dev/null

    kubectl_returns '{"items": []}'
    queue_enqueue Deployment default app
    scan_refresh_queued 0 2>/dev/null
    inventory_get Deployment default app
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io/x/y:1.0" ]
}

@test "queue refresh: a burst lists the kind instead of reading one at a time" {
    inventory_init
    queue_init
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMP_DIR/kubectl.calls"
printf '{"items": []}'
SH
    SCAN_QUEUE_LIST_THRESHOLD=3
    queue_enqueue Deployment default a
    queue_enqueue Deployment default b
    queue_enqueue Deployment default c
    scan_refresh_queued 0 2>/dev/null
    [ "$(wc -l <"$TMP_DIR/kubectl.calls")" -eq 1 ]
    ! grep -q -- "--field-selector" "$TMP_DIR/kubectl.calls"
    grep -q -- "--all-namespaces" "$TMP_DIR/kubectl.calls"
}

# --- init containers are containers ---
#
# An init container that prepares the app container is exactly the thing that
# must not drift a release behind it, so Keelson treats both lists the same.
# What differs is only where an update is written back.

deployment_with_init_json() {
    local image=$1 init_image=$2 policy=${3:-minor}
    cat <<JSON
{
  "items": [
    {
      "metadata": {
        "namespace": "default",
        "name": "app",
        "annotations": {"keelson.pro/policy": "$policy",
                        "keelson.pro/initContainers": "true"}
      },
      "spec": {
        "template": {
          "spec": {
            "initContainers": [
              {"name": "migrate", "image": "$init_image"}
            ],
            "containers": [
              {"name": "main", "image": "$image"}
            ]
          }
        }
      }
    }
  ]
}
JSON
}

@test "init containers: both lists are cached, each knowing where it lives" {
    inventory_init
    kubectl_returns "$(deployment_with_init_json ghcr.io/x/y:1.2.3 ghcr.io/x/m:1.4.0)"
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "${#INVENTORY_CONTAINER_NAMES[@]}" -eq 2 ]
    [ "${INVENTORY_CONTAINER_LISTS[0]}" = "containers" ]
    [ "${INVENTORY_CONTAINER_NAMES[0]}" = "main" ]
    [ "${INVENTORY_CONTAINER_LISTS[1]}" = "initContainers" ]
    [ "${INVENTORY_CONTAINER_NAMES[1]}" = "migrate" ]
}

@test "init containers: a reschedule does not lose which list a container is in" {
    local due=$(( $(date -u +%s) + 30 ))
    # Dropping the list here would change the fingerprint, and a record that
    # fingerprints differently after a plain reschedule resyncs forever.
    inventory_init
    kubectl_returns "$(deployment_with_init_json ghcr.io/x/y:1.2.3 ghcr.io/x/m:1.4.0)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app "$due"
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "$due" ]
    [ "${INVENTORY_CONTAINER_LISTS[1]}" = "initContainers" ]
}

@test "init containers: a newer tag on an init container is a candidate" {
    kubectl_returns "$(deployment_with_init_json ghcr.io/x/y:1.2.3 ghcr.io/x/m:1.4.0)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0","1.4.0","1.5.0"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"container":"migrate"'* ]]
    [[ "$output" == *'"candidate":"1.5.0"'* ]]
}

@test "init containers: the update is written to initContainers" {
    kubectl_returns "$(deployment_with_init_json ghcr.io/x/y:1.2.3 ghcr.io/x/m:1.4.0)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0","1.4.0","1.5.0"]}'
SH
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMP_DIR/kubectl.calls"
case "$1" in
    patch|apply) exit 0 ;;
esac
cat <<'JSON'
{"items":[{"metadata":{"namespace":"default","name":"app","annotations":{"keelson.pro/policy":"minor","keelson.pro/initContainers":"true"}},"spec":{"template":{"spec":{"initContainers":[{"name":"migrate","image":"ghcr.io/x/m:1.4.0"}],"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}]}
JSON
SH
    scan_run 1 2>/dev/null
    grep -q '"initContainers":\[{"name":"migrate","image":"ghcr.io/x/m:1.5.0"}\]' "$TMP_DIR/kubectl.calls"
    grep -q '"containers":\[{"name":"main","image":"ghcr.io/x/y:1.5.0"}\]' "$TMP_DIR/kubectl.calls"
}

@test "init containers: per-container annotations address them by name" {
    kubectl_returns "$(cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "namespace": "default",
        "name": "app",
        "annotations": {
          "keelson.pro/policy": "minor",
          "keelson.pro/initContainers": "true",
          "keelson.pro/policy.migrate": "never"
        }
      },
      "spec": {
        "template": {
          "spec": {
            "initContainers": [{"name": "migrate", "image": "ghcr.io/x/m:1.4.0"}],
            "containers": [{"name": "main", "image": "ghcr.io/x/y:1.2.3"}]
          }
        }
      }
    }
  ]
}
JSON
)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0","1.4.0","1.5.0"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"container":"migrate"'*'"reason":"policy-never"'* ]]
    [[ "$output" == *'"container":"main"'*'"candidate":"1.5.0"'* ]]
}

# --- the CronJob trigger belongs to the poll, not to a cache refresh ---
#
# The always-once rule fires on "no prior triggered-job recorded". Every
# cache-refresh path runs in its own child with its own copy of the ledger,
# so evaluating the trigger in more than one of them means two children can
# both read "never triggered" and both create a Job.

@test "cronjob trigger: a cache-only pass does not create a Job" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true true)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    inventory_init
    # poll-all=0 is what the controller's reconcile scan, full refresh and
    # queued re-read all use.
    KEELSON_WATCHED_KINDS=CronJob scan_run 1 0 2>/dev/null
    ! grep -q "create job" "$TMP_DIR/kubectl.log"
}

@test "cronjob trigger: a queued re-read does not create a Job" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true true)"
    inventory_init
    queue_init
    queue_enqueue CronJob default cron
    KEELSON_WATCHED_KINDS=CronJob scan_refresh_queued 1 2>/dev/null
    ! grep -q "create job" "$TMP_DIR/kubectl.log"
}

@test "cronjob trigger: the polling pass still creates one" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true true)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    KEELSON_WATCHED_KINDS=CronJob scan_run 1 2>/dev/null
    grep -q "create job" "$TMP_DIR/kubectl.log"
}

@test "cronjob trigger: the due-poll is what fires it in the controller" {
    # The controller's reconcile scan, full refresh and queued re-read all
    # run cache-only, so this is the only path left that can trigger a Job.
    # If it stops doing so, the feature is silently dead.
    inventory_init
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true true)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    KEELSON_WATCHED_KINDS=CronJob scan_run 0 0 2>/dev/null
    : > "$TMP_DIR/kubectl.log"
    KEELSON_WATCHED_KINDS=CronJob scan_poll_due 1 "$LATE" 2>/dev/null
    grep -q "create job" "$TMP_DIR/kubectl.log"
    grep -q -- "--from=cronjob/cron" "$TMP_DIR/kubectl.log"
}

# --- who counts as Keelson managed ---
#
# policy is the switch. A workload with only poll-schedule or match-tag has
# configured nothing that acts, and counting it would hide that from whoever
# made the mistake.

@test "managed: a workload-wide policy counts" {
    run scan_is_keelson_managed 'keelson.pro/policy=minor'
    [ "$status" -eq 0 ]
}

@test "managed: a per-container policy counts" {
    run scan_is_keelson_managed 'keelson.pro/policy.web=major'
    [ "$status" -eq 0 ]
}

@test "managed: other Keelson annotations alone do not count" {
    run scan_is_keelson_managed "$(printf 'keelson.pro/poll-schedule=5m\nkeelson.pro/match-tag=^1\\.')"
    [ "$status" -eq 1 ]
}

@test "managed: no annotations at all does not count" {
    run scan_is_keelson_managed ''
    [ "$status" -eq 1 ]
}

@test "managed: a keel policy does not count under config-mode keelson" {
    KEELSON_CONFIG_MODE=keelson run scan_is_keelson_managed 'keel.sh/policy=minor'
    [ "$status" -eq 1 ]
}

@test "managed: a keel policy counts under config-mode keel" {
    KEELSON_CONFIG_MODE=keel run scan_is_keelson_managed 'keel.sh/policy=minor'
    [ "$status" -eq 0 ]
}

@test "managed: either prefix counts under config-mode both" {
    KEELSON_CONFIG_MODE=both run scan_is_keelson_managed 'keel.sh/policy=minor'
    [ "$status" -eq 0 ]
}

@test "refresh: the rebuilt line carries the managed ratio" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    run emit scan_refresh_kind 0 Deployment
    [ "$status" -eq 0 ]
    [[ "$output" == *'"workloads":"1"'* ]]
    [[ "$output" == *'"managed":"1"'* ]]
    [[ "$output" == *"Rebuilt the cache for Deployment: 1 of 1 are Keelson managed."* ]]
}

@test "refresh: an unannotated workload is cached but not counted" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3)"
    run emit scan_refresh_kind 0 Deployment
    [[ "$output" == *"Rebuilt the cache for Deployment: 0 of 1 are Keelson managed."* ]]
}

# --- the boot listing of what Keelson will act on ---

@test "managed list: says nothing and fails while the cache is empty" {
    inventory_init
    run scan_log_managed_workloads
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "managed list: the header carries the ratio" {
    inventory_init
    inventory_put Deployment default web 1700 60 "" default '[]' \
        'keelson.pro/policy=minor' 'containers main=a:1'
    inventory_put Deployment default other 1700 60 "" default '[]' \
        '' 'containers main=b:1'
    run emit scan_log_managed_workloads
    [ "$status" -eq 0 ]
    [[ "$output" == *"Keelson is managing 1 of 2 cached workloads:"* ]]
}

@test "managed list: groups by namespace, kind then name inside" {
    inventory_init
    inventory_put Deployment run-platform web 1700 60 "" default '[]' \
        'keelson.pro/policy=minor' 'containers main=a:1'
    inventory_put CronJob run-platform nightly 1700 60 "" default '[]' \
        'keelson.pro/policy=minor' 'containers main=a:1'
    inventory_put DaemonSet kube-system shipper 1700 60 "" default '[]' \
        'keelson.pro/policy=minor' 'containers main=a:1'
    run emit scan_log_managed_workloads
    local plain
    plain=$(printf '%s\n' "$output" | grep -o '"msg":"[^"]*"' | sed 's/"msg":"//; s/"$//')
    [ "$(printf '%s\n' "$plain" | sed -n '2p')" = "  kube-system" ]
    [ "$(printf '%s\n' "$plain" | sed -n '3p')" = "    DaemonSet   shipper" ]
    [ "$(printf '%s\n' "$plain" | sed -n '4p')" = "  run-platform" ]
    [ "$(printf '%s\n' "$plain" | sed -n '5p')" = "    CronJob     nightly" ]
    [ "$(printf '%s\n' "$plain" | sed -n '6p')" = "    Deployment  web" ]
}

@test "managed list: a namespace header appears once for its workloads" {
    inventory_init
    inventory_put Deployment ns1 a 1700 60 "" default '[]' \
        'keelson.pro/policy=minor' 'containers main=a:1'
    inventory_put Deployment ns1 b 1700 60 "" default '[]' \
        'keelson.pro/policy=minor' 'containers main=a:1'
    run emit scan_log_managed_workloads
    [ "$(printf '%s\n' "$output" | grep -c '"event":"managed-namespace"')" = "1" ]
    [ "$(printf '%s\n' "$output" | grep -c '"event":"managed-workload"')" = "2" ]
}

@test "managed list: nothing annotated still reports the ratio" {
    inventory_init
    inventory_put Deployment default web 1700 60 "" default '[]' \
        '' 'containers main=a:1'
    run emit scan_log_managed_workloads
    [ "$status" -eq 0 ]
    [[ "$output" == *"Keelson is managing 0 of 1 cached workloads:"* ]]
    [[ "$output" != *'"event":"managed-workload"'* ]]
}

# --- our own update must not read back as someone else's change ---

@test "own update: the applied image is recorded against the cache" {
    inventory_init
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    scan_run 1 2>/dev/null
    inventory_get Deployment default app
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io/x/y:1.3.0" ]
}

@test "own update: the re-read that follows it does not resync" {
    local due=$(( $(date -u +%s) + 30 ))
    # Keelson's patch fires a watch event like anyone else's. Without the
    # record being updated, the re-read reports a change and asks the registry
    # a question it has just answered.
    inventory_init
    queue_init
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    scan_run 1 2>/dev/null
    inventory_set_next_due Deployment default app "$due"

    # The cluster now serves what we just applied, as it would to the re-read.
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.3.0 minor)"
    queue_enqueue Deployment default app
    run emit scan_refresh_queued 1
    [[ "$output" != *"scan-resync"* ]]
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "$due" ]
}

# --- annotations Keelson does not read must not drive its decisions ---

deployment_with_foreign_annotation() {
    local image=$1 policy=$2 revision=$3
    cat <<JSON
{
  "items": [
    {
      "metadata": {
        "namespace": "default",
        "name": "app",
        "annotations": {
          "keelson.pro/policy": "$policy",
          "deployment.kubernetes.io/revision": "$revision"
        }
      },
      "spec": {
        "template": {
          "spec": {
            "containers": [{"name": "main", "image": "$image"}]
          }
        }
      }
    }
  ]
}
JSON
}

@test "resync: someone else's annotation changing is not a decision change" {
    local due=$(( $(date -u +%s) + 30 ))
    # Patching a Deployment makes its own controller bump
    # deployment.kubernetes.io/revision, so Keelson's own update read back as
    # a change and asked the registry a question it had just answered.
    inventory_init
    kubectl_returns "$(deployment_with_foreign_annotation ghcr.io/x/y:1.2.3 minor 1)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app "$due"

    kubectl_returns "$(deployment_with_foreign_annotation ghcr.io/x/y:1.2.3 minor 2)"
    run emit scan_run 0 0
    [[ "$output" != *"scan-resync"* ]]
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "$due" ]
}

@test "resync: a Keelson annotation changing still is one" {
    local due=$(( $(date -u +%s) + 30 ))
    inventory_init
    kubectl_returns "$(deployment_with_foreign_annotation ghcr.io/x/y:1.2.3 minor 1)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app "$due"

    kubectl_returns "$(deployment_with_foreign_annotation ghcr.io/x/y:1.2.3 major 1)"
    run emit scan_run 0 0
    [[ "$output" == *"scan-resync"* ]]
}

@test "poll: a poll with nothing to update talks to kubectl not at all" {
    # managedFields are only ever read when an update is about to be written,
    # and almost every poll finds no newer tag. Fetching them up front is one
    # kubectl process per due workload per poll, thrown away.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    scan_run 0 0 2>/dev/null

    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMP_DIR/kubectl.calls"
printf '{"items":[]}'
SH
    scan_poll_due 0 "$LATE" 2>/dev/null
    [ ! -f "$TMP_DIR/kubectl.calls" ]
}

@test "match-mode: regex is honoured, not silently treated as a glob" {
    # match_mode defaults to glob when empty, so a value that fails to arrive
    # is indistinguishable from one that was never set.
    kubectl_returns "$(cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "namespace": "default",
        "name": "app",
        "annotations": {
          "keelson.pro/policy": "minor",
          "keelson.pro/match-tag": "^1",
          "keelson.pro/match-mode": "regex"
        }
      },
      "spec": {
        "template": {
          "spec": {"containers": [{"name": "main", "image": "ghcr.io/x/y:1.2.3"}]}
        }
      }
    }
  ]
}
JSON
)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.4.0","2.0.0"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"candidate":"1.4.0"'* ]]
}

@test "match-tag: a backslash in the pattern survives the flattener" {
    # yq's props output escapes backslashes in values as well as keys, and
    # only the key side was ever unescaped. An escaped dot, which is how
    # every real regex spells one, arrived doubled and matched nothing: the
    # workload silently never updated and nothing said why.
    kubectl_returns "$(cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "namespace": "default",
        "name": "app",
        "annotations": {
          "keelson.pro/policy": "minor",
          "keelson.pro/match-tag": "^1\\.",
          "keelson.pro/match-mode": "regex"
        }
      },
      "spec": {
        "template": {
          "spec": {"containers": [{"name": "main", "image": "ghcr.io/x/y:1.2.3"}]}
        }
      }
    }
  ]
}
JSON
)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.4.0","2.0.0"]}'
SH
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"candidate":"1.4.0"'* ]]
}

# --- scan_extract_workload ---
#
# The extraction runs once per workload per scan and is the bulk of what a
# pass costs, so it is the thing most likely to be rewritten for speed. These
# pin what it produces, field by field, so a rewrite has to answer for each.

EXTRACT_LIST='{"items":[
 {"metadata":{"namespace":"prod","name":"web",
   "annotations":{"keelson.pro/policy":"minor","keelson.pro/match-tag":"^1\\.",
                  "deployment.kubernetes.io/revision":"7"},
   "managedFields":[{"manager":"argocd","operation":"Apply"}]},
  "spec":{"template":{"spec":{
    "serviceAccountName":"deployer",
    "imagePullSecrets":[{"name":"regcred"}],
    "initContainers":[{"name":"migrate","image":"ghcr.io/acme/migrate:2.0.0"}],
    "containers":[{"name":"web","image":"ghcr.io/acme/web:1.2.3"},
                  {"name":"side","image":"ghcr.io/acme/side:0.1.0"}]}}}},
 {"metadata":{"namespace":"other","name":"bare"},
  "spec":{"template":{"spec":{
    "containers":[{"name":"only","image":"nginx:1.0"}]}}}}
]}'

@test "extract: namespace and name come from the indexed item" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [ "$SCAN_WL_NS" = "prod" ]
    [ "$SCAN_WL_NAME" = "web" ]
}

@test "extract: the index selects the workload" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 1
    [ "$SCAN_WL_NS" = "other" ]
    [ "$SCAN_WL_NAME" = "bare" ]
}

@test "extract: names come out bare, not quoted" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    case "$SCAN_WL_NAME" in *'"'*) return 1 ;; esac
    case "$SCAN_WL_NS" in *'"'*) return 1 ;; esac
    case "$SCAN_WL_SA_NAME" in *'"'*) return 1 ;; esac
}

@test "extract: only keelson and keel annotations survive" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [[ "$SCAN_WL_ANNOTATIONS" == *"keelson.pro/policy=minor"* ]]
    [[ "$SCAN_WL_ANNOTATIONS" != *"deployment.kubernetes.io/revision"* ]]
}

@test "extract: a backslash in an annotation value is not doubled" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [[ "$SCAN_WL_ANNOTATIONS" == *'keelson.pro/match-tag=^1\.'* ]]
}

@test "extract: a workload with no annotations yields nothing" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 1
    [ -z "$SCAN_WL_ANNOTATIONS" ]
}

@test "extract: image pull secrets stay on one line for the cache record" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [ "$(printf '%s\n' "$SCAN_WL_IPS_JSON" | wc -l | tr -d ' ')" = "1" ]
    [[ "$SCAN_WL_IPS_JSON" == *"regcred"* ]]
}

@test "extract: absent image pull secrets are an empty array" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 1
    [ "$SCAN_WL_IPS_JSON" = "[]" ]
}

@test "extract: service account is read when set" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [ "$SCAN_WL_SA_NAME" = "deployer" ]
}

@test "extract: an unset service account defaults to 'default'" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 1
    [ "$SCAN_WL_SA_NAME" = "default" ]
}

@test "extract: managed fields come through as JSON" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [ "$(printf '%s' "$SCAN_WL_MANAGED_FIELDS" | yq -p=json -o=y '.[0].manager')" = "argocd" ]
}

@test "extract: absent managed fields are an empty array" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 1
    [ "$(printf '%s' "$SCAN_WL_MANAGED_FIELDS" | yq -p=json -o=y 'length')" = "0" ]
}

@test "extract: suspend is only read for CronJob" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [ -z "$SCAN_WL_SUSPEND" ]
}

CRONJOB_LIST='{"items":[
 {"metadata":{"namespace":"prod","name":"nightly"},
  "spec":{"suspend":true,"jobTemplate":{"spec":{"template":{"spec":{
    "containers":[{"name":"job","image":"ghcr.io/acme/job:3.0.0"}]}}}}}},
 {"metadata":{"namespace":"prod","name":"hourly"},
  "spec":{"jobTemplate":{"spec":{"template":{"spec":{
    "containers":[{"name":"job","image":"ghcr.io/acme/job:3.0.0"}]}}}}}}
]}'

@test "extract: CronJob suspend is read" {
    scan_extract_workload "$CRONJOB_LIST" CronJob 0
    [ "$SCAN_WL_SUSPEND" = "true" ]
}

@test "extract: an unset CronJob suspend reads false, not empty" {
    scan_extract_workload "$CRONJOB_LIST" CronJob 1
    [ "$SCAN_WL_SUSPEND" = "false" ]
}

# --- container pairs ---
#
# "<list> <name>=<image>" is what the cache record stores and what the poll
# loop reads back, so the format is a contract between the two.

@test "pairs: every container is listed with its list, name and image" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [[ "$SCAN_WL_CONTAINER_PAIRS" == *"containers web=ghcr.io/acme/web:1.2.3"* ]]
    [[ "$SCAN_WL_CONTAINER_PAIRS" == *"containers side=ghcr.io/acme/side:0.1.0"* ]]
}

@test "pairs: init containers carry initContainers as their list" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [[ "$SCAN_WL_CONTAINER_PAIRS" == *"initContainers migrate=ghcr.io/acme/migrate:2.0.0"* ]]
}

@test "pairs: containers come before init containers" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [ "${SCAN_WL_CONTAINER_PAIRS%%$'\n'*}" = "containers web=ghcr.io/acme/web:1.2.3" ]
}

@test "pairs: one line per container, no blanks" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [ "$(printf '%s\n' "$SCAN_WL_CONTAINER_PAIRS" | wc -l | tr -d ' ')" = "3" ]
    ! printf '%s\n' "$SCAN_WL_CONTAINER_PAIRS" | grep -q '^$'
}

@test "pairs: a workload with no init containers lists only its containers" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 1
    [ "$SCAN_WL_CONTAINER_PAIRS" = "containers only=nginx:1.0" ]
}

@test "pairs: a digest-pinned image keeps its at-sign intact" {
    local list='{"items":[{"metadata":{"namespace":"n","name":"w"},
      "spec":{"template":{"spec":{"containers":[
        {"name":"c","image":"ghcr.io/acme/w@sha256:abc123"}]}}}}]}'
    scan_extract_workload "$list" Deployment 0
    [ "$SCAN_WL_CONTAINER_PAIRS" = "containers c=ghcr.io/acme/w@sha256:abc123" ]
}

@test "pairs: a registry port survives the colon" {
    local list='{"items":[{"metadata":{"namespace":"n","name":"w"},
      "spec":{"template":{"spec":{"containers":[
        {"name":"c","image":"reg.local:5000/acme/w:1.0"}]}}}}]}'
    scan_extract_workload "$list" Deployment 0
    [ "$SCAN_WL_CONTAINER_PAIRS" = "containers c=reg.local:5000/acme/w:1.0" ]
}

@test "pairs: a workload with no containers at all yields nothing" {
    local list='{"items":[{"metadata":{"namespace":"n","name":"w"},
      "spec":{"template":{"spec":{}}}}]}'
    scan_extract_workload "$list" Deployment 0
    [ -z "$SCAN_WL_CONTAINER_PAIRS" ]
}

@test "pairs: CronJob containers read through jobTemplate" {
    scan_extract_workload "$CRONJOB_LIST" CronJob 0
    [ "$SCAN_WL_CONTAINER_PAIRS" = "containers job=ghcr.io/acme/job:3.0.0" ]
}

@test "pairs: annotations after the sentinel do not swallow the pairs" {
    scan_extract_workload "$EXTRACT_LIST" Deployment 0
    [[ "$SCAN_WL_ANNOTATIONS" != *"containers "* ]]
    [[ "$SCAN_WL_CONTAINER_PAIRS" != *"keelson.pro/"* ]]
}

# --- an implausible next-due is corrupt, not a schedule ---
#
# No writer can put next-due beyond now + interval. Anything further out is
# corrupt, and nothing corrects it on its own: inventory_due never selects a
# far-future entry, so the workload is silently never polled again, across
# restarts. Seen in the wild with 49 of 50 entries sat 69 days out.

@test "clamp: a far-future cached next-due is recomputed" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app 4242424242
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" -le "$(( $(date -u +%s) + 60 ))" ]
}

@test "clamp: correcting it writes nothing to the ledger" {
    # The ledger carries no next-due at all now, so a correction is a cache
    # repair and nothing else.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app 4242424242
    STATE_DIRTY=()
    scan_run 0 0 2>/dev/null
    [ "${#STATE_DIRTY[@]}" -eq 0 ]
}

@test "clamp: it warns, because it should never happen" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app 4242424242
    run emit scan_run 0 0
    [[ "$output" == *"next-due-implausible"* ]]
}

@test "clamp: exactly one interval out is left alone" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    local due=$(( $(date -u +%s) + 60 ))
    inventory_set_next_due Deployment default app "$due"
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "$due" ]
}

@test "clamp: a non-numeric next-due is corrupt too" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app "not-a-number"
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" -le "$(( $(date -u +%s) + 60 ))" ]
}

# --- the ledger records whether Keelson is acting on a workload ---
#
# A workload carrying no Keelson annotation at all: catalogued, not acted on.
deployment_no_annotations() {
    cat <<JSON
{
  "items": [
    {
      "metadata": { "namespace": "default", "name": "app" },
      "spec": { "template": { "spec": { "containers": [
        { "name": "main", "image": "$1" }
      ] } } }
    }
  ]
}
JSON
}

#
# managed=false on a workload someone annotated is the interesting line: a
# keel.sh/ policy under config-mode=keelson, or a match-tag with no policy,
# are both silent misconfigurations otherwise.

@test "record: an annotated workload is recorded as managed" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    [ "$(state_get w--Deployment--default--app managed)" = "true" ]
}

@test "record: an unannotated workload is recorded as not managed" {
    inventory_init
    kubectl_returns "$(deployment_no_annotations ghcr.io/x/y:1.0)"
    scan_run 0 0 2>/dev/null
    [ "$(state_get w--Deployment--default--app managed)" = "false" ]
}

@test "record: annotating a cached workload flips it" {
    inventory_init
    kubectl_returns "$(deployment_no_annotations ghcr.io/x/y:1.0)"
    scan_run 0 0 2>/dev/null
    [ "$(state_get w--Deployment--default--app managed)" = "false" ]

    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    [ "$(state_get w--Deployment--default--app managed)" = "true" ]
}

@test "record: an unchanged workload writes nothing" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    STATE_DIRTY=()
    scan_run 0 0 2>/dev/null
    [ "${#STATE_DIRTY[@]}" -eq 0 ]
}

@test "record: first-seen survives a later pass unchanged" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    local first
    first=$(state_get w--Deployment--default--app first-seen)
    [ -n "$first" ]
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:2.0 patch)"
    scan_run 0 0 2>/dev/null
    [ "$(state_get w--Deployment--default--app first-seen)" = "$first" ]
}

# --- the trigger record is the image set, not a timestamp ---
#
# A CronJob can carry several containers. Recording one image left the others
# undefined: updating container A and then container B compared against
# whichever happened to have been written.

cronjob_two_containers() {
    cat <<JSON
{
  "items": [
    {
      "metadata": { "namespace": "ops", "name": "reindex",
        "annotations": { "keelson.pro/policy": "minor",
                         "keelson.pro/trigger-job-on-update": "true" } },
      "spec": { "suspend": true, "jobTemplate": { "spec": { "template": { "spec": {
        "initContainers": [ { "name": "wait-db", "image": "$2" } ],
        "containers": [ { "name": "reindex", "image": "$1" } ]
      } } } } }
    }
  ]
}
JSON
}

@test "trigger record: every container's image is recorded, init included" {
    inventory_init
    kubectl_returns "$(cronjob_two_containers ghcr.io/x/re:1.0 ghcr.io/x/wait:2.0)"
    KEELSON_WATCHED_KINDS=CronJob scan_run 1 1 2>/dev/null || true
    [ "$(state_get_trigger_field CronJob ops reindex 'containers/reindex')" = "ghcr.io/x/re:1.0" ]
    [ "$(state_get_trigger_field CronJob ops reindex 'initContainers/wait-db')" = "ghcr.io/x/wait:2.0" ]
}

@test "trigger record: triggered-at is written, triggered-job is not" {
    inventory_init
    kubectl_returns "$(cronjob_two_containers ghcr.io/x/re:1.0 ghcr.io/x/wait:2.0)"
    KEELSON_WATCHED_KINDS=CronJob scan_run 1 1 2>/dev/null || true
    [ -n "$(state_get_trigger_field CronJob ops reindex triggered-at)" ]
    [ -z "$(state_get_trigger_field CronJob ops reindex triggered-job)" ]
}

@test "trigger: an unchanged image set does not re-fire" {
    inventory_init
    kubectl_returns "$(cronjob_two_containers ghcr.io/x/re:1.0 ghcr.io/x/wait:2.0)"
    KEELSON_WATCHED_KINDS=CronJob scan_run 1 1 2>/dev/null || true
    : > "$TMP_DIR/kubectl.log"
    KEELSON_WATCHED_KINDS=CronJob scan_run 1 1 2>/dev/null || true
    ! grep -q "create job" "$TMP_DIR/kubectl.log"
}

@test "trigger: a third party changing the image does not fire" {
    # It moves the baseline the next poll compares against; it is not an event
    # Keelson acts on. Only our own update fires a Job.
    inventory_init
    kubectl_returns "$(cronjob_two_containers ghcr.io/x/re:1.0 ghcr.io/x/wait:2.0)"
    KEELSON_WATCHED_KINDS=CronJob scan_run 1 1 2>/dev/null || true
    : > "$TMP_DIR/kubectl.log"
    kubectl_returns "$(cronjob_two_containers ghcr.io/x/re:9.9 ghcr.io/x/wait:2.0)"
    KEELSON_WATCHED_KINDS=CronJob scan_run 1 1 2>/dev/null || true
    ! grep -q "create job" "$TMP_DIR/kubectl.log"
}

# --- which containers are in scope ---
#
# keel defaults initContainers to false and Keelson tracks them always, so the
# default follows the contract the mode is honouring. monitorContainers is
# keel's regex over container names, empty meaning all.

@test "monitored: init containers are out of scope by default" {
    KEELSON_CONFIG_MODE=keelson
    ! scan_container_monitored 'keelson.pro/policy=minor' initContainers migrate
}

@test "monitored: the default is the same under keel mode" {
    KEELSON_CONFIG_MODE=keel
    ! scan_container_monitored 'keel.sh/policy=minor' initContainers migrate
}

@test "monitored: keel mode still tracks ordinary containers" {
    KEELSON_CONFIG_MODE=keel
    scan_container_monitored 'keel.sh/policy=minor' containers web
}

@test "monitored: keel mode honours an explicit opt-in" {
    KEELSON_CONFIG_MODE=keel
    scan_container_monitored 'keel.sh/policy=minor
keel.sh/initContainers=true' initContainers migrate
}

@test "monitored: keelson mode honours an explicit opt-in" {
    KEELSON_CONFIG_MODE=keelson
    scan_container_monitored 'keelson.pro/policy=minor
keelson.pro/initContainers=true' initContainers migrate
}

@test "monitored: a non-true value leaves them out of scope" {
    KEELSON_CONFIG_MODE=keelson
    ! scan_container_monitored 'keelson.pro/initContainers=yes' initContainers migrate
    ! scan_container_monitored 'keelson.pro/initContainers=' initContainers migrate
}

@test "monitored: an empty monitorContainers means all" {
    KEELSON_CONFIG_MODE=keelson
    scan_container_monitored 'keelson.pro/policy=minor' containers anything
}

@test "monitored: the regex selects by container name" {
    KEELSON_CONFIG_MODE=keelson
    scan_container_monitored 'keelson.pro/monitorContainers=^web$' containers web
    ! scan_container_monitored 'keelson.pro/monitorContainers=^web$' containers sidecar
}

@test "monitored: an unusable regex monitors nothing, and says so" {
    KEELSON_CONFIG_MODE=keelson
    run emit scan_container_monitored 'keelson.pro/monitorContainers=[unclosed' containers web
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a usable regular expression"* ]]
}

@test "monitored: an init container is never polled without an opt-in" {
    inventory_init
    kubectl_returns '{"items":[{"metadata":{"namespace":"default","name":"app",
      "annotations":{"keelson.pro/policy":"minor"}},
      "spec":{"template":{"spec":{
        "initContainers":[{"name":"migrate","image":"ghcr.io/x/init:1.0.0"}],
        "containers":[{"name":"web","image":"ghcr.io/x/y:1.2.3"}]}}}}]}'
    skopeo_counting
    scan_run 0 1 2>/dev/null
    # Only the app container reaches a registry; the init container is skipped
    # before eligibility, so it costs no network call at all.
    [ "$(skopeo_call_count)" = "1" ]
}

@test "monitored: both are polled when init containers are in scope" {
    inventory_init
    kubectl_returns '{"items":[{"metadata":{"namespace":"default","name":"app",
      "annotations":{"keelson.pro/policy":"minor","keelson.pro/initContainers":"true"}},
      "spec":{"template":{"spec":{
        "initContainers":[{"name":"migrate","image":"ghcr.io/x/init:1.0.0"}],
        "containers":[{"name":"web","image":"ghcr.io/x/y:1.2.3"}]}}}}]}'
    skopeo_counting
    scan_run 0 1 2>/dev/null
    [ "$(skopeo_call_count)" = "2" ]
}

@test "monitored: the regex keeps an unmatched container off the network" {
    inventory_init
    kubectl_returns '{"items":[{"metadata":{"namespace":"default","name":"app",
      "annotations":{"keelson.pro/policy":"minor","keelson.pro/monitorContainers":"^web$"}},
      "spec":{"template":{"spec":{
        "containers":[{"name":"web","image":"ghcr.io/x/y:1.2.3"},
                      {"name":"sidecar","image":"ghcr.io/x/s:1.2.3"}]}}}}]}'
    skopeo_counting
    scan_run 0 1 2>/dev/null
    [ "$(skopeo_call_count)" = "1" ]
}
