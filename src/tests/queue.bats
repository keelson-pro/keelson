#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

load helper

setup() {
    tmp_dir_init

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/queue.bash
    source "$SCRIPT_DIR/lib/queue.bash"

    KEELSON_QUEUE_DIR="$TMP_DIR/queue"

    queue_init
}

@test "queue_init creates the queue directory" {
    [ -d "$KEELSON_QUEUE_DIR" ]
}

@test "queue_init is idempotent" {
    queue_init
    queue_init
    [ -d "$KEELSON_QUEUE_DIR" ]
}

@test "queue_enqueue creates a file named after the identity" {
    queue_enqueue Deployment default app
    [ -f "$KEELSON_QUEUE_DIR/Deployment--default--app" ]
}

@test "queue_enqueue: file body is 'kind ns name'" {
    queue_enqueue Deployment default app
    [ "$(cat "$KEELSON_QUEUE_DIR/Deployment--default--app")" = "Deployment default app" ]
}

@test "queue_enqueue: same identity twice collides to one file (dedupe)" {
    queue_enqueue Deployment default app
    queue_enqueue Deployment default app
    run queue_size
    [ "$output" = "1" ]
}

@test "queue_enqueue: different identities produce different files" {
    queue_enqueue Deployment default app
    queue_enqueue Deployment default other
    queue_enqueue CronJob default app
    run queue_size
    [ "$output" = "3" ]
}

@test "queue_drain emits each entry as 'kind ns name' line" {
    queue_enqueue Deployment default app
    queue_enqueue CronJob ns2 cron
    run queue_drain
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deployment default app"* ]]
    [[ "$output" == *"CronJob ns2 cron"* ]]
}

@test "queue_drain removes files as it emits them" {
    queue_enqueue Deployment default app
    queue_drain >/dev/null
    run queue_size
    [ "$output" = "0" ]
}

@test "queue_drain on empty queue is a no-op" {
    run queue_drain
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "queue_size on empty queue is 0" {
    run queue_size
    [ "$output" = "0" ]
}

# --- queue_pending ---

@test "queue_pending: an empty queue is not pending" {
    run queue_pending
    [ "$status" -eq 1 ]
}

@test "queue_pending: one entry is pending" {
    queue_enqueue Deployment default app
    run queue_pending
    [ "$status" -eq 0 ]
}

@test "queue_pending: draining makes it not pending again" {
    queue_enqueue Deployment default app
    queue_drain >/dev/null
    run queue_pending
    [ "$status" -eq 1 ]
}

@test "queue_pending: says nothing on stdout" {
    # It is asked every tick; the caller uses the status, and echoing would
    # make a command substitution the only way to read it.
    queue_enqueue Deployment default app
    run queue_pending
    [ -z "$output" ]
}

@test "queue_drain: exactly one line per entry, no blanks" {
    queue_enqueue Deployment default app
    queue_enqueue CronJob ns2 cron
    queue_enqueue StatefulSet ns3 db
    run queue_drain
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    printf '%s\n' "${lines[@]}" | grep -qv '^$'
}

@test "queue_drain: an entry file with no trailing newline still emits" {
    # queue_enqueue writes exactly this shape, so the EOF-without-newline
    # case is the normal one, not the edge case.
    printf '%s' 'Deployment default app' > "$KEELSON_QUEUE_DIR/Deployment--default--app"
    run queue_drain
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "Deployment default app" ]
}

@test "queue_drain: emits every entry when several are queued" {
    local i
    for i in 1 2 3 4 5; do queue_enqueue Deployment ns "app$i"; done
    run queue_drain
    [ "${#lines[@]}" -eq 5 ]
    run queue_size
    [ "$output" = "0" ]
}
