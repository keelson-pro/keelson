# Apply-path primitives: build patch documents, call kubectl, optionally
# trigger a CronJob run on a successful update.
# Sourced; not directly executable.
#
# Field-manager mimicry: when the existing image field is owned by an Apply
# manager (a GitOps controller doing server-side apply), Keelson updates
# via SSA under that manager's name and --force-conflicts; when it's owned
# by an Update manager (e.g. legacy kubectl-client-side-apply), Keelson
# patches under that manager's name. With no owner the default manager
# "keelson" is used with a strategic-merge patch.
#
# Depends on (must be sourced first):
#   lib/log.bash, lib/managedfields.bash

# update_patch_json <kind> <container> <new-image>
# Echoes a strategic-merge patch document that updates the named container's
# image. Returns non-zero for unsupported kinds.
update_patch_json() {
    local kind=$1 container=$2 image=$3
    case "$kind" in
        CronJob)
            printf '{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"%s","image":"%s"}]}}}}}}' \
                "$container" "$image"
            ;;
        Deployment|StatefulSet|DaemonSet|ReplicaSet)
            printf '{"spec":{"template":{"spec":{"containers":[{"name":"%s","image":"%s"}]}}}}' \
                "$container" "$image"
            ;;
        *)
            return 1
            ;;
    esac
}

# update_apiversion <kind>
# Echoes the apiVersion for SSA manifests of the given kind.
update_apiversion() {
    case "$1" in
        CronJob) printf 'batch/v1' ;;
        Deployment|StatefulSet|DaemonSet|ReplicaSet) printf 'apps/v1' ;;
        *) return 1 ;;
    esac
}

# update_minimal_manifest <kind> <ns> <name> <container> <image>
# Echoes a minimal YAML manifest suitable for SSA. Only the fields Keelson
# claims ownership over (container name + image) appear.
update_minimal_manifest() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5
    local av
    av=$(update_apiversion "$kind") || return 1
    case "$kind" in
        CronJob)
            cat <<EOF
apiVersion: $av
kind: $kind
metadata:
  name: $name
  namespace: $ns
spec:
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: $container
            image: $image
EOF
            ;;
        *)
            cat <<EOF
apiVersion: $av
kind: $kind
metadata:
  name: $name
  namespace: $ns
spec:
  template:
    spec:
      containers:
      - name: $container
        image: $image
EOF
            ;;
    esac
}

# update_fetch_managed_fields <kind> <ns> <name>
# Fetches the workload's managedFields array as JSON. Used by the CLI path
# (the scanner already has this in hand from its list call).
update_fetch_managed_fields() {
    local kind=$1 ns=$2 name=$3
    kubectl get "$kind" "$name" -n "$ns" -o json 2>/dev/null \
        | yq -p=json -o=json '.metadata.managedFields // []' 2>/dev/null
}

# update_apply <kind> <namespace> <name> <container> <new-image> [managed-fields-json]
# Detects the existing image-field owner and mimics it: SSA for Apply
# operation, strategic-merge patch for Update operation, "keelson" Update
# fallback when no manager claims the field. Logs update-applied or
# update-failed (with the manager/operation pair) and returns 0/1.
update_apply() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5
    local mf_json=${6:-}
    if [ -z "$mf_json" ]; then
        mf_json=$(update_fetch_managed_fields "$kind" "$ns" "$name")
    fi
    local owner manager=keelson operation=Update
    owner=$(managedfields_owner_of_image "$mf_json" "$container")
    if [ -n "$owner" ]; then
        manager=${owner% *}
        operation=${owner##* }
    fi
    case "$operation" in
        Apply)
            update_apply_ssa "$kind" "$ns" "$name" "$container" "$image" "$manager"
            ;;
        Update|*)
            update_apply_patch "$kind" "$ns" "$name" "$container" "$image" "$manager"
            ;;
    esac
}

update_apply_patch() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5 manager=$6
    local patch
    if ! patch=$(update_patch_json "$kind" "$container" "$image"); then
        log_error update-unsupported-kind kind="$kind" ns="$ns" name="$name"
        return 1
    fi
    if kubectl patch "$kind" "$name" -n "$ns" \
            --type=strategic --field-manager="$manager" \
            --patch "$patch" >/dev/null 2>&1; then
        log_info update-applied \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" manager="$manager" operation=Update
        return 0
    fi
    log_error update-failed \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        image="$image" manager="$manager" operation=Update
    return 1
}

update_apply_ssa() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5 manager=$6
    local manifest
    if ! manifest=$(update_minimal_manifest "$kind" "$ns" "$name" "$container" "$image"); then
        log_error update-unsupported-kind kind="$kind" ns="$ns" name="$name"
        return 1
    fi
    if printf '%s' "$manifest" | kubectl apply --server-side \
            --field-manager="$manager" --force-conflicts -f - >/dev/null 2>&1; then
        log_info update-applied \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" manager="$manager" operation=Apply
        return 0
    fi
    log_error update-failed \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        image="$image" manager="$manager" operation=Apply
    return 1
}

# update_trigger_cronjob <namespace> <cronjob-name>
# Creates a one-shot Job from the CronJob, named "<cronjob>-keelson-<ts>".
# Logs cronjob-job-triggered or cronjob-job-trigger-failed. Returns 0/1.
update_trigger_cronjob() {
    local ns=$1 name=$2
    local ts job_name
    ts=$(date -u +%Y%m%d%H%M%S)
    job_name="${name}-keelson-${ts}"
    if kubectl create job "$job_name" \
            --from="cronjob/$name" -n "$ns" >/dev/null 2>&1; then
        log_info cronjob-job-triggered ns="$ns" name="$name" job="$job_name"
        return 0
    fi
    log_error cronjob-job-trigger-failed ns="$ns" name="$name" job="$job_name"
    return 1
}
