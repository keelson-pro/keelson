# Image reference parsing for Keelson.
# Sourced; not directly executable.
#
# Docker reference grammar (informally):
#   reference := [host[":"port]"/"] path [":" tag] ["@" digest]
# The tag-separating ":" is always after the last "/" (port colons sit
# inside the host, which sits before the last "/").

# image_digest <ref>
# Echoes the digest (e.g. sha256:abc...) if present, else empty.
image_digest() {
    case "$1" in
        *@*) printf '%s' "${1#*@}" ;;
    esac
}

# image_repo <ref>
# Echoes the repo portion: host/path, with any :tag and @digest stripped.
image_repo() {
    local ref=$1 without_digest after_slash
    without_digest=${ref%%@*}
    after_slash=${without_digest##*/}
    if [[ "$after_slash" == *:* ]]; then
        local tag=${after_slash##*:}
        printf '%s' "${without_digest:0:$((${#without_digest} - ${#tag} - 1))}"
    else
        printf '%s' "$without_digest"
    fi
}

# image_tag <ref>
# Echoes the tag if present, else empty.
image_tag() {
    local ref=$1 without_digest after_slash
    without_digest=${ref%%@*}
    after_slash=${without_digest##*/}
    if [[ "$after_slash" == *:* ]]; then
        printf '%s' "${after_slash##*:}"
    fi
}

# image_host <ref>
# Echoes the registry hostname (with port if present).
# For refs with no explicit host, echoes "docker.io" (Docker's default).
image_host() {
    local repo
    repo=$(image_repo "$1")
    case "$repo" in
        */*)
            local first=${repo%%/*}
            # Heuristic: a host has a ".", a ":", or is "localhost".
            case "$first" in
                *.*|*:*|localhost) printf '%s' "$first" ;;
                *) printf 'docker.io' ;;
            esac
            ;;
        *)
            printf 'docker.io'
            ;;
    esac
}

# image_skip_reason <ref>
# Echoes a skip-reason if the image should not be considered for updates;
# empty if the image is updatable. Always returns 0.
#
# Skip reasons (in priority order):
#   tag-is-digest-pinned          - "@sha256:..." present (regardless of tag)
#   no-tag                        - no ":<tag>" at all
#   tag-is-latest                 - tag literal is "latest"
#   tag-has-non-numeric-segment   - tag splits on "." but a segment is non-int
image_skip_reason() {
    local ref=$1
    if [ -n "$(image_digest "$ref")" ]; then
        printf 'tag-is-digest-pinned'
        return 0
    fi
    local tag
    tag=$(image_tag "$ref")
    if [ -z "$tag" ]; then
        printf 'no-tag'
        return 0
    fi
    if [ "$tag" = "latest" ]; then
        printf 'tag-is-latest'
        return 0
    fi
    local IFS='.'
    # shellcheck disable=SC2206
    local segs=($tag)
    if [ ${#segs[@]} -eq 0 ]; then
        printf 'tag-has-non-numeric-segment'
        return 0
    fi
    local seg
    for seg in "${segs[@]}"; do
        case "$seg" in
            ''|*[!0-9]*)
                printf 'tag-has-non-numeric-segment'
                return 0
                ;;
        esac
    done
    printf ''
}
