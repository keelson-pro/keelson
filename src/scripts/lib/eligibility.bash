# Workload eligibility chain for Keelson.
# Sourced; not directly executable.
#
# Depends on:
#   lib/annotations.bash
#   lib/image.bash
#   lib/policy.bash
#
# The result lands in ELIGIBILITY_RESULT rather than on stdout: this runs once
# per container per poll, and every value it consults used to arrive through a
# command substitution of its own.

ELIGIBILITY_RESULT=

# eligibility_check <annotation-lines> <image-ref> [<container-name>]
#                   -> ELIGIBILITY_RESULT
# One of:
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
    annotation_get "$annotations" policy "$container"
    policy=$ANNOTATION_VALUE
    if [ -z "$policy" ]; then
        ELIGIBILITY_RESULT='SKIP no-policy-annotation'
        return 1
    fi
    case "$policy" in
        REJECT:*)
            ELIGIBILITY_RESULT="SKIP ${policy#REJECT:}"
            return 1
            ;;
        never)
            ELIGIBILITY_RESULT='SKIP policy-never'
            return 1
            ;;
    esac
    if ! eligibility_policy_syntax_ok "$policy"; then
        ELIGIBILITY_RESULT='SKIP invalid-policy'
        return 1
    fi

    image_skip_reason "$image"
    if [ -n "$IMAGE_SKIP_REASON" ]; then
        ELIGIBILITY_RESULT="SKIP $IMAGE_SKIP_REASON"
        return 1
    fi

    local tag position rc
    image_tag "$image"
    tag=$IMAGE_TAG
    set +e
    position=$(policy_resolve_position "$policy" "$tag")
    rc=$?
    set -e
    case "$rc" in
        0)
            ELIGIBILITY_RESULT="OK $policy $position"
            return 0
            ;;
        2)
            ELIGIBILITY_RESULT='SKIP policy-position-incompatible-with-tag'
            return 1
            ;;
        3)
            ELIGIBILITY_RESULT='SKIP policy-never'
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
