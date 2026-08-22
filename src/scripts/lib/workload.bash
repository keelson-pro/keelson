# kubectl helpers and per-kind path resolution.
# Sourced; not directly executable.
#
# Watched kinds: Deployment, StatefulSet, DaemonSet, CronJob.
# ReplicaSet is intentionally NOT watched: a Deployment-owned ReplicaSet
# inherits the Deployment's annotations, so watching both would cause
# Keelson to operate on the same container twice. Bare ReplicaSets (no
# Deployment) are not supported; convert them to a Deployment first.
# Rollouts deferred to the listener stage.

# KEELSON_WATCHED_KINDS is required at runtime; validate_config enforces it
# at boot. Module-level reads would block --help so we defer the check.

# workload_list_kind <kind>
# Echoes the kubectl JSON list for <kind>, scope-aware (KEELSON_SCOPE).
# workload_managed_fields <kind> <ns> <name>
# Echoes the workload's managedFields as compact JSON, or "[]" if it has
# none. Fetched at poll time rather than cached: it changes whenever anyone
# writes the object, so a stale copy would drive the field-manager strategy
# to the wrong owner.
workload_managed_fields() {
    local kind=$1 ns=$2 name=$3
    kubectl get "$kind" -n "$ns" "$name" -o json 2>/dev/null \
        | yq -p=json -o=json -I=0 '.metadata.managedFields // []'
}

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

# workload_get_one <kind> <ns> <name>
# Echoes the kubectl JSON for a single workload, in the same List shape
# workload_list_kind returns so the same extraction reads either.
#
# A field selector rather than naming the resource directly: `kubectl get X
# name` returns the bare object and errors when it is absent, while this
# returns a list with one item or none. A workload deleted between the event
# and this read is then an empty list rather than a failure to explain.
workload_get_one() {
    local kind=$1 ns=$2 name=$3
    kubectl get "$kind" -n "$ns" --field-selector "metadata.name=$name" -o json
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
        Deployment|StatefulSet|DaemonSet)
            printf '.spec.template.spec'
            ;;
        *)
            return 1
            ;;
    esac
}

# workload_is_watched <kind>
# Returns 0 if Keelson watches this kind, 1 otherwise.
workload_is_watched() {
    case " $KEELSON_WATCHED_KINDS " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}
