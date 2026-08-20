# Apply-path primitives: build patch/apply documents, call kubectl, optionally
# trigger a CronJob run on a successful update.
# Sourced; not directly executable.
#
# Two update methods, one attribution choice:
#
#   patch  - kubectl patch --type=strategic under field-manager=keelson.
#            Adds a Keelson Update entry to managedFields.
#   apply  - kubectl apply --server-side under some field-manager. Adds an
#            Apply entry under whichever manager we pass.
#
# Attribution is binary: the change gets pinned on the detected Apply owner
# ("them", only possible when there is one) or on us ("keelson").
#
# The config surface is a 2x2 quadrant of (detected state, choice):
#
#                              Choice A                Choice B
#   Apply-op owner detected    mimic (apply as them)   patch (patch as us)
#   No Apply-op owner          patch (patch as us)     claim (apply as us)
#
# The three value names are (method, attribution) tuples:
#   mimic - apply, attributed to them. Only offered when an Apply owner
#           exists; refused on unowned (log update-refused-mimic-unowned).
#   patch - patch, attributed to us. The one cell that appears in both
#           rows and is a safe default in either state.
#   claim - apply, attributed to us. Available only in the unowned row;
#           in the owned row that cell is taken by mimic.
#
# The missing "them + patch" cell (patch as OEM) is a legitimate operation
# we don't offer: when we attribute to them, we also match their operation
# type, so mimic always uses SSA.
#
# Selection is per-workload via keelson.pro/field-manager-strategy (with an
# optional .<container> suffix for per-container override), falling back to
# KEELSON_FIELD_MANAGER_STRATEGY_OWNED / _UNOWNED. "Owned" is defined as
# "an Apply-op manager claims the image field" (see lib/managedfields.bash);
# everything else - including Update-op managers, which don't participate
# in SSA conflict resolution - is treated as unowned.
#
# SSA is never force-applied: an ownership conflict logs
# update-apply-conflict and returns non-zero rather than stomping the other
# manager. Fix the source of truth instead.
#
# Depends on (must be sourced first):
#   lib/log.bash, lib/managedfields.bash, lib/annotations.bash

# update_patch_json <kind> <list> <container> <new-image>
# Echoes a strategic-merge patch document that updates the named container's
# image. <list> is "containers" or "initContainers". Returns non-zero for
# unsupported kinds.
update_patch_json() {
    local kind=$1 clist=$2 container=$3 image=$4
    case "$kind" in
        CronJob)
            printf '{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"%s":[{"name":"%s","image":"%s"}]}}}}}}' \
                "$clist" "$container" "$image"
            ;;
        Deployment|StatefulSet|DaemonSet)
            printf '{"spec":{"template":{"spec":{"%s":[{"name":"%s","image":"%s"}]}}}}' \
                "$clist" "$container" "$image"
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
        Deployment|StatefulSet|DaemonSet) printf 'apps/v1' ;;
        *) return 1 ;;
    esac
}

# update_minimal_manifest <kind> <ns> <name> <list> <container> <image>
# Echoes a minimal YAML manifest suitable for SSA. Only the fields Keelson
# claims ownership over (container name + image) appear. <list> is
# "containers" or "initContainers".
update_minimal_manifest() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6
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
          $clist:
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
      $clist:
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

# update_resolve_strategy <annotations> <container> <apply-owner-present>
# Echoes the effective strategy (mimic|patch|claim) OR echoes an empty
# string with a non-zero return when the annotation is present but invalid.
# When the annotation is absent, falls back to the global default for the
# case (owned vs unowned).
update_resolve_strategy() {
    local ann=$1 container=$2 owner_present=$3
    local val=""
    if [ -n "$ann" ]; then
        val=$(annotation_get "$ann" field-manager-strategy "$container")
    fi
    if [ -n "$val" ]; then
        case "$val" in
            mimic|patch|claim) printf '%s' "$val"; return 0 ;;
            *) printf '%s' "$val"; return 2 ;;
        esac
    fi
    if [ "$owner_present" = "1" ]; then
        printf '%s' "${KEELSON_FIELD_MANAGER_STRATEGY_OWNED:-mimic}"
    else
        printf '%s' "${KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED:-patch}"
    fi
}

