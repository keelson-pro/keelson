# Configuration

Keelson reads configuration from three places, each owned by a different actor:

- **Environment variables** on the Keelson Pod, set by the operator at deploy
  time.
- **`registries.yaml`** in the keelson ConfigMap, where the operator declares
  the registries Keelson talks to and how it authenticates to each.
- **Workload annotations**, set by the workload's owner.


## Environment variables

The Deployment's `env` supplies every variable, from the shipped defaults unless
overridden. The scripts have no built-in fallbacks: every variable must be
defined, and `keelson` runs the same checks as `keelson-validate` at boot and
refuses to start on a missing or malformed one. Only `KEELSON_NAMESPACES` and
the two `AWS_ECR_*` variables may be empty.

Each row shows the env var on top and its Kaptain token below. With Kaptain, set
the token in your `Keelson/…` env config directory; with Helm, the same options
are in `values.yaml`; otherwise set the env var directly.

### Deployment

Kaptain tokens that build the manifests rather than set an env var.

| Kaptain Token                                   | Default               | Purpose                                                                                             |
| ----------------------------------------------- | --------------------- | --------------------------------------------------------------------------------------------------- |
| `Keelson/PackageVersion`                        | none, required        | The `keelson-package` image tag to run. Pick one whose kubectl is within one minor of your cluster. |
| `Keelson/EnvironmentDockerRegistryAndNamespace` | `ghcr.io/keelson-pro` | Registry and namespace the `keelson-package` image is pulled from.                                  |
| `Keelson/EnvironmentDockerRegistry`             | none                  | The registry host of the one entry the shipped `registries.yaml` declares.                          |
| `Keelson/AuthMode`                              | `secret`              | That entry's `auth-mode` (see [auth modes](#auth-modes)).                                           |

### Image-provided

Not operator settings, and not in the Deployment's `env`: the `keelson-package`
build bakes them into the image. Both are still checked at boot, since a missing
one means the image was built wrong.

| Env Var                   | Set from                    | Purpose                                               |
| ------------------------- | --------------------------- | ----------------------------------------------------- |
| `KEELSON_VERSION`         | `${TemplateKeelsonVersion}` | The `keelson` release whose scripts are in the image. |
| `KEELSON_PACKAGE_VERSION` | `${Version}`                | The `keelson-package` release that built the image.   |

Both appear on the boot line: `Keelson <version> (package <package-version>)
booting in ns '<ns>'`.

### Behaviour

| Env Var / Kaptain Token                                                         | Default                                    | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KEELSON_SCOPE`<br>`Keelson/Scope`                                              | `cluster`                                  | `cluster` watches every namespace; `namespace` watches only those in `KEELSON_NAMESPACES`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `KEELSON_NAMESPACES`<br>`Keelson/Namespaces`                                    | empty                                      | The namespaces to watch under `namespace` scope, which requires at least one. Separate them with spaces or commas. Each must be a valid namespace name and must exist: boot reads each one and fails on anything short of a clean read, because a typo would otherwise watch an empty namespace and report healthy forever. That read needs `get namespaces` from the `keelson-clusterrole`. A value under `cluster` scope, and a namespace listed twice, are warned about. Each namespace costs one watcher per watched kind and needs its own copy of the `-own-ns` Role and RoleBinding; a namespace without one backs off on `Forbidden` while the others keep streaming.                                                                                                                                                                                                     |
| `KEELSON_CONFIG_MODE`<br>`Keelson/ConfigMode`                                   | `keelson`                                  | Which annotation prefix Keelson reads: `keelson` for `keelson.pro/`, `keel` for `keel.sh/` (drop-in mode), or `both`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `KEELSON_LOG_LEVEL`<br>`Keelson/LogLevel`                                       | `INFO`                                     | `DEBUG`, `INFO`, `WARN` or `ERROR`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `KEELSON_LOG_FORMAT`<br>`Keelson/LogFormat`                                     | `plain`                                    | `plain` or `json`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `KEELSON_LOG_MANAGED_WORKLOADS`<br>`Keelson/LogManagedWorkloads`                | `true`                                     | Once the first scan has filled the cache, list every workload Keelson will act on, by namespace, with a ratio header (`7 of 312 cached workloads`). Set `false` where the list would run to hundreds of lines.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `KEELSON_RESPECT_SA_PULL_SECRETS`<br>`Keelson/RespectServiceAccountPullSecrets` | `false`                                    | `true` also tries the workload's ServiceAccount `imagePullSecrets` after the Pod's own, as the kubelet does. Costs one `get sa` per scan.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `KEELSON_WATCHED_KINDS`<br>`Keelson/WatchedKinds`                               | `Deployment StatefulSet DaemonSet CronJob` | Space-separated, from `Deployment StatefulSet DaemonSet CronJob Rollout`. `Rollout` is Argo's: add it only where the CRD is installed and the `keelson-argo-rollouts-rbac` permissions are applied. Without the CRD every scan of it fails with `the server doesn't have a resource type "rollouts"`; without the permissions, with `Forbidden`. ReplicaSets are not supported: a Deployment's ReplicaSets inherit its annotations, so watching both would update twice.                                                                                                                                                                                                                                                                                                                                                                                                          |
| `KEELSON_STATE_CONFIGMAP`<br>`Keelson/StateConfigMap`                           | `keelson-state`                            | The ConfigMap holding what must survive a restart: a `w--<kind>--<ns>--<name>` key per workload seen (`first-seen`, and whether Keelson manages it) and a `j--<kind>--<ns>--<name>` key per CronJob trigger fired. The controller loads it once at boot and writes it whole, by forced server-side apply as `keelson`; its children spool their changes for the loop to write. `keelson-user-recheck --apply` and `keelson-update-resource` also write it when they fire a CronJob trigger, but the running controller's next write replaces theirs. Six `keelson.pro/` provenance annotations record which build created and last updated it. No schedule is stored, so a poll writes nothing here. A ConfigMap that cannot be read, or holds a value that is not a JSON object, logs `state-load-failed` and is left unwritten; only one the server says is missing is created. |

