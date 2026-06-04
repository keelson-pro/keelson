# Registry credential resolution + skopeo wrappers.
# Sourced; not directly executable.
#
# Depends on:
#   lib/image.bash, lib/annotations.bash
# Runtime tooling (in keelson-base-image):
#   skopeo, yq, kubectl, base64, curl, docker-credential-ecr-login
#
# Credential resolution per workload's keelson.pro/credentials annotation
# (default "respect-pod"):
#   respect-pod   - walk the workload's imagePullSecrets first; fall through
#                   to the central path if none cover the registry.
#                   When KEELSON_RESPECT_SA_PULL_SECRETS=true, also walks the
#                   workload's ServiceAccount imagePullSecrets between the
#                   pod-spec walk and the central fall-through (matches what
#                   the kubelet sees post-admission).
#   central       - skip pod creds; go straight to central.
#   ignore-pod    - synonym for "central".
#
# Central path consults the keelson-registries config at
# /configmap/registries.yaml (mounted from the keelson ConfigMap). The file is
# a map keyed by registry host, with each value carrying an "auth-mode":
#   secret    - kubectl get secret <host> in <namespace> (default: keelson's
#               own namespace from the SA mount), decode .dockerconfigjson.
#               The Secret name is the map key by convention; the optional
#               "namespace" override points to a different ns if needed.
#   aws-irsa  - docker-credential-ecr-login (relies on AWS_*_TOKEN_FILE / role)
#   azure-wi  - federated token -> AAD token -> ACR refresh token
#   gcp-wi    - GCE metadata server access_token

# -g so the cache survives across function scopes when this lib is sourced
# from inside a function (e.g. bats setup, future restart-and-reload paths).
declare -gA _REGISTRY_CONFIG_CACHE=()
declare -g _REGISTRY_CONFIG_LOADED=0
declare -g _REGISTRY_OWN_NAMESPACE=""

# Fixed mount location for the keelson ConfigMap. Tests reassign after sourcing.
KEELSON_REGISTRIES_FILE=/configmap/registries.yaml

# registry_init
# Idempotent. Loads keelson-registries from KEELSON_REGISTRIES_FILE.
# Missing/unreadable file is fine - that's the "all anonymous" case.
# The file is a map: { <host>: { auth-mode: ..., namespace: ... }, ... }.
registry_init() {
    [ "$_REGISTRY_CONFIG_LOADED" -eq 1 ] && return 0
    local file=$KEELSON_REGISTRIES_FILE
    _REGISTRY_CONFIG_LOADED=1
    [ ! -r "$file" ] && return 0
    local hosts host entry
    hosts=$(yq '.registries // {} | keys | .[]' "$file" 2>/dev/null) || return 0
    [ -z "$hosts" ] && return 0
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        entry=$(yq -o=json ".registries[\"$host\"]" "$file")
        _REGISTRY_CONFIG_CACHE["$host"]=$entry
    done <<< "$hosts"
}

# registry_own_namespace
# Echoes Keelson's own namespace, read from the SA token mount on first call
# and cached. Used as the default namespace for static-secret lookups.
# Tests override via KEELSON_SA_NAMESPACE_FILE.
registry_own_namespace() {
    if [ -z "$_REGISTRY_OWN_NAMESPACE" ]; then
        local ns_file="${KEELSON_SA_NAMESPACE_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/namespace}"
        if [ -r "$ns_file" ]; then
            _REGISTRY_OWN_NAMESPACE=$(cat "$ns_file")
        fi
    fi
    printf '%s' "$_REGISTRY_OWN_NAMESPACE"
}

# registry_config_for_host <host>
# Echoes the registry JSON entry for the host, or empty.
registry_config_for_host() {
    printf '%s' "${_REGISTRY_CONFIG_CACHE[$1]:-}"
}

