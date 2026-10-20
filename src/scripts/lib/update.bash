# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# Apply-path primitives: build patch/apply documents, call kubectl, optionally
# trigger a CronJob run on a successful update.
# Sourced; not directly executable.
#
# Who owns the image field decides what a write can be. The owner is the one
# entry managedfields_image_owner picks from managedFields just before
# writing (see lib/managedfields.bash: keelson's own entries rank below any
# other manager's), and the state follows that owner's operation:
#
#   apply-owned   the owner's entry is an Apply (server-side apply)
#   update-owned  the owner's entry is an Update (a patch, an edit,
#                 client-side apply, Helm), even with keelson's Apply entry
#                 holding the image too
#   unowned       nobody, which in practice means managedFields were stripped
#
# Each state has its own setting, KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED,
# _UPDATE_OWNED and _UNOWNED, and keelson.pro/field-manager-strategy
# overrides it per workload, or per target as
# keelson.pro/field-manager-strategy.containers.<name> or .volumes.<name>
# (camelCase fieldManagerStrategy works too). Three values:
#
#   mimic        as the owner, by the owner's own method: on apply-owned an
#                apply of the owner's whole set with the image changed, on
#                update-owned a JSON patch under the owner's name. The owner
#                keeps what it owns. The apply is forced only past co-owners
#                that do not apply the fields (Update entries, keelson), and
#                then only after a forced dry run passes the same guard; a
#                second applier is refused, never forced. Not accepted for the
#                unowned setting; an annotation asking for it on a workload
#                that turns out unowned claims the image as claim-patch would,
#                or refuses when
#                KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED
#                is false. A claim needs no such setting: it works by its own
#                method in every state.
#   claim-patch  a JSON patch as keelson, taking the image from any owner.
#   claim-apply  an apply as keelson of everything keelson already applies on
#                the object with this image set in it, always forced: a claim
#                is the operator saying the field is ours.
#
# Either claim against an Apply owner makes that owner's next non-forced
# apply of a different tag conflict. That is the choice the operator made, so
# it is said once at boot beside the setting, and not on every write. An
# Update owner is never refused anything, so claiming from one costs it no
# conflict.
#
# Every write changes the image and nothing else. A patch tests the element
# it changes; mimic's apply proves, by a server-side dry run, that the
# owner's set comes back as it was, less exactly the owned fields the server
# had already dropped (zero values, absent live, so the object does not
# change). Neither depends on the kind, so custom resources are written
# exactly as built-in ones are.
#
# Depends on (must be sourced first):
#   lib/log.bash, lib/managedfields.bash, lib/annotations.bash

# update_apiversion <kind>
# Echoes the apiVersion for SSA manifests of the given kind.
update_apiversion() {
    case "$1" in
        CronJob) printf 'batch/v1' ;;
        Deployment|StatefulSet|DaemonSet) printf 'apps/v1' ;;
        Rollout) printf 'argoproj.io/v1alpha1' ;;
        *) return 1 ;;
    esac
}

# update_resource_name <kind>
# The resource kubectl get and patch are given for <kind>, qualified by its
# API group. A bare kind is resolved by kubectl itself, and another CRD can
# share the name (OpenKruise has a Rollout too); the qualified resource can
# only mean the one Keelson reads and writes. apply needs nothing: the
# manifest's apiVersion and kind already say which. Kind names stay bare
# everywhere else (settings, logs, manifests).
update_resource_name() {
    case "$1" in
        Deployment) printf 'deployments.apps' ;;
        StatefulSet) printf 'statefulsets.apps' ;;
        DaemonSet) printf 'daemonsets.apps' ;;
        CronJob) printf 'cronjobs.batch' ;;
        Rollout) printf 'rollouts.argoproj.io' ;;
        *) return 1 ;;
    esac
}

# update_minimal_manifest <kind> <ns> <name> <list> <container> <image>
# Echoes a minimal YAML manifest suitable for SSA. Only the fields Keelson
# claims ownership over (container name + image) appear. Values are quoted:
# a name such as 123, on or null would otherwise read back as a number, a
# bool or nothing. <list> is
# "containers", "initContainers" or "imageVolumes".
update_minimal_manifest() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6
    local av
    av=$(update_apiversion "$kind") || return 1
    if [ "$clist" = "imageVolumes" ]; then
        local indent="    " prefix="  template:"
        if [ "$kind" = "CronJob" ]; then
            indent="          "
            prefix="  jobTemplate:
    spec:
      template:"
        fi
        cat <<EOF
apiVersion: $av
kind: $kind
metadata:
  name: "$name"
  namespace: "$ns"
spec:
${prefix:+$prefix
}${indent}spec:
${indent}  volumes:
${indent}  - name: "$container"
${indent}    image:
${indent}      reference: "$image"
EOF
        return 0
    fi
    case "$kind" in
        CronJob)
            cat <<EOF
apiVersion: $av
kind: $kind
metadata:
  name: "$name"
  namespace: "$ns"
spec:
  jobTemplate:
    spec:
      template:
        spec:
          $clist:
          - name: "$container"
            image: "$image"
EOF
            ;;
        *)
            cat <<EOF
apiVersion: $av
kind: $kind
metadata:
  name: "$name"
  namespace: "$ns"
spec:
  template:
    spec:
      $clist:
      - name: "$container"
        image: "$image"
EOF
            ;;
    esac
}

# update_fetch_managed_fields <kind> <ns> <name>  -> UPDATE_MANAGED_FIELDS
# Sets a global rather than printing, so kubectl's complaint (UPDATE_ERR)
# survives to be logged when the read fails.
# Fetches the workload's managedFields array as JSON, read just before every
# write: nothing upstream holds a usable copy (a list read leaves them out,
# and the cache deliberately does not keep them).
#
# kubectl emits the JSON itself rather than the whole object being piped
# through yq. This is the most expensive moment Keelson has: a pipe holds
# kubectl at ~52MB resident and yq at ~22MB at the same time, per updating
# child and times the poll concurrency, and that sum is what the memory limit
# has to cover. A deployment running at 250Mi took thirty OOM kills in under
# four days.
#
# The [*] matters. jsonpath returns a result set, so asking for
# .metadata.managedFields yields one result that is itself the array and
# renders as [[...]]; the extra level makes managedfields_image_owner
# find no owner at all and routes every update to the unowned strategy. [*]
# makes each entry its own result, giving the flat array callers expect.
#
# Empty output means the object carries no managedFields, which is an empty
# array rather than an error.
declare -g UPDATE_MANAGED_FIELDS=""
update_fetch_managed_fields() {
    local kind=$1 ns=$2 name=$3 resource
    UPDATE_MANAGED_FIELDS=""
    resource=$(update_resource_name "$kind") || return 1
    update_kubectl "" get "$resource" "$name" -n "$ns" \
        -o 'jsonpath-as-json={.metadata.managedFields[*]}' || return 1
    UPDATE_MANAGED_FIELDS=${UPDATE_OUT:-[]}
    return 0
}

# update_resolve_strategy <annotations> <list> <container> <state>  -> UPDATE_RESOLVED
# The effective strategy for <state> (apply-owned, update-owned or unowned)
# and where it came from, as "<strategy> annotated" or "<strategy>
# configured". Returns 2, with the bare value, when the annotation's is not
# one Keelson knows, or REJECT:<why> when it cannot be read. The settings
# themselves were checked at boot.
#
# Set rather than echoed: run in a subshell, the annotation lookup's own
# warnings lost their throttle stamps and repeated on every update.
#
# An image volume's annotations live under .volumes.<name>, a container's
# under .containers.<name>: a pod may hold both under one name, so the list
# says which one is being asked about.
# UPDATE_RESOLVED_KEY is the annotation the value was read from, as
# written on the workload (spelling and scope), empty when none was read.
declare -g UPDATE_RESOLVED="" UPDATE_RESOLVED_KEY=""
update_resolve_strategy() {
    local ann=$1 clist=$2 container=$3 state=$4
    local val="" atarget=containers
    [ "$clist" = "imageVolumes" ] && atarget=volumes
    UPDATE_RESOLVED="" UPDATE_RESOLVED_KEY=""
    if [ -n "$ann" ]; then
        ANNOTATION_VALUE="" ANNOTATION_KEY=""
        if ! annotation_get "$ann" fieldManagerStrategy "$container" "$atarget"; then
            UPDATE_RESOLVED="REJECT:annotation-read-failed"
            return 2
        fi
        val=$ANNOTATION_VALUE
        UPDATE_RESOLVED_KEY=$ANNOTATION_KEY
    fi
    if [ -n "$val" ]; then
        case "$val" in
            mimic|claim-patch|claim-apply) UPDATE_RESOLVED="$val annotated"; return 0 ;;
            *) UPDATE_RESOLVED=$val; return 2 ;;
        esac
    fi
    # Unset reads as empty, which the dispatcher refuses by name.
    case "$state" in
        apply-owned) UPDATE_RESOLVED="${KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED:-} configured" ;;
        update-owned) UPDATE_RESOLVED="${KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED:-} configured" ;;
        *) UPDATE_RESOLVED="${KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED:-} configured" ;;
    esac
}