### Field-manager strategy

How Keelson writes an image depends on who owns it, as
[FieldManagerOwnership.md](FieldManagerOwnership.md) explains: **apply-owned**
(an Apply entry holds it), **update-owned** (an Update entry holds it) or
**unowned**. Each state has its own setting, and a workload can override them
with the `fieldManagerStrategy` annotation.

| Env Var / Kaptain Token                                                                                                            | Default       | Values                                |
| ---------------------------------------------------------------------------------------------------------------------------------- | ------------- | ------------------------------------- |
| `KEELSON_FIELD_MANAGER_STRATEGY_APPLY_OWNED`<br>`Keelson/FieldManagerStrategyApplyOwned`                                           | `mimic`       | `mimic`, `claim-patch`, `claim-apply` |
| `KEELSON_FIELD_MANAGER_STRATEGY_UPDATE_OWNED`<br>`Keelson/FieldManagerStrategyUpdateOwned`                                         | `mimic`       | `mimic`, `claim-patch`, `claim-apply` |
| `KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED`<br>`Keelson/FieldManagerStrategyUnowned`                                                  | `claim-patch` | `claim-patch`, `claim-apply`          |
| `KEELSON_FIELD_MANAGER_STRATEGY_MIMIC_ANNOTATION_FALLBACK_ALLOWED`<br>`Keelson/FieldManagerStrategyMimicAnnotationFallbackAllowed` | `true`        | `true`, `false`                       |

- **`mimic`** writes as the image's owner. Apply-owned: a server-side apply of
  everything the owner applies, rebuilt from the live object with the image
  changed, checked first by a dry run. Update-owned: a JSON patch as the owner.
- **`claim-patch`** writes as `keelson` with a JSON patch of the image alone.
- **`claim-apply`** writes as `keelson` with a forced server-side apply of
  Keelson's own applied set.

Mimic needs an owner, so it is not a value for the unowned setting. An
annotation asking for mimic on an unowned image falls back to claim-patch,
unless the fallback setting is `false`, in which case the update is refused.

A claim strategy on the apply-owned setting takes the image away from its owner,
whose next apply then conflicts over it. The boot log says so beside the
setting.

### Tick loop and scan cadence

