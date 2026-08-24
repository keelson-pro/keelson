#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

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

# Warnings and errors go to stderr; fold them in so `run` can see them.
emit() { "$@" 2>&1; }

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
    annotation_get "$KEELSON_LINES" policy
    [ "$ANNOTATION_VALUE" = "minor" ]
}

@test "keelson mode: ignores keel.sh/" {
    annotation_get "$KEEL_LINES" policy
    [ -z "$ANNOTATION_VALUE" ]
}

@test "keelson mode: missing key returns empty" {
    annotation_get "$KEELSON_LINES" trigger
    [ -z "$ANNOTATION_VALUE" ]
}

# --- mode=keel ---

@test "keel mode: reads keel.sh/" {
    KEELSON_CONFIG_MODE=keel annotation_get "$KEEL_LINES" policy
    [ "$ANNOTATION_VALUE" = "major" ]
}

@test "keel mode: maps pollSchedule to keel.sh/pollSchedule" {
    KEELSON_CONFIG_MODE=keel annotation_get "$KEEL_LINES" pollSchedule
    [ "$ANNOTATION_VALUE" = "15m" ]
}

@test "keel mode: rejects policy=force" {
    KEELSON_CONFIG_MODE=keel annotation_get "keel.sh/policy=force" policy
    [ "$ANNOTATION_VALUE" = "REJECT:keel-policy-force-unsupported" ]
}

@test "keel mode: ignores keelson.pro/" {
    KEELSON_CONFIG_MODE=keel annotation_get "$KEELSON_LINES" policy
    [ -z "$ANNOTATION_VALUE" ]
}

@test "keel mode: key with no keel equivalent returns empty" {
    KEELSON_CONFIG_MODE=keel annotation_get "$KEELSON_LINES" matchMode
    [ -z "$ANNOTATION_VALUE" ]
}

# --- mode=both ---

@test "both mode: only keelson.pro/ present → uses keelson value" {
    KEELSON_CONFIG_MODE=both annotation_get "keelson.pro/policy=minor" policy
    [ "$ANNOTATION_VALUE" = "minor" ]
}

@test "both mode: only keel.sh/ present → translates keel value" {
    KEELSON_CONFIG_MODE=both annotation_get "keel.sh/policy=patch" policy
    [ "$ANNOTATION_VALUE" = "patch" ]
}

@test "both mode: same key on both prefixes → REJECT dual-prefix-conflict" {
    KEELSON_CONFIG_MODE=both annotation_get "$BOTH_LINES" policy
    [ "$ANNOTATION_VALUE" = "REJECT:dual-prefix-conflict" ]
}

@test "both mode: agreeing values on both prefixes → still REJECT (one prefix per workload)" {
    KEELSON_CONFIG_MODE=both annotation_get \
        "keelson.pro/policy=minor
keel.sh/policy=minor" policy
    [ "$ANNOTATION_VALUE" = "REJECT:dual-prefix-conflict" ]
}

@test "both mode: different keys split across prefixes → still REJECT (per-workload check)" {
    KEELSON_CONFIG_MODE=both annotation_get \
        "keelson.pro/match-tag=^1\.
keel.sh/policy=minor" policy
    [ "$ANNOTATION_VALUE" = "REJECT:dual-prefix-conflict" ]
}

# --- value/key edge cases ---

@test "value containing '=' is preserved" {
    annotation_get "keelson.pro/match-tag=^a=b$" matchTag
    [ "$ANNOTATION_VALUE" = "^a=b$" ]
}

@test "key prefix match is exact, not substring" {
    annotation_get "keelson.pro/policy-foo=bar
keelson.pro/policy=ok" policy
    [ "$ANNOTATION_VALUE" = "ok" ]
}

# --- per-container overrides ---

@test "container override: container-suffixed key wins over bare" {
    local lines='keelson.pro/policy=minor
keelson.pro/policy.web=major'
    annotation_get "$lines" policy web
    [ "$ANNOTATION_VALUE" = "major" ]
}

@test "container override: falls back to bare when container suffix absent" {
    local lines='keelson.pro/policy=minor
keelson.pro/policy.web=major'
    annotation_get "$lines" policy db
    [ "$ANNOTATION_VALUE" = "minor" ]
}

@test "container override: empty container arg behaves as workload-only" {
    local lines='keelson.pro/policy=minor
keelson.pro/policy.web=major'
    annotation_get "$lines" policy ""
    [ "$ANNOTATION_VALUE" = "minor" ]
}

@test "container override: keel mode honours container suffix" {
    local lines='keel.sh/policy=major
keel.sh/policy.web=minor'
    KEELSON_CONFIG_MODE=keel annotation_get "$lines" policy web
    [ "$ANNOTATION_VALUE" = "minor" ]
}

