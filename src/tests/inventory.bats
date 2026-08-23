#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

# Tests for lib/inventory.bash: the local workload cache.

load helper

setup() {
    tmp_dir_init
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/clock.bash
    source "$SCRIPT_DIR/lib/clock.bash"
    # shellcheck source=../scripts/lib/inventory.bash
    source "$SCRIPT_DIR/lib/inventory.bash"
    KEELSON_INVENTORY_DIR="$TMP_DIR/inventory"
    inventory_init
}

# Logs are emitted on stderr; merge to stdout so `run` captures them.
emit() { "$@" 2>&1; }

# A workload with one container and two annotations.
put_simple() {
    local next_due=${1:-1700} interval=${2:-60}
    inventory_put Deployment default web "$next_due" "$interval" "" \
        default '[]' \
        "$(printf 'keelson.pro/policy=minor\nkeelson.pro/match-tag=^1\\.')" \
        'containers main=ghcr.io/x/y:1.2.3'
}

# --- put / get ---

@test "put then get round-trips the identity and schedule" {
    put_simple 1700 60
    inventory_get Deployment default web
    [ "$INVENTORY_KIND" = "Deployment" ]
    [ "$INVENTORY_NAMESPACE" = "default" ]
    [ "$INVENTORY_NAME" = "web" ]
    [ "$INVENTORY_NEXT_DUE" = "1700" ]
    [ "$INVENTORY_INTERVAL" = "60" ]
}

@test "put then get round-trips the containers" {
    inventory_put Deployment default web 1700 60 "" default '[]' \
        'keelson.pro/policy=minor' \
        "$(printf 'containers main=ghcr.io/x/y:1.2.3\ncontainers sidecar=ghcr.io/x/z:2.0')"
    inventory_get Deployment default web
    [ "${#INVENTORY_CONTAINER_NAMES[@]}" -eq 2 ]
    [ "${INVENTORY_CONTAINER_NAMES[0]}" = "main" ]
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io/x/y:1.2.3" ]
    [ "${INVENTORY_CONTAINER_NAMES[1]}" = "sidecar" ]
    [ "${INVENTORY_CONTAINER_IMAGES[1]}" = "ghcr.io/x/z:2.0" ]
}

@test "put then get round-trips annotations as annotation_get expects them" {
    put_simple
    inventory_get Deployment default web
    # Newline-separated "<key>=<value>", verbatim from the flattener.
    [ "$(printf '%s' "$INVENTORY_ANNOTATIONS" | grep -c .)" = "2" ]
    printf '%s' "$INVENTORY_ANNOTATIONS" | grep -q '^keelson\.pro/policy=minor$'
    printf '%s' "$INVENTORY_ANNOTATIONS" | grep -q '^keelson\.pro/match-tag=\^1\\\.$'
}

@test "put then get round-trips credentials and suspend" {
    inventory_put CronJob ops backup 1700 60 true \
        builder '[{"name":"regcred"}]' 'keelson.pro/policy=patch' \
        'containers main=ghcr.io/x/y:1.0'
    inventory_get CronJob ops backup
    [ "$INVENTORY_SUSPEND" = "true" ]
    [ "$INVENTORY_SERVICE_ACCOUNT" = "builder" ]
    [ "$INVENTORY_IMAGE_PULL_SECRETS" = '[{"name":"regcred"}]' ]
}

@test "an image reference keeps everything after the first =" {
    inventory_put Deployment default web 1700 60 "" default '[]' \
        'keelson.pro/match-tag=^v1\.2=3$' 'containers main=ghcr.io:5000/x/y:1.0'
    inventory_get Deployment default web
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io:5000/x/y:1.0" ]
    [ "$INVENTORY_ANNOTATIONS" = 'keelson.pro/match-tag=^v1\.2=3$' ]
}

@test "get on an unknown workload returns 1" {
    run inventory_get Deployment default nope
    [ "$status" -eq 1 ]
}

@test "put overwrites an existing entry" {
    put_simple 1700 60
    put_simple 1800 30
    inventory_get Deployment default web
    [ "$INVENTORY_NEXT_DUE" = "1800" ]
    [ "$INVENTORY_INTERVAL" = "30" ]
}

@test "identities in different namespaces are distinct entries" {
    inventory_put Deployment ns1 web 1700 60 "" default '[]' '' 'containers main=a:1'
    inventory_put Deployment ns2 web 1700 60 "" default '[]' '' 'containers main=b:1'
    inventory_get Deployment ns1 web
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "a:1" ]
    inventory_get Deployment ns2 web
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "b:1" ]
}

