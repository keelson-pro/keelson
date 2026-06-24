# Configuration

Keelson reads configuration from three places, each owned by a different actor:

- **Environment variables** on the Keelson Pod — the operator sets these at deploy time.
- **`registries.yaml`** in the keelson ConfigMap — the operator declares which registries Keelson talks to and how it authenticates to each.
- **Workload annotations** — the workload owner controls per-workload behaviour.


## Environment variables

The Helm values (or templated Deployment) feed these directly into the Pod's `env`. Every variable is **required** — the scripts carry no built-in fallbacks, so `keelson-validate` (which `keelson` runs at boot) fails fast when one is missing. Defaults shipped in `src/defaults/Keelson/` populate the Deployment so a vanilla install just works.

Each row's left cell shows the env var on top and the matching Kaptain token below. If you're deploying with Kaptain, set the token in your `Keelson/…` env config directory; if you're using Helm the same options are available in `values.yaml`; if you're templating manifests another way, set the env var directly.

### Behaviour

| Env Var / Kaptain Token | Default | Purpose |
|---|---|---|
| `KEELSON_SCOPE`<br>`Keelson/Scope` | `cluster` | `cluster` watches every namespace; `namespace` watches only the one Keelson runs in. |
| `KEELSON_CONFIG_MODE`<br>`Keelson/ConfigMode` | `keelson` | Which annotation prefix Keelson honours: `keelson` for `keelson.pro/`, `keel` for `keel.sh/` (drop-in mode), or `both` (accept either, reject workloads that mix prefixes). |
| `KEELSON_LOG_LEVEL`<br>`Keelson/LogLevel` | `info` | `debug`, `info`, `warn`, `error`. |
| `KEELSON_LOG_FORMAT`<br>`Keelson/LogFormat` | `plain` | `plain` or `json`. |
| `KEELSON_RESPECT_SA_PULL_SECRETS`<br>`Keelson/RespectServiceAccountPullSecrets` | `false` | Set `true` to walk the workload's ServiceAccount `imagePullSecrets` after the Pod's own, matching what the kubelet sees post-admission. Costs one extra `get sa` per scan. |
| `KEELSON_WATCHED_KINDS`<br>`Keelson/WatchedKinds` | `Deployment StatefulSet DaemonSet CronJob` | Space-separated list. Anything not in this set is rejected by `keelson-validate`. ReplicaSets are intentionally excluded: a Deployment-owned ReplicaSet inherits its parent's annotations, so watching both would double-update; bare ReplicaSets are unsupported — convert to a Deployment. |
| `KEELSON_STATE_CONFIGMAP`<br>`Keelson/StateConfigMap` | `keelson-state` | Name of the ConfigMap that carries the per-CronJob always-once trigger ledger across pod restarts. |

### Tick loop and scan cadence

