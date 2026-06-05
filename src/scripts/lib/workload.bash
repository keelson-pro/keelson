# kubectl helpers and per-kind path resolution.
# Sourced; not directly executable.
#
# Watched kinds (Stage 3): Deployment, StatefulSet, DaemonSet, ReplicaSet, CronJob.
# Rollouts deferred to the listener stage.

# KEELSON_WATCHED_KINDS is required at runtime; validate_config enforces it
# at boot. Module-level reads would block --help so we defer the check.

# workload_list_kind <kind>
# Echoes the kubectl JSON list for <kind>, scope-aware (KEELSON_SCOPE).
workload_list_kind() {
    local kind=$1
    case "${KEELSON_SCOPE:?KEELSON_SCOPE required}" in
        namespace)
            kubectl get "$kind" \
                -n "${KEELSON_NAMESPACE:?KEELSON_NAMESPACE required when KEELSON_SCOPE=namespace}" \
                -o json
            ;;
        cluster|*)
            kubectl get "$kind" --all-namespaces -o json
            ;;
    esac
}

# workload_pod_spec_path <kind>
# Echoes the yq path expression to the pod spec under a single resource.
# CronJob nests its pod template under spec.jobTemplate; everything else uses
# spec.template.spec directly.
workload_pod_spec_path() {
    case "$1" in
        CronJob)
            printf '.spec.jobTemplate.spec.template.spec'
            ;;
        Deployment|StatefulSet|DaemonSet|ReplicaSet)
            printf '.spec.template.spec'
            ;;
        *)
            return 1
            ;;
    esac
}

# workload_containers_path <kind>
# Echoes the yq path to the containers array under a single resource.
workload_containers_path() {
    local base
    base=$(workload_pod_spec_path "$1") || return 1
    printf '%s.containers' "$base"
}

# workload_image_pull_secrets_path <kind>
# Echoes the yq path to the imagePullSecrets array under a single resource.
workload_image_pull_secrets_path() {
    local base
    base=$(workload_pod_spec_path "$1") || return 1
    printf '%s.imagePullSecrets' "$base"
}

# workload_service_account_name_path <kind>
# Echoes the yq path to the serviceAccountName string under a single resource.
workload_service_account_name_path() {
    local base
    base=$(workload_pod_spec_path "$1") || return 1
    printf '%s.serviceAccountName' "$base"
}

# workload_is_watched <kind>
# Returns 0 if Keelson watches this kind, 1 otherwise.
workload_is_watched() {
    case " $KEELSON_WATCHED_KINDS " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}
