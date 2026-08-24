#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/policy.bash
    source "${SCRIPT_DIR}/lib/policy.bash"
}

# --- policy_resolve_position ---

@test "policy_resolve_position: major -> 1" {
    run policy_resolve_position major 1.2.3
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "policy_resolve_position: all is alias for major" {
    run policy_resolve_position all 1.2.3
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "policy_resolve_position: minor on 3-segment -> 2" {
    run policy_resolve_position minor 1.2.3
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "policy_resolve_position: minor on 2-segment -> 2" {
    # The second part of however many there are, not the middle of exactly
    # three: a two-part tag has a second part and it is the one minor means.
    run policy_resolve_position minor 1.2
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "policy_resolve_position: minor on 4-segment -> 2" {
    run policy_resolve_position minor 1.2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "policy_resolve_position: minor on 5-segment -> 2" {
    # keelson-package releases are five parts, so this is a real shape.
    run policy_resolve_position minor 1.15.1.36.1
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "policy_resolve_position: minor on a 1-segment tag is invalid" {
    # There is no second part to change.
    run policy_resolve_position minor 7
    [ "$status" -eq 2 ]
}

@test "policy_resolve_position: minor ignores a v prefix" {
    run policy_resolve_position minor v1.2.3
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "policy_resolve_position: major is the first part whatever the length" {
    run policy_resolve_position major 1.15.1.36.1
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run policy_resolve_position major 7
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "policy_resolve_position: patch is the last part whatever the length" {
    run policy_resolve_position patch 1.15.1.36.1
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
    run policy_resolve_position patch 7
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "policy_resolve_position: patch -> last index for 3-segment" {
    run policy_resolve_position patch 1.2.3
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "policy_resolve_position: patch -> last index for 4-segment" {
    run policy_resolve_position patch 1.2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

# --- part-N: naming a part no shorthand reaches ---
#
# major, minor and patch cover the first, second and last. Anything between
# them needs saying explicitly, which matters for releases longer than semver.
# Keel has no equivalent: its policy parser is a closed set of all, major,
# minor, patch, force, glob: and regexp:.

@test "policy_resolve_position: part-N within range" {
    run policy_resolve_position part-3 1.2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "policy_resolve_position: part-N reaches a middle part of a long tag" {
    run policy_resolve_position part-4 1.15.1.36.1
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "policy_resolve_position: part-N has no upper bound in the name" {
    run policy_resolve_position part-12 1.2.3.4.5.6.7.8.9.10.11.12
    [ "$status" -eq 0 ]
    [ "$output" = "12" ]
}

@test "policy_resolve_position: part-N agrees with the shorthands" {
    run policy_resolve_position part-1 1.2.3
    [ "$output" = "$(policy_resolve_position major 1.2.3)" ]
    run policy_resolve_position part-2 1.2.3
    [ "$output" = "$(policy_resolve_position minor 1.2.3)" ]
}

@test "policy_resolve_position: part-N past the end of the tag is invalid" {
    run policy_resolve_position part-5 1.2.3
    [ "$status" -eq 2 ]
}

@test "policy_resolve_position: part-0 is invalid, parts are 1-indexed" {
    run policy_resolve_position part-0 1.2.3
    [ "$status" -eq 2 ]
}

@test "policy_resolve_position: a leading zero is invalid, not octal" {
    # Bash reads a leading zero as octal in arithmetic, so part-010 silently
    # meant part 8 and part-08 was not a number at all -- both accepted, with
    # the wrong answer.
    local t=1.2.3.4.5.6.7.8.9.10.11.12
    run policy_resolve_position part-010 "$t"
    [ "$status" -eq 2 ]
    run policy_resolve_position part-08 "$t"
    [ "$status" -eq 2 ]
    run policy_resolve_position part-01 "$t"
    [ "$status" -eq 2 ]
}

@test "policy_resolve_position: a part number past int64 is invalid" {
    # The range check errors past what bash arithmetic represents, so the
    # out-of-range test never fired and the value clamped to max int.
    run policy_resolve_position part-9223372036854775808 1.2.3
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    run policy_resolve_position part-99999999999999999999999 1.2.3
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "policy_resolve_position: a large but sane part number still resolves" {
    # Nine digits is well past any real tag and well inside the arithmetic.
    run policy_resolve_position part-999999999 1.2.3
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "policy_resolve_position: arbitrary depth works, both halves" {
    local t="" i
    for ((i = 1; i <= 40; i++)); do t+="$i."; done
    t=${t%.}
    run policy_resolve_position part-37 "$t"
    [ "$status" -eq 0 ]
    [ "$output" = "37" ]
    run policy_resolve_position patch "$t"
    [ "$output" = "40" ]
    # and the comparison half agrees at that depth
    local newer=${t/.37./.99.}
    tag_is_newer "$t" "$newer" 37
}

@test "policy_resolve_position: part- with no number is invalid" {
    run policy_resolve_position part- 1.2.3
    [ "$status" -eq 2 ]
}

@test "policy_resolve_position: part-abc is invalid" {
    run policy_resolve_position part-abc 1.2.3
    [ "$status" -eq 2 ]
}

@test "policy_resolve_position: partN without the hyphen is invalid" {
    run policy_resolve_position part3 1.2.3
    [ "$status" -eq 2 ]
}

@test "policy_resolve_position: a bare number is no longer a policy" {
    # It was accepted and undocumented. "3" reads as a count, a version or a
    # part depending on who is looking, which is why it is spelled out now.
    run policy_resolve_position 2 1.2.3.4
    [ "$status" -eq 2 ]
}

@test "policy_resolve_position: never returns status 3" {
    run policy_resolve_position never 1.2.3
    [ "$status" -eq 3 ]
}

@test "policy_resolve_position: empty policy returns status 3" {
    run policy_resolve_position "" 1.2.3
    [ "$status" -eq 3 ]
}

@test "policy_resolve_position: junk policy is invalid" {
    run policy_resolve_position foo 1.2.3
    [ "$status" -eq 2 ]
}

# --- tag_is_newer ---

@test "tag_is_newer: patch bump under patch policy is newer" {
    run tag_is_newer 1.2.3 1.2.4 3
    [ "$status" -eq 0 ]
}

@test "tag_is_newer: same tag is not newer" {
    run tag_is_newer 1.2.3 1.2.3 3
    [ "$status" -eq 1 ]
}

@test "tag_is_newer: minor bump under patch policy is rejected (left changed)" {
    run tag_is_newer 1.2.3 1.3.0 3
    [ "$status" -eq 1 ]
}

@test "tag_is_newer: minor bump under minor policy is newer" {
    run tag_is_newer 1.2.3 1.3.0 2
    [ "$status" -eq 0 ]
}

@test "tag_is_newer: major bump under major policy is newer" {
    run tag_is_newer 1.2.3 2.0.0 1
    [ "$status" -eq 0 ]
}

@test "tag_is_newer: older candidate is rejected" {
    run tag_is_newer 1.2.3 1.2.2 3
    [ "$status" -eq 1 ]
}

@test "tag_is_newer: different segment count is rejected" {
    run tag_is_newer 1.2.3 1.2.3.1 3
    [ "$status" -eq 1 ]
}

@test "tag_is_newer: non-numeric candidate segment is rejected" {
    run tag_is_newer 1.2.3 1.2.foo 3
    [ "$status" -eq 1 ]
}

@test "tag_is_newer: 4-segment patch bump" {
    run tag_is_newer 1.2.3.4 1.2.3.5 4
    [ "$status" -eq 0 ]
}

@test "tag_is_newer: 4-segment third-position bump under numeric 3 policy" {
    run tag_is_newer 1.2.3.4 1.2.4.0 3
    [ "$status" -eq 0 ]
}

@test "tag_is_newer: 4-segment third-position bump under patch (4) policy is rejected" {
    run tag_is_newer 1.2.3.4 1.2.4.0 4
    [ "$status" -eq 1 ]
}
