#!/usr/bin/env bats

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

# --- containers_path / image_pull_secrets_path ---

@test "containers_path: Deployment" {
    run workload_containers_path Deployment
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.template.spec.containers" ]
}

@test "containers_path: CronJob" {
    run workload_containers_path CronJob
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.jobTemplate.spec.template.spec.containers" ]
}

@test "image_pull_secrets_path: Deployment" {
    run workload_image_pull_secrets_path Deployment
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.template.spec.imagePullSecrets" ]
}

@test "image_pull_secrets_path: CronJob" {
    run workload_image_pull_secrets_path CronJob
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.jobTemplate.spec.template.spec.imagePullSecrets" ]
}

@test "service_account_name_path: Deployment" {
    run workload_service_account_name_path Deployment
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.template.spec.serviceAccountName" ]
}

@test "service_account_name_path: CronJob" {
    run workload_service_account_name_path CronJob
    [ "$status" -eq 0 ]
    [ "$output" = ".spec.jobTemplate.spec.template.spec.serviceAccountName" ]
}

@test "service_account_name_path: unknown kind returns non-zero" {
    run workload_service_account_name_path Pod
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
