#!/usr/bin/env bats

# Tests for lib/registry.bash. Network tooling (kubectl, skopeo, curl,
# docker-credential-ecr-login) is provided via PATH-prepended shim scripts in
# $TMP_BIN. Real yq/base64 from the test image are used as-is.

setup() {
    TMP_DIR=$(mktemp -d)
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    KEELSON_CONFIG_MODE=keelson
    KEELSON_RESPECT_SA_PULL_SECRETS=false
    export PATH KEELSON_CONFIG_MODE KEELSON_RESPECT_SA_PULL_SECRETS

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/image.bash
    source "$SCRIPT_DIR/lib/image.bash"
    # shellcheck source=../scripts/lib/annotations.bash
    source "$SCRIPT_DIR/lib/annotations.bash"
    # shellcheck source=../scripts/lib/registry.bash
    source "$SCRIPT_DIR/lib/registry.bash"

    # Override the hard-coded production path after sourcing.
    KEELSON_REGISTRIES_FILE="$TMP_DIR/registries.yaml"
}

teardown() {
    rm -rf "$TMP_DIR"
}

# install_shim <name> -- reads body from stdin.
install_shim() {
    local name=$1
    cat > "$TMP_BIN/$name"
    chmod +x "$TMP_BIN/$name"
}

# Make a docker-config secret payload for the given host + creds.
make_dockerconfig() {
    local host=$1 user=$2 pass=$3
    local auth
    auth=$(printf '%s:%s' "$user" "$pass" | base64 -w0 2>/dev/null || printf '%s:%s' "$user" "$pass" | base64)
    printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$auth"
}

# --- registry_init / registry_config_for_host ---

@test "registry_init: missing file is fine, no entries" {
    rm -f "$KEELSON_REGISTRIES_FILE"
    run registry_init
    [ "$status" -eq 0 ]
}

@test "registry_init: idempotent" {
    rm -f "$KEELSON_REGISTRIES_FILE"
    registry_init
    run registry_init
    [ "$status" -eq 0 ]
}

@test "registry_init: loads entries from file" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  ghcr.io:
    auth-mode: secret
    namespace: keelson-system
  123.dkr.ecr.us-east-1.amazonaws.com:
    auth-mode: aws-irsa
YAML
    registry_init
    run registry_config_for_host ghcr.io
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "registry_config_for_host: unknown host is empty" {
    rm -f "$KEELSON_REGISTRIES_FILE"
    registry_init
    run registry_config_for_host nope.example
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- registry_creds_from_named_secret ---

@test "named_secret: kubectl returns empty → fail" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf ''
SH
    run registry_creds_from_named_secret pull-secret default ghcr.io
    [ "$status" -ne 0 ]
}

@test "named_secret: auth missing for host → fail" {
    local payload b64
    payload=$(make_dockerconfig other.example fred sekret)
    b64=$(printf '%s' "$payload" | base64 -w0 2>/dev/null || printf '%s' "$payload" | base64)
    install_shim kubectl <<SH
#!/usr/bin/env bash
printf '%s' '$b64'
SH
    run registry_creds_from_named_secret pull-secret default ghcr.io
    [ "$status" -ne 0 ]
}

@test "named_secret: returns user:pass on match" {
    local payload b64
    payload=$(make_dockerconfig ghcr.io fred 's3cret')
    b64=$(printf '%s' "$payload" | base64 -w0 2>/dev/null || printf '%s' "$payload" | base64)
    install_shim kubectl <<SH
#!/usr/bin/env bash
printf '%s' '$b64'
SH
    run registry_creds_from_named_secret pull-secret default ghcr.io
    [ "$status" -eq 0 ]
    [ "$output" = "fred:s3cret" ]
}

# --- registry_creds_from_pull_secrets ---

@test "pull_secrets: empty list → fail" {
    run registry_creds_from_pull_secrets '[]' default ghcr.io
    [ "$status" -ne 0 ]
}

@test "pull_secrets: null → fail" {
    run registry_creds_from_pull_secrets 'null' default ghcr.io
    [ "$status" -ne 0 ]
}

@test "pull_secrets: walks list and picks first match" {
    local p1 p2 b1 b2
    p1=$(make_dockerconfig other.example a b)
    p2=$(make_dockerconfig ghcr.io fred sekret)
    b1=$(printf '%s' "$p1" | base64 -w0 2>/dev/null || printf '%s' "$p1" | base64)
    b2=$(printf '%s' "$p2" | base64 -w0 2>/dev/null || printf '%s' "$p2" | base64)
    install_shim kubectl <<SH
#!/usr/bin/env bash
case "\$*" in
    *first*) printf '%s' '$b1' ;;
    *second*) printf '%s' '$b2' ;;
