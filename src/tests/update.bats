#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# Tests for lib/update.bash. kubectl is shimmed via $TMP_BIN on PATH.

load helper

setup() {
    tmp_dir_init
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    PATH="$TMP_BIN:$PATH"
    KEELSON_CONFIG_MODE=keelson
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=mimic
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=mimic
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-patch
    KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED=true
    export PATH TMP_DIR KEELSON_CONFIG_MODE \
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED \
        KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED \
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED \
        KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/annotations.bash
    source "$SCRIPT_DIR/lib/annotations.bash"
    # shellcheck source=../scripts/lib/managedfields.bash
    source "$SCRIPT_DIR/lib/managedfields.bash"
    # shellcheck source=../scripts/lib/update.bash
    source "$SCRIPT_DIR/lib/update.bash"
}

# Logs go to stderr; merge so `run` sees them.
emit() { "$@" 2>&1; }

# A 409 as kubectl apply --server-side (and its server-side dry run) prints
# it: wrapped as "error: ..." and followed by its --force-conflicts speech.
# Only patch and get print a 409 as "Error from server (Conflict): ...".
KUBECTL_APPLY_SPEECH='Please review the fields above--they currently have other managers. Here
are the ways you can resolve this warning:
* If you intend to manage all of these fields, please re-run the apply
  command with the `--force-conflicts` flag.
* If you do not intend to manage all of the fields, please edit your
  manifest to remove references to the fields that should keep their
  current managers.
* You may co-own fields by updating your manifest to match the existing
  value; in this case, you will become the manager if the other manager(s)
  stop managing the field (remove it from their configuration).
See https://kubernetes.io/docs/reference/using-api/server-side-apply/#conflicts'
STALE_MSG='Operation cannot be fulfilled on deployments.apps "app": the object has been modified; please apply your changes to the latest version and try again'
apply_409() {
    printf 'error: %s\n%s\n' "$1" "$KUBECTL_APPLY_SPEECH"
}

# at_level <LEVEL> <text>: every line of $output holding <text> is logged at
# <LEVEL> (plain or JSON), and there is at least one.
at_level() {
    local lines
    lines=$(grep -F -- "$2" <<<"$output") || { echo "'$2' not logged"; return 1; }
    if grep -v -e " $1 " -e "\"level\":\"$1\"" <<<"$lines" >/dev/null; then
        echo "'$2' not at $1: $lines"; return 1
    fi
}

# one_error: exactly one error line in $output, so a refusal that runs on
# into a second, different error fails.
one_error() {
    local n
    n=$(grep -c ERROR <<<"$output") || true
    [ "$n" -eq 1 ] || { echo "$n error lines"; return 1; }
}

# once <text>: <text> is on exactly one line of $output, so a line logged
# twice fails where a substring match would not.
once() {
    local n
    n=$(grep -cF -- "$1" <<<"$output") || true
    [ "$n" -eq 1 ] || { echo "'$1' on $n lines"; return 1; }
}

install_shim() {
    local name=$1
    cat > "$TMP_BIN/$name"
    chmod +x "$TMP_BIN/$name"
}

# managedFields fixtures.
mf_apply_argocd() {
    printf '%s' '[{"manager":"argocd-application-controller","operation":"Apply","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]'
}
mf_update_kubectl() {
    printf '%s' '[{"manager":"kubectl-client-side-apply","operation":"Update","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]'
}

# A live Deployment for the patch path: main runs 1.2.3 behind a sidecar.
patch_obj() {
    printf '%s' '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"app","namespace":"default","resourceVersion":"41"},"spec":{"template":{"spec":{"containers":[{"name":"side","image":"ghcr.io/x/s:9"},{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}'
}
cron_obj() {
    printf '%s' '{"apiVersion":"batch/v1","kind":"CronJob","metadata":{"name":"nightly","namespace":"batch","resourceVersion":"5"},"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"worker","image":"ghcr.io/acme/n:1.4.2"}]}}}}}}'
}

# kubectl for the patch path. The managedFields read answers from mf.json
# ([] when absent), a read by name from obj.json (patch_obj by default).
# Each patch N logs its arguments, saves its body as patch.body and fails
# with patch.err.N when that exists; an apply saves its body as apply.stdin.
install_patch_kubectl() {
    [ -e "$TMP_DIR/obj.json" ] || printf '%s' "$(patch_obj)" >"$TMP_DIR/obj.json"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
# A real server's object always has a uid; obj.json may leave it out
# (uid-1 then), and no-uid in TMP_DIR reads it as having none.
with_uid() {
    if [ -e "$TMP_DIR/no-uid" ]; then cat; else yq -p=json -o=json -I0 'with(select(.metadata.uid == null); .metadata.uid = "uid-1")'; fi
}
# An apply body naming another uid than the live object's is refused as the
# server refuses it for an object deleted and re-created under the same name
# (k3s v1.34.1, 2026-10-20): stale when the body carries a resourceVersion,
# the uid immutable (a 422) when it does not. The object here always exists,
# so "no existing object was found" (deleted, not re-created) is left to the
# tests that put it in an err file.
uid_check() {
    local live sent rv
    live=$(with_uid <"$TMP_DIR/obj.json" | yq -p=json -oy '.metadata.uid // ""')
    sent=$(yq '.metadata.uid // ""' "$1")
    rv=$(yq '.metadata.resourceVersion // ""' "$1")
    if [ -n "$sent" ] && [ "$sent" != "$live" ]; then
        local res kind name
        kind=$(yq '.kind' "$1")
        name=$(yq '.metadata.name' "$1")
        case "$kind" in
            StatefulSet) res=statefulsets.apps ;;
            DaemonSet) res=daemonsets.apps ;;
            CronJob) res=cronjobs.batch ;;
            Rollout) res=rollouts.argoproj.io ;;
            *) res=deployments.apps ;;
        esac
        if [ -n "$rv" ]; then
            printf '%s\n%s\n' "error: Operation cannot be fulfilled on $res \"$name\": the object has been modified; please apply your changes to the latest version and try again" "Please review the fields above--they currently have other managers. Here" >&2
        else
            echo "The $kind \"$name\" is invalid: metadata.uid: Invalid value: \"$sent\": field is immutable" >&2
        fi
        exit 1
    fi
}
# Only the object's own namespace exists, so a read or write aimed anywhere
# else fails as it would on a server.
ns=$(yq -p=json -oy '.metadata.namespace // "default"' "$TMP_DIR/obj.json")
args=("$@")
for i in "${!args[@]}"; do
    if [ "${args[i]}" = "-n" ] && [ "${args[i+1]-}" != "$ns" ]; then
        echo "Error from server (NotFound): namespaces \"${args[i+1]-}\" not found" >&2
        exit 1
    fi
done
# One with no -n at all would land in the pod's own namespace.
case "$1" in
    get|patch|create)
        if [[ " $* " != *" -n "* ]]; then
            echo "Error from server (NotFound): no namespace given" >&2
            exit 1
        fi
        ;;
esac
# A read or patch of another kind or name finds nothing, as on a server.
# (An object written without a kind or name, as some fixtures are, is not
# checked on that part.)
case "$1" in
    get|patch)
        # Asked for by its qualified resource, never a bare kind: a kind is
        # left to kubectl to resolve, and another CRD may share it.
        want_kind=$(yq -p=json -oy '.kind // ""' "$TMP_DIR/obj.json")
        want_name=$(yq -p=json -oy '.metadata.name // ""' "$TMP_DIR/obj.json")
        case "$want_kind" in
            Deployment) want_res=deployments.apps ;;
            StatefulSet) want_res=statefulsets.apps ;;
            DaemonSet) want_res=daemonsets.apps ;;
            CronJob) want_res=cronjobs.batch ;;
            Rollout) want_res=rollouts.argoproj.io ;;
            *) want_res="" ;;
        esac
        case "$2" in
            deployments.apps|statefulsets.apps|daemonsets.apps|cronjobs.batch|rollouts.argoproj.io) ;;
            *) echo "error: the server doesn't have a resource type \"$2\" (test shim: qualified resources only)" >&2; exit 1 ;;
        esac
        if { [ -n "$want_res" ] && [ "$2" != "$want_res" ]; } \
                || { [ -n "$want_name" ] && [ "$3" != "$want_name" ]; }; then
            echo "Error from server (NotFound): $2 \"$3\" not found" >&2
            exit 1
        fi
        ;;
esac
case "$*" in
    get*jsonpath-as-json*) if [ -r "$TMP_DIR/mf.json" ]; then cat "$TMP_DIR/mf.json"; else printf '[]'; fi ;;
    get*)
        # The object carries the managedFields the strategy read returned,
        # unless it has its own, as one object read from a real server would.
        if [ -r "$TMP_DIR/mf.json" ]; then
            yq -p=json -o=json -I0 '(.metadata.managedFields // load("'"$TMP_DIR"'/mf.json")) as $mf | .metadata.managedFields = $mf' "$TMP_DIR/obj.json"
        else
            cat "$TMP_DIR/obj.json"
        fi | with_uid
        ;;
    patch*)
        # No uid_check: a JSON patch carries no uid or resourceVersion, only
        # tests of name and image (update_json_patch), so on a server a
        # re-created object with both unchanged takes it.
        n=$(( $(cat "$TMP_DIR/patch.count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$TMP_DIR/patch.count"
        while [ $# -gt 0 ]; do
            [ "$1" = "--patch" ] && printf '%s' "$2" >"$TMP_DIR/patch.body"
            shift
        done
        if [ -r "$TMP_DIR/patch.err.$n" ]; then cat "$TMP_DIR/patch.err.$n" >&2; exit 1; fi
        ;;
    apply*--dry-run*) echo "unexpected dry run on the patch path" >&2; exit 99 ;;
    apply*)
        n=$(( $(cat "$TMP_DIR/apply.count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$TMP_DIR/apply.count"
        cat - >"$TMP_DIR/apply.stdin"
        body_ns=$(yq '.metadata.namespace' "$TMP_DIR/apply.stdin")
        if [ "$body_ns" != "$ns" ]; then
            echo "Error from server (NotFound): namespaces \"$body_ns\" not found" >&2
            exit 1
        fi
        uid_check "$TMP_DIR/apply.stdin"
        if [ -r "$TMP_DIR/apply.err.$n" ]; then cat "$TMP_DIR/apply.err.$n" >&2; exit 1; fi
        ;;
esac
SH
}

# owned_obj <kind> <list> <target> <manager> <operation> [<extra-fieldsV1-json>]
# A live object whose <target> in <list> (containers, initContainers or
# imageVolumes) runs ghcr.io/x/y:1.2.3 behind a sidecar container, its name
# and image owned by <manager> through <operation>. Extra owned fields are
# merged into the entry's fieldsV1 (they must exist live: see the pod spec).
owned_obj() {
    local kind=$1 clist=$2 target=$3 manager=$4 op=$5 extra=${6:-'{}'}
    local pod='["spec","template","spec"]' api=apps/v1
    case "$kind" in
        CronJob) pod='["spec","jobTemplate","spec","template","spec"]'
                 api=batch/v1 ;;
        Rollout) api=argoproj.io/v1alpha1 ;;
    esac
    local obj leaf
    obj=$(KIND=$kind API=$api CLIST=$clist TARGET=$target POD=$pod yq -n -o=json -I0 '
        (strenv(POD) | from_json) as $pod
        | {"apiVersion": strenv(API), "kind": strenv(KIND),
           "metadata": {"name": "app", "namespace": "default", "resourceVersion": "41"}}
        | setpath($pod + ["dnsPolicy"]; "ClusterFirst")
        | setpath($pod + ["containers"]; [{"name": "side", "image": "ghcr.io/x/s:9"}])')
    case "$clist" in
        imageVolumes)
            obj=$(POD=$pod TARGET=$target yq -p=json -o=json -I0 '(strenv(POD) | from_json) as $pod | setpath($pod + ["volumes"]; [{"name": strenv(TARGET), "image": {"reference": "ghcr.io/x/y:1.2.3"}}])' <<<"$obj")
            leaf='{"f:name":{},"f:image":{"f:reference":{}}}' ;;
        initContainers)
            obj=$(POD=$pod TARGET=$target yq -p=json -o=json -I0 '(strenv(POD) | from_json) as $pod | setpath($pod + ["initContainers"]; [{"name": strenv(TARGET), "image": "ghcr.io/x/y:1.2.3"}])' <<<"$obj")
            leaf='{"f:name":{},"f:image":{}}' ;;
        *)
            obj=$(POD=$pod TARGET=$target yq -p=json -o=json -I0 '(strenv(POD) | from_json) as $pod | setpath($pod + ["containers"]; [{"name": "side", "image": "ghcr.io/x/s:9"}, {"name": strenv(TARGET), "image": "ghcr.io/x/y:1.2.3"}])' <<<"$obj")
            leaf='{"f:name":{},"f:image":{}}' ;;
    esac
    local flist=$clist seg fs
    [ "$clist" = "imageVolumes" ] && flist=volumes
    # Built as a string: yq's setpath does nothing to a value outside the
    # document, so it cannot assemble a fieldsV1 to merge.
    fs="{\"f:$flist\":{\"k:{\\\"name\\\":\\\"$target\\\"}\":$leaf}}"
    for seg in spec template spec; do
        [ "$kind" = "CronJob" ] && [ "$seg" = "template" ] && fs="{\"f:template\":$fs}" && fs="{\"f:spec\":$fs}" && seg=jobTemplate
        fs="{\"f:$seg\":$fs}"
    done
    FS=$fs MGR=$manager OP=$op EXTRA=$extra yq -p=json -o=json -I0 '
        ((strenv(FS) | from_json) * (strenv(EXTRA) | from_json)) as $fs
        | .metadata.managedFields = [{"manager": strenv(MGR), "operation": strenv(OP), "time": "2026-04-01T10:00:00Z", "fieldsV1": $fs}]' <<<"$obj"
}

# The managedFields array of an object, as the strategy read returns it.
mf_of() {
    yq -p=json -o=json -I0 '.metadata.managedFields'
}

# A live Deployment for the mimic path: argocd owns replicas and main's
# image; a sidecar, dnsPolicy, a defaulted field and status are not its.
mimic_obj() {
    printf '%s' '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"app","namespace":"default","resourceVersion":"41","managedFields":[{"manager":"argocd-application-controller","operation":"Apply","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:replicas":{},"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{".":{},"f:name":{},"f:image":{}}}}}}}},{"manager":"kube-controller-manager","operation":"Update","subresource":"status","fieldsV1":{"f:status":{}}}]},"spec":{"replicas":3,"template":{"spec":{"dnsPolicy":"ClusterFirst","containers":[{"name":"sidecar","image":"ghcr.io/x/side:9"},{"name":"main","image":"ghcr.io/x/y:1.2.3","terminationMessagePath":"/dev/termination-log"}]}}},"status":{"replicas":3}}'
}

# kubectl for the mimic path. The managedFields read that picks the strategy
# answers from mf.json, the object read from obj.json, and a server-side dry
# run from dry.json (default: obj.json, so the owner's set comes back as it
# went) or fails with dry.err, or dry.err.N for the Nth dry run only. Each
# real apply N saves its body as apply.stdin and fails with apply.err.N when
# that exists.
install_mimic_kubectl() {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    printf '%s' "$(mimic_obj)" >"$TMP_DIR/obj.json"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
# A real server's object always has a uid; obj.json may leave it out
# (uid-1 then), and no-uid in TMP_DIR reads it as having none.
with_uid() {
    if [ -e "$TMP_DIR/no-uid" ]; then cat; else yq -p=json -o=json -I0 'with(select(.metadata.uid == null); .metadata.uid = "uid-1")'; fi
}
# An apply body naming another uid than the live object's is refused as the
# server refuses it for an object deleted and re-created under the same name
# (k3s v1.34.1, 2026-10-20): stale when the body carries a resourceVersion,
# the uid immutable (a 422) when it does not. The object here always exists,
# so "no existing object was found" (deleted, not re-created) is left to the
# tests that put it in an err file.
uid_check() {
    local live sent rv
    live=$(with_uid <"$TMP_DIR/obj.json" | yq -p=json -oy '.metadata.uid // ""')
    sent=$(yq '.metadata.uid // ""' "$1")
    rv=$(yq '.metadata.resourceVersion // ""' "$1")
    if [ -n "$sent" ] && [ "$sent" != "$live" ]; then
        local res kind name
        kind=$(yq '.kind' "$1")
        name=$(yq '.metadata.name' "$1")
        case "$kind" in
            StatefulSet) res=statefulsets.apps ;;
            DaemonSet) res=daemonsets.apps ;;
            CronJob) res=cronjobs.batch ;;
            Rollout) res=rollouts.argoproj.io ;;
            *) res=deployments.apps ;;
        esac
        if [ -n "$rv" ]; then
            printf '%s\n%s\n' "error: Operation cannot be fulfilled on $res \"$name\": the object has been modified; please apply your changes to the latest version and try again" "Please review the fields above--they currently have other managers. Here" >&2
        else
            echo "The $kind \"$name\" is invalid: metadata.uid: Invalid value: \"$sent\": field is immutable" >&2
        fi
        exit 1
    fi
}
# Only the object's own namespace exists, so a read or write aimed anywhere
# else fails as it would on a server.
ns=$(yq -p=json -oy '.metadata.namespace // "default"' "$TMP_DIR/obj.json")
args=("$@")
for i in "${!args[@]}"; do
    if [ "${args[i]}" = "-n" ] && [ "${args[i+1]-}" != "$ns" ]; then
        echo "Error from server (NotFound): namespaces \"${args[i+1]-}\" not found" >&2
        exit 1
    fi
done
# One with no -n at all would land in the pod's own namespace.
case "$1" in
    get|patch|create)
        if [[ " $* " != *" -n "* ]]; then
            echo "Error from server (NotFound): no namespace given" >&2
            exit 1
        fi
        ;;
esac
# A read or patch of another kind or name finds nothing, as on a server.
# (An object written without a kind or name, as some fixtures are, is not
# checked on that part.)
case "$1" in
    get|patch)
        # Asked for by its qualified resource, never a bare kind: a kind is
        # left to kubectl to resolve, and another CRD may share it.
        want_kind=$(yq -p=json -oy '.kind // ""' "$TMP_DIR/obj.json")
        want_name=$(yq -p=json -oy '.metadata.name // ""' "$TMP_DIR/obj.json")
        case "$want_kind" in
            Deployment) want_res=deployments.apps ;;
            StatefulSet) want_res=statefulsets.apps ;;
            DaemonSet) want_res=daemonsets.apps ;;
            CronJob) want_res=cronjobs.batch ;;
            Rollout) want_res=rollouts.argoproj.io ;;
            *) want_res="" ;;
        esac
        case "$2" in
            deployments.apps|statefulsets.apps|daemonsets.apps|cronjobs.batch|rollouts.argoproj.io) ;;
            *) echo "error: the server doesn't have a resource type \"$2\" (test shim: qualified resources only)" >&2; exit 1 ;;
        esac
        if { [ -n "$want_res" ] && [ "$2" != "$want_res" ]; } \
                || { [ -n "$want_name" ] && [ "$3" != "$want_name" ]; }; then
            echo "Error from server (NotFound): $2 \"$3\" not found" >&2
            exit 1
        fi
        ;;
esac
case "$*" in
    get*jsonpath-as-json*) cat "$TMP_DIR/mf.json" ;;
    get*) with_uid <"$TMP_DIR/obj.json" ;;
    apply*--dry-run=server*)
        n=$(( $(cat "$TMP_DIR/dry.count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$TMP_DIR/dry.count"
        cat - >"$TMP_DIR/dry.stdin"
        body_ns=$(yq '.metadata.namespace' "$TMP_DIR/dry.stdin")
        if [ "$body_ns" != "$ns" ]; then
            echo "Error from server (NotFound): namespaces \"$body_ns\" not found" >&2
            exit 1
        fi
        uid_check "$TMP_DIR/dry.stdin"
        if [ -r "$TMP_DIR/dry.err" ]; then cat "$TMP_DIR/dry.err" >&2; exit 1; fi
        if [ -r "$TMP_DIR/dry.err.$n" ]; then cat "$TMP_DIR/dry.err.$n" >&2; exit 1; fi
        # A real server's -o json carries managedFields only when asked.
        if [ -r "$TMP_DIR/dry.json" ]; then cat "$TMP_DIR/dry.json"; else cat "$TMP_DIR/obj.json"; fi | with_uid \
            | if [[ " $* " == *" --show-managed-fields "* ]]; then cat; else yq -p=json -o=json -I0 'del(.metadata.managedFields)'; fi
        ;;
    apply*)
        n=$(( $(cat "$TMP_DIR/apply.count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$TMP_DIR/apply.count"
        cat - >"$TMP_DIR/apply.stdin"
        body_ns=$(yq '.metadata.namespace' "$TMP_DIR/apply.stdin")
        if [ "$body_ns" != "$ns" ]; then
            echo "Error from server (NotFound): namespaces \"$body_ns\" not found" >&2
            exit 1
        fi
        uid_check "$TMP_DIR/apply.stdin"
        if [ -r "$TMP_DIR/apply.err.$n" ]; then cat "$TMP_DIR/apply.err.$n" >&2; exit 1; fi
        ;;
esac
SH
}

# obj_kind <kind>: the stand-in object becomes that kind, as a read of it
# by that kind would return; the shims refuse a read of any other.
obj_kind() {
    local api=apps/v1
    case "$1" in
        Rollout) api=argoproj.io/v1alpha1 ;;
        CronJob) api=batch/v1 ;;
    esac
    KIND=$1 API=$api yq -i -p=json -o=json -I0 '.kind = strenv(KIND) | .apiVersion = strenv(API)' "$TMP_DIR/obj.json"
}

# --- update_resource_name ---

@test "resource_name: every kind maps to its group-qualified resource" {
    local pair
    for pair in Deployment=deployments.apps StatefulSet=statefulsets.apps DaemonSet=daemonsets.apps \
            CronJob=cronjobs.batch Rollout=rollouts.argoproj.io; do
        [ "$(update_resource_name "${pair%%=*}")" = "${pair#*=}" ] || { echo "$pair"; return 1; }
    done
    run update_resource_name Pod
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# --- update_json_patch ---

# A pod spec with two containers, an init container and an image volume.
patch_live() {
    printf '%s' '{"metadata":{"resourceVersion":"9"},"spec":{"template":{"spec":{"initContainers":[{"name":"migrate","image":"ghcr.io/x/m:1"}],"containers":[{"name":"side","image":"ghcr.io/x/s:9"},{"name":"main","image":"ghcr.io/x/y:1.2.3"}],"volumes":[{"name":"cfg","configMap":{"name":"c"}},{"name":"models","image":{"reference":"ghcr.io/x/v:1"}}]}}}}'
}

@test "json_patch: tests name and current image, then replaces, at the live index" {
    update_json_patch Deployment containers main ghcr.io/x/y:1.2.4 "$(patch_live)"
    [ "$UPDATE_JSON_PATCH" = '[{"op":"test","path":"/spec/template/spec/containers/1/name","value":"main"},{"op":"test","path":"/spec/template/spec/containers/1/image","value":"ghcr.io/x/y:1.2.3"},{"op":"replace","path":"/spec/template/spec/containers/1/image","value":"ghcr.io/x/y:1.2.4"}]' ]
}

@test "json_patch: an init container is addressed under initContainers" {
    update_json_patch Deployment initContainers migrate ghcr.io/x/m:2 "$(patch_live)"
    [[ "$UPDATE_JSON_PATCH" == *'"op":"replace","path":"/spec/template/spec/initContainers/0/image","value":"ghcr.io/x/m:2"'* ]]
}

@test "json_patch: an image volume's reference" {
    update_json_patch Deployment imageVolumes models ghcr.io/x/v:2 "$(patch_live)"
    [ "$UPDATE_JSON_PATCH" = '[{"op":"test","path":"/spec/template/spec/volumes/1/name","value":"models"},{"op":"test","path":"/spec/template/spec/volumes/1/image/reference","value":"ghcr.io/x/v:1"},{"op":"replace","path":"/spec/template/spec/volumes/1/image/reference","value":"ghcr.io/x/v:2"}]' ]
}

@test "json_patch: CronJob nests under jobTemplate" {
    update_json_patch CronJob containers job ghcr.io/x/y:2 \
        '{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"job","image":"ghcr.io/x/y:1"}]}}}}}}'
    [[ "$UPDATE_JSON_PATCH" == *'"path":"/spec/jobTemplate/spec/template/spec/containers/0/image","value":"ghcr.io/x/y:2"'* ]]
}

@test "json_patch: a Rollout takes the same patch as a Deployment" {
    update_json_patch Rollout containers main ghcr.io/x/y:1.2.4 "$(patch_live)"
    [[ "$UPDATE_JSON_PATCH" == *'"path":"/spec/template/spec/containers/1/image"'* ]]
}

@test "json_patch: a kind Keelson does not update returns 3" {
    local rc=0
    update_json_patch Pod containers main ghcr.io/x/y:2 "$(patch_live)" || rc=$?
    [ "$rc" -eq 3 ]
}

@test "json_patch: no element by that name is refused" {
    if update_json_patch Deployment containers absent ghcr.io/x/y:2 "$(patch_live)"; then false; fi
    [ -z "$UPDATE_JSON_PATCH" ]
}

@test "json_patch: a volume with no image is not an image volume" {
    if update_json_patch Deployment imageVolumes cfg ghcr.io/x/v:2 "$(patch_live)"; then false; fi
}

@test "apiversion: Rollout is an Argo CRD, not apps/v1" {
    run update_apiversion Rollout
    [ "$status" -eq 0 ]
    [ "$output" = "argoproj.io/v1alpha1" ]
}

@test "minimal_manifest: Rollout carries the Argo apiVersion" {
    run update_minimal_manifest Rollout default app containers main ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"apiVersion: argoproj.io/v1alpha1"* ]]
    [[ "$output" == *"kind: Rollout"* ]]
}

@test "minimal_manifest: an init container claims initContainers" {
    run update_minimal_manifest Deployment default app initContainers migrate ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"initContainers:"* ]]
    [[ "$output" != *$'\n'"      containers:"* ]]
}

