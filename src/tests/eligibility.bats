#!/usr/bin/env bats

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
    run eligibility_check "keelson.pro/policy=minor" "ghcr.io/x/y:1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "OK minor 2" ]
}

@test "eligible: patch policy on 4-segment tag picks last position" {
    run eligibility_check "keelson.pro/policy=patch" "ghcr.io/x/y:1.2.3.4"
    [ "$status" -eq 0 ]
    [ "$output" = "OK patch 4" ]
}

@test "eligible: numeric N policy" {
    run eligibility_check "keelson.pro/policy=2" "ghcr.io/x/y:1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "OK 2 2" ]
}

@test "eligible: all is alias for major" {
    run eligibility_check "keelson.pro/policy=all" "ghcr.io/x/y:1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "OK all 1" ]
}

@test "skip: no policy annotation" {
    run eligibility_check "" "ghcr.io/x/y:1.2.3"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP no-policy-annotation" ]
}

@test "skip: policy=never" {
    run eligibility_check "keelson.pro/policy=never" "ghcr.io/x/y:1.2.3"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP policy-never" ]
}

@test "skip: invalid policy junk" {
    run eligibility_check "keelson.pro/policy=foo" "ghcr.io/x/y:1.2.3"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP invalid-policy" ]
}

@test "skip: keel policy=force under keel mode" {
    KEELSON_CONFIG_MODE=keel run eligibility_check "keel.sh/policy=force" "ghcr.io/x/y:1.2.3"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP keel-policy-force-unsupported" ]
}

@test "skip: tag is latest" {
    run eligibility_check "keelson.pro/policy=minor" "nginx:latest"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP tag-is-latest" ]
}

@test "skip: no tag at all" {
    run eligibility_check "keelson.pro/policy=minor" "nginx"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP no-tag" ]
}

@test "skip: digest-pinned" {
    run eligibility_check "keelson.pro/policy=minor" "nginx@sha256:abc"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP tag-is-digest-pinned" ]
}

@test "skip: non-numeric tag segment" {
    run eligibility_check "keelson.pro/policy=minor" "nginx:v1.2.3"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP tag-has-non-numeric-segment" ]
}

@test "skip: minor policy on 4-segment tag" {
    run eligibility_check "keelson.pro/policy=minor" "nginx:1.2.3.4"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP policy-position-incompatible-with-tag" ]
}

@test "skip: minor policy on 2-segment tag" {
    run eligibility_check "keelson.pro/policy=minor" "nginx:1.2"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP policy-position-incompatible-with-tag" ]
}

@test "skip: numeric N out of range" {
    run eligibility_check "keelson.pro/policy=5" "nginx:1.2.3"
    [ "$status" -eq 1 ]
    [ "$output" = "SKIP policy-position-incompatible-with-tag" ]
}

@test "keel mode: cleanly maps major policy" {
    KEELSON_CONFIG_MODE=keel run eligibility_check "keel.sh/policy=major" "ghcr.io/x/y:1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "OK major 1" ]
}
