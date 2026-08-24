#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# Tag-policy primitives for Keelson. Source-only - do not execute.
#
# Policy semantics: a policy identifies the highest segment position
# that may change. Segments to the LEFT must match byte-for-byte.
# Segments AT and to the RIGHT must be numeric and form a larger
# integer tuple than the current tag's same positions.
#
# Public API:
#   policy_resolve_position <policy> <tag>
#       Print the 1-indexed position. Exit 0 ok. Exit 2 invalid for this tag
#       (e.g. minor on a single-part tag, which has no second part). Exit 3
#       'never' or empty.
#
# major is the first part, minor the second, patch the last whatever its
# index. None of them assume three: a five-part release still has a first, a
# second and a last.
#   tag_is_newer <current-tag> <candidate-tag> <position>
#       Exit 0 iff candidate is strictly newer under <position>.

# policy_name_valid <policy>
# Whether the policy is one Keelson understands at all, without reference to
# any tag. Whether it then fits a particular tag is policy_resolve_position's
# question.
#
# Here rather than in eligibility.bash so the set of policy names is stated
# once: it was in both, and adding part-N to one and not the other made every
# part-N annotation invalid while resolving perfectly well.
policy_name_valid() {
    case "$1" in
        major|minor|patch|all|never) return 0 ;;
        part-[0-9]*)
            local part=${1#part-}
            case "$part" in
                # Digits all the way: the pattern above only promises the
                # first one, so part-1x still arrives here.
                *[!0-9]*) return 1 ;;
                # No leading zero, which also rules out part-0. Bash reads a
                # leading zero as octal in arithmetic, so part-010 would mean
                # part 8, and part-08 is not a number at all -- both were
                # accepted, quietly, with the wrong answer.
                0*) return 1 ;;
            esac
            # Longer than any tag could possibly be, and past what bash
            # arithmetic represents the comparison below errors and the value
            # clamps to max int, so an impossible position gets accepted.
            [ "${#part}" -le 9 ] || return 1
            return 0
            ;;
        *) return 1 ;;
    esac
}

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
            # The second part of however many there are, not the middle of
            # exactly three. A version longer than semver still has a second
            # part and it is the one minor means; demanding three rejected
            # 1.0 and 1.2.3.4 alike, and a rejected tag is a container that
            # silently never updates.
            if [ "$n" -lt 2 ]; then
                return 2
            fi
            printf '2\n'
            return 0
            ;;
        patch)
            printf '%d\n' "$n"
            return 0
            ;;
        part-[0-9]*)
            # Any part by number, for the ones no shorthand reaches: major,
            # minor and patch are the first, second and last, so a five-part
            # release has two in the middle with no other way to name them.
            #
            # Spelled out rather than a bare number, which this accepted
            # before and never documented: "3" reads as a count, a version or
            # a part depending on who is looking.
            # Validated there, not here: the rules are fiddly enough that a
            # second copy drifted once already.
            policy_name_valid "$policy" || return 2
            local part=${policy#part-}
            if [ "$part" -gt "$n" ]; then
                return 2
            fi
            printf '%d\n' "$part"
            return 0
            ;;
        *)
            return 2
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