# --- update_apply: default strategy dispatch ---

@test "update_apply: success logs the sentence and returns 0" {
    install_patch_kubectl
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deployment 'app' in 'default' updated from 1.2.3 to 1.2.4 by claim-patch (as configured) for image 'ghcr.io/x/y'."* ]]
    once 'updated from 1.2.3 to 1.2.4'
}

@test "update_apply: JSON output includes strategy kv" {
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"event":"update-applied"'* ]]
    [[ "$output" == *'"strategy":"claim-patch"'* ]]
    [[ "$output" == *'"kind":"Deployment"'* ]]
    [[ "$output" == *'"from":"1.2.3"'* ]]
    [[ "$output" == *'"to":"1.2.4"'* ]]
}

@test "update_apply: unowned -> UNOWNED=claim-patch as field-manager=keelson" {
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"operation":"Update"'* ]]
    [[ "$output" == *'"strategy":"claim-patch"'* ]]
    grep -q -- "patch deployments.apps app -n default --type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
    [ "$(cat "$TMP_DIR/patch.body")" = '[{"op":"test","path":"/spec/template/spec/containers/1/name","value":"main"},{"op":"test","path":"/spec/template/spec/containers/1/image","value":"ghcr.io/x/y:1.2.3"},{"op":"replace","path":"/spec/template/spec/containers/1/image","value":"ghcr.io/x/y:1.2.4"}]' ]
}

@test "update_apply: update-owned -> UPDATE_OWNED=mimic patches as the owner" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"kubectl-client-side-apply"'* ]]
    [[ "$output" == *'"operation":"Update"'* ]]
    [[ "$output" == *'"strategy":"mimic"'* ]]
    [[ "$output" == *"by mimic (as configured)"* ]]
    grep -q -- "patch deployments.apps app -n default --type=json --field-manager=kubectl-client-side-apply" "$TMP_DIR/kubectl.log"
    if grep -q -- "apply --server-side" "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: update-owned mimic on a Rollout is a patch too" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    obj_kind Rollout
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -q -- "patch rollouts.argoproj.io app -n default --type=json --field-manager=kubectl-client-side-apply" "$TMP_DIR/kubectl.log"
}

@test "update_apply: update-owned -> UPDATE_OWNED=claim-patch patches as keelson" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-patch \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-patch"'* ]]
    grep -q -- "--type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: update-owned -> UPDATE_OWNED=claim-apply forces as keelson" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-apply"'* ]]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
    [ "$(yq '.spec.template.spec.containers[0].image' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/y:1.2.4" ]
    [ "$(yq '.spec.template.spec.containers[0].name' "$TMP_DIR/apply.stdin")" = "main" ]
}

@test "update_apply: apply-owned -> APPLY_OWNED=mimic applies the owner's set as that manager" {
    install_mimic_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"argocd-application-controller"'* ]]
    [[ "$output" == *'"operation":"Apply"'* ]]
    [[ "$output" == *'"strategy":"mimic"'* ]]
    [[ "$output" == *"updated from 1.2.3 to 1.2.4 by mimic (as configured) for image 'ghcr.io/x/y'."* ]]
    once 'updated from 1.2.3 to 1.2.4'
    # The guard needs the owner's set back from the dry run.
    grep -qx -- "apply --server-side --dry-run=server --field-manager=argocd-application-controller -o json --show-managed-fields -f -" "$TMP_DIR/kubectl.log"
    grep -q -- "apply --server-side --field-manager=argocd-application-controller -f -" "$TMP_DIR/kubectl.log"
    if grep -q -- "--force-conflicts" "$TMP_DIR/kubectl.log"; then false; fi
    [ "$(cat "$TMP_DIR/apply.stdin")" = '{"spec":{"template":{"spec":{"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.4"}]}},"replicas":3},"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"app","namespace":"default","resourceVersion":"41","uid":"uid-1"}}' ]
    # What the dry run was shown is what was written.
    [ "$(cat "$TMP_DIR/dry.stdin")" = "$(cat "$TMP_DIR/apply.stdin")" ]
}

@test "update_apply: managedFields passed in spare the strategy read, not the object read" {
    install_mimic_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "$(mf_apply_argocd)"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"mimic"'* ]]
    if grep -q -- "jsonpath-as-json" "$TMP_DIR/kubectl.log"; then false; fi
    grep -q -- "get deployments.apps app -n default -o json --show-managed-fields" "$TMP_DIR/kubectl.log"
}

@test "update_apply: mimic refuses when the dry run would change the owner's set" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:paused"] = {}' >"$TMP_DIR/dry.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-mimic-refused"'* ]]
    [[ "$output" == *"a dry run showed the write would change what 'argocd-application-controller' owns. Nothing was written."* ]]
    [ ! -e "$TMP_DIR/apply.stdin" ]
}

@test "update_apply: mimic skips when the owner has gone by the time it reads" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 'del(.metadata.managedFields[0])' >"$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *'"level":"WARN","event":"update-owner-moved"'* ]]
    once '"event":"update-owner-moved"'
    [[ "$output" == *"the image is now owned by 'nobody'. Nothing was written; the next poll decides again."* ]]
    [ ! -e "$TMP_DIR/dry.stdin" ]
    [ ! -e "$TMP_DIR/apply.stdin" ]
}

@test "update_apply: mimic skips when the owner no longer owns the image" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 'del(.metadata.managedFields[0].fieldsV1["f:spec"]["f:template"])' >"$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *'"event":"update-owner-moved"'* ]]
    [ ! -e "$TMP_DIR/dry.stdin" ]
}

@test "update_apply: mimic reads again and retries once when the object moved" {
    install_mimic_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"by mimic (as configured)"* ]]
    [ "$(grep -c -- "-o json --show-managed-fields" "$TMP_DIR/kubectl.log")" -eq 4 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 2 ]
}

@test "update_apply: mimic gives up after the object moves three times, and does not call it a conflict" {
    install_mimic_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.1"
    cp "$TMP_DIR/apply.err.1" "$TMP_DIR/apply.err.2"
    cp "$TMP_DIR/apply.err.1" "$TMP_DIR/apply.err.3"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed between read and write three times running"* ]]
    at_level ERROR 'three times running'
    [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 3 ]
}

@test "update_apply: CronJob mimic changes the image under jobTemplate" {
    install_mimic_kubectl
    printf '%s' '[{"manager":"kaptain","operation":"Apply","fieldsV1":{"f:spec":{"f:jobTemplate":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"job\"}":{"f:name":{},"f:image":{}}}}}}}}}}]' >"$TMP_DIR/mf.json"
    printf '%s' '{"apiVersion":"batch/v1","kind":"CronJob","metadata":{"name":"cron","namespace":"default","resourceVersion":"5","managedFields":[{"manager":"kaptain","operation":"Apply","fieldsV1":{"f:spec":{"f:schedule":{},"f:jobTemplate":{"f:spec":{"f:template":{"f:spec":{"f:restartPolicy":{},"f:containers":{"k:{\"name\":\"job\"}":{"f:name":{},"f:image":{}}}}}}}}}}]},"spec":{"schedule":"0 * * * *","suspend":true,"jobTemplate":{"spec":{"template":{"spec":{"restartPolicy":"Never","containers":[{"name":"job","image":"ghcr.io/x/y:1.2.3"}]}}}}}}' >"$TMP_DIR/obj.json"
    run emit update_apply CronJob default cron containers job ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/apply.stdin")" = '{"spec":{"schedule":"0 * * * *","jobTemplate":{"spec":{"template":{"spec":{"restartPolicy":"Never","containers":[{"name":"job","image":"ghcr.io/x/y:1.2.4"}]}}}}},"apiVersion":"batch/v1","kind":"CronJob","metadata":{"name":"cron","namespace":"default","resourceVersion":"5","uid":"uid-1"}}' ]
}

@test "mimic_set_image: an image volume's reference" {
    update_mimic_set_image Deployment imageVolumes models ghcr.io/x/m:2 \
        '{"spec":{"template":{"spec":{"volumes":[{"name":"models","image":{"reference":"ghcr.io/x/m:1"}}]}}}}'
    [ "$UPDATE_MIMIC_MANIFEST" = '{"spec":{"template":{"spec":{"volumes":[{"name":"models","image":{"reference":"ghcr.io/x/m:2"}}]}}}}' ]
}

@test "mimic_set_image: an init container" {
    update_mimic_set_image Deployment initContainers migrate ghcr.io/x/m:2 \
        '{"spec":{"template":{"spec":{"initContainers":[{"name":"migrate","image":"ghcr.io/x/m:1"}]}}}}'
    [ "$UPDATE_MIMIC_MANIFEST" = '{"spec":{"template":{"spec":{"initContainers":[{"name":"migrate","image":"ghcr.io/x/m:2"}]}}}}' ]
}

@test "mimic_set_image: refuses an element the set holds without its image" {
    if update_mimic_set_image Deployment containers main ghcr.io/x/y:2 \
        '{"spec":{"template":{"spec":{"containers":[{"name":"main"}]}}}}'; then false; fi
}

# --- update_apply: global strategy overrides ---

@test "update_apply: apply-owned -> APPLY_OWNED=claim-patch patches as keelson" {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"strategy":"claim-patch"'* ]]
    grep -q -- "patch deployments.apps app -n default --type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: apply-owned -> APPLY_OWNED=claim-apply forces as keelson" {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-apply"'* ]]
    [[ "$output" == *"by claim-apply (as configured)"* ]]
    once 'updated from 1.2.3 to 1.2.4'
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
    [ "$(yq '.spec.template.spec.containers[0].image' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/y:1.2.4" ]
}

@test "update_apply: unowned -> UNOWNED=claim-apply applies as keelson, forced" {
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"operation":"Apply"'* ]]
    [[ "$output" == *'"strategy":"claim-apply"'* ]]
    # Forced even unowned: the server records a before-first-apply owner.
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
}

# A workload outside "default": every read and write must name its own
# namespace, which the shims enforce.
in_prod() {
    yq -i -p=json -o=json -I0 '.metadata.namespace = "prod"' "$TMP_DIR/obj.json"
}

@test "update_apply: another namespace -> claim-patch reads and patches there" {
    install_patch_kubectl
    in_prod
    run emit update_apply Deployment prod app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -q -- "patch deployments.apps app -n prod --type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: another namespace -> update-owned mimic reads and patches there" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    in_prod
    run emit update_apply Deployment prod app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -q -- "patch deployments.apps app -n prod --type=json --field-manager=kubectl-client-side-apply" "$TMP_DIR/kubectl.log"
}

@test "update_apply: another namespace -> claim-apply sends its manifest there" {
    install_patch_kubectl
    in_prod
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply     run emit update_apply Deployment prod app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq '.metadata.namespace' "$TMP_DIR/apply.stdin")" = "prod" ]
}

@test "minimal_manifest: a CronJob init container goes under initContainers" {
    run update_minimal_manifest CronJob default cron initContainers migrate ghcr.io/x/m:2
    [ "$status" -eq 0 ]
    [ "$(yq '.spec.jobTemplate.spec.template.spec.initContainers[0].name' <<<"$output")" = "migrate" ]
    [ "$(yq '.spec.jobTemplate.spec.template.spec.initContainers[0].image' <<<"$output")" = "ghcr.io/x/m:2" ]
    [ "$(yq '.spec.jobTemplate.spec.template.spec.containers' <<<"$output")" = "null" ]
}

@test "minimal_manifest: every shape carries the namespace it is given" {
    local kind clist
    for kind in Deployment CronJob; do
        for clist in containers imageVolumes; do
            run update_minimal_manifest "$kind" prod app "$clist" main ghcr.io/x/y:1.2.4
            [ "$status" -eq 0 ]
            [ "$(yq '.metadata.namespace' <<<"$output")" = "prod" ] || { echo "$kind $clist: $output"; return 1; }
        done
    done
}

@test "update_apply: another namespace -> apply-owned mimic dry-runs and applies there" {
    install_mimic_kubectl
    in_prod
    run emit update_apply Deployment prod app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq '.metadata.namespace' "$TMP_DIR/dry.stdin")" = "prod" ]
    [ "$(yq '.metadata.namespace' "$TMP_DIR/apply.stdin")" = "prod" ]
}

# --- update_apply: annotation overrides ---

@test "update_apply: annotation claim-apply overrides APPLY_OWNED=mimic" {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    local ann='keelson.pro/field-manager-strategy=claim-apply'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *'"strategy":"claim-apply"'* ]]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: mimic on unowned claims the image with a patch as keelson" {
    install_patch_kubectl
    local ann='keelson.pro/field-manager-strategy=mimic'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"mimic"'* ]]
    [[ "$output" == *'"manager":"keelson"'* ]]
    [[ "$output" == *"updated from 1.2.3 to 1.2.4 by claim-patch (fallback from mimic) for image 'ghcr.io/x/y'."* ]]
    grep -q -- "patch deployments.apps app -n default --type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: annotated mimic on unowned refuses when fallback is not allowed" {
    install_patch_kubectl
    local ann='keelson.pro/field-manager-strategy=mimic'
    KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED=false \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-mimic-refused"'* ]]
    [[ "$output" == *"to image 'ghcr.io/x/y:1.2.4': nobody owns the image to be, and falling back from an annotated mimic is not allowed. Nothing was written."* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: an unset strategy refuses rather than reporting success" {
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED='' \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-invalid-strategy"'* ]]
    at_level ERROR '"event":"update-invalid-strategy"'
    once '"event":"update-invalid-strategy"'
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: the old annotation values are rejected, not translated" {
    install_patch_kubectl
    local v
    for v in patch claim; do
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "keelson.pro/field-manager-strategy=$v"
        [ "$status" -eq 1 ]
        [[ "$output" == *'"event":"update-invalid-strategy-annotation"'* ]]
        once '"event":"update-invalid-strategy-annotation"'
        [[ "$output" == *"must be one of: mimic, claim-patch, claim-apply."* ]]
    done
}

@test "update_apply: annotation strategy invalid value logs error and returns 1" {
    install_patch_kubectl
    local ann='keelson.pro/field-manager-strategy=mimick'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 1 ]
    one_error
    [[ "$output" == *'"event":"update-invalid-strategy-annotation"'* ]]
    once '"event":"update-invalid-strategy-annotation"'
    [[ "$output" == *'"value":"mimick"'* ]]
    if grep -q -- "patch \|apply " "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: per-container annotation wins over workload-wide" {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    local ann=$'keelson.pro/field-manager-strategy=mimic\nkeelson.pro/field-manager-strategy.containers.main=claim-patch'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-patch"'* ]]
    [[ "$output" == *'"manager":"keelson"'* ]]
}

# --- update_apply: SSA failure branches ---

# add_entry <manager> <operation>: another managedFields entry on the live
# object, holding a field of its own.
add_entry() {
    M=$1 OP=$2 yq -i -p=json -o=json -I0 '.metadata.managedFields += [{"manager": strenv(M), "operation": strenv(OP), "time": "2026-03-01T10:00:00Z", "fieldsV1": {"f:spec": {"f:replicas": {}}}}]' "$TMP_DIR/obj.json"
}

# image_applier <manager>: another Apply entry on the live object, co-owning
# main's image (older than the owner's, so the owner keeps it), in obj.json
# and mf.json alike.
image_applier() {
    M=$1 yq -i -p=json -o=json -I0 '.metadata.managedFields += [{"manager": strenv(M), "operation": "Apply", "time": "2026-03-01T10:00:00Z", "fieldsV1": {"f:spec": {"f:template": {"f:spec": {"f:containers": {"k:{\"name\":\"main\"}": {".": {}, "f:name": {}, "f:image": {}}}}}}}}]' "$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
}

@test "update_apply: SSA conflict logs update-apply-conflict and returns 1" {
    # flux applies the fields too: two appliers, so no force.
    install_mimic_kubectl
    add_entry flux Apply
    apply_409 'Apply failed with 1 conflict: conflict with "flux": .spec.replicas' >"$TMP_DIR/dry.err"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    [[ "$output" == *'"event":"update-apply-conflict"'* ]]
    once '"event":"update-apply-conflict"'
    [[ "$output" == *'"event":"update-apply-conflict"'*'"operation":"Apply"'* ]]
    [[ "$output" == *'"manager":"argocd-application-controller"'* ]]
    [[ "$output" == *'"strategy":"mimic"'* ]]
    [[ "$output" == *"field-ownership conflict with 'flux'; refusing to force. Nothing was written. 'flux' also applies these fields (Apply); two managers apply this workload, so Keelson won't pick one. Remove one, or annotate the workload with a claim strategy."* ]]
    [[ "$output" == *'"reason":"error: Apply failed with 1 conflict'* ]]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    [ ! -e "$TMP_DIR/apply.stdin" ]
}

@test "update_apply: mimic forces past the owner's own Update entry" {
    install_mimic_kubectl
    apply_409 'Apply failed with 1 conflict: conflict with "argocd-application-controller" using apps/v1: .spec.template.spec.containers[name="main"].image' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"by mimic (as configured), forced past its own Update entry, for image 'ghcr.io/x/y'."* ]]
}

@test "update_apply: mimic refuses to force past the owner's own Apply entry on a subresource" {
    # Named with no using: an Apply entry, the owner's own on scale, which
    # a force would take from it; not its Update entry.
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields += [{"manager": "argocd-application-controller", "operation": "Apply", "subresource": "scale", "time": "2026-03-01T10:00:00Z", "fieldsV1": {"f:spec": {"f:replicas": {}}}}]' "$TMP_DIR/obj.json"
    apply_409 'Apply failed with 1 conflict: conflict with "argocd-application-controller" with subresource "scale": .spec.replicas' >"$TMP_DIR/dry.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    [[ "$output" == *"'argocd-application-controller' also holds these fields by another Apply entry of its own, so Keelson won't force past it. Remove that entry, or annotate the workload with a claim strategy."* ]]
    [[ "$output" != *"its own Update entry"* ]]
    [[ "$output" != *"(an Update entry under its own name)"* ]]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    if grep -q -- "--force-conflicts" "$TMP_DIR/kubectl.log"; then false; fi
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: the owner named as Update-held and Apply-held is still refused" {
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields += [{"manager": "argocd-application-controller", "operation": "Apply", "subresource": "scale", "time": "2026-03-01T10:00:00Z", "fieldsV1": {"f:spec": {"f:replicas": {}}}}]' "$TMP_DIR/obj.json"
    apply_409 'Apply failed with 2 conflicts: conflicts with "argocd-application-controller" using apps/v1:
- .spec.template.spec.containers[name="main"].image
conflicts with "argocd-application-controller" with subresource "scale":
- .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"'argocd-application-controller' also holds these fields by another Apply entry of its own, so Keelson won't force past it."* ]]
    [[ "$output" == *"conflict with 'argocd-application-controller' (an Update entry under its own name)"* ]]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    if grep -q -- "--force-conflicts" "$TMP_DIR/kubectl.log"; then false; fi
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: an ownership conflict in the server-error form plans the force too" {
    install_mimic_kubectl
    add_entry kubectl-client-side-apply Update
    printf 'Error from server (Conflict): %s\n%s\n' 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.template.spec.containers[name="main"].image' "$KUBECTL_APPLY_SPEECH" >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past Update entries of 'kubectl-client-side-apply', for image 'ghcr.io/x/y'."* ]]
    grep -qx -- "apply --server-side --field-manager=argocd-application-controller --force-conflicts -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: mimic forces past a co-owner holding only Update entries, dry run and real apply alike" {
    install_mimic_kubectl
    add_entry kubectl-client-side-apply Update
    apply_409 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.template.spec.containers[name="main"].image' >"$TMP_DIR/dry.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    once '"event":"update-applied"'
    [[ "$output" == *"by mimic (as configured), forced past Update entries of 'kubectl-client-side-apply', for image 'ghcr.io/x/y'."* ]]
    # The unforced dry run, the forced one, then the forced real apply.
    [ "$(grep -cx -- "apply --server-side --dry-run=server --field-manager=argocd-application-controller -o json --show-managed-fields -f -" "$TMP_DIR/kubectl.log")" -eq 1 ]
    [ "$(grep -cx -- "apply --server-side --dry-run=server --field-manager=argocd-application-controller --force-conflicts -o json --show-managed-fields -f -" "$TMP_DIR/kubectl.log")" -eq 1 ]
    grep -qx -- "apply --server-side --field-manager=argocd-application-controller --force-conflicts -f -" "$TMP_DIR/kubectl.log"
    [[ "$output" != *'"level":"WARN"'* ]]
}

@test "update_apply: mimic forces past keelson's own Apply entry" {
    # keelson's Apply entry co-owns the image beside the Argo owner: not a
    # second applier to the pre-check, and forced past on the dry run.
    install_mimic_kubectl
    image_applier keelson
    apply_409 'Apply failed with 1 conflict: conflict with "keelson": .spec.template.spec.containers[name="main"].image' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past keelson's own Apply entry, for image"* ]]
    [[ "$output" != *"Update entries of 'keelson'"* ]]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 2 ]
    grep -qx -- "apply --server-side --field-manager=argocd-application-controller --force-conflicts -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: mimic runs as argocd past keelson's Apply entry, whichever is newer" {
    # Picked by time alone, a newer keelson entry made keelson the owner and
    # argocd a second applier, refused on every poll.
    local t
    for t in 2026-03-01T10:00:00Z 2026-05-01T10:00:00Z; do
        rm -f "$TMP_DIR/dry.count" "$TMP_DIR/kubectl.log" "$TMP_DIR/apply.stdin" "$TMP_DIR/apply.count"
        install_mimic_kubectl
        image_applier keelson
        T=$t yq -i -p=json -o=json -I0 '(.metadata.managedFields[] | select(.manager == "keelson")).time = strenv(T)' "$TMP_DIR/obj.json"
        mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
        apply_409 'Apply failed with 1 conflict: conflict with "keelson": .spec.template.spec.containers[name="main"].image' >"$TMP_DIR/dry.err.1"
        run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 0 ]
        [[ "$output" == *"forced past keelson's own Apply entry, for image"* ]]
        [[ "$output" != *"also applies"* ]]
        [ "$(cat "$TMP_DIR/dry.count")" -eq 2 ]
        grep -qx -- "apply --server-side --field-manager=argocd-application-controller --force-conflicts -f -" "$TMP_DIR/kubectl.log"
        if grep -q -- "--field-manager=keelson" "$TMP_DIR/kubectl.log"; then false; fi
    done
}

@test "update_apply: an Update co-owner beside another applier is not forced past" {
    install_mimic_kubectl
    add_entry kubectl-client-side-apply Update
    add_entry flux Apply
    apply_409 'Apply failed with 2 conflicts: conflicts with "flux":
- .spec.paused
conflicts with "kubectl-client-side-apply" using apps/v1:
- .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"'flux' also applies these fields (Apply); two managers apply this workload"* ]]
    if grep -q -- "--force-conflicts" "$TMP_DIR/kubectl.log"; then false; fi
    [ ! -e "$TMP_DIR/apply.stdin" ]
}

@test "update_apply: another manager's Apply entry on the image is refused before any dry run" {
    # Owner "kubectl": the server would retry a conflicting dry run forced
    # and hand it ci's image, so the refusal cannot wait for the conflict.
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields[0].manager = "kubectl"' "$TMP_DIR/obj.json"
    image_applier ci
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    once '"event":"update-mimic-refused"'
    [[ "$output" == *"'ci' also applies this image (Apply); two managers apply this workload, so Keelson won't pick one. Remove one, or annotate the workload with a claim strategy"* ]]
    [[ "$output" == *'"manager":"kubectl"'* ]]
    [ ! -e "$TMP_DIR/dry.count" ]
    [ ! -e "$TMP_DIR/apply.stdin" ]
}

@test "update_apply: an Apply co-owner of an unrelated field only is not refused before the dry run" {
    install_mimic_kubectl
    add_entry ci Apply
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" != *"also applies this image"* ]]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    [ -e "$TMP_DIR/apply.stdin" ]
}

@test "update_apply: keelson's Apply entry off the conflict is not called its own Apply entry" {
    # keelson holds an Apply entry elsewhere on the object, but the server
    # names its conflicting field as held by an Update entry.
    install_mimic_kubectl
    add_entry keelson Apply
    add_entry keelson Update
    apply_409 'Apply failed with 1 conflict: conflict with "keelson" using apps/v1: .spec.template.spec.containers[name="main"].image' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past Update entries of 'keelson', for image"* ]]
    [[ "$output" != *"keelson's own Apply entry"* ]]
}

