#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# Tests for src/scripts/keelson-user-recheck. The script is sourced (its main
# is guarded) and the work it hands off is stubbed, so what is checked is the
# order: nothing is scanned with --apply until the settings validate.

load helper

setup() {
    tmp_dir_init
    # shellcheck source=../scripts/keelson-user-recheck
    source "${BATS_TEST_DIRNAME}/../scripts/keelson-user-recheck"
    # Its own set -u would trip on bats internals; -e must stay.
    set +u
    log_file_init() { :; }
    state_spool_init() { :; }
    state_init() { echo "state_init" >>"$TMP_DIR/calls"; return 0; }
    state_drain_spool() { echo "drain" >>"$TMP_DIR/calls"; }
    state_flush() { echo "flush" >>"$TMP_DIR/calls"; }
    scan_run() { echo "scan_run $*" >>"$TMP_DIR/calls"; }
}

@test "user_recheck: --apply stops before scanning when validation fails" {
    validate_config() { echo "validate" >>"$TMP_DIR/calls"; return 1; }
    run main --apply
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/calls")" = "validate" ]
}

@test "user_recheck: --apply scans with writes once validation passes" {
    validate_config() { echo "validate" >>"$TMP_DIR/calls"; return 0; }
    run main --apply
    [ "$status" -eq 0 ]
    # And, with no tick loop to do it, writes what the scan spooled.
    [ "$(cat "$TMP_DIR/calls")" = $'validate\nstate_init\nscan_run 1 1\ndrain\nflush' ]
}

@test "user_recheck: a dry run neither validates the write settings nor writes" {
    validate_config() { echo "validate" >>"$TMP_DIR/calls"; return 1; }
    run main
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP_DIR/calls")" = "scan_run 0 1" ]
}

@test "user_recheck: an unknown argument exits 64 before anything runs" {
    validate_config() { echo "validate" >>"$TMP_DIR/calls"; return 0; }
    run main --apply --bogus
    [ "$status" -eq 64 ]
    [[ "$output" == *"unknown arg: --bogus"* ]]
    [ ! -e "$TMP_DIR/calls" ]
}

@test "user_recheck: --apply carries on without trigger state when it cannot be set up" {
    validate_config() { echo "validate" >>"$TMP_DIR/calls"; return 0; }
    state_init() { echo "state_init" >>"$TMP_DIR/calls"; return 1; }
    run main --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"continuing without trigger-state"* ]]
    [ "$(cat "$TMP_DIR/calls")" = $'validate\nstate_init\nscan_run 1 1\ndrain\nflush' ]
}

@test "user_recheck: the real validation and its helpers are there to call" {
    run bash -c 'source "$1"; declare -F validate_config registry_key_valid' _ "${BATS_TEST_DIRNAME}/../scripts/keelson-user-recheck"
    [ "$status" -eq 0 ]
    [[ "$output" == *validate_config*registry_key_valid* ]]
}

@test "user_recheck: anything the scan logged as an error exits 1, after writing what it spooled" {
    validate_config() { echo "validate" >>"$TMP_DIR/calls"; return 0; }
    scan_run() { echo "scan_run $*" >>"$TMP_DIR/calls"; SCAN_ERRORS=2; }
    run main --apply
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/calls")" = $'validate\nstate_init\nscan_run 1 1\ndrain\nflush' ]
    rm "$TMP_DIR/calls"
    run main
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP_DIR/calls")" = "scan_run 0 1" ]
}

@test "user_recheck: a pass with no errors exits 0, dry run or not" {
    validate_config() { return 0; }
    scan_run() { SCAN_ERRORS=0; }
    run main
    [ "$status" -eq 0 ]
    run main --apply
    [ "$status" -eq 0 ]
}