| Env Var / Kaptain Token | Default | Purpose |
|---|---|---|
| `KEELSON_TICK_INTERVAL`<br>`Keelson/TickInterval` | `1` | Seconds between supervisor ticks. Each tick: supervise watchers, drain queue, kick scan if due, write the status file. |
| `KEELSON_POLL_INTERVAL`<br>`Keelson/PollInterval` | `60` | Seconds between scan starts (measured from the previous scan's start time; long scans queue the next for the very next tick, never overlap). |
| `KEELSON_FULL_REFRESH_INTERVAL`<br>`Keelson/FullRefreshInterval` | `3600` | Seconds between trigger-state cache reloads from the ConfigMap. Picks up any out-of-band edits an operator made. |
| `KEELSON_HEARTBEAT_MAX_AGE`<br>`Keelson/HeartbeatMaxAge` | `5` | Seconds before the kubelet's liveness probe treats the status file as stale. Keep close to `KEELSON_TICK_INTERVAL` — too generous masks a wedged loop, too tight false-positives on jitter. |

### Watcher supervision

| Env Var / Kaptain Token | Default | Purpose |
|---|---|---|
| `KEELSON_WATCHER_BACKOFF_MAX`<br>`Keelson/WatcherBackoffMax` | `300` | Cap on per-kind respawn delay (s). Failures back off `1, 2, 4, 8...` capped here, CrashLoopBackOff-style. |
| `KEELSON_WATCHER_HEALTHY_RESET`<br>`Keelson/WatcherHealthyReset` | `30` | Seconds a watcher must stay alive before its failure count resets to zero. |
| `KEELSON_WATCHER_RECONNECT_INITIAL`<br>`Keelson/WatcherReconnectInitial` | `2` | Initial delay (s) inside a single watcher before it reconnects to its `kubectl watch` stream. Independent from the supervisor's respawn backoff above — the watcher reconnects in-process when its stream ends. |
| `KEELSON_WATCHER_RECONNECT_MAX`<br>`Keelson/WatcherReconnectMax` | `60` | Cap on the in-watcher reconnect delay. |

### Log throttling and the file log

| Env Var / Kaptain Token | Default | Purpose |
|---|---|---|
| `KEELSON_LOG_DEBUG_REPEAT_INTERVAL`<br>`Keelson/LogDebugRepeatInterval` | `0` | Seconds. The rate limiter suppresses a repeat of the same `(level, event, sorted-kv-pairs)` hash within this window. `0` disables throttling for the level. |
| `KEELSON_LOG_INFO_REPEAT_INTERVAL`<br>`Keelson/LogInfoRepeatInterval` | `120` | Same shape, info level. The throttle-eligible info events are `dry-run-would-update` and `watch-start` (which can fire on every in-watcher reconnect); the rest use `_always` so every event lands. |
| `KEELSON_LOG_WARN_REPEAT_INTERVAL`<br>`Keelson/LogWarnRepeatInterval` | `300` | Warn-level repeats (`watch-disconnected`, `watcher-respawned`) collapse inside this window. |
| `KEELSON_LOG_ERROR_REPEAT_INTERVAL`<br>`Keelson/LogErrorRepeatInterval` | `600` | Error-level repeats (registry/auth failures, kubectl-list failures) collapse inside this window. |
| `KEELSON_LOG_FILE_MAX_BYTES`<br>`Keelson/LogFileMaxBytes` | `10485760` | Rotate `/keelson/work/log/keelson.log` once it grows past this many bytes (default 10 MiB). |
| `KEELSON_LOG_FILE_KEEP`<br>`Keelson/LogFileKeep` | `5` | Number of rotated `.1, .2, …` files to retain. Older than this are dropped on rotate. |

The file log path is convention, not configuration: `/keelson/work/log/keelson.log` (under the Pod's `emptyDir`).

A misconfigured variable here fails `keelson-validate`, so the Pod refuses to boot rather than running with surprising defaults.


## Logging

Better logging is a key promise for the creation of Keelson, this is the logging description.

### Log Philosophy

For the happy path log only what actually changes or goes wrong or things that happen once at startup. For the unhappy paths, warn or error, rate limit as configured by the consumer to a period between the same message being printed so as not not immediately flush away useful information. For debug by default print everythign always - but tunable by the consumer to slow down duplicates to whatever level is configured. For all messages they're in files inside the pod and rotated by size and file count so that you can run default info level logging and still get debug and complete logging by getting inside the pod and reading or tailing the files. By this method it's never confusing what's going on. Enjoy :-)

### Log Levels

`KEELSON_LOG_LEVEL` is a threshold, not a filter set: each level emits its own events **plus everything above it**. Format is controlled separately by `KEELSON_LOG_FORMAT` (`plain` or `json`); the event name and `key=value` pairs are identical either way, so log queries port between the two.

| Level | What it adds on top of the level below | Use it for |
|---|---|---|
| `error` | Hard failures Keelson cannot work around on its own. Registry lookups (`registry-creds-failed`, `registry-list-tags-failed`, `registry-namespace-unknown`), scan-time API calls (`kubectl-list-failed`), patch attempts (`update-failed`, `update-unsupported-kind`, `cronjob-job-trigger-failed`, `cronjob-trigger-requires-suspend`), state writes (`state-configmap-create-failed`, `state-flush-failed`, `state-namespace-unknown`), probe failures (`probe-liveness-fail`, `probe-readiness-fail`), and every `validate-*` boot check. | Page-worthy. Persistent errors mean misconfiguration, broken RBAC, or a registry outside Keelson's reach. |
| `warn` | Everything `error` shows, plus transient faults the controller recovers from on its own. `watch-disconnected` (kubectl stream ended; reconnecting), `watcher-died` and `watcher-respawned` (the supervisor saw a death and is bringing the watcher back), `state-reload-failed` (the scan child continues without the prior trigger state), `state-init-failed` (entry-point ConfigMap load failed; the next tick retries). | Alerting on connectivity churn or noisy backoff loops. Single warns are normal; a steady rate is a signal. |
| `info` *(default)* | Everything `warn` shows, plus the lean operational journal: only changes and one-shot lifecycle events. `boot`, `shutdown`, `validate-passed`, the initial `watcher-spawned`, `watch-start` (the in-watcher stream open — fires once per reconnect, throttled), `state-configmap-created` (first-boot ledger creation), `update-applied`, `cronjob-job-triggered`, and `dry-run-would-update`. Kept deliberately quiet — a healthy cluster produces little noise and real signals stand out. | The default. An operator should be able to read info logs at the rate Keelson emits them without filters. |
| `debug` | Everything `info` shows, plus the high-frequency mechanics: `scan-start`/`scan-summary` bookends, every `skip-not-eligible`, `no-change`, and `dry-run-no-change`, every `watch-enqueued`, `queue-item`, and `queue-drained`, every `state-flushed`, and `state-full-refresh`. | Tracing why a particular workload event did or didn't trigger a scan, or why a candidate tag was or wasn't picked. Verbose; not recommended in production. |

The rate limiter hashes `level + event + sorted-kv-pairs` and drops a repeat hit on the same hash within its level's interval. **Unique events** (the ones using the `_always` variant in the code) bypass it: every applied update, every triggered job, every boot/shutdown is logged in full. If a bug ever causes one of these to repeat, the repetition is the signal — not something the limiter masks.

In parallel with stdout/stderr, **every emission is also written to `/keelson/work/log/keelson.log`** in plain format, regardless of `KEELSON_LOG_LEVEL` or throttle state. The file rotates when it grows past `KEELSON_LOG_FILE_MAX_BYTES` and keeps `KEELSON_LOG_FILE_KEEP` numbered backups (`.1, .2, …`). This is the verification trail: inspect it when info-level stdout isn't enough but full `debug` is too much. The file lives on the Pod's `emptyDir`, so it does not survive pod restarts (which is the intended baseline — a restart re-emits the lean info trail).

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

| Key (logical) | Values | Purpose |
|---|---|---|
| `policy` | `major`, `minor`, `patch`, `all`, `glob:<pattern>`, `regexp:<pattern>` | Which version bumps trigger an update. Keel's `force` is rejected. |
| `match-tag` | regex / glob | Restrict the tag set considered before policy applies. |
| `match-mode` | `regex`, `glob` | Selects how `match-tag` is interpreted. |
| `trigger` | `default`, `poll` | Update on registry events or by poll. (Keelson currently polls.) |
| `poll-schedule` | cron expression | Override the global poll cadence for this workload. |
| `credentials` | `respect-pod` (default), `central`, `ignore-pod` | Which credential path Keelson uses. `respect-pod` walks the workload's `imagePullSecrets` first, then falls through to central. `central` skips the Pod entirely. |
| `trigger-job-on-update` | `true`, `false` | On a CronJob with `spec.suspend: true`, create a one-off Job whenever Keelson updates the image. The CronJob must stay suspended; otherwise the scheduler and Keelson would both fire. |
| `notify` | sink name | Reserved for future notification routing. |

Workloads under `KEELSON_CONFIG_MODE=both` must pick **one** prefix. Mixing `keelson.pro/` and `keel.sh/` on the same workload triggers a `dual-prefix-conflict` rejection.

### Per-container overrides

Pods with multiple containers can scope any of the keys above to a single container by appending `.<container-name>`:

```yaml
metadata:
  annotations:
    keelson.pro/policy: minor              # default for every container
    keelson.pro/policy.web: major          # the "web" container gets major bumps
    keelson.pro/match-tag.db: '^pg-15\.'   # restrict tag set for "db" only
```

The container-suffixed key wins when present; otherwise Keelson falls back to the workload-wide key. The same precedence applies under `KEELSON_CONFIG_MODE=keel` with `keel.sh/policy.<container>`.


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
- **`keel.sh/maxAge`** — skip tags older than a duration. Express the
  constraint through a `match-tag` regex or by tagging discipline upstream.
- **`keel.sh/releaseNotes`** — surface release notes alongside notifications.
  Keelson has no notification sinks yet, so the value has nowhere to go.
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
