#!/usr/bin/env bats

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "${SCRIPT_DIR}/lib/log.bash"
    # shellcheck source=../scripts/lib/annotations.bash
    source "${SCRIPT_DIR}/lib/annotations.bash"
    unset KEELSON_LOG_FORMAT KEELSON_LOG_LEVEL
    KEELSON_CONFIG_MODE=keelson
    export KEELSON_CONFIG_MODE
}

KEELSON_LINES='keelson.pro/policy=minor
keelson.pro/match-tag=^1\.
keelson.pro/match-mode=regex'

KEEL_LINES='keel.sh/policy=major
keel.sh/match-tag=^2\.
keel.sh/pollSchedule=15m'

BOTH_LINES="${KEELSON_LINES}
${KEEL_LINES}"

# --- mode=keelson (default) ---

@test "keelson mode: reads keelson.pro/ only" {
    run annotation_get "$KEELSON_LINES" policy
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

@test "keelson mode: ignores keel.sh/" {
    run annotation_get "$KEEL_LINES" policy
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "keelson mode: missing key returns empty" {
    run annotation_get "$KEELSON_LINES" trigger
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- mode=keel ---

@test "keel mode: reads keel.sh/" {
    KEELSON_CONFIG_MODE=keel run annotation_get "$KEEL_LINES" policy
    [ "$status" -eq 0 ]
    [ "$output" = "major" ]
}

@test "keel mode: maps poll-schedule to keel.sh/pollSchedule" {
    KEELSON_CONFIG_MODE=keel run annotation_get "$KEEL_LINES" poll-schedule
    [ "$status" -eq 0 ]
    [ "$output" = "15m" ]
}

@test "keel mode: rejects policy=force" {
    KEELSON_CONFIG_MODE=keel run annotation_get "keel.sh/policy=force" policy
    [ "$status" -eq 0 ]
    [ "$output" = "REJECT:keel-policy-force-unsupported" ]
}

@test "keel mode: ignores keelson.pro/" {
    KEELSON_CONFIG_MODE=keel run annotation_get "$KEELSON_LINES" policy
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "keel mode: key with no keel equivalent returns empty" {
    KEELSON_CONFIG_MODE=keel run annotation_get "$KEELSON_LINES" match-mode
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- mode=both ---

@test "both mode: only keelson.pro/ present → uses keelson value" {
    KEELSON_CONFIG_MODE=both run annotation_get "keelson.pro/policy=minor" policy
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

@test "both mode: only keel.sh/ present → translates keel value" {
    KEELSON_CONFIG_MODE=both run annotation_get "keel.sh/policy=patch" policy
    [ "$status" -eq 0 ]
    [ "$output" = "patch" ]
}

@test "both mode: same key on both prefixes → REJECT dual-prefix-conflict" {
    KEELSON_CONFIG_MODE=both run annotation_get "$BOTH_LINES" policy
    [ "$status" -eq 0 ]
    [ "$output" = "REJECT:dual-prefix-conflict" ]
}

@test "both mode: agreeing values on both prefixes → still REJECT (one prefix per workload)" {
    KEELSON_CONFIG_MODE=both run annotation_get \
        "keelson.pro/policy=minor
keel.sh/policy=minor" policy
    [ "$status" -eq 0 ]
    [ "$output" = "REJECT:dual-prefix-conflict" ]
}

@test "both mode: different keys split across prefixes → still REJECT (per-workload check)" {
    KEELSON_CONFIG_MODE=both run annotation_get \
        "keelson.pro/match-tag=^1\.
keel.sh/policy=minor" policy
    [ "$status" -eq 0 ]
    [ "$output" = "REJECT:dual-prefix-conflict" ]
}

# --- value/key edge cases ---

@test "value containing '=' is preserved" {
    run annotation_get "keelson.pro/match-tag=^a=b$" match-tag
    [ "$status" -eq 0 ]
    [ "$output" = "^a=b$" ]
}

@test "key prefix match is exact, not substring" {
    run annotation_get "keelson.pro/policy-foo=bar
keelson.pro/policy=ok" policy
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

# --- per-container overrides ---

@test "container override: container-suffixed key wins over bare" {
    local lines='keelson.pro/policy=minor
keelson.pro/policy.web=major'
    run annotation_get "$lines" policy web
    [ "$status" -eq 0 ]
    [ "$output" = "major" ]
}

@test "container override: falls back to bare when container suffix absent" {
    local lines='keelson.pro/policy=minor
keelson.pro/policy.web=major'
    run annotation_get "$lines" policy db
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

@test "container override: empty container arg behaves as workload-only" {
    local lines='keelson.pro/policy=minor
keelson.pro/policy.web=major'
    run annotation_get "$lines" policy ""
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

@test "container override: keel mode honours container suffix" {
    local lines='keel.sh/policy=major
keel.sh/policy.web=minor'
    KEELSON_CONFIG_MODE=keel run annotation_get "$lines" policy web
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

@test "container override: container key with hyphens in name" {
    local lines='keelson.pro/policy.web-frontend=major
keelson.pro/policy=minor'
    run annotation_get "$lines" policy web-frontend
    [ "$status" -eq 0 ]
    [ "$output" = "major" ]
}

@test "invalid KEELSON_CONFIG_MODE returns status 2" {
    KEELSON_CONFIG_MODE=junk run annotation_get "$KEELSON_LINES" policy
    [ "$status" -eq 2 ]
}