@test "container override: container key with hyphens in name" {
    local lines='keelson.pro/policy.web-frontend=major
keelson.pro/policy=minor'
    annotation_get "$lines" policy web-frontend
    [ "$ANNOTATION_VALUE" = "major" ]
}

@test "invalid KEELSON_CONFIG_MODE returns status 2" {
    local rc=0
    KEELSON_CONFIG_MODE=junk annotation_get "$KEELSON_LINES" policy || rc=$?
    [ "$rc" -eq 2 ]
}

# --- lookup mechanics ---
#
# These pin the line-scanning contract directly, so an implementation swap
# underneath annotation_get has something to answer to.

@test "lookup: matches on the first line" {
    annotation_lookup_raw 'keelson.pro/policy=minor
keelson.pro/trigger=poll' 'keelson.pro/policy'
    [ "$ANNOTATION_RAW" = "minor" ]
}

@test "lookup: matches on the last line" {
    annotation_lookup_raw 'keelson.pro/trigger=poll
keelson.pro/policy=minor' 'keelson.pro/policy'
    [ "$ANNOTATION_RAW" = "minor" ]
}

@test "lookup: absent key leaves the raw value empty" {
    annotation_lookup_raw 'keelson.pro/policy=minor' 'keelson.pro/trigger'
    [ -z "$ANNOTATION_RAW" ]
}

@test "lookup: empty input leaves the raw value empty" {
    annotation_lookup_raw '' 'keelson.pro/policy'
    [ -z "$ANNOTATION_RAW" ]
}

@test "lookup: empty value is read as empty, not as absent-then-stale" {
    ANNOTATION_RAW=stale
    annotation_lookup_raw 'keelson.pro/policy=' 'keelson.pro/policy'
    [ -z "$ANNOTATION_RAW" ]
}

@test "lookup: a longer key is not matched by its prefix" {
    annotation_lookup_raw 'keelson.pro/match-mode=regex' 'keelson.pro/match'
    [ -z "$ANNOTATION_RAW" ]
}

@test "lookup: a key spelled inside another line's value does not match" {
    annotation_lookup_raw 'keelson.pro/notify=on keelson.pro/policy=all
keelson.pro/policy=minor' 'keelson.pro/policy'
    [ "$ANNOTATION_RAW" = "minor" ]
}

@test "lookup: the first of two duplicate keys wins" {
    annotation_lookup_raw 'keelson.pro/policy=minor
keelson.pro/policy=major' 'keelson.pro/policy'
    [ "$ANNOTATION_RAW" = "minor" ]
}

@test "lookup: an equals sign in the value survives" {
    annotation_lookup_raw 'keelson.pro/match-tag=^v=1' 'keelson.pro/match-tag'
    [ "$ANNOTATION_RAW" = '^v=1' ]
}

@test "lookup: a backslash in the value survives" {
    annotation_lookup_raw 'keelson.pro/match-tag=^1\.' 'keelson.pro/match-tag'
    [ "$ANNOTATION_RAW" = '^1\.' ]
}

@test "has-prefix: finds a prefix on the first line" {
    annotation_has_prefix 'keel.sh/policy=all
keelson.pro/policy=minor' 'keel.sh/'
}

@test "has-prefix: finds a prefix on the last line" {
    annotation_has_prefix 'keelson.pro/policy=minor
keel.sh/policy=all' 'keel.sh/'
}

@test "has-prefix: absent prefix returns 1" {
    run annotation_has_prefix 'keelson.pro/policy=minor' 'keel.sh/'
    [ "$status" -eq 1 ]
}

@test "has-prefix: empty input returns 1" {
    run annotation_has_prefix '' 'keel.sh/'
    [ "$status" -eq 1 ]
}

@test "has-prefix: a prefix only inside a value does not count" {
    run annotation_has_prefix 'keelson.pro/notify=migrate off keel.sh/' 'keel.sh/'
    [ "$status" -eq 1 ]
}

# --- both spellings of the same key ---
#
# camelCase is canonical, the hyphenated form is accepted. Carrying both with
# different values is not a precedence puzzle to be resolved quietly: whichever
# was picked would be somebody's surprise, so the workload is not managed.

@test "spelling: the canonical form is read" {
    annotation_get 'keelson.pro/matchTag=^1\.' matchTag
    [ "$ANNOTATION_VALUE" = '^1\.' ]
}

@test "spelling: the hyphenated form is read too" {
    annotation_get 'keelson.pro/match-tag=^1\.' matchTag
    [ "$ANNOTATION_VALUE" = '^1\.' ]
}

