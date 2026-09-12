#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# Tests for lib/registry.bash. Network tooling (kubectl, skopeo, curl,
# docker-credential-ecr-login) is provided via PATH-prepended shim scripts in
# $TMP_BIN. Real yq/base64 from the test image are used as-is.

load helper

setup() {
    tmp_dir_init
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

# --- KEELSON_REGISTRIES_FILE default ---

# Sourced in a clean shell, because setup() reassigns the path after sourcing
# and so cannot see whether the assignment respected an existing value.
@test "registries file: an operator env override survives sourcing" {
    run env KEELSON_REGISTRIES_FILE=/custom/registries.yaml bash -c '
        source "$1/lib/registry.bash"
        printf "%s" "$KEELSON_REGISTRIES_FILE"
    ' _ "$SCRIPT_DIR"
    [ "$output" = "/custom/registries.yaml" ]
}

@test "registries file: the mount location is the default with no override" {
    run env -u KEELSON_REGISTRIES_FILE bash -c '
        source "$1/lib/registry.bash"
        printf "%s" "$KEELSON_REGISTRIES_FILE"
    ' _ "$SCRIPT_DIR"
    [ "$output" = "/configmap/registries.yaml" ]
}

# --- registry_init: failures are logged, not swallowed ---

# json so the event name is assertable; plain format prints only the message.
emit_json() {
    KEELSON_LOG_FORMAT=json "$@" 2>&1
}

# A file yq cannot parse at all.
write_unparseable_registries() {
    printf 'registries:\n  ghcr.io:\n    auth-mode: secret\n  : : :\n' \
        > "$KEELSON_REGISTRIES_FILE"
}

# Parses as YAML, but the host key is not a registry reference. It used to
# surface as a per-host extraction failure; the key rule now names it first.
write_unextractable_entry() {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  ghcr.io:
    auth-mode: secret
  'a"b':
    auth-mode: secret
YAML
}

@test "registry_init: unparseable file logs an error" {
    write_unparseable_registries
    run emit_json registry_init
    [ "$status" -eq 0 ]
    [[ "$output" == *registry-config-parse-failed* ]]
}

@test "registry_init: unparseable file loads no entries" {
    write_unparseable_registries
    registry_init 2>/dev/null
    run registry_config_for_host ghcr.io
    [ -z "$output" ]
}

@test "registry_init: unextractable entry logs an error" {
    write_unextractable_entry
    run emit_json registry_init
    [ "$status" -eq 0 ]
    [[ "$output" == *registry-config-key-invalid* ]]
}

@test "registry_init: unextractable entry does not stop the good ones loading" {
    write_unextractable_entry
    registry_init 2>/dev/null
    run registry_config_for_host ghcr.io
    [ -n "$output" ]
}

@test "registry_init: unextractable entry is not cached" {
    write_unextractable_entry
    registry_init 2>/dev/null
    run registry_config_for_host 'a"b'
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

# --- registry_init: entries boot validation would have rejected ---
#
# Boot refuses to start on any of these. They only reach registry_init when
# the ConfigMap is edited after boot, and there the entry is dropped and the
# rest of the file still loads.

@test "registry_init: a key that is not a registry reference is skipped" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  "not a host":
    auth-mode: secret
  ghcr.io:
    auth-mode: secret
YAML
    run emit_json registry_init
    [[ "$output" == *registry-config-key-invalid* ]]
}

@test "registry_init: a key that is not a registry reference leaves the rest loaded" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  "not a host":
    auth-mode: secret
  ghcr.io:
    auth-mode: secret
YAML
    registry_init 2>/dev/null
    run registry_config_for_host ghcr.io
    [ -n "$output" ]
}

@test "registry_init: an illegal derived Secret name is skipped" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  "[::1]:123":
    auth-mode: secret
YAML
    run emit_json registry_init
    [[ "$output" == *registry-config-secret-name-invalid* ]]
}

@test "registry_init: an illegal derived Secret name is skipped under any auth mode" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  "[::1]:123":
    auth-mode: aws-irsa
YAML
    run emit_json registry_init
    [[ "$output" == *registry-config-secret-name-invalid* ]]
}

@test "registry_init: a duplicated key keeps the first and logs the second" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  ghcr.io:
    auth-mode: secret
  ghcr.io:
    auth-mode: aws-irsa
YAML
    run emit_json registry_init
    [[ "$output" == *registry-config-key-duplicate* ]]
}

# --- central secret path: Secret naming convention and its overrides ---

# kubectl shim for the central secret path. Records the Secret name it was
# asked for so the naming convention is assertable, and answers with a docker
# config keyed by <auths-key>.
kubectl_secret_shim() {
    local auths_key=$1 user=$2 pass=$3 payload b64
    payload=$(make_dockerconfig "$auths_key" "$user" "$pass")
    b64=$(printf '%s' "$payload" | base64 -w0 2>/dev/null || printf '%s' "$payload" | base64)
    install_shim kubectl <<SH
#!/usr/bin/env bash
printf '%s' "\$3" > "$TMP_DIR/secret.name"
printf '%s' '$b64'
SH
}

# Central-mode entry for reg.example:5000, plus any extra entry lines given.
write_ported_registry() {
    {
        printf 'registries:\n  reg.example:5000:\n'
        printf '    auth-mode: secret\n    namespace: keelson-system\n'
        local line
        for line in "$@"; do
            printf '    %s\n' "$line"
        done
    } > "$KEELSON_REGISTRIES_FILE"
    registry_init
}

