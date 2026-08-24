#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "${SCRIPT_DIR}/lib/log.bash"
    # shellcheck source=../scripts/lib/annotations.bash
    source "${SCRIPT_DIR}/lib/annotations.bash"
    # shellcheck source=../scripts/lib/image.bash
    source "${SCRIPT_DIR}/lib/image.bash"
    # shellcheck source=../scripts/lib/policy.bash
    source "${SCRIPT_DIR}/lib/policy.bash"
    # shellcheck source=../scripts/lib/eligibility.bash
    source "${SCRIPT_DIR}/lib/eligibility.bash"
    KEELSON_CONFIG_MODE=keelson
    export KEELSON_CONFIG_MODE
}

@test "eligible: minor policy + 3-segment tag" {
    rc=0
    eligibility_check "keelson.pro/policy=minor" "ghcr.io/x/y:1.2.3" || rc=$?
    [ "$rc" -eq 0 ]
    [ "$ELIGIBILITY_RESULT" = "OK minor 2" ]
}

@test "eligible: patch policy on 4-segment tag picks last position" {
    rc=0
    eligibility_check "keelson.pro/policy=patch" "ghcr.io/x/y:1.2.3.4" || rc=$?
    [ "$rc" -eq 0 ]
    [ "$ELIGIBILITY_RESULT" = "OK patch 4" ]
}

@test "eligible: part-N policy" {
    rc=0
    eligibility_check "keelson.pro/policy=part-2" "ghcr.io/x/y:1.2.3" || rc=$?
    [ "$rc" -eq 0 ]
    [ "$ELIGIBILITY_RESULT" = "OK part-2 2" ]
}

@test "skip: a bare number is not a policy" {
    rc=0
    eligibility_check "keelson.pro/policy=2" "ghcr.io/x/y:1.2.3" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP invalid-policy" ]
}

@test "eligible: all is alias for major" {
    rc=0
    eligibility_check "keelson.pro/policy=all" "ghcr.io/x/y:1.2.3" || rc=$?
    [ "$rc" -eq 0 ]
    [ "$ELIGIBILITY_RESULT" = "OK all 1" ]
}

@test "skip: no policy annotation" {
    rc=0
    eligibility_check "" "ghcr.io/x/y:1.2.3" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP no-policy-annotation" ]
}

@test "skip: policy=never" {
    rc=0
    eligibility_check "keelson.pro/policy=never" "ghcr.io/x/y:1.2.3" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP policy-never" ]
}

@test "skip: invalid policy junk" {
    rc=0
    eligibility_check "keelson.pro/policy=foo" "ghcr.io/x/y:1.2.3" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP invalid-policy" ]
}

@test "skip: keel policy=force under keel mode" {
    rc=0
    KEELSON_CONFIG_MODE=keel eligibility_check "keel.sh/policy=force" "ghcr.io/x/y:1.2.3" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP keel-policy-force-unsupported" ]
}

@test "skip: tag is latest" {
    rc=0
    eligibility_check "keelson.pro/policy=minor" "nginx:latest" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP tag-is-latest" ]
}

@test "skip: no tag at all" {
    rc=0
    eligibility_check "keelson.pro/policy=minor" "nginx" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP no-tag" ]
}

@test "skip: digest-pinned" {
    rc=0
    eligibility_check "keelson.pro/policy=minor" "nginx@sha256:abc" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP tag-is-digest-pinned" ]
}

@test "skip: non-numeric tag segment" {
    rc=0
    eligibility_check "keelson.pro/policy=minor" "nginx:v1.2.3" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP tag-has-non-numeric-segment" ]
}

@test "eligible: minor policy on a 4-segment tag" {
    # minor is the second part of however many there are, so a tag longer
    # than semver is eligible rather than silently never updating.
    rc=0
    eligibility_check "keelson.pro/policy=minor" "nginx:1.2.3.4" || rc=$?
    [ "$rc" -eq 0 ]
    [ "$ELIGIBILITY_RESULT" = "OK minor 2" ]
}

@test "eligible: minor policy on a 2-segment tag" {
    rc=0
    eligibility_check "keelson.pro/policy=minor" "nginx:1.2" || rc=$?
    [ "$rc" -eq 0 ]
    [ "$ELIGIBILITY_RESULT" = "OK minor 2" ]
}

@test "skip: minor policy on a 1-segment tag" {
    # No second part to change, so there is nothing for minor to mean.
    rc=0
    eligibility_check "keelson.pro/policy=minor" "nginx:7" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP policy-position-incompatible-with-tag" ]
}

@test "skip: part-N past the end of the tag" {
    # A valid policy name that this particular tag cannot satisfy, which is a
    # different answer from a policy Keelson does not understand at all.
    rc=0
    eligibility_check "keelson.pro/policy=part-5" "nginx:1.2.3" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ELIGIBILITY_RESULT" = "SKIP policy-position-incompatible-with-tag" ]
}

@test "keel mode: cleanly maps major policy" {
    rc=0
    KEELSON_CONFIG_MODE=keel eligibility_check "keel.sh/policy=major" "ghcr.io/x/y:1.2.3" || rc=$?
    [ "$rc" -eq 0 ]
    [ "$ELIGIBILITY_RESULT" = "OK major 1" ]
}
