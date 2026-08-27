# Configuration

Keelson reads configuration from three places, each owned by a different actor:

- **Environment variables** on the Keelson Pod — the operator sets these at deploy time.
- **`registries.yaml`** in the keelson ConfigMap — the operator declares which registries Keelson talks to and how it authenticates to each.
- **Workload annotations** — the workload owner controls per-workload behaviour.


## Environment variables

The Helm values (or templated Deployment) feed these directly into the Pod's `env`. Every variable is **required** — the scripts carry no built-in fallbacks, so `keelson-validate` (which `keelson` runs at boot) fails fast when one is missing. Defaults shipped in `src/defaults/Keelson/` populate the Deployment so a vanilla install just works.

Each row's left cell shows the env var on top and the matching Kaptain token below. If you're deploying with Kaptain, set the token in your `Keelson/…` env config directory; if you're using Helm the same options are available in `values.yaml`; if you're templating manifests another way, set the env var directly.

### Image-provided

These two are not operator settings and do not appear in the Deployment's `env`. The `keelson-package` build bakes them into the image with `ENV`, so they describe the artifact rather than configure it. `keelson-validate` still requires both: a missing one means the image was built wrong, and the boot line would otherwise report a version nobody can trace.

| Env Var | Set from | Purpose |
|---|---|---|
| `KEELSON_VERSION` | `${TemplateKeelsonVersion}` | The `keelson` release whose scripts are in the image. |
| `KEELSON_PACKAGE_VERSION` | `${Version}` | The `keelson-package` release that assembled the image, five parts (keelson template, base image, patch). |

Both are reported on the boot line: `Keelson <version> (package <package-version>) booting in ns '<ns>'`.

### Behaviour

