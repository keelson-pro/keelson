# Boot-time configuration validation.
# Sourced; not directly executable.
#
# validate_config accumulates errors across all checks and returns non-zero
# if any failed, so operators see the full list in one boot log instead of
# fixing one variable at a time.
#
# Depends on: lib/log.bash

KEELSON_WATCHED_KINDS_ALLOWED="Deployment StatefulSet DaemonSet CronJob"
KEELSON_REGISTRIES_FILE="${KEELSON_REGISTRIES_FILE:-/configmap/registries.yaml}"

validate_env_set() {
    local name=$1
    if [ -z "${!name:-}" ]; then
        log_error validate-env-missing var="$name" \
            msg="Validation failed: required env var '$name' is not set."
        return 1
    fi
}

validate_env_enum() {
    local name=$1 allowed=$2 value=${!1:-}
    case " $allowed " in
        *" $value "*) return 0 ;;
    esac
    log_error validate-env-invalid var="$name" value="$value" allowed="$allowed" \
        msg="Validation failed: env var '$name' has value '$value' but must be one of: $allowed."
    return 1
}

validate_env_positive_int() {
    local name=$1 value=${!1:-}
    case "$value" in
        ''|*[!0-9]*)
            log_error validate-env-not-int var="$name" value="$value" \
                msg="Validation failed: env var '$name' has value '$value' which is not an integer."
            return 1
            ;;
        0)
            log_error validate-env-not-positive var="$name" value="$value" \
                msg="Validation failed: env var '$name' has value '$value' which is not a positive integer."
            return 1
            ;;
    esac
}

validate_env_non_negative_int() {
    local name=$1 value=${!1:-}
    case "$value" in
        ''|*[!0-9]*)
            log_error validate-env-not-int var="$name" value="$value" \
                msg="Validation failed: env var '$name' has value '$value' which is not a non-negative integer."
            return 1
            ;;
    esac
}

validate_env_kinds() {
    local kind value=${KEELSON_WATCHED_KINDS:-}
    if [ -z "$value" ]; then
        log_error validate-env-missing var=KEELSON_WATCHED_KINDS \
            msg="Validation failed: required env var 'KEELSON_WATCHED_KINDS' is not set."
        return 1
    fi
    for kind in $value; do
        case " $KEELSON_WATCHED_KINDS_ALLOWED " in
            *" $kind "*) ;;
            *)
                log_error validate-env-kind-unknown kind="$kind" allowed="$KEELSON_WATCHED_KINDS_ALLOWED" \
                    msg="Validation failed: watched kind '$kind' is not supported (allowed: $KEELSON_WATCHED_KINDS_ALLOWED)."
                return 1
                ;;
        esac
    done
}

validate_binary() {
    local bin=$1
    if ! command -v "$bin" >/dev/null 2>&1; then
        log_error validate-binary-missing bin="$bin" \
            msg="Validation failed: required binary '$bin' not found on PATH."
        return 1
    fi
}

validate_bash_version() {
    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        log_error validate-bash-too-old version="${BASH_VERSION:-unknown}" required=4 \
            msg="Validation failed: Bash version '${BASH_VERSION:-unknown}' is older than required v4."
        return 1
    fi
}

validate_yq_v4() {
    local out
    if ! out=$(yq --version 2>&1); then
        log_error validate-yq-version-failed detail="$out" \
            msg="Validation failed: could not run 'yq --version' ($out)."
        return 1
    fi
    case "$out" in
        *version\ v4.*|*version\ 4.*) return 0 ;;
    esac
    log_error validate-yq-not-v4 detail="$out" \
        msg="Validation failed: yq must be v4 (got: $out)."
    return 1
}

