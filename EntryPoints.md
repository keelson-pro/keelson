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
and an emptyDir at `/keelson/work` (for the watch queue, the workload
inventory, and the status files).

**Flow:**

1. Call `validate_config` — every required variable, enum, positive integer,
   and external binary is checked up front so the boot log carries every
   failure at once. A bad config fails the container, not the scan.
2. Log a `boot` event and install `TERM`/`INT` traps that kill watcher PIDs
   and any in-flight scan.
3. Initialise the work queue under `/keelson/work` and load the trigger-state
   ConfigMap into memory (per-CronJob always-once ledger and each workload's
   next-due, so schedules survive a restart; log dedupe is held
   in-memory by `lib/log.bash` and does not touch the ConfigMap).
4. Enter the tick loop (`KEELSON_TICK_INTERVAL=1s`). Each tick:
   - **Publish the heartbeat.** The clock is read and written in the same
     breath, first thing, to `/keelson/work/status/heartbeat`. Written
     atomically (tempfile + rename). Publishing before the work is what makes
     the stamp honest: the file holds the moment it was published, so nothing
     later in the tick can age a value a probe is about to read, and the file
     can never report a time the loop was not at. The stamp is decimal
     seconds at microsecond precision (`heartbeat=1786867629.967696`) and
     `keelson-probe` compares in microseconds too, so the answer is never
     rounded across the limit by where a second boundary happened to fall.
   - **Supervise watchers.** Each kind in `KEELSON_WATCHED_KINDS` gets one
     `kubectl get --watch --output-watch-events` child. The stream carries the
     event type and the workload's identity and nothing else: an event cannot
     say *what* changed, so the watcher draws no conclusions from it. A delete
     evicts the cache entry, since there is nothing left to read; anything else
     is written to the queue for the tick to re-read. The queue is keyed by
     identity, so a workload writing its status fifty times in a second costs
     fifty file writes and one re-read.
     A dead watcher's PID becomes 0 and its
     failure count increments; the next respawn waits `1, 2, 4, 8...`
     seconds, capped at `KEELSON_WATCHER_RESPAWN_BACKOFF_MAX` (CrashLoopBackOff
     style). A watcher that stays alive past `KEELSON_WATCHER_RESPAWN_HEALTHY_RESET`
     clears its failure count.

     This layer handles the watcher *process* dying. A watch that fails
     without the process dying (denied RBAC, an unknown kind, a refused
     connection) is handled inside the watcher instead: see below.
   - **Re-read what the watchers queued.** Spawned in a background subshell
     and gated so one never overlaps itself, for the same reason as the scan:
     it talks to the API server and the tick must not wait on it. Each queued
     identity is read back from the cluster and run through the same
     extraction the reconcile scan uses, so there is one definition of what a
     workload looks like rather than two that can drift. If the workload's
     decision inputs moved — image, annotations, service account, pull
     secrets, suspend — it becomes due now and the next tick polls it;
     if only its status moved it fingerprints identically and keeps its
     schedule. Past a couple of dozen queued identities the kinds are listed
     once each instead, which is the routine case after a reconnect, since
     kubectl replays the entire cluster as `ADDED`.
   - **Kick a scan if due.** `now - last_scan_start >= KEELSON_RECONCILE_INTERVAL`
     and no prior scan still running → spawn the scan in a background
     subshell. The child owns the full trigger-state lifecycle: load the
     ConfigMap, run `scan_run`, flush deltas
     back. The parent's state stays clean; the next child rereads the
     ConfigMap. Long scans overlap ticks but never each other.
   - **Take one kind of a full refresh, if one is due.** Every
     `KEELSON_FULL_REFRESH_INTERVAL` the watched kinds are queued, and one is
     taken per tick: the cluster is listed, and only once that list is in
     hand is that kind's cache thrown away and rebuilt, so a failed list
     leaves the cache untouched and the window where those workloads are
     invisible stays inside a single child. next-due comes back from the
     ledger rather than the discarded file, so a refresh corrects drift
     without resetting every schedule at once. The last kind of the cycle
     also drops entries for kinds no longer watched and forgets ledger keys
     with no workload behind them.

     The controller's scan makes no registry calls of its own; that is the
     tick's job, above. `keelson-boot-scan` is the exception, being a
     one-shot with no tick behind it, so it polls everything in the same
     pass. Otherwise the scan is the reconciler for the workload inventory under
     `/keelson/work/inventory`: it records every workload it saw, eligible or
     not, and forgets any it no longer finds. Eviction is confined to kinds
     the pass listed successfully, because from here "kubectl errored" and
     "all of them were deleted" look identical and only one of those should
     empty the cache.

     The inventory is what decouples the two costs. Listing is one call per
     kind however many workloads exist; a registry tag lookup is one call per
     eligible container and is the rate-limited one. So the scan asks the
     registry about a workload only when its `next-due` has arrived, or when
     its fingerprint shows the image or a decision annotation changed. A
     workload nobody has touched, on a long `poll-schedule`, costs nothing
     between polls.
   - **Rotate the log file if it is oversize.** The controller loop is the
     only rotator. Watchers and scan children append to the same file, and
     concurrent appends are safe, but two processes running the rename
     shuffle at once lose or duplicate rotated files. Checking here also
     takes a `wc -c` off every single log call.
   - **Sleep the remainder of the cycle.** `KEELSON_TICK_INTERVAL` is the
     cycle time, not the idle time: the loop sleeps the tick minus the work
     it just did, so ticks start on a fixed cadence rather than drifting by
     however long each one took. Work that outruns the tick gets no sleep and
     a `tick-overrun` warning, so the next tick starts immediately and the
     broken cadence is reported rather than silently absorbed. The cycle is
     timed in microseconds via bash 5's `EPOCHREALTIME`; whole seconds would
     misread half the sub-second ticks as overruns.

   The watcher PID map lives beside it in `/keelson/work/status/watchers`,
   one `<Kind>=<pid>` line per watched kind, and is written by the supervisor
   step above rather than here. The supervisor owns the map, so it publishes
   it the moment it changes it: a death or a respawn, not once per tick. That
   keeps the map on disk current for `keelson-probe readiness` instead of
   lagging until the end of the tick, and stops a value that moves twice a
   week from being rewritten 86,400 times a day.

   Each watcher publishes its own health to
   `/keelson/work/status/watcher-<Kind>`, carrying `failures=<consecutive>`
   and `error=<last kubectl stderr line>`. One writer per file, so watchers
   never contend. Readiness needs this as well as the PID map, because a live
   PID only proves the watcher process exists: the process outlives a watch
   that is failing, so without it a watcher reconnecting into a permission
   error for a week would report Ready.
