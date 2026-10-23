# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# managedFields owner detection for Keelson.
# Sourced; not directly executable.
#
# When updating a workload's container image, Keelson needs to know who owns
# the image field and how: through an Apply (server-side apply) or an Update
# (anything else: a patch, an edit, client-side apply, Helm). Both kinds take
# part in conflicts: an apply that changes a field another manager holds is
# refused unless forced, whichever operation put it there. The strategy
# dispatcher in update.bash picks its write from the owner's operation.
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

# managedfields_image_owned_expr <list> <container>  -> MANAGEDFIELDS_OWNED_EXPR
# The yq condition, on one managedFields entry, that it owns <container>'s
# image in <list>: managedfields_image_owner's rule, shared with
# managedfields_image_appliers.
declare -g MANAGEDFIELDS_OWNED_EXPR=""
managedfields_image_owned_expr() {
    local clist=$1 container=$2
    # An image volume is not in a container list and holds its reference a
    # level deeper, so both the list name and the leaf differ.
    local field='["f:image"]'
    if [ "$clist" = "imageVolumes" ]; then
        clist=volumes
        field='["f:image"]["f:reference"]'
    fi
    # Owned is the image's own leaf, or any node above it held whole as a
    # bare {} leaf: a custom resource whose list is atomic (Argo Rollouts
    # before v1.9 declares containers with no list type) records only
    # f:containers, and its owner owns every image in it. Every prefix of
    # both pod paths is asked; none of them is ever {} on a built-in kind.
    local seg segs=() prefix owned=""
    local key='["k:{\"name\":\"'"$container"'\"}"]'
    local path
    for path in '["f:spec"]["f:template"]["f:spec"]' '["f:spec"]["f:jobTemplate"]["f:spec"]["f:template"]["f:spec"]'; do
        path+='["f:'"$clist"'"]'"$key$field"
        prefix=.fieldsV1
        segs=()
        while [[ $path =~ ^(\[\"([^\"\\]|\\.)*\"\]) ]]; do
            seg=${BASH_REMATCH[1]}
            path=${path#"$seg"}
            prefix+=$seg
            segs+=("$prefix")
        done
        for seg in "${segs[@]}"; do
            owned+="${owned:+ or }((${seg} | tag) == \"!!map\" and (${seg} | length) == 0)"
        done
    done

    MANAGEDFIELDS_OWNED_EXPR=$owned
}

# managedfields_image_owner <managed-fields-json-array> <list> <container>
#   -> MANAGEDFIELDS_OWNER, MANAGEDFIELDS_OWNER_OPERATION
# Who owns the named container's image field, and by which operation (Apply
# or Update), for the object itself: subresource entries are skipped. Both
# are empty when nobody does, which in practice means managedFields were
# stripped. Returns 1 when the managedFields could not be read at all.
#
# Keelson's own entries aside (below), an Apply owner wins over an Update
# one. Both can hold a field, when an apply set it to the value an Update had
# already written, and then the Apply entry is the one whose next apply is at
# stake. Within the winning rank the latest .time wins, and on equal times
# the earlier entry in the array keeps it: two Apply managers co-own a field
# while they agree on its value.
# Any co-owner left out of the choice still holds the old value, so changing
# it conflicts with them on mimic's dry run: one that only holds Update
# entries (or keelson) is forced past, a second applier is refused.
#
# Keelson's own entries (from a claim) rank below any other manager's, Apply
# or Update: keelson owns the image only when nobody else does. Picked by
# time alongside another applier, mimic would run as keelson and refuse that
# applier on every poll. Below an Update owner too: the image is then
# update-owned, and mimic's patch as that owner takes it from keelson's
# Apply entry, as any Update does.
#
# <list> is "containers", "initContainers" or "imageVolumes", and it has to be
# right: an init container's ownership lives under f:initContainers, so
# looking in the wrong array finds no owner.
#
# One yq, not four per entry. What comes back is only the entries that
# already qualify, one "<operation>|<time>|<manager>" per line in array order.
# Picking the winner stays in bash because the rule is not "latest" alone: an
# entry with no time must still be able to win when it is the only one.
declare -g MANAGEDFIELDS_OWNER="" MANAGEDFIELDS_OWNER_OPERATION=""
managedfields_image_owner() {
    local mf_json=$1 clist=${2:-containers} container=$3
    MANAGEDFIELDS_OWNER=""
    MANAGEDFIELDS_OWNER_OPERATION=""
    [ -z "$mf_json" ] && return 0
    # The name is pasted into the k: key as written, without Go's escaping
    # of < > &, control characters and U+2028/2029, or JSON's of " and \,
    # and the writes find it with yq's ==, which reads * and ? as a
    # pattern: such a name (only a loosely validated custom resource can
    # hold one) would read as unowned and be claimed, or match a second
    # container.
    case "$container" in
        *[\"\\\<\>\&\*\?]* | *[[:cntrl:]]* | *$'\xe2\x80\xa8'* | *$'\xe2\x80\xa9'*) return 1 ;;
    esac

    managedfields_image_owned_expr "$clist" "$container"
    local owned=$MANAGEDFIELDS_OWNED_EXPR

    # A failed read is not "nobody owns it": returns 1, so the caller can
    # refuse rather than claim an image that has an owner.
    local candidates
    candidates=$(printf '%s' "$mf_json" | yq -p=json -o=y -r \
        "((select(tag == \"!!seq\")) // error(\"managedFields is not a list\"))
         | [.[] | select(.operation == \"Apply\" or .operation == \"Update\")
             | select((.subresource // \"\") == \"\")
             | select(${owned})] as \$c
         | (([\$c[] | select(((.manager // \"\") | (test(\"[\\x{0000}\\n\\r]\") or . == \"\"))
                or ((.time // \"\") | tostring | test(\"[\\x{0000}\\n\\r|]\")))] | length) as \$odd
            | (select(\$odd == 0)) // error(\"an owner's manager name is empty or holds a NUL or a line break, or its time holds one or a |\"))
         | \$c[] | .operation + \"|\" + (.time // \"\") + \"|\" + (.manager // \"\")" 2>/dev/null) || return 1

    # Split by expansion, not read's IFS: read drops a trailing "|" from its
    # last field, so a manager named "argo|" would come back as "argo".
    # Operation and time hold no "|", so everything after the second is the
    # name, whole; only a line break, refused above, could pass for another
    # entry (a NUL, bash would drop), and only an owner's name is ever read. An empty one is refused
    # too: skipping it would hand the image to a lesser owner. A here-string,
    # not a pipe: the loop must run in this shell for the globals it sets to
    # survive. The empty line of no candidates at all is skipped.
    local line rest op t manager rank best_rank=0 best_time=""
    while IFS= read -r line; do
        op=${line%%|*}
        rest=${line#*|}
        t=${rest%%|*}
        manager=${rest#*|}
        [ -n "$manager" ] || continue
        rank=1
        [[ $op == Apply ]] && rank=2
        # Keelson's own entries rank below every other manager's, so mimic
        # runs as the real owner and never as keelson while one exists.
        [ "$manager" = keelson ] || rank=$((rank + 2))
        # Strictly greater, so equal timestamps keep the earlier entry.
        if (( rank > best_rank )) || { (( rank == best_rank )) && [[ $t > $best_time ]]; }; then
            MANAGEDFIELDS_OWNER=$manager
            MANAGEDFIELDS_OWNER_OPERATION=$op
            best_rank=$rank
            best_time=$t
        fi
    done <<<"$candidates"
    return 0
}

# managedfields_image_appliers <managed-fields-json> <list> <container> <owner>
#     -> MANAGEDFIELDS_IMAGE_APPLIERS
# The managers other than <owner> and keelson whose Apply entry on the
# object itself owns <container>'s image (by managedfields_image_owner's
# rule), shown as "'a', 'b'". Returns 0 when there is at least one, 1 when
# there is none, 2 when the input cannot be read or the name cannot be
# carried. Two appliers of the image: mimic changing it as one would take it
# from the other. Keelson's own Apply entry, from an earlier claim-apply, is
# not one: mimic forces past it by design (update_mimic_force_plan).
declare -g MANAGEDFIELDS_IMAGE_APPLIERS=""
managedfields_image_appliers() {
    local mf_json=$1 clist=$2 container=$3 owner=$4 out line name list="" seen=$'\n'
    MANAGEDFIELDS_IMAGE_APPLIERS=""
    case "$container" in
        *[\"\\\<\>\&\*\?]* | *[[:cntrl:]]* | *$'\xe2\x80\xa8'* | *$'\xe2\x80\xa9'*) return 2 ;;
    esac
    managedfields_image_owned_expr "$clist" "$container"
    out=$(printf '%s' "${mf_json:-[]}" | OWNER=$owner yq -p=json -o=y \
        "((select(tag == \"!!seq\")) // error(\"managedFields is not a list\"))
         | .[] | select(.operation == \"Apply\" and (.subresource // \"\") == \"\")
         | select(((.manager // \"\") | @base64) != (strenv(OWNER) | @base64))
         | select((.manager // \"\") != \"keelson\")
         | select(${MANAGEDFIELDS_OWNED_EXPR})
         | (.manager // \"\") | @base64" 2>/dev/null) || return 2
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$seen" in *$'\n'"$line"$'\n'*) continue ;; esac
        seen+="$line"$'\n'
        name=$(printf '%s' "$line" | base64 -d 2>/dev/null) || return 2
        managedfields_name_shown "$name"
        list+="${list:+, }'$MANAGEDFIELDS_NAME_SHOWN'"
    done <<<"$out"
    [ -n "$list" ] || return 1
    MANAGEDFIELDS_IMAGE_APPLIERS=$list
    return 0
}

# managedfields_reshaped <before-set-json> <after-set-json>  -> MANAGEDFIELDS_RESHAPED
# Whether a path <before> holds whole, as a bare {} leaf, comes back in
# <after> holding fields beneath it: the server now records that list or map
# field by field where it once recorded it whole, as after a CRD schema
# change (Argo Rollouts v1.9 keyed containers by name; before, the list was
# atomic). Only the pod lists a CRD schema change can re-key count:
# containers, initContainers and volumes under spec.template.spec or
# spec.jobTemplate.spec.template.spec. Any other {} leaf coming back with
# fields (a struct copied with the server's defaults, a resources map
# another manager filled) is the owned-{}-copies-the-live-value case, which
# no fresh apply by the owner clears. Sets MANAGEDFIELDS_RESHAPED to the
# first such path, as dot-joined field names, and returns 0; returns 1 when
# there is none or either input cannot be read.
declare -g MANAGEDFIELDS_RESHAPED=""
managedfields_reshaped() {
    MANAGEDFIELDS_RESHAPED=""
    local out
    # Each path is flagged, then the list filtered: a select inside the
    # walk lets everything through (yq carries on past a select whose
    # input is a binding), and a missing key yields no value, so the walk
    # is collected and indexed to read as null. Both sets go in on stdin,
    # as one document: either can be larger than one environment string
    # may be (128 KiB on Linux, past which yq is never run).
    out=$(printf '{"b":%s,"a":%s}' "$1" "$2" | yq -p=json -o=y '
        .b as $b
        | .a as $a
        # A path from inside the document starts at its key, b, which the
        # lookups below do not walk through.
        | [$b | .. | select(tag == "!!map" and length == 0) | path | .[1:]
            | select(length > 0)] as $leaves
        | [$leaves[] as $p
            | ([$p[] as $s ireduce ($a; .[$s])] | .[0]) as $there
            | {"p": $p, "hit": ((($there | tag) == "!!map") and (($there | length) > 0))}]
        # Compared with the data on the left: == reads its right side as a
        # glob, and these right sides are literals.
        | ["f:spec.f:template.f:spec.f:containers",
           "f:spec.f:template.f:spec.f:initContainers",
           "f:spec.f:template.f:spec.f:volumes",
           "f:spec.f:jobTemplate.f:spec.f:template.f:spec.f:containers",
           "f:spec.f:jobTemplate.f:spec.f:template.f:spec.f:initContainers",
           "f:spec.f:jobTemplate.f:spec.f:template.f:spec.f:volumes"] as $lists
        | map(select(.hit) | select((.p | join(".")) as $j | $lists | any_c($j == .)))
        | (.[0].p // []) | map(sub("^f:"; "")) | join(".")' 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    MANAGEDFIELDS_RESHAPED=$out
}

# managedfields_set_without <set-json> <omitted-json>  -> MANAGEDFIELDS_SET_EXPECTED
# <set-json> (a field set as managedfields_owner_set gives it) with each
# fieldsV1 path in <omitted-json> taken out, and any map that leaves empty
# taken out too: the set the server records once a body leaves those
# fields out. In the same sorted compact form, so the two compare as
# strings. Returns 1 when either input cannot be read.
declare -g MANAGEDFIELDS_SET_EXPECTED=""
managedfields_set_without() {
    local set=$1 omitted=$2
    MANAGEDFIELDS_SET_EXPECTED=""
    # Deepest ancestor first: once one is still holding something, every
    # one above it is too. A node is looked up by walking from the
    # document, which is what an ireduce over the path's segments does.
    # Both on stdin, as for managedfields_reshaped: the omitted list, as
    # the set, can be larger than one environment string may be.
    MANAGEDFIELDS_SET_EXPECTED=$(printf '{"s":%s,"o":%s}' "$set" "$omitted" | yq -p=json -o=yaml '
        .o as $om
        | .s
        | ($om[] as $p ireduce (.;
            delpaths([$p])
            | ([$p | to_entries | .[] | .key] | reverse | .[1:]) as $ks
            | ($ks[] as $n ireduce (.;
                ($p[:($n + 1)]) as $q
                | (. as $d | [$q[] as $s ireduce ($d; .[$s])] | .[0]) as $node
                | ((select(($node | tag) == "!!map" and ($node | length) == 0) | delpaths([$q])) // .)))))
        | sort_keys(..) | to_json(0)' 2>/dev/null) && [ -n "$MANAGEDFIELDS_SET_EXPECTED" ]
}

# managedfields_csa_holders <object-json>  -> MANAGEDFIELDS_CSA_HOLDERS
# The managers whose Update entry on the object itself owns kubectl's
# last-applied-configuration annotation, as "'a', 'b'". Returns 0 when there
# is at least one, 1 when there is none, 2 when the object cannot be read.
#
# Why it matters: after a successful kubectl apply --server-side, kubectl
# looks for an Update manager owning that annotation (left by a client-side
# kubectl apply, or Argo CD in client-side mode) and, finding one, merges
# all of that manager's fields into the applier's Apply entry and sends the
# body again; a failed re-send is only a warning. Confirmed on the wire in
# round 5 against kubectl 1.36.5. The applier then owns fields it never set,
# which its next deploy deletes, and a dry run cannot show it: the merge
# happens after the real write. So any server-side apply through kubectl is
# refused while such an entry exists.
declare -g MANAGEDFIELDS_CSA_HOLDERS=""
managedfields_csa_holders() {
    local obj=$1 out line name shown seen=$'\n' list=""
    MANAGEDFIELDS_CSA_HOLDERS=""
    # One name a line, as base64 so a name holding a line break stays one;
    # decoded, deduplicated in entry order and shown for a log line here.
    out=$(printf '%s' "$obj" | yq -p=json -o=y \
        '(.metadata.managedFields // [])[]
            | select(.operation == "Update" and (.subresource // "") == "")
            | select(.fieldsV1["f:metadata"]["f:annotations"]["f:kubectl.kubernetes.io/last-applied-configuration"] != null)
            | (.manager // "") | @base64' 2>/dev/null) || return 2
    [ -n "$out" ] || return 1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$seen" in *$'\n'"$line"$'\n'*) continue ;; esac
        seen+="$line"$'\n'
        name=$(printf '%s' "$line" | base64 -d 2>/dev/null) || return 2
        managedfields_name_shown "$name"
        shown=$MANAGEDFIELDS_NAME_SHOWN
        list+="${list:+, }'$shown'"
    done <<<"$out"
    [ -n "$list" ] || return 1
    MANAGEDFIELDS_CSA_HOLDERS=$list
    return 0
}

# managedfields_name_shown <name>  -> MANAGEDFIELDS_NAME_SHOWN
# A manager name as it may appear in a log line: a tab or line break written
# back as \t or \n, and any other control character as ?, so a plain-format
# line never splits. Only for display; decisions use the name itself.
declare -g MANAGEDFIELDS_NAME_SHOWN=""
managedfields_name_shown() {
    local n=$1
    # A backslash first, so one written into a name cannot pass for the \n
    # or \t that stand for a real line break or tab.
    n=${n//\\/\\\\}
    n=${n//$'\t'/\\t}
    n=${n//$'\n'/\\n}
    n=${n//[[:cntrl:]]/?}
    # C1 controls (U+0080 to U+009F, NEL among them) are not [[:cntrl:]] in
    # the C locale: as UTF-8 they are C2 followed by 80 to 9F.
    n=$(LC_ALL=C sed $'s/\xc2[\x80-\x9f]/?/g' <<<"$n")
    MANAGEDFIELDS_NAME_SHOWN=$n
}

# managedfields_list_held_whole <managed-fields-json> <list>
# Returns 0 when some entry holds the pod spec's <list> ("containers",
# "initContainers" or "imageVolumes"), or a node above it, as a bare {}
# leaf: the list is atomic (Argo Rollouts before v1.9 declares containers
# so), and a write that sends one element of it replaces the whole list.
# Returns 1 when none does, 2 when the input cannot be read.
managedfields_list_held_whole() {
    local mf_json=$1 clist=$2 path prefix seg held=""
    [ "$clist" = "imageVolumes" ] && clist=volumes
    for path in '["f:spec"]["f:template"]["f:spec"]' '["f:spec"]["f:jobTemplate"]["f:spec"]["f:template"]["f:spec"]'; do
        path+='["f:'"$clist"'"]'
        prefix=.fieldsV1
        while [[ $path =~ ^(\[\"[^\"]*\"\]) ]]; do
            seg=${BASH_REMATCH[1]}
            path=${path#"$seg"}
            prefix+=$seg
            held+="${held:+ or }((${prefix} | tag) == \"!!map\" and (${prefix} | length) == 0)"
        done
    done
    local n
    n=$(printf '%s' "$mf_json" | yq -p=json -o=y \
        "((select(tag == \"!!seq\")) // error(\"managedFields is not a list\"))
         | [.[] | select((.subresource // \"\") == \"\") | select(${held})] | length" 2>/dev/null) || return 2
    [ "$n" -gt 0 ]
}

# The projection is yq, kept in its own file beside lib/ so it reads as what
# it is. Resolved from this file, so the image and the tests find it alike.
MANAGEDFIELDS_PROJECT_YQ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../yq" && pwd)/managedfields-project.yq"
declare -g MANAGEDFIELDS_OWNER_SET=""
declare -g MANAGEDFIELDS_PROJECTED=""
declare -g MANAGEDFIELDS_OMITTED="[]"

# managedfields_owner_set <object-json> <manager>  -> MANAGEDFIELDS_OWNER_SET
# The fieldsV1 of <manager>'s Apply entry for the object itself, keys sorted
# and compact, so two reads of it compare as strings. Returns 1 unless there
# is exactly one such entry and it carries a set (mimic is only defined
# against one set, and the projection cannot be trusted to refuse on its
# own), and 2 when the object could not be read at all, which is not the same
# as the manager owning nothing.
#
# The count and the set come back together, one line each, from one yq.
# The entries are bound as an array, which is always one value; binding a
# stream that might be empty is what makes yq carry on with nulls.
managedfields_owner_set() {
    local obj=$1 manager=$2 out count
    MANAGEDFIELDS_OWNER_SET=""
    out=$(printf '%s' "$obj" | MANAGER=$manager yq -p=json -o=yaml \
        "[.metadata.managedFields[] | select((.manager | @base64) == (strenv(MANAGER) | @base64) and .operation == \"Apply\" and (.subresource // \"\") == \"\")] as \$e
         | (\$e | length | tostring) + \"\\n\"
           + ((\$e[0].fieldsV1 | select(tag == \"!!map\" and length > 0) | sort_keys(..) | to_json(0)) // \"null\")" 2>/dev/null) || return 2
    # No second line, or a null one, is an entry without a set: no
    # fieldsV1, an empty one, or one that is not a map at all.
    [[ $out == *$'\n'* ]] || return 1
    count=${out%%$'\n'*}
    [ "$count" = "1" ] || return 1
    out=${out#*$'\n'}
    [[ -n $out && $out != null ]] || return 1
    MANAGEDFIELDS_OWNER_SET=$out
    return 0
}

# managedfields_project <object-json> <manager>  -> MANAGEDFIELDS_PROJECTED MANAGEDFIELDS_OMITTED
# What <manager> applied, rebuilt from the live values of exactly its set, as
# compact JSON (see yq/managedfields-project.yq). Owned fields the live
# object no longer has (the server drops zero values) are left out, and
# their fieldsV1 paths are put in MANAGEDFIELDS_OMITTED as a compact JSON
# array of path arrays, "[]" when there are none: a caller that compares the
# owner's set afterwards expects exactly those to be gone. Check the manager
# with managedfields_owner_set first: given one with no entry, the output is
# rubbish rather than nothing. Returns non-zero, with yq's complaint in
# MANAGEDFIELDS_PROJECTED, when the walk fails.
managedfields_project() {
    local obj=$1 manager=$2 out
    MANAGEDFIELDS_OMITTED="[]"
    # stdout alone is the result: a warning yq prints on a run that succeeds
    # must not end up in what gets applied. Only a failure is run a second
    # time, for its message.
    if out=$(printf '%s' "$obj" | MANAGER=$manager yq -p=json -o=json -I0 \
            --from-file "$MANAGEDFIELDS_PROJECT_YQ" 2>/dev/null); then
        # Body and omitted paths, a line each: both are compact JSON, so
        # neither holds a line break of its own.
        if out=$(printf '%s' "$out" | yq -p=json -o=yaml '(.body | to_json(0)) + "\n" + (.omitted | to_json(0))' 2>/dev/null) \
                && [[ $out == *$'\n'* ]]; then
            MANAGEDFIELDS_PROJECTED=${out%%$'\n'*}
            MANAGEDFIELDS_OMITTED=${out#*$'\n'}
            return 0
        fi
        MANAGEDFIELDS_PROJECTED="the rebuilt set could not be read back"
        return 1
    fi
    MANAGEDFIELDS_PROJECTED=$(printf '%s' "$obj" | MANAGER=$manager yq -p=json -o=json -I0 \
        --from-file "$MANAGEDFIELDS_PROJECT_YQ" 2>&1 >/dev/null)
    return 1
}
