# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)
#
# Image reference parsing for Keelson.
# Sourced; not directly executable.
#
# Docker reference grammar (informally):
#   reference := [host[":"port]"/"] path [":" tag] ["@" digest]
# The tag-separating ":" is always after the last "/" (port colons sit
# inside the host, which sits before the last "/").
#
# Results land in globals rather than on stdout: this is pure string work on
# the per-container poll path, and returning through a command substitution
# forked a subshell to do it.

IMAGE_DIGEST=
IMAGE_REPO=
IMAGE_TAG=
IMAGE_HOST=
IMAGE_SKIP_REASON=

# image_digest <ref>  -> IMAGE_DIGEST
# The digest (e.g. sha256:abc...) if present, else empty.
image_digest() {
    IMAGE_DIGEST=
    case "$1" in
        *@*) IMAGE_DIGEST=${1#*@} ;;
    esac
}

# image_repo <ref>  -> IMAGE_REPO
# The repo portion: host/path, with any :tag and @digest stripped.
image_repo() {
    local ref=$1 without_digest after_slash
    without_digest=${ref%%@*}
    after_slash=${without_digest##*/}
    if [[ "$after_slash" == *:* ]]; then
        local tag=${after_slash##*:}
        IMAGE_REPO=${without_digest:0:$((${#without_digest} - ${#tag} - 1))}
    else
        IMAGE_REPO=$without_digest
    fi
}

# image_tag <ref>  -> IMAGE_TAG
# The tag if present, else empty.
image_tag() {
    local ref=$1 without_digest after_slash
    without_digest=${ref%%@*}
    after_slash=${without_digest##*/}
    IMAGE_TAG=
    if [[ "$after_slash" == *:* ]]; then
        IMAGE_TAG=${after_slash##*:}
    fi
}

# image_host <ref>  -> IMAGE_HOST
# The registry hostname (with port if present). For refs with no explicit
# host, "docker.io" (Docker's default).
image_host() {
    local repo
    image_repo "$1"
    repo=$IMAGE_REPO
    case "$repo" in
        */*)
            local first=${repo%%/*}
            # Heuristic: a host has a ".", a ":", or is "localhost".
            case "$first" in
                *.*|*:*|localhost) IMAGE_HOST=$first ;;
                *) IMAGE_HOST='docker.io' ;;
            esac
            ;;
        *)
            IMAGE_HOST='docker.io'
            ;;
    esac
}

# image_skip_reason <ref>  -> IMAGE_SKIP_REASON
# A skip-reason if the image should not be considered for updates; empty if
# the image is updatable. Always returns 0.
#
# Skip reasons (in priority order):
#   tag-is-digest-pinned          - "@sha256:..." present (regardless of tag)
#   no-tag                        - no ":<tag>" at all
#   tag-is-latest                 - tag literal is "latest"
#   tag-has-non-numeric-segment   - tag splits on "." but a segment is non-int
image_skip_reason() {
    local ref=$1
    IMAGE_SKIP_REASON=
    image_digest "$ref"
    if [ -n "$IMAGE_DIGEST" ]; then
        IMAGE_SKIP_REASON='tag-is-digest-pinned'
        return 0
    fi
    local tag
    image_tag "$ref"
    tag=$IMAGE_TAG
    if [ -z "$tag" ]; then
        IMAGE_SKIP_REASON='no-tag'
        return 0
    fi
    if [ "$tag" = "latest" ]; then
        IMAGE_SKIP_REASON='tag-is-latest'
        return 0
    fi
    local IFS='.'
    # shellcheck disable=SC2206
    local segs=($tag)
    if [ ${#segs[@]} -eq 0 ]; then
        IMAGE_SKIP_REASON='tag-has-non-numeric-segment'
        return 0
    fi
    local seg
    for seg in "${segs[@]}"; do
        case "$seg" in
            ''|*[!0-9]*)
                IMAGE_SKIP_REASON='tag-has-non-numeric-segment'
                return 0
                ;;
        esac
    done
}
