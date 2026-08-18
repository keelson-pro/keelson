#!/usr/bin/env bats

# Tests for lib/scan.bash orchestration. Network tooling (kubectl, skopeo) is
# provided via PATH-prepended shim scripts in $TMP_BIN. Real yq is used.
# To keep cases focused we set KEELSON_WATCHED_KINDS to a single kind per test.

setup() {
    TMP_DIR=$(mktemp -d)
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
    KEELSON_LOG_LEVEL=debug
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
    # shellcheck source=../scripts/lib/scan.bash
    source "$SCRIPT_DIR/lib/scan.bash"

    KEELSON_INVENTORY_DIR="$TMP_DIR/inventory"
    KEELSON_RECONCILE_INTERVAL=60
    export KEELSON_RECONCILE_INTERVAL
}

teardown() {
    rm -rf "$TMP_DIR"
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
    # keelson-boot-scan run outside a controller pod has no inventory to keep.
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
    # Otherwise a CronJob's trigger entry outlives the CronJob and the state
    # ConfigMap only ever grows.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 2>/dev/null

    kubectl_returns '{"items": []}'
    scan_run 0 2>/dev/null
    [ -n "${STATE_DELETED[j--Deployment--default--app]:-}" ]
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
    [ "$INVENTORY_NEXT_DUE" -gt "$(( $(date -u +%s) + 1000 ))" ]

    kubectl_returns "$(deployment_with_schedule ghcr.io/x/y:2.0 1d)"
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" -le "$(date -u +%s)" ]
}

@test "resync: an annotation change makes the workload due now" {
    # The watch stream cannot see these at all, so only the scan can.
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app 4242424242

    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 patch)"
    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" -le "$(date -u +%s)" ]
}

@test "resync: an unchanged workload keeps its place in the cycle" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    inventory_set_next_due Deployment default app 4242424242

    scan_run 0 0 2>/dev/null
    inventory_get Deployment default app
    [ "$INVENTORY_NEXT_DUE" = "4242424242" ]
}

@test "resync: it says so, so an operator knows the watch missed something" {
    inventory_init
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.0 minor)"
    scan_run 0 0 2>/dev/null
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:2.0 minor)"
    run emit scan_run 0 0
    [[ "$output" == *"scan-resync"* ]]
}