| Env Var / Kaptain Token                                                                                 | Default       | Purpose                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `KEELSON_TICK_INTERVAL`<br>`Keelson/TickInterval`                                                       | `1`           | Seconds from the start of one tick to the start of the next. Each tick publishes the heartbeat, supervises watchers, re-reads what the watchers queued, polls what is due and starts a scan if one is due, then sleeps the rest of the interval. A tick that runs over sleeps not at all and logs `tick-overrun`.                                                                                            |
| `KEELSON_RECONCILE_INTERVAL`<br>`Keelson/ReconcileInterval`                                             | `600` (10m)   | Seconds between reconcile scans, which list the cluster to refresh the workload cache. A safety net: watch events carry changes as they happen, and the scan catches what they cannot, chiefly a deletion missed while a watcher was down. One list per watched kind, so this is the main lever on load against the API server. Scans never overlap; one that runs over warns with `reconcile-pass-overrun`. |
| `KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT`<br>`Keelson/RegistryPollIntervalDefault`                       | `60`          | Seconds between registry tag lookups for each workload, overridable per workload with `pollSchedule`. The lever for registry traffic. A new workload's first poll is offset inside its interval, derived from its identity, so workloads cached together do not fall due together.                                                                                                                           |
| `KEELSON_FIRST_POLL_DELAY_MAX`<br>`Keelson/FirstPollDelayMax`                                           | `300`         | Seconds. Caps that first-poll offset, so a long `pollSchedule` (say `@every 24h`) still polls soon after a restart. Lowering it concentrates registry load after a restart.                                                                                                                                                                                                                                  |
| `KEELSON_REGISTRY_POLL_CONCURRENCY`<br>`Keelson/RegistryPollConcurrency`                                | `2`           | How many workloads the due-poll checks at once. A lookup is mostly waiting, so concurrency cuts a pass's time sharply. **Raise `Keelson/Memory` with it**: each concurrent check costs about 30-50MB, and an OOM kill presents as a crashloop.                                                                                                                                                               |
| `KEELSON_POLL_OVERRUN_WARNING_BACKOFF_LIMIT`<br>`Keelson/PollOverrunWarningBackoffLimit`                | `64`          | A poll pass longer than the shortest schedule it polled warns with `poll-pass-overrun` on the 1st, 2nd, 4th, 8th consecutive overrun and so on, then every this-many-th. A pass that fits resets the count.                                                                                                                                                                                                  |
| `KEELSON_RECONCILE_OVERRUN_WARNING_BACKOFF_LIMIT`<br>`Keelson/ReconcileOverrunWarningBackoffLimit`      | `64`          | The same backoff for `reconcile-pass-overrun`.                                                                                                                                                                                                                                                                                                                                                               |
| `KEELSON_ROLLOUT_WORKLOAD_REF_WARNING_BACKOFF_LIMIT`<br>`Keelson/RolloutWorkloadRefWarningBackoffLimit` | `64`          | The same backoff for `rollout-workload-ref-no-template`: an annotated Rollout that takes its pod template from `spec.workloadRef` has no image of its own, so annotate the referenced Deployment instead.                                                                                                                                                                                                    |
| `AWS_ECR_DISABLE_CACHE`<br>`Keelson/AwsEcrDisableCache`                                                 | empty         | Passed to `docker-credential-ecr-login`. Any value turns off its token cache, so every ECR lookup re-authenticates. Set it only to diagnose a stale token.                                                                                                                                                                                                                                                   |
| `AWS_ECR_CACHE_DIR`<br>`Keelson/AwsEcrCacheDir`                                                         | empty         | Passed to `docker-credential-ecr-login`. Empty uses `/home/keelson/.ecr`, on the Pod's writable `emptyDir`.                                                                                                                                                                                                                                                                                                  |
| `KEELSON_FULL_REFRESH_INTERVAL`<br>`Keelson/FullRefreshInterval`                                        | `86400` (24h) | Seconds between full refreshes, which rebuild the workload cache from the cluster one kind per tick, then drop cache entries for kinds no longer watched and ledger keys whose workload is gone. Corrects cache drift nothing else sees. Makes no registry calls.                                                                                                                                            |
| `KEELSON_HEARTBEAT_MAX_AGE`<br>`Keelson/HeartbeatMaxAge`                                                | `5`           | Seconds before the liveness probe treats the heartbeat as stale. Must be at least twice `KEELSON_TICK_INTERVAL` (checked at boot), so one missed tick never kills a healthy controller.                                                                                                                                                                                                                      |

### Watcher supervision

| Env Var / Kaptain Token                                                         | Default | Purpose                                                                                |
| ------------------------------------------------------------------------------- | ------- | -------------------------------------------------------------------------------------- |
| `KEELSON_WATCHER_RESPAWN_BACKOFF_MAX`<br>`Keelson/WatcherRespawnBackoffMax`     | `300`   | Cap, in seconds, on a dead watcher's respawn delay, which backs off `1, 2, 4, 8...`.   |
| `KEELSON_WATCHER_RESPAWN_HEALTHY_RESET`<br>`Keelson/WatcherRespawnHealthyReset` | `30`    | Seconds a watcher process must stay alive before its failure count resets.             |
| `KEELSON_WATCHER_RECONNECT_INITIAL`<br>`Keelson/WatcherReconnectInitial`        | `2`     | Seconds a live watcher waits before reconnecting a watch stream that ended.            |
| `KEELSON_WATCHER_RECONNECT_MAX`<br>`Keelson/WatcherReconnectMax`                | `60`    | Cap on that reconnect delay.                                                           |
| `KEELSON_WATCHER_RECONNECT_RESET`<br>`Keelson/WatcherReconnectReset`            | `30`    | Seconds a stream must last before the reconnect delay drops back to the initial value. |

