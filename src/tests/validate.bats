#!/usr/bin/env bats

# Tests for lib/validate.bash. Binaries are checked against PATH; we shim
# missing ones in/out via $TMP_BIN to drive the pass/fail paths.

setup() {
    TMP_DIR=$(mktemp -d)
    TMP_BIN="$TMP_DIR/bin"
    mkdir -p "$TMP_BIN"
    SAVED_PATH="$PATH"
    export TMP_DIR

    # Symlink host utilities into TMP_BIN so v_run can lock PATH to TMP_BIN
    # alone without breaking log.bash (date/tr), validate.bash (mkdir/rm/sort),
    # or the shim shebang resolver (env/bash). Binaries under test
    # (kubectl/skopeo/yq) are NOT linked — tests install shims for those.
    local tool src
    for tool in bash env date tr sort mkdir rm ls cat dirname chmod printf; do
        if src=$(command -v "$tool" 2>/dev/null); then
            ln -sf "$src" "$TMP_BIN/$tool"
        fi
    done

    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/log.bash
    source "$SCRIPT_DIR/lib/log.bash"
    # shellcheck source=../scripts/lib/validate.bash
    source "$SCRIPT_DIR/lib/validate.bash"

    KEELSON_REGISTRIES_FILE="$TMP_DIR/registries.yaml"
    KEELSON_WORK_DIR="$TMP_DIR/work"
    export KEELSON_REGISTRIES_FILE KEELSON_WORK_DIR
}

teardown() {
    PATH="$SAVED_PATH"
    rm -rf "$TMP_DIR"
}

emit() { "$@" 2>&1; }

# Restrict PATH to $TMP_BIN for the duration of `run`, so validate_binary
# and validate_yq_v4 only see the shims we installed — never host binaries.
v_run() { PATH="$TMP_BIN" run "$@"; }

install_shim() {
    local name=$1
    cat > "$TMP_BIN/$name"
    chmod +x "$TMP_BIN/$name"
}

install_yq_v4() {
    install_shim yq <<'SH'
#!/usr/bin/env bash
case "$1" in
    --version) printf 'yq (https://github.com/mikefarah/yq/) version v4.40.5\n' ;;
    *) exit 0 ;;
esac
SH
}

set_required_env() {
    export KEELSON_SCOPE=cluster
    export KEELSON_CONFIG_MODE=keelson
    export KEELSON_LOG_LEVEL=info
    export KEELSON_LOG_FORMAT=plain
    export KEELSON_RESPECT_SA_PULL_SECRETS=false
    export KEELSON_STATE_CONFIGMAP=keelson-state
    export KEELSON_WATCHED_KINDS="Deployment CronJob"
    export KEELSON_POLL_INTERVAL=60
    export KEELSON_FULL_REFRESH_INTERVAL=3600
    export KEELSON_TICK_INTERVAL=1
    export KEELSON_HEARTBEAT_MAX_AGE=5
    export KEELSON_WATCHER_BACKOFF_MAX=300
    export KEELSON_WATCHER_HEALTHY_RESET=30
    export KEELSON_WATCHER_RECONNECT_INITIAL=2
    export KEELSON_WATCHER_RECONNECT_MAX=60
    export KEELSON_LOG_DEBUG_REPEAT_INTERVAL=0
    export KEELSON_LOG_INFO_REPEAT_INTERVAL=120
    export KEELSON_LOG_WARN_REPEAT_INTERVAL=300
    export KEELSON_LOG_ERROR_REPEAT_INTERVAL=600
    export KEELSON_LOG_FILE_MAX_BYTES=10485760
    export KEELSON_LOG_FILE_KEEP=5
}

install_required_binaries() {
    install_yq_v4
    # date is left as the host symlink from setup so log_emit's timestamps
    # and the rate limiter's `now=$(date +%s)` produce real values.
    local b
    for b in kubectl skopeo awk sed head tail; do
        install_shim "$b" <<<'#!/usr/bin/env bash'$'\nexit 0'
    done
}

# --- helpers in isolation ---

@test "env_set: passes when var is non-empty" {
    export FOO=bar
    v_run validate_env_set FOO
    [ "$status" -eq 0 ]
}

