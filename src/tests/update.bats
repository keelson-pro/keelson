#!/usr/bin/env bats

# Tests for lib/update.bash. kubectl is shimmed via $TMP_BIN on PATH.

setup() {
    TMP_DIR=$(mktemp -d)
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    KEELSON_CONFIG_MODE=keelson
    KEELSON_FIELD_MANAGER_STRATEGY_OWNED=mimic
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=patch
    export PATH TMP_DIR KEELSON_CONFIG_MODE \
        KEELSON_FIELD_MANAGER_STRATEGY_OWNED KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/annotations.bash
    source "$SCRIPT_DIR/lib/annotations.bash"
    # shellcheck source=../scripts/lib/managedfields.bash
    source "$SCRIPT_DIR/lib/managedfields.bash"
    # shellcheck source=../scripts/lib/update.bash
    source "$SCRIPT_DIR/lib/update.bash"
}

teardown() {
    rm -rf "$TMP_DIR"
}

# Logs go to stderr; merge so `run` sees them.
emit() { "$@" 2>&1; }

install_shim() {
    local name=$1
    cat > "$TMP_BIN/$name"
    chmod +x "$TMP_BIN/$name"
}

# managedFields fixtures.
mf_apply_argocd() {
    printf '%s' '[{"manager":"argocd-application-controller","operation":"Apply","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]'
}
mf_update_kubectl() {
    printf '%s' '[{"manager":"kubectl-client-side-apply","operation":"Update","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]'
}

# --- update_patch_json ---

@test "patch_json: Deployment shape" {
    run update_patch_json Deployment containers main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [ "$output" = '{"spec":{"template":{"spec":{"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.4"}]}}}}' ]
}

@test "patch_json: StatefulSet uses same template path" {
    run update_patch_json StatefulSet containers web ghcr.io/x/y:2.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"template":{"spec":{"containers":[{"name":"web"'* ]]
}

@test "patch_json: CronJob nests under jobTemplate" {
    run update_patch_json CronJob containers worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [ "$output" = '{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"worker","image":"ghcr.io/x/y:1.2.4"}]}}}}}}' ]
}

@test "patch_json: unknown kind returns non-zero" {
    run update_patch_json Pod containers main ghcr.io/x/y:1.0.0
    [ "$status" -ne 0 ]
}

@test "patch_json: an init container patches initContainers, not containers" {
    run update_patch_json Deployment initContainers migrate ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [ "$output" = '{"spec":{"template":{"spec":{"initContainers":[{"name":"migrate","image":"ghcr.io/x/y:1.2.4"}]}}}}' ]
}

@test "patch_json: CronJob init container nests under jobTemplate too" {
    run update_patch_json CronJob initContainers migrate ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [ "$output" = '{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"initContainers":[{"name":"migrate","image":"ghcr.io/x/y:1.2.4"}]}}}}}}' ]
}

@test "minimal_manifest: an init container claims initContainers" {
    run update_minimal_manifest Deployment default app initContainers migrate ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"initContainers:"* ]]
    [[ "$output" != *$'\n'"      containers:"* ]]
}

# --- update_apply: default strategy dispatch ---

@test "update_apply: success logs the sentence and returns 0" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
exit 0
SH
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deployment 'app' in 'default' updated from 1.2.3 to 1.2.4 for image 'ghcr.io/x/y'"* ]]
}

@test "update_apply: JSON output includes strategy kv" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"event":"update-applied"'* ]]
    [[ "$output" == *'"strategy":"patch"'* ]]
    [[ "$output" == *'"kind":"Deployment"'* ]]
    [[ "$output" == *'"from":"1.2.3"'* ]]
    [[ "$output" == *'"to":"1.2.4"'* ]]
}

@test "update_apply: no owner -> UNOWNED=patch as field-manager=keelson" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) printf '{}' ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"operation":"Update"'* ]]
    [[ "$output" == *'"strategy":"patch"'* ]]
    grep -q -- "--field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: Update-op owner routes to UNOWNED=patch as field-manager=keelson" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) cat "$TMP_DIR/mf.json" ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    printf '{"metadata":{"managedFields":%s}}' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"strategy":"patch"'* ]]
    grep -q -- "--field-manager=keelson" "$TMP_DIR/kubectl.log"
    grep -q -- "patch Deployment app" "$TMP_DIR/kubectl.log"
}

@test "update_apply: Apply owner -> OWNED=mimic SSAs as that manager, no --force-conflicts" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) cat "$TMP_DIR/mf.json" ;;
    apply)
        echo "$@" >>"$TMP_DIR/kubectl.log"
        cat - >"$TMP_DIR/kubectl.stdin"
        exit 0
        ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    printf '{"metadata":{"managedFields":%s}}' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"argocd-application-controller"'* ]]
    [[ "$output" == *'"operation":"Apply"'* ]]
    [[ "$output" == *'"strategy":"mimic"'* ]]
    grep -q -- "apply --server-side" "$TMP_DIR/kubectl.log"
    grep -q -- "--field-manager=argocd-application-controller" "$TMP_DIR/kubectl.log"
    ! grep -q -- "--force-conflicts" "$TMP_DIR/kubectl.log"
    grep -q "image: ghcr.io/x/y:1.2.4" "$TMP_DIR/kubectl.stdin"
    grep -q "kind: Deployment" "$TMP_DIR/kubectl.stdin"
}

@test "update_apply: managedFields can be passed directly (no kubectl get)" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) echo "kubectl get should not have been called" >&2; exit 99 ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "$(mf_apply_argocd)"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"argocd-application-controller"'* ]]
    [[ "$output" == *'"strategy":"mimic"'* ]]
    grep -q -- "apply --server-side" "$TMP_DIR/kubectl.log"
}

