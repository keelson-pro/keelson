# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# Registry credential resolution + skopeo wrappers.
# Sourced; not directly executable.
#
# Depends on:
#   lib/image.bash, lib/annotations.bash
# Runtime tooling (in keelson-base-image):
#   skopeo, yq, kubectl, base64, curl, docker-credential-ecr-login
#
# Credential resolution per workload's keelson.pro/credentials annotation
# (default "central-then-pod-spec"):
#   central-then-pod-spec - the central config first, falling back to the
#                   workload's own imagePullSecrets. Central first because a
#                   host the operator has configured then costs no Secret
#                   read per workload at all, and because the operator's
#                   credential is the one they can reason about.
#   central       - central only, no fallback.
#   ignore-pod    - synonym for "central".
#   respect-pod-spec - the workload's own credentials only; central is never
#                   consulted. For a registry where the team's token is the
#                   only one that works.
#
# Wherever the pod spec is consulted, the workload's ServiceAccount
# imagePullSecrets are walked after it when KEELSON_RESPECT_SA_PULL_SECRETS
# is true, matching what the kubelet sees post-admission.
#
# A credential that resolves is not a credential that works, so the scan
# tries each source against the registry in turn rather than committing to
# the first one that answers.
#
# Central path consults the keelson-registries config at
# /configmap/registries.yaml (mounted from the keelson ConfigMap). The file is
# a map keyed by registry host, with each value carrying an "auth-mode":
#   secret    - kubectl get secret <host> in <namespace> (default: keelson's
#               own namespace from the SA mount), decode .dockerconfigjson.
#               The Secret name is the map key by convention; the optional
#               "namespace" override points to a different ns if needed.
#   aws       - docker-credential-ecr-login, so whatever the SDK credential
#               chain provides: EKS Pod Identity, IRSA, or an instance role
#   azure     - federated token -> Entra token -> ACR refresh token
#   gcp       - GCE metadata server access_token
#
# The cloud modes are named for the cloud rather than the mechanism, because
# the mechanisms get superseded and the credential source does not. Every
# mechanism spelling is still accepted as an alias.

# -g so the cache survives across function scopes when this lib is sourced
# from inside a function (e.g. bats setup, future restart-and-reload paths).
declare -gA _REGISTRY_CONFIG_CACHE=()
declare -g _REGISTRY_CONFIG_LOADED=0
declare -g _REGISTRY_OWN_NAMESPACE=""
# Last skopeo failure reason (one line). Set by registry_list_tags on
# failure so callers can surface a hint in their error log instead of an
# opaque "could not list tags". Cleared on success.
declare -g REGISTRY_LAST_ERROR=""
# Credential sources to try, in order, set by registry_creds_source_order.
declare -ga REGISTRY_CREDS_SOURCES=()

# Default mount location for the keelson ConfigMap, matching validate.bash so
# an operator's override survives whichever lib is sourced last. A bare
# assignment here silently beat that override in every entrypoint that sources
# this file, which is all three of them.
KEELSON_REGISTRIES_FILE="${KEELSON_REGISTRIES_FILE:-/configmap/registries.yaml}"

# The rules below are the single definition of what a registries map key may
# be and what Secret name it resolves to. Boot validation reads them to refuse
# a bad config outright; registry_init reads them to skip a bad entry that
# arrived in a ConfigMap edit after boot. One rule, two consequences.

# registry_key_valid <key>
# True when the key is a registry reference: a hostname or a bracketed IPv6
# literal, either with an optional port. The bracket form is accepted because
# that is how a raw IPv6 address is written, even though the Secret name it
# derives never is.
registry_key_valid() {
    [[ $1 =~ ^(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?)(:[0-9]+)?$ ]]
}

# registry_secret_name_for <key>
# The Secret name a key resolves to by convention: every colon becomes a
# hyphen, because a colon is not legal in a Kubernetes object name.
registry_secret_name_for() {
    printf '%s' "${1//:/-}"
}