@test "central secret: a port in the host becomes a hyphen in the Secret name" {
    write_ported_registry
    kubectl_secret_shim 'reg.example:5000' port-user port-pass
    run registry_resolve_creds reg.example:5000/x/y:1.0 '[]' default \
        'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$output" = "port-user:port-pass" ]
    [ "$(cat "$TMP_DIR/secret.name")" = "reg.example-5000" ]
}

@test "central secret: a host with no port is still the Secret name verbatim" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  ghcr.io:
    auth-mode: secret
    namespace: keelson-system
YAML
    registry_init
    kubectl_secret_shim ghcr.io plain-user plain-pass
    run registry_resolve_creds ghcr.io/x/y:1.0 '[]' default \
        'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/secret.name")" = "ghcr.io" ]
}

@test "central secret: secret-name-override beats the derived name" {
    write_ported_registry 'secret-name-override: shared-pull'
    kubectl_secret_shim 'reg.example:5000' shared-user shared-pass
    run registry_resolve_creds reg.example:5000/x/y:1.0 '[]' default \
        'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$output" = "shared-user:shared-pass" ]
    [ "$(cat "$TMP_DIR/secret.name")" = "shared-pull" ]
}

@test "central secret: secret-key-override changes the auths key looked up" {
    write_ported_registry 'secret-key-override: https://reg.example:5000/v1/'
    kubectl_secret_shim 'https://reg.example:5000/v1/' proto-user proto-pass
    run registry_resolve_creds reg.example:5000/x/y:1.0 '[]' default \
        'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$output" = "proto-user:proto-pass" ]
}

@test "central secret: secret-key-override does not change the Secret name" {
    write_ported_registry 'secret-key-override: https://reg.example:5000/v1/'
    kubectl_secret_shim 'https://reg.example:5000/v1/' proto-user proto-pass
    run registry_resolve_creds reg.example:5000/x/y:1.0 '[]' default \
        'keelson.pro/credentials=central'
    [ "$(cat "$TMP_DIR/secret.name")" = "reg.example-5000" ]
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

# --- host case folding ---

@test "registry_init: an uppercase key is cached under its lowercase form" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  REG.Example.COM:
    auth-mode: secret
    namespace: keelson-system
YAML
    registry_init 2>/dev/null
    run registry_config_for_host reg.example.com
    [ -n "$output" ]
}

@test "registry_init: two spellings of one host are a duplicate" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  REG.example.com:
    auth-mode: secret
  reg.example.com:
    auth-mode: secret
YAML
    run emit_json registry_init
    [[ "$output" == *registry-config-key-duplicate* ]]
}

@test "central secret: an uppercase image host resolves a lowercase entry" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  reg.example.com:
    auth-mode: secret
    namespace: keelson-system
YAML
    registry_init
    kubectl_secret_shim reg.example.com case-user case-pass
    run registry_resolve_creds REG.Example.COM/x/y:1.0 '[]' default \
        'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$output" = "case-user:case-pass" ]
    [ "$(cat "$TMP_DIR/secret.name")" = "reg.example.com" ]
}

@test "registry_init: a derived name colliding with an override is skipped" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  other.example:
    auth-mode: secret
    secret-name-override: reg.example-5000
  reg.example:5000:
    auth-mode: secret
YAML
    run emit_json registry_init
    [[ "$output" == *registry-config-secret-name-collision* ]]
}

# --- auth-mode aliases ---
#
# The canonical names describe a mechanism; operators think in terms of their
# cloud or their registry product, and the mechanisms outlive their names.

@test "auth-mode alias: aws-ecr resolves as the AWS mode" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  123.dkr.ecr.us-east-1.amazonaws.com:
    auth-mode: aws-ecr
YAML
    install_shim docker-credential-ecr-login <<'SH'
#!/usr/bin/env bash
printf '{"Username":"AWS","Secret":"tok123"}'
SH
    registry_init
    run registry_resolve_creds 123.dkr.ecr.us-east-1.amazonaws.com/x/y:1.0 '[]' default 'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$output" = "AWS:tok123" ]
}

@test "auth-mode alias: aws-pi resolves as the AWS mode" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  123.dkr.ecr.us-east-1.amazonaws.com:
    auth-mode: aws-pi
YAML
    install_shim docker-credential-ecr-login <<'SH'
#!/usr/bin/env bash
printf '{"Username":"AWS","Secret":"tok123"}'
SH
    registry_init
    run registry_resolve_creds 123.dkr.ecr.us-east-1.amazonaws.com/x/y:1.0 '[]' default 'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$output" = "AWS:tok123" ]
}

@test "auth-mode alias: gcp-gar resolves as the GCP mode" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  europe-docker.pkg.dev:
    auth-mode: gcp-gar
YAML
    install_shim curl <<'SH'
#!/usr/bin/env bash
printf '{"access_token":"gcp-tok-xyz","expires_in":3600}'
SH
    registry_init
    run registry_resolve_creds europe-docker.pkg.dev/x/y:1.0 '[]' default 'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ "$output" = "oauth2accesstoken:gcp-tok-xyz" ]
}

@test "auth-mode alias: an unknown mode is still anonymous" {
    cat > "$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  ghcr.io:
    auth-mode: not-a-mode
YAML
    registry_init
    run registry_resolve_creds ghcr.io/x/y:1.0 '[]' default 'keelson.pro/credentials=central'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