esac
SH
    run registry_creds_from_pull_secrets '[{"name":"first"},{"name":"second"}]' default ghcr.io
    [ "$status" -eq 0 ]
    [ "$output" = "fred:sekret" ]
}

# --- registry_resolve_creds ---

@test "resolve_creds: respect-pod with matching pod secret uses it" {
    local payload b64
    payload=$(make_dockerconfig ghcr.io pod-user pod-pass)
    b64=$(printf '%s' "$payload" | base64 -w0 2>/dev/null || printf '%s' "$payload" | base64)
    install_shim kubectl <<SH
#!/usr/bin/env bash
printf '%s' '$b64'
SH
    run registry_resolve_creds ghcr.io/x/y:1.0 '[{"name":"a"}]' default 'keelson.pro/credentials=respect-pod'
    [ "$status" -eq 0 ]
    [ "$output" = "pod-user:pod-pass" ]
}

@test "resolve_creds: respect-pod falls through to central when pod secret has no match" {
    rm -f "$KEELSON_REGISTRIES_FILE"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf ''
SH
    run registry_resolve_creds ghcr.io/x/y:1.0 '[{"name":"a"}]' default 'keelson.pro/credentials=respect-pod'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "resolve_creds: central skips pod secrets" {
    rm -f "$KEELSON_REGISTRIES_FILE"
    # If kubectl is called, fail loudly so we know respect-pod path leaked.
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "kubectl should not have been called" >&2
exit 99
SH
    run registry_resolve_creds ghcr.io/x/y:1.0 '[{"name":"a"}]' default 'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "resolve_creds: ignore-pod is a synonym for central" {
    rm -f "$KEELSON_REGISTRIES_FILE"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "kubectl should not have been called" >&2
exit 99
SH
    run registry_resolve_creds ghcr.io/x/y:1.0 '[{"name":"a"}]' default 'keelson.pro/credentials=ignore-pod'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "resolve_creds: invalid mode returns 2" {
    run registry_resolve_creds ghcr.io/x/y:1.0 '[]' default 'keelson.pro/credentials=bogus'
    [ "$status" -eq 2 ]
}

@test "resolve_creds: default mode is respect-pod" {
    local payload b64
    payload=$(make_dockerconfig ghcr.io u p)
    b64=$(printf '%s' "$payload" | base64 -w0 2>/dev/null || printf '%s' "$payload" | base64)
    install_shim kubectl <<SH
#!/usr/bin/env bash
printf '%s' '$b64'
SH
    run registry_resolve_creds ghcr.io/x/y:1.0 '[{"name":"a"}]' default ''
    [ "$status" -eq 0 ]
    [ "$output" = "u:p" ]
}

# --- SA imagePullSecrets walk (KEELSON_RESPECT_SA_PULL_SECRETS) ---

@test "resolve_creds: SA walk disabled by default → no kubectl get sa call" {
    rm -f "$KEELSON_REGISTRIES_FILE"
    # If kubectl is asked for an SA, the test fails. Pod-secret call must return
    # empty so we go past the pod-spec walk.
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$*" in
    *"get sa "*) echo "SA walk should not have happened" >&2; exit 99 ;;
esac
printf ''
SH
    run registry_resolve_creds ghcr.io/x/y:1.0 '[{"name":"podsec"}]' default \
        'keelson.pro/credentials=respect-pod' my-sa
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "resolve_creds: SA walk enabled, pod miss → walks SA secrets and uses match" {
    KEELSON_RESPECT_SA_PULL_SECRETS=true
    local payload b64
    payload=$(make_dockerconfig ghcr.io sa-user sa-pass)
    b64=$(printf '%s' "$payload" | base64 -w0 2>/dev/null || printf '%s' "$payload" | base64)
    install_shim kubectl <<SH
#!/usr/bin/env bash
case "\$*" in
    *"get sa "*) printf '%s' '{"imagePullSecrets":[{"name":"sa-secret"}]}' ;;
    *"get secret sa-secret"*) printf '%s' '$b64' ;;
    *) printf '' ;;
esac
SH
    # Empty pod-spec list, so pod walk yields nothing and SA walk runs.
    run registry_resolve_creds ghcr.io/x/y:1.0 '[]' default \
        'keelson.pro/credentials=respect-pod' my-sa
    [ "$status" -eq 0 ]
    [ "$output" = "sa-user:sa-pass" ]
}

