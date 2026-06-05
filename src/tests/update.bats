#!/usr/bin/env bats

# Tests for lib/update.bash. kubectl is shimmed via $TMP_BIN on PATH.

setup() {
    TMP_DIR=$(mktemp -d)
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    export PATH TMP_DIR

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
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

# --- update_patch_json ---

@test "patch_json: Deployment shape" {
    run update_patch_json Deployment main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [ "$output" = '{"spec":{"template":{"spec":{"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.4"}]}}}}' ]
}

@test "patch_json: StatefulSet uses same template path" {
    run update_patch_json StatefulSet web ghcr.io/x/y:2.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *'"template":{"spec":{"containers":[{"name":"web"'* ]]
}

@test "patch_json: CronJob nests under jobTemplate" {
    run update_patch_json CronJob worker ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [ "$output" = '{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"worker","image":"ghcr.io/x/y:1.2.4"}]}}}}}}' ]
}

@test "patch_json: unknown kind returns non-zero" {
    run update_patch_json Pod main ghcr.io/x/y:1.0.0
    [ "$status" -ne 0 ]
}

# --- update_apply ---

@test "update_apply: success logs the sentence and returns 0" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
exit 0
SH
    run emit update_apply Deployment default app main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deployment 'app' in 'default' updated from 1.2.3 to 1.2.4 for image 'ghcr.io/x/y'"* ]]
}

@test "update_apply: JSON output retains structured fields" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"event":"update-applied"'* ]]
    [[ "$output" == *'"kind":"Deployment"'* ]]
    [[ "$output" == *'"from":"1.2.3"'* ]]
    [[ "$output" == *'"to":"1.2.4"'* ]]
    [[ "$output" == *'"repo":"ghcr.io/x/y"'* ]]
    [[ "$output" == *'"msg":"Deployment '\''app'\'' in '\''default'\'' updated from 1.2.3 to 1.2.4 for image '\''ghcr.io/x/y'\''."'* ]]
}

@test "update_apply: invokes kubectl patch with strategic merge type" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
exit 0
SH
    run update_apply Deployment default app main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"patch Deployment app -n default --type=strategic"* ]]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *'"name":"main"'* ]]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *'"image":"ghcr.io/x/y:1.2.4"'* ]]
}

@test "update_apply: no owner -> patches under field-manager=keelson Update" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get) printf '{}' ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"operation":"Update"'* ]]
    grep -q -- "--field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: Update owner -> patches as that manager" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get)
        cat <<JSON
{"metadata":{"managedFields":[{"manager":"kubectl-client-side-apply","operation":"Update","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]}}
JSON
        ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"kubectl-client-side-apply"'* ]]
    [[ "$output" == *'"operation":"Update"'* ]]
    grep -q -- "--field-manager=kubectl-client-side-apply" "$TMP_DIR/kubectl.log"
    grep -q -- "patch Deployment app" "$TMP_DIR/kubectl.log"
}

@test "update_apply: Apply owner -> SSA under that manager with --force-conflicts" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$1" in
    get)
        cat <<JSON
{"metadata":{"managedFields":[{"manager":"argocd-application-controller","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]}}
JSON
        ;;
    apply)
        echo "$@" >>"$TMP_DIR/kubectl.log"
        cat - >"$TMP_DIR/kubectl.stdin"
        exit 0
        ;;
    *) echo "$@" >>"$TMP_DIR/kubectl.log"; exit 0 ;;
esac
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"argocd-application-controller"'* ]]
    [[ "$output" == *'"operation":"Apply"'* ]]
    grep -q -- "apply --server-side" "$TMP_DIR/kubectl.log"
    grep -q -- "--field-manager=argocd-application-controller" "$TMP_DIR/kubectl.log"
    grep -q -- "--force-conflicts" "$TMP_DIR/kubectl.log"
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
    local mf='[{"manager":"argocd","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app main ghcr.io/x/y:1.2.4 1.2.3 "$mf"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"argocd"'* ]]
    [[ "$output" == *'"operation":"Apply"'* ]]
    grep -q -- "apply --server-side" "$TMP_DIR/kubectl.log"
}

@test "update_apply: CronJob patch nests under jobTemplate" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
exit 0
SH
    run update_apply CronJob default cron worker ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"jobTemplate"* ]]
}

@test "update_apply: CronJob success uses the same sentence shape" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    run emit update_apply CronJob batch nightly worker ghcr.io/acme/n:1.4.3 1.4.2
    [ "$status" -eq 0 ]
    [[ "$output" == *"CronJob 'nightly' in 'batch' updated from 1.4.2 to 1.4.3 for image 'ghcr.io/acme/n'"* ]]
}

@test "update_apply: kubectl failure logs update-failed and returns 1" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 1
SH
    run emit update_apply Deployment default app main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not patch Deployment 'app'/main in 'default'"* ]]
}

@test "update_apply: unsupported kind logs update-unsupported-kind and returns 1" {
    run emit update_apply Pod default app main ghcr.io/x/y:1.2.4 1.2.3
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