# update_apply <kind> <namespace> <name> <list> <container> <new-image> <from-tag> [managed-fields-json] [annotation-lines]
# Finds who owns the image, resolves the strategy for that state and
# dispatches. Logs update-applied / update-failed / update-apply-conflict /
# update-mimic-refused / update-invalid-strategy-annotation /
# update-invalid-strategy / update-unsupported-kind / update-claim-refused /
# update-image-moved / update-owner-moved / update-already-applied /
# update-workload-gone / update-tempfile-failed, and at debug update-retry
# and the *-detail lines behind its refusals. Returns 0 on success, 3 when it
# deliberately wrote nothing and nothing is wrong (the image or its owner
# moved since the poll, it already runs the target, or the workload is
# gone), 1 otherwise.
update_apply() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6 from_tag=$7
    local mf_json=${8:-} ann=${9:-}
    UPDATE_OUTCOME="Nothing was written."
    # Before anything is read: every write needs the kind's shape.
    if ! update_apiversion "$kind" >/dev/null; then
        log_error update-unsupported-kind kind="$kind" ns="$ns" name="$name" \
            msg="Cannot update $kind '$name' in '$ns': kind not supported. ${UPDATE_OUTCOME}"
        return 1
    fi
    # Who owns the image decides the write, so not knowing is not "nobody":
    # read as unowned, it would claim an image somebody holds.
    if [ -z "$mf_json" ]; then
        if ! update_fetch_managed_fields "$kind" "$ns" "$name"; then
            if update_is_gone "$UPDATE_ERR" "$kind" "$ns" "$name"; then
                update_log_gone "$kind" "$ns" "$name" "$container" "$image"
                return 3
            fi
            log_flatten "$UPDATE_ERR"
            log_error update-failed \
                kind="$kind" ns="$ns" name="$name" container="$container" image="$image" \
                msg="Could not read who owns the image of $kind '$name'/$container in '$ns', so the right way to write it is unknown${LOG_FLAT:+: $LOG_FLAT}. ${UPDATE_OUTCOME}"
            return 1
        fi
        mf_json=$UPDATE_MANAGED_FIELDS
    fi
    if ! managedfields_image_owner "$mf_json" "$clist" "$container"; then
        log_error update-failed \
            kind="$kind" ns="$ns" name="$name" container="$container" image="$image" \
            msg="Could not make sense of who owns the image of $kind '$name'/$container in '$ns', so the right way to write it is unknown. ${UPDATE_OUTCOME}"
        return 1
    fi
    local owner=$MANAGEDFIELDS_OWNER state
    # What the strategy is chosen from. Every write path checks its own
    # fresh read against it: a write chosen for one owner must not land on
    # an image that has another by then.
    UPDATE_EXPECT_OWNER=$MANAGEDFIELDS_OWNER
    UPDATE_EXPECT_OPERATION=$MANAGEDFIELDS_OWNER_OPERATION
    case "$MANAGEDFIELDS_OWNER_OPERATION" in
        Apply) state=apply-owned ;;
        Update) state=update-owned ;;
        *) state=unowned ;;
    esac

    # Called with || so set -e in an entry script cannot end the run here
    # before the reason is logged.
    local strategy rc=0
    # The workload, for the lookup's own lines (a spelling conflict is said
    # there, once, and must name it).
    ANNOTATION_CTX_KIND=$kind ANNOTATION_CTX_NS=$ns ANNOTATION_CTX_NAME=$name
    update_resolve_strategy "$ann" "$clist" "$container" "$state" || rc=$?
    ANNOTATION_CTX_KIND= ANNOTATION_CTX_NS= ANNOTATION_CTX_NAME=
    strategy=$UPDATE_RESOLVED
    # The annotation as set on the workload, so the message points at the
    # key the operator wrote; the canonical spelling when none was read.
    local akey=${UPDATE_RESOLVED_KEY:-keelson.pro/field-manager-strategy}
    if [ $rc -ne 0 ]; then
        case "$strategy" in
            REJECT:dual-prefix-conflict)
                log_error update-invalid-strategy-annotation \
                    kind="$kind" ns="$ns" name="$name" container="$container" \
                    reason="dual-prefix-conflict" \
                    msg="$kind '$name' in '$ns' carries both keelson.pro/ and keel.sh/ annotations, so none of them can be trusted. Skipping update; nothing was written."
                ;;
            # The lookup has already said, once, that the two spellings
            # disagree: a second line here would only repeat it.
            REJECT:annotation-spelling-conflict) ;;
            REJECT:*)
                log_error update-invalid-strategy-annotation \
                    kind="$kind" ns="$ns" name="$name" container="$container" \
                    annotation="$akey" reason="${strategy#REJECT:}" \
                    msg="The $akey annotation on $kind '$name' in '$ns' cannot be used (${strategy#REJECT:}). Skipping update; nothing was written."
                ;;
            *)
                log_error update-invalid-strategy-annotation \
                    kind="$kind" ns="$ns" name="$name" container="$container" \
                    annotation="$akey" value="$strategy" \
                    msg="Invalid $akey annotation value '$strategy' on $kind '$name' in '$ns'; must be one of: mimic, claim-patch, claim-apply. Skipping update; nothing was written."
                ;;
        esac
        return 1
    fi
    # "as annotated" or "as configured", for the line that says what was done.
    UPDATE_STRATEGY_SOURCE=${strategy##* }
    strategy=${strategy% *}

    case "$strategy:$state" in
        mimic:apply-owned)
            update_apply_mimic "$kind" "$ns" "$name" "$clist" "$container" "$image" \
                "$owner" "$from_tag"
            ;;
        mimic:update-owned)
            update_apply_patch "$kind" "$ns" "$name" "$clist" "$container" "$image" \
                "$owner" "$from_tag" mimic
            ;;
        mimic:unowned)
            # Only an annotation gets here: it names a strategy for every
            # state, and boot validation keeps mimic out of the unowned
            # setting. Nobody to be, so nothing to keep as it was: claimed,
            # by the simplest write there is, unless the operator said not to.
            if [ "${KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED:-}" != "true" ]; then
                update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "" \
                    "nobody owns the image to be, and falling back from an annotated mimic is not allowed" ""
                return 1
            fi
            update_apply_patch "$kind" "$ns" "$name" "$clist" "$container" "$image" \
                keelson "$from_tag" mimic "claim-patch (fallback from mimic)"
            ;;
        claim-patch:*)
            update_apply_patch "$kind" "$ns" "$name" "$clist" "$container" "$image" \
                keelson "$from_tag" claim-patch
            ;;
        claim-apply:*)
            # Forced even with no owner: on an object with no managedFields
            # the server first records every field under an Update entry
            # called before-first-apply, and an unforced apply that changes
            # the image conflicts with it. A claim takes the field anyway.
            update_apply_ssa "$kind" "$ns" "$name" "$clist" "$container" "$image" \
                keelson "$from_tag" claim-apply force
            ;;
        *)
            # Boot validation makes this unreachable, and it stays a refusal
            # rather than falling out of the case as a success that wrote
            # nothing.
            log_error update-invalid-strategy \
                kind="$kind" ns="$ns" name="$name" container="$container" \
                state="$state" value="$strategy" \
                msg="No usable field-manager strategy for $kind '$name'/$container in '$ns' (state $state, value '$strategy'). Skipping update; nothing was written."
            return 1
            ;;
    esac
}

declare -g UPDATE_STRATEGY_SOURCE=configured

# update_check_owner <kind> <ns> <name> <list> <container> <image> <manager> <strategy> <operation> <live-json>
# The image's owner on this fresh read must be the one the strategy was
# chosen from (UPDATE_EXPECT_OWNER / _OPERATION, set by update_apply). A
# change since is nothing wrong but means the choice no longer holds:
# returns 3, logged at warn. 1 when the owner cannot be read again.
declare -g UPDATE_EXPECT_OWNER="" UPDATE_EXPECT_OPERATION=""
update_check_owner() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6 manager=$7 \
          strategy=$8 operation=$9 live=${10} mf
    if ! mf=$(printf '%s' "$live" | yq -p=json -o=json -I0 '.metadata.managedFields // []' 2>/dev/null) \
            || ! managedfields_image_owner "$mf" "$clist" "$container"; then
        if [ "$strategy" = mimic ]; then
            update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
                "who owns the image could not be read again" "" "$operation"
        else
            update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
                "$strategy" "who owns the image could not be read again" "" "$operation"
        fi
        return 1
    fi
    if [ "$MANAGEDFIELDS_OWNER" != "$UPDATE_EXPECT_OWNER" ] \
            || [ "$MANAGEDFIELDS_OWNER_OPERATION" != "$UPDATE_EXPECT_OPERATION" ]; then
        update_log_owner_moved "$kind" "$ns" "$name" "$container" "$image" "$manager"
        return 3
    fi
}

# update_with_retries <kind-of-refusal> <once-function> <kind> <ns> <name> <list> <container> <args...>
# Up to three tries of one read-and-write. A try returns 0 written, 1 failed
# (logged), 2 the object moved or the write was refused (worth reading
# again), 3 deliberately not written, or 4 the image already is the target.
# A rollout in progress keeps bumping the object, so one retry is not
# always enough to get a read and its write in between.
#
# Returns 0, 1 or 3, or 2 when every try came back 2, for the caller to say
# so in its own terms. A 4 on the first try is someone else's change (3). On
# a later one it depends on <kind-of-refusal>: "maybe-written" (a failed
# patch, which a timeout can report though it landed) counts it as ours
# (0), so the scan records it; "not-written" (a stale-resourceVersion 409,
# which never lands) counts it as someone else's (3).
declare -g UPDATE_OUTCOME="Nothing was written."
update_with_retries() {
    local refusal=$1 once=$2
    shift 2
    local kind=$1 ns=$2 name=$3 container=$5 attempt rc
    UPDATE_OUTCOME="Nothing was written."
    for attempt in 1 2 3; do
        rc=0
        "$once" "$@" || rc=$?
        case "$rc" in
            0) return 0 ;;
            # Ours only if an earlier try may have landed: a 409 on a
            # resourceVersion precondition never did, so then it is someone
            # else's change.
            4) if (( attempt > 1 )) && [ "$refusal" = maybe-written ]; then
                   log_info_always update-applied \
                       kind="$kind" ns="$ns" name="$name" container="$container" \
                       image="$6" from="$8" to="${6##*:}" repo="${6%:*}" \
                       manager="$7" operation=Update strategy="$9" \
                       msg="$kind '$name' in '$ns' updated from $8 to ${6##*:} by ${10:-"$9 (as ${UPDATE_STRATEGY_SOURCE:-configured})"} for image '${6%:*}': an earlier try that reported failure landed after all."
                   return 0
               fi
               log_info update-already-applied \
                   kind="$kind" ns="$ns" name="$name" container="$container" image="$6" \
                   msg="$kind '$name'/$container in '$ns' already runs '$6'; nothing to write."
               return 3 ;;
            # A failed patch may have landed: a later try that fails before
            # writing must not claim nothing was written.
            2) [ "$refusal" = maybe-written ] \
                   && UPDATE_OUTCOME="An earlier try may have landed; the next poll will see." ;;
            *) return "$rc" ;;
        esac
        (( attempt < 3 )) && log_debug update-retry \
            kind="$kind" ns="$ns" name="$name" container="$container" attempt="$attempt" \
            msg="$kind '$name'/$container in '$ns' changed or the write was refused; reading it again."
    done
    return 2
}