@test "update_apply: mimic refuses, not blaming a co-owner, when who applies cannot be read" {
    # helm holds only an Update entry, so would be forced past; the lookup
    # of who applies failing must say so, not call helm an applier.
    install_mimic_kubectl
    add_entry helm Update
    apply_409 'Apply failed with 1 conflict: conflict with "helm" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    yq() {
        if [[ $* == *'select(.operation == "Apply" and (.subresource // "") == "") | .manager // "" | @base64'* ]]; then
            return 1
        fi
        command yq "$@"
    }
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    [[ "$output" == *"conflict with 'helm'; refusing to force. Nothing was written. Keelson could not read the workload's field managers to tell whether another one applies these fields, so it will not force past them."* ]]
    [[ "$output" != *"Fix the owning manager's source of truth."* ]]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: a forced dry run that would change the owner's set is still refused" {
    install_mimic_kubectl
    add_entry kubectl-client-side-apply Update
    apply_409 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.paused' >"$TMP_DIR/dry.err.1"
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:paused"] = {}' >"$TMP_DIR/dry.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"a dry run showed the write would change what 'argocd-application-controller' owns"* ]]
    [ ! -e "$TMP_DIR/apply.stdin" ]
}

@test "conflict_managers: each manager named once, in order" {
    update_conflict_managers 'Apply failed with 3 conflicts: conflicts with "flux" using apps/v1:
- .spec.replicas
- .spec.template.spec.containers[name="main"].image
conflict with "helm": .metadata.labels.app
conflict with "flux" using apps/v1: .spec.paused'
    [ "$UPDATE_CONFLICT_MANAGERS" = "'flux', 'helm'" ]
}

@test "conflict_managers: none found leaves it empty" {
    UPDATE_CONFLICT_MANAGERS=stale
    update_conflict_managers 'the server could not find the requested resource'
    [ -z "$UPDATE_CONFLICT_MANAGERS" ]
}

@test "update_apply: SSA non-conflict failure logs update-failed and returns 1" {
    install_mimic_kubectl
    echo 'error: unable to reach cluster' >"$TMP_DIR/apply.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    [[ "$output" == *'"event":"update-failed"'* ]]
    [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    [[ "$output" == *'"reason":"error: unable to reach cluster"'* ]]
}

@test "update_apply: CronJob patch nests under jobTemplate" {
    printf '%s' "$(cron_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    run update_apply CronJob batch nightly containers worker ghcr.io/acme/n:1.4.3 1.4.2
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"op":"replace","path":"/spec/jobTemplate/spec/template/spec/containers/0/image","value":"ghcr.io/acme/n:1.4.3"'* ]]
}

@test "update_apply: CronJob success uses the same sentence shape" {
    printf '%s' "$(cron_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    run emit update_apply CronJob batch nightly containers worker ghcr.io/acme/n:1.4.3 1.4.2
    [ "$status" -eq 0 ]
    [[ "$output" == *"CronJob 'nightly' in 'batch' updated from 1.4.2 to 1.4.3 by claim-patch (as configured) for image 'ghcr.io/acme/n'"* ]]
}

@test "update_apply: kubectl failure logs update-failed and returns 1" {
    install_patch_kubectl
    echo 'error: unable to reach cluster' >"$TMP_DIR/patch.err.1"
    cp "$TMP_DIR/patch.err.1" "$TMP_DIR/patch.err.2"
    cp "$TMP_DIR/patch.err.1" "$TMP_DIR/patch.err.3"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not patch Deployment 'app'/main in 'default'"* ]]
    [ "$(cat "$TMP_DIR/patch.count")" -eq 3 ]
}

@test "update_apply: a refused patch reads again and succeeds on the retry" {
    install_patch_kubectl
    echo 'The request is invalid: test operation failed' >"$TMP_DIR/patch.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"by claim-patch (as configured)"* ]]
    [ "$(cat "$TMP_DIR/patch.count")" -eq 2 ]
    [ "$(grep -cx -- "get deployments.apps app -n default -o json --show-managed-fields" "$TMP_DIR/kubectl.log")" -eq 2 ]
}

@test "update_apply: a patch is refused when the container is not there" {
    # With a polled tag the polled-image check refuses first.
    install_patch_kubectl
    run emit update_apply Deployment default app containers absent ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *"it runs 'no such image' now, not 'ghcr.io/x/y:1.2.3' as polled. Nothing was written; the next poll decides again."* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: without a polled tag the patch builder refuses a missing container" {
    install_patch_kubectl
    run emit update_apply Deployment default app containers absent ghcr.io/x/y:1.2.4 ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"it has no single element named 'absent' with an image to change."* ]]
    at_level ERROR 'no single element named'
    once 'no single element named'
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: unsupported kind logs update-unsupported-kind and returns 1" {
    install_patch_kubectl
    run emit update_apply Pod default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot update Pod 'app' in 'default': kind not supported."* ]]
    at_level ERROR 'kind not supported'
    once 'kind not supported'
    # Refused before anything is read.
    [ ! -e "$TMP_DIR/kubectl.log" ]
}

# --- update_trigger_cronjob ---

@test "update_trigger_cronjob: success with version info renders the full sentence" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
exit 0
SH
    run emit update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n
    [ "$status" -eq 0 ]
    [[ "$output" =~ Job\ \'nightly-[0-9]+\'\ created\ from\ CronJob\ \'nightly\'\ in\ \'batch\'\ with\ update\ from\ 1.4.2\ to\ 1.4.3\ for\ image\ \'ghcr.io/acme/n\' ]]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"create job"* ]]
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *"--from=cronjob/nightly"* ]]
    # In the CronJob's namespace, not the pod's own.
    [[ "$(cat "$TMP_DIR/kubectl.log")" == *" -n batch"* ]]
}

@test "update_trigger_cronjob: without version info renders the concise sentence" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    run emit update_trigger_cronjob batch nightly
    [ "$status" -eq 0 ]
    [[ "$output" =~ Job\ \'nightly-[0-9]+\'\ created\ from\ CronJob\ \'nightly\'\ in\ \'batch\' ]]
    [[ "$output" != *"with update from"* ]]
    once "created from CronJob 'nightly'"
}

@test "update_trigger_cronjob: kubectl failure logs cronjob-job-trigger-failed" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 1
SH
    run emit update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not create Job"* ]]
    at_level ERROR 'Could not create Job'
    once "Could not create Job"
    [[ "$output" == *"from CronJob 'nightly' in 'batch'"* ]]
}

# --- update_fetch_managed_fields ---

@test "fetch_managed_fields: asks kubectl for the flat array and returns it" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
printf '[{"manager":"argocd-application-controller","operation":"Apply"}]'
SH
    update_fetch_managed_fields Deployment default app
    [ "$UPDATE_MANAGED_FIELDS" = '[{"manager":"argocd-application-controller","operation":"Apply"}]' ]
    # [*] and not the bare path: without it kubectl wraps the array in the
    # jsonpath result set and every owner lookup comes back empty.
    grep -q -- 'jsonpath-as-json={.metadata.managedFields\[\*\]}' "$TMP_DIR/kubectl.log"
}

@test "fetch_managed_fields: an object with none yields an empty array" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    update_fetch_managed_fields Deployment default app
    [ "$UPDATE_MANAGED_FIELDS" = "[]" ]
}

@test "fetch_managed_fields: a failed kubectl returns 1" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 1
SH
    run update_fetch_managed_fields Deployment default app
    [ "$status" -eq 1 ]
}

# --- custom resources take the same JSON patch ---

@test "update_apply: a Rollout takes a JSON patch like any other kind" {
    install_patch_kubectl
    obj_kind Rollout
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"Rollout 'app' in 'default' updated from 1.2.3 to 1.2.4 by claim-patch (as configured) for image 'ghcr.io/x/y'."* ]]
    grep -q -- "patch rollouts.argoproj.io app -n default --type=json" "$TMP_DIR/kubectl.log"
    if grep -q -- "--server-side" "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: no patch is ever a strategic merge" {
    install_patch_kubectl
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -q -- "--type=json" "$TMP_DIR/kubectl.log"
    if grep -q -- "--type=strategic" "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: a failed patch says why" {
    install_patch_kubectl
    echo "admission webhook denied the request" >"$TMP_DIR/patch.err.1"
    cp "$TMP_DIR/patch.err.1" "$TMP_DIR/patch.err.2"
    cp "$TMP_DIR/patch.err.1" "$TMP_DIR/patch.err.3"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -ne 0 ]
    [[ "$output" == *"admission webhook denied"* ]]
}

@test "update_apply: a failed apply says why" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$*" in
    get*jsonpath-as-json*) printf '[]' ;;
    get*) printf '%s' '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"app","namespace":"default","resourceVersion":"3","uid":"u-1"},"spec":{"template":{"spec":{"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}' ;;
    apply*) echo 'spec.selector: Required value' >&2; exit 1 ;;
esac
SH
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -ne 0 ]
    [[ "$output" == *"(manager 'keelson', operation Apply): spec.selector: Required value."* ]]
}


# --- image volumes: spec.volumes[].image.reference ---

@test "minimal_manifest: an image volume claims volumes, not containers" {
    run update_minimal_manifest Deployment default app imageVolumes vol ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [ "$(yq '.spec.template.spec.volumes[0].name' <<<"$output")" = "vol" ]
    [ "$(yq '.spec.template.spec.volumes[0].image.reference' <<<"$output")" = "ghcr.io/x/y:1.2.4" ]
    [[ "$output" != *"containers:"* ]]
}

@test "minimal_manifest: a CronJob image volume nests under jobTemplate" {
    run update_minimal_manifest CronJob default cron imageVolumes vol ghcr.io/x/y:1.2.4
    [ "$status" -eq 0 ]
    [ "$(yq '.spec.jobTemplate.spec.template.spec.volumes[0].image.reference' <<<"$output")" = "ghcr.io/x/y:1.2.4" ]
}

# --- the matrix beyond Deployment containers ---

# A Rollout with the same shape as patch_obj / mimic_obj.
as_rollout() {
    yq -p=json -o=json -I0 '.apiVersion = "argoproj.io/v1alpha1" | .kind = "Rollout"'
}

@test "update_apply: apply-owned Rollout -> mimic applies the owner's set" {
    install_mimic_kubectl
    mimic_obj | as_rollout >"$TMP_DIR/obj.json"
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"by mimic (as configured)"* ]]
    [ "$(yq -p=json '.kind' "$TMP_DIR/apply.stdin")" = "Rollout" ]
    [ "$(yq -p=json '.apiVersion' "$TMP_DIR/apply.stdin")" = "argoproj.io/v1alpha1" ]
    grep -q -- "apply --server-side --field-manager=argocd-application-controller -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: apply-owned Rollout -> claim-patch patches as keelson" {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    obj_kind Rollout
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch \
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -q -- "patch rollouts.argoproj.io app -n default --type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: apply-owned Rollout -> claim-apply forces as keelson" {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    obj_kind Rollout
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
    [ "$(yq '.apiVersion' "$TMP_DIR/apply.stdin")" = "argoproj.io/v1alpha1" ]
}

@test "update_apply: update-owned Rollout -> claim-patch patches as keelson" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    obj_kind Rollout
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-patch \
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -q -- "patch rollouts.argoproj.io app -n default --type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: update-owned Rollout -> claim-apply forces as keelson" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    obj_kind Rollout
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-apply \
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: annotated mimic on an unowned Rollout claims with a patch" {
    install_patch_kubectl
    obj_kind Rollout
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=mimic'
    [ "$status" -eq 0 ]
    [[ "$output" == *"by claim-patch (fallback from mimic)"* ]]
    grep -q -- "patch rollouts.argoproj.io app -n default --type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: annotated mimic on an unowned Rollout refuses when fallback is not allowed" {
    install_patch_kubectl
    obj_kind Rollout
    KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED=false \
    KEELSON_LOG_FORMAT=json run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=mimic'
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-mimic-refused"'* ]]
    [[ "$output" == *"falling back from an annotated mimic is not allowed. Nothing was written."* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: mimic reads again when the dry run finds the object moved" {
    install_mimic_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 2 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
}

@test "update_apply: mimic leaves out an owned field the live object lacks, and the guard accepts that loss" {
    # The owner applied paused: false; the server dropped it, so the object
    # has no paused but the owner's set still lists it.
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:paused"] = {}' >"$TMP_DIR/obj.json"
    # The server's answer: the same object, the owner no longer holding paused.
    mimic_obj >"$TMP_DIR/dry.json"
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    once '"event":"update-applied"'
    [ "$(yq '.spec | has("paused")' "$TMP_DIR/apply.stdin")" = false ]
    grep -F '"event":"update-mimic-omitted"' <<<"$output" | grep -q 'f:paused'
}

@test "update_apply: the guard still refuses a loss that was not left out" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:paused"] = {}' >"$TMP_DIR/obj.json"
    # The dry run loses paused, as expected, and replicas, which was sent.
    mimic_obj | yq -p=json -o=json -I0 'del(.metadata.managedFields[0].fieldsV1["f:spec"]["f:replicas"])' >"$TMP_DIR/dry.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"a dry run showed the write would change what 'argocd-application-controller' owns"* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
    # Nor does it accept the left-out field coming back unlost.
    rm -f "$TMP_DIR"/dry.* "$TMP_DIR"/apply.*
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: an empty apply-owned strategy refuses" {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED='' \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-invalid-strategy"'* ]]
    if grep -q -- "patch \|apply " "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: an empty update-owned strategy refuses" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED='' \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-invalid-strategy"'* ]]
    if grep -q -- "patch \|apply " "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: a failed ownership read refuses rather than claiming" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
case "$*" in
    get*jsonpath-as-json*) echo 'Unable to connect to the server' >&2; exit 1 ;;
esac
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not read who owns the image of Deployment 'app'/main in 'default'"* ]]
    at_level ERROR 'Could not read who owns the image'
    once 'Could not read who owns the image'
    [[ "$output" == *"Nothing was written."* ]]
    [ "$(wc -l <"$TMP_DIR/kubectl.log")" -eq 1 ]
}

@test "update_apply: CronJob claim-apply nests the image under jobTemplate" {
    printf '%s' "$(cron_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply CronJob batch nightly containers worker ghcr.io/acme/n:1.4.3 1.4.2
    [ "$status" -eq 0 ]
    [ "$(yq '.spec.jobTemplate.spec.template.spec.containers[0].image' "$TMP_DIR/apply.stdin")" = "ghcr.io/acme/n:1.4.3" ]
}

cron_update_mf() {
    printf '%s' '[{"manager":"helm","operation":"Update","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:jobTemplate":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"worker\"}":{"f:image":{}}}}}}}}}}]'
}

@test "update_apply: update-owned CronJob -> mimic patches under jobTemplate as the owner" {
    printf '%s' "$(cron_update_mf)" >"$TMP_DIR/mf.json"
    printf '%s' "$(cron_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    run emit update_apply CronJob batch nightly containers worker ghcr.io/acme/n:1.4.3 1.4.2
    [ "$status" -eq 0 ]
    grep -q -- "patch cronjobs.batch nightly -n batch --type=json --field-manager=helm" "$TMP_DIR/kubectl.log"
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"path":"/spec/jobTemplate/spec/template/spec/containers/0/image","value":"ghcr.io/acme/n:1.4.3"'* ]]
}

@test "update_apply: update-owned CronJob -> claim-patch patches as keelson" {
    printf '%s' "$(cron_update_mf)" >"$TMP_DIR/mf.json"
    printf '%s' "$(cron_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-patch \
    run emit update_apply CronJob batch nightly containers worker ghcr.io/acme/n:1.4.3 1.4.2
    [ "$status" -eq 0 ]
    grep -q -- "patch cronjobs.batch nightly -n batch --type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: an init container is patched under initContainers" {
    printf '%s' "$(patch_live | yq -p=json -o=json -I0 '.apiVersion = "apps/v1" | .kind = "Deployment" | .metadata = {"name": "app", "namespace": "default"}')" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    run emit update_apply Deployment default app initContainers migrate ghcr.io/x/m:2 1
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"op":"replace","path":"/spec/template/spec/initContainers/0/image","value":"ghcr.io/x/m:2"'* ]]
}

@test "update_apply: an update-owned init container is mimicked as its owner" {
    printf '%s' '[{"manager":"helm","operation":"Update","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:initContainers":{"k:{\"name\":\"migrate\"}":{"f:image":{}}}}}}}}]' >"$TMP_DIR/mf.json"
    printf '%s' "$(patch_live)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    run emit update_apply Deployment default app initContainers migrate ghcr.io/x/m:2 1
    [ "$status" -eq 0 ]
    grep -q -- "--type=json --field-manager=helm" "$TMP_DIR/kubectl.log"
}

@test "update_apply: an image volume is patched at its reference" {
    printf '%s' "$(patch_live)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    run emit update_apply Deployment default app imageVolumes models ghcr.io/x/v:2 1
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"op":"replace","path":"/spec/template/spec/volumes/1/image/reference","value":"ghcr.io/x/v:2"'* ]]
}

@test "update_apply: an image volume claimed by apply lands under template" {
    printf '%s' "$(patch_live)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app imageVolumes models ghcr.io/x/v:2 1
    [ "$status" -eq 0 ]
    [ "$(yq '.spec.template.spec.volumes[0].image.reference' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/v:2" ]
}

@test "update_apply: an update-owned image volume is mimicked as its owner" {
    printf '%s' '[{"manager":"helm","operation":"Update","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:volumes":{"k:{\"name\":\"models\"}":{"f:image":{"f:reference":{}}}}}}}}}]' >"$TMP_DIR/mf.json"
    printf '%s' "$(patch_live)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    run emit update_apply Deployment default app imageVolumes models ghcr.io/x/v:2 1
    [ "$status" -eq 0 ]
    grep -q -- "--type=json --field-manager=helm" "$TMP_DIR/kubectl.log"
}

@test "update_apply: the camelCase annotation spelling chooses the strategy too" {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/fieldManagerStrategy=claim-patch'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-patch"'* ]]
    grep -q -- "--type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

# --- round three: claim-apply keeps what keelson already applies ---

@test "update_apply: claim-apply sends every image keelson already applies" {
    # keelson already claimed the sidecar by apply; claiming main must not
    # leave it out, or the server would take it from keelson and delete it.
    # owned_obj's sidecar is "side"; keelson's entry is moved onto it.
    owned_obj Deployment containers main keelson Apply \
        | sed 's/k:{\\"name\\":\\"main\\"}/k:{\\"name\\":\\"side\\"}/' >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.containers' "$TMP_DIR/apply.stdin")" = '[{"name":"side","image":"ghcr.io/x/s:9"},{"name":"main","image":"ghcr.io/x/y:1.2.4"}]' ]
    [ "$(yq -p=json '.metadata.resourceVersion' "$TMP_DIR/apply.stdin")" = "41" ]
    # Without managedFields in the read there is no set to carry.
    grep -qx -- "get deployments.apps app -n default -o json --show-managed-fields" "$TMP_DIR/kubectl.log"
}

@test "update_apply: claim-apply on an image keelson already applies replaces it in place" {
    owned_obj Deployment containers main keelson Apply >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.containers' "$TMP_DIR/apply.stdin")" = '[{"name":"main","image":"ghcr.io/x/y:1.2.4"}]' ]
}

@test "update_apply: claim-apply carrying keelson's set reads again when the object moved" {
    owned_obj Deployment containers main keelson Apply \
        | sed 's/k:{\\"name\\":\\"main\\"}/k:{\\"name\\":\\"side\\"}/' >"$TMP_DIR/obj.json"
    install_patch_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.1"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 2 ]
    [ "$(grep -cx -- "get deployments.apps app -n default -o json --show-managed-fields" "$TMP_DIR/kubectl.log")" -eq 2 ]
    [ "$(yq -p=json '.metadata.resourceVersion' "$TMP_DIR/apply.stdin")" = "41" ]
}

@test "update_apply: claim-apply gives up when the object moves three times" {
    owned_obj Deployment containers main keelson Apply \
        | sed 's/k:{\\"name\\":\\"main\\"}/k:{\\"name\\":\\"side\\"}/' >"$TMP_DIR/obj.json"
    install_patch_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.1"
    cp "$TMP_DIR/apply.err.1" "$TMP_DIR/apply.err.2"
    cp "$TMP_DIR/apply.err.1" "$TMP_DIR/apply.err.3"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed between read and write three times running. Nothing was written"* ]]
    at_level ERROR 'three times running'
    [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 3 ]
}

@test "update_apply: claim-apply refuses when keelson's own fields cannot be rebuilt" {
    # keelson owns the sidecar, not main, and its set holds a field under
    # dnsPolicy, which is a string live.
    owned_obj Deployment containers main keelson Apply '{"f:spec":{"f:template":{"f:spec":{"f:dnsPolicy":{"f:x":{}}}}}}' \
        | sed 's/k:{\\"name\\":\\"main\\"}/k:{\\"name\\":\\"side\\"}/' >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-claim-refused"'* ]]
    at_level ERROR '"event":"update-claim-refused"'
    [ ! -e "$TMP_DIR/apply.count" ]
}

@test "update_apply: mimic gives up when the dry run finds the object moved three times" {
    install_mimic_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/dry.err.1"
    cp "$TMP_DIR/dry.err.1" "$TMP_DIR/dry.err.2"
    cp "$TMP_DIR/dry.err.1" "$TMP_DIR/dry.err.3"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed between read and write three times running"* ]]
    [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    [ ! -e "$TMP_DIR/apply.count" ]
}

# --- per-target annotations ---

@test "update_apply: an image volume takes its own per-volume annotation" {
    printf '%s' "$(patch_live)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app imageVolumes models ghcr.io/x/v:2 1 "" 'keelson.pro/field-manager-strategy.volumes.models=claim-apply'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-apply"'* ]]
}

@test "update_apply: a container annotation does not reach a volume of the same name" {
    printf '%s' "$(patch_live)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app imageVolumes models ghcr.io/x/v:2 1 "" 'keelson.pro/field-manager-strategy.containers.models=claim-apply'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-patch"'* ]]
}

@test "update_apply: the camelCase per-container spelling is honoured" {
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/fieldManagerStrategy.containers.main=claim-apply'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-apply"'* ]]
}

@test "update_apply: both spellings with different values are refused" {
    install_patch_kubectl
    local ann=$'keelson.pro/field-manager-strategy=claim-patch\nkeelson.pro/fieldManagerStrategy=claim-apply'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 1 ]
    # Said once, by the lookup, naming the workload; the update adds nothing.
    once '"event":"annotation-spelling-conflict"'
    one_error
    [[ "$output" == *'"event":"annotation-spelling-conflict"'*'"kind":"Deployment","ns":"default","name":"app"'* ]]
    [[ "$output" == *"are set on Deployment 'app' in 'default' with different values"* ]]
    [[ "$output" != *'"event":"update-invalid-strategy-annotation"'* ]]
    if grep -q -- "patch \|apply " "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: the workload it names for the lookup does not outlive it" {
    install_patch_kubectl
    # In this shell, not under run: the context is shell state, and a
    # subshell would drop it whether update_apply clears it or not.
    KEELSON_LOG_FORMAT=json update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 >"$TMP_DIR/first.out" 2>&1
    grep -q '"strategy":"claim-patch"' "$TMP_DIR/first.out"
    local ann=$'keelson.pro/field-manager-strategy=claim-patch\nkeelson.pro/fieldManagerStrategy=claim-apply'
    output=$(KEELSON_LOG_FORMAT=json annotation_get "$ann" fieldManagerStrategy 2>&1)
    once '"event":"annotation-spelling-conflict"'
    [[ "$output" != *'"name":'* ]]
    [[ "$output" != *"on Deployment 'app'"* ]]
    [[ "$output" == *"are set with different values"* ]]
}

# --- annotations by state ---

@test "update_apply: annotated mimic on apply-owned wins over a claim setting" {
    install_mimic_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=mimic'
    [ "$status" -eq 0 ]
    [[ "$output" == *"by mimic (as annotated)"* ]]
}

@test "update_apply: annotated mimic on update-owned wins over a claim setting" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=mimic'
    [ "$status" -eq 0 ]
    grep -q -- "--type=json --field-manager=kubectl-client-side-apply" "$TMP_DIR/kubectl.log"
}

@test "update_apply: annotated claim-patch on update-owned and on unowned" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=claim-patch'
    [ "$status" -eq 0 ]
    grep -q -- "--type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
    rm "$TMP_DIR/mf.json" "$TMP_DIR/kubectl.log"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=claim-patch'
    [ "$status" -eq 0 ]
    grep -q -- "--type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: annotated claim-apply forces on update-owned and on unowned" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=claim-apply'
    [ "$status" -eq 0 ]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
    rm "$TMP_DIR/mf.json" "$TMP_DIR/kubectl.log"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=claim-apply'
    [ "$status" -eq 0 ]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: a managedFields array that cannot be read refuses" {
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 'not json [' ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not make sense of who owns the image"*"Nothing was written."* ]]
    at_level ERROR 'Could not make sense of who owns the image'
    once 'Could not make sense of who owns the image'
    # Refused before kubectl was asked anything.
    [ ! -e "$TMP_DIR/kubectl.log" ]
}

# --- CronJob, init containers and image volumes across states ---

@test "update_apply: apply-owned CronJob -> mimic applies the owner's set under jobTemplate" {
    install_mimic_kubectl
    owned_obj CronJob containers main argocd Apply >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    run emit update_apply CronJob default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json '.spec.jobTemplate.spec.template.spec.containers[0].image' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/y:1.2.4" ]
    [ "$(yq -p=json '.spec.jobTemplate.spec.template.spec.containers | length' "$TMP_DIR/apply.stdin")" = "1" ]
    grep -q -- "apply --server-side --dry-run=server --field-manager=argocd" "$TMP_DIR/kubectl.log"
    grep -qx -- "apply --server-side --field-manager=argocd -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: apply-owned CronJob -> mimic refuses when the dry run changes the set" {
    install_mimic_kubectl
    owned_obj CronJob containers main argocd Apply >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:suspend"] = {}' "$TMP_DIR/obj.json" >"$TMP_DIR/dry.json"
    run emit update_apply CronJob default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"a dry run showed the write would change what 'argocd' owns"* ]]
    [ ! -e "$TMP_DIR/apply.count" ]
}

