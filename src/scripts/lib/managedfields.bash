# managedFields owner detection for Keelson.
# Sourced; not directly executable.
#
# When updating a workload's container image, Keelson needs to know whether
# a server-side-apply (Apply-op) manager already claims the image field.
# Only Apply-op ownership matters for the SSA-conflict question: Update-op
# entries do not participate in SSA conflict resolution and are treated the
# same as "no owner" by the strategy dispatcher in update.bash.
#
# managedFields entries look like:
#   { "manager": "argocd-application-controller",
#     "operation": "Apply",
#     "time": "2026-04-01T10:00:00Z",
#     "fieldsV1": { "f:spec": { "f:template": { ... f:containers:
#                  { "k:{\"name\":\"main\"}": { "f:image": {} } } } } } }
#
# CronJob's wrapper path nests through f:jobTemplate instead of going
# straight into f:template. We try both well-known paths via yq's
# alternative operator (//) and accept whichever resolves.

# managedfields_apply_owner_of_image <managed-fields-json-array> <list>
#                                    <container>
# Echoes the manager name of the most-recent Apply-op entry that owns the
# named container's image field, or empty if none. Multiple Apply owners
# on the same field are rare but possible; the tie-breaker is .time
# descending, then array-order last.
#
# <list> is "containers" or "initContainers", and it has to be right: an init
# container's ownership lives under f:initContainers, so looking in the wrong
# array finds no owner and the mimic strategy refuses the update.
managedfields_apply_owner_of_image() {
    local mf_json=$1 clist=${2:-containers} container=$3
    [ -z "$mf_json" ] && return 0
    local count i entry hit op manager t
    count=$(printf '%s' "$mf_json" | yq -p=json 'length // 0' 2>/dev/null)
    if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" -eq 0 ]; then
        return 0
    fi
    local p1='.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:'"$clist"'"]["k:{\"name\":\"'"$container"'\"}"]["f:image"]'
    local p2='.fieldsV1["f:spec"]["f:jobTemplate"]["f:spec"]["f:template"]["f:spec"]["f:'"$clist"'"]["k:{\"name\":\"'"$container"'\"}"]["f:image"]'
    local expr="($p1) // ($p2)"
    local best_manager="" best_time=""
    for ((i=0; i<count; i++)); do
        entry=$(printf '%s' "$mf_json" | yq -p=json -o=json ".[$i]" 2>/dev/null)
        op=$(printf '%s' "$entry" | yq -p=json '.operation' 2>/dev/null)
        [ "$op" = "Apply" ] || continue
        hit=$(printf '%s' "$entry" | yq -p=json -o=json "$expr" 2>/dev/null)
        if [ -z "$hit" ] || [ "$hit" = "null" ]; then
            continue
        fi
        manager=$(printf '%s' "$entry" | yq -p=json '.manager' 2>/dev/null)
        t=$(printf '%s' "$entry" | yq -p=json '.time // ""' 2>/dev/null)
        if [ -z "$best_manager" ] || [[ "$t" > "$best_time" ]]; then
            best_manager=$manager
            best_time=$t
        fi
    done
    if [ -n "$best_manager" ]; then
        printf '%s' "$best_manager"
    fi
    return 0
}