# registry_resolve_creds <image-ref> <imagePullSecrets-json> <namespace> <annotation-lines> [<service-account-name>] [<container-name>]
# Echoes a "user:pass" string suitable for skopeo --creds, or empty for anonymous.
# The SA arg is optional; when KEELSON_RESPECT_SA_PULL_SECRETS=true and the SA
# name is non-empty, the SA's imagePullSecrets are walked between the pod-spec
# walk and the central fall-through.
# The container arg is optional; when non-empty, per-container annotation
# overrides (e.g. keelson.pro/credentials.<container>) take precedence.
registry_resolve_creds() {
    local image=$1 ips_json=$2 ns=$3 ann=$4 sa=${5:-} container=${6:-}
    local host mode creds
    host=$(image_host "$image")
    mode=$(annotation_get "$ann" credentials "$container")
    mode=${mode:-respect-pod}

    case "$mode" in
        respect-pod)
            if creds=$(registry_creds_from_pull_secrets "$ips_json" "$ns" "$host") \
                    && [ -n "$creds" ]; then
                printf '%s' "$creds"
                return 0
            fi
            if [ "${KEELSON_RESPECT_SA_PULL_SECRETS:-false}" = "true" ] \
                    && [ -n "$sa" ]; then
                if creds=$(registry_creds_from_sa "$sa" "$ns" "$host") \
                        && [ -n "$creds" ]; then
                    printf '%s' "$creds"
                    return 0
                fi
            fi
            ;;
        central|ignore-pod)
            : # fall through
            ;;
        *)
            return 2
            ;;
    esac

    registry_creds_central "$host"
}

# registry_creds_from_sa <sa-name> <namespace> <host>
# Fetches the ServiceAccount's imagePullSecrets and walks them, returning the
# first that has creds for <host>. Returns non-zero with empty output if the
# SA does not exist, has no imagePullSecrets, or none cover the host.
registry_creds_from_sa() {
    local sa=$1 ns=$2 host=$3
    local sa_json ips
    sa_json=$(kubectl get sa "$sa" -n "$ns" -o json 2>/dev/null) || return 1
    ips=$(printf '%s' "$sa_json" \
        | yq -p=json -o=json '.imagePullSecrets // []')
    if [ -z "$ips" ] || [ "$ips" = "null" ] || [ "$ips" = "[]" ]; then
        return 1
    fi
    registry_creds_from_pull_secrets "$ips" "$ns" "$host"
}

registry_creds_central() {
    local host=$1 cfg auth_mode
    cfg=$(registry_config_for_host "$host")
    if [ -z "$cfg" ]; then
        printf ''
        return 0
    fi
    auth_mode=$(printf '%s' "$cfg" | yq -p=json '."auth-mode"')
    case "$auth_mode" in
        secret)   registry_creds_secret "$cfg" "$host" ;;
        aws-irsa) registry_creds_aws_irsa "$host" ;;
        azure-wi) registry_creds_azure_wi "$host" ;;
        gcp-wi)   registry_creds_gcp_wi ;;
        *)        printf '' ;;
    esac
}

# registry_creds_secret <entry-json> <host>
# Static-secret resolution. By convention the Secret is named after the host
# (the map key), so we don't take a secret-name field. The Secret lives in
# Keelson's own namespace unless the entry overrides with "namespace".
registry_creds_secret() {
    local cfg=$1 host=$2
    local ns
    ns=$(printf '%s' "$cfg" | yq -p=json '.namespace // ""')
    if [ -z "$ns" ] || [ "$ns" = "null" ]; then
        ns=$(registry_own_namespace)
    fi
    if [ -z "$ns" ]; then
        log_error registry-namespace-unknown host="$host"
        return 1
    fi
    registry_creds_from_named_secret "$host" "$ns" "$host"
}

