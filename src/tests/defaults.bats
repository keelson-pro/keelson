#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# The Kaptain defaults and the manifests that read them must agree: a default
# nothing reads is a setting that does nothing, and a reference with no
# default renders empty, which boot validation then refuses.

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
}

# Read by the manifests but supplied by the deployment, never defaulted:
# PackageVersion is picked to match the cluster's kubectl window, and the
# registry comes from the environment the package is installed into.
NOT_DEFAULTED="EnvironmentDockerRegistry PackageVersion"

referenced() {
    grep -oh '\${Keelson/[A-Za-z]*}' "$ROOT"/src/kubernetes/*.yaml \
        | sed 's/^\${Keelson\///; s/}$//' | sort -u
}

@test "defaults: every default is read by a manifest" {
    local f name missing=""
    for f in "$ROOT"/src/defaults/Keelson/*; do
        name=${f##*/}
        grep -qx -- "$name" <<<"$(referenced)" || missing+=" $name"
    done
    [ -z "$missing" ] || { echo "defaults no manifest reads:$missing"; return 1; }
}

@test "defaults: every setting a manifest reads has a default" {
    local name missing=""
    while read -r name; do
        case " $NOT_DEFAULTED " in *" $name "*) continue ;; esac
        [ -e "$ROOT/src/defaults/Keelson/$name" ] || missing+=" $name"
    done <<<"$(referenced)"
    [ -z "$missing" ] || { echo "settings with no default:$missing"; return 1; }
}

@test "defaults: no default ends in a newline" {
    # Kaptain substitutes the file's bytes, so a newline would end up inside
    # the quoted env value.
    local f bad=""
    for f in "$ROOT"/src/defaults/Keelson/*; do
        [ -s "$f" ] || continue
        [ "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" != '\n' ] || bad+=" ${f##*/}"
    done
    [ -z "$bad" ] || { echo "defaults ending in a newline:$bad"; return 1; }
}

@test "defaults: every setting validation checks by name is set by the manifest" {
    # A name the manifest spells differently leaves the setting empty, and
    # boot validation then refuses to start.
    local name missing="" checked looped
    checked=$(grep -oE 'validate_env_(set|enum)[[:space:]]+KEELSON_[A-Z_]+' "$ROOT/src/scripts/lib/validate.bash" \
        | awk '{print $2}' | sort -u)
    # And the names its for var in ... loops check, which span lines up to
    # their ; do. KEELSON_VERSION and KEELSON_PACKAGE_VERSION are left out
    # deliberately: the keelson-package build bakes them into the image, and
    # the manifest has no business setting either.
    looped=$(awk '/^[ \t]*for var in /{f=1} f{print} f && /; do/{f=0}' "$ROOT/src/scripts/lib/validate.bash" \
        | grep -oE '(KEELSON|AWS)_[A-Z0-9_]+' \
        | grep -vxE 'KEELSON_(PACKAGE_)?VERSION' | sort -u)
    grep -q KEELSON_TICK_INTERVAL <<<"$looped"
    grep -q KEELSON_LOG_ERROR_REPEAT_INTERVAL <<<"$looped"
    grep -q AWS_ECR_CACHE_DIR <<<"$looped"
    checked=$(printf '%s\n%s\n' "$checked" "$looped" | sort -u)
    [ -n "$checked" ]
    grep -q KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED <<<"$checked"
    while read -r name; do
        grep -qE "^[[:space:]]*- name: ${name}\$" "$ROOT/src/kubernetes/deployment.yaml" || missing+=" $name"
    done <<<"$checked"
    [ -z "$missing" ] || { echo "settings validation checks that the manifest does not set:$missing"; return 1; }
}