@test "update_apply: apply-owned CronJob -> claim-patch and claim-apply" {
    owned_obj CronJob containers main argocd Apply >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch \
    run emit update_apply CronJob default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"path":"/spec/jobTemplate/spec/template/spec/containers/1/image","value":"ghcr.io/x/y:1.2.4"'* ]]
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    run emit update_apply CronJob default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
    [ "$(yq '.spec.jobTemplate.spec.template.spec.containers[0].image' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/y:1.2.4" ]
}

@test "update_apply: update-owned CronJob -> claim-apply forces under jobTemplate" {
    owned_obj CronJob containers main helm Update >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-apply \
    run emit update_apply CronJob default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: apply-owned init container -> mimic applies the owner's set" {
    install_mimic_kubectl
    owned_obj Deployment initContainers migrate argocd Apply >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    run emit update_apply Deployment default app initContainers migrate ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec' "$TMP_DIR/apply.stdin")" = '{"initContainers":[{"name":"migrate","image":"ghcr.io/x/y:1.2.4"}]}' ]
    grep -q -- "apply --server-side --dry-run=server --field-manager=argocd" "$TMP_DIR/kubectl.log"
    grep -qx -- "apply --server-side --field-manager=argocd -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: owned init container -> claim-patch and claim-apply" {
    local op
    for op in Apply Update; do
        rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/patch.* "$TMP_DIR/kubectl.log"
        owned_obj Deployment initContainers migrate owner "$op" >"$TMP_DIR/obj.json"
        printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
        install_patch_kubectl
        # Unowned would apply, so a patch proves the owner was found.
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-patch \
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
        run emit update_apply Deployment default app initContainers migrate ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 0 ]
        [[ "$(cat "$TMP_DIR/patch.body")" == *'"path":"/spec/template/spec/initContainers/0/image","value":"ghcr.io/x/y:1.2.4"'* ]]
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-apply \
        run emit update_apply Deployment default app initContainers migrate ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 0 ]
        grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
        [ "$(yq '.spec.template.spec.initContainers[0].image' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/y:1.2.4" ]
    done
}

@test "update_apply: apply-owned image volume -> mimic applies the owner's set" {
    install_mimic_kubectl
    owned_obj Deployment imageVolumes models argocd Apply >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    run emit update_apply Deployment default app imageVolumes models ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec' "$TMP_DIR/apply.stdin")" = '{"volumes":[{"name":"models","image":{"reference":"ghcr.io/x/y:1.2.4"}}]}' ]
    grep -q -- "apply --server-side --dry-run=server --field-manager=argocd" "$TMP_DIR/kubectl.log"
    grep -qx -- "apply --server-side --field-manager=argocd -f -" "$TMP_DIR/kubectl.log"
}

@test "update_apply: owned image volume -> claim-patch and claim-apply" {
    local op
    for op in Apply Update; do
        rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/patch.* "$TMP_DIR/kubectl.log"
        owned_obj Deployment imageVolumes models owner "$op" >"$TMP_DIR/obj.json"
        printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
        install_patch_kubectl
        # Unowned would apply, so a patch proves the owner was found.
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-patch \
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
        run emit update_apply Deployment default app imageVolumes models ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 0 ]
        [[ "$(cat "$TMP_DIR/patch.body")" == *'"path":"/spec/template/spec/volumes/0/image/reference","value":"ghcr.io/x/y:1.2.4"'* ]]
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-apply \
        run emit update_apply Deployment default app imageVolumes models ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 0 ]
        grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
        [ "$(yq '.spec.template.spec.volumes[0].image.reference' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/y:1.2.4" ]
    done
}

# --- reads that fail, guards, and the rest of the matrix ---

@test "update_apply: a failed object read in each write path writes nothing" {
    local strategy expect
    for strategy in claim-patch claim-apply mimic; do
        case "$strategy" in
            claim-patch) expect="Could not read Deployment 'app' in 'default' to patch it: Unable to connect to the server" ;;
            claim-apply) expect="as manager 'keelson': could not read it: Unable to connect to the server. Nothing was written." ;;
            mimic) expect="as manager 'argocd-application-controller': could not read it: Unable to connect to the server. Nothing was written." ;;
        esac
        rm -f "$TMP_DIR/kubectl.log"
        printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
        install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
case "$*" in
    get*jsonpath-as-json*) cat "$TMP_DIR/mf.json" ;;
    get*) echo 'Unable to connect to the server' >&2; exit 1 ;;
esac
SH
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=$strategy \
        run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 1 ]
        [[ "$output" == *"$expect"* ]] || { echo "$strategy: $output"; return 1; }
        at_level ERROR "$expect"
        if grep -q -- "^patch \|^apply " "$TMP_DIR/kubectl.log"; then false; fi
    done
}

@test "update_apply: mimic refuses when the dry run shows the owner gone" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 'del(.metadata.managedFields[0])' >"$TMP_DIR/dry.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"a dry run showed the write would change what 'argocd-application-controller' owns"* ]]
    [ ! -e "$TMP_DIR/apply.count" ]
}

@test "update_apply: mimic on a Rollout refuses when the dry run changes the set" {
    install_mimic_kubectl
    mimic_obj | as_rollout >"$TMP_DIR/obj.json"
    mimic_obj | as_rollout | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:paused"] = {}' >"$TMP_DIR/dry.json"
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"would change what 'argocd-application-controller' owns"* ]]
    [ ! -e "$TMP_DIR/apply.count" ]
}

@test "update_apply: a forced claim-apply carries keelson's set while another owns the image" {
    owned_obj Deployment containers main argocd Apply \
        | yq -p=json -o=json -I0 '.metadata.managedFields += [{"manager": "keelson", "operation": "Apply",
            "fieldsV1": {"f:spec": {"f:template": {"f:spec": {"f:containers": {"k:{\"name\":\"side\"}": {"f:name": {}, "f:image": {}}}}}}}}]' >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.containers' "$TMP_DIR/apply.stdin")" = '[{"name":"side","image":"ghcr.io/x/s:9"},{"name":"main","image":"ghcr.io/x/y:1.2.4"}]' ]
}

@test "update_apply: an unowned init container claimed by apply lands under initContainers" {
    owned_obj Deployment initContainers migrate nobody Apply | yq -p=json -o=json -I0 '.metadata.managedFields = []' >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app initContainers migrate ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    grep -qx -- "apply --server-side --field-manager=keelson --force-conflicts -f -" "$TMP_DIR/kubectl.log"
    [ "$(yq '.spec.template.spec.initContainers[0].image' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/y:1.2.4" ]
}

@test "update_apply: a CronJob image volume is patched and mimicked under jobTemplate" {
    owned_obj CronJob imageVolumes models argocd Apply >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch \
    run emit update_apply CronJob default app imageVolumes models ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$(cat "$TMP_DIR/patch.body")" == *'"path":"/spec/jobTemplate/spec/template/spec/volumes/0/image/reference","value":"ghcr.io/x/y:1.2.4"'* ]]
    install_mimic_kubectl
    owned_obj CronJob imageVolumes models argocd Apply >"$TMP_DIR/obj.json"
    printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
    run emit update_apply CronJob default app imageVolumes models ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json '.spec.jobTemplate.spec.template.spec.volumes[0].image.reference' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/y:1.2.4" ]
}

@test "update_apply: annotated mimic on an unowned CronJob claims with a patch" {
    printf '%s' "$(cron_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    run emit update_apply CronJob batch nightly containers worker ghcr.io/acme/n:1.4.3 1.4.2 "" 'keelson.pro/field-manager-strategy=mimic'
    [ "$status" -eq 0 ]
    [[ "$output" == *"by claim-patch (fallback from mimic)"* ]]
}

@test "update_apply: a volume annotation does not reach a container of the same name" {
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy.volumes.main=claim-apply'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-patch"'* ]]
}

@test "update_apply: the camelCase per-volume spelling is honoured" {
    printf '%s' "$(patch_live)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app imageVolumes models ghcr.io/x/v:2 1 "" 'keelson.pro/fieldManagerStrategy.volumes.models=claim-apply'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-apply"'* ]]
}

# --- the write checks the image it was chosen from ---

@test "update_apply: an image moved since the poll is not written, by any path" {
    local strategy
    for strategy in claim-patch claim-apply mimic; do
        rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/patch.* "$TMP_DIR"/dry.* "$TMP_DIR/kubectl.log" "$TMP_DIR/obj.json"
        if [ "$strategy" = mimic ]; then install_mimic_kubectl; else install_patch_kubectl; fi
        printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
        # CI moved it on to 1.5.0 after the poll chose 1.2.4 over 1.2.3.
        yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.5.0"' \
            <<<"$( [ "$strategy" = mimic ] && mimic_obj || patch_obj )" >"$TMP_DIR/obj.json"
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=$strategy \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 3 ]
        [[ "$output" == *'"level":"WARN","event":"update-image-moved"'* ]]
        once '"event":"update-image-moved"'
        [[ "$output" == *"it runs 'ghcr.io/x/y:1.5.0' now, not 'ghcr.io/x/y:1.2.3' as polled"* ]]
        if grep -q -- "^patch \|^apply " "$TMP_DIR/kubectl.log"; then false; fi
    done
}

@test "update_apply: claim-apply keeps the live order of the elements it sends" {
    # keelson applies seed; claiming migrate, which runs before it, must not
    # move it after seed.
    yq -n -o=json -I0 '{"apiVersion": "apps/v1", "kind": "Deployment",
        "metadata": {"name": "app", "namespace": "default", "resourceVersion": "41",
          "managedFields": [{"manager": "keelson", "operation": "Apply", "fieldsV1": {"f:spec": {"f:template": {"f:spec":
            {"f:initContainers": {"k:{\"name\":\"seed\"}": {"f:name": {}, "f:image": {}}}}}}}}]},
        "spec": {"template": {"spec": {"initContainers": [
          {"name": "migrate", "image": "ghcr.io/x/y:1.2.3"}, {"name": "seed", "image": "ghcr.io/x/s:9"}],
          "containers": [{"name": "main", "image": "ghcr.io/x/m:1"}]}}}}' >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app initContainers migrate ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.initContainers' "$TMP_DIR/apply.stdin")" = '[{"name":"migrate","image":"ghcr.io/x/y:1.2.4"},{"name":"seed","image":"ghcr.io/x/s:9"}]' ]
}

# --- round five ---

@test "update_apply: a moved image is refused for init containers, image volumes and CronJobs" {
    local case kind clist target
    for case in "Deployment initContainers migrate" "Deployment imageVolumes models" "CronJob containers main"; do
        read -r kind clist target <<<"$case"
        rm -f "$TMP_DIR"/patch.* "$TMP_DIR/kubectl.log"
        owned_obj "$kind" "$clist" "$target" helm Update >"$TMP_DIR/obj.json"
        printf '%s' "$(mf_of <"$TMP_DIR/obj.json")" >"$TMP_DIR/mf.json"
        install_patch_kubectl
        KEELSON_LOG_FORMAT=json run emit update_apply "$kind" default app "$clist" "$target" ghcr.io/x/y:1.2.4 1.2.2
        [ "$status" -eq 3 ] || { echo "$case: $output"; return 1; }
        [[ "$output" == *'"event":"update-image-moved"'* ]]
        [ ! -e "$TMP_DIR/patch.count" ]
    done
}

@test "update_apply: claim-apply with no keelson set carries the read's resourceVersion" {
    install_patch_kubectl
    yq -p=json -o=json -I0 '.metadata.resourceVersion = "77"' <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq '.metadata.resourceVersion' "$TMP_DIR/apply.stdin")" = "77" ]
}

@test "update_apply: claim-apply with no keelson set reads again when the object moved" {
    install_patch_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.1"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 2 ]
    [ "$(grep -cx -- "get deployments.apps app -n default -o json --show-managed-fields" "$TMP_DIR/kubectl.log")" -eq 2 ]
}

@test "update_apply: claim-apply carrying keelson's set on a Rollout keeps the Rollout's identity" {
    owned_obj Rollout containers main keelson Apply \
        | sed 's/k:{\\"name\\":\\"main\\"}/k:{\\"name\\":\\"side\\"}/' >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json '.apiVersion' "$TMP_DIR/apply.stdin")" = "argoproj.io/v1alpha1" ]
    [ "$(yq -p=json '.kind' "$TMP_DIR/apply.stdin")" = "Rollout" ]
}

@test "update_apply: a dual-prefix annotation conflict names its reason" {
    install_patch_kubectl
    local ann=$'keelson.pro/field-manager-strategy=claim-patch\nkeel.sh/policy=minor'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 1 ]
    [[ "$output" == *"carries both keelson.pro/ and keel.sh/ annotations"* ]]
    at_level ERROR 'carries both keelson.pro/ and keel.sh/'
    once 'carries both keelson.pro/ and keel.sh/ annotations'
    if grep -q -- "patch \|apply " "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: a both-spellings conflict on a per-target key is refused" {
    install_patch_kubectl
    local ann=$'keelson.pro/field-manager-strategy.containers.main=claim-patch\nkeelson.pro/fieldManagerStrategy.containers.main=claim-apply'
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"annotation-spelling-conflict"'* ]]
    if grep -q -- "patch \|apply " "$TMP_DIR/kubectl.log"; then false; fi
}

# --- round five: skips, owner moves, unreadable sets, big objects ---

@test "update_apply: an image already at the target is not written and is not an error" {
    install_patch_kubectl
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *'"level":"INFO","event":"update-already-applied"'* ]]
    once '"event":"update-already-applied"'
    [[ "$output" == *"already runs 'ghcr.io/x/y:1.2.4'; nothing to write."* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: mimic on update-owned refuses when the owner changed since it was chosen" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    # The object as read now is owned by someone else.
    yq -p=json -o=json -I0 '.metadata.managedFields = [{"manager": "helm", "operation": "Update",
        "fieldsV1": {"f:spec": {"f:template": {"f:spec": {"f:containers": {"k:{\"name\":\"main\"}": {"f:image": {}}}}}}}}]' \
        <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *'"event":"update-owner-moved"'* ]]
    [[ "$output" == *"the image is now owned by 'helm' (Update). Nothing was written"* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: claim-apply refuses when keelson's set cannot be read, rather than sending the image alone" {
    install_patch_kubectl
    # Shadow yq so the owner-set read fails while everything else works.
    local bin="$BATS_TEST_TMPDIR/ybin" real
    real=$(command -v yq)
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\ncase "$*" in *"(strenv(MANAGER) | @base64) and .operation"*) exit 1 ;; esac\nexec %q "$@"\n' "$real" >"$bin/yq"
    chmod +x "$bin/yq"
    PATH="$bin:$PATH" KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"what 'keelson' already applies could not be read. Nothing was written."* ]]
    [ ! -e "$TMP_DIR/apply.count" ]
}

@test "update_apply: claim-apply refuses when whether the list is atomic cannot be read" {
    install_patch_kubectl
    # Shadow yq so only the held-whole read fails.
    local bin="$BATS_TEST_TMPDIR/ybin" real
    real=$(command -v yq)
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\ncase "$*" in *"[.[] | select((.subresource // \\"\\") == \\"\\") | select("*) exit 1 ;; esac\nexec %q "$@"\n' "$real" >"$bin/yq"
    chmod +x "$bin/yq"
    PATH="$bin:$PATH" KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-claim-refused"'
    [[ "$output" == *"its managedFields could not be read to tell whether its containers list is atomic, so sending the image alone would replace the whole list"* ]]
    [ ! -e "$TMP_DIR/apply.count" ]
}

@test "update_apply: claim-apply on an object too big for one environment string still works" {
    owned_obj Deployment containers main keelson Apply \
        | sed 's/k:{\\"name\\":\\"main\\"}/k:{\\"name\\":\\"side\\"}/' \
        >"$TMP_DIR/small.json"
    # Built from a file: the payload is too big to pass through the
    # environment, which is the point.
    head -c 150000 /dev/zero | tr '\0' 'x' >"$TMP_DIR/big.txt"
    yq -p=json -o=json -I0 '.metadata.annotations.big = load_str("'"$TMP_DIR"'/big.txt")' "$TMP_DIR/small.json" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.containers' "$TMP_DIR/apply.stdin")" = '[{"name":"side","image":"ghcr.io/x/s:9"},{"name":"main","image":"ghcr.io/x/y:1.2.4"}]' ]
}

# --- round six ---

@test "update_apply: mimic on update-owned skips when the owner now applies under the same name" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    mf_update_kubectl | yq -p=json -o=json -I0 '.[0].operation = "Apply"' >"$TMP_DIR/now.json"
    yq -p=json -o=json -I0 '.metadata.managedFields = load("'"$TMP_DIR"'/now.json")' <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *"the image is now owned by 'kubectl-client-side-apply' (Apply). Nothing was written"* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: mimic on update-owned refuses when the owner cannot be read again" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    local bin="$BATS_TEST_TMPDIR/ybin" real
    real=$(command -v yq)
    mkdir -p "$bin"
    # The owner lookup runs twice: for the strategy, then on the patch's
    # re-read. Only the second fails.
    printf '#!/usr/bin/env bash\ncase "$*" in *"select(.operation == \\\"Apply\\\" or"*)\n  n=$(( $(cat %q 2>/dev/null || echo 0) + 1 )); echo "$n" >%q\n  [ "$n" -eq 2 ] && exit 1 ;;\nesac\nexec %q "$@"\n' \
        "$BATS_TEST_TMPDIR/owner.count" "$BATS_TEST_TMPDIR/owner.count" "$real" >"$bin/yq"
    chmod +x "$bin/yq"
    PATH="$bin:$PATH" KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "$(mf_update_kubectl)"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-mimic-refused"'*'"manager":"kubectl-client-side-apply","operation":"Update","strategy":"mimic"'* ]]
    [[ "$output" == *"who owns the image could not be read again. Nothing was written."* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: the mimic fallback skips when the image gained an owner" {
    # Unowned when chosen; owned by flux on the patch's fresh read.
    mf_apply_argocd | yq -p=json -o=json -I0 '.[0].manager = "flux"' >"$TMP_DIR/now.json"
    yq -p=json -o=json -I0 '.metadata.managedFields = load("'"$TMP_DIR"'/now.json")' <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "[]" 'keelson.pro/field-manager-strategy=mimic'
    [ "$status" -eq 3 ]
    [[ "$output" == *"the image is now owned by 'flux' (Apply)"* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: a write that landed though kubectl reported failure counts as done" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    # The first patch landed: the next read shows the target image.
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == patch ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"an earlier try that reported failure landed after all."* ]]
    [ "$(cat "$TMP_DIR/patch.count")" -eq 1 ]
}

@test "update_apply: a refused patch is retried up to three times" {
    install_patch_kubectl
    echo 'The request is invalid' >"$TMP_DIR/patch.err.1"
    cp "$TMP_DIR/patch.err.1" "$TMP_DIR/patch.err.2"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/patch.count")" -eq 3 ]
}

@test "update_apply: a failed read on the patch path is logged once and not retried" {
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
case "$*" in
    get*jsonpath-as-json*) cat "$TMP_DIR/mf.json" ;;
    get*) echo 'Unable to connect to the server' >&2; exit 1 ;;
esac
SH
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [ "$(grep -c "Could not read Deployment 'app' in 'default' to patch it" <<<"$output")" -eq 1 ]
    [ "$(grep -c -- "-o json --show-managed-fields" "$TMP_DIR/kubectl.log")" -eq 1 ]
}

@test "update_apply: claim-apply carrying keelson's set on a CronJob and on an image volume" {
    owned_obj CronJob containers main keelson Apply \
        | sed 's/k:{\\"name\\":\\"main\\"}/k:{\\"name\\":\\"side\\"}/' >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply CronJob default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json -o=json -I0 '.spec.jobTemplate.spec.template.spec.containers' "$TMP_DIR/apply.stdin")" = '[{"name":"side","image":"ghcr.io/x/s:9"},{"name":"main","image":"ghcr.io/x/y:1.2.4"}]' ]
    [ "$(yq -p=json '.spec.template // "none"' "$TMP_DIR/apply.stdin")" = none ]
    rm -f "$TMP_DIR"/apply.* "$TMP_DIR/kubectl.log"
    # An image volume, keelson already applying the sidecar's image.
    owned_obj Deployment imageVolumes models nobody Apply | yq -p=json -o=json -I0 '.metadata.managedFields = [{"manager": "keelson", "operation": "Apply",
        "fieldsV1": {"f:spec": {"f:template": {"f:spec": {"f:containers": {"k:{\"name\":\"side\"}": {"f:name": {}, "f:image": {}}}}}}}}]' >"$TMP_DIR/obj.json"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app imageVolumes models ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec' "$TMP_DIR/apply.stdin")" = '{"containers":[{"name":"side","image":"ghcr.io/x/s:9"}],"volumes":[{"name":"models","image":{"reference":"ghcr.io/x/y:1.2.4"}}]}' ]
}

@test "update_apply: StatefulSets and DaemonSets take the same patch" {
    local kind
    for kind in StatefulSet DaemonSet; do
        rm -f "$TMP_DIR"/patch.* "$TMP_DIR/kubectl.log"
        install_patch_kubectl
        obj_kind "$kind"
        run emit update_apply "$kind" default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 0 ]
        grep -q -- "patch $(update_resource_name "$kind") app -n default --type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
    done
}

# --- round seven ---

@test "update_apply: an image keelson owns by an Update is mimicked as keelson, not skipped" {
    # Any earlier claim-patch, fallback or old-Keelson patch leaves this.
    mf_update_kubectl | yq -p=json -o=json -I0 '.[0].manager = "keelson"' >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"by mimic (as configured)"* ]]
    [[ "$output" != *'"event":"update-owner-moved"'* ]]
    grep -q -- "--type=json --field-manager=keelson" "$TMP_DIR/kubectl.log"
}

@test "update_apply: a stale refusal then the target already live is someone else's change" {
    install_mimic_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
# After the refused apply, someone else sets the same tag.
if [[ "\$*" == "apply --server-side --field-manager="*" -f -" ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *"already runs 'ghcr.io/x/y:1.2.4'; nothing to write."* ]]
}

@test "update_apply: a claim skips when the image gained an owner after the strategy was chosen" {
    # Unowned when chosen, so claim-patch; Apply-owned by flux on the fresh read.
    mf_apply_argocd | yq -p=json -o=json -I0 '.[0].manager = "flux"' >"$TMP_DIR/now.json"
    yq -p=json -o=json -I0 '.metadata.managedFields = load("'"$TMP_DIR"'/now.json")' <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    local strategy
    for strategy in claim-patch claim-apply; do
        rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.*
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=$strategy \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "[]"
        [ "$status" -eq 3 ] || { echo "$strategy: $output"; return 1; }
        [[ "$output" == *"the image is now owned by 'flux' (Apply)"* ]]
        [ ! -e "$TMP_DIR/patch.count" ]
        [ ! -e "$TMP_DIR/apply.count" ]
    done
}

@test "update_apply: a failed ownership read says why" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo 'Unable to connect to the server: dial tcp: i/o timeout' >&2
exit 1
SH
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"so the right way to write it is unknown: Unable to connect to the server: dial tcp: i/o timeout. Nothing was written."* ]]
}

# --- round seven: layers told apart, and what the mutants slipped past ---

@test "update_apply: mimic refuses an owner with two Apply entries" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields = [.metadata.managedFields[0], .metadata.managedFields[0]]' >"$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not have exactly one usable Apply entry on it. Nothing was written."* ]]
    [[ "$output" == *'"operation":"Apply"'* ]]
    [ ! -e "$TMP_DIR/dry.stdin" ]
}

@test "update_apply: mimic skips when a newer Apply manager now co-owns the image" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields += [.metadata.managedFields[0]
        | .manager = "flux" | .time = "2026-09-01T00:00:00Z"]' >"$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *"the image is now owned by 'flux' (Apply)"* ]]
    [ ! -e "$TMP_DIR/dry.stdin" ]
}

@test "update_apply: a failed object read is logged once on the apply and mimic paths" {
    local strategy expect
    for strategy in claim-apply mimic; do
        rm -f "$TMP_DIR/kubectl.log"
        printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
        install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
case "$*" in
    get*jsonpath-as-json*) cat "$TMP_DIR/mf.json" ;;
    get*) echo 'Unable to connect to the server' >&2; exit 1 ;;
esac
SH
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=$strategy \
        run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 1 ]
        [ "$(grep -c "could not read it: Unable to connect to the server. Nothing was written." <<<"$output")" -eq 1 ] || { echo "$strategy: $output"; return 1; }
        [ "$(grep -c -- "-o json --show-managed-fields" "$TMP_DIR/kubectl.log")" -eq 1 ]
    done
}

@test "update_apply: claim-apply after a stale refusal counts the target already live as someone else's" {
    install_patch_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == apply ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *"already runs 'ghcr.io/x/y:1.2.4'; nothing to write."* ]]
}

