#!/usr/bin/env bats

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

@test "policy_resolve_position: minor on 2-segment is invalid" {
    run policy_resolve_position minor 1.2
    [ "$status" -eq 2 ]
}

@test "policy_resolve_position: minor on 4-segment is invalid" {
    run policy_resolve_position minor 1.2.3.4
    [ "$status" -eq 2 ]
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

@test "policy_resolve_position: numeric N within range" {
    run policy_resolve_position 2 1.2.3.4
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "policy_resolve_position: numeric N out of range is invalid" {
    run policy_resolve_position 5 1.2.3
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