# update_apply <kind> <namespace> <name> <list> <container> <new-image> <from-tag> [managed-fields-json] [annotation-lines]
# Resolves the effective field-manager strategy and dispatches. Logs
# update-applied / update-failed / update-apply-conflict /
# update-refused-mimic-unowned / update-invalid-strategy-annotation and
# returns 0 on success, 1 otherwise.
update_apply() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6 from_tag=$7
    local mf_json=${8:-} ann=${9:-}
    if [ -z "$mf_json" ]; then
        mf_json=$(update_fetch_managed_fields "$kind" "$ns" "$name")
    fi
    local apply_owner owner_present=0
    apply_owner=$(managedfields_apply_owner_of_image "$mf_json" "$clist" "$container")
    [ -n "$apply_owner" ] && owner_present=1

    local strategy rc
    strategy=$(update_resolve_strategy "$ann" "$container" "$owner_present")
    rc=$?
    if [ $rc -ne 0 ]; then
        log_error update-invalid-strategy-annotation \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            annotation="keelson.pro/field-manager-strategy" value="$strategy" \
            msg="Invalid keelson.pro/field-manager-strategy annotation value '$strategy' on $kind '$name' in '$ns'; must be one of: mimic, patch, claim. Skipping update."
        return 1
    fi

    case "$strategy" in
        mimic)
            if [ "$owner_present" != "1" ]; then
                log_error update-refused-mimic-unowned \
                    kind="$kind" ns="$ns" name="$name" container="$container" \
                    image="$image" \
                    msg="Refusing to update $kind '$name'/$container in '$ns' to image '$image': strategy 'mimic' requires an Apply-op field owner but none was detected."
                return 1
            fi
            update_apply_ssa "$kind" "$ns" "$name" "$clist" "$container" "$image" \
                "$apply_owner" "$from_tag" mimic
            ;;
        patch)
            update_apply_patch "$kind" "$ns" "$name" "$clist" "$container" "$image" \
                keelson "$from_tag" patch
            ;;
        claim)
            update_apply_ssa "$kind" "$ns" "$name" "$clist" "$container" "$image" \
                keelson "$from_tag" claim
            ;;
    esac
}

update_apply_patch() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6 manager=$7 \
          from_tag=$8 strategy=$9
    local to_tag=${image##*:} repo=${image%:*}
    local patch
    if ! patch=$(update_patch_json "$kind" "$clist" "$container" "$image"); then
        log_error update-unsupported-kind kind="$kind" ns="$ns" name="$name" \
            msg="Cannot update $kind '$name' in '$ns': kind not supported."
        return 1
    fi
    if kubectl patch "$kind" "$name" -n "$ns" \
            --type=strategic --field-manager="$manager" \
            --patch "$patch" >/dev/null 2>&1; then
        log_info_always update-applied \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" from="$from_tag" to="$to_tag" repo="$repo" \
            manager="$manager" operation=Update strategy="$strategy" \
            msg="$kind '$name' in '$ns' updated from $from_tag to $to_tag for image '$repo'."
        return 0
    fi
    log_error update-failed \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        image="$image" manager="$manager" operation=Update strategy="$strategy" \
        msg="Could not patch $kind '$name'/$container in '$ns' to image '$image' (manager '$manager', operation Update)."
    return 1
}

