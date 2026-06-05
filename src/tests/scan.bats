#!/usr/bin/env bats

# Tests for lib/scan.bash orchestration. Network tooling (kubectl, skopeo) is
# provided via PATH-prepended shim scripts in $TMP_BIN. Real yq is used.
# To keep cases focused we set KEELSON_WATCHED_KINDS to a single kind per test.

setup() {
    TMP_DIR=$(mktemp -d)
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    export PATH

    KEELSON_WATCHED_KINDS=Deployment
    KEELSON_SCOPE=cluster
    KEELSON_CONFIG_MODE=keelson
    KEELSON_RESPECT_SA_PULL_SECRETS=false
    KEELSON_REGISTRIES_FILE="$TMP_DIR/registries.yaml"
    rm -f "$KEELSON_REGISTRIES_FILE"
    export KEELSON_WATCHED_KINDS KEELSON_SCOPE KEELSON_CONFIG_MODE \
        KEELSON_RESPECT_SA_PULL_SECRETS KEELSON_REGISTRIES_FILE

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
    # shellcheck source=../scripts/lib/scan.bash
    source "$SCRIPT_DIR/lib/scan.bash"
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
    [[ "$output" == *"resources=0"* ]]
    [[ "$output" == *"would-update=0"* ]]
    [[ "$output" == *"no-change=0"* ]]
    [[ "$output" == *"skip=0"* ]]
}

# --- skip reasons surface as skip-not-eligible ---

@test "scan_run: container with no policy annotation → skip-not-eligible" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3)"
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"skip-not-eligible"* ]]
    [[ "$output" == *"reason=no-policy-annotation"* ]]
    [[ "$output" == *"skip=1"* ]]
}

@test "scan_run: container with policy=never → skip-not-eligible policy-never" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:1.2.3 never)"
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"reason=policy-never"* ]]
}

@test "scan_run: digest-pinned image → skip tag-is-digest-pinned" {
    kubectl_returns "$(single_deployment_json 'ghcr.io/x/y@sha256:deadbeef' major)"
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"reason=tag-is-digest-pinned"* ]]
}

@test "scan_run: latest tag → skip tag-is-latest" {
    kubectl_returns "$(single_deployment_json ghcr.io/x/y:latest minor)"
    run emit scan_run 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"reason=tag-is-latest"* ]]
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
    [[ "$output" == *"no-change=1"* ]]
    [[ "$output" == *"would-update=0"* ]]
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
    [[ "$output" == *"would-update=1"* ]]
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
    [[ "$output" == *"candidate=1.2.4"* ]]
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
    [[ "$output" == *"candidate=1.4.0"* ]]
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
    [[ "$output" == *"error=1"* ]]
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
    [[ "$output" == *"error=1"* ]]
}

# --- scan-start emits the configured mode ---

@test "scan_run: scan-start mode is dry-run when apply=0" {
    kubectl_returns '{"items": []}'
    run emit scan_run 0
    [[ "$output" == *"scan-start mode=dry-run"* ]]
}

@test "scan_run: scan-start mode is apply when apply=1" {
    kubectl_returns '{"items": []}'
    run emit scan_run 1
    [[ "$output" == *"scan-start mode=apply"* ]]
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

@test "scan_run apply: newer candidate triggers update-applied + updated counter" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"update-applied"* ]]
    [[ "$output" == *"image=ghcr.io/x/y:1.3.0"* ]]
    [[ "$output" == *"updated=1"* ]]
    [[ "$output" == *"would-update=0"* ]]
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
    [[ "$output" == *"error=1"* ]]
    [[ "$output" == *"updated=0"* ]]
}

@test "scan_run apply: no newer candidate logs no-change (not dry-run-no-change)" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *" no-change "* ]]
    [[ "$output" != *"dry-run-no-change"* ]]
    [[ "$output" == *"no-change=1"* ]]
}

@test "scan_run apply: CronJob with trigger-job-on-update=true creates a Job" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3","1.3.0"]}'
SH
    KEELSON_WATCHED_KINDS=CronJob run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"update-applied"* ]]
    [[ "$output" == *"cronjob-job-triggered"* ]]
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
    [[ "$output" == *"update-applied"* ]]
    [[ "$output" != *"cronjob-job-triggered"* ]]
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
    [[ "$output" != *"cronjob-job-triggered"* ]]
    ! grep -q "create job" "$TMP_DIR/kubectl.log" 2>/dev/null || false
}

@test "scan_run apply: CronJob trigger=true + suspend=true + no update -> always-once triggers Job" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true true)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    KEELSON_WATCHED_KINDS=CronJob run emit scan_run 1
    [ "$status" -eq 0 ]
    [[ "$output" != *"update-applied"* ]]
    [[ "$output" == *"cronjob-job-triggered"* ]]
    grep -q "create job" "$TMP_DIR/kubectl.log"
}

# --- log dedupe (state cache persists across scan_run in same shell) ---
#
# bats `run` runs the command in a subshell, which would isolate the
# in-memory cache. These tests call scan_run directly so the cache lives.

@test "scan_run apply: repeat skip with same reason emits only on first scan" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    scan_run 1 2>"$TMP_DIR/s1.log"
    grep -q "skip-not-eligible" "$TMP_DIR/s1.log"

    scan_run 1 2>"$TMP_DIR/s2.log"
    ! grep -q "skip-not-eligible" "$TMP_DIR/s2.log"
}

@test "scan_run apply: no-change clears skip state, so a later skip re-emits" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    scan_run 1 2>"$TMP_DIR/s1.log"
    grep -q "skip-not-eligible" "$TMP_DIR/s1.log"

    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    scan_run 1 2>"$TMP_DIR/s2.log"
    grep -q " no-change " "$TMP_DIR/s2.log"

    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3)"
    scan_run 1 2>"$TMP_DIR/s3.log"
    grep -q "skip-not-eligible" "$TMP_DIR/s3.log"
}

@test "scan_run apply: registry-list-tags-failed deduped across consecutive scans" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3 minor)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
exit 1
SH
    scan_run 1 2>"$TMP_DIR/s1.log"
    grep -q "registry-list-tags-failed" "$TMP_DIR/s1.log"

    scan_run 1 2>"$TMP_DIR/s2.log"
    ! grep -q "registry-list-tags-failed" "$TMP_DIR/s2.log"
}

@test "scan_run apply: dry-run does NOT mutate state (skip re-emits on next dry-run)" {
    kubectl_apply_shim "$(single_deployment_json ghcr.io/x/y:1.2.3)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    scan_run 0 2>"$TMP_DIR/s1.log"
    grep -q "skip-not-eligible" "$TMP_DIR/s1.log"

    scan_run 0 2>"$TMP_DIR/s2.log"
    grep -q "skip-not-eligible" "$TMP_DIR/s2.log"
}

@test "scan_run apply: CronJob trigger requires-suspend deduped across scans" {
    kubectl_apply_shim "$(single_cronjob_json ghcr.io/x/y:1.2.3 minor true false)"
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
printf '{"Tags":["1.2.3"]}'
SH
    KEELSON_WATCHED_KINDS=CronJob
    scan_run 1 2>"$TMP_DIR/s1.log"
    grep -q "cronjob-trigger-requires-suspend" "$TMP_DIR/s1.log"

    scan_run 1 2>"$TMP_DIR/s2.log"
    ! grep -q "cronjob-trigger-requires-suspend" "$TMP_DIR/s2.log"
}