@test "a workload with no annotations round-trips empty" {
    inventory_put Deployment default web 1700 60 "" default '[]' '' 'containers main=a:1'
    inventory_get Deployment default web
    [ -z "$INVENTORY_ANNOTATIONS" ]
    [ "${#INVENTORY_CONTAINER_NAMES[@]}" -eq 1 ]
}

# --- fingerprint ---

@test "fingerprint covers the image" {
    inventory_put Deployment default web 1700 60 "" default '[]' '' 'containers main=a:1'
    inventory_get Deployment default web
    local first=$INVENTORY_FINGERPRINT
    inventory_put Deployment default web 1700 60 "" default '[]' '' 'containers main=a:2'
    inventory_get Deployment default web
    [ "$INVENTORY_FINGERPRINT" != "$first" ]
}

@test "fingerprint covers the annotations" {
    inventory_put Deployment default web 1700 60 "" default '[]' 'p=minor' 'containers main=a:1'
    inventory_get Deployment default web
    local first=$INVENTORY_FINGERPRINT
    inventory_put Deployment default web 1700 60 "" default '[]' 'p=patch' 'containers main=a:1'
    inventory_get Deployment default web
    [ "$INVENTORY_FINGERPRINT" != "$first" ]
}

@test "fingerprint covers the interval, so a cadence change forces a poll" {
    inventory_put Deployment default web 1700 60 "" default '[]' '' 'containers main=a:1'
    inventory_get Deployment default web
    local first=$INVENTORY_FINGERPRINT
    inventory_put Deployment default web 1700 30 "" default '[]' '' 'containers main=a:1'
    inventory_get Deployment default web
    [ "$INVENTORY_FINGERPRINT" != "$first" ]
}

@test "fingerprint covers the credentials" {
    inventory_put Deployment default web 1700 60 "" default '[]' '' 'containers main=a:1'
    inventory_get Deployment default web
    local first=$INVENTORY_FINGERPRINT
    inventory_put Deployment default web 1700 60 "" default '[{"name":"rc"}]' '' 'containers main=a:1'
    inventory_get Deployment default web
    [ "$INVENTORY_FINGERPRINT" != "$first" ]
}

@test "fingerprint ignores next-due, which moves on every poll" {
    inventory_put Deployment default web 1700 60 "" default '[]' '' 'containers main=a:1'
    inventory_get Deployment default web
    local first=$INVENTORY_FINGERPRINT
    inventory_put Deployment default web 9999 60 "" default '[]' '' 'containers main=a:1'
    inventory_get Deployment default web
    [ "$INVENTORY_FINGERPRINT" = "$first" ]
}

# --- spreading the load ---

@test "first_due lands inside the first interval" {
    inventory_first_due Deployment default web 60 1000
    [ "$INVENTORY_FIRST_DUE" -ge 1000 ]
    [ "$INVENTORY_FIRST_DUE" -lt 1060 ]
}

@test "first_due is stable for the same identity" {
    inventory_first_due Deployment default web 60 1000
    local a=$INVENTORY_FIRST_DUE
    inventory_first_due Deployment default web 60 1000
    [ "$INVENTORY_FIRST_DUE" = "$a" ]
}

@test "first_due differs across identities on the same cadence" {
    # Without an offset every workload cached in the same pass shares a
    # next-due forever, and the registry sees the whole estate at once.
    local seen=""
    local n
    for n in web api worker cache queue router; do
        inventory_first_due Deployment default "$n" 60 1000
        seen="${seen}${INVENTORY_FIRST_DUE}\n"
    done
    local distinct
    distinct=$(printf "$seen" | sort -u | grep -c .)
    [ "$distinct" -ge 4 ]
}

@test "first_due respects a short interval" {
    inventory_first_due Deployment default web 5 1000
    [ "$INVENTORY_FIRST_DUE" -ge 1000 ]
    [ "$INVENTORY_FIRST_DUE" -lt 1005 ]
}

@test "hash is stable and identity-dependent" {
    inventory_hash "Deployment default web"
    local a=$INVENTORY_HASH
    inventory_hash "Deployment default web"
    [ "$INVENTORY_HASH" = "$a" ]
    inventory_hash "Deployment default api"
    [ "$INVENTORY_HASH" != "$a" ]
}

# --- evict ---

@test "evict removes the entry" {
    put_simple
    inventory_evict Deployment default web
    run inventory_get Deployment default web
    [ "$status" -eq 1 ]
}

@test "evict on an unknown workload is a no-op and succeeds" {
    run inventory_evict Deployment default nope
    [ "$status" -eq 0 ]
}