@test "update_apply: refusals log the operation that was refused" {
    # The dry-run guard refuses an Apply.
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:paused"] = {}' >"$TMP_DIR/dry.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [[ "$output" == *'"event":"update-mimic-refused"'*'"operation":"Apply"'* ]]
    # The disallowed fallback names no write at all.
    rm -f "$TMP_DIR/dry.json" "$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED=false \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "[]" 'keelson.pro/field-manager-strategy=mimic'
    [[ "$output" == *'"event":"update-mimic-refused"'*'"operation":""'* ]]
}

@test "update_apply: a claim refuses, naming its operation, when the owner cannot be read again" {
    local strategy op
    for strategy in claim-patch claim-apply; do
        case "$strategy" in claim-patch) op=Update ;; claim-apply) op=Apply ;; esac
        rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.* "$BATS_TEST_TMPDIR/owner.count"
        install_patch_kubectl
        local bin="$BATS_TEST_TMPDIR/ybin" real
        real=$(command -v yq)
        mkdir -p "$bin"
        printf '#!/usr/bin/env bash\ncase "$*" in *"select(.operation == \\\"Apply\\\" or"*)\n  n=$(( $(cat %q 2>/dev/null || echo 0) + 1 )); echo "$n" >%q\n  [ "$n" -eq 2 ] && exit 1 ;;\nesac\nexec %q "$@"\n' \
            "$BATS_TEST_TMPDIR/owner.count" "$BATS_TEST_TMPDIR/owner.count" "$real" >"$bin/yq"
        chmod +x "$bin/yq"
        PATH="$bin:$PATH" KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=$strategy \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "[]"
        [ "$status" -eq 1 ] || { echo "$strategy: $output"; return 1; }
        [[ "$output" == *'"event":"update-claim-refused"'*"\"operation\":\"$op\""* ]]
        [[ "$output" == *"who owns the image could not be read again. Nothing was written."* ]]
        [ ! -e "$TMP_DIR/patch.count" ]
        [ ! -e "$TMP_DIR/apply.count" ]
    done
}

@test "update_apply: a per-container annotation reaches an init container" {
    printf '%s' "$(patch_live)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app initContainers migrate ghcr.io/x/m:2 1 "" 'keelson.pro/field-manager-strategy.containers.migrate=claim-apply'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"strategy":"claim-apply"'* ]]
}

@test "update_apply: StatefulSets and DaemonSets claimed by apply carry apps/v1, and mimic their owner" {
    local kind
    for kind in StatefulSet DaemonSet; do
        rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.* "$TMP_DIR/kubectl.log" "$TMP_DIR/mf.json" "$TMP_DIR/obj.json"
        install_patch_kubectl
        obj_kind "$kind"
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
        run emit update_apply "$kind" default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 0 ]
        [ "$(yq '.apiVersion' "$TMP_DIR/apply.stdin")" = "apps/v1" ]
        [ "$(yq '.kind' "$TMP_DIR/apply.stdin")" = "$kind" ]
        rm -f "$TMP_DIR"/apply.*
        install_mimic_kubectl
        obj_kind "$kind"
        mimic_obj | KIND=$kind yq -p=json -o=json -I0 '.kind = strenv(KIND)' >"$TMP_DIR/obj.json"
        run emit update_apply "$kind" default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 0 ]
        [[ "$output" == *"by mimic (as configured)"* ]]
        [ "$(yq -p=json '.kind' "$TMP_DIR/apply.stdin")" = "$kind" ]
    done
}

@test "update_apply: an image already at the target is not written on the mimic and claim-apply paths" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' >"$TMP_DIR/obj.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [ ! -e "$TMP_DIR/dry.stdin" ]
    rm -f "$TMP_DIR/mf.json"
    install_patch_kubectl
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [ ! -e "$TMP_DIR/apply.count" ]
}

@test "update_apply: two live elements of the target's name count as no such image" {
    install_patch_kubectl
    yq -p=json -o=json -I0 '.spec.template.spec.containers += [{"name": "main", "image": "ghcr.io/x/y:1.2.3"}]' <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *"it runs 'no such image' now"* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

# --- round eight ---

@test "update_apply: every failure line names the operation it refused" {
    local strategy op
    # A failed object read, per path.
    for strategy in claim-patch claim-apply mimic; do
        case "$strategy" in claim-patch) op=Update ;; *) op=Apply ;; esac
        rm -f "$TMP_DIR/kubectl.log"
        printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
        install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo "$@" >>"$TMP_DIR/kubectl.log"
case "$*" in
    get*jsonpath-as-json*) cat "$TMP_DIR/mf.json" ;;
    get*) echo 'Unable to connect to the server' >&2; exit 1 ;;
esac
SH
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=$strategy \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [[ "$output" == *"\"operation\":\"$op\""* ]] || { echo "read $strategy: $output"; return 1; }
    done
    # The patch path's final failure, after three tries.
    rm -f "$TMP_DIR/mf.json" "$TMP_DIR/kubectl.log"
    install_patch_kubectl
    echo 'error: unable to reach cluster' >"$TMP_DIR/patch.err.1"
    cp "$TMP_DIR/patch.err.1" "$TMP_DIR/patch.err.2"
    cp "$TMP_DIR/patch.err.1" "$TMP_DIR/patch.err.3"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [[ "$output" == *'"event":"update-failed"'*'"operation":"Update"'*'"detail":"error: unable to reach cluster"'* ]]
    # An apply that fails other than by conflict.
    rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.*
    echo 'error: unable to reach cluster' >"$TMP_DIR/apply.err.1"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [[ "$output" == *'"event":"update-failed"'*'"operation":"Apply"'* ]]
}

@test "update_apply: each path's exhausted retries are logged once, with the operation" {
    local strategy op
    for strategy in claim-apply mimic; do
        case "$strategy" in mimic) install_mimic_kubectl ;; *) rm -f "$TMP_DIR/mf.json"; install_patch_kubectl ;; esac
        rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.*
        local i
        for i in 1 2 3; do
            apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.$i"
        done
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 1 ]
        [ "$(grep -c '"event":"update-failed"' <<<"$output")" -eq 1 ] || { echo "$strategy: $output"; return 1; }
        [[ "$output" == *'"operation":"Apply"'*'"reason":"object kept changing"'* ]]
        [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    done
}

@test "update_apply: a refused apply and the dry-run guard are each logged once" {
    install_patch_kubectl
    echo 'spec.selector: Required value' >"$TMP_DIR/apply.err.1"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$(grep -c '"level":"ERROR"' <<<"$output")" -eq 1 ]
    [[ "$output" == *"It may have been written regardless; the next poll will see."* ]]
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:paused"] = {}' >"$TMP_DIR/dry.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$(grep -c '"level":"ERROR"' <<<"$output")" -eq 1 ]
}

@test "update_apply: the fallback setting touches only the unowned case" {
    KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED=false
    # Annotated mimic on apply-owned still mimics.
    install_mimic_kubectl
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=mimic'
    [ "$status" -eq 0 ]
    [[ "$output" == *"by mimic (as annotated)"* ]]
    # Configured mimic on update-owned still mimics.
    rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.* "$TMP_DIR/obj.json"
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"by mimic (as configured)"* ]]
}

@test "update_apply: the minimal claim manifest names the object and quotes a numeric name" {
    yq -p=json -o=json -I0 '.spec.template.spec.containers[1].name = "123"' <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers 123 ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq '.metadata.name' "$TMP_DIR/apply.stdin")" = app ]
    [ "$(yq '.metadata.namespace' "$TMP_DIR/apply.stdin")" = default ]
    [ "$(yq '.spec.template.spec.containers[0].name | tag' "$TMP_DIR/apply.stdin")" = '!!str' ]
}

@test "update_apply: a counted-as-done retry says what landed" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == patch ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"event":"update-applied"'*"an earlier try that reported failure landed after all."* ]]
}

@test "update_apply: an image that cannot be read on the fresh read is an error, not a skip" {
    install_patch_kubectl
    local bin="$BATS_TEST_TMPDIR/ybin" real
    real=$(command -v yq)
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\ncase "$*" in *"select(length == 1) | .[0] // \\\"\\\""*) exit 1 ;; esac\nexec %q "$@"\n' "$real" >"$bin/yq"
    chmod +x "$bin/yq"
    PATH="$bin:$PATH" run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not read the image Deployment 'app'/main in 'default' runs now. Nothing was written."* ]]
    at_level ERROR 'Could not read the image'
    once 'Could not read the image'
}

# --- round nine ---

@test "update_apply: a try that may have landed makes a later failure say so" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    # The next read fails.
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == get ]] && [ -e "$TMP_DIR/patch.count" ] && [[ "\$*" != *jsonpath* ]]; then
    echo 'Unable to connect to the server' >&2; exit 1
fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"An earlier try may have landed; the next poll will see."* ]]
    [[ "$output" != *"Nothing was written."* ]]
}

@test "update_apply: a landed retry logs one line, with from, to and repo" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == patch ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" != *'"event":"update-already-applied"'* ]]
    [[ "$output" == *'"event":"update-applied"'*'"from":"1.2.3","to":"1.2.4","repo":"ghcr.io/x/y"'* ]]
}

@test "update_apply: a landed retry of an annotated strategy says so, as an Update" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == patch ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=claim-patch'
    [ "$status" -eq 0 ]
    once '"event":"update-applied"'
    [[ "$output" == *'"event":"update-applied"'*'"operation":"Update"'* ]]
    [[ "$output" == *"by claim-patch (as annotated)"*"landed after all"* ]]
}

@test "update_apply: a conflict on mimic's real apply is an ownership conflict" {
    # The dry run passed; someone took a field before the real apply.
    install_mimic_kubectl
    printf '%s\n' 'error: Apply failed with 1 conflict: conflict with "flux": .spec.replicas' >"$TMP_DIR/apply.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-apply-conflict"'
    [[ "$output" == *"conflict with 'flux'; refusing to force. Nothing was written."* ]]
}

@test "update_apply: a dual-prefix workload is refused for what it is" {
    install_patch_kubectl
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" $'keel.sh/policy=minor\nkeelson.pro/policy=minor'
    [ "$status" -eq 1 ]
    [[ "$output" == *"carries both keelson.pro/ and keel.sh/ annotations"* ]]
}

# --- round nine: endings, resets, preconditions, guards ---

@test "update_apply: failure endings say whether the write may have landed" {
    # Three failed patches: the last may have landed.
    install_patch_kubectl
    local i
    for i in 1 2 3; do echo 'error: unable to reach cluster' >"$TMP_DIR/patch.err.$i"; done
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [[ "$output" == *"Could not patch"*"It may have been written regardless; the next poll will see."* ]]
    # A real mimic apply that fails other than by conflict: may have landed.
    install_mimic_kubectl
    echo 'error: unable to reach cluster' >"$TMP_DIR/apply.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [[ "$output" == *"Could not server-side apply"*"It may have been written regardless; the next poll will see."* ]]
    # A mimic dry run that fails: a dry run never writes.
    rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.*
    echo 'error: unable to reach cluster' >"$TMP_DIR/dry.err"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [[ "$output" == *"Could not server-side apply"*"Nothing was written."* ]]
    [[ "$output" != *"may have been written"* ]]
}

@test "update_apply: a moved image after a try that may have landed says it may have" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    # After the failed patch someone else moves the image on.
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == patch ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:9.9.9"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    # A third tag live does not prove the earlier try never landed.
    [[ "$output" == *"it runs 'ghcr.io/x/y:9.9.9' now, not 'ghcr.io/x/y:1.2.3' as polled. An earlier try may have landed; the next poll decides again."* ]]
}

@test "update_apply: one call's may-have-landed does not leak into the next" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == get ]] && [ -e "$TMP_DIR/patch.count" ] && [[ "\$*" != *jsonpath* ]]; then
    echo 'Unable to connect to the server' >&2; exit 1
fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    # Called in this shell, not under run, so state left behind is visible.
    update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 2>"$TMP_DIR/first.log" || true
    grep -q "An earlier try may have landed" "$TMP_DIR/first.log"
    # A fresh call whose first read fails: nothing of ours could have landed.
    rm -f "$TMP_DIR/patch.count"
    : >"$TMP_DIR/patch.count"
    update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 2>"$TMP_DIR/second.log" || true
    grep -q "Nothing was written." "$TMP_DIR/second.log"
    if grep -q "An earlier try may have landed" "$TMP_DIR/second.log"; then false; fi
}

@test "update_apply: a claim-apply with no resourceVersion to send is refused" {
    yq -p=json -o=json -I0 'del(.metadata.resourceVersion)' <<<"$(patch_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"the read carries no resourceVersion and uid to write against. Nothing was written."* ]]
    [ ! -e "$TMP_DIR/apply.count" ]
}

@test "update_apply: patch and claim-apply success lines say (as annotated)" {
    install_patch_kubectl
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=claim-patch'
    [[ "$output" == *"by claim-patch (as annotated)"* ]]
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=claim-apply'
    [[ "$output" == *"by claim-apply (as annotated)"* ]]
}

@test "json_patch and mimic_set_image: two elements of the name are refused" {
    if update_json_patch Deployment containers main ghcr.io/x/y:2 '{"spec":{"template":{"spec":{"containers":[{"name":"main","image":"a:1"},{"name":"main","image":"b:1"}]}}}}'; then false; fi
    if update_mimic_set_image Deployment containers main ghcr.io/x/y:2 '{"spec":{"template":{"spec":{"containers":[{"name":"main","image":"a:1"},{"name":"main","image":"b:1"}]}}}}'; then false; fi
}

@test "update_apply: a landed retry's line names the method, as a normal success does" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == patch ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=mimic'
    [ "$status" -eq 0 ]
    [[ "$output" == *"updated from 1.2.3 to 1.2.4 by claim-patch (fallback from mimic) for image 'ghcr.io/x/y': an earlier try"* ]]
}

@test "update_apply: an annotation that cannot be read refuses, not reads a stale value" {
    install_patch_kubectl
    KEELSON_CONFIG_MODE=bogus \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=claim-apply'
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot be used (annotation-read-failed)"* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

# --- round ten: endings on every line a later try can reach ---

# After the first failed patch, kubectl answers through after_patch_shim:
# its get of the object prints $1 instead, its jsonpath read is untouched.
after_patch_shim() {
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    printf '%s' "$1" >"$TMP_DIR/after.json"
    install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == get ]] && [ -e "$TMP_DIR/patch.count" ] && [[ "\$*" != *jsonpath* ]]; then
    cat "$TMP_DIR/after.json"; exit 0
fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
}

@test "update_apply: an unreadable image after a try that may have landed says so" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    after_patch_shim 'not json {'
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not read the image Deployment 'app'/main in 'default' runs now. An earlier try may have landed; the next poll will see."* ]]
}

@test "update_apply: no element to patch after a try that may have landed says so" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    # Not reachable through a live object once the polled check passed, so
    # the builder itself fails on the later try.
    eval "real_$(declare -f update_json_patch)"
    update_json_patch() {
        [ -e "$TMP_DIR/patch.count" ] && return 1
        real_update_json_patch "$@"
    }
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no single element named 'main' with an image to change. An earlier try may have landed; the next poll will see."* ]]
}

@test "update_apply: a stale claim-apply never makes a later failure say it may have landed" {
    install_patch_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == get ]] && [ -e "$TMP_DIR/apply.count" ] && [[ "\$*" != *jsonpath* ]]; then
    echo 'Unable to connect to the server' >&2; exit 1
fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not read it: Unable to connect to the server. Nothing was written."* ]]
    [[ "$output" != *"may have landed"* ]]
}

@test "update_apply: a stale mimic apply never makes a later failure say it may have landed" {
    install_mimic_kubectl
    apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.1"
    echo 'error: unable to reach cluster' >"$TMP_DIR/dry.err.2"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not server-side apply"*"Nothing was written."* ]]
    [[ "$output" != *"may have landed"* ]]
}

@test "update_apply: an early failure does not inherit the last call's ending" {
    # What a previous call that may have landed leaves behind.
    UPDATE_OUTCOME="An earlier try may have landed; the next poll will see."
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo 'Unable to connect to the server' >&2
exit 1
SH
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not read who owns the image"*"Nothing was written."* ]]
    [[ "$output" != *"may have landed"* ]]
}

@test "update_apply: claim-patch's exhausted retries are logged once" {
    install_patch_kubectl
    local i
    for i in 1 2 3; do echo 'error: unable to reach cluster' >"$TMP_DIR/patch.err.$i"; done
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/patch.count")" -eq 3 ]
    [ "$(grep -c '"level":"ERROR"' <<<"$output")" -eq 1 ]
    [[ "$output" == *'"event":"update-failed"'*'"operation":"Update"'* ]]
}

# --- round eleven ---

@test "update_apply: an owner that moved after a try that may have landed says it may have" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    # The image is as polled, but helm holds it now.
    after_patch_shim "$(patch_obj | MF="$(mf_update_kubectl | sed 's/kubectl-client-side-apply/helm/')" \
        yq -p=json -o=json -I0 '.metadata.managedFields = (strenv(MF) | from_json)')"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *"the image is now owned by 'helm' (Update). An earlier try may have landed; the next poll decides again."* ]]
}

@test "update_apply: a refusal that only mentions modified is not taken for a stale read" {
    install_mimic_kubectl
    echo 'Error from server: admission webhook "guard" denied the request: the image may not be modified' >"$TMP_DIR/apply.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
    [[ "$output" == *"It may have been written regardless; the next poll will see."* ]]
}

@test "update_apply: an empty fallback setting does not allow the fallback" {
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED= \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" 'keelson.pro/field-manager-strategy=mimic'
    [ "$status" -eq 1 ]
    [[ "$output" == *"falling back from an annotated mimic is not allowed"* ]]
    [ ! -e "$TMP_DIR/patch.count" ]
}

@test "update_apply: a forced claim-apply's failure that says conflict is not an ownership conflict" {
    install_patch_kubectl
    echo 'Error from server: admission webhook "policy" denied the request: conflicts with policy freeze-window' >"$TMP_DIR/apply.err.1"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-failed"'* ]]
    [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    [[ "$output" == *"It may have been written regardless; the next poll will see."* ]]
}

@test "update_apply: a mimic dry run denied in words that say conflict is not an ownership conflict" {
    install_mimic_kubectl
    echo 'Error from server: admission webhook "policy" denied the request: image tag conflicts with policy' >"$TMP_DIR/dry.err"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    once '"event":"update-failed"'
    [[ "$output" == *"Nothing was written."* ]]
}

@test "update_apply: a forced claim-apply is never logged as an ownership conflict" {
    # Not something a forced apply can be told, but the gate is what says so.
    install_patch_kubectl
    echo 'error: Apply failed with 1 conflict: conflict with "flux" using apps/v1: .spec.replicas' >"$TMP_DIR/apply.err.1"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    once '"event":"update-failed"'
}

@test "update_apply: several conflicts at once are an ownership conflict too" {
    install_mimic_kubectl
    echo 'error: Apply failed with 2 conflicts: conflicts with "flux" using apps/v1: .spec.replicas, .spec.template.spec.dnsPolicy' >"$TMP_DIR/apply.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-apply-conflict"'
}

@test "update_apply: has been modified in another sense is not a stale read" {
    install_mimic_kubectl
    echo 'Error from server: admission webhook "guard" denied the request: the image has been modified by policy' >"$TMP_DIR/apply.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
}

# --- round fourteen: the debug detail behind each refusal ---

# A complaint longer than the error line's clip, ending in a marker the
# clip cuts off: only the detail line can carry it whole.
long_complaint() {
    printf 'error: %s END-OF-COMPLAINT' "$(printf 'x%.0s' {1..400})"
}

# detail_whole <event>: that event's own line carries the whole complaint.
detail_whole() {
    grep -F "\"event\":\"$1\"" <<<"$output" | grep -q END-OF-COMPLAINT
}

@test "update_apply: each refusal's detail line carries kubectl's whole complaint" {
    # The patch path's exhausted retries.
    install_patch_kubectl
    local i
    for i in 1 2 3; do long_complaint >"$TMP_DIR/patch.err.$i"; done
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    detail_whole update-patch-failed-detail
    # mimic's real apply.
    install_mimic_kubectl
    long_complaint >"$TMP_DIR/apply.err.1"
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    detail_whole update-apply-failed-detail
    # A failed object read on the claim-apply and mimic paths.
    local strategy event
    for strategy in claim-apply mimic; do
        case "$strategy" in claim-apply) event=update-claim-refused-detail ;; mimic) event=update-mimic-refused-detail ;; esac
        install_mimic_kubectl
        mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
        long_complaint >"$TMP_DIR/read.err"
        install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == get ]] && [[ "\$*" != *jsonpath* ]]; then cat "$TMP_DIR/read.err" >&2; exit 1; fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=$strategy \
        KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        detail_whole "$event" || { echo "$strategy: $output"; return 1; }
        rm -f "$TMP_BIN/kubectl.real"
    done
}

@test "update_apply: mimic's guard refusal says at debug what the set was and became" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:paused"] = {}' >"$TMP_DIR/dry.json"
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    grep -F '"event":"update-mimic-guard-detail"' <<<"$output" | grep -q 'after the dry run:.*f:paused'
}

@test "update_apply: a disallowed fallback leaves annotated claims on an unowned image alone" {
    # The setting is about falling back from mimic; a claim never falls back.
    local strategy
    for strategy in claim-patch claim-apply; do
        rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.*
        install_patch_kubectl
        KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED=false \
        run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "keelson.pro/field-manager-strategy=$strategy"
        [ "$status" -eq 0 ] || { echo "$strategy: $output"; return 1; }
        [[ "$output" == *"by $strategy (as annotated)"* ]]
    done
}

# --- round fifteen ---

@test "update_apply: an owner that cannot be read again on mimic's apply path is refused as mimic, as an Apply" {
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields = "garbage"' "$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-mimic-refused"'
    [[ "$output" == *'"operation":"Apply","strategy":"mimic","reason":"who owns the image could not be read again"'* ]]
    if [ -e "$TMP_DIR/apply.count" ]; then false; fi
}

@test "update_apply: an owner that cannot be read again after a try that may have landed says so" {
    local case
    for case in claim-patch update-owned; do
        rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/mf.json "$TMP_DIR"/obj.json "$TMP_BIN"/kubectl.real
        [ "$case" = update-owned ] && printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
        install_patch_kubectl
        echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
        after_patch_shim "$(patch_obj | yq -p=json -o=json -I0 '.metadata.managedFields = "garbage"')"
        run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 1 ] || { echo "$case: $output"; return 1; }
        [[ "$output" == *"who owns the image could not be read again. An earlier try may have landed; the next poll will see."* ]] \
            || { echo "$case: $output"; return 1; }
    done
}

@test "update_apply: refusals carry their reason as a field" {
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields = "garbage"' "$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"reason":"who owns the image could not be read again"'* ]]
    # claim-apply's refusal, on an image nobody owns.
    rm -f "$TMP_DIR/mf.json"
    printf '%s' "$(patch_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    managedfields_project() { MANAGEDFIELDS_PROJECTED="boom"; return 1; }
    managedfields_owner_set() { MANAGEDFIELDS_OWNER_SET='{}'; return 0; }
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-claim-refused"'
    [[ "$output" == *'"reason":"the fields '"'"'keelson'"'"' already applies could not be rebuilt"'* ]]
}

@test "update_apply: an owner that moved is named in its own field" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    printf '%s' "$(patch_obj | MF="$(mf_update_kubectl | sed 's/kubectl-client-side-apply/helm/')" \
        yq -p=json -o=json -I0 '.metadata.managedFields = (strenv(MF) | from_json)')" >"$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *'"event":"update-owner-moved"'*'"now":"helm"'* ]]
}

@test "update_apply: mimic refuses when who else applies the image cannot be read" {
    install_mimic_kubectl
    # Fails only the read after the client-side check, so the checks before
    # it read as they would.
    update_csa_clear() { YQ_FAIL=1; return 0; }
    yq() {
        if [ -n "${YQ_FAIL:-}" ] && [ "$*" = "-p=json -o=json -I0 .metadata.managedFields // []" ]; then
            return 1
        fi
        command yq "$@"
    }
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    [[ "$output" == *"who else applies the image could not be read. Nothing was written."* ]]
    if [ -e "$TMP_DIR/apply.count" ]; then false; fi
    if [ -e "$TMP_DIR/dry.count" ]; then false; fi
}

@test "update_apply: mimic says when the owner's own entry cannot be read" {
    install_mimic_kubectl
    managedfields_owner_set() { return 2; }
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    [[ "$output" == *"what 'argocd-application-controller' owns could not be read. Nothing was written."* ]]
}

@test "update_apply: the duplicate-spelling warning is throttled across updates" {
    # Resolved in this shell, not a subshell, so its throttle stamp holds.
    KEELSON_LOG_WARN_REPEAT_INTERVAL=3600
    install_patch_kubectl
    local ann=$'keelson.pro/field-manager-strategy=claim-patch\nkeelson.pro/fieldManagerStrategy=claim-patch'
    update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann" 2>"$TMP_DIR/first.log"
    printf '%s' "$(patch_obj)" >"$TMP_DIR/obj.json"
    update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" "$ann" 2>"$TMP_DIR/second.log"
    [ "$(cat "$TMP_DIR/first.log" "$TMP_DIR/second.log" | grep -c "are set to the same value")" -eq 1 ]
}