# --- update_apply: global strategy overrides ---

@test "update_apply: OWNED=patch overrides mimic on Apply-owned resource" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) cat "$TMP_DIR/mf.json" ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    printf '{"metadata":{"managedFields":%s}}' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    KEELSON_FIELD_MANAGER_STRATEGY_OWNED=patch \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"strategy":"patch"'* ]]
    grep -q -- "patch Deployment app" "$TMP_DIR/kubectl.log"
}

@test "update_apply: UNOWNED=claim SSAs as keelson on unowned resource" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) printf '{}' ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"operation":"Apply"'* ]]
    [[ "$output" == *'"strategy":"claim"'* ]]
    grep -q -- "apply --server-side" "$TMP_DIR/kubectl.log"
    grep -q -- "--field-manager=keelson" "$TMP_DIR/kubectl.log"
}

# --- update_apply: annotation overrides ---

@test "update_apply: annotation strategy=claim overrides OWNED=mimic default" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) cat "$TMP_DIR/mf.json" ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    printf '{"metadata":{"managedFields":%s}}' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    local ann='keelson.pro/field-manager-strategy=claim'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"strategy":"claim"'* ]]
    grep -q -- "apply --server-side" "$TMP_DIR/kubectl.log"
    grep -q -- "--field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: annotation strategy=mimic on unowned refuses and returns 1" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) printf '{}' ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    local ann='keelson.pro/field-manager-strategy=mimic'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-refused-mimic-unowned"'* ]]
    [[ "$output" == *"requires an Apply-op field owner"* ]]
    ! grep -q -- "patch " "$TMP_DIR/kubectl.log" 2>/dev/null || true
}

@test "update_apply: annotation strategy invalid value logs error and returns 1" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) printf '{}' ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    local ann='keelson.pro/field-manager-strategy=mimick'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-invalid-strategy-annotation"'* ]]
    [[ "$output" == *'"value":"mimick"'* ]]
}

@test "update_apply: per-container annotation wins over workload-wide" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) cat "$TMP_DIR/mf.json" ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    printf '{"metadata":{"managedFields":%s}}' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    local ann=$'keelson.pro/field-manager-strategy=mimic\nkeelson.pro/field-manager-strategy.main=patch'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"patch"'* ]]
    [[ "$output" == *'"manager":"keelson"'* ]]
}

# --- update_apply: SSA failure branches ---

@test "update_apply: SSA conflict logs update-apply-conflict and returns 1" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) cat "$TMP_DIR/mf.json" ;;
    apply)
        echo 'Apply failed with 1 conflict: conflict with "flux" using apps/v1' >&2
        exit 1
        ;;
esac
SH
    printf '{"metadata":{"managedFields":%s}}' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-apply-conflict"'* ]]
    [[ "$output" == *'"manager":"argocd-application-controller"'* ]]
    [[ "$output" == *'"strategy":"mimic"'* ]]
    [[ "$output" == *'field-ownership conflict'* ]]
    [[ "$output" == *'"reason":"Apply failed with 1 conflict'* ]]
}

@test "update_apply: SSA non-conflict failure logs update-failed and returns 1" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) cat "$TMP_DIR/mf.json" ;;
    apply)
        echo 'error: unable to reach cluster' >&2
        exit 1
        ;;
esac
SH
    printf '{"metadata":{"managedFields":%s}}' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-failed"'* ]]
    [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    [[ "$output" == *'"reason":"error: unable to reach cluster"'* ]]
}

@test "update_apply: CronJob patch nests under jobTemplate" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
exit 0
SH
    run update_apply CronJob default cron containers worker ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"jobTemplate"* ]]
}

@test "update_apply: CronJob success uses the same sentence shape" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    run emit update_apply CronJob batch nightly containers worker ghcr.io/acme/n:1.4.3 1.4.2
    [ "$status" -eq 0 ]
    [[ "$output" == *"CronJob 'nightly' in 'batch' updated from 1.4.2 to 1.4.3 for image 'ghcr.io/acme/n'"* ]]
}

@test "update_apply: kubectl failure logs update-failed and returns 1" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 1
SH
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not patch Deployment 'app'/main in 'default'"* ]]
}

@test "update_apply: unsupported kind logs update-unsupported-kind and returns 1" {
    run emit update_apply Pod default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot update Pod 'app' in 'default': kind not supported."* ]]
}

# --- update_trigger_cronjob ---

@test "update_trigger_cronjob: success with version info renders the full sentence" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
exit 0
SH
    run emit update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n
    [ "$status" -eq 0 ]
    [[ "$output" =~ Job\ \'nightly-[0-9]+\'\ created\ from\ CronJob\ \'nightly\'\ in\ \'batch\'\ with\ update\ from\ 1.4.2\ to\ 1.4.3\ for\ image\ \'ghcr.io/acme/n\' ]]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"create job"* ]]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"--from=cronjob/nightly"* ]]
}

@test "update_trigger_cronjob: without version info renders the concise sentence" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    run emit update_trigger_cronjob batch nightly
    [ "$status" -eq 0 ]
    [[ "$output" =~ Job\ \'nightly-[0-9]+\'\ created\ from\ CronJob\ \'nightly\'\ in\ \'batch\' ]]
    [[ "$output" != *"with update from"* ]]
}

@test "update_trigger_cronjob: kubectl failure logs cronjob-job-trigger-failed" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 1
SH
    run emit update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not create Job"* ]]
    [[ "$output" == *"from CronJob 'nightly' in 'batch'"* ]]
}
