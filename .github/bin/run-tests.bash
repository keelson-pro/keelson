#!/usr/bin/env bash
# Lint and test the Keelson scripts.
# shellcheck runs locally (small enough not to warrant a container);
# bats runs in our test image (needs real yq + our shimming conventions).
# Container runtime follows buildon-github-actions: IMAGE_BUILD_COMMAND env, default podman.
# Runs from any CWD: resolves the repo root from this script's location.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

IMAGE_BUILD_COMMAND="${IMAGE_BUILD_COMMAND:-podman}"
TEST_IMAGE="${KEELSON_TEST_IMAGE:-ghcr.io/keelson-pro/keelson/keelson-test-image:1.1}"

ENTRY_SCRIPTS=(
    src/scripts/keelson
    src/scripts/keelson-boot-scan
    src/scripts/keelson-update-resource
)

printf '== shellcheck (entry scripts + sourced libs via -x) ==\n'
if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'shellcheck not found on PATH - install it locally (brew install shellcheck / apt install shellcheck)\n' >&2
    exit 1
fi
shellcheck --shell=bash --external-sources --source-path=SCRIPTDIR "${ENTRY_SCRIPTS[@]}"

printf '== bats (src/tests/) ==\n'
if ! command -v "$IMAGE_BUILD_COMMAND" >/dev/null 2>&1; then
    printf '%s not found on PATH - install it or override IMAGE_BUILD_COMMAND\n' "$IMAGE_BUILD_COMMAND" >&2
    exit 1
fi
"$IMAGE_BUILD_COMMAND" run --rm \
    -v "$REPO_ROOT:/workspace" -w /workspace \
    --entrypoint bats \
    "$TEST_IMAGE" --print-output-on-failure --recursive src/tests