# update_apply_patch <kind> <ns> <name> <list> <container> <image> <manager> <from-tag> <strategy> [<method>]
# <method> is how the success line describes the write when it is not the
# configured strategy itself.
# The image changed by a JSON patch under <manager>, an Update operation that
# touches that one field. A JSON patch needs no merge directives, so it works
# on custom resources as well as built-in kinds, and a write by patch is a patch
# on every kind rather than falling back to something else on some.
#
# It addresses the element by index, so the object is read first and the
# patch tests the element's name and current image before replacing it: if
# the list moved in between, the whole patch is refused rather than landing
# on the wrong element. A refusal, or any other failure, earns another read
# and try, since which of kubectl's messages a failed test produces is not
# something to depend on.
update_apply_patch() {
    local kind=$1 ns=$2 name=$3 container=$5 image=$6 manager=$7 strategy=$9
    local rc=0
    update_with_retries maybe-written update_patch_once "$@" || rc=$?
    [ "$rc" -eq 2 ] || return "$rc"
    # Same shape as the apply path: the whole complaint at debug, a clip of it
    # on the error line. Discarding it entirely left every failure looking
    # alike, so a patch the server refused outright read no differently from
    # one it merely lost a race on.
    # Each try's whole complaint was logged at debug as it failed.
    local detail=$UPDATE_PATCH_DETAIL reason
    log_hint "$detail"
    reason=$LOG_HINT
    log_error update-failed \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        image="$image" manager="$manager" operation=Update strategy="$strategy" \
        detail="$reason" \
        msg="Could not patch $kind '$name'/$container in '$ns' to image '$image' (manager '$manager', operation Update)${reason:+: $reason}. It may have been written regardless; the next poll will see."
    return 1
}

# update_patch_once <kind> <ns> <name> <list> <container> <image> <manager> <from-tag> <strategy> [<method>]
# One read and patch. Returns 0 on success, 2 when kubectl refused the patch
# (its complaint left in UPDATE_PATCH_DETAIL), 3 when it was deliberately not
# written (the image or its owner moved, or the workload is gone since the
# poll), 4 when the image already is the target, 1 on anything else, logged.
declare -g UPDATE_PATCH_DETAIL=""
update_patch_once() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6 manager=$7 \
          from_tag=$8 strategy=$9 method=${10:-"$9 (as ${UPDATE_STRATEGY_SOURCE:-configured})"}
    local to_tag=${image##*:} repo=${image%:*} rc resource
    UPDATE_PATCH_DETAIL=""
    resource=$(update_resource_name "$kind") || resource=$kind
    if ! update_kubectl "" get "$resource" "$name" -n "$ns" -o json --show-managed-fields; then
        if update_is_gone "$UPDATE_ERR" "$kind" "$ns" "$name"; then
            update_log_gone "$kind" "$ns" "$name" "$container" "$image"
            return 3
        fi
        log_flatten "$UPDATE_ERR"
        log_error update-failed \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" manager="$manager" operation=Update strategy="$strategy" \
            msg="Could not read $kind '$name' in '$ns' to patch it: ${LOG_FLAT:-no error output}. ${UPDATE_OUTCOME}"
        return 1
    fi
    update_check_polled "$kind" "$ns" "$name" "$clist" "$container" "$image" \
        "$from_tag" "$UPDATE_OUT" || return
    update_check_owner "$kind" "$ns" "$name" "$clist" "$container" "$image" \
        "$manager" "$strategy" Update "$UPDATE_OUT" || return
    rc=0
    update_json_patch "$kind" "$clist" "$container" "$image" "$UPDATE_OUT" || rc=$?
    if [ "$rc" -eq 3 ]; then
        log_error update-unsupported-kind kind="$kind" ns="$ns" name="$name" \
            msg="Cannot update $kind '$name' in '$ns': kind not supported. ${UPDATE_OUTCOME}"
        return 1
    elif [ "$rc" -ne 0 ]; then
        log_error update-failed \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" manager="$manager" operation=Update strategy="$strategy" \
            msg="Could not patch $kind '$name'/$container in '$ns': it has no single element named '$container' with an image to change. ${UPDATE_OUTCOME}"
        return 1
    fi
    # stderr into the capture, stdout to /dev/null, in that order.
    if UPDATE_PATCH_DETAIL=$(kubectl patch "$resource" "$name" -n "$ns" \
            --type=json --field-manager="$manager" \
            --patch "$UPDATE_JSON_PATCH" 2>&1 >/dev/null); then
        log_info_always update-applied \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" from="$from_tag" to="$to_tag" repo="$repo" \
            manager="$manager" operation=Update strategy="$strategy" \
            msg="$kind '$name' in '$ns' updated from $from_tag to $to_tag by $method for image '$repo'."
        return 0
    fi
    # Deleted between the read and the patch: nothing landed, nothing to do.
    if update_is_gone "$UPDATE_PATCH_DETAIL" "$kind" "$ns" "$name"; then
        update_log_gone "$kind" "$ns" "$name" "$container" "$image"
        return 3
    fi
    # Logged per try: a later try that ends the call another way (it landed
    # after all, or the image moved) would otherwise lose why this one failed.
    log_flatten "$UPDATE_PATCH_DETAIL"
    log_debug update-patch-failed-detail \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        msg="Patch of $kind '$name'/$container in '$ns' failed, full output: ${LOG_FLAT:-no error output}"
    return 2
}

