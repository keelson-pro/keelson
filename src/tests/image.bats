#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/image.bash
    source "${SCRIPT_DIR}/lib/image.bash"
}

# --- image_repo ---

@test "image_repo: plain name with tag" {
    image_repo "nginx:1.2.3"
    [ "$IMAGE_REPO" = "nginx" ]
}

@test "image_repo: host/path with tag" {
    image_repo "ghcr.io/keelson/keelson:1.36.1"
    [ "$IMAGE_REPO" = "ghcr.io/keelson/keelson" ]
}

@test "image_repo: host with port and tag" {
    image_repo "registry.local:5000/team/app:1.2"
    [ "$IMAGE_REPO" = "registry.local:5000/team/app" ]
}

@test "image_repo: digest-only ref" {
    image_repo "nginx@sha256:abc123"
    [ "$IMAGE_REPO" = "nginx" ]
}

@test "image_repo: tag + digest" {
    image_repo "nginx:1.2.3@sha256:abc123"
    [ "$IMAGE_REPO" = "nginx" ]
}

@test "image_repo: no tag, no digest" {
    image_repo "ghcr.io/keelson/keelson"
    [ "$IMAGE_REPO" = "ghcr.io/keelson/keelson" ]
}

# --- image_tag ---

@test "image_tag: tag present" {
    image_tag "nginx:1.2.3"
    [ "$IMAGE_TAG" = "1.2.3" ]
}

@test "image_tag: no tag" {
    image_tag "nginx"
    [ -z "$IMAGE_TAG" ]
}

@test "image_tag: tag with host:port" {
    image_tag "registry.local:5000/team/app:1.2"
    [ "$IMAGE_TAG" = "1.2" ]
}

@test "image_tag: digest-only ref has no tag" {
    image_tag "nginx@sha256:abc"
    [ -z "$IMAGE_TAG" ]
}

# --- image_digest ---

@test "image_digest: present" {
    image_digest "nginx@sha256:abc"
    [ "$IMAGE_DIGEST" = "sha256:abc" ]
}

@test "image_digest: absent" {
    image_digest "nginx:1.2.3"
    [ -z "$IMAGE_DIGEST" ]
}

# --- image_host ---

@test "image_host: explicit host with dot" {
    image_host "ghcr.io/keelson/keelson:1.0"
    [ "$IMAGE_HOST" = "ghcr.io" ]
}

@test "image_host: host with port" {
    image_host "registry.local:5000/team/app:1.0"
    [ "$IMAGE_HOST" = "registry.local:5000" ]
}

@test "image_host: localhost" {
    image_host "localhost/team/app:1.0"
    [ "$IMAGE_HOST" = "localhost" ]
}

@test "image_host: implicit docker.io for short name" {
    image_host "nginx:1.0"
    [ "$IMAGE_HOST" = "docker.io" ]
}

@test "image_host: implicit docker.io for library/name" {
    image_host "library/nginx:1.0"
    [ "$IMAGE_HOST" = "docker.io" ]
}

# --- image_skip_reason ---

@test "image_skip_reason: digest-pinned" {
    image_skip_reason "nginx@sha256:abc"
    [ "$IMAGE_SKIP_REASON" = "tag-is-digest-pinned" ]
}

@test "image_skip_reason: digest+tag is still digest-pinned" {
    image_skip_reason "nginx:1.2.3@sha256:abc"
    [ "$IMAGE_SKIP_REASON" = "tag-is-digest-pinned" ]
}

@test "image_skip_reason: no tag" {
    image_skip_reason "nginx"
    [ "$IMAGE_SKIP_REASON" = "no-tag" ]
}

@test "image_skip_reason: latest" {
    image_skip_reason "nginx:latest"
    [ "$IMAGE_SKIP_REASON" = "tag-is-latest" ]
}

@test "image_skip_reason: v-prefixed tag is non-numeric" {
    image_skip_reason "nginx:v1.2.3"
    [ "$IMAGE_SKIP_REASON" = "tag-has-non-numeric-segment" ]
}

@test "image_skip_reason: alphanumeric tag is non-numeric" {
    image_skip_reason "nginx:stable"
    [ "$IMAGE_SKIP_REASON" = "tag-has-non-numeric-segment" ]
}

@test "image_skip_reason: 3-segment numeric is OK" {
    image_skip_reason "nginx:1.2.3"
    [ -z "$IMAGE_SKIP_REASON" ]
}

@test "image_skip_reason: 4-segment numeric is OK" {
    image_skip_reason "ghcr.io/keelson/keelson:1.36.1.0"
    [ -z "$IMAGE_SKIP_REASON" ]
}

@test "image_skip_reason: single-segment numeric is OK" {
    image_skip_reason "nginx:7"
    [ -z "$IMAGE_SKIP_REASON" ]
}