### Log throttling and the file log

| Env Var / Kaptain Token                                                 | Default    | Purpose                                                                                                                                                     |
| ----------------------------------------------------------------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KEELSON_LOG_DEBUG_REPEAT_INTERVAL`<br>`Keelson/LogDebugRepeatInterval` | `0`        | Seconds within which an identical debug line (same level, event and fields) is suppressed. `0` turns throttling off.                                        |
| `KEELSON_LOG_INFO_REPEAT_INTERVAL`<br>`Keelson/LogInfoRepeatInterval`   | `120`      | The same for info. Only `dry-run-would-update`, `update-already-applied` and `update-workload-gone` are throttled; every other info event is always logged. |
| `KEELSON_LOG_WARN_REPEAT_INTERVAL`<br>`Keelson/LogWarnRepeatInterval`   | `300`      | The same for warnings.                                                                                                                                      |
| `KEELSON_LOG_ERROR_REPEAT_INTERVAL`<br>`Keelson/LogErrorRepeatInterval` | `600`      | The same for errors.                                                                                                                                        |
| `KEELSON_LOG_FILE_MAX_BYTES`<br>`Keelson/LogFileMaxBytes`               | `10485760` | Rotate `/keelson/work/log/keelson.log` past this size (10 MiB). Checked once a minute.                                                                      |
| `KEELSON_LOG_FILE_KEEP`<br>`Keelson/LogFileKeep`                        | `5`        | Rotated files (`.1`, `.2`, ...) to keep.                                                                                                                    |

### Not in the manifest

Neither is set by the shipped Deployment, and neither is checked at boot.

| Env Var                   | Default             | Purpose                                                                                                                                                                                                                                                                 |
| ------------------------- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KEELSON_DRY_RUN`         | unset               | `1` runs the controller without writing to any workload: the poll logs `dry-run-would-update` instead. Needs no write RBAC on workloads, though the state ConfigMap is still created if missing. Read by the controller only; the manual tools have their own switches. |
| `KEELSON_STATE_NAMESPACE` | the Pod's namespace | Where the state ConfigMap lives. The default is read from the ServiceAccount mount.                                                                                                                                                                                     |


## Resources

