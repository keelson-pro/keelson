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