validate_registries_auth_modes() {
    [ -r "$KEELSON_REGISTRIES_FILE" ] || return 0
    local modes mode errors=0
    if ! modes=$(yq -p=yaml '.registries[].auth-mode // ""' "$KEELSON_REGISTRIES_FILE" 2>/dev/null | sort -u); then
        log_error validate-registries-parse-failed file="$KEELSON_REGISTRIES_FILE" \
            msg="Validation failed: could not parse registries file '$KEELSON_REGISTRIES_FILE'."
        return 1
    fi
    while IFS= read -r mode; do
        [ -z "$mode" ] && continue
        case "$mode" in
            secret) ;;
            aws-irsa)
                validate_binary docker-credential-ecr-login || errors=$((errors+1))
                ;;
            azure-wi|gcp-wi)
                validate_binary curl || errors=$((errors+1))
                ;;
            *)
                log_error validate-auth-mode-unknown mode="$mode" \
                    msg="Validation failed: registry auth-mode '$mode' is not supported."
                errors=$((errors+1))
                ;;
        esac
    done <<< "$modes"
    [ "$errors" -eq 0 ]
}

validate_filesystem() {
    local dir=${KEELSON_WORK_DIR:-/keelson/work}
    local probe="$dir/.validate-probe"
    if ! mkdir -p "$dir" 2>/dev/null; then
        log_error validate-fs-mkdir-failed dir="$dir" \
            msg="Validation failed: could not create work directory '$dir'."
        return 1
    fi
    if ! : > "$probe" 2>/dev/null; then
        log_error validate-fs-write-failed path="$probe" \
            msg="Validation failed: could not write probe file '$probe'."
        return 1
    fi
    rm -f "$probe"
}

validate_config() {
    local errors=0
    local var

    validate_bash_version || errors=$((errors+1))

    for var in KEELSON_SCOPE KEELSON_CONFIG_MODE KEELSON_LOG_LEVEL KEELSON_LOG_FORMAT \
               KEELSON_RESPECT_SA_PULL_SECRETS KEELSON_STATE_CONFIGMAP; do
        validate_env_set "$var" || errors=$((errors+1))
    done

    validate_env_enum KEELSON_SCOPE "cluster namespace" || errors=$((errors+1))
    validate_env_enum KEELSON_CONFIG_MODE "keelson keel both" || errors=$((errors+1))
    validate_env_enum KEELSON_LOG_LEVEL "debug info warn error" || errors=$((errors+1))
    validate_env_enum KEELSON_LOG_FORMAT "plain json" || errors=$((errors+1))
    validate_env_enum KEELSON_RESPECT_SA_PULL_SECRETS "true false" || errors=$((errors+1))

    if [ "${KEELSON_SCOPE:-}" = "namespace" ]; then
        validate_env_set KEELSON_NAMESPACE || errors=$((errors+1))
    fi

    for var in KEELSON_POLL_INTERVAL KEELSON_FULL_REFRESH_INTERVAL KEELSON_TICK_INTERVAL \
               KEELSON_HEARTBEAT_MAX_AGE KEELSON_WATCHER_BACKOFF_MAX KEELSON_WATCHER_HEALTHY_RESET \
               KEELSON_WATCHER_RECONNECT_INITIAL KEELSON_WATCHER_RECONNECT_MAX \
               KEELSON_LOG_FILE_MAX_BYTES KEELSON_LOG_FILE_KEEP; do
        validate_env_set "$var" && validate_env_positive_int "$var" || errors=$((errors+1))
    done

    # Repeat intervals: 0 is valid (= never throttle).
    for var in KEELSON_LOG_DEBUG_REPEAT_INTERVAL KEELSON_LOG_INFO_REPEAT_INTERVAL \
               KEELSON_LOG_WARN_REPEAT_INTERVAL KEELSON_LOG_ERROR_REPEAT_INTERVAL; do
        validate_env_set "$var" && validate_env_non_negative_int "$var" || errors=$((errors+1))
    done

    validate_env_kinds || errors=$((errors+1))

    for var in kubectl skopeo yq awk sed head tail date; do
        validate_binary "$var" || errors=$((errors+1))
    done
    validate_yq_v4 || errors=$((errors+1))

    validate_registries_auth_modes || errors=$((errors+1))
    validate_filesystem || errors=$((errors+1))

    if [ "$errors" -gt 0 ]; then
        log_error validate-failed errors="$errors" \
            msg="Validation failed with $errors errors."
        return 1
    fi
    log_info_always validate-passed \
        msg="Validation passed: configuration and dependencies validated successfully."
}