registry_creds_from_pull_secrets() {
    local ips_json=$1 ns=$2 host=$3
    [ -z "$ips_json" ] && return 1
    [ "$ips_json" = "null" ] && return 1
    local count i name creds
    count=$(printf '%s' "$ips_json" | yq -p=json 'length // 0')
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        return 1
    fi
    for ((i=0; i<count; i++)); do
        name=$(printf '%s' "$ips_json" | yq -p=json ".[$i].name")
        if creds=$(registry_creds_from_named_secret "$name" "$ns" "$host") \
                && [ -n "$creds" ]; then
            printf '%s' "$creds"
            return 0
        fi
    done
    return 1
}

registry_creds_from_named_secret() {
    local secret=$1 ns=$2 host=$3
    local b64 dockerconfig auth
    b64=$(kubectl get secret "$secret" -n "$ns" \
            -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null) || return 1
    [ -z "$b64" ] && return 1
    dockerconfig=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || return 1
    auth=$(printf '%s' "$dockerconfig" \
            | yq -p=json '.auths."'"$host"'".auth // ""')
    if [ -z "$auth" ] || [ "$auth" = "null" ]; then
        return 1
    fi
    printf '%s' "$auth" | base64 -d
}

registry_creds_aws_irsa() {
    local host=$1 raw user secret
    raw=$(printf '%s' "$host" | docker-credential-ecr-login get 2>/dev/null) || return 1
    [ -z "$raw" ] && return 1
    user=$(printf '%s' "$raw" | yq -p=json '.Username')
    secret=$(printf '%s' "$raw" | yq -p=json '.Secret')
    if [ -z "$user" ] || [ -z "$secret" ]; then
        return 1
    fi
    printf '%s:%s' "$user" "$secret"
}

registry_creds_gcp_wi() {
    local token
    token=$(curl -fsSL -H 'Metadata-Flavor: Google' \
        'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
        2>/dev/null | yq -p=json '.access_token') || return 1
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        return 1
    fi
    printf 'oauth2accesstoken:%s' "$token"
}

registry_creds_azure_wi() {
    local host=$1
    local fed_file=${AZURE_FEDERATED_TOKEN_FILE:?AZURE_FEDERATED_TOKEN_FILE required for azure-wi}
    local tenant=${AZURE_TENANT_ID:?AZURE_TENANT_ID required for azure-wi}
    local client=${AZURE_CLIENT_ID:?AZURE_CLIENT_ID required for azure-wi}
    local fed_token aad_token refresh
    fed_token=$(cat "$fed_file") || return 1
    aad_token=$(curl -fsSL -X POST \
        "https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token" \
        --data-urlencode "client_id=${client}" \
        --data-urlencode "scope=https://containerregistry.azure.net/.default" \
        --data-urlencode "client_assertion=${fed_token}" \
        --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
        --data-urlencode "grant_type=client_credentials" \
        2>/dev/null | yq -p=json '.access_token') || return 1
    if [ -z "$aad_token" ] || [ "$aad_token" = "null" ]; then
        return 1
    fi
    refresh=$(curl -fsSL -X POST \
        "https://${host}/oauth2/exchange" \
        --data-urlencode "grant_type=access_token" \
        --data-urlencode "service=${host}" \
        --data-urlencode "access_token=${aad_token}" \
        2>/dev/null | yq -p=json '.refresh_token') || return 1
    if [ -z "$refresh" ] || [ "$refresh" = "null" ]; then
        return 1
    fi
    printf '00000000-0000-0000-0000-000000000000:%s' "$refresh"
}

# registry_list_tags <image-ref> [creds]
# Echoes one tag per line. Returns non-zero on registry error.
registry_list_tags() {
    local image=$1 creds=${2:-}
    local repo out
    repo=$(image_repo "$image")
    if [ -n "$creds" ]; then
        out=$(skopeo list-tags --creds="$creds" "docker://${repo}" 2>/dev/null) || return 1
    else
        out=$(skopeo list-tags "docker://${repo}" 2>/dev/null) || return 1
    fi
    printf '%s' "$out" | yq -p=json '.Tags[]'
}
