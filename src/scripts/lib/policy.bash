#!/usr/bin/env bash
# Tag-policy primitives for Keelson. Source-only - do not execute.
#
# Policy semantics: a policy identifies the highest segment position
# that may change. Segments to the LEFT must match byte-for-byte.
# Segments AT and to the RIGHT must be numeric and form a larger
# integer tuple than the current tag's same positions.
#
# Public API:
#   policy_resolve_position <policy> <tag>
#       Print the 1-indexed position. Exit 0 ok. Exit 2 invalid for
#       this tag (e.g. minor on non-3-segment). Exit 3 'never' or empty.
#   tag_is_newer <current-tag> <candidate-tag> <position>
#       Exit 0 iff candidate is strictly newer under <position>.

policy_resolve_position() {
    local policy=$1 tag=$2
    local -a segs
    IFS='.' read -r -a segs <<<"$tag"
    local n=${#segs[@]}

    case "$policy" in
        never|"")
            return 3
            ;;
        major|all)
            printf '1\n'
            return 0
            ;;
        minor)
            if [ "$n" -ne 3 ]; then
                return 2
            fi
            printf '2\n'
            return 0
            ;;
        patch)
            printf '%d\n' "$n"
            return 0
            ;;
        *[!0-9]*)
            return 2
            ;;
        *)
            if [ "$policy" -lt 1 ] || [ "$policy" -gt "$n" ]; then
                return 2
            fi
            printf '%d\n' "$policy"
            return 0
            ;;
    esac
}

tag_is_newer() {
    local current=$1 candidate=$2 position=$3
    local -a curr_segs cand_segs
    IFS='.' read -r -a curr_segs <<<"$current"
    IFS='.' read -r -a cand_segs <<<"$candidate"

    [ "${#curr_segs[@]}" -eq "${#cand_segs[@]}" ] || return 1
    local n=${#curr_segs[@]}
    local i

    for (( i=1; i<position; i++ )); do
        [ "${curr_segs[i-1]}" = "${cand_segs[i-1]}" ] || return 1
    done

    for (( i=position; i<=n; i++ )); do
        case "${cand_segs[i-1]}" in *[!0-9]*|'') return 1 ;; esac
        case "${curr_segs[i-1]}" in *[!0-9]*|'') return 1 ;; esac
    done

    for (( i=position; i<=n; i++ )); do
        if [ "${cand_segs[i-1]}" -gt "${curr_segs[i-1]}" ]; then
            return 0
        fi
        if [ "${cand_segs[i-1]}" -lt "${curr_segs[i-1]}" ]; then
            return 1
        fi
    done
    return 1
}