update_apply_ssa() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6 manager=$7 \
          from_tag=$8 strategy=$9
    local to_tag=${image##*:} repo=${image%:*}
    local manifest tmperr detail="" reason=""
    if ! manifest=$(update_minimal_manifest "$kind" "$ns" "$name" "$clist" "$container" "$image"); then
        log_error update-unsupported-kind kind="$kind" ns="$ns" name="$name" \
            msg="Cannot update $kind '$name' in '$ns': kind not supported."
        return 1
    fi
    tmperr=$(mktemp 2>/dev/null) || tmperr=/dev/null
    if printf '%s' "$manifest" | kubectl apply --server-side \
            --field-manager="$manager" -f - >/dev/null 2>"$tmperr"; then
        [ "$tmperr" != "/dev/null" ] && rm -f "$tmperr"
        log_info_always update-applied \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" from="$from_tag" to="$to_tag" repo="$repo" \
            manager="$manager" operation=Apply strategy="$strategy" \
            msg="$kind '$name' in '$ns' updated from $from_tag to $to_tag for image '$repo'."
        return 0
    fi
    if [ -r "$tmperr" ] && [ "$tmperr" != "/dev/null" ]; then
        detail=$(<"$tmperr")
        rm -f "$tmperr"
    fi
    # The whole of kubectl's complaint at debug, a clip of it on the error
    # line. A rejected apply lists every conflicting field path and runs to
    # paragraphs; the error below has to stay one readable line.
    log_flatten "$detail"
    log_debug update-apply-failed-detail \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        msg="Server-side apply of $kind '$name'/$container in '$ns' failed, full output: ${LOG_FLAT:-no error output}"
    log_hint "$detail"
    reason=$LOG_HINT
    # Matched on the full text, not the clip: the word that decides this can
    # sit past the clip.
    case "$detail" in
        *conflict*|*Conflict*)
            log_error update-apply-conflict \
                kind="$kind" ns="$ns" name="$name" container="$container" \
                image="$image" manager="$manager" operation=Apply \
                strategy="$strategy" reason="$reason" \
                msg="Server-side apply of $kind '$name'/$container in '$ns' as manager '$manager' rejected on field-ownership conflict; refusing to force. Fix the owning manager's source of truth."
            ;;
        *)
            log_error update-failed \
                kind="$kind" ns="$ns" name="$name" container="$container" \
                image="$image" manager="$manager" operation=Apply \
                strategy="$strategy" reason="$reason" \
                msg="Could not server-side apply $kind '$name'/$container in '$ns' to image '$image' (manager '$manager', operation Apply)."
            ;;
    esac
    return 1
}

# update_trigger_cronjob <namespace> <cronjob-name> [<from-tag> <to-tag> <repo>]
# Creates a one-shot Job from the CronJob, named "<cronjob>-keelson-<ts>".
# Logs cronjob-job-triggered or cronjob-job-trigger-failed. Returns 0/1.
# When from/to/repo are supplied (a scan-triggered update preceded this), the
# log sentence includes the version delta; otherwise it stays concise.
update_trigger_cronjob() {
    local ns=$1 name=$2 from_tag=${3:-} to_tag=${4:-} repo=${5:-}
    local ts job_name
    # Match the K8s CronJob controller naming: <cronjob>-<unix-seconds>.
    # No "keelson" infix - operators expect Job names that read like any
    # other Job they create with `kubectl create job --from=cronjob/...`.
    ts=$(date -u +%s)
    job_name="${name}-${ts}"
    local msg
    if [ -n "$from_tag" ] && [ -n "$to_tag" ] && [ -n "$repo" ]; then
        msg="Job '$job_name' created from CronJob '$name' in '$ns' with update from $from_tag to $to_tag for image '$repo'."
    else
        msg="Job '$job_name' created from CronJob '$name' in '$ns'."
    fi
    if kubectl create job "$job_name" \
            --from="cronjob/$name" -n "$ns" >/dev/null 2>&1; then
        log_info_always cronjob-job-triggered \
            ns="$ns" name="$name" job="$job_name" \
            from="$from_tag" to="$to_tag" repo="$repo" \
            msg="$msg"
        return 0
    fi
    log_error cronjob-job-trigger-failed ns="$ns" name="$name" job="$job_name" \
        msg="Could not create Job '$job_name' from CronJob '$name' in '$ns'."
    return 1
}
