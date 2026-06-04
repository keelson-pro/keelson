#!/usr/bin/env bats

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/image.bash
    source "${SCRIPT_DIR}/lib/image.bash"
}

# --- image_repo ---

@test "image_repo: plain name with tag" {
    run image_repo "nginx:1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "nginx" ]
}

@test "image_repo: host/path with tag" {
    run image_repo "ghcr.io/keelson/keelson:1.36.1"
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/keelson/keelson" ]
}

@test "image_repo: host with port and tag" {
    run image_repo "registry.local:5000/team/app:1.2"
    [ "$status" -eq 0 ]
    [ "$output" = "registry.local:5000/team/app" ]
}

@test "image_repo: digest-only ref" {
    run image_repo "nginx@sha256:abc123"
    [ "$status" -eq 0 ]
    [ "$output" = "nginx" ]
}

@test "image_repo: tag + digest" {
    run image_repo "nginx:1.2.3@sha256:abc123"
    [ "$status" -eq 0 ]
    [ "$output" = "nginx" ]
}

@test "image_repo: no tag, no digest" {
    run image_repo "ghcr.io/keelson/keelson"
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/keelson/keelson" ]
}

# --- image_tag ---

@test "image_tag: tag present" {
    run image_tag "nginx:1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
}

@test "image_tag: no tag" {
    run image_tag "nginx"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "image_tag: tag with host:port" {
    run image_tag "registry.local:5000/team/app:1.2"
    [ "$status" -eq 0 ]
    [ "$output" = "1.2" ]
}

@test "image_tag: digest-only ref has no tag" {
    run image_tag "nginx@sha256:abc"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- image_digest ---

@test "image_digest: present" {
    run image_digest "nginx@sha256:abc"
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:abc" ]
}

@test "image_digest: absent" {
    run image_digest "nginx:1.2.3"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- image_host ---

@test "image_host: explicit host with dot" {
    run image_host "ghcr.io/keelson/keelson:1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io" ]
}

@test "image_host: host with port" {
    run image_host "registry.local:5000/team/app:1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "registry.local:5000" ]
}

@test "image_host: localhost" {
    run image_host "localhost/team/app:1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "localhost" ]
}

@test "image_host: implicit docker.io for short name" {
    run image_host "nginx:1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "docker.io" ]
}

@test "image_host: implicit docker.io for library/name" {
    run image_host "library/nginx:1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "docker.io" ]
}

# --- image_skip_reason ---

@test "image_skip_reason: digest-pinned" {
    run image_skip_reason "nginx@sha256:abc"
    [ "$status" -eq 0 ]
    [ "$output" = "tag-is-digest-pinned" ]
}

@test "image_skip_reason: digest+tag is still digest-pinned" {
    run image_skip_reason "nginx:1.2.3@sha256:abc"
    [ "$status" -eq 0 ]
    [ "$output" = "tag-is-digest-pinned" ]
}

@test "image_skip_reason: no tag" {
    run image_skip_reason "nginx"
    [ "$status" -eq 0 ]
    [ "$output" = "no-tag" ]
}

@test "image_skip_reason: latest" {
    run image_skip_reason "nginx:latest"
    [ "$status" -eq 0 ]
    [ "$output" = "tag-is-latest" ]
}

@test "image_skip_reason: v-prefixed tag is non-numeric" {
    run image_skip_reason "nginx:v1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "tag-has-non-numeric-segment" ]
}

@test "image_skip_reason: alphanumeric tag is non-numeric" {
    run image_skip_reason "nginx:stable"
    [ "$status" -eq 0 ]
    [ "$output" = "tag-has-non-numeric-segment" ]
}

@test "image_skip_reason: 3-segment numeric is OK" {
    run image_skip_reason "nginx:1.2.3"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "image_skip_reason: 4-segment numeric is OK" {
    run image_skip_reason "ghcr.io/keelson/keelson:1.36.1.0"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "image_skip_reason: single-segment numeric is OK" {
    run image_skip_reason "nginx:7"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