| Env Var / Kaptain Token | Default | Purpose |
|---|---|---|
| `KEELSON_SCOPE`<br>`Keelson/Scope` | `cluster` | `cluster` watches every namespace; `namespace` watches only the one Keelson runs in. |
| `KEELSON_CONFIG_MODE`<br>`Keelson/ConfigMode` | `keelson` | Which annotation prefix Keelson honours: `keelson` for `keelson.pro/`, `keel` for `keel.sh/` (drop-in mode), or `both` (accept either, reject workloads that mix prefixes). |
| `KEELSON_LOG_LEVEL`<br>`Keelson/LogLevel` | `INFO` | `DEBUG`, `INFO`, `WARN`, `ERROR`. |
| `KEELSON_LOG_FORMAT`<br>`Keelson/LogFormat` | `plain` | `plain` or `json`. |
| `KEELSON_LOG_MANAGED_WORKLOADS`<br>`Keelson/LogManagedWorkloads` | `true` | List every workload Keelson will act on, grouped by namespace, once as soon as the first scan has filled the cache. The header carries the ratio (`7 of 312 cached workloads`), which is how you tell an annotation that did not take from one that did. Read from the cache, not the cluster, so it costs nothing. Set `false` on clusters where the list would run to hundreds of lines. |
| `KEELSON_RESPECT_SA_PULL_SECRETS`<br>`Keelson/RespectServiceAccountPullSecrets` | `false` | Set `true` to walk the workload's ServiceAccount `imagePullSecrets` after the Pod's own, matching what the kubelet sees post-admission. Costs one extra `get sa` per scan. |
| `KEELSON_WATCHED_KINDS`<br>`Keelson/WatchedKinds` | `Deployment StatefulSet DaemonSet CronJob` | Space-separated list. Anything not in this set is rejected by `keelson-validate`. ReplicaSets are intentionally excluded: a Deployment-owned ReplicaSet inherits its parent's annotations, so watching both would double-update; bare ReplicaSets are unsupported — convert to a Deployment. |
| `KEELSON_STATE_CONFIGMAP`<br>`Keelson/StateConfigMap` | `keelson-state` | Name of the ConfigMap carrying what must survive a pod restart. Written by server-side apply of the whole ledger under field manager `keelson`, the same identity Keelson claims workloads with — there is no patch path, so a key Keelson has forgotten is simply absent from the next write and the server drops it. Exactly one process writes it: the controller's children are subshells that inherit the loaded ledger, record what they change to a spool directory, and never contact the API themselves; the tick loop drains that spool and writes once, before spawning anything. Two writers applying the whole ledger would each drop what the other had just written, and a lost CronJob trigger record re-fires a Job that already ran. Conflicts are forced: the ConfigMap is wholly Keelson's, so if something else has taken a field, Keelson takes it back and carries on rather than stopping. There is nothing here to negotiate over. It carries six provenance annotations — `keelson.pro/createdAt`, `createdByVersion`, `createdByPackage` and the matching `updated*` three — so the record says which build wrote it, which the image tag, the label and the env can all disagree about. Two kinds of key: `w--<kind>--<ns>--<name>` records that Keelson has seen a workload (`first-seen`, written once) and whether it is acting on it (`managed`, rewritten only when it changes); `j--<kind>--<ns>--<name>` records the per-CronJob always-once trigger. No schedule is stored — `next-due` is derived from a hash of the workload's identity, so it is the same on every cold start and needs no ledger to survive a restart. A poll therefore writes nothing here. |
| `KEELSON_FIELD_MANAGER_STRATEGY_OWNED`<br>`Keelson/FieldManagerStrategyOwned` | `mimic` | Chooses between attributing the change to them (the detected Apply-op owner) or to us (`keelson`) when an Apply-op manager already owns the image field. `mimic` = SSA as their manager (no ownership churn, attribution to them). `patch` = strategic-merge patch as `keelson` (attribution to us, adds a Keelson Update entry). Per-workload override: annotation `keelson.pro/fieldManagerStrategy`. |
| `KEELSON_FIELD_MANAGER_STRATEGY_UNOWNED`<br>`Keelson/FieldManagerStrategyUnowned` | `patch` | Chooses the write method — patch or SSA — when no Apply-op manager owns the image field (Update-op ownership counts as unowned; Update entries don't participate in SSA conflict resolution). Attribution is always to us (`keelson`) in this row. `patch` = strategic-merge patch (adds a Keelson Update entry). `claim` = SSA (adds a Keelson Apply entry). Per-workload override: annotation `keelson.pro/fieldManagerStrategy`. |

### Tick loop and scan cadence

| Env Var / Kaptain Token | Default | Purpose |
|---|---|---|
| `KEELSON_TICK_INTERVAL`<br>`Keelson/TickInterval` | `1` | Seconds between the *start* of successive supervisor ticks: the cycle time, not the idle time. Each tick publishes the heartbeat, supervises watchers, re-reads whatever the watchers queued, polls whatever is due, kicks a scan if due, then sleeps whatever is left of the interval. A tick whose work outruns the interval sleeps not at all and logs `tick-overrun`. The watcher PID map is published by the supervisor when it changes, not on this cadence. |
| `KEELSON_RECONCILE_INTERVAL`<br>`Keelson/ReconcileInterval` | `60` | Seconds between reconcile scans: how often Keelson lists the cluster to refresh its workload cache and forget what has gone. A fallback and a safety net, not the thing that drives updates. Registry polling runs off each workload's own `next-due`, checked every `TickInterval`, so raising this costs cache freshness rather than update latency. Measured from the previous scan's start; long scans queue the next for the very next tick, never overlap. |
| `KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT`<br>`Keelson/RegistryPollIntervalDefault` | `60` | Seconds between registry tag lookups **for a given workload**, overridable per workload with the `poll-schedule` annotation. Distinct from `PollInterval`, which is how often Keelson lists the cluster: listing is one call per kind however many workloads there are, while a registry lookup is one call per eligible container and is the rate-limited one. Raising this is the lever for cutting registry traffic: a workload nothing has touched costs no registry calls at all between polls. New workloads are given an offset inside their first interval, derived from their identity, so an estate cached in one pass does not fall due in lockstep afterwards. |
| `KEELSON_FIRST_POLL_DELAY_MAX`<br>`Keelson/FirstPollDelayMax` | `300` | Seconds. Caps how long after being cached a workload can wait for its first poll. The offset is hashed from the workload's identity and spread across its interval, so a restart does not poll the estate at once; this bounds the other end. Without it a `poll-schedule` of `@every 24h` averages twelve hours out on a cold start, so a pod restarting more often than that would never poll the workload at all. Only bites above this value — at the default 60s interval nothing changes. Lowering it concentrates registry load after a restart. |
| `KEELSON_REGISTRY_POLL_CONCURRENCY`<br>`Keelson/RegistryPollConcurrency` | `2` | How many workloads the due-poll checks at once. A registry lookup is roughly two seconds of waiting for sixty milliseconds of work, so a serial poll spends nearly all of it idle: six workloads take 13.3s at `1`, 6.5s at `2`, 4.4s at `4`. **Coupled to `Keelson/Memory`** — each concurrent check is a `skopeo`, or a `kubectl` if it updates, at roughly 30-50MB resident. Raising this without raising memory gets the Pod OOM-killed, which reads as a crashloop rather than a misconfiguration. Sizing: base is 64-89Mi measured, plus concurrency times ~50MB. |
| `KEELSON_POLL_OVERRUN_WARNING_BACKOFF_LIMIT`<br>`Keelson/PollOverrunWarningBackoffLimit` | `64` | How far the `poll-pass-overrun` warning backs off, in passes. A poll pass that takes longer than the shortest poll schedule among the workloads it polled cannot hold that schedule, so it warns; consecutive overruns are reported on the 1st, 2nd, 4th, 8th and so on, then every this-many-th, and a pass that fits resets the count. Passes, not seconds: a pass is as long as it is, which is the thing being complained about. The count is kept on disk because each pass runs in its own subshell, which is also why `KEELSON_LOG_WARN_REPEAT_INTERVAL` cannot throttle it. Lower for a louder warning, raise for a quieter one; there is no value that silences it altogether, deliberately, because the condition does not clear itself. |
| `KEELSON_RECONCILE_OVERRUN_WARNING_BACKOFF_LIMIT`<br>`Keelson/ReconcileOverrunWarningBackoffLimit` | `64` | How far the `reconcile-pass-overrun` warning backs off, in scans. A reconcile scan that takes longer than `ReconcileInterval` means the cluster is being listed as fast as it can be rather than on the cadence configured, which is otherwise entirely silent: the next scan simply starts on the following tick, never overlapping, never saying so. Reported on the 1st, 2nd, 4th, 8th consecutive overrun and so on, then every this-many-th, with a scan that fits resetting the count. Same shape as `PollOverrunWarningBackoffLimit` and separate from it, because a slow list and a slow registry are different problems with different fixes. |
| `KEELSON_FULL_REFRESH_INTERVAL`<br>`Keelson/FullRefreshInterval` | `86400` (24h) | Seconds between full refreshes. A refresh throws the local workload cache away and rebuilds it from the cluster, one kind per tick so no single pass runs long, then reconciles the ledger against what came back: entries for kinds no longer watched are dropped, and ledger keys whose workload no longer exists are removed. Belt and braces rather than the mechanism: watch events and the reconcile scan keep the cache current between refreshes, so this exists to correct drift nothing else can see, such as a hand-edited ConfigMap or a cache file that went bad. Makes no registry calls. |
| `KEELSON_HEARTBEAT_MAX_AGE`<br>`Keelson/HeartbeatMaxAge` | `5` | Seconds before the kubelet's liveness probe treats the heartbeat as stale. Whole seconds here, but the comparison is made in microseconds at both ends, so the limit is exact rather than plus or minus a second. Keep close to `KEELSON_TICK_INTERVAL` — too generous masks a wedged loop, too tight false-positives on jitter. The lower end of that is enforced: it must be **at least twice `KEELSON_TICK_INTERVAL`**, checked by `keelson-validate` at boot. The loop writes the heartbeat once per tick, so a smaller allowance leaves no room for scheduling jitter and the kubelet kills a healthy controller; two ticks means one whole tick may be missed before liveness is entitled to call the loop wedged. Raising `KEELSON_TICK_INTERVAL` therefore requires raising this with it. Nothing enforces the upper end — that one is on you. |

### Watcher supervision

| Env Var / Kaptain Token | Default | Purpose |
|---|---|---|
| `KEELSON_WATCHER_RESPAWN_BACKOFF_MAX`<br>`Keelson/WatcherRespawnBackoffMax` | `300` | Cap on per-kind respawn delay (s). Failures back off `1, 2, 4, 8...` capped here, CrashLoopBackOff-style. |
| `KEELSON_WATCHER_RESPAWN_HEALTHY_RESET`<br>`Keelson/WatcherRespawnHealthyReset` | `30` | Seconds a watcher must stay alive before its failure count resets to zero. |
| `KEELSON_WATCHER_RECONNECT_INITIAL`<br>`Keelson/WatcherReconnectInitial` | `2` | Initial delay (s) inside a single watcher before it reconnects to its `kubectl watch` stream. Independent from the supervisor's respawn backoff above — the watcher reconnects in-process when its stream ends. |
| `KEELSON_WATCHER_RECONNECT_MAX`<br>`Keelson/WatcherReconnectMax` | `60` | Cap on the in-watcher reconnect delay. |
| `KEELSON_WATCHER_RECONNECT_RESET`<br>`Keelson/WatcherReconnectReset` | `30` | Seconds a single watch stream must hold before it counts as healthy and the reconnect delay drops back to `WatcherReconnectInitial`. Streams end for routine reasons, so without this the delay only ever climbs and a healthy watcher sits at the cap for the life of the Pod. Distinct from `WatcherRespawnHealthyReset`, which measures how long the watcher *process* has been alive; this measures how long one *stream* lasted. |

### Log throttling and the file log

| Env Var / Kaptain Token | Default | Purpose |
|---|---|---|
| `KEELSON_LOG_DEBUG_REPEAT_INTERVAL`<br>`Keelson/LogDebugRepeatInterval` | `0` | Seconds. The rate limiter suppresses a repeat of the same `(level, event, sorted-kv-pairs)` hash within this window. `0` disables throttling for the level. |
| `KEELSON_LOG_INFO_REPEAT_INTERVAL`<br>`Keelson/LogInfoRepeatInterval` | `120` | Same shape, info level. The throttle-eligible info events are `dry-run-would-update` and `watch-start` (which can fire on every in-watcher reconnect); the rest use `_always` so every event lands. |
| `KEELSON_LOG_WARN_REPEAT_INTERVAL`<br>`Keelson/LogWarnRepeatInterval` | `300` | Warn-level repeats (`watch-disconnected`, `watch-failed`, `watcher-respawned`) collapse inside this window. |
| `KEELSON_LOG_ERROR_REPEAT_INTERVAL`<br>`Keelson/LogErrorRepeatInterval` | `600` | Error-level repeats (registry/auth failures, kubectl-list failures) collapse inside this window. |
| `KEELSON_LOG_FILE_MAX_BYTES`<br>`Keelson/LogFileMaxBytes` | `10485760` | Rotate `/keelson/work/log/keelson.log` once it grows past this many bytes (default 10 MiB). Checked once per tick by the controller, so the file can overshoot by up to one tick's worth of logging. |
| `KEELSON_LOG_FILE_KEEP`<br>`Keelson/LogFileKeep` | `5` | Number of rotated `.1, .2, …` files to retain. Older than this are dropped on rotate. |

The file log path is convention, not configuration: `/keelson/work/log/keelson.log` (under the Pod's `emptyDir`).

A misconfigured variable here fails `keelson-validate`, so the Pod refuses to boot rather than running with surprising defaults.


## Resources

| Kaptain Token | Default | Applied as |
|---|---|---|
| `Keelson/Memory` | `250Mi` | request **and** limit, sized for the worst instant rather than the common one. A poll is cheap: 89Mi observed steady plus `Keelson/RegistryPollConcurrency` concurrent `skopeo` at 30MB measured, so 149Mi at the default 2. An **update** is the expensive moment — `workload_managed_fields` pipes `kubectl` into `yq`, so both are resident together, roughly 80MB per child, and concurrency 2 permits two of those at once: 89 + 160. Note the base figure was taken on a cluster where almost nothing was managed, so a registry check was essentially never in it — this is not the old default plus one check. `kubectl`'s own footprint is the one estimate left in that sum and is worth measuring in the pod. **Raise this with concurrency**: exceeding the limit is an OOM kill, which presents as a crashloop rather than as a misconfiguration. |
| `Keelson/CpuRequest` | `100m` | request only (no limit is set) |
| `Keelson/EphemeralStorage` | `150Mi` | request **and** limit |

Memory request equals limit so the allocation is guaranteed and a leak dies predictably rather than growing into the node. Steady state is 64-89 MiB, so the default leaves room for a scan burst without over-reserving.

There is deliberately **no CPU limit**. The tick loop is idle most of every second and then forks hard during a scan, which is exactly the shape a CPU limit throttles worst: a throttled tick reads as a wedged loop and the liveness probe restarts a controller that was only slow. Anyone who needs a limit has a `LimitRange` that will impose one.

Ephemeral storage is tight on purpose, and the budget is worth knowing because it is a sum of three things. The Pod's quota covers the `emptyDir`, the container's writable layer, **and** the node-level container log for stdout. At Kubernetes' own defaults the console log rotates at 10Mi across 5 files, so 50Mi; Keelson's own log file is `LogFileMaxBytes × (LogFileKeep + 1)`, so 60Mi at defaults, since the live file reaches its size before rotating; the cache, queue and status files are under 1Mi even for a few hundred workloads. That is 120Mi at full convergence, which for a long-lived pod is where it settles rather than a spike. 150Mi is the margin over that. Lower `LogFileMaxBytes` and `LogFileKeep` together if you want it smaller: they are the only half of the sum Keelson controls.

## Probe timings

Startup, readiness and liveness probes have sensible defaults but are all overrideable.

| Kaptain Token | Default |
|---|---|
| `Keelson/StartupProbePeriodSeconds` | `5` |
| `Keelson/StartupProbeFailureThreshold` | `24` |
| `Keelson/StartupProbeTimeoutSeconds` | `4` |
| `Keelson/ReadinessProbePeriodSeconds` | `20` |
| `Keelson/ReadinessProbeFailureThreshold` | `2` |
| `Keelson/ReadinessProbeTimeoutSeconds` | `5` |
| `Keelson/LivenessProbePeriodSeconds` | `15` |
| `Keelson/LivenessProbeFailureThreshold` | `5` |
| `Keelson/LivenessProbeTimeoutSeconds` | `6` |

Budgets at those defaults: 120s to start, 40s to NotReady, 75s to a liveness kill. Keep each `timeoutSeconds` under its `periodSeconds` for obvious reasons.

Liveness is biased toward not killing, because restarting Keelson costs more than it fixes. The work queue lives on the Pod's `emptyDir` and goes with it, and every watcher's `kubectl get --watch` re-lists its whole kind before streaming, so a restart produces the largest event burst Keelson can generate. Against that, a wedged controller noticed a minute later is invisible at a 60s poll cycle.

Keelson exposes no Service, so readiness only colours the READY column and gates rollouts. It runs at the lowest frequency for that reason.


## Logging

Better logging is a key promise for the creation of Keelson, this is the logging description.

### Log Philosophy

For the happy path log only what actually changes or goes wrong or things that happen once at startup. For the unhappy paths, warn or error, rate limit as configured by the consumer to a period between the same message being printed so as not not immediately flush away useful information. For debug by default print everythign always - but tunable by the consumer to slow down duplicates to whatever level is configured. For all messages they're in files inside the pod and rotated by size and file count so that you can run default info level logging and still get debug and complete logging by getting inside the pod and reading or tailing the files. By this method it's never confusing what's going on. Enjoy :-)

### Log Levels

`KEELSON_LOG_LEVEL` is a threshold, not a filter set: each level emits its own events **plus everything above it**. Format is controlled separately by `KEELSON_LOG_FORMAT` (`plain` or `json`); the event name and `key=value` pairs are identical either way, so log queries port between the two.

| Level | What it adds on top of the level below | Use it for |
|---|---|---|
| `error` | Hard failures Keelson cannot work around on its own. Registry lookups (`registry-creds-failed`, `registry-list-tags-failed`, `registry-namespace-unknown`), scan-time API calls (`kubectl-list-failed`), patch attempts (`update-failed`, `update-apply-conflict`, `update-refused-mimic-unowned`, `update-invalid-strategy-annotation`, `update-unsupported-kind`, `cronjob-job-trigger-failed`, `cronjob-trigger-requires-suspend`), state writes (`state-configmap-create-failed`, `state-flush-failed`, `state-namespace-unknown`), probe failures (`probe-liveness-fail`, `probe-readiness-fail`, on stderr only: see below), and every `validate-*` boot check. | Page-worthy. Persistent errors mean misconfiguration, broken RBAC, or a registry outside Keelson's reach. |
| `warn` | Everything `error` shows, plus transient faults the controller recovers from on its own. `watch-disconnected` (a healthy kubectl stream ended; reconnecting), `watch-failed` (kubectl exited non-zero, carrying its own error text and the consecutive failure count), `watcher-died` and `watcher-respawned` (the supervisor saw a death and is bringing the watcher back), `state-reload-failed` (the scan child continues without the prior trigger state), `state-init-failed` (entry-point ConfigMap load failed; the next tick retries), `poll-schedule-invalid` (an unparseable annotation; the global default applies), `poll-schedule-too-fast` (a sub-second annotation; clamped to 1s), `tick-overrun` (a tick's work ran past `KEELSON_TICK_INTERVAL`, so the next one started with no sleep). | Alerting on connectivity churn or noisy backoff loops. Single warns are normal; a steady rate is a signal. |
| `info` *(default)* | Everything `warn` shows, plus the lean operational journal: only changes and one-shot lifecycle events. `boot`, `shutdown`, `validate-passed`, the initial `watcher-spawned`, `full-refresh-due` and `full-refresh-complete`, `inventory-refreshed` (one kind rebuilt), `scan-resync` (a workload's decision inputs moved, so it is polled at once rather than waiting out its schedule), `watch-start` (the in-watcher stream open — fires once per reconnect, throttled), `state-configmap-created` (first-boot ledger creation), `update-applied`, `cronjob-job-triggered`, and `dry-run-would-update`. Kept deliberately quiet — a healthy cluster produces little noise and real signals stand out. | The default. An operator should be able to read info logs at the rate Keelson emits them without filters. |
| `debug` | Everything `info` shows, plus the high-frequency mechanics: `scan-start`/`scan-summary` bookends, every `skip-not-eligible`, `no-change`, and `dry-run-no-change`, every `watch-enqueued` (carrying the event type), `watch-evicted` (a deleted workload dropped from the cache), `queue-refreshed` (how many queued identities the tick re-read), `queue-refresh-listing` (a burst large enough that listing the kinds beat reading them one at a time), `queue-refresh-failed` (a queued identity could not be re-read; its cache record is left alone), every `state-flushed`, `ledger-forgotten` (a ledger key dropped because its workload is gone), `poll-summary` (what the tick's due-poll did), and `inventory-evicted` (a cached workload the cluster no longer has). | Tracing why a particular workload event did or didn't trigger a scan, or why a candidate tag was or wasn't picked. Verbose; not recommended in production. |

The rate limiter hashes `level + event + sorted-kv-pairs` and drops a repeat hit on the same hash within its level's interval. **Unique events** (the ones using the `_always` variant in the code) bypass it: every applied update, every triggered job, every boot/shutdown is logged in full. If a bug ever causes one of these to repeat, the repetition is the signal — not something the limiter masks.

In parallel with stdout/stderr, **every emission from the controller is also written to `/keelson/work/log/keelson.log`** in plain format, regardless of `KEELSON_LOG_LEVEL` or throttle state. `keelson-probe` is the one exception: it writes no file, only stderr, which is what the kubelet captures into the Pod event you read a probe failure from. It reads the controller's state rather than authoring the controller's trail, and on a liveness kill the container restarts and takes the `emptyDir` with it, so the file would not have survived to be read anyway. The file rotates when it grows past `KEELSON_LOG_FILE_MAX_BYTES` and keeps `KEELSON_LOG_FILE_KEEP` numbered backups (`.1, .2, …`). Many processes append to it (the controller loop, one watcher per watched kind, every scan child) and concurrent appends are safe, but the rename shuffle a rotation performs is not, so rotation has a single owner: the controller loop checks the size once per tick. Nothing else ever rotates, which means the file is only bounded while the controller is running. This is the verification trail: inspect it when INFO-level stdout isn't enough but full `DEBUG` is too much. The file lives on the Pod's `emptyDir`, so it does not survive pod restarts (which is the intended baseline — a restart re-emits the lean INFO trail).

JSON format adds `ts` and `level` keys to every line; plain format prefixes each line with `<ISO-timestamp> <LEVEL>` followed by the event name and pairs.


## Central registry config

Keelson reads `/configmap/registries.yaml`, mounted from the keelson ConfigMap. The file is a map keyed by registry host; the value carries an `auth-mode` and any mode-specific fields.

```yaml
registries:
  ghcr.io:
    auth-mode: secret
  123.dkr.ecr.us-east-1.amazonaws.com:
    auth-mode: aws-irsa
  europe-docker.pkg.dev:
    auth-mode: gcp-wi
  myregistry.azurecr.io:
    auth-mode: azure-wi
```

If a host has no entry, Keelson treats it as anonymous.

### Auth modes

- **`secret`** — pull `dockerconfigjson` from a Kubernetes Secret in Keelson's own namespace. The Secret's name **must equal the registry host** (the map key). Override the lookup namespace with an optional `namespace:` field on the entry.
- **`aws-irsa`** — fetch credentials via `docker-credential-ecr-login`, which uses the Pod's IRSA role (the standard `AWS_*_TOKEN_FILE` env).
- **`azure-wi`** — federated workload-identity token → AAD token → ACR refresh token. Requires `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` on the Pod.
- **`gcp-wi`** — workload-identity access token from the GCE metadata server.


## Per-workload annotations

Annotations live on the workload's `metadata.annotations`. Under the default `KEELSON_CONFIG_MODE=keelson` every key is prefixed `keelson.pro/`; under `keel` use the `keel.sh/` prefix and Keelson translates the value where it can.

**Two spellings are accepted for every multi-word key.** camelCase is canonical and is what this document uses; the hyphenated form is equally valid on either prefix. Keel's own surface mixes the two, so a workload moving between the projects should not have to be rewritten:

| Canonical | Also accepted |
|---|---|
| `matchTag` | `match-tag` |
| `matchMode` | `match-mode` |
| `pollSchedule` | `poll-schedule` |
| `triggerJobOnUpdate` | `trigger-job-on-update` |
| `initContainers` | `true`, `false` | Whether init containers are in scope. **Defaults to `false`** in every config mode, as keel does. Anything but a literal `true` leaves them out, so a rejected or mistyped value fails closed rather than quietly enabling them. Once in scope an init container is updated like any other, and one left a release behind the app container it prepares is the skew this exists to prevent — so turn it on for workloads where that matters. |
| `monitorContainers` | regular expression | Restrict updates to containers whose **name** matches. Empty means all, which is keel's shape and default. Applies to init containers too, when they are in scope. A pattern that is not a usable regular expression is an error and nothing is monitored until it is fixed — falling back to "monitor everything" would turn a typo into an estate-wide update. Distinct from scoping `policy.<container>`, which addresses one container by name; use whichever reads better. |
| `fieldManagerStrategy` | `field-manager-strategy` |

Setting **both spellings of the same key to the same value** logs a warning naming the older one, and Keelson carries on. Setting them to **different values** is an error and the workload is not managed — whichever Keelson picked would be somebody's surprise, so it picks neither. Both checks apply per scope, so a `.<container>` pair is caught the same way, and a container-suffixed key still beats a workload-wide one.


| Key (logical) | Values | Purpose |
|---|---|---|
| `policy` | `major`, `minor`, `patch`, `all`, `part-<n>`, `glob:<pattern>`, `regexp:<pattern>` | Which part of the tag may change; everything to its left must match exactly. `major` is the first part, `minor` the second, `patch` the last **whatever the length** — none of them assume three, so a five-part release like `1.15.1.36.1` works as naturally as `1.2.3`. `part-<n>` names any part by number, 1-indexed and unbounded (`part-3`, `part-12`), for the ones the shorthands cannot reach: on a five-part release `major`, `minor` and `patch` give you the first, second and fifth, leaving the third and fourth with no other name. `minor` needs at least two parts and `part-<n>` needs at least `n`; a tag with fewer is skipped with `policy-position-incompatible-with-tag`. `all` is identical to `major`. Keel's `force` is rejected, and `part-<n>` is Keelson-only — keel's policy parser is a closed set with no positional form. |
| `matchTag` | regex / glob | Restrict the tag set considered before policy applies. |
| `matchMode` | `regex`, `glob` | Selects how `matchTag` is interpreted. |
| `trigger` | `default`, `poll` | **Deferred: not read.** Keel's switch between webhook-driven and poll-driven updates. Keelson polls, and a registry webhook path is future work, so setting this changes nothing either way today. |
| `pollSchedule` | duration: `30s`, `5m`, `2h45m`, `1.5h`, `1d`, bare seconds, or Keel's `@every 10m` / `@hourly` / `@daily` / `@weekly` | How often this workload's registry is polled for tags, overriding `KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT`. An unparseable value is ignored with a `poll-schedule-invalid` warning and the global default applies. A value below Keelson's one-second resolution is clamped to `1s` with a `poll-schedule-too-fast` warning, since that is far closer to the intent than the global default would be. A watch event on the workload makes Keelson re-read it, and anything a decision depends on having moved — image, annotations, service account, image pull secrets, `spec.suspend` — brings the next poll forward to immediately, regardless of the schedule. A write that touched none of them, which is most of what a watch delivers, leaves the schedule alone. |
| `credentials` | `respect-pod` (default), `central`, `ignore-pod` | Which credential path Keelson uses. `respect-pod` walks the workload's `imagePullSecrets` first, then falls through to central. `central` skips the Pod entirely. |
| `triggerJobOnUpdate` | `true`, `false` | On a CronJob with `spec.suspend: true`, create a one-off Job whenever Keelson updates the image. It also fires **once** the first time Keelson polls a suspended, annotated CronJob even if there is nothing to update, so one that was already on its newest tag when Keelson took it over still runs rather than waiting for a future release. The state ConfigMap records every container's image at the moment it fired, so the same update cannot repeat and a multi-container CronJob compares against all of them rather than whichever one happened to be written. A change made by anything other than Keelson does not fire a Job: it moves the baseline the next poll compares against, exactly as for any other workload. Only the poll evaluates this: the reconcile scan, the full refresh and the queued re-read all run cache-only, because two of them overlapping would each read "never triggered" and each create a Job. The CronJob must stay suspended; otherwise the scheduler and Keelson would both fire. |
| `fieldManagerStrategy` | `mimic`, `patch`, `claim` | Override the global `KEELSON_FIELD_MANAGER_STRATEGY_OWNED` / `_UNOWNED` default for this workload. Each value is a (write method, attribution) pair: `mimic` = SSA attributed to the detected Apply owner; `patch` = strategic-merge patch attributed to us (`keelson`); `claim` = SSA attributed to us. `mimic` requires an Apply-op field owner and is rejected (error, workload skipped) when the image field has none. `patch` and `claim` are always valid. Invalid values (typos) are rejected with an error and the workload is skipped this cycle. Keelson-only — no `keel.sh/` equivalent. |
| `notify` | sink name | **Deferred: not read.** Reserved for notification routing. |

A workload must carry **one** prefix, in every mode. Mixing `keelson.pro/` and `keel.sh/` triggers a `dual-prefix-conflict` rejection and Keelson does not manage it. This is not about ambiguity: a `keel.sh/` annotation is evidence that keel itself may be running, and two controllers writing the same image field is worse than either doing nothing. Presence of both prefixes is the signal, not a clash on one key — `keelson.pro/policy` alongside `keel.sh/pollSchedule` is enough. Migrating between the two means removing the old annotations as you add the new ones.

### Per-container overrides

Pods with multiple containers can scope any of the keys above to a single container by appending `.<container-name>`:

```yaml
metadata:
  annotations:
    keelson.pro/policy: minor              # default for every container
    keelson.pro/policy.web: major          # the "web" container gets major bumps
    keelson.pro/matchTag.db: '^pg-15\.'    # restrict tag set for "db" only
    keelson.pro/matchMode.db: regex        # matchTag is a glob unless you say this
```

The container-suffixed key wins when present; otherwise Keelson falls back to the workload-wide key. The same precedence applies under `KEELSON_CONFIG_MODE=keel` with `keel.sh/policy.<container>`.

### Init containers

Init containers are **out of scope until you opt in** with `initContainers: true`, matching keel's default in every config mode. Once opted in they are updated exactly like any other container and every annotation above applies to them unchanged, including `monitorContainers` and the `.<container>` suffix. Worth knowing what the default costs you: an init container that prepares the app container it runs alongside is precisely the thing that must not drift a release behind it, so a workload with one is usually a workload that wants this on.

Container names are unique across `containers` and `initContainers` within a pod spec, so a per-container override addresses an init container by name like any other:

```yaml
metadata:
  annotations:
    keelson.pro/policy: minor
    keelson.pro/policy.migrate: never   # leave the "migrate" init container alone
```

The only place the distinction matters is where Keelson writes an update back, since the two lists are separate keys in the pod spec.


## Keel annotations Keelson does not honour

Keel offers a wider feature set than Keelson aims to match. Under
`KEELSON_CONFIG_MODE=keel` (or `both`) the keys below are read but ignored, and
in one case actively rejected. Workloads relying on them need their behaviour
moved elsewhere — usually to the GitOps or CI layer where it belongs.

- **`keel.sh/policy: force`** — redeploy on every poll regardless of tag.
  Keelson rejects the workload with `keel-policy-force-unsupported`. Use a
  semver, glob, or regex policy instead.
- **Digest tracking for unchanged tags** — Keel can re-pull when the image
  digest behind a fixed tag (e.g. `:latest`) changes. Keelson updates only on a
  newer tag and treats tag-immutability as a hard invariant.
- **`keel.sh/approvals`, `keel.sh/approvalDeadline`** — Keel's in-controller
  approval workflow. Drive approvals from your CI/CD or chat platform; Keelson
  applies eligible updates immediately.
- **`keel.sh/preDeploy`, `keel.sh/postDeploy`** — pre/post-update shell hooks.
  Run those steps from the workload's own lifecycle (initContainers, Jobs) or
  from CI.
- **`keel.sh/imageVolumes`** — track OCI image volume references
  (`spec.volumes[].image.reference`). Keel defaults this to false and Keelson
  does not read image volumes at all, so an opted-in workload loses that
  tracking. `keel.sh/initContainers` and `keel.sh/monitorContainers` **are**
  honoured, with keel's defaults — see the table above.
- **`keel.sh/maxAge`** — skip tags older than a duration. Express the
  constraint through `match-tag` (with `match-mode: regex`) or by tagging
  discipline upstream.
- **`keel.sh/releaseNotes`** — surface release notes alongside notifications.
  Keelson has no notification sinks yet, so the value has nowhere to go.
- **`keel.sh/pollSchedule` as a raw cron expression** — Keel accepts robfig
  cron syntax as well as the `@every` descriptor its own docs recommend.
  Keelson reads `@every 10m`, `@hourly`, `@daily` and `@weekly`, and warns
  with `poll-schedule-invalid` on a raw cron expression or on `@monthly` /
  `@yearly`, falling back to `KEELSON_REGISTRY_POLL_INTERVAL_DEFAULT`. Those forms are
  calendar positions rather than durations; express the cadence as a duration
  instead.
- **Sub-second poll precision** — Keel's `pollSchedule` is a Go duration, so
  its syntax accepts `ns`, `us` and `ms`. Keelson schedules in whole seconds
  and rounds to the nearest, clamping anything below half a second to `1s`.
  In practice Keel struggles below a minute anyway (keel-hq/keel
  [#663](https://github.com/keel-hq/keel/issues/663)); Keelson polls happily
  at `30s` or faster, bounded by what your registry will tolerate.
- **`keel.sh/monitor-container`** — restrict monitoring to a named container in
  a multi-container Pod. Keelson scans every container in the workload's Pod
  spec.

Anything Keel-specific not listed here is either silently passed over or
covered by an equivalent `keelson.pro/` key documented above.


## Keelson features not yet implemented

The keys and behaviours below appear in the configuration surface or in the
roadmap but do nothing today. Future releases will fill them in; do not rely on
them yet.

- **Notification sinks** — the `notify` annotation is parsed and the keelson
  ConfigMap can hold a notifications block, but Keelson emits to none of the
  usual targets (Slack, webhook, email). Watch the changelog before wiring
  workloads to expect alerts.
- **Argo Rollouts** — `Rollout` is a recognised kind but Keelson does not
  watch or patch it yet. Treat managed Rollouts as out of scope for the
  current release.
- **HelmRelease (Flux) and other CRD-shaped workloads** — Keelson watches
  only the core kinds listed under `KEELSON_WATCHED_KINDS`
  (Deployment, StatefulSet, DaemonSet, CronJob).
- **ReplicaSet** — not watched. A Deployment-owned ReplicaSet inherits
  the Deployment's annotations and is updated by patching the Deployment;
  watching ReplicaSets directly would cause the same container to be
  updated twice. Bare ReplicaSets (no Deployment) are unsupported.
- **Event-driven `trigger`** — the annotation accepts `default` and `poll`,
  but Keelson only polls. A registry-webhook listener is planned.