@test "minimal_manifest: every shape names its kind and object, quoted so names stay strings" {
    # Names that read back as a number or a bool unless quoted.
    local kind clist pod api list leaf out
    for kind in Deployment StatefulSet DaemonSet CronJob Rollout; do
        case "$kind" in
            CronJob) api=batch/v1; pod='.spec.jobTemplate.spec.template.spec' ;;
            Rollout) api=argoproj.io/v1alpha1; pod='.spec.template.spec' ;;
            *) api=apps/v1; pod='.spec.template.spec' ;;
        esac
        for clist in containers initContainers imageVolumes; do
            list=$clist leaf=.image
            [ "$clist" = imageVolumes ] && list=volumes leaf=.image.reference
            out=$(update_minimal_manifest "$kind" 456 123 "$clist" 007 on)
            [ "$(yq '.apiVersion + " " + .kind' <<<"$out")" = "$api $kind" ] || { echo "$kind $clist: $out"; return 1; }
            [ "$(yq '[.metadata.name, .metadata.namespace] | map(tag) | join(" ")' <<<"$out")" = '!!str !!str' ] || { echo "$kind $clist: $out"; return 1; }
            [ "$(yq '.metadata.name + "/" + .metadata.namespace' <<<"$out")" = "123/456" ] || { echo "$kind $clist: $out"; return 1; }
            [ "$(yq "${pod}.${list}[0] | [.name, ${leaf}] | map(tag) | join(\" \")" <<<"$out")" = '!!str !!str' ] || { echo "$kind $clist: $out"; return 1; }
            [ "$(yq "${pod}.${list}[0] | .name + \"=\" + ${leaf}" <<<"$out")" = "007=on" ] || { echo "$kind $clist: $out"; return 1; }
        done
    done
}

# --- round seventeen: the fields a JSON consumer reads ---

@test "update_apply: success lines carry from, to, repo and the container on every path" {
    local strategy
    for strategy in claim-patch claim-apply; do
        rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.* "$TMP_DIR/obj.json"
        install_patch_kubectl
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=$strategy \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [[ "$output" == *'"event":"update-applied"'*'"container":"main"'*'"from":"1.2.3","to":"1.2.4","repo":"ghcr.io/x/y"'* ]] || { echo "$strategy: $output"; return 1; }
    done
    install_mimic_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [[ "$output" == *'"event":"update-applied"'*'"container":"main"'*'"from":"1.2.3","to":"1.2.4","repo":"ghcr.io/x/y"'* ]]
}

@test "update_trigger_cronjob: the triggered line carries the job and the update" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    KEELSON_LOG_FORMAT=json run emit update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"event\":\"cronjob-job-triggered\".*\"job\":\"nightly-[0-9]+\",\"from\":\"1.4.2\",\"to\":\"1.4.3\",\"repo\":\"ghcr.io/acme/n\" ]]
}

@test "update_apply: a moved image names what was polled and what is live" {
    install_patch_kubectl
    yq -i -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.5.0"' "$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *'"event":"update-image-moved"'*'"polled":"ghcr.io/x/y:1.2.3","live":"ghcr.io/x/y:1.5.0"'* ]]
}

@test "update_apply: refused annotations name the annotation and why, or the state and value" {
    install_patch_kubectl
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 "" \
        'keelson.pro/fieldManagerStrategy=mimik'
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-invalid-strategy-annotation"'*'"annotation":"keelson.pro/fieldManagerStrategy","value":"mimik"'* ]]
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=bogus \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *'"event":"update-invalid-strategy"'*'"state":"unowned","value":"bogus"'* ]]
}

@test "update_kubectl: leaves no temp file behind, failing or not" {
    mkdir -p "$TMP_DIR/tmp"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo out; echo err >&2; exit "${RC:-0}"
SH
    TMPDIR="$TMP_DIR/tmp" update_kubectl "" get x
    [ "$UPDATE_ERR" = err ]
    local rc=0
    RC=1 TMPDIR="$TMP_DIR/tmp" update_kubectl "" get x || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$(ls -A "$TMP_DIR/tmp")" ]
}

@test "check_polled: already the target wins even with no polled tag" {
    local live='{"spec":{"template":{"spec":{"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.4"}]}}}}' rc=0
    update_check_polled Deployment default app containers main ghcr.io/x/y:1.2.4 "" "$live" || rc=$?
    [ "$rc" -eq 4 ]
}

@test "update_apply: claim-apply keeps the other fields keelson already applies on the element" {
    # keelson's set owns main's pull policy too; sending the element with only
    # name and image would have the server drop it.
    owned_obj Deployment containers main keelson Apply >"$TMP_DIR/obj.json"
    yq -i -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .imagePullPolicy) = "Always"
        | .metadata.managedFields[0].fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"]["k:{\"name\":\"main\"}"]["f:imagePullPolicy"] = {}' "$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq '.spec.template.spec.containers[] | select(.name == "main") | .imagePullPolicy + " " + .image' "$TMP_DIR/apply.stdin")" = "Always ghcr.io/x/y:1.2.4" ]
}

@test "update_apply: a success line is never throttled away" {
    # The same update twice inside the repeat interval: both are said.
    KEELSON_LOG_INFO_REPEAT_INTERVAL=3600
    install_patch_kubectl
    update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 2>"$TMP_DIR/first.log"
    printf '%s' "$(patch_obj)" >"$TMP_DIR/obj.json"
    update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 2>"$TMP_DIR/second.log"
    [ "$(cat "$TMP_DIR/first.log" "$TMP_DIR/second.log" | grep -c "updated from 1.2.3 to 1.2.4")" -eq 2 ]
}

@test "update_trigger_cronjob: a triggered line is never throttled away" {
    KEELSON_LOG_INFO_REPEAT_INTERVAL=3600
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
exit 0
SH
    update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n 2>"$TMP_DIR/first.log"
    update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n 2>"$TMP_DIR/second.log"
    [ "$(cat "$TMP_DIR/first.log" "$TMP_DIR/second.log" | grep -c "created from CronJob 'nightly'")" -eq 2 ]
}

# --- round twenty ---

@test "update_apply: a landed retry names the owner it wrote as, and the strategy" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == patch ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    once '"event":"update-applied"'
    [[ "$output" == *'"event":"update-applied"'*'"manager":"kubectl-client-side-apply","operation":"Update","strategy":"mimic"'*"landed after all"* ]]
}

@test "update_apply: why the fields could not be rebuilt is said at debug" {
    install_mimic_kubectl
    # A field owned under dnsPolicy, which is a string live.
    mimic_obj | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:template"]["f:spec"]["f:dnsPolicy"] = {"f:x": {}}' >"$TMP_DIR/obj.json"
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    grep -F '"event":"update-mimic-refused-detail"' <<<"$output" | grep -q "owned field's parent is not a map in the live object"
    # And claim-apply's, over keelson's own set.
    owned_obj Deployment containers main keelson Apply '{"f:spec":{"f:template":{"f:spec":{"f:dnsPolicy":{"f:x":{}}}}}}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    grep -F '"event":"update-claim-refused-detail"' <<<"$output" | grep -q "owned field's parent is not a map in the live object"
}

@test "conflict_managers: kubectl's capitalised wording is read too" {
    update_conflict_managers 'Apply failed with 1 conflict: Conflict with "flux" using apps/v1: .spec.replicas'
    [ "$UPDATE_CONFLICT_MANAGERS" = "'flux'" ]
}

@test "update_apply: a Rollout whose containers list is atomic is mimicked as its owner, list and all" {
    install_mimic_kubectl
    printf '%s' '{"apiVersion":"argoproj.io/v1alpha1","kind":"Rollout","metadata":{"name":"app","namespace":"default","resourceVersion":"41","managedFields":[{"manager":"argocd-application-controller","operation":"Apply","apiVersion":"argoproj.io/v1alpha1","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:replicas":{},"f:template":{"f:spec":{"f:containers":{}}}}}}]},"spec":{"replicas":3,"template":{"spec":{"containers":[{"name":"sidecar","image":"ghcr.io/x/side:9"},{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"manager":"argocd-application-controller","operation":"Apply","strategy":"mimic"'* ]]
    # The owner's whole list goes back, in order, with only the image changed.
    [ "$(yq -o=json -I0 '.spec.template.spec.containers' "$TMP_DIR/apply.stdin")" = '[{"name":"sidecar","image":"ghcr.io/x/side:9"},{"name":"main","image":"ghcr.io/x/y:1.2.4"}]' ]
}

@test "update_apply: a failed patch try's complaint is kept even when a later try ends the call" {
    install_patch_kubectl
    long_complaint >"$TMP_DIR/patch.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    # The failed try landed after all: the next read finds the target.
    install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == patch ]]; then
    yq -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json" >"$TMP_DIR/obj.next"
    mv "$TMP_DIR/obj.next" "$TMP_DIR/obj.json"
fi
exit \$rc
SH
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    detail_whole update-patch-failed-detail
    once '"event":"update-patch-failed-detail"'
}

@test "claim_merge: a live sibling named like a pattern does not stand in for another element" {
    # keelson's set holds "ab"; a live sibling "a*" must not pick it up.
    local projected='{"spec":{"template":{"spec":{"containers":[{"name":"ab","image":"ghcr.io/x/b:1"}]}}}}'
    local live='{"spec":{"template":{"spec":{"containers":[{"name":"a*","image":"ghcr.io/x/s:1"},{"name":"ab","image":"ghcr.io/x/b:1"},{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}'
    update_claim_merge Deployment containers main ghcr.io/x/y:1.2.4 "$projected" "$live"
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.containers' <<<"$UPDATE_CLAIM_MANIFEST")" = '[{"name":"ab","image":"ghcr.io/x/b:1"},{"name":"main","image":"ghcr.io/x/y:1.2.4"}]' ]
}

@test "claim_merge: live names too big for one environment string are still read" {
    local big projected live
    big=$(head -c 140000 /dev/zero | tr '\0' x)
    projected='{"spec":{"template":{"spec":{"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}'
    live='{"spec":{"template":{"spec":{"containers":[{"name":"'"$big"'","image":"ghcr.io/x/s:1"},{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}'
    update_claim_merge Deployment containers main ghcr.io/x/y:1.2.4 "$projected" "$live"
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.containers' <<<"$UPDATE_CLAIM_MANIFEST")" = '[{"name":"main","image":"ghcr.io/x/y:1.2.4"}]' ]
}

@test "update_apply: an image moved to another repository at the same tag is moved" {
    install_patch_kubectl
    yq -i -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "mirror.example/x/y:1.2.3"' "$TMP_DIR/obj.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    [[ "$output" == *"it runs 'mirror.example/x/y:1.2.3' now, not 'ghcr.io/x/y:1.2.3' as polled"* ]]
    if [ -e "$TMP_DIR/patch.count" ]; then false; fi
}

@test "update_apply: success lines on claim-apply, mimic and a landed retry are never throttled" {
    KEELSON_LOG_INFO_REPEAT_INTERVAL=3600
    local i
    # claim-apply, twice.
    install_patch_kubectl
    for i in 1 2; do
        printf '%s' "$(patch_obj)" >"$TMP_DIR/obj.json"
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
            update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 2>>"$TMP_DIR/claim.log"
    done
    [ "$(grep -c "updated from 1.2.3 to 1.2.4 by claim-apply" "$TMP_DIR/claim.log")" -eq 2 ]
    # mimic, twice.
    install_mimic_kubectl
    for i in 1 2; do
        printf '%s' "$(mimic_obj)" >"$TMP_DIR/obj.json"
        update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 2>>"$TMP_DIR/mimic.log"
    done
    [ "$(grep -c "updated from 1.2.3 to 1.2.4 by mimic" "$TMP_DIR/mimic.log")" -eq 2 ]
    # A landed retry, twice: the first patch of each call fails but lands.
    rm -f "$TMP_DIR"/mf.json "$TMP_DIR"/patch.* "$TMP_BIN/kubectl.real"
    printf '%s' "$(patch_obj)" >"$TMP_DIR/obj.json"
    install_patch_kubectl
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == patch ]]; then
    yq -i -p=json -o=json -I0 '(.spec.template.spec.containers[] | select(.name == "main") | .image) = "ghcr.io/x/y:1.2.4"' "$TMP_DIR/obj.json"
    echo 'error: the server was unable to return a response in the time allotted' >&2
    exit 1
fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    for i in 1 2; do
        printf '%s' "$(patch_obj)" >"$TMP_DIR/obj.json"
        update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 2>>"$TMP_DIR/landed.log"
    done
    [ "$(grep -c "landed after all" "$TMP_DIR/landed.log")" -eq 2 ]
}

# field_on <event> <field> <value>: that event's line carries the field.
field_on() {
    grep -F "\"event\":\"$1\"" <<<"$output" | grep -qF "\"$2\":\"$3\"" \
        || { echo "$1 lacks $2=$3: $output"; return 1; }
}

@test "update_apply: failure lines name the manager written as and the strategy" {
    # mimic on update-owned: three refused patches, as the owner.
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    local i
    for i in 1 2 3; do echo 'error: unable to reach cluster' >"$TMP_DIR/patch.err.$i"; done
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    field_on update-failed manager kubectl-client-side-apply
    field_on update-failed strategy mimic
    # Its object read failing.
    rm -f "$TMP_DIR"/patch.*
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == get ]] && [[ "\$*" != *jsonpath* ]]; then echo 'Unable to connect to the server' >&2; exit 1; fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    field_on update-failed manager kubectl-client-side-apply
    field_on update-failed strategy mimic
    # mimic on apply-owned: a failed dry run, then three stale real applies.
    rm -f "$TMP_BIN/kubectl.real"
    install_mimic_kubectl
    echo 'error: unable to reach cluster' >"$TMP_DIR/dry.err"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    field_on update-failed manager argocd-application-controller
    rm -f "$TMP_DIR/dry.err"
    for i in 1 2 3; do
        apply_409 "$STALE_MSG" >"$TMP_DIR/apply.err.$i"
    done
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    field_on update-failed manager argocd-application-controller
    # A mimic refusal names its manager.
    rm -f "$TMP_DIR"/apply.*
    yq -i -p=json -o=json -I0 '.metadata.managedFields = "garbage"' "$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    field_on update-mimic-refused manager argocd-application-controller
}

@test "update_apply: an owner that moved names the manager it would have written as" {
    printf '%s' "$(mf_update_kubectl)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    printf '%s' "$(patch_obj | MF="$(mf_update_kubectl | sed 's/kubectl-client-side-apply/helm/')" \
        yq -p=json -o=json -I0 '.metadata.managedFields = (strenv(MF) | from_json)')" >"$TMP_DIR/obj.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    field_on update-owner-moved manager kubectl-client-side-apply
    field_on update-owner-moved now helm
}

# --- claim-apply never replaces an atomic list ---

@test "update_apply: claim-apply refuses a Rollout whose containers list is held whole" {
    install_mimic_kubectl
    printf '%s' '{"apiVersion":"argoproj.io/v1alpha1","kind":"Rollout","metadata":{"name":"app","namespace":"default","resourceVersion":"41","managedFields":[{"manager":"argocd-application-controller","operation":"Apply","apiVersion":"argoproj.io/v1alpha1","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{}}}}}}]},"spec":{"template":{"spec":{"containers":[{"name":"sidecar","image":"ghcr.io/x/side:9"},{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-claim-refused"'
    [[ "$output" == *"its containers list is held whole (atomic), so sending the image alone would replace the whole list; claim-patch changes only the image. Nothing was written."* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: claim-apply refuses a Rollout with no managedFields to tell by" {
    install_patch_kubectl
    obj_kind Rollout
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"it records no managedFields to tell whether its containers list is atomic"* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: claim-apply still sends the image alone where the list is keyed" {
    # A Deployment with no managedFields, and a Rollout whose list is keyed.
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    rm -f "$TMP_DIR"/apply.* "$TMP_DIR/obj.json"
    owned_obj Rollout containers main argocd-application-controller Apply >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ -e "$TMP_DIR/apply.stdin" ]
}

@test "update_apply: mimic sends the owner's empty template annotations past kubectl's restartedAt" {
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '
        .metadata.managedFields[0].fieldsV1["f:spec"]["f:template"]["f:metadata"] = {"f:annotations": {}}
        | .metadata.managedFields += [{"manager": "kubectl-rollout", "operation": "Update", "time": "2026-04-02T10:00:00Z",
            "fieldsV1": {"f:spec": {"f:template": {"f:metadata": {"f:annotations": {"f:kubectl.kubernetes.io/restartedAt": {}}}}}}}]
        | .spec.template.metadata = {"annotations": {"kubectl.kubernetes.io/restartedAt": "2026-04-02T10:00:00Z"}}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"by mimic (as configured)"* ]]
    [ "$(yq -o=json -I0 '.spec.template.metadata.annotations' "$TMP_DIR/apply.stdin")" = '{}' ]
}

# --- a workload gone since the poll is a skip ---

GONE='Error from server (NotFound): deployments.apps "app" not found'

# gone_on_get <== or !=> [<line>]: a get that is (==) or is not (!=) the
# jsonpath ownership read answers NotFound (<line>, $GONE by default), as for
# a workload deleted since the poll.
gone_on_get() {
    local line=${2:-$GONE}
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == get ]] && [[ "\$*" $1 *jsonpath* ]]; then echo '$line' >&2; exit 1; fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
}

# gone_ok: a skip at info, said once, no error, and status 3.
# Every line returns on failure itself: a caller may run it on the left of
# ||, where errexit is off and a bare assertion would fail silently.
gone_ok() {
    [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
    once '"event":"update-workload-gone"' || return 1
    at_level INFO '"event":"update-workload-gone"' || return 1
    if grep -q '"level":"ERROR"' <<<"$output"; then echo "error logged: $output"; return 1; fi
}

@test "update_apply: a workload gone at the ownership read is a skip" {
    install_patch_kubectl
    gone_on_get '=='
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    gone_ok
    [[ "$output" == *"Deployment 'app' in 'default' is gone since the poll; nothing to write."* ]]
    if [ -e "$TMP_DIR/patch.count" ]; then false; fi
}

@test "update_apply: a workload gone at each path's fresh read is a skip, nothing written" {
    local strategy
    for strategy in claim-patch claim-apply; do
        rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.* "$TMP_DIR/obj.json" "$TMP_BIN/kubectl.real"
        install_patch_kubectl
        gone_on_get '!='
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=$strategy \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        gone_ok || { echo "$strategy"; return 1; }
        if [ -e "$TMP_DIR/patch.count" ] || [ -e "$TMP_DIR/apply.count" ]; then echo "$strategy wrote"; return 1; fi
    done
    rm -f "$TMP_BIN/kubectl.real"
    install_mimic_kubectl
    gone_on_get '!='
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    gone_ok
    if [ -e "$TMP_DIR/dry.count" ] || [ -e "$TMP_DIR/apply.count" ]; then false; fi
}

@test "update_apply: a workload gone at the write itself is a skip, not retried" {
    install_patch_kubectl
    echo "$GONE" >"$TMP_DIR/patch.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    gone_ok
    [ "$(cat "$TMP_DIR/patch.count")" -eq 1 ]
    # claim-apply's apply.
    rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.*
    echo "$GONE" >"$TMP_DIR/apply.err.1"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    gone_ok
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
    # mimic's dry run, then its real apply.
    rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.*
    install_mimic_kubectl
    echo "$GONE" >"$TMP_DIR/dry.err"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    gone_ok
    if [ -e "$TMP_DIR/apply.count" ]; then false; fi
    rm -f "$TMP_DIR"/dry.* "$TMP_DIR"/apply.*
    echo "$GONE" >"$TMP_DIR/apply.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    gone_ok
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
}

# A validating or mutating webhook may deny with reason NotFound: the server
# keeps the reason, and kubectl prints it as it prints a real one.
HOOK_NOTFOUND='Error from server (NotFound): admission webhook "guard.example.com" denied the request: image not found in registry'

@test "update_apply: a webhook denying a patch with reason NotFound is an error, not gone" {
    install_patch_kubectl
    local n
    for n in 1 2 3; do echo "$HOOK_NOTFOUND" >"$TMP_DIR/patch.err.$n"; done
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" != *'"event":"update-workload-gone"'* ]]
    once '"event":"update-failed"'
    [[ "$output" == *'Error from server (NotFound): admission'* ]]
}

@test "update_apply: a webhook denying mimic's dry run with reason NotFound is refused, not gone" {
    install_mimic_kubectl
    echo "$HOOK_NOTFOUND" >"$TMP_DIR/dry.err"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" != *'"event":"update-workload-gone"'* ]]
    [[ "$output" == *'"level":"ERROR"'* ]]
    if [ -e "$TMP_DIR/apply.count" ]; then false; fi
}

@test "update_apply: the namespace gone, at a patch or a dry run, is the workload gone" {
    install_patch_kubectl
    echo 'Error from server (NotFound): namespaces "default" not found' >"$TMP_DIR/patch.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    gone_ok
    [ "$(cat "$TMP_DIR/patch.count")" -eq 1 ]
    rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.* "$TMP_DIR"/dry.*
    install_mimic_kubectl
    echo 'Error from server (NotFound): namespaces "default" not found' >"$TMP_DIR/dry.err"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    gone_ok
    if [ -e "$TMP_DIR/apply.count" ]; then false; fi
}

NS_GONE='Error from server (NotFound): namespaces "default" not found'

@test "update_apply: the namespace gone at any of the nine reads and writes is the workload gone" {
    # Each site judges its own kubectl's complaint with this namespace: one
    # given another would miss the namespace form and fail or retry.
    local site
    for site in own-read patch-read patch apply-read apply mimic-read mimic-dry mimic-forced-dry mimic-apply; do
        rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.* "$TMP_DIR"/dry.* "$TMP_DIR"/mf.json "$TMP_DIR/obj.json" "$TMP_BIN/kubectl.real"
        case "$site" in
            mimic-*) install_mimic_kubectl ;;
            *) install_patch_kubectl ;;
        esac
        case "$site" in
            own-read) gone_on_get '==' "$NS_GONE" ;;
            *-read) gone_on_get '!=' "$NS_GONE" ;;
            patch) echo "$NS_GONE" >"$TMP_DIR/patch.err.1" ;;
            apply | mimic-apply) echo "$NS_GONE" >"$TMP_DIR/apply.err.1" ;;
            mimic-dry) echo "$NS_GONE" >"$TMP_DIR/dry.err.1" ;;
            mimic-forced-dry) add_entry kubectl-client-side-apply Update
                apply_409 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
                echo "$NS_GONE" >"$TMP_DIR/dry.err.2" ;;
        esac
        local unowned=claim-patch
        case "$site" in apply*) unowned=claim-apply ;; esac
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=$unowned \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        gone_ok || { echo "$site"; return 1; }
        case "$site" in
            patch) [ "$(cat "$TMP_DIR/patch.count")" -eq 1 ] || { echo "$site retried"; return 1; } ;;
            apply | mimic-apply) [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ] || { echo "$site retried"; return 1; } ;;
            *) if [ -e "$TMP_DIR/patch.count" ] || [ -e "$TMP_DIR/apply.count" ]; then echo "$site wrote"; return 1; fi ;;
        esac
    done
}

@test "update_apply: every kind gone at a patch or an apply is the workload gone" {
    # Each kind's NotFound names its own qualified resource: one judged as a
    # Deployment's would miss every kind but that.
    local kind res site
    for kind in StatefulSet DaemonSet CronJob Rollout; do
        res=$(update_resource_name "$kind")
        for site in patch claim-apply mimic-apply; do
            rm -f "$TMP_DIR"/patch.* "$TMP_DIR"/apply.* "$TMP_DIR"/dry.* "$TMP_DIR"/mf.json "$TMP_DIR/obj.json"
            # Unowned for the patch; owned by an applier for the applies, so
            # a Rollout's list is known keyed (claim-apply refuses one that
            # records nothing).
            case "$site" in
                patch) owned_obj "$kind" containers main nobody Update | yq -p=json -o=json -I0 '.metadata.managedFields = []' >"$TMP_DIR/obj.json"
                    install_patch_kubectl
                    echo "Error from server (NotFound): $res \"app\" not found" >"$TMP_DIR/patch.err.1" ;;
                claim-apply) owned_obj "$kind" containers main argocd-application-controller Apply >"$TMP_DIR/obj.json"
                    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
                    install_patch_kubectl ;;
                mimic-apply) install_mimic_kubectl
                    owned_obj "$kind" containers main argocd-application-controller Apply >"$TMP_DIR/obj.json"
                    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json" ;;
            esac
            [ "$site" = patch ] || echo "Error from server (NotFound): $res \"app\" not found" >"$TMP_DIR/apply.err.1"
            local applied=mimic
            [ "$site" = claim-apply ] && applied=claim-apply
            KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=$applied \
            KEELSON_LOG_FORMAT=json run emit update_apply "$kind" default app containers main ghcr.io/x/y:1.2.4 1.2.3
            gone_ok || { echo "$kind $site"; return 1; }
            [[ "$output" == *"$kind 'app' in 'default' is gone since the poll; nothing to write."* ]] || { echo "$kind $site: $output"; return 1; }
            case "$site" in
                patch) [ "$(cat "$TMP_DIR/patch.count")" -eq 1 ] || { echo "$kind $site retried"; return 1; } ;;
                *) [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ] || { echo "$kind $site retried"; return 1; } ;;
            esac
        done
    done
}

@test "update_apply: a NotFound naming another object is an error, not gone" {
    install_patch_kubectl
    local n
    for n in 1 2 3; do echo 'Error from server (NotFound): deployments.apps "other" not found' >"$TMP_DIR/patch.err.$n"; done
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" != *'"event":"update-workload-gone"'* ]]
    once '"event":"update-failed"'
}

