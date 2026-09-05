#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    KEELSON_WATCHED_KINDS="Deployment StatefulSet DaemonSet CronJob"
    KEELSON_SCOPE=cluster
    export KEELSON_WATCHED_KINDS KEELSON_SCOPE
    # shellcheck source=../scripts/lib/workload.bash
    source "${SCRIPT_DIR}/lib/workload.bash"
}

# --- workload_pod_spec_path ---

@test "pod_spec_path: Deployment" {
    run workload_pod_spec_path Deployment
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.template.spec" ]
}

@test "pod_spec_path: StatefulSet" {
    run workload_pod_spec_path StatefulSet
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.template.spec" ]
}

@test "pod_spec_path: DaemonSet" {
    run workload_pod_spec_path DaemonSet
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.template.spec" ]
}

@test "pod_spec_path: CronJob nests under jobTemplate" {
    run workload_pod_spec_path CronJob
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.jobTemplate.spec.template.spec" ]
}

@test "pod_spec_path: unknown kind returns non-zero" {
    run workload_pod_spec_path Pod
    [ "$status" -ne 0 ]
}

# --- workload_is_watched ---

@test "is_watched: Deployment" {
    run workload_is_watched Deployment
    [ "$status" -eq 0 ]
}

@test "is_watched: CronJob" {
    run workload_is_watched CronJob
    [ "$status" -eq 0 ]
}

@test "is_watched: Pod is not" {
    run workload_is_watched Pod
    [ "$status" -eq 1 ]
}

@test "is_watched: Rollout is not (deferred)" {
    run workload_is_watched Rollout
    [ "$status" -eq 1 ]
}

# --- workload_namespaces ---

@test "namespaces: cluster scope is one empty entry, meaning all of them" {
    KEELSON_SCOPE=cluster workload_namespaces
    [ "${#WORKLOAD_NAMESPACES[@]}" -eq 1 ]
    [ -z "${WORKLOAD_NAMESPACES[0]}" ]
}

@test "namespaces: one namespace" {
    KEELSON_SCOPE=namespace KEELSON_NAMESPACES=team-a workload_namespaces
    [ "${#WORKLOAD_NAMESPACES[@]}" -eq 1 ]
    [ "${WORKLOAD_NAMESPACES[0]}" = "team-a" ]
}

@test "namespaces: a space-separated list" {
    KEELSON_SCOPE=namespace KEELSON_NAMESPACES="team-a team-b team-c" workload_namespaces
    [ "${#WORKLOAD_NAMESPACES[@]}" -eq 3 ]
    [ "${WORKLOAD_NAMESPACES[2]}" = "team-c" ]
}

@test "namespaces: a comma-separated list means the same thing" {
    # The entrypoints that never run validate_config read this directly, so
    # both spellings have to work here and not only at boot.
    KEELSON_SCOPE=namespace KEELSON_NAMESPACES="team-a,team-b" workload_namespaces
    [ "${#WORKLOAD_NAMESPACES[@]}" -eq 2 ]
    [ "${WORKLOAD_NAMESPACES[0]}" = "team-a" ]
    [ "${WORKLOAD_NAMESPACES[1]}" = "team-b" ]
}

@test "namespaces: sloppy separators collapse" {
    KEELSON_SCOPE=namespace KEELSON_NAMESPACES="  team-a ,, team-b,  " workload_namespaces
    [ "${#WORKLOAD_NAMESPACES[@]}" -eq 2 ]
    [ "${WORKLOAD_NAMESPACES[0]}" = "team-a" ]
    [ "${WORKLOAD_NAMESPACES[1]}" = "team-b" ]
}

@test "namespaces: namespace scope with nothing set is fatal, not silently cluster-wide" {
    # Its own shell: the guard aborts whichever shell evaluates it, which is
    # the point, and would take the test runner with it.
    local out status=0
    out=$("$BASH" -c 'KEELSON_SCOPE=namespace; unset KEELSON_NAMESPACES
        source "'"${BATS_TEST_DIRNAME}"'/../scripts/lib/workload.bash"
        workload_namespaces' 2>&1) || status=$?
    [ "$status" -ne 0 ]
    [[ "$out" == *"KEELSON_NAMESPACES required"* ]]
}

# --- workload_list_kind ---

@test "list_kind: no namespace lists every namespace" {
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\necho "$@"\n' > "$bin/kubectl"
    chmod +x "$bin/kubectl"
    PATH="$bin:$PATH" run workload_list_kind Deployment
    [ "$output" = "get Deployment --all-namespaces -o json" ]
}

@test "list_kind: a namespace lists that one" {
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\necho "$@"\n' > "$bin/kubectl"
    chmod +x "$bin/kubectl"
    PATH="$bin:$PATH" run workload_list_kind Deployment team-b
    [ "$output" = "get Deployment -n team-b -o json" ]
}
