#!/usr/bin/env bats
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