@test "update_apply: gone after a try that may have landed says so" {
    install_patch_kubectl
    echo 'error: the server was unable to return a response in the time allotted' >"$TMP_DIR/patch.err.1"
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == get ]] && [ -e "$TMP_DIR/patch.count" ] && [[ "\$*" != *jsonpath* ]]; then
    echo '$GONE' >&2; exit 1
fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    gone_ok
    [[ "$output" == *"is gone since the poll; an earlier try may have landed before it went; nothing more to write."* ]]
}

@test "update_apply: a read failure other than NotFound is still an error" {
    install_patch_kubectl
    mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
    install_shim kubectl <<SH
#!/usr/bin/env bash
if [[ "\$1" == get ]] && [[ "\$*" != *jsonpath* ]]; then echo 'Error from server (Forbidden): deployments.apps "app" is forbidden' >&2; exit 1; fi
exec "$TMP_BIN/kubectl.real" "\$@"
SH
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" != *'"event":"update-workload-gone"'* ]]
    one_error
}

# --- kubectl's client-side-apply migration: no server-side apply ---

# with_csa_entry <manager> <operation>: obj.json gains an entry of that
# manager and operation owning kubectl's last-applied-configuration.
with_csa_entry() {
    M=$1 OP=$2 yq -i -p=json -o=json -I0 '.metadata.managedFields = ((.metadata.managedFields // []) + [{"manager": strenv(M), "operation": strenv(OP), "time": "2026-01-01T00:00:00Z", "fieldsV1": {"f:metadata": {"f:annotations": {".": {}, "f:kubectl.kubernetes.io/last-applied-configuration": {}}}}}])' "$TMP_DIR/obj.json"
}

@test "update_apply: mimic refuses while a client-side applier owns last-applied-configuration" {
    install_mimic_kubectl
    with_csa_entry kubectl-client-side-apply Update
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-mimic-refused"'
    [[ "$output" == *"an Update entry of 'kubectl-client-side-apply' owns kubectl's last-applied-configuration annotation, so kubectl apply would merge that manager's fields into 'argocd-application-controller' after the write, unseen by the dry run; remove the annotation (or that entry), or use claim-patch. Nothing was written."* ]]
    if [ -e "$TMP_DIR/dry.count" ] || [ -e "$TMP_DIR/apply.count" ]; then false; fi
}

@test "update_apply: claim-apply refuses while a client-side applier owns last-applied-configuration" {
    install_patch_kubectl
    with_csa_entry kubectl-client-side-apply Update
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-claim-refused"'
    [[ "$output" == *"so kubectl apply would merge that manager's fields into 'keelson' after the write"* ]]
    if [ -e "$TMP_DIR/apply.count" ]; then false; fi
}

@test "update_apply: claim-apply refuses an object with no managedFields that carries last-applied-configuration" {
    install_patch_kubectl
    yq -i -p=json -o=json -I0 '.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] = "{}"' "$TMP_DIR/obj.json"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-claim-refused"'
    [[ "$output" == *"it records no managedFields but carries kubectl's last-applied-configuration, so kubectl apply would hand 'keelson' every field after the write; remove the annotation, or use claim-patch"* ]]
    if [ -e "$TMP_DIR/apply.count" ] || [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
    if grep -q -- "^apply" "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: claim-apply refuses an object with no managedFields whose last-applied-configuration reads as null" {
    # Mimic never gets this far: with no managedFields there is no owner.
    install_patch_kubectl
    yq -i -p=json -o=json -I0 '.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] = "null"' "$TMP_DIR/obj.json"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-claim-refused"'
    [[ "$output" == *"it records no managedFields but carries kubectl's last-applied-configuration"* ]]
    if [ -e "$TMP_DIR/apply.count" ] || [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: claim-apply still writes an object with no managedFields and no last-applied-configuration" {
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"by claim-apply (as configured)"* ]]
    [ -e "$TMP_DIR/apply.stdin" ]
}

@test "update_apply: an Apply entry owning last-applied-configuration does not stop mimic" {
    install_mimic_kubectl
    with_csa_entry flux Apply
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
}

# as_kubectl_owner: obj.json's owner is "kubectl" and carries kubectl's
# last-applied-configuration, owned by no entry; mf.json follows.
as_kubectl_owner() {
    yq -i -p=json -o=json -I0 '.metadata.managedFields[0].manager = "kubectl" | .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] = "{}"' "$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
}

@test "update_apply: mimic as kubectl refuses while no Apply entry owns last-applied-configuration" {
    # kubectl would follow the dry run with an apply as kubectl-last-applied
    # and print that one's result, which the guard would check instead.
    install_mimic_kubectl
    as_kubectl_owner
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    once '"event":"update-mimic-refused"'
    [[ "$output" == *'"manager":"kubectl"'* ]]
    [[ "$output" == *"it carries kubectl's last-applied-configuration and no Apply entry owns it, so kubectl apply as 'kubectl' would send a second apply, as 'kubectl-last-applied', and print that one's result for the dry run's, unseen by the guard; remove the annotation, or use claim-patch. Nothing was written."* ]]
    if [ -e "$TMP_DIR/dry.count" ] || [ -e "$TMP_DIR/apply.count" ]; then false; fi
}

@test "update_apply: mimic as kubectl refuses an unowned last-applied-configuration whose value reads as null" {
    install_mimic_kubectl
    as_kubectl_owner
    yq -i -p=json -o=json -I0 '.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] = "null"' "$TMP_DIR/obj.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"no Apply entry owns it, so kubectl apply as 'kubectl' would send a second apply"* ]]
    if [ -e "$TMP_DIR/dry.count" ] || [ -e "$TMP_DIR/apply.count" ]; then false; fi
}

@test "update_apply: mimic as kubectl writes once an Apply entry owns last-applied-configuration" {
    install_mimic_kubectl
    as_kubectl_owner
    with_csa_entry kubectl-last-applied Apply
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
}

@test "update_apply: an Apply entry owning last-applied-configuration on a subresource does not clear mimic as kubectl" {
    install_mimic_kubectl
    as_kubectl_owner
    with_csa_entry kubectl-last-applied Apply
    yq -i -p=json -o=json -I0 '.metadata.managedFields[-1].subresource = "status"' "$TMP_DIR/obj.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"no Apply entry owns it, so kubectl apply as 'kubectl' would send a second apply"* ]]
    if [ -e "$TMP_DIR/dry.count" ] || [ -e "$TMP_DIR/apply.count" ]; then false; fi
}

@test "update_apply: an unowned last-applied-configuration does not stop mimic as another manager" {
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] = "{}"' "$TMP_DIR/obj.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
}

@test "update_apply: claim-patch still writes while a client-side applier owns last-applied-configuration" {
    install_patch_kubectl
    with_csa_entry kubectl-client-side-apply Update
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"by claim-patch (as configured)"* ]]
}

@test "update_apply: mimic leaves out a port protocol the owner never sent" {
    # The owner applied a port without protocol; the server defaulted it.
    install_mimic_kubectl
    printf '%s' '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"app","namespace":"default","resourceVersion":"41","managedFields":[{"manager":"argocd-application-controller","operation":"Apply","apiVersion":"apps/v1","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{".":{},"f:name":{},"f:image":{},"f:ports":{"k:{\"containerPort\":80,\"protocol\":\"TCP\"}":{".":{},"f:containerPort":{}}}}}}}}}}]},"spec":{"template":{"spec":{"containers":[{"name":"main","image":"ghcr.io/x/y:1.2.3","ports":[{"containerPort":80,"protocol":"TCP"}]}]}}}}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq -o=json -I0 '.spec.template.spec.containers[0].ports' "$TMP_DIR/apply.stdin")" = '[{"containerPort":80}]' ]
    [ "$(yq '.spec.template.spec.containers[0].image' "$TMP_DIR/apply.stdin")" = "ghcr.io/x/y:1.2.4" ]
}

@test "update_apply: an invalid strategy names the annotation actually set" {
    install_patch_kubectl
    local key list target
    for key in keelson.pro/field-manager-strategy keelson.pro/fieldManagerStrategy \
            keelson.pro/field-manager-strategy.containers.main keelson.pro/fieldManagerStrategy.containers.main \
            keelson.pro/field-manager-strategy.volumes.models; do
        list=containers target=main
        case "$key" in *.volumes.*) list=imageVolumes target=models ;; esac
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app "$list" "$target" ghcr.io/x/y:1.2.4 1.2.3 "" "$key=mimik"
        [ "$status" -eq 1 ] || { echo "$key: $output"; return 1; }
        [[ "$output" == *"\"annotation\":\"$key\",\"value\":\"mimik\""*"Invalid $key annotation value 'mimik'"* ]] \
            || { echo "$key: $output"; return 1; }
    done
}

# --- round twenty-seven ---

UID_GONE=$(apply_409 'Operation cannot be fulfilled on deployments.apps "app": uid mismatch: the provided object specified uid uid-1, and no existing object was found')

@test "update_apply: mimic's and claim-apply's bodies carry the read's uid" {
    # An apply is an upsert: without the uid it would create a deleted
    # object anew.
    install_mimic_kubectl
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq '.metadata.uid' "$TMP_DIR/dry.stdin")" = uid-1 ]
    [ "$(yq '.metadata.uid' "$TMP_DIR/apply.stdin")" = uid-1 ]
    rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/mf.json "$TMP_DIR/obj.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(yq '.metadata.uid' "$TMP_DIR/apply.stdin")" = uid-1 ]
}

@test "update_apply: a uid mismatch on any apply is the workload gone, never a resurrection" {
    local site
    for site in mimic-dry mimic-forced-dry mimic-apply mimic-forced-apply claim-apply; do
        rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.* "$TMP_DIR"/mf.json "$TMP_DIR/obj.json"
        case "$site" in
            mimic-dry) install_mimic_kubectl; echo "$UID_GONE" >"$TMP_DIR/dry.err.1" ;;
            mimic-forced-dry) install_mimic_kubectl; add_entry kubectl-client-side-apply Update
                apply_409 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
                echo "$UID_GONE" >"$TMP_DIR/dry.err.2" ;;
            mimic-apply) install_mimic_kubectl; echo "$UID_GONE" >"$TMP_DIR/apply.err.1" ;;
            mimic-forced-apply) install_mimic_kubectl; add_entry kubectl-client-side-apply Update
                apply_409 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
                echo "$UID_GONE" >"$TMP_DIR/apply.err.1" ;;
            claim-apply) install_patch_kubectl; echo "$UID_GONE" >"$TMP_DIR/apply.err.1" ;;
        esac
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 3 ] || { echo "$site: $output"; return 1; }
        once '"event":"update-workload-gone"'
        [[ "$output" != *'"level":"ERROR"'* ]] || { echo "$site: $output"; return 1; }
        case "$site" in
            *-dry) if [ -e "$TMP_DIR/apply.stdin" ]; then echo "$site applied"; return 1; fi ;;
            *) [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ] ;;
        esac
    done
}

@test "update_apply: a workload replaced since the read is read again before any write" {
    # Deleted and re-created under the same name after the first object
    # read (swap_after_read: a new uid and resourceVersion, plus the yq in
    # swap). The shim refuses the old uid as the server does, stale, so the
    # write is retried from a fresh read of the new object, never sent
    # against the old one, and never reported gone.
    swap_after_read() {
        mv "$TMP_BIN/kubectl" "$TMP_BIN/kubectl.real"
        install_shim kubectl <<SH
#!/usr/bin/env bash
"$TMP_BIN/kubectl.real" "\$@"; rc=\$?
if [[ "\$1" == get ]] && [[ "\$*" != *jsonpath* ]] && [ -e "$TMP_DIR/swap" ]; then
    yq -i -p=json -o=json -I0 ".metadata.uid = \"uid-2\" | .metadata.resourceVersion = \"42\" | \$(cat "$TMP_DIR/swap")" "$TMP_DIR/obj.json"
    rm "$TMP_DIR/swap"
fi
exit \$rc
SH
    }
    local site
    for site in mimic mimic-new-owner claim-apply; do
        rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.* "$TMP_DIR"/mf.json "$TMP_DIR/obj.json" "$TMP_DIR/kubectl.log"
        case "$site" in
            mimic) install_mimic_kubectl; echo '.' >"$TMP_DIR/swap" ;;
            mimic-new-owner) install_mimic_kubectl
                echo '.metadata.managedFields[0].manager = "helm"' >"$TMP_DIR/swap" ;;
            claim-apply) install_patch_kubectl; echo '.' >"$TMP_DIR/swap" ;;
        esac
        swap_after_read
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [[ "$output" != *'"event":"update-workload-gone"'* ]] || { echo "$site: $output"; return 1; }
        [ "$(grep -c -- '-o json --show-managed-fields$' "$TMP_DIR/kubectl.log")" -eq 2 ] \
            || { echo "$site: $(cat "$TMP_DIR/kubectl.log")"; return 1; }
        case "$site" in
            mimic)
                # The first dry run, against the old uid, was refused stale.
                [ "$status" -eq 0 ] || { echo "$site: $output"; return 1; }
                [ "$(cat "$TMP_DIR/dry.count")" -eq 2 ]
                [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
                [ "$(yq '.metadata.uid' "$TMP_DIR/dry.stdin")" = uid-2 ]
                [ "$(yq '.metadata.uid + " " + .metadata.resourceVersion' "$TMP_DIR/apply.stdin")" = "uid-2 42" ]
                ;;
            mimic-new-owner)
                # The fresh read finds the image owned by another manager.
                [ "$status" -eq 3 ] || { echo "$site: $output"; return 1; }
                once '"event":"update-owner-moved"'
                [[ "$output" == *"the image is now owned by 'helm'"* ]]
                [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
                if [ -e "$TMP_DIR/apply.stdin" ]; then echo "$site applied"; return 1; fi
                ;;
            claim-apply)
                # The first apply, against the old uid, was refused stale.
                [ "$status" -eq 0 ] || { echo "$site: $output"; return 1; }
                [ "$(cat "$TMP_DIR/apply.count")" -eq 2 ]
                [ "$(yq '.metadata.uid + " " + .metadata.resourceVersion' "$TMP_DIR/apply.stdin")" = "uid-2 42" ]
                ;;
        esac
    done
}

@test "update_apply: an apply naming another uid without a resourceVersion is refused immutable" {
    # The shim's answer for a body with no resourceVersion, as the server
    # gives it forced (k3s v1.34.1, 2026-10-20); Keelson always sends one,
    # so this pins the shim, not the code.
    install_patch_kubectl
    printf '%s' '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"app","namespace":"default","uid":"uid-1"}}' >"$TMP_DIR/body.json"
    run kubectl apply --server-side -f - <"$TMP_DIR/body.json"
    [ "$status" -eq 0 ]
    yq -i -p=json -o=json -I0 '.metadata.uid = "uid-2"' "$TMP_DIR/obj.json"
    run kubectl apply --server-side -f - <"$TMP_DIR/body.json"
    [ "$status" -eq 1 ]
    [ "$output" = 'The Deployment "app" is invalid: metadata.uid: Invalid value: "uid-1": field is immutable' ]
    yq -i -p=json -o=json -I0 '.metadata.resourceVersion = "40"' "$TMP_DIR/body.json"
    run kubectl apply --server-side -f - <"$TMP_DIR/body.json"
    [ "$status" -eq 1 ]
    [[ "$output" == 'error: Operation cannot be fulfilled on deployments.apps "app": the object has been modified; please apply your changes to the latest version and try again'* ]]
}

@test "update_apply: claim-apply with no uid in the read is refused" {
    install_patch_kubectl
    touch "$TMP_DIR/no-uid"
    KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply \
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"the read carries no resourceVersion and uid to write against. Nothing was written."* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_trigger_cronjob: a failed trigger says why" {
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
echo 'Error from server (Forbidden): jobs.batch is forbidden: User "keelson" cannot create resource "jobs"' >&2
exit 1
SH
    KEELSON_LOG_FORMAT=json run emit update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n
    [ "$status" -eq 1 ]
    once '"event":"cronjob-job-trigger-failed"'
    [[ "$output" == *'"event":"cronjob-job-trigger-failed"'*'"reason":"Error from server (Forbidden)'* ]]
    [[ "$output" == *"from CronJob 'nightly' in 'batch': Error from server (Forbidden)"* ]]
    # The whole complaint, unclipped, at debug.
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=json run emit update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n
    grep -F '"event":"cronjob-job-trigger-failed-detail"' <<<"$output" | grep -q 'cannot create resource'
}

@test "update_apply: claim-apply adding an element to keelson's set refuses an atomic list" {
    # keelson applies side's image; argocd holds the whole list (a Rollout
    # before v1.9): adding main would replace the list.
    printf '%s' '{"apiVersion":"argoproj.io/v1alpha1","kind":"Rollout","metadata":{"name":"app","namespace":"default","resourceVersion":"41","managedFields":[{"manager":"argocd-application-controller","operation":"Apply","apiVersion":"argoproj.io/v1alpha1","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{}}}}}},{"manager":"keelson","operation":"Apply","apiVersion":"argoproj.io/v1alpha1","time":"2026-03-01T10:00:00Z","fieldsV1":{"f:spec":{"f:replicas":{}}}}]},"spec":{"replicas":2,"template":{"spec":{"containers":[{"name":"side","image":"ghcr.io/x/s:9"},{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"its containers list is held whole (atomic), so adding the image to what 'keelson' applies would replace the whole list"* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: an ancestor of the list held whole refuses claim-apply too" {
    install_patch_kubectl
    obj_kind Rollout
    yq -i -p=json -o=json -I0 '.metadata.managedFields = [{"manager":"argocd-application-controller","operation":"Apply","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{}}}}]' "$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply \
    run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"held whole (atomic)"* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "conflict_names: Go-quoted names are read back exactly, an unknown escape makes none" {
    update_conflict_names 'Apply failed with 2 conflicts: conflicts with "x\"y" using apps/v1: .spec.replicas
conflict with "a\\b\tc" using apps/v1: .spec.paused'
    [ "${#UPDATE_CONFLICT_NAMES[@]}" -eq 2 ]
    [ "${UPDATE_CONFLICT_NAMES[0]}" = 'x"y' ]
    [ "${UPDATE_CONFLICT_NAMES[1]}" = $'a\\b\tc' ]
    update_conflict_names 'Apply failed with 1 conflict: conflict with "d\ne" using apps/v1: .spec.replicas'
    [ "${#UPDATE_CONFLICT_NAMES[@]}" -eq 1 ]
    [ "${UPDATE_CONFLICT_NAMES[0]}" = $'d\ne' ]
    update_conflict_names 'Apply failed with 1 conflict: conflict with "a\x41" using apps/v1: .spec.replicas'
    [ "${#UPDATE_CONFLICT_NAMES[@]}" -eq 0 ]
}

@test "conflict_names: an Update entry on a subresource is read as an Update entry" {
    # The server puts the subresource between the name and its using.
    update_conflict_names 'Apply failed with 2 conflicts: conflicts with "m" with subresource "st\"at" using apps/v1:
- .status.replicas
conflicts with "a" with subresource "status":
- .status.paused'
    [ "${#UPDATE_CONFLICT_NAMES[@]}" -eq 2 ]
    [ "${UPDATE_CONFLICT_NAMES[0]}" = m ]
    [ "${UPDATE_CONFLICT_NAMES[1]}" = a ]
    [ "$UPDATE_CONFLICT_BY_UPDATE" = $'m\n' ]
    [ "$UPDATE_CONFLICT_BY_APPLY" = $'a\n' ]
}

@test "update_apply: keelson's Update entry on a subresource is not called its own Apply entry" {
    install_mimic_kubectl
    add_entry keelson Update
    apply_409 'Apply failed with 1 conflict: conflict with "keelson" with subresource "status" using apps/v1: .spec.template.spec.containers[name="main"].image' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past Update entries of 'keelson', for image"* ]]
    [[ "$output" != *"keelson's own Apply entry"* ]]
}

@test "update_apply: an applier whose name Go quotes with escapes is still a second applier" {
    install_mimic_kubectl
    add_entry 'x"y' Apply
    apply_409 'Apply failed with 1 conflict: conflict with "x\"y" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"'x\"y' also applies these fields (Apply); two managers apply this workload"* ]]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: an applier on a subresource is still a second applier" {
    # Its Apply entry is on scale, not the object, and the server names it
    # with no using; mimic must not file it as an Update entry and force.
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields += [{"manager": "m", "operation": "Apply", "subresource": "scale", "time": "2026-03-01T10:00:00Z", "fieldsV1": {"f:spec": {"f:replicas": {}}}}]' "$TMP_DIR/obj.json"
    apply_409 'Apply failed with 1 conflict: conflict with "m" with subresource "scale": .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"'m' also applies these fields (Apply); two managers apply this workload"* ]]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: a subresource applier listed after an Update-held manager is still a second applier" {
    # Grouped as the server prints it: sorted by the printed manager, an
    # Update's carrying its apiVersion and no time (k3s v1.34.1). Only a
    # using straight after m's name and subresource would make m an Update
    # entry.
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields += [{"manager": "m", "operation": "Apply", "subresource": "scale", "time": "2026-03-01T10:00:00Z", "fieldsV1": {"f:spec": {"f:replicas": {}}}}]' "$TMP_DIR/obj.json"
    add_entry helm Update
    apply_409 'Apply failed with 2 conflicts: conflicts with "helm" using apps/v1:
- .spec.template.spec.containers[name="main"].image
conflicts with "m" with subresource "scale":
- .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"'m' also applies these fields (Apply); two managers apply this workload"* ]]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    if grep -q -- "--force-conflicts" "$TMP_DIR/kubectl.log"; then false; fi
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: keelson's Apply entry listed before an Update-held manager is called its own Apply entry" {
    # "keelson" sorts before "kustomize-controller", so the next manager's
    # using follows keelson's fields: only a using straight after its name
    # makes it an Update entry.
    install_mimic_kubectl
    image_applier keelson
    add_entry kustomize-controller Update
    apply_409 'Apply failed with 2 conflicts: conflicts with "keelson":
- .spec.replicas
conflicts with "kustomize-controller" using apps/v1:
- .spec.template.spec.containers[name="main"].image' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past Update entries of 'kustomize-controller' and keelson's own Apply entry, for image"* ]]
    [[ "$output" != *"Update entries of 'keelson'"* ]]
}

@test "update_apply: an owned metadata {} beside other gone fields under a missing metadata is mimicked" {
    # A chart renders jobTemplate.metadata {annotations: {}, creationTimestamp:
    # null}; the server stores no jobTemplate.metadata at all.
    install_mimic_kubectl
    local fs='{"f:spec":{"f:jobTemplate":{"f:metadata":{"f:annotations":{},"f:creationTimestamp":{}},"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"job\"}":{".":{},"f:name":{},"f:image":{}}}}}}}}}'
    FS=$fs yq -n -o=json -I0 '{"apiVersion":"batch/v1","kind":"CronJob","metadata":{"name":"cron","namespace":"default","resourceVersion":"5","managedFields":[{"manager":"argocd-application-controller","operation":"Apply","apiVersion":"batch/v1","time":"2026-04-01T10:00:00Z","fieldsV1":(strenv(FS) | from_json)}]},"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"job","image":"ghcr.io/x/y:1.2.3"}]}}}}}}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    # The dry run's answer: the owner's set without the field we left out.
    yq -p=json -o=json -I0 'del(.metadata.managedFields[0].fieldsV1["f:spec"]["f:jobTemplate"]["f:metadata"]["f:creationTimestamp"])' "$TMP_DIR/obj.json" >"$TMP_DIR/dry.json"
    run emit update_apply CronJob default cron containers job ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(yq -o=json -I0 '.spec.jobTemplate.metadata' "$TMP_DIR/apply.stdin")" = '{"annotations":{}}' ]
}

@test "update_apply: a forced mimic's failure is never called an ownership conflict" {
    local site
    for site in dry apply; do
        rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.* "$TMP_DIR"/mf.json "$TMP_DIR/obj.json"
        install_mimic_kubectl
        add_entry kubectl-client-side-apply Update
        apply_409 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
        case "$site" in
            dry) apply_409 'Apply failed with 1 conflict: conflict with "other" using apps/v1: .spec.paused' >"$TMP_DIR/dry.err.2" ;;
            apply) apply_409 'Apply failed with 1 conflict: conflict with "other" using apps/v1: .spec.paused' >"$TMP_DIR/apply.err.1" ;;
        esac
        KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 1 ] || { echo "$site: $output"; return 1; }
        [[ "$output" != *'"event":"update-apply-conflict"'* ]] || { echo "$site: $output"; return 1; }
        once '"event":"update-failed"'
    done
}

