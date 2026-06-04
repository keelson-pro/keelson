# Workload eligibility chain for Keelson.
# Sourced; not directly executable.
#
# Depends on:
#   lib/annotations.bash
#   lib/image.bash
#   lib/policy.bash

# eligibility_check <annotation-lines> <image-ref> [<container-name>]
# Echoes:
#   "OK <policy> <position>"     - workload is eligible for an update check.
#   "SKIP <reason>"              - workload is ineligible; reason is a stable id.
# Returns 0 if eligible, 1 if skipped. Errors return non-zero status with no output.
#
# When <container-name> is non-empty, per-container annotation overrides
# (e.g. keelson.pro/policy.<container>) take precedence over the
# workload-wide key.
#
# Skip reasons (stable ids):
#   no-policy-annotation
#   dual-prefix-conflict                    (config-mode=both, workload has both prefixes)
#   keel-policy-force-unsupported           (only under config-mode keel/both)
#   policy-never
#   invalid-policy
#   tag-is-digest-pinned
#   no-tag
#   tag-is-latest
#   tag-has-non-numeric-segment
#   policy-position-incompatible-with-tag   (e.g. "minor" on a 4-segment tag)
eligibility_check() {
    local annotations=$1 image=$2 container=${3:-}

    local policy
    policy=$(annotation_get "$annotations" policy "$container")
    if [ -z "$policy" ]; then
        printf 'SKIP no-policy-annotation'
        return 1
    fi
    case "$policy" in
        REJECT:*)
            printf 'SKIP %s' "${policy#REJECT:}"
            return 1
            ;;
        never)
            printf 'SKIP policy-never'
            return 1
            ;;
    esac
    if ! eligibility_policy_syntax_ok "$policy"; then
        printf 'SKIP invalid-policy'
        return 1
    fi

    local img_reason
    img_reason=$(image_skip_reason "$image")
    if [ -n "$img_reason" ]; then
        printf 'SKIP %s' "$img_reason"
        return 1
    fi

    local tag position rc
    tag=$(image_tag "$image")
    set +e
    position=$(policy_resolve_position "$policy" "$tag")
    rc=$?
    set -e
    case "$rc" in
        0)
            printf 'OK %s %s' "$policy" "$position"
            return 0
            ;;
        2)
            printf 'SKIP policy-position-incompatible-with-tag'
            return 1
            ;;
        3)
            printf 'SKIP policy-never'
            return 1
            ;;
    esac
    return 1
}

# Recognise syntactically valid policy words. "never" handled by caller; this
# helper exists to distinguish "junk policy string" from "valid policy that
# doesn't fit this tag's segment count" (both produce status 2 in policy.bash).
eligibility_policy_syntax_ok() {
    case "$1" in
        major|minor|patch|all|never) return 0 ;;
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}
