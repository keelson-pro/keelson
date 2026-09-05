# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
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

# workload_namespaces
# Sets WORKLOAD_NAMESPACES to the namespaces every lister and watcher works
# over: one empty entry in cluster scope, meaning --all-namespaces, and one
# entry per configured namespace otherwise.
#
# The single place KEELSON_SCOPE is turned into namespaces, so the callers
# below take a namespace and do as they are told. One namespace or fifty is
# then the same code path, and there is no second opinion about what scope
# means.
#
# Commas are tolerated as separators here as well as at boot: the entrypoints
# that do not run validate_config (keelson-user-recheck) read this too, and a
# list that works for the controller has to work for them.
declare -ga WORKLOAD_NAMESPACES=()
workload_namespaces() {
    local raw
    case "${KEELSON_SCOPE:?KEELSON_SCOPE required}" in
        namespace)
            raw=${KEELSON_NAMESPACES:?KEELSON_NAMESPACES required when KEELSON_SCOPE=namespace}
            # shellcheck disable=SC2206
            WORKLOAD_NAMESPACES=(${raw//,/ })
            ;;
        cluster|*)
            WORKLOAD_NAMESPACES=("")
            ;;
    esac
}

# workload_list_kind <kind> [ns]
# Echoes the kubectl JSON list for <kind>. An empty or absent <ns> lists every
# namespace; anything else lists that one.
workload_list_kind() {
    local kind=$1 ns=${2:-}
    if [ -n "$ns" ]; then
        kubectl get "$kind" -n "$ns" -o json
    else
        kubectl get "$kind" --all-namespaces -o json
    fi
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