| Kaptain Token              | Default | Applied as                                                                                                                                                                                        |
| -------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Keelson/Memory`           | `270Mi` | Request and limit. Sized for two updates at once: about 89Mi steady, plus roughly 80MB per concurrent update (`kubectl` and `yq` resident together). **Raise it with `RegistryPollConcurrency`.** |
| `Keelson/CpuRequest`       | `100m`  | Request only.                                                                                                                                                                                     |
| `Keelson/EphemeralStorage` | `150Mi` | Request and limit.                                                                                                                                                                                |

Memory request equals limit, so the allocation is guaranteed and a leak dies
predictably.

There is deliberately no CPU limit. The loop is idle most of each second and
then forks hard during a scan, which is the shape a limit throttles worst, and a
throttled tick reads to the liveness probe as a wedged loop.

Ephemeral storage covers the `emptyDir`, the writable layer and the node's copy
of the console log. At defaults that settles near 120Mi: 50Mi of console log
(Kubernetes rotates it at 10Mi across 5 files), 60Mi of Keelson's own log
(`LogFileMaxBytes` × (`LogFileKeep` + 1)), and under 1Mi of cache and status. To
shrink it, lower `LogFileMaxBytes` and `LogFileKeep` together.


## Probe timings

| Kaptain Token                            | Default |
| ---------------------------------------- | ------- |
| `Keelson/StartupProbePeriodSeconds`      | `5`     |
| `Keelson/StartupProbeFailureThreshold`   | `24`    |
| `Keelson/StartupProbeTimeoutSeconds`     | `4`     |
| `Keelson/ReadinessProbePeriodSeconds`    | `20`    |
| `Keelson/ReadinessProbeFailureThreshold` | `2`     |
| `Keelson/ReadinessProbeTimeoutSeconds`   | `5`     |
| `Keelson/LivenessProbePeriodSeconds`     | `15`    |
| `Keelson/LivenessProbeFailureThreshold`  | `5`     |
| `Keelson/LivenessProbeTimeoutSeconds`    | `6`     |

At defaults: 120s to start, 40s to NotReady, 75s to a liveness kill. Keep each
timeout under its period.

Liveness errs toward not killing, because a restart costs more than it fixes:
the work queue lives on the `emptyDir` and goes with it, and every watcher
re-lists its whole kind on start. Keelson exposes no Service, so readiness only
colours the READY column and gates rollouts.


## Logging

On the happy path Keelson logs what changes, what goes wrong, and what happens
once at startup. Repeated warnings and errors are rate-limited by the intervals
above, so a persistent fault stays visible without flooding. Everything, at
every level, also goes to a rotated file inside the Pod, so default info logging
still leaves full detail to read there.

Every line goes to stderr. `json` lines carry `ts`, `level`, the event name and
every field. `plain` lines read `<ISO-timestamp> <LEVEL> <message>`, the
sentence alone, or `<ISO-timestamp> <LEVEL> <event> <fields>` for the few events
without one. Query by event name and fields in `json`.

### Levels

`KEELSON_LOG_LEVEL` is a threshold: each level adds its own events to those of
the levels above it.

| Level              | Adds                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `error`            | Failures Keelson cannot work around: a misconfiguration, broken RBAC, a registry out of reach, or a workload Keelson will not write as configured. Registry: `registry-creds-failed`, `registry-list-tags-failed`, `registry-namespace-unknown`, `registry-config-parse-failed`, `registry-config-entry-failed`, `registry-config-key-invalid`, `registry-config-key-duplicate`, `registry-config-secret-name-invalid`, `registry-config-secret-name-collision`. Workloads: `kubectl-list-failed`, `annotation-spelling-conflict`, `annotation-monitor-containers-invalid`, `inventory-write-failed`. Updates: `update-failed`, `update-apply-conflict`, `update-mimic-refused`, `update-claim-refused`, `update-invalid-strategy-annotation`, `update-invalid-strategy`, `update-unsupported-kind`. CronJob triggers: `cronjob-job-trigger-failed`, `cronjob-trigger-requires-suspend`. State: `state-load-failed`, `state-configmap-create-failed`, `state-flush-failed`, `state-flush-refused`, `state-namespace-unknown`, `state-spool-write-failed`. Probes, stderr only: `probe-liveness-fail`, `probe-readiness-fail`. Boot: every `validate-*` check except the three warnings below. |
| `warn`             | Faults Keelson recovers from, and updates it deliberately skipped. `watch-failed`, `watch-disconnected` (for a stream that lasted under 30 minutes; a longer one logs it at debug), `watcher-died`, `watcher-respawned`, `state-init-failed`, `poll-schedule-invalid`, `poll-schedule-too-fast`, `tick-overrun`, `poll-pass-overrun`, `reconcile-pass-overrun`, `rollout-workload-ref-no-template`, `annotation-spelling-duplicate`, `next-due-implausible`, `inventory-image-not-recorded`, `inventory-not-rescheduled`, `update-image-moved` and `update-owner-moved` (the image or its owner changed since the poll, so nothing was written), `update-tempfile-failed`, and at boot `validate-namespace-duplicate`, `validate-namespaces-ignored`, `validate-registries-key-not-lowercase`.                                                                                                                                                                                                                                                                                                                                                                                                |
| `info` *(default)* | Changes and one-time lifecycle events. `boot`, `config`, `shutdown`, `validate-passed`, `watcher-spawned`, `managed-workloads`, `full-refresh-due`, `full-refresh-complete`, `inventory-refreshed`, `scan-resync`, `state-configmap-created`, `update-applied`, `update-already-applied`, `update-workload-gone`, `cronjob-job-triggered`, `dry-run-would-update`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `debug`            | The mechanics. `scan-start`, `scan-summary`, `poll-summary`, `skip-not-eligible`, `skip-not-monitored`, `no-change`, `dry-run-no-change`, `watch-start`, `watch-enqueued`, `watch-evicted`, `queue-refreshed`, `queue-refresh-listing`, `queue-refresh-failed`, `inventory-evicted`, `state-flushed`, `ledger-forgotten`, `update-retry`, `update-mimic-omitted`, `registry-creds-source-rejected`, and a `*-detail` line with the full output behind each failed lookup, update or trigger.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |

Every info event except the three throttled ones (every applied update, every
triggered Job, boot and shutdown among them) bypasses the rate limiter. If one
of those ever repeats, the repetition is the signal.

### The file log

Every line the controller emits is also written to
`/keelson/work/log/keelson.log` in plain format, whatever the level or throttle.
The controller loop is its only rotator, at the size and count set above;
watchers and children only append. The file lives on the `emptyDir` and does not
survive a Pod restart. `keelson-probe` writes no file, only stderr, which the
kubelet records in the Pod's events.


## Argo Rollouts

Use Argo Rollouts 1.9.0 or newer. Older CRDs record a Rollout's `containers` as
one atomic value. Mimic still works there, sending the owner's whole list back
with only the image changed, but claim-apply refuses, because sending the image
alone would replace the list; claim-patch works. After an upgrade to 1.9, a
Rollout whose owner recorded the list whole under the old CRD is refused by
mimic until the owner syncs it again, or claim-patch is used.


## Central registry config

Keelson reads `/configmap/registries.yaml`, mounted from the keelson ConfigMap:
a map keyed by registry host, each value an `auth-mode` and any fields that mode
takes. A rotated Secret or an edited file is picked up on the next poll pass.

```yaml
registries:
  ghcr.io:
    auth-mode: secret
  123.dkr.ecr.us-east-1.amazonaws.com:
    auth-mode: aws
  europe-docker.pkg.dev:
    auth-mode: gcp
  myregistry.azurecr.io:
    auth-mode: azure
