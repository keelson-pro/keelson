#!/usr/bin/env bash
# Lint and test the Keelson scripts.
# Linting runs locally via shellcheck (small enough not to warrant a
# container); a comment must never open with the tool's own name, or it
# parses as a malformed directive and the whole file goes unchecked.
# bats runs in our test image (needs real yq + our shimming conventions).
# Container runtime follows buildon-github-actions: IMAGE_BUILD_COMMAND env, default podman.
# Runs from any CWD: resolves the repo root from this script's location.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

IMAGE_BUILD_COMMAND="${IMAGE_BUILD_COMMAND:-podman}"
TEST_IMAGE="${KEELSON_TEST_IMAGE:-ghcr.io/keelson-pro/keelson/keelson-test-image:1.1}"

# Derived, not hand-listed: a hand-listed set silently skips new files,
# which is how keelson-probe and keelson-validate went unlinted.
#
# Entry scripts are exactly the executable files at the top of src/scripts;
# lib/ is reached transitively via --external-sources, and
# src/tests/scripts_perms.bats enforces both halves of that convention.
# The build scripts in here lint themselves too - they are the only bash in
# the repo nothing else covers.
SHELL_SCRIPTS=()
for candidate in src/scripts/*; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
        SHELL_SCRIPTS+=("$candidate")
    fi
done
for candidate in .github/bin/*.bash; do
    if [ -f "$candidate" ]; then
        SHELL_SCRIPTS+=("$candidate")
    fi
done
if [ "${#SHELL_SCRIPTS[@]}" -eq 0 ]; then
    printf 'no shell scripts found to lint\n' >&2
    exit 1
fi

printf '== shellcheck (entry + build scripts, sourced libs via -x) ==\n'
if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'shellcheck not found on PATH - install it locally (brew install shellcheck / apt install shellcheck)\n' >&2
    exit 1
fi
shellcheck --shell=bash --external-sources --source-path=SCRIPTDIR "${SHELL_SCRIPTS[@]}"

printf '== bats (src/tests/) ==\n'
if ! command -v "$IMAGE_BUILD_COMMAND" >/dev/null 2>&1; then
    printf '%s not found on PATH - install it or override IMAGE_BUILD_COMMAND\n' "$IMAGE_BUILD_COMMAND" >&2
    exit 1
fi
"$IMAGE_BUILD_COMMAND" run --rm \
    -v "$REPO_ROOT:/workspace" -w /workspace \
    --entrypoint bats \
    "$TEST_IMAGE" --print-output-on-failure --recursive src/tests