# registry_object_name_valid <name>
# True for an RFC 1123 subdomain, which is what a Secret name has to be.
# Applied to the derived name and to secret-name-override alike: an override
# that cannot name a Secret is no better than a key that cannot.
registry_object_name_valid() {
    [ -n "$1" ] && [ "${#1}" -le 253 ] || return 1
    [[ $1 =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]]
}

# registry_init
# Idempotent. Loads keelson-registries from KEELSON_REGISTRIES_FILE.
# Missing/unreadable file is fine - that's the "all anonymous" case.
# The file is a map: { <host>: { auth-mode: ..., namespace: ... }, ... }.
#
# A file that will not parse, or a host key that will not extract, is
# survivable but never silent: falling back to anonymous pulls looks exactly
# like a registry that needs no credentials until the tags stop listing, so
# both cases say so and carry on with whatever else loaded. Every caller runs
# in a per-pass subshell, so the log repeats each pass until the file is fixed.
registry_init() {
    [ "$_REGISTRY_CONFIG_LOADED" -eq 1 ] && return 0
    local file=$KEELSON_REGISTRIES_FILE
    _REGISTRY_CONFIG_LOADED=1
    [ ! -r "$file" ] && return 0
    local hosts host entry
    if ! hosts=$(yq -o=y '.registries // {} | keys | .[]' "$file" 2>/dev/null); then
        log_error registry-config-parse-failed file="$file" \
            msg="Could not parse the registries config '$file', so no central registry credentials are available and every registry will be tried anonymously. Fix the ConfigMap and the next pass picks it up."
        return 0
    fi
    [ -z "$hosts" ] && return 0
    local override name key
    local -A seen=() claimed_by=() claimed_explicit=()
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        # Folded to match image_host, so config and image refs never have to
        # agree on spelling. Boot validation warns about the difference; here
        # it is taken quietly, since a nag every pass is noise, not news.
        host=${key,,}
        if [ -n "${seen[$host]:-}" ]; then
            log_error registry-config-key-duplicate host="$host" file="$file" \
                msg="Registry '$host' is declared more than once in '$file'. The first entry is being used and this one ignored; boot validation refuses this outright, so it can only have arrived in a ConfigMap edit."
            continue
        fi
        seen[$host]=1
        if ! registry_key_valid "$host"; then
            log_error registry-config-key-invalid host="$host" file="$file" \
                msg="Registry key '$host' in '$file' is not a registry hostname or bracketed IPv6 literal with an optional port, so the entry is ignored and that registry will be tried anonymously."
            continue
        fi
        if ! entry=$(yq -o=json ".registries[\"$key\"]" "$file" 2>/dev/null); then
            log_error registry-config-entry-failed host="$host" file="$file" \
                msg="Could not read the entry for registry '$host' from '$file', so that registry will be tried anonymously. Every other entry in the file still loaded."
            continue
        fi
        override=$(registry_entry_field "$entry" secret-name-override)
        name=$override
        [ -z "$name" ] && name=$(registry_secret_name_for "$host")
        if ! registry_object_name_valid "$name"; then
            log_error registry-config-secret-name-invalid host="$host" secret-name="$name" \
                msg="Registry '$host' resolves to Secret name '$name', which is not a valid Kubernetes object name, so the entry is ignored. Set secret-name-override on it to name the Secret explicitly."
            continue
        fi
        # Every claim is recorded, derived or overridden, and sharing is only
        # allowed where both sides said so. An override is not a licence for
        # someone else's derived name to land on the same Secret.
        if [ -n "${claimed_by[$name]:-}" ] \
                && ! { [ -n "$override" ] && [ -n "${claimed_explicit[$name]:-}" ]; }; then
            log_error registry-config-secret-name-collision host="$host" \
                other="${claimed_by[$name]}" secret-name="$name" \
                msg="Registries '${claimed_by[$name]}' and '$host' both resolve to Secret name '$name', so '$host' is ignored rather than sent another registry's credentials. If sharing one Secret is intended, set secret-name-override on both."
            continue
        fi
        claimed_by[$name]=$host
        [ -n "$override" ] && claimed_explicit[$name]=1
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
# registry_creds_source_order <annotation-lines> [<container>]
# Sets REGISTRY_CREDS_SOURCES to the credential sources to try, in order.
# Returns 2 for a credentials annotation naming no known mode.
#
# Sources are named here and resolved later, one at a time, because resolving
# one costs a kubectl call or a token fetch and the point is to stop at the
# first that works. Naming them also lets the caller try the next when a
# credential resolves but the registry rejects it, which a function returning
# a single credential cannot express.
registry_creds_source_order() {
    local ann=$1 container=${2:-} mode
    annotation_get "$ann" credentials "$container"
    mode=${ANNOTATION_VALUE:-central-then-pod-spec}
    REGISTRY_CREDS_SOURCES=()
    case "$mode" in
        central-then-pod-spec)
            REGISTRY_CREDS_SOURCES=(central pod)
            ;;
        central|ignore-pod)
            REGISTRY_CREDS_SOURCES=(central)
            ;;
        respect-pod-spec)
            REGISTRY_CREDS_SOURCES=(pod)
            ;;
        *)
            return 2
            ;;
    esac
    # The ServiceAccount walk is part of "what the workload has", so it
    # follows the pod spec wherever the pod spec appears and is absent where
    # it does not. Gated on the same switch as ever, since it costs a get.
    case " ${REGISTRY_CREDS_SOURCES[*]} " in
        *" pod "*)
            if [ "${KEELSON_RESPECT_SA_PULL_SECRETS:?KEELSON_RESPECT_SA_PULL_SECRETS required}" = "true" ]; then
                REGISTRY_CREDS_SOURCES+=(sa)
            fi
            ;;
    esac
}