```

A host with no entry is treated as anonymous.

### Auth modes

- **`secret`**: a `dockerconfigjson` Secret in Keelson's own namespace (or the
  entry's optional `namespace:`), named after the host. See below.
- **`aws`**: `docker-credential-ecr-login`, so whatever the AWS SDK credential
  chain provides: EKS Pod Identity, IRSA or an instance role.
- **`azure`**: federated workload-identity token, then Entra token, then ACR
  refresh token. Needs `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_TENANT_ID` and
  `AZURE_CLIENT_ID` on the Pod.
- **`gcp`**: a workload-identity access token from the GCE metadata server.

Cloud modes are named for the cloud, not the mechanism, because mechanisms get
superseded. The mechanism spellings are accepted as aliases and validated as the
mode they name:

| Canonical | Also accepted                   |
| --------- | ------------------------------- |
| `aws`     | `aws-irsa`, `aws-pi`, `aws-ecr` |
| `gcp`     | `gcp-wi`, `gcp-gar`, `gcp-gcr`  |
| `azure`   | `azure-wi`, `azure-acr`         |

### Secret naming for `auth-mode: secret`

|                     | Value                                     | Why                                    |
| ------------------- | ----------------------------------------- | -------------------------------------- |
| Secret name         | the map key with each `:` replaced by `-` | a colon is not legal in an object name |
| Key inside `.auths` | the map key as written                    | that is what Docker writes             |

So `reg.example:5000` reads Secret `reg.example-5000` and looks up
`reg.example:5000` inside it. Two optional fields override each half:

```yaml
registries:
  reg.example:1234:
    auth-mode: secret
    secret-name-override: reg-example-shared
  reg.example:5678:
    auth-mode: secret
    secret-name-override: reg-example-shared
    secret-key-override: https://reg.example:5678/v1/
