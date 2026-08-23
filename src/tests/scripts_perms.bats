#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# Entry scripts must be executable; sourced libs must not be.

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
}

@test "entry script: keelson is executable" {
    [ -x "${SCRIPT_DIR}/keelson" ]
}

@test "entry script: keelson-boot-scan is executable" {
    [ -x "${SCRIPT_DIR}/keelson-boot-scan" ]
}

@test "entry script: keelson-update-resource is executable" {
    [ -x "${SCRIPT_DIR}/keelson-update-resource" ]
}

@test "entry script: keelson-validate is executable" {
    [ -x "${SCRIPT_DIR}/keelson-validate" ]
}

@test "entry script: keelson-probe is executable" {
    [ -x "${SCRIPT_DIR}/keelson-probe" ]
}

@test "entry script: --help on keelson exits 0" {
    run "${SCRIPT_DIR}/keelson" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ Usage: ]]
}

@test "entry script: --help on keelson-boot-scan exits 0" {
    run "${SCRIPT_DIR}/keelson-boot-scan" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ Usage: ]]
}

@test "entry script: --help on keelson-update-resource exits 0" {
    run "${SCRIPT_DIR}/keelson-update-resource" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ Usage: ]]
}

@test "entry script: --help on keelson-validate exits 0" {
    run "${SCRIPT_DIR}/keelson-validate" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ Usage: ]]
}

@test "entry script: --help on keelson-probe exits 0" {
    run "${SCRIPT_DIR}/keelson-probe" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ Usage: ]]
}

@test "lib: no file under src/scripts/lib/ is executable" {
    while IFS= read -r f; do
        if [ -x "$f" ]; then
            printf 'unexpected executable lib file: %s\n' "$f" >&2
            return 1
        fi
    done < <(find "${SCRIPT_DIR}/lib" -type f)
}

@test "lib: every file under src/scripts/lib/ ends in .bash" {
    while IFS= read -r f; do
        case "$f" in
            *.bash) ;;
            *) printf 'non-.bash file under lib/: %s\n' "$f" >&2; return 1 ;;
        esac
    done < <(find "${SCRIPT_DIR}/lib" -type f)
}

# yq's default output format is changing: with -p=json and no -o it currently
# emits YAML "for backwards compatibility" and warns that it will not forever.
# Under JSON output every string comes back quoted, so a namespace becomes
# "default" and Keelson goes on running against names that no longer exist.
# Most of these calls already suppress stderr for other reasons, so the
# warning yq is shouting today is swallowed everywhere.

@test "yq: every invocation states its output format" {
    # An invocation is yq followed by a flag or a quoted expression, which
    # excludes prose mentioning yq and lists that merely name the binary.
    local offenders
    offenders=$(grep -rnE "yq[[:space:]]+[-'\"]" "${SCRIPT_DIR}" \
        | grep -v ':[0-9]*:[[:space:]]*#' \
        | grep -v -- '--version' \
        | grep -v -- '-o=' || true)
    [ -z "$offenders" ] || {
        printf 'yq calls relying on the default output format:\n%s\n' "$offenders"
        return 1
    }
}