# update_json_patch <kind> <list> <container> <new-image> <live-json>  -> UPDATE_JSON_PATCH
# A JSON patch (RFC 6902) changing the named element's image in <live-json>:
# test its name, test its current image, replace the image. <list> is
# "containers", "initContainers" or "imageVolumes". Returns 3 for a kind
# Keelson does not update, 1 unless exactly one element by that name carries
# an image.
declare -g UPDATE_JSON_PATCH=""
update_json_patch() {
    local kind=$1 clist=$2 container=$3 image=$4 live=$5
    local pod ptr list=$clist leaf='.image' leafptr='/image' out count
    UPDATE_JSON_PATCH=""
    case "$kind" in
        CronJob)
            pod='.spec.jobTemplate.spec.template.spec'
            ptr='/spec/jobTemplate/spec/template/spec'
            ;;
        Deployment|StatefulSet|DaemonSet|Rollout)
            pod='.spec.template.spec'
            ptr='/spec/template/spec'
            ;;
        *) return 3 ;;
    esac
    if [ "$clist" = "imageVolumes" ]; then
        list=volumes
        leaf='.image.reference'
        leafptr='/image/reference'
    fi
    # The count and the patch from one yq, a line each. The matches are
    # bound as an array, which is always one value, so none is a count of 0
    # rather than yq carrying on with nulls.
    out=$(printf '%s' "$live" | CONTAINER=$container IMAGE=$image \
        PTR="${ptr}/${list}/" LEAFPTR=$leafptr yq -p=json -o=yaml "
        [(${pod}.${list} // []) | to_entries | .[]
            | select(.value.name == strenv(CONTAINER) and .value${leaf} != null)] as \$m
        | (\$m | length | tostring) + \"\\n\" + ([
            {\"op\": \"test\", \"path\": strenv(PTR) + (\$m[0].key | tostring) + \"/name\", \"value\": strenv(CONTAINER)},
            {\"op\": \"test\", \"path\": strenv(PTR) + (\$m[0].key | tostring) + strenv(LEAFPTR), \"value\": \$m[0].value${leaf}},
            {\"op\": \"replace\", \"path\": strenv(PTR) + (\$m[0].key | tostring) + strenv(LEAFPTR), \"value\": strenv(IMAGE)}
          ] | to_json(0))" 2>/dev/null) || return 1
    count=${out%%$'\n'*}
    [ "$count" = "1" ] || return 1
    UPDATE_JSON_PATCH=${out#*$'\n'}
}


# update_apply_ssa <kind> <ns> <name> <list> <container> <image> <manager> <from-tag> <strategy> [force]
# The image applied as <manager>, together with everything <manager> already
# applies on the object. An apply is the manager's whole intent: this image
# sent alone would take from <manager> every other field it applied, and
# after a forced claim nobody else holds those, so the server deletes them
# (a claimed sidecar image would vanish when the main one is claimed next).
# So <manager>'s existing set is rebuilt from the live values, as mimic does
# for an owner, and this image is set in it, or added to it when it is not
# there yet. With no existing set the image goes alone.
#
# "force" takes the image from whoever holds it: only a claim asks for that.
# The object is read fresh
# and its resourceVersion sent as a precondition; when it moved in between,
# it is read again and the whole thing retried (update_with_retries).
update_apply_ssa() {
    local kind=$1 ns=$2 name=$3 container=$5 image=$6 manager=$7 strategy=$9
    local rc=0
    update_with_retries not-written update_ssa_once "$@" || rc=$?
    [ "$rc" -eq 2 ] || return "$rc"
    log_error update-failed \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        image="$image" manager="$manager" operation=Apply strategy="$strategy" \
        reason="object kept changing" \
        msg="Could not update $kind '$name'/$container in '$ns' to image '$image' as manager '$manager': it changed between read and write three times running. Nothing was written; trying again next poll."
    return 1
}

# update_ssa_once <kind> <ns> <name> <list> <container> <image> <manager> <from-tag> <strategy> [force]
# One read and apply. Returns 0 on success, 2 when the object moved since it
# was read, 3 or 4 from update_check_polled, 3 from update_check_owner, 3
# when the workload is gone since the poll, 1 on anything else, logged.
update_ssa_once() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6 manager=$7 \
          from_tag=$8 strategy=$9 force=${10:-}
    local to_tag=${image##*:} repo=${image%:*}
    local live manifest detail rv uid resource
    resource=$(update_resource_name "$kind") || resource=$kind
    if ! update_kubectl "" get "$resource" "$name" -n "$ns" -o json --show-managed-fields; then
        if update_is_gone "$UPDATE_ERR" "$kind" "$ns" "$name"; then
            update_log_gone "$kind" "$ns" "$name" "$container" "$image"
            return 3
        fi
        # The reason on the error line, as the patch path gives it: the
        # debug detail alone is not seen at the default level.
        log_flatten "$UPDATE_ERR"
        update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "$strategy" "could not read it: ${LOG_FLAT:-no error output}" "$UPDATE_ERR"
        return 1
    fi
    live=$UPDATE_OUT
    update_check_polled "$kind" "$ns" "$name" "$clist" "$container" "$image" \
        "$from_tag" "$live" || return
    update_check_owner "$kind" "$ns" "$name" "$clist" "$container" "$image" \
        "$manager" "$strategy" Apply "$live" || return
    # kubectl would hand a client-side applier's fields to keelson after
    # the write (managedfields_csa_holders).
    if ! update_csa_clear "$live" "$manager"; then
        update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "$strategy" "$UPDATE_CSA_WHY" ""
        return 1
    fi
    local owned=0
    managedfields_owner_set "$live" "$manager" || owned=$?
    if [ "$owned" -eq 2 ]; then
        update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "$strategy" "what '$manager' already applies could not be read" ""
        return 1
    fi
    if [ "$owned" -eq 0 ]; then
        if ! managedfields_project "$live" "$manager"; then
            update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
                "$strategy" "the fields '$manager' already applies could not be rebuilt" \
                "$MANAGEDFIELDS_PROJECTED"
            return 1
        fi
        # A new element added to keelson's set is one element of a list,
        # forced: on an atomic list that replaces the whole list, as the
        # image alone would.
        if ! update_set_has_element "$kind" "$clist" "$container" "$MANAGEDFIELDS_PROJECTED" \
                && ! update_claim_alone_safe "$live" "$kind" "$clist"; then
            update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
                "$strategy" "$UPDATE_CLAIM_UNSAFE_WHY, so adding the image to what '$manager' applies would replace the whole list; claim-patch changes only the image" ""
            return 1
        fi
        if ! update_claim_merge "$kind" "$clist" "$container" "$image" "$MANAGEDFIELDS_PROJECTED" "$live"; then
            update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
                "$strategy" "the image could not be added to what '$manager' already applies" ""
            return 1
        fi
        manifest=$UPDATE_CLAIM_MANIFEST
    elif ! update_claim_alone_safe "$live" "$kind" "$clist"; then
        # The image alone is a one-element list, forced: on an atomic list
        # the server would replace the whole list with it, deleting every
        # other element. Refused, never sent.
        update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "$strategy" "$UPDATE_CLAIM_UNSAFE_WHY, so sending the image alone would replace the whole list; claim-patch changes only the image" ""
        return 1
    elif ! manifest=$(update_minimal_manifest "$kind" "$ns" "$name" "$clist" "$container" "$image"); then
        log_error update-unsupported-kind kind="$kind" ns="$ns" name="$name" \
            msg="Cannot update $kind '$name' in '$ns': kind not supported. ${UPDATE_OUTCOME}"
        return 1
    elif ! rv=$(printf '%s' "$live" | yq -p=json -o=yaml '.metadata.resourceVersion // ""' 2>/dev/null) \
            || [ -z "$rv" ] \
            || ! uid=$(printf '%s' "$live" | yq -p=json -o=yaml '.metadata.uid // ""' 2>/dev/null) \
            || [ -z "$uid" ]; then
        # The preconditions, as on the rebuilt-set path: the image was
        # checked against this read, so the write must not land on a later
        # one, nor create the object anew if it was deleted since (an apply
        # is an upsert; the uid makes it refuse instead).
        update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "$strategy" "the read carries no resourceVersion and uid to write against" ""
        return 1
    elif ! manifest=$(printf '%s' "$manifest" | RV=$rv UID_=$uid yq -o=yaml '.metadata.resourceVersion = strenv(RV) | .metadata.uid = strenv(UID_)' 2>/dev/null); then
        update_log_claim_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "$strategy" "the manifest could not be built" ""
        return 1
    fi
    # Captured the same way as the patch path. Under pipefail the status is
    # kubectl's, or printf's SIGPIPE when kubectl quits before reading: a
    # failure either way, with kubectl's complaint captured.
    local forcing=()
    [ "$force" = "force" ] && forcing=(--force-conflicts)
    if detail=$(printf '%s' "$manifest" | kubectl apply --server-side \
            --field-manager="$manager" ${forcing[@]+"${forcing[@]}"} -f - 2>&1 >/dev/null); then
        log_info_always update-applied \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" from="$from_tag" to="$to_tag" repo="$repo" \
            manager="$manager" operation=Apply strategy="$strategy" \
            msg="$kind '$name' in '$ns' updated from $from_tag to $to_tag by $strategy (as ${UPDATE_STRATEGY_SOURCE:-configured}) for image '$repo'."
        return 0
    fi
    update_is_stale "$detail" && return 2
    if update_is_gone "$detail" "$kind" "$ns" "$name"; then
        update_log_gone "$kind" "$ns" "$name" "$container" "$image"
        return 3
    fi
    update_log_ssa_failure "$kind" "$ns" "$name" "$container" "$image" \
        "$manager" "$strategy" "$detail" "It may have been written regardless; the next poll will see." \
        "$force"
    return 1
}

# update_set_has_element <kind> <list> <container> <set-json>
# Whether the rebuilt set already holds the target's element by name.
# Compared as base64: yq's == reads * and ? on its right as a pattern.
update_set_has_element() {
    local kind=$1 clist=$2 container=$3 set=$4 pod='.spec.template.spec' list=$2 n
    [ "$kind" = "CronJob" ] && pod='.spec.jobTemplate.spec.template.spec'
    [ "$clist" = "imageVolumes" ] && list=volumes
    n=$(printf '%s' "$set" | CONTAINER=$container yq -p=json -o=yaml \
        "[(${pod}.${list} // [])[] | select((.name | @base64) == (strenv(CONTAINER) | @base64))] | length" 2>/dev/null) \
        || return 1
    [ "$n" -gt 0 ]
}

# update_claim_alone_safe <live-json> <kind> <list>  -> UPDATE_CLAIM_UNSAFE_WHY
# Whether claim-apply may send the image alone. Not when the list is held
# whole by anyone (it is atomic), nor on a Rollout with no managedFields at
# all: its CRD may declare the list atomic (before v1.9 it does) and
# nothing on the object says otherwise. Built-in kinds key their lists.
declare -g UPDATE_CLAIM_UNSAFE_WHY=""
update_claim_alone_safe() {
    local live=$1 kind=$2 clist=$3 mf rc=0 list=$3
    [ "$list" = "imageVolumes" ] && list=volumes
    UPDATE_CLAIM_UNSAFE_WHY=""
    if ! mf=$(printf '%s' "$live" | yq -p=json -o=json -I0 '.metadata.managedFields // []' 2>/dev/null); then
        UPDATE_CLAIM_UNSAFE_WHY="its managedFields could not be read to tell whether its $list list is atomic"
        return 1
    fi
    managedfields_list_held_whole "$mf" "$clist" || rc=$?
    case "$rc" in
        0) UPDATE_CLAIM_UNSAFE_WHY="its $list list is held whole (atomic)"; return 1 ;;
        2) UPDATE_CLAIM_UNSAFE_WHY="its managedFields could not be read to tell whether its $list list is atomic"; return 1 ;;
    esac
    if [ "$kind" = Rollout ] && [ "$mf" = "[]" ]; then
        UPDATE_CLAIM_UNSAFE_WHY="it records no managedFields to tell whether its $list list is atomic (Argo Rollouts before v1.9 declare it so)"
        return 1
    fi
    return 0
}

# update_claim_merge <kind> <list> <container> <image> <projected-json> <live-json>  -> UPDATE_CLAIM_MANIFEST
# The manager's rebuilt set with this image in it: the element by that name
# given the new image, or added when the set has none, and the list in its
# live order. An applied list's order is the order the server keeps, so
# moving the element (or appending a new one last) would reorder init
# containers or sidecars on the next write.
declare -g UPDATE_CLAIM_MANIFEST=""
update_claim_merge() {
    local kind=$1 clist=$2 container=$3 image=$4 projected=$5 live=$6
    local pod='.spec.template.spec' list=$clist set='{"image": strenv(IMAGE)}'
    [ "$kind" = "CronJob" ] && pod='.spec.jobTemplate.spec.template.spec'
    if [ "$clist" = "imageVolumes" ]; then
        list=volumes
        set='{"image": {"reference": strenv(IMAGE)}}'
    fi
    UPDATE_CLAIM_MANIFEST=""
    # The live names go in on stdin beside the set, not by environment:
    # enough of them can be larger than one environment string may be
    # (128 KiB on Linux, past which yq is never run). Names are
    # compared as base64: yq's == reads * and ? on its right as a pattern,
    # and a live sibling's name is not screened.
    local order
    order=$(printf '%s' "$live" | yq -p=json -o=json -I0 "[(${pod}.${list} // [])[] | .name]" 2>/dev/null) \
        || return 1
    UPDATE_CLAIM_MANIFEST=$(printf '{"p":%s,"o":%s}' "$projected" "$order" | CONTAINER=$container IMAGE=$image \
        yq -p=json -o=json -I0 "
        .o as \$order
        | .p
        | [(${pod}.${list} // [])[]] as \$mine
        | (${pod}.${list}) = ([\$order[] as \$n
              | {\"n\": \$n, \"have\": ([\$mine[] | select((.name | @base64) == (\$n | @base64))] | .[0])}]
            | map((select((.n | @base64) == (strenv(CONTAINER) | @base64)) | ((.have // {\"name\": .n}) * ${set})) // .have)
            | map(select(. != null)))" 2>/dev/null) && [ -n "$UPDATE_CLAIM_MANIFEST" ]
}

# update_check_polled <kind> <ns> <name> <list> <container> <image> <from-tag> <live-json>
# The update was chosen from the image as polled. If the live one is not
# that any more (a deploy since, a retag, someone else's update), the
# choice no longer holds: written anyway it could downgrade or undo that
# change. Refused, logged at warn since nothing is broken, and the next poll
# decides again from what is there. Skipped when there is no polled tag to
# compare with. A moved image does not prove an earlier try of ours never
# landed (it may have, and been overwritten since), so after one that may
# have it says so. Returns 3 when the image moved and 4 when it already is the
# target: both "not written and nothing wrong", which update_apply passes on
# as 3 (or 0, see update_with_retries) so the scan counts a skip, not an error.
update_check_polled() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6 from_tag=$7 live=$8
    local expected=${image%:*}:$from_tag pod='.spec.template.spec' list=$clist leaf='.image' now
    [ "$kind" = "CronJob" ] && pod='.spec.jobTemplate.spec.template.spec'
    if [ "$clist" = "imageVolumes" ]; then
        list=volumes
        leaf='.image.reference'
    fi
    if ! now=$(printf '%s' "$live" | CONTAINER=$container yq -p=json -o=yaml \
            "[(${pod}.${list} // [])[] | select(.name == strenv(CONTAINER)) | ${leaf}] | select(length == 1) | .[0] // \"\"" \
            2>/dev/null); then
        log_error update-failed \
            kind="$kind" ns="$ns" name="$name" container="$container" image="$image" \
            msg="Could not read the image $kind '$name'/$container in '$ns' runs now. ${UPDATE_OUTCOME}"
        return 1
    fi
    # Already there first: asked for what it runs (polled tag and target can
    # be the same from the command line), someone else made the change, or an
    # earlier try of ours landed though kubectl reported it failed. Nothing to
    # write; update_with_retries says which.
    [ "$now" = "$image" ] && return 4
    [ -n "$from_tag" ] || return 0
    [ "$now" = "$expected" ] && return 0
    log_warn update-image-moved \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        image="$image" polled="$expected" live="${now:-none}" \
        msg="Not updating $kind '$name'/$container in '$ns' to image '$image': it runs '${now:-no such image}' now, not '$expected' as polled. $(update_moved_outcome)"
    return 3
}

# update_moved_outcome
# How a "moved, not written" line ends: nothing was written this try, but an
# earlier one in this call may have landed before the move.
update_moved_outcome() {
    if [ "$UPDATE_OUTCOME" = "Nothing was written." ]; then
        printf '%s' "Nothing was written; the next poll decides again."
    else
        printf '%s' "An earlier try may have landed; the next poll decides again."
    fi
}

# update_log_claim_refused <kind> <ns> <name> <container> <image> <manager> <strategy> <why> <detail> [<operation>]
update_log_claim_refused() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5 manager=$6 strategy=$7 \
          why=$8 detail=$9 operation=${10:-Apply}
    if [ -n "$detail" ]; then
        log_flatten "$detail"
        log_debug update-claim-refused-detail \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            msg="Claim of $kind '$name'/$container in '$ns' refused, full output: $LOG_FLAT"
    fi
    log_error update-claim-refused \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        image="$image" manager="$manager" operation="$operation" strategy="$strategy" \
        reason="$why" \
        msg="Refusing to update $kind '$name'/$container in '$ns' to image '$image' as manager '$manager': $why. ${UPDATE_OUTCOME}"
}

# update_log_ssa_failure <kind> <ns> <name> <container> <image> <manager> <strategy> <detail> [<outcome>] [force]
# Logs a refused server-side apply: all of kubectl's complaint at debug, a
# clip of it on the error line, and an ownership conflict told apart from any
# other failure. <detail> is kubectl's stderr. <outcome> ends a failure that
# was not a conflict: "Nothing was written." by default, but a real apply
# that timed out may have landed, and says so. A conflict never lands.
update_log_ssa_failure() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5 manager=$6 \
          strategy=$7 detail=$8 outcome=${9:-"Nothing was written."} forced=${10:-} reason
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
    # sit past the clip. The server's own wording on kubectl's own line
    # (update_is_ownership_conflict), not the bare word, which a webhook's or
    # a policy's denial can use too; and a forced apply cannot conflict over
    # ownership at all.
    local conflict=0
    [ -z "$forced" ] && update_is_ownership_conflict "$detail" && conflict=1
    case "$conflict" in
        1)
            update_conflict_managers "$detail" "$manager"
            # An apply only conflicts with another manager, so its own name
            # in the list is an Update entry under that name, left by a patch
            # or edit made as it. Said, because otherwise it reads as nonsense.
            local held_by=$UPDATE_CONFLICT_MANAGERS
            # The caller's advice when it knows who applies the fields.
            local advice="Fix the owning manager's source of truth."
            [ -n "$UPDATE_CONFLICT_ADVICE" ] && advice=$UPDATE_CONFLICT_ADVICE
            [ "$UPDATE_CONFLICT_OWN" -eq 1 ] && held_by+=" (an Update entry under its own name)"
            log_error update-apply-conflict \
                kind="$kind" ns="$ns" name="$name" container="$container" \
                image="$image" manager="$manager" operation=Apply \
                strategy="$strategy" reason="$reason" \
                msg="Server-side apply of $kind '$name'/$container in '$ns' as manager '$manager' rejected on field-ownership conflict${held_by:+ with $held_by}; refusing to force. Nothing was written. $advice"
            ;;
        *)
            log_error update-failed \
                kind="$kind" ns="$ns" name="$name" container="$container" \
                image="$image" manager="$manager" operation=Apply \
                strategy="$strategy" reason="$reason" \
                msg="Could not server-side apply $kind '$name'/$container in '$ns' to image '$image' (manager '$manager', operation Apply)${reason:+: $reason}. $outcome"
            ;;
    esac
}

# update_apply_mimic <kind> <ns> <name> <list> <container> <image> <manager> <from-tag>
# Mimic: the image changed under the owner's own name, with what it owns
# otherwise left exactly as it is.
#
# An apply is the manager's whole intent. Sent with only the image, the
# owner would lose every other field it set, and the server deletes those
# nobody else holds (a Deployment then fails on its selector, a CronJob on
# its schedule). Sent with the whole object, it would come to own fields it
# never set. So the body is the owner's set exactly, rebuilt from the live
# values (managedfields_project), with the image changed in it.
#
# Nothing is written on trust: a server-side dry run must return the owner's
# set unchanged before the real apply is made. The object is read again and
# the whole thing retried (update_with_retries) when it moved between read
# and write, which a rollout in progress does constantly.
update_apply_mimic() {
    local kind=$1 ns=$2 name=$3 container=$5 image=$6 manager=$7
    local rc=0
    update_with_retries not-written update_mimic_once "$@" || rc=$?
    [ "$rc" -eq 2 ] || return "$rc"
    log_error update-failed \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        image="$image" manager="$manager" operation=Apply strategy=mimic \
        reason="object kept changing" \
        msg="Could not update $kind '$name'/$container in '$ns' to image '$image' as manager '$manager': it changed between read and write three times running. Nothing was written; trying again next poll."
    return 1
}

# update_conflict_names <kubectl-stderr>
#     -> UPDATE_CONFLICT_NAMES, UPDATE_CONFLICT_BY_UPDATE, UPDATE_CONFLICT_BY_APPLY
# The managers an apply conflicted with, by name, each once, in order: the
# raw names update_conflict_managers quotes for display. The server writes
# "conflict with \"m\" using <apiVersion>" for a field held by an Update
# entry (with subresource \"s\" between the two for one on a subresource)
# and plain "conflict with \"m\"" for one held by an Apply entry, so
# each mention is also noted by which: UPDATE_CONFLICT_BY_UPDATE and
# UPDATE_CONFLICT_BY_APPLY hold the names so mentioned, one a line.
declare -ga UPDATE_CONFLICT_NAMES=()
declare -g UPDATE_CONFLICT_BY_UPDATE="" UPDATE_CONFLICT_BY_APPLY=""
update_conflict_names() {
    local rest=$1 m n seen i c closed after bad=0
    local re='[Cc]onflicts? with "'
    UPDATE_CONFLICT_NAMES=()
    UPDATE_CONFLICT_BY_UPDATE="" UPDATE_CONFLICT_BY_APPLY=""
    while [[ $rest =~ $re ]]; do
        rest=${rest#*"${BASH_REMATCH[0]}"}
        # The name as Go's %q writes it: read to the closing quote, undoing
        # \" \\ \t \n. Any other escape is not decoded, and a name that
        # cannot be read back exactly makes the whole list unreadable.
        m="" i=0 closed=0
        while [ "$i" -lt "${#rest}" ]; do
            c=${rest:i:1}
            if [ "$c" = '"' ]; then
                closed=1
                break
            elif [ "$c" = '\' ]; then
                i=$((i + 1))
                case "${rest:i:1}" in
                    '"') m+='"' ;;
                    '\') m+='\' ;;
                    t) m+=$'\t' ;;
                    n) m+=$'\n' ;;
                    *) bad=1 ;;
                esac
            else
                m+=$c
            fi
            i=$((i + 1))
        done
        if [ "$closed" -ne 1 ] || [ -z "$m" ]; then
            bad=1
        fi
        rest=${rest:i+1}
        # An entry on a subresource is written with it between the name and
        # the using: "m" with subresource "status" using apps/v1 is still an
        # Update entry. Its quoted name is skipped as the manager's was read.
        after=$rest
        if [[ $after == ' with subresource "'* ]]; then
            after=${after#' with subresource "'}
            i=0
            while [ "$i" -lt "${#after}" ]; do
                c=${after:i:1}
                [ "$c" = '"' ] && break
                [ "$c" = '\' ] && i=$((i + 1))
                i=$((i + 1))
            done
            after=${after:i+1}
        fi
        if [[ $after == ' using '* ]]; then
            UPDATE_CONFLICT_BY_UPDATE+="$m"$'\n'
        else
            UPDATE_CONFLICT_BY_APPLY+="$m"$'\n'
        fi
        seen=0
        for n in ${UPDATE_CONFLICT_NAMES[@]+"${UPDATE_CONFLICT_NAMES[@]}"}; do
            [ "$n" = "$m" ] && seen=1
        done
        [ "$seen" -eq 1 ] || UPDATE_CONFLICT_NAMES+=("$m")
    done
    # Unreadable is none: the caller refuses rather than force past a
    # manager it could not name.
    [ "$bad" -eq 0 ] || UPDATE_CONFLICT_NAMES=()
}

# update_conflict_mentioned <name> <names-one-a-line>
update_conflict_mentioned() {
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && [ "$line" = "$1" ] && return 0
    done <<<"$2"
    return 1
}

# update_mimic_force_plan <live-json> <owner> <kubectl-stderr>
#     -> UPDATE_FORCE_NOTE, UPDATE_CONFLICT_ADVICE
# Whether mimic's conflicting dry run may be redone forced. It may when no
# manager it conflicted with applies the fields itself: one holding them
# only by Update entries wrote the same value the owner did (an Update that
# changed it would have taken it outright), so it loses nothing it would
# not take back on its next write; the owner's own Update entry is the
# same; and keelson's own entries, an Apply from an earlier claim-apply
# included, are Keelson's to release. Returns 0 with UPDATE_FORCE_NOTE
# naming what is forced past, for the success line. Returns 1 when another
# manager applies them: two appliers, and Keelson will not pick one; when
# the owner holds them by another Apply entry of its own (on scale, say);
# or when who applies them cannot be read. The advice for the refusal is left
# in UPDATE_CONFLICT_ADVICE.
declare -g UPDATE_FORCE_NOTE=""
declare -g UPDATE_CONFLICT_ADVICE=""
update_mimic_force_plan() {
    local live=$1 owner=$2 detail=$3 appliers n a held line
    local updates="" own_update=0 own_apply=0 keelson_apply=0 others=""
    UPDATE_FORCE_NOTE=""
    UPDATE_CONFLICT_ADVICE=""
    update_conflict_names "$detail"
    (( ${#UPDATE_CONFLICT_NAMES[@]} )) || return 1
    # Who holds an Apply entry on the object itself, one base64 per line.
    # Unreadable is refused as such, not as a co-owner that applies.
    if ! appliers=$(printf '%s' "$live" | yq -p=json -o=y \
            '.metadata.managedFields // [] | .[] | select(.operation == "Apply" and (.subresource // "") == "") | .manager // "" | @base64' 2>/dev/null); then
        UPDATE_CONFLICT_ADVICE="Keelson could not read the workload's field managers to tell whether another one applies these fields, so it will not force past them."
        return 1
    fi
    for n in "${UPDATE_CONFLICT_NAMES[@]}"; do
        held=0
        a=$(printf '%s' "$n" | base64 | tr -d '\n')
        while IFS= read -r line; do
            [ "$line" = "$a" ] && held=1
        done <<<"$appliers"
        # The server printing it as Apply-held is an applier too, whatever
        # subresource that entry is on: the object-only lookup above would
        # otherwise file an Apply on scale as an Update and force past it.
        update_conflict_mentioned "$n" "$UPDATE_CONFLICT_BY_APPLY" && held=1
        update_name_shown "$n"
        # The owner only as Update-held: named as Apply-held it holds these
        # fields by another Apply entry of its own (on scale, say), which a
        # force would take from it.
        if [ "$n" = "$owner" ] && update_conflict_mentioned "$n" "$UPDATE_CONFLICT_BY_APPLY"; then
            own_apply=1
        elif [ "$n" = "$owner" ]; then
            own_update=1
        elif [ "$n" = keelson ]; then
            # By how the server named keelson's conflicting fields: an Apply
            # entry holding them (from a claim-apply), its Update entry
            # (from a claim-patch), or both. Holding an Apply entry somewhere
            # on the object is not enough to say which.
            update_conflict_mentioned "$n" "$UPDATE_CONFLICT_BY_APPLY" && keelson_apply=1
            update_conflict_mentioned "$n" "$UPDATE_CONFLICT_BY_UPDATE" \
                && updates+="${updates:+, }'$UPDATE_NAME_SHOWN'"
        elif (( held )); then
            others+="${others:+, }'$UPDATE_NAME_SHOWN'"
        else
            updates+="${updates:+, }'$UPDATE_NAME_SHOWN'"
        fi
    done
    if (( own_apply )); then
        update_name_shown "$owner"
        UPDATE_CONFLICT_ADVICE="'$UPDATE_NAME_SHOWN' also holds these fields by another Apply entry of its own, so Keelson won't force past it. Remove that entry, or annotate the workload with a claim strategy."
        return 1
    fi
    if [ -n "$others" ]; then
        UPDATE_CONFLICT_ADVICE="$others also applies these fields (Apply); two managers apply this workload, so Keelson won't pick one. Remove one, or annotate the workload with a claim strategy."
        return 1
    fi
    local parts=()
    [ -n "$updates" ] && parts+=("Update entries of $updates")
    (( own_update )) && parts+=("its own Update entry")
    (( keelson_apply )) && parts+=("keelson's own Apply entry")
    # Joined part by part: a separator rewritten afterwards would rewrite
    # the same character inside a manager's name too.
    local part joined=""
    for part in "${parts[@]}"; do
        joined+="${joined:+ and }$part"
    done
    UPDATE_FORCE_NOTE="forced past $joined"
    return 0
}

# update_mimic_once <kind> <ns> <name> <list> <container> <image> <manager> <from-tag>
# One read, check and write. Returns 0 on success, 2 when the object moved
# since it was read (worth reading again), 3 when the image or its owner
# moved or the workload is gone since the poll, 4 when the image already is
# the target, 1 on anything else, logged.
update_mimic_once() {
    local kind=$1 ns=$2 name=$3 clist=$4 container=$5 image=$6 manager=$7 \
          from_tag=$8
    local to_tag=${image##*:} repo=${image%:*}
    local live before manifest detail resource
    resource=$(update_resource_name "$kind") || resource=$kind

    if ! update_kubectl "" get "$resource" "$name" -n "$ns" -o json --show-managed-fields; then
        if update_is_gone "$UPDATE_ERR" "$kind" "$ns" "$name"; then
            update_log_gone "$kind" "$ns" "$name" "$container" "$image"
            return 3
        fi
        log_flatten "$UPDATE_ERR"
        update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "could not read it: ${LOG_FLAT:-no error output}" "$UPDATE_ERR"
        return 1
    fi
    live=$UPDATE_OUT
    update_check_polled "$kind" "$ns" "$name" "$clist" "$container" "$image" \
        "$from_tag" "$live" || return
    update_check_owner "$kind" "$ns" "$name" "$clist" "$container" "$image" \
        "$manager" mimic Apply "$live" || return
    # Before any dry run, forced or not: kubectl's merge of a client-side
    # applier's fields happens after the real write, where the guard cannot
    # see it (managedfields_csa_holders). Mimic as "kubectl" also has the
    # server rewrite last-applied-configuration from our body: tested on a
    # cluster (2026-10-18) and harmless; but with the annotation owned by no
    # Apply entry, kubectl's second apply blinds the dry run, so that is
    # refused here too.
    if ! update_csa_clear "$live" "$manager"; then
        update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "$UPDATE_CSA_WHY" ""
        return 1
    fi
    # Another Apply entry on the image: two appliers, and mimic changing it as
    # one would take it from the other. Asked here, before any dry run, and
    # not left to the dry run's conflict: for a manager named "kubectl" the
    # API server retries a conflicting apply forced when the fields match
    # last-applied-configuration, so the dry run would pass and the second
    # applier lose the image unseen.
    local mf rc=0
    if mf=$(printf '%s' "$live" | yq -p=json -o=json -I0 '.metadata.managedFields // []' 2>/dev/null); then
        managedfields_image_appliers "$mf" "$clist" "$container" "$manager" || rc=$?
    else
        rc=2
    fi
    case "$rc" in
        0)
            update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
                "${MANAGEDFIELDS_IMAGE_APPLIERS} also applies this image (Apply); two managers apply this workload, so Keelson won't pick one. Remove one, or annotate the workload with a claim strategy" ""
            return 1
            ;;
        2)
            update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
                "who else applies the image could not be read" ""
            return 1
            ;;
    esac

    # The owner's own entry, which the rebuild and the guard work from.
    local owned=0
    managedfields_owner_set "$live" "$manager" || owned=$?
    if [ "$owned" -eq 2 ]; then
        update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "what '$manager' owns could not be read" ""
        return 1
    elif [ "$owned" -ne 0 ]; then
        # update_check_owner found it holding the image by an Apply, so this
        # is an entry the server should not have: more than one, or one
        # with no set. Nothing to rebuild from.
        update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "'$manager' does not have exactly one usable Apply entry on it" ""
        return 1
    fi
    before=$MANAGEDFIELDS_OWNER_SET

    if ! managedfields_project "$live" "$manager"; then
        update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "its owned fields could not be rebuilt" "$MANAGEDFIELDS_PROJECTED"
        return 1
    fi
    # Owned fields the live object no longer has were left out of the body
    # (the server drops zero values such as readOnly: false). The field is
    # absent and stays absent (a parent the drop left empty, such as
    # dnsConfig: {}, may go with it: equivalent for core types, see the
    # projection's header); the owner only stops being recorded as owning
    # it, and its next deploy re-owns it. So the guard below expects exactly
    # that loss from the set, and nothing else.
    local omitted=$MANAGEDFIELDS_OMITTED expected=$before
    if [ "$omitted" != "[]" ]; then
        log_debug update-mimic-omitted \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            msg="Owned fields of '$manager' that $kind '$name' no longer holds, left out of the write: $omitted"
        if ! managedfields_set_without "$before" "$omitted"; then
            update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
                "the fields it no longer holds could not be taken out of what '$manager' owns" ""
            return 1
        fi
        expected=$MANAGEDFIELDS_SET_EXPECTED
    fi
    if ! update_mimic_set_image "$kind" "$clist" "$container" "$image" "$MANAGEDFIELDS_PROJECTED"; then
        # The owner holds the image (update_check_owner), yet its rebuilt
        # set has no single element by that name carrying one.
        update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "the image of '$container' is not in what '$manager' owns, rebuilt" ""
        return 1
    fi
    manifest=$UPDATE_MIMIC_MANIFEST

    # Unforced first. A conflict only with managers that do not apply these
    # fields themselves is redone forced (update_mimic_force_plan); any
    # other failure, or a conflict with another applier, is refused.
    local forcing=() note=""
    if ! update_kubectl "$manifest" apply --server-side --dry-run=server \
            --field-manager="$manager" -o json --show-managed-fields -f -; then
        update_is_stale "$UPDATE_ERR" && return 2
        if update_is_gone "$UPDATE_ERR" "$kind" "$ns" "$name"; then
            update_log_gone "$kind" "$ns" "$name" "$container" "$image"
            return 3
        fi
        local refused=$UPDATE_ERR
        if update_is_ownership_conflict "$refused" \
                && update_mimic_force_plan "$live" "$manager" "$refused"; then
            forcing=(--force-conflicts)
            note=$UPDATE_FORCE_NOTE
        fi
        if (( ! ${#forcing[@]} )); then
            update_log_ssa_failure "$kind" "$ns" "$name" "$container" "$image" \
                "$manager" mimic "$refused"
            UPDATE_CONFLICT_ADVICE=""
            return 1
        fi
        if ! update_kubectl "$manifest" apply --server-side --dry-run=server \
                --field-manager="$manager" "${forcing[@]}" -o json --show-managed-fields -f -; then
            update_is_stale "$UPDATE_ERR" && return 2
            if update_is_gone "$UPDATE_ERR" "$kind" "$ns" "$name"; then
                update_log_gone "$kind" "$ns" "$name" "$container" "$image"
                return 3
            fi
            update_log_ssa_failure "$kind" "$ns" "$name" "$container" "$image" \
                "$manager" mimic "$UPDATE_ERR" "" force
            return 1
        fi
    fi
    if ! managedfields_owner_set "$UPDATE_OUT" "$manager" \
            || [ "$MANAGEDFIELDS_OWNER_SET" != "$expected" ]; then
        log_debug update-mimic-guard-detail \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            msg="Owner set before: $before; expected after the dry run: $expected; after the dry run: ${MANAGEDFIELDS_OWNER_SET:-none}"
        # A list or map the owner recorded whole that the server now records
        # field by field is a schema change since the owner last applied,
        # not a write that would take or give fields: still refused (the
        # guard cannot tell the two sets apart safely), but said for what
        # it is, with what clears it.
        local why="a dry run showed the write would change what '$manager' owns"
        if [ -n "$MANAGEDFIELDS_OWNER_SET" ] \
                && managedfields_reshaped "$expected" "$MANAGEDFIELDS_OWNER_SET"; then
            why="'$manager' recorded $MANAGEDFIELDS_RESHAPED whole, and the server now records it field by field (a schema change since the owner last applied, such as Argo Rollouts v1.9 keying containers by name); a fresh apply by the owner (an Argo CD sync) clears this, or use claim-patch"
        fi
        update_log_mimic_refused "$kind" "$ns" "$name" "$container" "$image" "$manager" \
            "$why" ""
        return 1
    fi

    # The real write: output not needed, so stderr is captured directly.
    # Forced only when the dry run was, so the guard has seen exactly this.
    if detail=$(printf '%s' "$manifest" | kubectl apply --server-side \
            --field-manager="$manager" ${forcing[@]+"${forcing[@]}"} -f - 2>&1 >/dev/null); then
        log_info_always update-applied \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            image="$image" from="$from_tag" to="$to_tag" repo="$repo" \
            manager="$manager" operation=Apply strategy=mimic \
            msg="$kind '$name' in '$ns' updated from $from_tag to $to_tag by mimic (as ${UPDATE_STRATEGY_SOURCE:-configured})${note:+, $note,} for image '$repo'."
        return 0
    fi
    update_is_stale "$detail" && return 2
    if update_is_gone "$detail" "$kind" "$ns" "$name"; then
        update_log_gone "$kind" "$ns" "$name" "$container" "$image"
        return 3
    fi
    update_log_ssa_failure "$kind" "$ns" "$name" "$container" "$image" \
        "$manager" mimic "$detail" "It may have been written regardless; the next poll will see." \
        "${forcing[*]:+force}"
    return 1
}

# update_mimic_set_image <kind> <list> <container> <image> <projected-json>  -> UPDATE_MIMIC_MANIFEST
# Changes the image in the owner's rebuilt set. Refuses unless exactly one
# element by that name carries an image there, which is the proof the owner
# still owns it: the set holds only fields the owner owns.
declare -g UPDATE_MIMIC_MANIFEST=""
update_mimic_set_image() {
    local kind=$1 clist=$2 container=$3 image=$4 projected=$5
    local pod='.spec.template.spec' list=$clist leaf='.image' sel count
    [ "$kind" = "CronJob" ] && pod='.spec.jobTemplate.spec.template.spec'
    if [ "$clist" = "imageVolumes" ]; then
        list=volumes
        leaf='.image.reference'
    fi
    sel="${pod}.${list}[] | select(.name == strenv(CONTAINER)) | ${leaf}"
    UPDATE_MIMIC_MANIFEST=""
    count=$(printf '%s' "$projected" | CONTAINER=$container yq -p=json -o=yaml \
        "[${sel} | select(tag != \"!!null\")] | length" 2>/dev/null) || return 1
    [ "$count" = "1" ] || return 1
    UPDATE_MIMIC_MANIFEST=$(printf '%s' "$projected" | CONTAINER=$container IMAGE=$image \
        yq -p=json -o=json -I0 "(${sel}) = strenv(IMAGE)" 2>/dev/null)
}

# update_is_gone <kubectl-stderr> <kind> <ns> <name>
# True when the workload no longer exists: the API server's NotFound for
# this very object, '<resource> "<name>" not found' (the resource qualified
# by its group, as update_resource_name gives it: the server's own spelling,
# the same from get, patch, apply and its dry run), or for its namespace,
# 'namespaces "<ns>" not found' (which get and patch also print for an
# object in a namespace that is gone). kubectl prints the server's message
# after "Error from server (NotFound): " and adds nothing (checked with
# kubectl 1.36.5 against a stand-in API server). A server-side apply is an
# upsert: to a deleted object it would create a new one, so every apply
# body carries the read's uid, and the server then refuses with a uid
# mismatch naming no existing object (verified on k3s), which is the same
# news, and is also judged for this object.
#
# Judged line by line, on kubectl's own line for the error, and the whole
# line: the reason alone is not enough, since an admission webhook may deny
# with reason NotFound (the server keeps it), and kubectl then prints
# "Error from server (NotFound): admission webhook ... denied the request:
# ...", which is a refusal, not news of a deletion. Nor is a denial that
# merely quotes the wording somewhere in its text. The uid refusal is a
# 409, which kubectl prints two ways (update_conflict_line).
update_is_gone() {
    local ns=$3 name=$4 resource line uid_tail
    resource=$(update_resource_name "$2") || resource=""
    uid_tail="Operation cannot be fulfilled on $resource \"$name\": uid mismatch: "
    while IFS= read -r line; do
        [ "$line" = "Error from server (NotFound): namespaces \"$ns\" not found" ] && return 0
        [ -n "$resource" ] || continue
        [ "$line" = "Error from server (NotFound): $resource \"$name\" not found" ] && return 0
        case "$line" in
            "Error from server (Conflict): $uid_tail"*'no existing object was found' | \
            "error: $uid_tail"*'no existing object was found') return 0 ;;
        esac
    done <<<"$1"
    return 1
}

# update_conflict_line <line>
# True for kubectl's line reporting a 409 that a precondition earned: "Error
# from server (Conflict): Operation cannot be fulfilled on ..." from patch
# and get, and "error: Operation cannot be fulfilled on ..." from apply
# --server-side and its dry run, which wraps every 409 before printing it
# (and follows it with its --force-conflicts speech). An ownership conflict
# reads "Apply failed with ...", never this.
update_conflict_line() {
    case "$1" in
        'Error from server (Conflict): Operation cannot be fulfilled on '*) return 0 ;;
        'error: Operation cannot be fulfilled on '*) return 0 ;;
        *) return 1 ;;
    esac
}

# update_log_gone <kind> <ns> <name> <container> <image>
# Deleted since the poll: nothing wrong and nothing to write, so info, and
# the caller returns 3 for the scan to count a skip. An earlier try of this
# call may have landed before it went, and then says so.
update_log_gone() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5 ending="nothing to write."
    [ "$UPDATE_OUTCOME" = "Nothing was written." ] \
        || ending="an earlier try may have landed before it went; nothing more to write."
    log_info update-workload-gone \
        kind="$kind" ns="$ns" name="$name" container="$container" image="$image" \
        msg="$kind '$name' in '$ns' is gone since the poll; $ending"
}

# update_csa_clear <live-json> <applier>  -> UPDATE_CSA_WHY
# Whether a server-side apply through kubectl as <applier> is safe from
# kubectl's client-side-apply migration: false when an Update entry owns the
# last-applied-configuration annotation (or the managedFields cannot be
# read to tell), with the reason in UPDATE_CSA_WHY. JSON patches do not go
# through kubectl apply and need no such check.
#
# Also false for an object that records no managedFields at all yet carries
# the annotation: the write itself has the server record every live field
# under a before-first-apply Update entry, that entry owns the annotation,
# and kubectl's migration then hands all of it to the applier. Seen on a
# cluster (2026-10-18, lastapplied-check-3): a forced apply of one field
# left the applier owning every field and the annotation.
#
# And false for <applier> "kubectl" while the annotation is present and no
# Apply entry owns it: kubectl then follows the apply with a second one as
# "kubectl-last-applied", holding only the annotation, and -o json prints
# the second result, so a dry run shows the guard the live set and not the
# write's. Seen on k3s v1.34.1 with its kubectl (2026-10-20): two PATCHes
# under -v=6, the printed image the live one; none once an Apply entry of
# another manager owned the annotation.
declare -g UPDATE_CSA_WHY=""
update_csa_clear() {
    local live=$1 applier=$2 rc=0 bare orphan
    UPDATE_CSA_WHY=""
    managedfields_csa_holders "$live" || rc=$?
    case "$rc" in
        1)
            # By key, as below: yq's != takes the string "null" for null.
            if ! bare=$(printf '%s' "$live" | yq -p=json -o=y \
                    '((.metadata.managedFields // []) | length == 0)
                     and ((.metadata.annotations // {}) | has("kubectl.kubernetes.io/last-applied-configuration"))' 2>/dev/null); then
                UPDATE_CSA_WHY="its managedFields could not be read to tell whether kubectl apply would merge a client-side applier's fields into '$applier'"
                return 1
            fi
            if [ "$bare" = true ]; then
                UPDATE_CSA_WHY="it records no managedFields but carries kubectl's last-applied-configuration, so kubectl apply would hand '$applier' every field after the write; remove the annotation, or use claim-patch"
                return 1
            fi
            [ "$applier" = kubectl ] || return 0
            # By key: yq's != takes the string "null" for null.
            if ! orphan=$(printf '%s' "$live" | yq -p=json -o=y \
                    '((.metadata.annotations // {}) | has("kubectl.kubernetes.io/last-applied-configuration"))
                     and ([(.metadata.managedFields // [])[]
                         | select(.operation == "Apply" and (.subresource // "") == "")
                         | select(.fieldsV1["f:metadata"]["f:annotations"]["f:kubectl.kubernetes.io/last-applied-configuration"] != null)]
                         | length == 0)' 2>/dev/null); then
                UPDATE_CSA_WHY="its managedFields could not be read to tell whether kubectl apply as 'kubectl' would send a second apply for kubectl's last-applied-configuration"
                return 1
            fi
            [ "$orphan" = true ] || return 0
            UPDATE_CSA_WHY="it carries kubectl's last-applied-configuration and no Apply entry owns it, so kubectl apply as 'kubectl' would send a second apply, as 'kubectl-last-applied', and print that one's result for the dry run's, unseen by the guard; remove the annotation, or use claim-patch"
            ;;
        0) UPDATE_CSA_WHY="an Update entry of ${MANAGEDFIELDS_CSA_HOLDERS} owns kubectl's last-applied-configuration annotation, so kubectl apply would merge that manager's fields into '$applier' after the write, unseen by the dry run; remove the annotation (or that entry), or use claim-patch" ;;
        *) UPDATE_CSA_WHY="its managedFields could not be read to tell whether kubectl apply would merge a client-side applier's fields into '$applier'" ;;
    esac
    return 1
}

# update_is_ownership_conflict <kubectl-stderr>
# True when kubectl reports a field-ownership conflict: its own line,
# "error: Apply failed with N conflict(s): ..." from apply and its server
# dry run (or the same after "Error from server (Conflict): ", should a
# kubectl print it so), not the phrase anywhere: a webhook's or a policy's
# denial can quote it in its own text.
update_is_ownership_conflict() {
    local line
    while IFS= read -r line; do
        case "$line" in
            "error: Apply failed with "*" conflict"* | \
            "Error from server (Conflict): Apply failed with "*" conflict"*) return 0 ;;
        esac
    done <<<"$1"
    return 1
}

# update_is_stale <kubectl-stderr>
# True for the 409 a resourceVersion precondition earns when the object moved
# since it was read. kubectl follows it with its whole speech about
# --force-conflicts, so this is asked before anything looks for "conflict".
# Judged like update_is_gone: kubectl's own Conflict line, either form
# (update_conflict_line), not the phrase anywhere (a webhook's text could
# quote it).
update_is_stale() {
    local line
    while IFS= read -r line; do
        if update_conflict_line "$line" && [[ $line == *'the object has been modified'* ]]; then
            return 0
        fi
    done <<<"$1"
    return 1
}

# update_log_owner_moved <kind> <ns> <name> <container> <image> <manager>
# The strategy was chosen for an owner that, on the fresh read, no longer
# holds the image as it did: nothing wrong, so a warn, and the next poll
# decides again.
# Names the owner now from MANAGEDFIELDS_OWNER / _OPERATION.
update_log_owner_moved() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5 manager=$6
    log_warn update-owner-moved \
        kind="$kind" ns="$ns" name="$name" container="$container" image="$image" \
        manager="$manager" now="${MANAGEDFIELDS_OWNER:-nobody}" \
        msg="Not updating $kind '$name'/$container in '$ns' to image '$image' as '$manager': the image is now owned by '${MANAGEDFIELDS_OWNER:-nobody}'${MANAGEDFIELDS_OWNER_OPERATION:+ (${MANAGEDFIELDS_OWNER_OPERATION})}. $(update_moved_outcome)"
}

# update_log_mimic_refused <kind> <ns> <name> <container> <image> <manager> <why> <detail> [<operation>]
# <operation> is the write that was refused: Apply by default, Update on the
# patch path, none when there was no manager to write as.
update_log_mimic_refused() {
    local kind=$1 ns=$2 name=$3 container=$4 image=$5 manager=$6 why=$7 detail=$8 \
          operation=${9-${6:+Apply}}
    if [ -n "$detail" ]; then
        log_flatten "$detail"
        log_debug update-mimic-refused-detail \
            kind="$kind" ns="$ns" name="$name" container="$container" \
            msg="Mimic update of $kind '$name'/$container in '$ns' refused, full output: $LOG_FLAT"
    fi
    log_error update-mimic-refused \
        kind="$kind" ns="$ns" name="$name" container="$container" \
        image="$image" manager="$manager" operation="$operation" strategy=mimic \
        reason="$why" \
        msg="Refusing to update $kind '$name'/$container in '$ns' to image '$image'${manager:+ as manager '$manager'}: $why. ${UPDATE_OUTCOME}"
}

# update_kubectl <stdin> <kubectl-args...>  -> UPDATE_OUT, UPDATE_ERR
# For a call whose output is needed as well as its complaint, so stderr
# cannot simply be captured in place of stdout. It goes to a temporary file
# (/tmp is an emptyDir in the pod); one that cannot be made is said rather
# than costing the error silently. <stdin>, when not empty, is fed to kubectl.
declare -g UPDATE_OUT="" UPDATE_ERR=""
update_kubectl() {
    local input=$1 errf rc=0
    shift
    UPDATE_OUT=""
    UPDATE_ERR=""
    if ! errf=$(mktemp 2>/dev/null); then
        log_warn update-tempfile-failed \
            msg="Could not create a temporary file for kubectl's error output; if the call below fails it will not say why."
        errf=/dev/null
    fi
    if [ -n "$input" ]; then
        UPDATE_OUT=$(printf '%s' "$input" | kubectl "$@" 2>"$errf") || rc=$?
    else
        UPDATE_OUT=$(kubectl "$@" 2>"$errf") || rc=$?
    fi
    if [ "$errf" != /dev/null ]; then
        UPDATE_ERR=$(<"$errf")
        rm -f "$errf"
    fi
    return "$rc"
}

# update_conflict_managers <apply-output>  -> UPDATE_CONFLICT_MANAGERS
# The managers a rejected apply names, each once, quoted and comma separated:
# "'flux', 'helm'". Empty when none can be found. Who holds the field is what
# the reader needs, and the 40 character hint never reaches it.
# Built from the decoded names update_conflict_names reads, so a name the
# server escaped with Go's %q (a"b printed as "a\"b") is shown as it is.
# When those cannot be read back, the names are shown as kubectl printed
# them, and said to be. UPDATE_CONFLICT_OWN is set when <manager> is among
# them as Update-held: an Update entry under the applier's own name.
declare -g UPDATE_CONFLICT_MANAGERS=""
declare -g UPDATE_CONFLICT_OWN=0
# update_name_shown <name>  -> UPDATE_NAME_SHOWN
# A decoded manager name as it may appear in a log line (see
# managedfields_name_shown, which does the work for both files).
declare -g UPDATE_NAME_SHOWN=""
update_name_shown() {
    managedfields_name_shown "$1"
    UPDATE_NAME_SHOWN=$MANAGEDFIELDS_NAME_SHOWN
}

update_conflict_managers() {
    local rest=$1 manager=${2:-} found="" m
    local saved=(${UPDATE_CONFLICT_NAMES[@]+"${UPDATE_CONFLICT_NAMES[@]}"})
    UPDATE_CONFLICT_OWN=0
    update_conflict_names "$rest"
    if (( ${#UPDATE_CONFLICT_NAMES[@]} )); then
        for m in "${UPDATE_CONFLICT_NAMES[@]}"; do
            update_name_shown "$m"
            found+="${found:+, }'$UPDATE_NAME_SHOWN'"
            # Only as Update-held: named Apply-held, it is another Apply
            # entry of its own, and the note would contradict the refusal.
            [ -n "$manager" ] && [ "$m" = "$manager" ] \
                && update_conflict_mentioned "$m" "$UPDATE_CONFLICT_BY_UPDATE" \
                && UPDATE_CONFLICT_OWN=1
        done
    else
        local re='[Cc]onflicts? with "([^"]+)"'
        while [[ $rest =~ $re ]]; do
            m=${BASH_REMATCH[1]}
            rest=${rest#*"${BASH_REMATCH[0]}"}
            case ", $found, " in
                *", '$m', "*) ;;
                *) found+="${found:+, }'$m'" ;;
            esac
        done
        [ -n "$found" ] && found+=" (names as kubectl printed them)"
    fi
    UPDATE_CONFLICT_NAMES=(${saved[@]+"${saved[@]}"})
    UPDATE_CONFLICT_MANAGERS=$found
}

# update_trigger_cronjob <namespace> <cronjob-name> [<from-tag> <to-tag> <repo>]
# Creates a one-shot Job from the CronJob, named "<cronjob>-<ts>", as the CronJob controller names its own.
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
    # stderr into the capture, stdout to /dev/null, in that order.
    local detail reason
    if detail=$(kubectl create job "$job_name" \
            --from="cronjob/$name" -n "$ns" 2>&1 >/dev/null); then
        log_info_always cronjob-job-triggered \
            ns="$ns" name="$name" job="$job_name" \
            from="$from_tag" to="$to_tag" repo="$repo" \
            msg="$msg"
        return 0
    fi
    # kubectl's whole complaint at debug, a clip of it on the error line, so
    # a refusal by RBAC, a quota or a name clash reads as what it was.
    log_flatten "$detail"
    log_debug cronjob-job-trigger-failed-detail ns="$ns" name="$name" job="$job_name" \
        msg="Creating Job '$job_name' from CronJob '$name' in '$ns' failed, full output: ${LOG_FLAT:-no error output}"
    log_hint "$detail"
    reason=$LOG_HINT
    log_error cronjob-job-trigger-failed ns="$ns" name="$name" job="$job_name" \
        reason="$reason" \
        msg="Could not create Job '$job_name' from CronJob '$name' in '$ns'${reason:+: $reason}."
    return 1
}