@test "update_apply: NotFound on the forced dry run is the workload gone" {
    install_mimic_kubectl
    add_entry kubectl-client-side-apply Update
    apply_409 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    echo 'Error from server (NotFound): deployments.apps "app" not found' >"$TMP_DIR/dry.err.2"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 3 ]
    once '"event":"update-workload-gone"'
    [[ "$output" != *'"level":"ERROR"'* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: a conflict naming nobody readable is refused, not forced" {
    install_mimic_kubectl
    add_entry kubectl-client-side-apply Update
    apply_409 'Apply failed with 1 conflict: .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: a manager whose only Apply entry is a subresource's is not a second applier" {
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields += [{"manager":"scaler","operation":"Apply","subresource":"scale","time":"2026-03-01T10:00:00Z","fieldsV1":{"f:spec":{"f:replicas":{}}}}]' "$TMP_DIR/obj.json"
    apply_409 'Apply failed with 1 conflict: conflict with "scaler" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past Update entries of 'scaler'"* ]]
}

@test "update_apply: one refusal's advice does not reach the next conflict line" {
    install_mimic_kubectl
    add_entry flux Apply
    apply_409 'Apply failed with 1 conflict: conflict with "flux" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 2>"$TMP_DIR/first.log" || true
    grep -q "two managers apply this workload" "$TMP_DIR/first.log"
    # Next: a clean dry run, then the real apply conflicts.
    rm -f "$TMP_DIR"/dry.* "$TMP_DIR"/apply.* "$TMP_DIR"/mf.json "$TMP_DIR/obj.json"
    install_mimic_kubectl
    apply_409 'Apply failed with 1 conflict: conflict with "helm" using apps/v1: .spec.paused' >"$TMP_DIR/apply.err.1"
    update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3 2>"$TMP_DIR/second.log" || true
    grep -q "conflict with 'helm'" "$TMP_DIR/second.log"
    if grep -q "two managers apply this workload" "$TMP_DIR/second.log"; then false; fi
}

@test "update_apply: a refused conflict naming the owner itself says it is an Update entry" {
    install_mimic_kubectl
    add_entry flux Apply
    apply_409 'Apply failed with 2 conflicts: conflicts with "argocd-application-controller" using apps/v1:
- .spec.replicas
conflicts with "flux":
- .spec.paused' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"(an Update entry under its own name)"* ]]
}

@test "update_apply: a webhook denial quoting kubectl's conflict text is not an ownership conflict" {
    install_mimic_kubectl
    add_entry flux Apply
    echo 'Error from server: admission webhook "policy" denied the request: Apply failed with 1 conflict: conflict with "x": .spec.replicas' >"$TMP_DIR/dry.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    once '"event":"update-failed"'
    [[ "$output" != *'"event":"update-apply-conflict"'* ]]
    if grep -q -- "--force-conflicts" "$TMP_DIR/kubectl.log"; then false; fi
}

@test "update_apply: a webhook denial quoting a conflict is not force-planned" {
    install_mimic_kubectl
    add_entry kubectl-client-side-apply Update
    echo 'Error from server: admission webhook "policy" denied the request: conflict with "kubectl-client-side-apply" over the freeze window' >"$TMP_DIR/dry.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    once '"event":"update-failed"'
}

@test "update_apply: a webhook denial quoting a parseable conflict is not forced" {
    # helm holds only an Update entry and the text names it as kubectl
    # would, so only the missing "error: Apply failed with" line keeps
    # this from being forced past.
    install_mimic_kubectl
    add_entry helm Update
    echo 'Error from server: admission webhook "policy" denied the request: conflict with "helm" using apps/v1: .spec.template.spec.containers[name="main"].image' >"$TMP_DIR/dry.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    once '"event":"update-failed"'
    [ "$(cat "$TMP_DIR/dry.count")" -eq 1 ]
    if grep -q -- "--force-conflicts" "$TMP_DIR/kubectl.log"; then false; fi
    [ ! -e "$TMP_DIR/apply.stdin" ]
}

# --- round twenty-eight ---

@test "update_apply: a conflict line shows Go-quoted manager names decoded" {
    install_mimic_kubectl
    add_entry 'a"b' Apply
    add_entry 'x\' Apply
    printf '%s
' 'error: Apply failed with 2 conflicts: conflicts with "a\"b" using apps/v1: .spec.replicas' 'conflict with "x\\" using apps/v1: .spec.paused' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    # A backslash in a name is shown doubled, so it cannot pass for an escape.
    [[ "$output" == *"conflict with 'a\"b', 'x\\\\'; refusing to force"* ]] || { echo "$output"; return 1; }
}

@test "update_apply: a conflict line falls back to kubectl's printing, and says so, when names cannot be read" {
    install_mimic_kubectl
    add_entry flux Apply
    apply_409 'Apply failed with 1 conflict: conflict with "a\x41" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict with 'a\\x41' (names as kubectl printed them)"* ]] || { echo "$output"; return 1; }
}

@test "update_apply: an owner named with a quote still gets its own-name note" {
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields[0].manager = "argo\"cd"' "$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    add_entry flux Apply
    printf '%s
' 'error: Apply failed with 2 conflicts: conflicts with "argo\"cd" using apps/v1: .spec.replicas' 'conflict with "flux" using apps/v1: .spec.paused' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict with 'argo\"cd', 'flux' (an Update entry under its own name)"* ]] || { echo "$output"; return 1; }
}

@test "update_apply: an owner named with a backslash still gets its own-name note" {
    # Shown escaped as argo\\cd: the note must compare the name itself.
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields[0].manager = "argo\\cd"' "$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    add_entry flux Apply
    printf '%s\n' 'error: Apply failed with 2 conflicts: conflicts with "argo\\cd" using apps/v1: .spec.replicas' 'conflict with "flux" using apps/v1: .spec.paused' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict with 'argo\\\\cd', 'flux' (an Update entry under its own name)"* ]] || { echo "$output"; return 1; }
}

@test "conflict_names: an unterminated or empty quoted name makes the list unreadable" {
    update_conflict_names 'Apply failed with 1 conflict: conflict with "abc'
    [ "${#UPDATE_CONFLICT_NAMES[@]}" -eq 0 ]
    update_conflict_names 'Apply failed with 1 conflict: conflict with "" using apps/v1: .spec.replicas'
    [ "${#UPDATE_CONFLICT_NAMES[@]}" -eq 0 ]
}

@test "update_apply: keelson holding only Update entries is forced past as an Update entry" {
    install_mimic_kubectl
    add_entry keelson Update
    apply_409 'Apply failed with 1 conflict: conflict with "keelson" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past Update entries of 'keelson'"* ]]
    [[ "$output" != *"keelson's own Apply entry"* ]]
}

# A complaint over several lines and longer than the clip.
long_multiline() {
    printf 'error: first line\n'
    long_complaint
}

@test "update_trigger_cronjob: a failed trigger's line carries the clipped reason, not the whole complaint" {
    long_multiline >"$TMP_DIR/trig.err"
    install_shim kubectl <<SH
#!/usr/bin/env bash
cat "$TMP_DIR/trig.err" >&2
exit 1
SH
    KEELSON_LOG_FORMAT=json run emit update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n
    [ "$status" -eq 1 ]
    once '"event":"cronjob-job-trigger-failed"'
    if grep -F '"event":"cronjob-job-trigger-failed"' <<<"$output" | grep -q END-OF-COMPLAINT; then false; fi
    grep -F '"event":"cronjob-job-trigger-failed"' <<<"$output" | grep -q '"reason":"error: first line'
}

@test "update_apply: a failed server-side apply's line carries the clipped reason, not the whole complaint" {
    install_mimic_kubectl
    long_multiline >"$TMP_DIR/apply.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-failed"'
    if grep -F '"event":"update-failed"' <<<"$output" | grep -q END-OF-COMPLAINT; then false; fi
    grep -F '"event":"update-failed"' <<<"$output" | grep -q '"reason":"error: first line'
}

# --- round twenty-nine ---

@test "update_apply: the force note keeps a manager name holding ;" {
    install_mimic_kubectl
    add_entry 'a;b' Update
    apply_409 'Apply failed with 1 conflict: conflict with "a;b" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past Update entries of 'a;b'"* ]]
}

@test "update_apply: the force note joins several parts with and" {
    install_mimic_kubectl
    add_entry helmish Update
    add_entry argocd-application-controller Update
    apply_409 'Apply failed with 2 conflicts: conflicts with "helmish" using apps/v1: .spec.replicas, conflict with "argocd-application-controller" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past Update entries of 'helmish' and its own Update entry"* ]]
}

@test "update_apply: a webhook quoting NotFound or a stale read is neither gone nor stale" {
    # Gone: the workload is not skipped as deleted.
    install_mimic_kubectl
    echo 'Error from server (Forbidden): admission webhook "guard" denied the request: image ref (NotFound) in policy' >"$TMP_DIR/apply.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" != *'"event":"update-workload-gone"'* ]]
    # Stale: not retried as a moved object.
    rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.*
    install_mimic_kubectl
    echo 'Error from server (Forbidden): admission webhook "guard" denied the request: the object has been modified by policy' >"$TMP_DIR/apply.err.1"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
}

@test "update_is_gone and update_is_stale: only kubectl's own server-error line counts" {
    update_is_gone 'Error from server (NotFound): deployments.apps "app" not found' Deployment default app
    update_is_gone $'warning: x\nError from server (NotFound): deployments.apps "app" not found' Deployment default app
    if update_is_gone 'Error from server (Forbidden): denied: (NotFound)' Deployment default app; then false; fi
    update_is_gone 'Error from server (Conflict): Operation cannot be fulfilled on deployments.apps "app": uid mismatch: the provided object specified uid u, and no existing object was found' Deployment default app
    if update_is_gone 'Error from server (Forbidden): uid mismatch ... no existing object was found' Deployment default app; then false; fi
    # Only this object's own NotFound, or its namespace's, and the whole line:
    # a webhook may deny with reason NotFound, and kubectl prints it alike.
    update_is_gone 'Error from server (NotFound): namespaces "default" not found' Deployment default app
    update_is_gone 'Error from server (NotFound): cronjobs.batch "nightly" not found' CronJob batch nightly
    update_is_gone 'Error from server (NotFound): rollouts.argoproj.io "app" not found' Rollout default app
    if update_is_gone 'Error from server (NotFound): admission webhook "guard" denied the request: deployments.apps "app" not found' Deployment default app; then false; fi
    if update_is_gone 'Error from server (NotFound): deployments.apps "other" not found' Deployment default app; then false; fi
    if update_is_gone 'Error from server (NotFound): statefulsets.apps "app" not found' Deployment default app; then false; fi
    if update_is_gone 'Error from server (NotFound): namespaces "other" not found' Deployment default app; then false; fi
    if update_is_gone 'Error from server (NotFound): deployments.apps "app" not found; and more' Deployment default app; then false; fi
    if update_is_gone 'Error from server (Conflict): Operation cannot be fulfilled on deployments.apps "other": uid mismatch: the provided object specified uid u, and no existing object was found' Deployment default app; then false; fi
    update_is_stale 'Error from server (Conflict): Operation cannot be fulfilled on deployments.apps "app": the object has been modified; please apply your changes to the latest version and try again'
    if update_is_stale 'Error from server (Forbidden): the object has been modified by policy'; then false; fi
}

@test "update_is_gone and update_is_stale: kubectl apply's own wording of a 409 counts" {
    # apply --server-side wraps a 409 as "error: ..." and adds its speech.
    update_is_stale "$(apply_409 "$STALE_MSG")"
    if update_is_gone "$(apply_409 "$STALE_MSG")" Deployment default app; then false; fi
    update_is_gone "$(apply_409 'Operation cannot be fulfilled on deployments.apps "app": uid mismatch: the provided object specified uid u, and no existing object was found')" Deployment default app
    if update_is_stale "$(apply_409 'Operation cannot be fulfilled on deployments.apps "app": uid mismatch: the provided object specified uid u, and no existing object was found')"; then false; fi
    # A NotFound from apply keeps the server-error form.
    update_is_gone 'Error from server (NotFound): deployments.apps "app" not found' Deployment default app
    # An ownership conflict is neither.
    local own
    own=$(printf 'error: Apply failed with 1 conflict: conflict with "helm" using apps/v1: .spec.replicas\n%s' "$KUBECTL_APPLY_SPEECH")
    if update_is_stale "$own"; then false; fi
    if update_is_gone "$own" Deployment default app; then false; fi
    # A webhook denial quoting both phrases, in either prefix, is neither.
    local hook='Error from server (Forbidden): admission webhook "guard" denied the request: error: Operation cannot be fulfilled on x: the object has been modified; uid mismatch, and no existing object was found'
    if update_is_stale "$hook"; then false; fi
    if update_is_gone "$hook" Deployment default app; then false; fi
    hook='error: admission webhook "guard" denied the request: Operation cannot be fulfilled on x: the object has been modified'
    if update_is_stale "$hook"; then false; fi
    # The phrase on a later line than kubectl's Conflict line does not count.
    if update_is_stale $'Error from server (Conflict): Operation cannot be fulfilled on x: something else\nthe object has been modified'; then false; fi
}

@test "update_is_gone: a uid refusal for an object that still exists is not gone" {
    # Re-created under the same name, on k3s v1.34.1 (2026-10-20): with the
    # read's resourceVersion every apply, dry run and patch is refused stale;
    # forced without it, the uid is immutable (a 422). Neither is gone.
    local immutable='The Deployment "app" is invalid: metadata.uid: Invalid value: "uid-1": field is immutable'
    if update_is_gone "$immutable" Deployment default app; then false; fi
    if update_is_stale "$immutable"; then false; fi
    update_is_stale "$(apply_409 "$STALE_MSG")"
    if update_is_gone "$(apply_409 "$STALE_MSG")" Deployment default app; then false; fi
    # A uid mismatch that does not say no object was found (not seen from
    # apply or patch) names one that exists, in either form.
    local other='Operation cannot be fulfilled on deployments.apps "app": uid mismatch: the provided object specified uid uid-1, and the existing object has uid uid-2'
    if update_is_gone "$(apply_409 "$other")" Deployment default app; then false; fi
    if update_is_gone "Error from server (Conflict): $other" Deployment default app; then false; fi
}

@test "update_apply: a uid refused as immutable is an error, not the workload gone" {
    install_mimic_kubectl
    echo 'The Deployment "app" is invalid: metadata.uid: Invalid value: "uid-1": field is immutable' >"$TMP_DIR/apply.err.1"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    one_error
    once '"event":"update-failed"'
    [[ "$output" != *'"event":"update-workload-gone"'* ]]
    [ "$(cat "$TMP_DIR/apply.count")" -eq 1 ]
}

@test "update_apply: a stale read on the forced dry run reads again and retries" {
    install_mimic_kubectl
    add_entry kubectl-client-side-apply Update
    apply_409 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    apply_409 "$STALE_MSG" >"$TMP_DIR/dry.err.2"
    apply_409 'Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.3"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/dry.count")" -eq 4 ]
    [[ "$output" == *"forced past Update entries of 'kubectl-client-side-apply'"* ]]
}

@test "update_apply: a manager name with a line break never splits a plain log line" {
    install_mimic_kubectl
    add_entry flux Apply
    apply_409 'Apply failed with 1 conflict: conflict with "a\nb": .spec.replicas, conflict with "flux": .spec.paused' >"$TMP_DIR/dry.err.1"
    KEELSON_LOG_FORMAT=plain run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    local line
    line=$(grep -F "conflict with" <<<"$output")
    [ "$(grep -c "" <<<"$line")" -eq 1 ]
    [[ "$line" == *"'a\\nb'"* ]]
    [[ "$line" != *"(names as kubectl printed them)"* ]]
    # The force note as well.
    rm -f "$TMP_DIR"/apply.* "$TMP_DIR"/dry.* "$TMP_DIR/obj.json"
    install_mimic_kubectl
    add_entry $'x\ty' Update
    apply_409 'Apply failed with 1 conflict: conflict with "x\ty" using apps/v1: .spec.replicas' >"$TMP_DIR/dry.err.1"
    KEELSON_LOG_FORMAT=plain run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"forced past Update entries of 'x\\ty'"* ]]
}

@test "update_apply: a list the owner held whole, now recorded key by key, is refused saying so" {
    # A pre-1.9 Rollout's owner entry holds containers whole; after the CRD
    # moved to keyed containers the dry run records them field by field.
    install_mimic_kubectl
    printf '%s' '{"apiVersion":"argoproj.io/v1alpha1","kind":"Rollout","metadata":{"name":"app","namespace":"default","resourceVersion":"41","managedFields":[{"manager":"argocd-application-controller","operation":"Apply","apiVersion":"argoproj.io/v1alpha1","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:replicas":{},"f:template":{"f:spec":{"f:containers":{}}}}}}]},"spec":{"replicas":3,"template":{"spec":{"containers":[{"name":"sidecar","image":"ghcr.io/x/side:9"},{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"] = {"k:{\"name\":\"sidecar\"}": {".": {}, "f:name": {}, "f:image": {}}, "k:{\"name\":\"main\"}": {".": {}, "f:name": {}, "f:image": {}}}' "$TMP_DIR/obj.json" >"$TMP_DIR/dry.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-mimic-refused"'
    [[ "$output" == *"'argocd-application-controller' recorded spec.template.spec.containers whole, and the server now records it field by field"*"a fresh apply by the owner (an Argo CD sync) clears this, or use claim-patch. Nothing was written."* ]]
    [[ "$output" != *"a dry run showed the write would change"* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: a client-side applier named with a line break keeps the refusal on one plain line" {
    install_mimic_kubectl
    yq -i -p=json -o=json -I0 '.metadata.managedFields += [{"manager": "evil\nINJECTED 2026 ERROR fake", "operation": "Update", "fieldsV1": {"f:metadata": {"f:annotations": {"f:kubectl.kubernetes.io/last-applied-configuration": {}}}}}]' "$TMP_DIR/obj.json"
    run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    [ "$(grep -c . <<<"$output")" -eq 1 ]
    [[ "$output" == *"an Update entry of 'evil\\nINJECTED 2026 ERROR fake' owns kubectl's last-applied-configuration"* ]]
}

@test "update_apply: a list the owner held whole is named even when its set is too big for one environment string" {
    # 128 KiB is Linux's cap on one; past it the reshape check never ran
    # and the refusal fell back to the plain guard wording.
    install_mimic_kubectl
    # One owned annotation whose key alone is over 128 KiB: a server caps
    # keys far shorter, and a set that big holds hundreds of fields, which
    # the projection takes minutes over in a test. The size is the point.
    head -c 140000 /dev/zero | tr '\0' 'a' >"$TMP_DIR/big.txt"
    printf '%s' '{"apiVersion":"argoproj.io/v1alpha1","kind":"Rollout","metadata":{"name":"app","namespace":"default","resourceVersion":"41","managedFields":[{"manager":"argocd-application-controller","operation":"Apply","apiVersion":"argoproj.io/v1alpha1","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:replicas":{},"f:template":{"f:spec":{"f:containers":{}}}}}}]},"spec":{"replicas":3,"template":{"spec":{"containers":[{"name":"sidecar","image":"ghcr.io/x/side:9"},{"name":"main","image":"ghcr.io/x/y:1.2.3"}]}}}}' >"$TMP_DIR/small.json"
    yq -p=json -o=json -I0 'load_str("'"$TMP_DIR"'/big.txt") as $k
        | .metadata.annotations[$k] = "v"
        | .metadata.managedFields[0].fieldsV1["f:metadata"]["f:annotations"]["f:" + $k] = {}' "$TMP_DIR/small.json" >"$TMP_DIR/obj.json"
    [ "$(yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1' "$TMP_DIR/obj.json" | wc -c)" -gt 131072 ]
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"] = {"k:{\"name\":\"sidecar\"}": {".": {}, "f:name": {}, "f:image": {}}, "k:{\"name\":\"main\"}": {".": {}, "f:name": {}, "f:image": {}}}' "$TMP_DIR/obj.json" >"$TMP_DIR/dry.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Rollout default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-mimic-refused"'
    [[ "$output" == *"'argocd-application-controller' recorded spec.template.spec.containers whole, and the server now records it field by field"* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

@test "update_apply: mimic sends the owner's {} at a container's resources and securityContext and the pod's, not a webhook's values" {
    # As a Helm chart renders them, the owner applies {} at each; a
    # mutating webhook (an Update entry here) fills them in. A copy of the
    # live values would hand the owner the webhook's fields.
    install_mimic_kubectl
    printf '%s' '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"app","namespace":"default","resourceVersion":"41","managedFields":[{"manager":"argocd-application-controller","operation":"Apply","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:securityContext":{},"f:containers":{"k:{\"name\":\"main\"}":{".":{},"f:name":{},"f:image":{},"f:resources":{},"f:securityContext":{}}}}}}}},{"manager":"kyverno","operation":"Update","time":"2026-04-01T10:00:01Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:securityContext":{"f:fsGroup":{}},"f:containers":{"k:{\"name\":\"main\"}":{"f:resources":{"f:limits":{"f:cpu":{}}},"f:securityContext":{"f:runAsNonRoot":{}}}}}}}}}]},"spec":{"template":{"spec":{"securityContext":{"fsGroup":2000},"containers":[{"name":"sidecar","image":"ghcr.io/x/side:9"},{"name":"main","image":"ghcr.io/x/y:1.2.3","resources":{"limits":{"cpu":"200m"}},"securityContext":{"runAsNonRoot":true}}]}}}}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 0 ]
    once '"event":"update-applied"'
    [ "$(yq -p=json -o=json -I0 '.spec | sort_keys(..)' "$TMP_DIR/apply.stdin")" = '{"template":{"spec":{"containers":[{"image":"ghcr.io/x/y:1.2.4","name":"main","resources":{},"securityContext":{}}],"securityContext":{}}}}' ]
    # What the dry run was shown is what was written.
    [ "$(cat "$TMP_DIR/dry.stdin")" = "$(cat "$TMP_DIR/apply.stdin")" ]
}

@test "update_apply: an owned {} that comes back with fields elsewhere keeps the plain guard wording" {
    # strategy: {} copied with the server's defaults is recorded field by
    # field; no schema change, and no fresh apply by the owner clears it.
    install_mimic_kubectl
    mimic_obj | yq -p=json -o=json -I0 '.spec.strategy = {"type": "RollingUpdate"} | .metadata.managedFields[0].fieldsV1["f:spec"]["f:strategy"] = {}' >"$TMP_DIR/obj.json"
    mf_of <"$TMP_DIR/obj.json" >"$TMP_DIR/mf.json"
    yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1["f:spec"]["f:strategy"] = {"f:type": {}}' "$TMP_DIR/obj.json" >"$TMP_DIR/dry.json"
    KEELSON_LOG_FORMAT=json run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    once '"event":"update-mimic-refused"'
    [[ "$output" == *"a dry run showed the write would change what 'argocd-application-controller' owns"* ]]
    [[ "$output" != *"records it field by field"* ]]
    if [ -e "$TMP_DIR/apply.stdin" ]; then false; fi
}

# --- kubectl's multi-line complaints stay one line per event ---

# A complaint over two lines, each with a marker.
two_line_complaint() {
    printf 'error: FIRST-LINE\nSECOND-LINE\n'
}

# lines_are_events: every line of plain $output opens with a timestamp and a
# level, so a complaint's newline let through starts a line that does not;
# and the complaint's second line is there, so it was flattened, not lost.
lines_are_events() {
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ (DEBUG|INFO|WARN|ERROR)\  ]] \
            || { echo "not an event line: $line"; return 1; }
    done <<<"$output"
    grep -q 'FIRST-LINE SECOND-LINE' <<<"$output" || { echo "complaint not flattened: $output"; return 1; }
}

@test "update_apply: a failed ownership read's multi-line complaint stays on one line" {
    two_line_complaint >"$TMP_DIR/read.err"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$*" in
    get*jsonpath-as-json*) cat "$TMP_DIR/read.err" >&2; exit 1 ;;
esac
SH
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=plain run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    at_level ERROR 'Could not read who owns the image'
    lines_are_events
}

@test "update_apply: a failed object read's multi-line complaint stays on one line in each write path" {
    local strategy expect
    two_line_complaint >"$TMP_DIR/read.err"
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
case "$*" in
    get*jsonpath-as-json*) cat "$TMP_DIR/mf.json" ;;
    get*) cat "$TMP_DIR/read.err" >&2; exit 1 ;;
esac
SH
    for strategy in claim-patch claim-apply mimic; do
        case "$strategy" in
            claim-patch) expect='to patch it: error: FIRST-LINE SECOND-LINE' ;;
            *) expect='could not read it: error: FIRST-LINE SECOND-LINE' ;;
        esac
        KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=$strategy \
        KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=plain run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
        [ "$status" -eq 1 ]
        at_level ERROR "$expect" || { echo "$strategy"; return 1; }
        lines_are_events
    done
}

@test "update_apply: a refused patch's multi-line complaint stays on one line" {
    local n
    printf '%s' "$(mf_apply_argocd)" >"$TMP_DIR/mf.json"
    install_patch_kubectl
    for n in 1 2 3; do two_line_complaint >"$TMP_DIR/patch.err.$n"; done
    KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch \
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=plain run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    at_level DEBUG 'failed, full output: error: FIRST-LINE SECOND-LINE'
    lines_are_events
}

@test "update_apply: a refused server-side apply's multi-line complaint stays on one line" {
    install_mimic_kubectl
    two_line_complaint >"$TMP_DIR/apply.err.1"
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=plain run emit update_apply Deployment default app containers main ghcr.io/x/y:1.2.4 1.2.3
    [ "$status" -eq 1 ]
    at_level DEBUG 'failed, full output: error: FIRST-LINE SECOND-LINE'
    lines_are_events
}

@test "update_trigger_cronjob: a failed trigger's multi-line complaint stays on one line" {
    two_line_complaint >"$TMP_DIR/trig.err"
    install_shim kubectl <<'SH'
#!/usr/bin/env bash
cat "$TMP_DIR/trig.err" >&2
exit 1
SH
    KEELSON_LOG_LEVEL=DEBUG KEELSON_LOG_FORMAT=plain run emit update_trigger_cronjob batch nightly 1.4.2 1.4.3 ghcr.io/acme/n
    [ "$status" -eq 1 ]
    at_level DEBUG 'failed, full output: error: FIRST-LINE SECOND-LINE'
    lines_are_events
}
