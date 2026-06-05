# Entry Points

`src/scripts/` ships five executable entry points. Everything else under
`src/scripts/lib/` is library code, sourced and never run directly.

| Script | Role | Lifetime |
|---|---|---|
| `keelson` | Long-running controller. The Deployment's `command`. | Forever (until SIGTERM). |
| `keelson-probe` | Kubernetes probe — `startup`, `readiness`, `liveness`. | Exits after one decision. |
| `keelson-validate` | Boot-time config and dependency check. | Exits after one run. |
| `keelson-boot-scan` | One-shot scan, default dry-run. | Exits after one pass. |
| `keelson-update-resource` | Patch one container's image on one workload. | Exits after one patch. |


## `keelson` — the controller

**Invoked by:** the Deployment, as `command: ["keelson"]`. Nothing else calls it.

**Args:** `--help` only; no runtime flags. All behaviour comes from env.

**Env required:** every `KEELSON_*` variable validated by `keelson-validate`.
The full list lives in [Configuration.md](Configuration.md). The Pod also
needs the keelson ConfigMap mounted at `/configmap` (for `registries.yaml`)
and an emptyDir at `/keelson/work` (for the watch queue and status file).

**Flow:**

1. Call `validate_config` — every required variable, enum, positive integer,
   and external binary is checked up front so the boot log carries every
   failure at once. A bad config fails the container, not the scan.
2. Log a `boot` event and install `TERM`/`INT` traps that kill watcher PIDs
   and any in-flight scan.
3. Initialise the work queue under `/keelson/work` and load the trigger-state
   ConfigMap into memory (per-CronJob always-once ledger; log dedupe is held
   in-memory by `lib/log.bash` and does not touch the ConfigMap).
4. Enter the tick loop (`KEELSON_TICK_INTERVAL=1s`). Each tick:
   - **Supervise watchers.** Each kind in `KEELSON_WATCHED_KINDS` gets one
     `kubectl get --watch` child. A dead watcher's PID becomes 0 and its
     failure count increments; the next respawn waits `1, 2, 4, 8...`
     seconds, capped at `KEELSON_WATCHER_BACKOFF_MAX` (CrashLoopBackOff
     style). A watcher that stays alive past `KEELSON_WATCHER_HEALTHY_RESET`
     clears its failure count.
   - **Drain the queue.** Events written by watchers are read and logged.
   - **Kick a scan if due.** `now - last_scan_start >= KEELSON_POLL_INTERVAL`
     and no prior scan still running → spawn the scan in a background
     subshell. The child owns the full trigger-state lifecycle: load the
     ConfigMap, clear the cache if a full refresh is due (which lets the
     scan pick up any out-of-band edits), run `scan_run`, flush deltas
     back. The parent's state stays clean; the next child rereads the
     ConfigMap. Long scans overlap ticks but never each other.
   - **Write the status file.** `/keelson/work/status` carries the heartbeat
     timestamp and one `<Kind>=<pid>` line per watched kind. `keelson-probe`
     reads it. Written atomically (tempfile + rename).
5. On `KEELSON_DRY_RUN=1` the scan still runs but no `kubectl patch` is
   issued — handy for debugging in-cluster without write RBAC.


## `keelson-probe` — Kubernetes probe entry

**Invoked by:** the kubelet, via the three `exec` probes on the Deployment.
Not called by anything else.

**Args:** `startup`, `readiness`, or `liveness`. Anything else exits 64.

**Env required:** `KEELSON_HEARTBEAT_MAX_AGE`. Other env defaults to the same
path the controller writes (`/keelson/work/status`).

**Decisions:**

| Subcommand | Pass when |
|---|---|
| `startup` | Heartbeat fresh **and** every watched-kind PID alive. |
| `readiness` | Every watched-kind PID alive. |
| `liveness` | Heartbeat younger than `KEELSON_HEARTBEAT_MAX_AGE`. |

Exit 0 on pass, 1 on fail. One log line is emitted on failure; success is
silent so the kubelet's probe logs stay readable.


## `keelson-validate` — boot-time check

**Invoked by:** `keelson` itself at start. Operators can also run it from a
pod shell to debug a misconfigured Deployment.

**Args:** `--help` only.

**Checks:**

- Every required `KEELSON_*` variable is set, with the right enum or
  positive-int shape.
- `KEELSON_WATCHED_KINDS` contains only kinds Keelson supports.
- `bash` is version 4 or newer; `kubectl`, `skopeo`, `yq` (v4), `awk`, `sed`,
  `head`, `tail`, `date` are all on `PATH`.
- If `registries.yaml` is present, every declared `auth-mode` has its
  helper binary available (`docker-credential-ecr-login` for `aws-irsa`,
  `curl` for `azure-wi`/`gcp-wi`; `secret` needs no helper).
- The work directory is writable.

Errors accumulate across every check so a misconfigured Pod logs the full
list once, not one failure at a time across restarts.


## `keelson-boot-scan` — one-shot scan

**Invoked by:** humans, debugging from a pod shell or a Job. Not wired into
the Deployment.

**Args:** `[--apply]` — without it, the script logs what *would* update but
makes no kube writes. With it, the script patches workloads in place.

**Env required:** same as `keelson` for anything that affects scanning
(scope, config mode, registry credentials). The tick-loop and watcher
variables are ignored.

**Flow:** initialise state (only in `--apply` mode), call `scan_run`, flush
state, exit. This is the same `scan_run` the controller's loop calls — one
iteration, no watchers, no sleep. Use it to verify policy and credentials
before flipping a workload to controller management.


## `keelson-update-resource` — single-workload patch

**Invoked by:** the scan path inside `keelson` and `keelson-boot-scan` once
a workload is found eligible. Also CLI-usable for manual overrides.

**Args:** `<kind> <namespace> <name> <container> <new-image>` — all five are
positional and required. `<kind>` must be one of Deployment, StatefulSet,
DaemonSet, CronJob. ReplicaSet is not supported: patch the owning
Deployment instead.

**Env required:** none beyond a working `kubectl` context. The script reads
no Keelson env vars; the caller is responsible for policy decisions before
invoking it.

**Flow:** build a strategic-merge patch document for the named container,
inspect the workload's `managedFields` to pick the right field manager and
apply mode (SSA vs strategic-merge), call `kubectl patch`, and on success
optionally trigger a one-off Job when patching a suspended CronJob with
`trigger-job-on-update=true`.


## How they fit together

```
Deployment
   ├── command:          keelson
   │       │
   │       ├── validate_config (sources lib/validate.bash)
   │       └── loop_run
   │             ├── supervise watchers ──► kubectl get --watch &
   │             ├── drain queue
   │             ├── kick scan ──► scan_run ──► keelson-update-resource ──► kubectl
   │             └── write status file
   │
   ├── startupProbe:    keelson-probe startup     (heartbeat + PIDs)
   ├── readinessProbe:  keelson-probe readiness   (PIDs)
   └── livenessProbe:   keelson-probe liveness    (heartbeat)

humans ──► keelson-boot-scan        (same scan_run code path, no watchers)
humans ──► keelson-validate         (same checks the controller runs at boot)
```

The shared library code in `src/scripts/lib/` is the substance; the entry
points are thin orchestrators that wire the right pieces together for the
mode they implement.
