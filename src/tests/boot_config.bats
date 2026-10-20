#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# Tests for the configuration lines src/scripts/keelson logs at boot. The
# entry script is sourced in a child bash, so its set -euo pipefail and its
# functions stay out of the test shell.

load helper

setup() {
    tmp_dir_init
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
}

# boot_config <VAR=value...>
# Runs log_boot_config with only the given settings, in a clean environment
# so nothing the runner exported can stand in for one, and prints the lines.
boot_config() {
    env -i PATH="$PATH" "$@" KEELSON_LOG_FILE_PATH= KEELSON_LOG_FORMAT=plain \
        bash -c 'source "$1"; set +u; log_boot_config 2>&1' _ "$SCRIPT_DIR/keelson"
}

@test "boot config: a claim on the apply-owned setting carries the conflict note" {
    run boot_config KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch
    [ "$status" -eq 0 ]
    [[ "$output" =~ field-manager-strategy-apply-owned\ +=\ claim-patch\ \ \(owner\'s\ next\ deploy\ will\ conflict\) ]]
}

@test "boot config: claim-apply on the apply-owned setting carries the note too" {
    run boot_config KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-apply
    [ "$status" -eq 0 ]
    [[ "$output" =~ field-manager-strategy-apply-owned\ +=\ claim-apply\ \ \(owner\'s\ next\ deploy\ will\ conflict\) ]]
}

@test "boot config: each field-manager setting is logged exactly once" {
    run boot_config KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=mimic
    [ "$status" -eq 0 ]
    local name
    for name in apply-owned update-owned unowned mimic-annotation-fallback-allowed; do
        [ "$(grep -c "field-manager-strategy-$name " <<<"$output")" -eq 1 ]
    done
    # The old two-setting line is gone.
    [ "$(grep -c "field-manager-strategy-owned " <<<"$output")" -eq 0 ]
}

@test "boot config: mimic on the apply-owned setting carries no note" {
    run boot_config KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=mimic
    [ "$status" -eq 0 ]
    [[ "$output" =~ field-manager-strategy-apply-owned\ +=\ mimic ]]
    [[ "$output" != *"will conflict"* ]]
}

@test "boot config: a claim on the update-owned setting carries no note" {
    # An Update owner is never refused anything, so there is nothing to say.
    run boot_config KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=claim-apply \
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-apply
    [ "$status" -eq 0 ]
    [[ "$output" =~ field-manager-strategy-update-owned\ +=\ claim-apply ]]
    [[ "$output" != *"will conflict"* ]]
}

@test "boot config: every field-manager setting is logged" {
    run boot_config KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=mimic \
        KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED=mimic \
        KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED=claim-patch \
        KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED=true
    [ "$status" -eq 0 ]
    [[ "$output" =~ field-manager-strategy-apply-owned\ +=\ mimic ]]
    [[ "$output" =~ field-manager-strategy-update-owned\ +=\ mimic ]]
    [[ "$output" =~ field-manager-strategy-unowned\ +=\ claim-patch ]]
    [[ "$output" =~ field-manager-strategy-mimic-annotation-fallback-allowed\ +=\ true ]]
}

@test "boot config: the note is in the message, not in the value" {
    run env -i PATH="$PATH" KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=claim-patch \
        KEELSON_LOG_FILE_PATH= KEELSON_LOG_FORMAT=json \
        bash -c 'source "$1"; set +u; log_boot_config 2>&1' _ "$SCRIPT_DIR/keelson"
    [ "$status" -eq 0 ]
    local line
    line=$(grep '"setting":"field-manager-strategy-apply-owned"' <<<"$output")
    [[ "$line" == *'"value":"claim-patch",'* ]]
    [[ "$line" == *"(owner's next deploy will conflict)"* ]]
}

# controller_main <validate-status>: the controller's main in a child bash,
# with validation stubbed to <validate-status> and everything after the boot
# lines stubbed out, printing which steps ran.
controller_main() {
    env -i PATH="$PATH" KEELSON_LOG_FILE_PATH= KEELSON_LOG_FORMAT=plain RC="$1" \
        bash -c 'source "$1"; set +u
            validate_config() { echo STEP:validate; return "$RC"; }
            log_boot_config() { echo STEP:boot-config; }
            state_own_namespace() { :; }
            queue_init() { :; }; inventory_init() { :; }; status_init() { :; }
            state_spool_init() { :; }; state_init() { :; }
            loop_run() { echo STEP:loop; }
            main 2>&1' _ "$SCRIPT_DIR/keelson"
}

@test "controller: main validates, then logs its settings, then runs" {
    run controller_main 0
    [ "$status" -eq 0 ]
    [ "$(grep '^STEP:' <<<"$output" | tr '\n' ' ')" = "STEP:validate STEP:boot-config STEP:loop " ]
}

@test "controller: a failed validation stops it before anything else" {
    run controller_main 1
    [ "$status" -ne 0 ]
    [ "$(grep '^STEP:' <<<"$output" | tr '\n' ' ')" = "STEP:validate " ]
}

@test "boot config: a line with no note ends at its value" {
    run boot_config KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED=mimic
    [ "$status" -eq 0 ]
    local line
    line=$(grep "field-manager-strategy-apply-owned " <<<"$output")
    [[ "$line" == *"= mimic" ]]
    [[ "$output" != *"()"* ]]
}

@test "boot config: the fallback setting is logged as set, false included" {
    local v
    for v in true false; do
        run boot_config KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED=$v
        [ "$status" -eq 0 ]
        [[ "$output" =~ field-manager-strategy-mimic-annotation-fallback-allowed\ +=\ $v($'\n'|$) ]] || { echo "$v: $output"; return 1; }
    done
}
