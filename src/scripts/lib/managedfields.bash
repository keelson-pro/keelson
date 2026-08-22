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
# descending, and on equal times the earlier entry in the array keeps it.
#
# <list> is "containers" or "initContainers", and it has to be right: an init
# container's ownership lives under f:initContainers, so looking in the wrong
# array finds no owner and the mimic strategy refuses the update.
# One yq, not four per entry. The filtering is all expressible in the
# expression, so what comes back is only the entries that already qualify:
# Apply-op, owning this container's image, one "<time>|<manager>" per line in
# array order. Picking the winner stays in bash because the rule is not
# "latest" alone -- an entry with no time must still be able to win when it is
# the only one.
managedfields_apply_owner_of_image() {
    local mf_json=$1 clist=${2:-containers} container=$3
    [ -z "$mf_json" ] && return 0

    local key='["k:{\"name\":\"'"$container"'\"}"]["f:image"]'
    local p1='.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:'"$clist"'"]'"$key"
    local p2='.fieldsV1["f:spec"]["f:jobTemplate"]["f:spec"]["f:template"]["f:spec"]["f:'"$clist"'"]'"$key"

    local candidates
    candidates=$(printf '%s' "$mf_json" | yq -p=json -o=y -r \
        ".[] | select(.operation == \"Apply\")
             | select(((${p1}) // (${p2})) != null)
             | (.time // \"\") + \"|\" + (.manager // \"\")" 2>/dev/null)

    local rest=$candidates line t manager best_manager="" best_time=""
    while [ -n "$rest" ]; do
        line=${rest%%$'\n'*}
        if [ "$line" = "$rest" ]; then
            rest=
        else
            rest=${rest#*$'\n'}
        fi
        [ -n "$line" ] || continue
        t=${line%%|*}
        manager=${line#*|}
        [ -n "$manager" ] || continue
        # Strictly greater, so equal timestamps keep the earlier entry.
        if [ -z "$best_manager" ] || [[ $t > $best_time ]]; then
            best_manager=$manager
            best_time=$t
        fi
    done
    if [ -n "$best_manager" ]; then
        printf '%s' "$best_manager"
    fi
    return 0
}