# registry_creds_from_source <source> <host> <ips-json> <namespace> [<sa>]
# Echoes credentials from one named source. Empty output or non-zero means
# this source has nothing for this host, which is not an error: the caller
# moves to the next one.
registry_creds_from_source() {
    local source=$1 host=$2 ips_json=$3 ns=$4 sa=${5:-}
    case "$source" in
        pod)     registry_creds_from_pull_secrets "$ips_json" "$ns" "$host" ;;
        sa)      [ -n "$sa" ] || return 1
                 registry_creds_from_sa "$sa" "$ns" "$host" ;;
        central) registry_creds_central "$host" ;;
        *)       return 1 ;;
    esac
}

# registry_resolve_creds <image-ref> <imagePullSecrets-json> <namespace> <annotation-lines> [<service-account-name>] [<container-name>]
# Echoes the first credential any source yields, or empty for anonymous.
#
# The single-answer form, for callers with no way to retry. The scan walks
# the sources itself so that a credential the registry rejects is followed by
# the next source rather than ending the attempt.
registry_resolve_creds() {
    local image=$1 ips_json=$2 ns=$3 ann=$4 sa=${5:-} container=${6:-}
    local host source creds
    image_host "$image"
    host=$IMAGE_HOST
    registry_creds_source_order "$ann" "$container" || return 2
    for source in "${REGISTRY_CREDS_SOURCES[@]}"; do
        if creds=$(registry_creds_from_source "$source" "$host" "$ips_json" "$ns" "$sa") \
                && [ -n "$creds" ]; then
            printf '%s' "$creds"
            return 0
        fi
    done
    printf ''
    return 0
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

# registry_normalise_auth_mode <value>
# Echoes the canonical auth-mode for a configured value, or returns 1 for a
# value that names no mode at all. One definition, read by the dispatch below
# and by boot validation, so a mode accepted at boot is a mode that resolves.
#
# The rule is the cloud name, optionally suffixed with whichever mechanism or
# registry product the operator thinks of it as. Aliases exist because the
# canonical names describe a mechanism while operators think in terms of their
# cloud, and because the mechanisms outlive their names: EKS Pod Identity
# supersedes IRSA and Artifact Registry supersedes GCR, but
# docker-credential-ecr-login and the metadata server serve old and new alike.
registry_normalise_auth_mode() {
    case "$1" in
        secret)                            printf 'secret' ;;
        aws|aws-irsa|aws-pi|aws-ecr)       printf 'aws' ;;
        gcp|gcp-wi|gcp-gar|gcp-gcr)        printf 'gcp' ;;
        azure|azure-wi|azure-acr)          printf 'azure' ;;
        *)                                 return 1 ;;
    esac
}

