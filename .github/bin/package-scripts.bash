#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# prePackagePrepare hook: packages src/scripts/ as a multi-arch FROM-scratch
# OCI image and produces a zip of the same content for the GitHub release.
#
# Delegates the build to buildon's util/docker-package-multi-arch which
# generates the Dockerfile on the fly, builds per-arch, and registers URIs
# for the consolidated push step.

set -euo pipefail

: "${BUILD_SCRIPTS_REPO_ROOT:?BUILD_SCRIPTS_REPO_ROOT is required}"
: "${DOCKER_TARGET_REGISTRY:?DOCKER_TARGET_REGISTRY is required}"
: "${DOCKER_IMAGE_NAME:?DOCKER_IMAGE_NAME is required}"
: "${DOCKER_TAG:?DOCKER_TAG is required}"
: "${OUTPUT_SUB_PATH:?OUTPUT_SUB_PATH is required}"
DOCKER_TARGET_NAMESPACE="${DOCKER_TARGET_NAMESPACE:-}"

if [[ -n "${DOCKER_TARGET_NAMESPACE}" ]]; then
  IMAGE_URI="${DOCKER_TARGET_REGISTRY}/${DOCKER_TARGET_NAMESPACE}/${DOCKER_IMAGE_NAME}:${DOCKER_TAG}"
else
  IMAGE_URI="${DOCKER_TARGET_REGISTRY}/${DOCKER_IMAGE_NAME}:${DOCKER_TAG}"
fi

"${BUILD_SCRIPTS_REPO_ROOT}/src/scripts/util/docker-package-multi-arch" \
  src/scripts "${IMAGE_URI}"

RELEASE_ZIP="${OUTPUT_SUB_PATH}/keelson-scripts.zip"
mkdir -p "${OUTPUT_SUB_PATH}"
(cd src/scripts && zip -qr "${OLDPWD}/${RELEASE_ZIP}" .)
zip_count=$(unzip -l "${RELEASE_ZIP}" | tail -1 | awk '{print $2}')
echo "Created ${RELEASE_ZIP} with ${zip_count} files"