@test "evict leaves other entries alone" {
    put_simple
    inventory_put Deployment default api 1700 60 "" default '[]' '' 'containers main=b:1'
    inventory_evict Deployment default web
    inventory_get Deployment default api
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "b:1" ]
}

# --- next-due scheduling ---

@test "due: nothing is due before its time" {
    put_simple 2000 60
    inventory_due 1999
    [ "${#INVENTORY_DUE[@]}" -eq 0 ]
}

@test "due: an entry at exactly its next-due is due" {
    put_simple 2000 60
    inventory_due 2000
    [ "${#INVENTORY_DUE[@]}" -eq 1 ]
    [ "${INVENTORY_DUE[0]}" = "Deployment default web" ]
}

@test "due: only the overdue entries come back" {
    put_simple 1000 60
    inventory_put Deployment default api 5000 60 "" default '[]' '' 'containers main=b:1'
    inventory_put CronJob ops backup 1000 60 "" default '[]' '' 'containers main=c:1'
    inventory_due 2000
    [ "${#INVENTORY_DUE[@]}" -eq 2 ]
    printf '%s\n' "${INVENTORY_DUE[@]}" | grep -q '^Deployment default web$'
    printf '%s\n' "${INVENTORY_DUE[@]}" | grep -q '^CronJob ops backup$'
    ! printf '%s\n' "${INVENTORY_DUE[@]}" | grep -q 'api'
}

@test "due: an empty inventory yields nothing" {
    inventory_due 2000
    [ "${#INVENTORY_DUE[@]}" -eq 0 ]
}

@test "set_next_due reschedules and preserves the record" {
    put_simple 1000 60
    inventory_set_next_due Deployment default web 4000
    inventory_get Deployment default web
    [ "$INVENTORY_NEXT_DUE" = "4000" ]
    [ "$INVENTORY_INTERVAL" = "60" ]
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io/x/y:1.2.3" ]
    printf '%s' "$INVENTORY_ANNOTATIONS" | grep -q 'policy=minor'
}

@test "mark_polled pushes next-due out by the entry's own interval" {
    put_simple 1000 300
    inventory_mark_polled Deployment default web 2000
    inventory_get Deployment default web
    [ "$INVENTORY_NEXT_DUE" = "2300" ]
    [ "$INVENTORY_INTERVAL" = "300" ]
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io/x/y:1.2.3" ]
}

@test "mark_polled on an unknown workload returns 1" {
    run inventory_mark_polled Deployment default nope 2000
    [ "$status" -eq 1 ]
}

@test "due: a polled entry drops out until its interval elapses" {
    put_simple 1000 300
    inventory_mark_polled Deployment default web 2000
    inventory_due 2299
    [ "${#INVENTORY_DUE[@]}" -eq 0 ]
    inventory_due 2300
    [ "${#INVENTORY_DUE[@]}" -eq 1 ]
}

# --- listing ---

@test "list: emits every identity" {
    put_simple
    inventory_put CronJob ops backup 1000 60 "" default '[]' '' 'containers main=b:1'
    inventory_list
    [ "${#INVENTORY_ALL[@]}" -eq 2 ]
}

@test "list: an empty inventory yields nothing" {
    inventory_list
    [ "${#INVENTORY_ALL[@]}" -eq 0 ]
}

@test "init is idempotent and keeps existing entries" {
    put_simple
    inventory_init
    inventory_get Deployment default web
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "ghcr.io/x/y:1.2.3" ]
}

@test "enabled is false before init and true after" {
    rm -rf "$KEELSON_INVENTORY_DIR"
    run inventory_enabled
    [ "$status" -eq 1 ]
    inventory_init
    run inventory_enabled
    [ "$status" -eq 0 ]
}

# --- full refresh support ---

@test "evict_kind: drops every entry of one kind and no others" {
    inventory_put Deployment default web 1000 60 "" default '[]' '' 'containers main=a:1'
    inventory_put Deployment other api 1000 60 "" default '[]' '' 'containers main=b:1'
    inventory_put CronJob ops backup 1000 60 "" default '[]' '' 'containers main=c:1'
    inventory_evict_kind Deployment
    run inventory_get Deployment default web
    [ "$status" -eq 1 ]
    run inventory_get Deployment other api
    [ "$status" -eq 1 ]
    run inventory_get CronJob ops backup
    [ "$status" -eq 0 ]
}

@test "evict_kind: an unknown kind is a no-op" {
    inventory_put Deployment default web 1000 60 "" default '[]' '' 'containers main=a:1'
    run inventory_evict_kind StatefulSet
    [ "$status" -eq 0 ]
    run inventory_get Deployment default web
    [ "$status" -eq 0 ]
}