```

- **`secret-name-override`** names the Secret, so several registries can share
  one.
- **`secret-key-override`** names the key inside `.auths`, for entries written
  with a scheme or path.

A raw IPv6 host needs the name override: `[::1]:123` would derive `[--1]-123`,
which is not a valid name.

### What is checked, and when

Keelson refuses to boot on any of these, naming the entry. One introduced by a
later ConfigMap edit drops that entry, keeps the rest, and logs an error every
pass until fixed.

| Rejected                                                                       | Why                                               |
| ------------------------------------------------------------------------------ | ------------------------------------------------- |
| An `auth-mode` that is not a mode or an alias of one                           | Keelson cannot authenticate with it               |
| A key that is not a hostname or bracketed IPv6 literal, with an optional port  | it cannot be read as a registry                   |
| The same key twice                                                             | one entry would silently win                      |
| A derived Secret name that is not a valid object name                          | no Secret could match; set `secret-name-override` |
| A `secret-name-override` that is not a valid object name                       | the same                                          |
| Two keys deriving the same Secret name, unless both set `secret-name-override` | one registry would get the other's credentials    |

A valid object name is an RFC 1123 subdomain: lowercase letters, digits, hyphens
and dots, starting and ending alphanumeric, at most 253 characters.

Hostnames are case-insensitive, so case is normalised (`REG.example.com` reads
as `reg.example.com`) with one warning at boot. Two spellings of one host count
as the same key twice.


## Per-workload annotations

Annotations go on the workload's `metadata.annotations`, prefixed `keelson.pro/`
under the default `KEELSON_CONFIG_MODE=keelson`, or `keel.sh/` under `keel`.

**A `policy` annotation is what makes a workload managed.** One with only
`pollSchedule` or `matchTag`, say, is cached but never updated, and the
managed-workloads list at boot leaves it out.

**Labels are never read.** Keel accepts some of its keys as labels; a workload
moving from Keel with settings in `metadata.labels` must move them to
annotations.

**Some keys have a second, hyphenated spelling**, accepted on `keelson.pro/`
(and on `keel.sh/` for `match-tag` and `poll-schedule`). camelCase is canonical
and used below.

| Canonical              | Also accepted            |
| ---------------------- | ------------------------ |
| `matchTag`             | `match-tag`              |
| `matchMode`            | `match-mode`             |
| `pollSchedule`         | `poll-schedule`          |
| `triggerJobOnUpdate`   | `trigger-job-on-update`  |
| `fieldManagerStrategy` | `field-manager-strategy` |

Both spellings of one key set to the same value log a warning; set to different
values, they are an error and the workload is not managed.

| Key                    | Values                                                                                                                                                          | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `policy`               | `major`, `minor`, `patch`, `all`, `part-<n>`, `never`                                                                                                           | Which part of the tag may change; everything to its left must match. `major` is the first part, `minor` the second and `patch` the last, whatever the tag's length, so `1.15.1.36.1` works like `1.2.3`. `part-<n>` names any part by number from 1. A tag with too few parts is skipped with `policy-position-incompatible-with-tag`. `all` equals `major`; `never` leaves the container alone. Keel's `force` is rejected. `part-<n>` is Keelson-only.                                                                                                                                                                                                                        |
| `matchTag`             | glob or regular expression                                                                                                                                      | Restrict the tags considered before the policy applies.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `matchMode`            | `glob` (default), `regex`                                                                                                                                       | How `matchTag` is read. Keelson-only.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `pollSchedule`         | `30s`, `5m`, `2h45m`, `1.5h`, `1d`, bare seconds, or `@every 10m`, `@hourly`, `@daily`, `@weekly`, `@monthly` (30d), `@yearly` (365d), `@midnight`, `@annually` | How often this workload's registry is polled, overriding `KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT`. Unparseable: `poll-schedule-invalid` and the default applies. Under one second: clamped to `1s` with `poll-schedule-too-fast`. A change to anything a decision depends on (image, annotations, service account, pull secrets, `spec.suspend`) polls the workload at once regardless.                                                                                                                                                                                                                                                                                         |
| `credentials`          | `central-then-pod-spec` (default), `central` (also `ignore-pod`), `respect-pod-spec`                                                                            | Which credentials to try, in order. The default tries `registries.yaml` first, then the workload's `imagePullSecrets` (and its ServiceAccount's, with `KEELSON_RESPECT_SA_PULL_SECRETS`). `central` never reads the pod spec; `respect-pod-spec` never reads `registries.yaml`. A credential the registry rejects falls through to the next. Central credentials are resolved once per poll pass and shared. The old `respect-pod` is rejected: its meaning changed. Keelson-only.                                                                                                                                                                                              |
| `initContainers`       | `true`, `false`                                                                                                                                                 | Whether init containers are in scope. Default `false`, as Keel; anything but `true` leaves them out. Usually wanted where an init container must not lag the app container it prepares.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `imageVolumes`         | `true`, `false`                                                                                                                                                 | Whether OCI image volumes (`spec.volumes[].image.reference`) are in scope. Default `false`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `monitorContainers`    | regular expression                                                                                                                                              | Only update containers whose name matches. Empty means all. Applies to init containers when in scope, never to image volumes. An invalid pattern is an error and nothing is updated until fixed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `monitorVolumes`       | regular expression                                                                                                                                              | The same for image volumes, by volume name.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `triggerJobOnUpdate`   | `true`, `false`                                                                                                                                                 | On a suspended CronJob, create a one-off Job each time Keelson updates its image, and once on the first poll of a suspended, annotated CronJob even with nothing to update, so one already on its newest tag still runs. The state ConfigMap records every image at each firing, so the controller never fires one update twice. A change made by anything other than Keelson moves the baseline and fires nothing. The CronJob must stay suspended (`spec.suspend: true`), or the scheduler and Keelson would both fire; otherwise the trigger is refused with `cronjob-trigger-requires-suspend`. `keelson-update-resource` fires it too, after its own update. Keelson-only. |
| `fieldManagerStrategy` | `mimic`, `claim-patch`, `claim-apply`                                                                                                                           | Override the [field-manager strategy](#field-manager-strategy) settings for this workload, whoever owns its image. `mimic` on an unowned image falls back to `claim-patch` when allowed. Any other value is refused with `update-invalid-strategy-annotation` and nothing is written. Keelson-only.                                                                                                                                                                                                                                                                                                                                                                             |
| `trigger`              | `default`, `poll`                                                                                                                                               | **Not acted on.** Keel's switch between webhook and poll updates; Keelson only polls.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `notify`               | sink name                                                                                                                                                       | **Not acted on.** Reserved for notifications.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

**Keel mode reads only Keel's keys.** Under `keel`, Keelson reads
`keel.sh/policy`, `pollSchedule`, `matchTag`, `initContainers`, `imageVolumes`,
`monitorContainers` and `monitorVolumes`. The Keelson-only keys have no
`keel.sh/` form, and a workload cannot mix prefixes, so under `keel` they cannot
be used at all.

A workload carries one prefix, in every mode. Mixing `keelson.pro/` and
`keel.sh/` on one workload is rejected with `dual-prefix-conflict` and Keelson
leaves it alone: a `keel.sh/` annotation suggests Keel itself may be running,
and two controllers writing the same image is worse than neither. Migrate by
removing the old annotations as you add the new ones.

### Which tags are considered

The running tag and every candidate must be dot-separated numbers (`1.2.3`,
`1.15.1.36.1`). An image pinned by digest, with no tag, tagged `latest`, or with
any non-numeric part (`v1.2`, `1.2-rc1`) is skipped; so is a candidate with a
different number of parts from the running tag.

### Per-container overrides

`policy`, `matchTag`, `matchMode` and `fieldManagerStrategy` can be scoped to
one container, or one image volume, by suffix; `credentials` to a container
only. Every other key is workload-wide.

```yaml
metadata:
  annotations:
    keelson.pro/policy: minor                       # every container
    keelson.pro/policy.containers.web: major        # the "web" container
    keelson.pro/matchTag.containers.db: '^pg-15\.'  # "db" only
    keelson.pro/matchMode.containers.db: regex
    keelson.pro/fieldManagerStrategy.volumes.models: claim-patch