registry_creds_central() {
    local host=$1 cfg auth_mode
    cfg=$(registry_config_for_host "$host")
    if [ -z "$cfg" ]; then
        printf ''
        return 0
    fi
    auth_mode=$(printf '%s' "$cfg" | yq -p=json -o=y '."auth-mode"')
    auth_mode=$(registry_normalise_auth_mode "$auth_mode") || auth_mode=''
    case "$auth_mode" in
        secret)   registry_creds_secret "$cfg" "$host" ;;
        aws)      registry_creds_aws "$host" ;;
        azure)    registry_creds_azure "$host" ;;
        gcp)      registry_creds_gcp ;;
        *)        printf '' ;;
    esac
}

# registry_entry_field <entry-json> <field>
# Echoes an optional string field from a registries entry, empty when absent.
registry_entry_field() {
    local value
    value=$(printf '%s' "$1" | yq -p=json -o=y ".\"$2\" // \"\"")
    [ "$value" = "null" ] && value=""
    printf '%s' "$value"
}

# registry_creds_secret <entry-json> <host>
# Static-secret resolution. Two names come out of one map key. The Secret is
# named after the host with any port's colon turned into a hyphen, because a
# colon is not legal in a Kubernetes object name and a registry on a custom
# port is not a reason to be locked out. The key looked up inside the Secret
# is the host verbatim, colon and all, because that is what Docker writes
# into .auths.
#
# "secret-name-override" and "secret-key-override" beat each half of that.
# The name override lets registries on several ports share one Secret; the
# key override reaches entries written with a scheme or a trailing path.
# Both are named as overrides so the convention stays the obvious default.
#
# The Secret lives in Keelson's own namespace unless the entry overrides
# with "namespace".
registry_creds_secret() {
    local cfg=$1 host=$2
    local ns secret key
    ns=$(registry_entry_field "$cfg" namespace)
    if [ -z "$ns" ]; then
        ns=$(registry_own_namespace)
    fi
    if [ -z "$ns" ]; then
        log_error registry-namespace-unknown host="$host" \
            msg="Could not determine Kubernetes namespace to look up the imagePullSecret for registry '$host' (no override set and Keelson's own namespace could not be read from the ServiceAccount mount)."
        return 1
    fi
    secret=$(registry_entry_field "$cfg" secret-name-override)
    [ -z "$secret" ] && secret=$(registry_secret_name_for "$host")
    key=$(registry_entry_field "$cfg" secret-key-override)
    [ -z "$key" ] && key=$host
    registry_creds_from_named_secret "$secret" "$ns" "$key"
}

registry_creds_from_pull_secrets() {
    local ips_json=$1 ns=$2 host=$3
    [ -z "$ips_json" ] && return 1
    [ "$ips_json" = "null" ] && return 1
    local count i name creds
    count=$(printf '%s' "$ips_json" | yq -p=json -o=y 'length // 0')
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        return 1
    fi
    for ((i=0; i<count; i++)); do
        name=$(printf '%s' "$ips_json" | yq -p=json -o=y ".[$i].name")
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
            | yq -p=json -o=y '.auths."'"$host"'".auth // ""')
    if [ -z "$auth" ] || [ "$auth" = "null" ]; then
        return 1
    fi
    printf '%s' "$auth" | base64 -d
}