@test "evict_unwatched: drops kinds no longer watched" {
    # A reconcile only evicts within the kinds it listed, so dropping a kind
    # from the watched set would otherwise leave its entries polled forever.
    inventory_put Deployment default web 1000 60 "" default '[]' '' 'containers main=a:1'
    inventory_put CronJob ops backup 1000 60 "" default '[]' '' 'containers main=c:1'
    inventory_evict_unwatched "Deployment StatefulSet"
    run inventory_get Deployment default web
    [ "$status" -eq 0 ]
    run inventory_get CronJob ops backup
    [ "$status" -eq 1 ]
}

@test "evict_unwatched: keeps everything when all kinds are watched" {
    inventory_put Deployment default web 1000 60 "" default '[]' '' 'containers main=a:1'
    inventory_put CronJob ops backup 1000 60 "" default '[]' '' 'containers main=c:1'
    inventory_evict_unwatched "Deployment CronJob"
    inventory_list
    [ "${#INVENTORY_ALL[@]}" -eq 2 ]
}

# --- concurrent writers ---

@test "put: a failed write logs and returns 1 rather than killing the pass" {
    KEELSON_INVENTORY_DIR="$TMP_DIR/inventory/absent/deeper"
    run emit inventory_put Deployment default web 1700 60 "" default '[]' '' \
        'containers main=a:1'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not write the cache record"* ]]
}

@test "put: a failed write leaves no scratch file behind" {
    chmod 500 "$KEELSON_INVENTORY_DIR"
    inventory_put Deployment default web 1700 60 "" default '[]' '' \
        'containers main=a:1' 2>/dev/null || true
    chmod 700 "$KEELSON_INVENTORY_DIR"
    [ -z "$(find "$KEELSON_INVENTORY_DIR" -name '*.tmp' -print -quit)" ]
}

@test "put: a successful write leaves no scratch file behind" {
    put_simple
    [ -z "$(find "$KEELSON_INVENTORY_DIR" -name '*.tmp' -print -quit)" ]
}

# --- recording an image Keelson just applied ---

@test "set_container_image: replaces the image and keeps the schedule" {
    inventory_put Deployment default web 4242 60 "" default '[]' '' \
        "$(printf 'containers main=a:1\ninitContainers migrate=m:1')"
    inventory_set_container_image Deployment default web containers main a:2
    inventory_get Deployment default web
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "a:2" ]
    [ "${INVENTORY_CONTAINER_IMAGES[1]}" = "m:1" ]
    [ "$INVENTORY_NEXT_DUE" = "4242" ]
}

@test "set_container_image: an init container is matched on its own list" {
    inventory_put Deployment default web 4242 60 "" default '[]' '' \
        "$(printf 'containers main=a:1\ninitContainers migrate=m:1')"
    inventory_set_container_image Deployment default web initContainers migrate m:2
    inventory_get Deployment default web
    [ "${INVENTORY_CONTAINER_IMAGES[0]}" = "a:1" ]
    [ "${INVENTORY_CONTAINER_IMAGES[1]}" = "m:2" ]
}

@test "set_container_image: the wrong list matches nothing and returns 1" {
    inventory_put Deployment default web 4242 60 "" default '[]' '' \
        'containers main=a:1'
    run inventory_set_container_image Deployment default web initContainers main a:2
    [ "$status" -eq 1 ]
}

@test "set_container_image: an unknown workload returns 1" {
    run inventory_set_container_image Deployment default ghost containers main a:2
    [ "$status" -eq 1 ]
}

@test "set_container_image: no cache at all is not an error" {
    # The keelson-boot-scan CLI runs with no inventory to keep current, so a
    # warn at the call site would fire on every update it makes.
    KEELSON_INVENTORY_DIR="$TMP_DIR/absent"
    run inventory_set_container_image Deployment default web containers main a:2
    [ "$status" -eq 0 ]
}

@test "set_container_image: the record fingerprints as the new image" {
    # The whole point: the re-read after our own patch must compare equal, or
    # it resyncs and asks the registry a question it has already answered.
    inventory_put Deployment default web 4242 60 "" default '[]' '' \
        'containers main=a:1'
    inventory_set_container_image Deployment default web containers main a:2
    inventory_get Deployment default web
    local after=$INVENTORY_FINGERPRINT
    inventory_fingerprint 60 "" default '[]' '' 'containers main=a:2'
    [ "$INVENTORY_COMPUTED_FINGERPRINT" = "$after" ]
}