@test "spelling: both with the same value is accepted" {
    annotation_get 'keelson.pro/matchTag=^1\.
keelson.pro/match-tag=^1\.' matchTag
    [ "$ANNOTATION_VALUE" = '^1\.' ]
}

@test "spelling: both with the same value warns about the older one" {
    run emit annotation_get 'keelson.pro/matchTag=^1\.
keelson.pro/match-tag=^1\.' matchTag
    [[ "$output" == *"older spelling"* ]]
}

@test "spelling: both with different values is rejected" {
    annotation_get 'keelson.pro/matchTag=^1\.
keelson.pro/match-tag=^2\.' matchTag
    [ "$ANNOTATION_VALUE" = 'REJECT:annotation-spelling-conflict' ]
}

@test "spelling: a conflict says both keys and both values" {
    run emit annotation_get 'keelson.pro/matchTag=^1\.
keelson.pro/match-tag=^2\.' matchTag
    [[ "$output" == *"pick one spelling"* ]]
    [[ "$output" == *'^1\.'* ]]
    [[ "$output" == *'^2\.'* ]]
}

@test "spelling: a conflict is an error, not a crash" {
    local rc=0
    annotation_get 'keelson.pro/matchTag=a
keelson.pro/match-tag=b' matchTag || rc=$?
    [ "$rc" -eq 0 ]
}

@test "spelling: a per-container conflict is caught too" {
    annotation_get 'keelson.pro/matchTag.web=a
keelson.pro/match-tag.web=b' matchTag web
    [ "$ANNOTATION_VALUE" = 'REJECT:annotation-spelling-conflict' ]
}

@test "spelling: a container override beats a workload-wide pair" {
    annotation_get 'keelson.pro/matchTag=^1\.
keelson.pro/match-tag=^2\.
keelson.pro/matchTag.web=^3\.' matchTag web
    [ "$ANNOTATION_VALUE" = '^3\.' ]
}

@test "spelling: policy has no second spelling, so no pair to conflict" {
    annotation_get 'keelson.pro/policy=minor' policy
    [ "$ANNOTATION_VALUE" = "minor" ]
}

@test "spelling: the keel side accepts both as well" {
    KEELSON_CONFIG_MODE=keel annotation_get 'keel.sh/poll-schedule=15m' pollSchedule
    [ "$ANNOTATION_VALUE" = "15m" ]
}

@test "spelling: a keel-side conflict is rejected" {
    KEELSON_CONFIG_MODE=keel annotation_get 'keel.sh/pollSchedule=15m
keel.sh/poll-schedule=30m' pollSchedule
    [ "$ANNOTATION_VALUE" = 'REJECT:annotation-spelling-conflict' ]
}

# --- a workload carrying both prefixes ---
#
# Not an operator-confusion problem: a keel.sh/ annotation is evidence keel may
# be running, and two controllers writing one image field is worse than either
# doing nothing. So neither does, whatever mode Keelson is in.

@test "dual prefix: rejected under config-mode=keelson" {
    annotation_get "$BOTH_LINES" policy
    [ "$ANNOTATION_VALUE" = "REJECT:dual-prefix-conflict" ]
}

@test "dual prefix: rejected under config-mode=keel" {
    KEELSON_CONFIG_MODE=keel annotation_get "$BOTH_LINES" policy
    [ "$ANNOTATION_VALUE" = "REJECT:dual-prefix-conflict" ]
}

@test "dual prefix: unrelated keys on the two prefixes still conflict" {
    # Presence of the prefixes is the signal, not a clash on one key: keel
    # acting on any annotation is enough for both of us to be writing.
    annotation_get 'keelson.pro/policy=minor
keel.sh/pollSchedule=15m' policy
    [ "$ANNOTATION_VALUE" = "REJECT:dual-prefix-conflict" ]
}

@test "dual prefix: one prefix alone is fine in keelson mode" {
    annotation_get "$KEELSON_LINES" policy
    [ "$ANNOTATION_VALUE" = "minor" ]
}

@test "dual prefix: one prefix alone is fine in keel mode" {
    KEELSON_CONFIG_MODE=keel annotation_get "$KEEL_LINES" policy
    [ "$ANNOTATION_VALUE" = "major" ]
}

@test "dual prefix: it is a skip, not a crash" {
    local rc=0
    annotation_get "$BOTH_LINES" policy || rc=$?
    [ "$rc" -eq 0 ]
}

@test "dual prefix: an invalid mode is still reported as such" {
    local rc=0
    KEELSON_CONFIG_MODE=junk annotation_get "$BOTH_LINES" policy || rc=$?
    [ "$rc" -eq 2 ]
}