registry_creds_aws() {
    local host=$1 raw user secret
    raw=$(printf '%s' "$host" | docker-credential-ecr-login get 2>/dev/null) || return 1
    [ -z "$raw" ] && return 1
    user=$(printf '%s' "$raw" | yq -p=json -o=y '.Username')
    secret=$(printf '%s' "$raw" | yq -p=json -o=y '.Secret')
    if [ -z "$user" ] || [ -z "$secret" ]; then
        return 1
    fi
    printf '%s:%s' "$user" "$secret"
}

registry_creds_gcp() {
    local token
    token=$(curl -fsSL -H 'Metadata-Flavor: Google' \
        'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
        2>/dev/null | yq -p=json -o=y '.access_token') || return 1
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        return 1
    fi
    printf 'oauth2accesstoken:%s' "$token"
}

registry_creds_azure() {
    local host=$1
    local fed_file=${AZURE_FEDERATED_TOKEN_FILE:?AZURE_FEDERATED_TOKEN_FILE required for auth-mode azure}
    local tenant=${AZURE_TENANT_ID:?AZURE_TENANT_ID required for auth-mode azure}
    local client=${AZURE_CLIENT_ID:?AZURE_CLIENT_ID required for auth-mode azure}
    local fed_token aad_token refresh
    fed_token=$(cat "$fed_file") || return 1
    aad_token=$(curl -fsSL -X POST \
        "https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token" \
        --data-urlencode "client_id=${client}" \
        --data-urlencode "scope=https://containerregistry.azure.net/.default" \
        --data-urlencode "client_assertion=${fed_token}" \
        --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
        --data-urlencode "grant_type=client_credentials" \
        2>/dev/null | yq -p=json -o=y '.access_token') || return 1
    if [ -z "$aad_token" ] || [ "$aad_token" = "null" ]; then
        return 1
    fi
    refresh=$(curl -fsSL -X POST \
        "https://${host}/oauth2/exchange" \
        --data-urlencode "grant_type=access_token" \
        --data-urlencode "service=${host}" \
        --data-urlencode "access_token=${aad_token}" \
        2>/dev/null | yq -p=json -o=y '.refresh_token') || return 1
    if [ -z "$refresh" ] || [ "$refresh" = "null" ]; then
        return 1
    fi
    printf '00000000-0000-0000-0000-000000000000:%s' "$refresh"
}

# registry_list_tags <image-ref> [creds]
# Echoes one tag per line. Returns non-zero on registry error and sets
# REGISTRY_LAST_ERROR to the whole of skopeo's stderr, so the caller can log
# all of it at debug and a log_hint of it on the error line.
registry_list_tags() {
    local image=$1 creds=${2:-}
    local repo out tmperr
    image_repo "$image"
    repo=$IMAGE_REPO
    tmperr=$(mktemp 2>/dev/null) || tmperr=""
    REGISTRY_LAST_ERROR=""
    if [ -n "$creds" ]; then
        if ! out=$(skopeo list-tags --creds="$creds" "docker://${repo}" 2>"${tmperr:-/dev/null}"); then
            [ -r "$tmperr" ] && REGISTRY_LAST_ERROR=$(<"$tmperr")
            [ -n "$tmperr" ] && rm -f "$tmperr"
            return 1
        fi
    else
        if ! out=$(skopeo list-tags "docker://${repo}" 2>"${tmperr:-/dev/null}"); then
            [ -r "$tmperr" ] && REGISTRY_LAST_ERROR=$(<"$tmperr")
            [ -n "$tmperr" ] && rm -f "$tmperr"
            return 1
        fi
    fi
    [ -n "$tmperr" ] && rm -f "$tmperr"
    printf '%s' "$out" | yq -p=json -o=y '.Tags[]'
}