@test "resolve_creds: SA walk enabled but pod secret wins → SA never consulted" {
    KEELSON_RESPECT_SA_PULL_SECRETS=true
    local payload b64
    payload=$(make_dockerconfig ghcr.io pod-user pod-pass)
    b64=$(printf '%s' "$payload" | base64 -w0 2>/dev/null || printf '%s' "$payload" | base64)
    install_shim kubectl <<SH
#!/usr/bin/env bash
case "\$*" in
    *"get sa "*) echo "SA walk should not have happened when pod won" >&2; exit 99 ;;
    *) printf '%s' '$b64' ;;
esac
SH
    run registry_resolve_creds ghcr.io/x/y:1.0 '[{"name":"podsec"}]' default \
        'keelson.pro/credentials=respect-pod' my-sa
    [ "$status" -eq 0 ]
    [ "$output" = "pod-user:pod-pass" ]
}

@test "resolve_creds: SA walk enabled but empty SA name → SA walk skipped" {
    KEELSON_RESPECT_SA_PULL_SECRETS=true
    rm -f "$KEELSON_REGISTRIES_FILE"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$*" in
    *"get sa "*) echo "SA walk attempted with no SA name" >&2; exit 99 ;;
esac
printf ''
SH
    run registry_resolve_creds ghcr.io/x/y:1.0 '[]' default \
        'keelson.pro/credentials=respect-pod' ''
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "registry_creds_from_sa: SA missing (kubectl fails) → non-zero" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 1
SH
    run registry_creds_from_sa missing-sa default ghcr.io
    [ "$status" -ne 0 ]
}

@test "registry_creds_from_sa: SA has no imagePullSecrets → non-zero" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
printf '%s' '{"metadata":{"name":"my-sa"}}'
SH
    run registry_creds_from_sa my-sa default ghcr.io
    [ "$status" -ne 0 ]
}

# --- aws-irsa via registries.yaml ---

@test "resolve_creds: aws-irsa central path calls helper" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  123.dkr.ecr.us-east-1.amazonaws.com:
    auth-mode: aws-irsa
YAML
    install_shim docker-credential-ecr-login <<'SH'
#!/usr/bin/env bash
printf '{"Username":"AWS","Secret":"tok123"}'
SH
    # Re-init to load the file we just wrote.
    _REGISTRY_CONFIG_LOADED=0
    registry_init
    run registry_resolve_creds 123.dkr.ecr.us-east-1.amazonaws.com/x/y:1.0 '[]' default 'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$output" = "AWS:tok123" ]
}

@test "resolve_creds: aws-irsa helper failure → empty" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  123.dkr.ecr.us-east-1.amazonaws.com:
    auth-mode: aws-irsa
YAML
    install_shim docker-credential-ecr-login <<'SH'
#!/usr/bin/env bash
exit 1
SH
    _REGISTRY_CONFIG_LOADED=0
    registry_init
    run registry_resolve_creds 123.dkr.ecr.us-east-1.amazonaws.com/x/y:1.0 '[]' default 'keelson.pro/credentials=central'
    # aws_irsa returns 1 on failure but resolve_creds does not propagate, so output is empty.
    [ -z "$output" ]
}

# --- gcp-wi ---

@test "resolve_creds: gcp-wi reads metadata access_token" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  europe-docker.pkg.dev:
    auth-mode: gcp-wi
YAML
    install_shim curl <<'SH'
#!/usr/bin/env bash
printf '{"access_token":"gcp-tok-xyz","expires_in":3600}'
SH
    _REGISTRY_CONFIG_LOADED=0
    registry_init
    run registry_resolve_creds europe-docker.pkg.dev/x/y:1.0 '[]' default 'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$output" = "oauth2accesstoken:gcp-tok-xyz" ]
}

# --- registry_list_tags ---

@test "list_tags: anon path - skopeo called without --creds" {
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        --creds=*) echo "ANON_BROKEN" >&2; exit 1 ;;
    esac
done
printf '{"Tags":["1.0","1.1","1.2"]}'
SH
    run registry_list_tags ghcr.io/x/y:1.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0"* ]]
    [[ "$output" == *"1.2"* ]]
}

@test "list_tags: with creds - skopeo called with --creds" {
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
saw=0
for a in "$@"; do
    case "$a" in
        --creds=fred:sekret) saw=1 ;;
    esac
done
[ "$saw" -eq 1 ] || { echo "no creds passed" >&2; exit 1; }
printf '{"Tags":["2.0"]}'
SH
    run registry_list_tags ghcr.io/x/y:1.0 fred:sekret
    [ "$status" -eq 0 ]
    [[ "$output" == *"2.0"* ]]
}

@test "list_tags: skopeo failure returns non-zero" {
    install_shim skopeo <<'SH'
#!/usr/bin/env bash
exit 1
SH
    run registry_list_tags ghcr.io/x/y:1.0
    [ "$status" -ne 0 ]
}