```

The scoped key wins over the workload-wide one. `.containers.<name>` addresses a
container or init container, `.volumes.<name>` an image volume, so a container
and a volume sharing a name never address each other. The same applies to
`keel.sh/policy` and `keel.sh/matchTag` under `keel` mode.

### Init containers

Out of scope unless `initContainers: true`, as Keel. Once in, an init container
is updated like any other container and every annotation applies to it,
addressed by name with the `.containers.<name>` suffix (names are unique across
both lists):

```yaml
metadata:
  annotations:
    keelson.pro/initContainers: "true"
    keelson.pro/policy: minor
    keelson.pro/policy.containers.migrate: never   # leave "migrate" alone
```


## Keel annotations Keelson does not honour

Under `KEELSON_CONFIG_MODE=keel` or `both`, these are read but ignored, or in
one case rejected. Move the behaviour to your GitOps or CI layer.

- **`keel.sh/policy: force`**: redeploy every poll regardless of tag. Rejected
  with `keel-policy-force-unsupported`; use a real policy.
- **Digest tracking for unchanged tags**: Keelson only moves to a newer tag and
  treats tags as immutable.
- **`keel.sh/approvals`, `keel.sh/approvalDeadline`**: drive approvals from
  CI/CD or chat; Keelson applies eligible updates immediately.
- **`keel.sh/matchPreRelease`**: Keelson compares tags by position, not as
  semver, so there is no pre-release field. Use `matchTag`.
- **`keel.sh/releaseNotes`**: Keelson has no notification sinks yet.
- **`keel.sh/pollSchedule` as a cron expression**: every `@` descriptor is read,
  but a raw cron expression warns with `poll-schedule-invalid` and the default
  applies. Express the cadence as a duration.

Anything else Keel-specific is passed over.


## Not yet implemented

- **Notification sinks**: `notify` is parsed but Keelson sends nothing.
- **Other workload kinds** (Flux HelmRelease, ReplicaSet): only the kinds in
  `KEELSON_WATCHED_KINDS` are watched. Bare ReplicaSets are unsupported; use a
  Deployment.
- **Registry webhooks**: `trigger` is accepted, but Keelson only polls.