@test "env_set: fails when var is unset" {
    unset FOO
    v_run emit validate_env_set FOO
    [ "$status" -eq 1 ]
    [[ "$output" == *"Validation failed: required env var 'FOO' is not set."* ]]
}

@test "env_enum: passes when value is in allowed set" {
    export KEELSON_SCOPE=cluster
    v_run validate_env_enum KEELSON_SCOPE "cluster namespace"
    [ "$status" -eq 0 ]
}

@test "env_enum: fails when value is not allowed" {
    export KEELSON_SCOPE=neither
    v_run emit validate_env_enum KEELSON_SCOPE "cluster namespace"
    [ "$status" -eq 1 ]
    [[ "$output" == *"env var 'KEELSON_SCOPE' has value 'neither' but must be one of"* ]]
}

@test "env_positive_int: passes for positive int" {
    export N=60
    v_run validate_env_positive_int N
    [ "$status" -eq 0 ]
}

@test "env_positive_int: fails for zero" {
    export N=0
    v_run emit validate_env_positive_int N
    [ "$status" -eq 1 ]
}

@test "env_positive_int: fails for non-int" {
    export N=abc
    v_run emit validate_env_positive_int N
    [ "$status" -eq 1 ]
}

@test "env_kinds: passes for allowed kinds" {
    export KEELSON_WATCHED_KINDS="Deployment CronJob"
    v_run validate_env_kinds
    [ "$status" -eq 0 ]
}

@test "env_kinds: fails on unknown kind" {
    export KEELSON_WATCHED_KINDS="Deployment HelmRelease"
    v_run emit validate_env_kinds
    [ "$status" -eq 1 ]
    [[ "$output" == *"watched kind 'HelmRelease' is not supported"* ]]
}

@test "binary: passes when in PATH" {
    install_shim foo <<<'#!/usr/bin/env bash'$'\nexit 0'
    v_run validate_binary foo
    [ "$status" -eq 0 ]
}

@test "binary: fails when missing" {
    v_run emit validate_binary nope-not-here
    [ "$status" -eq 1 ]
    [[ "$output" == *"required binary 'nope-not-here' not found on PATH."* ]]
}

@test "yq_v4: passes for v4" {
    install_yq_v4
    v_run validate_yq_v4
    [ "$status" -eq 0 ]
}

@test "yq_v4: fails for v3" {
    install_shim yq <<'SH'
#!/usr/bin/env bash
printf 'yq version 3.4.1\n'
SH
    v_run emit validate_yq_v4
    [ "$status" -eq 1 ]
    [[ "$output" == *"yq must be v4"* ]]
}

# --- registries auth-mode handling ---

@test "registries: absent file is OK" {
    rm -f "$KEELSON_REGISTRIES_FILE"
    install_yq_v4
    v_run validate_registries_auth_modes
    [ "$status" -eq 0 ]
}

@test "registries: secret-only declared needs no helper" {
    install_yq_v4
    cat >"$KEELSON_REGISTRIES_FILE" <<'YAML'
registries:
  ghcr.io:
    auth-mode: secret
YAML
    v_run validate_registries_auth_modes
    [ "$status" -eq 0 ]
}

# --- full validate_config ---

@test "validate_config: all valid passes" {
    set_required_env
    install_required_binaries
    v_run emit validate_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"Validation passed:"* ]]
}

@test "validate_config: missing required env fails" {
    set_required_env
    install_required_binaries
    unset KEELSON_SCOPE
    v_run emit validate_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"KEELSON_SCOPE"* ]]
}

@test "validate_config: invalid enum fails" {
    set_required_env
    install_required_binaries
    export KEELSON_CONFIG_MODE=bogus
    v_run emit validate_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"env var 'KEELSON_CONFIG_MODE' has value 'bogus' but must be one of"* ]]
}

@test "validate_config: missing yq fails" {
    set_required_env
    install_required_binaries
    rm -f "$TMP_BIN/yq"
    v_run emit validate_config
    [ "$status" -eq 1 ]
}

@test "validate_config: KEELSON_SCOPE=namespace requires KEELSON_NAMESPACE" {
    set_required_env
    install_required_binaries
    export KEELSON_SCOPE=namespace
    unset KEELSON_NAMESPACE
    v_run emit validate_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"KEELSON_NAMESPACE"* ]]
}
