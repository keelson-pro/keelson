# Configuration

Keelson reads configuration from three places, each owned by a different actor:

- **Environment variables** on the Keelson Pod — the operator sets these at deploy time.
- **`registries.yaml`** in the keelson ConfigMap — the operator declares which registries Keelson talks to and how it authenticates to each.
- **Workload annotations** — the workload owner controls per-workload behaviour.


## Environment variables

The Helm values (or templated Deployment) feed these directly into the Pod's `env`. Defaults live in `src/defaults/Keelson/`.

| Variable | Default | Purpose |
|---|---|---|
| `KEELSON_SCOPE` | `cluster` | `cluster` watches every namespace; `namespace` watches only the one Keelson runs in. |
| `KEELSON_CONFIG_MODE` | `keelson` | Which annotation prefix Keelson honours: `keelson` for `keelson.pro/`, `keel` for `keel.sh/` (drop-in mode), or `both` (accept either, reject workloads that mix prefixes). |
| `KEELSON_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error`. |
| `KEELSON_LOG_FORMAT` | `plain` | `plain` or `json`. |
| `KEELSON_RESPECT_SA_PULL_SECRETS` | `false` | Set `true` to walk the workload's ServiceAccount `imagePullSecrets` after the Pod's own, matching what the kubelet sees post-admission. Costs one extra `get sa` per scan. |

A few more variables exist for development overrides (queue paths, state ConfigMap name); they default to production values and rarely need changing. See `src/scripts/lib/` for the authoritative list.


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
  (Deployment, StatefulSet, DaemonSet, ReplicaSet, CronJob).
- **Event-driven `trigger`** — the annotation accepts `default` and `poll`,
  but Keelson only polls. A registry-webhook listener is planned.