5. On `KEELSON_DRY_RUN=1` the scan still runs but no `kubectl patch` is
   issued — handy for debugging in-cluster without write RBAC.


## `keelson-probe` — Kubernetes probe entry

**Invoked by:** the kubelet, via the three `exec` probes on the Deployment.
Not called by anything else.

**Args:** `startup`, `readiness`, or `liveness`. Anything else exits 64.

**Env required:** `KEELSON_HEARTBEAT_MAX_AGE`. Other env defaults to the same
directory the controller writes (`/keelson/work/status`). Each check reads
only the files it needs, so a missing watcher map never affects liveness and a
stale heartbeat never affects readiness.

**Decisions:**

| Subcommand | Pass when |
|---|---|
| `startup` | Everything `readiness` needs, **and** the heartbeat fresh. |
| `readiness` | Every watched-kind PID alive **and** every watcher streaming (`failures=0`). |
| `liveness` | Heartbeat younger than `KEELSON_HEARTBEAT_MAX_AGE`. |

Readiness needs both halves because they answer different questions. The PID
says the watcher process exists; the health file says its watch is actually
working. A watcher whose `kubectl` is being refused stays alive and keeps
retrying, so the PID alone would report a broken kind as Ready.

Startup deliberately demands the same as readiness: a kind Keelson was
configured to watch but cannot is a misconfiguration, and the Pod should
refuse to come up rather than run half working.

Exit 0 on pass, 1 on fail. One log line is emitted on failure; success is
silent so the kubelet's probe logs stay readable.

That line goes to stderr only. The probe switches the file channel off before
sourcing `lib/log.bash`, so it never writes `/keelson/work/log/keelson.log`.
It reads the controller's state rather than authoring the controller's trail,
the kubelet already surfaces the line in the Pod event, and a liveness kill
restarts the container and takes the `emptyDir` with it, so the file would not
have survived to be read. It also keeps the failure path from doing file I/O
on the one path already closest to its `timeoutSeconds`.


## `keelson-validate` — boot-time check

**Invoked by:** `keelson` itself at start. Operators can also run it from a
pod shell to debug a misconfigured Deployment.

**Args:** `--help` only.

**Checks:**

- Every required `KEELSON_*` variable is set, with the right enum or
  positive-int shape.
- `KEELSON_WATCHED_KINDS` contains only kinds Keelson supports.
- `bash` is version 5 or newer (the tick loop times its cycle with
  `EPOCHREALTIME`); `kubectl`, `skopeo`, `yq` (v4), `awk`, `sed`,
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

**Args:** `<kind> <namespace> <name> <container> <new-image> [--init]` — the
five positionals are required. `<kind>` must be one of Deployment,
StatefulSet, DaemonSet, CronJob. ReplicaSet is not supported: patch the owning
Deployment instead. `--init` says the container is an initContainer: names are
unique across both lists, but the key to write the image back under is not, so
it has to be stated rather than guessed.

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
   │             ├── write status/heartbeat        (clock read + write)
   │             ├── supervise watchers ──► kubectl get --watch &
   │             │      ├── on change ──► write status/watchers
   │             │      └── per watcher ──► write status/watcher-<Kind>
   │             ├── re-read queued ──► scan_refresh_queued ──► kubectl &
   │             ├── poll what is due ──► scan_poll_due ──► skopeo &
   │             ├── kick scan ──► scan_run ──► keelson-update-resource ──► kubectl
   │             ├── rotate log if oversize        (sole rotator)
   │             └── sleep (tick - elapsed), or warn if already over
   │
   ├── startupProbe:    keelson-probe startup     (heartbeat + PIDs + streaming)
   ├── readinessProbe:  keelson-probe readiness   (PIDs + streaming)
   └── livenessProbe:   keelson-probe liveness    (heartbeat)

humans ──► keelson-boot-scan        (same scan_run code path, no watchers)
humans ──► keelson-validate         (same checks the controller runs at boot)
```

The shared library code in `src/scripts/lib/` is the substance; the entry
points are thin orchestrators that wire the right pieces together for the
mode they implement.
