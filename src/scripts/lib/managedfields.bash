# managedFields owner detection for Keelson.
# Sourced; not directly executable.
#
# When patching a workload's container image, Keelson must mimic the field
# manager that already owns the image field - otherwise a GitOps tool that
# created the workload will either fight us back to the old tag (Update
# ownership) or refuse to reconcile (Apply ownership / SSA conflict).
#
# managedFields entries look like:
#   { "manager": "argocd-application-controller",
#     "operation": "Apply",
#     "fieldsV1": { "f:spec": { "f:template": { ... f:containers:
#                  { "k:{\"name\":\"main\"}": { "f:image": {} } } } } } }
#
# CronJob's wrapper path nests through f:jobTemplate instead of going
# straight into f:template. We try both well-known paths via yq's
# alternative operator (//) and accept whichever resolves.

# managedfields_owner_of_image <managed-fields-json-array> <container>
# Echoes "<manager> <operation>" for the manager that owns the named
# container's image field, or nothing if no entry claims it.
managedfields_owner_of_image() {
    local mf_json=$1 container=$2
    [ -z "$mf_json" ] && return 0
    local count i entry hit manager operation
    count=$(printf '%s' "$mf_json" | yq -p=json 'length // 0' 2>/dev/null)
    if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" -eq 0 ]; then
        return 0
    fi
    local p1='.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"]["k:{\"name\":\"'"$container"'\"}"]["f:image"]'
    local p2='.fieldsV1["f:spec"]["f:jobTemplate"]["f:spec"]["f:template"]["f:spec"]["f:containers"]["k:{\"name\":\"'"$container"'\"}"]["f:image"]'
    local expr="($p1) // ($p2)"
    for ((i=0; i<count; i++)); do
        entry=$(printf '%s' "$mf_json" | yq -p=json -o=json ".[$i]" 2>/dev/null)
        hit=$(printf '%s' "$entry" | yq -p=json -o=json "$expr" 2>/dev/null)
        if [ -n "$hit" ] && [ "$hit" != "null" ]; then
            manager=$(printf '%s' "$entry" | yq -p=json '.manager')
            operation=$(printf '%s' "$entry" | yq -p=json '.operation')
            printf '%s %s' "$manager" "$operation"
            return 0
        fi
    done
}
