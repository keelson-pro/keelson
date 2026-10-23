# Entry Points

`src/scripts/` ships five executable entry points. Everything under
`src/scripts/lib/` is library code, sourced and never run directly.

| Script                    | Role                                                     | Lifetime       |
| ------------------------- | -------------------------------------------------------- | -------------- |
| `keelson`                 | The controller. The Deployment's `command`.              | Until SIGTERM. |
| `keelson-probe`           | The `startup`, `readiness` and `liveness` probes.        | One decision.  |
| `keelson-validate`        | Boot-time config and dependency check.                   | One run.       |
| `keelson-user-recheck`    | A one-shot pass over every workload, dry run by default. | One pass.      |
| `keelson-update-resource` | Update one image on one workload, by hand.               | One update.    |


## `keelson`: the controller

**Invoked by** the Deployment, as `command: ["keelson"]`.

**Args:** `--help` only. All behaviour comes from env.

**Env:** every `KEELSON_*` variable in [Configuration.md](Configuration.md). The
Pod also needs the keelson ConfigMap at `/configmap` (for `registries.yaml`) and
an `emptyDir` at `/keelson/work` (queue, workload cache, status files, log).

**Flow:**

1. `validate_config`, the same checks `keelson-validate` runs, logs every
   failure at once. A bad config fails the container.
2. Log `boot` and the effective settings, and trap `TERM`/`INT` to stop the
   watchers and any running child.
3. Set up the work queue and load the state ConfigMap.
4. Run the tick loop, one tick every `KEELSON_TICK_INTERVAL`:
   - **Publish the heartbeat** to `/keelson/work/status/heartbeat`
     (`heartbeat=<seconds>.<microseconds>`), first, atomically. Publishing
     before the work keeps the stamp honest: nothing later in the tick can age
     it.
   - **Supervise the watchers.** One `kubectl get --watch --output-watch-events`
     per watch target: each watched kind in cluster scope, or each kind in each
     namespace (`<Kind>.<namespace>`) in namespace scope. A watcher evicts
     deleted workloads from the cache and queues every other event for
     re-reading; it draws no other conclusion, since an event cannot say what
     changed. A dead watcher is respawned after `1, 2, 4, 8...` seconds, capped
     at `KEELSON_WATCHER_RESPAWN_BACKOFF_MAX`, and one that stays up past
     `KEELSON_WATCHER_RESPAWN_HEALTHY_RESET` clears its failure count. A watch
     that fails without the watcher dying (RBAC, an unknown kind) is retried
     inside the watcher, and reported in its health file.
   - **Re-read what the watchers queued**, in a background child. Each queued
     workload is read back and extracted the same way the scan does. If a
     decision input moved (image, annotations, service account, pull secrets,
     `suspend`), it is due now; if only its status moved, its schedule stands. A
     large queue, as after a reconnect replays the cluster, lists the kinds
     instead.
   - **Poll what is due**, in a background child: registry lookups, then
     `update_apply` for anything with a newer tag the policy allows, and the
     CronJob trigger where annotated. Up to `KEELSON_REGISTRY_POLL_CONCURRENCY`
     workloads at once.
   - **Start a reconcile scan** every `KEELSON_RECONCILE_INTERVAL`, in a
     background child that never overlaps the last. It lists each watched kind,
     refreshes the cache and forgets workloads it no longer finds, for kinds it
     listed successfully only. It makes no registry calls.
   - **Take one kind of a full refresh**, when one is due: list it, rebuild its
     cache, and after the last kind, reconcile the state ledger.
   - **Rotate the log file** if oversize, checked once a minute. The loop is the
     only rotator.
   - **Sleep** the rest of the tick, or log `tick-overrun` and start the next
     one at once.

   Children never write the state ConfigMap: they spool their changes, and the
   loop writes them once per tick, before starting anything. Every kubectl call
   names the group-qualified resource (`deployments.apps`, `cronjobs.batch`,
   `rollouts.argoproj.io`, ...), so another CRD sharing a kind name is never
   read or written.

   The supervisor publishes the watcher PID map to
   `/keelson/work/status/watchers`, one `<target>=<pid>` line each, when it
   changes, and each watcher its own health (`failures=`, `error=`) to
   `/keelson/work/status/watcher-<target>`.

5. With `KEELSON_DRY_RUN=1`, everything runs but no workload is written: the
   poll logs `dry-run-would-update` instead. It needs no write RBAC on
   workloads, though the state ConfigMap is still created if missing.


## `keelson-probe`: the probes

**Invoked by** the kubelet, through the Deployment's three `exec` probes.

**Args:** `startup`, `readiness` or `liveness`; anything else exits 64.

**Env:** `KEELSON_HEARTBEAT_MAX_AGE`. Reads only the status files each check
needs.

| Subcommand  | Passes when                                                                  |
| ----------- | ---------------------------------------------------------------------------- |
| `startup`   | `readiness` passes and the heartbeat is fresh.                               |
| `readiness` | Every watch target's PID is alive and its watch is streaming (`failures=0`). |
| `liveness`  | The heartbeat is younger than `KEELSON_HEARTBEAT_MAX_AGE`.                   |

A live PID only proves the watcher exists; the health file proves its watch
works, so a watcher retrying a permission error never reports Ready. Startup
demands the same, so a kind Keelson cannot watch keeps the Pod from coming up.

Exits 0 on pass, 1 on fail, with one line on stderr on failure and nothing on
success. It writes no log file: the kubelet records the line in the Pod's
events, and a liveness kill takes the `emptyDir` with it anyway.


## `keelson-validate`: the boot check

**Invoked by** operators, from a Pod shell, to debug a Deployment. `keelson`
runs the same checks in-process at boot.

**Args:** `--help` only.

**Checks:**

- every required variable is defined, with its enum or integer shape, and the
  two `AWS_ECR_*` variables defined even if empty;
- `KEELSON_WATCHED_KINDS` holds only supported kinds, and the namespaces in
  `KEELSON_NAMESPACES` exist;
- `KEELSON_HEARTBEAT_MAX_AGE` is at least twice `KEELSON_TICK_INTERVAL`;
- the clock is UTC and the locale's decimal point is `.`;
- bash 5 or newer, and `kubectl`, `skopeo`, `yq` v4, `awk`, `sed`, `head`,
  `tail` and `date` on `PATH`;
- `registries.yaml`, if present: every key, Secret name and `auth-mode` (see
  [Configuration.md](Configuration.md#what-is-checked-and-when)), and each
  mode's helper (`docker-credential-ecr-login` for `aws`, `curl` for `azure` and
  `gcp`);
- the work directory is writable.

Every failure is logged in one run.


## `keelson-user-recheck`: a one-shot pass

**Invoked by** a person, from a Pod shell or a Job.

**Args:** `[--apply]`. Without it, a dry run: it logs what would be updated and
writes nothing. With it, it updates what it finds, the way the field-manager
strategy settings choose, and fires CronJob triggers.

**Env:** the same as `keelson` for scanning (scope, kinds, config mode,
registries). A dry run validates nothing; `--apply` runs the controller's full
validation first. `KEELSON_DRY_RUN` is not read: `--apply` is the switch.

Use it to check a workload's policy and credentials before annotating it for the
controller. Run `--apply` from its own Pod or Job, not with `kubectl exec` in
the controller's Pod: it writes the state ConfigMap from the spool directory the
controller's children use, taking changes the controller has not yet written.
The running controller's next write of the ConfigMap also replaces the CronJob
firings `--apply` recorded, so the controller may fire one of those CronJobs
once more.

**Flow:** with `--apply`, validate and load the state ConfigMap (carrying on
without it, with a warning, if that fails). Then one `scan_run` with registry
polling, the same code the controller's poll runs, with no watchers and no loop.
With `--apply`, write the trigger state it recorded.

**Exits** 0 when nothing errored (skips and no-change are success), 1 when
anything did (a kind that could not be listed, credentials or tags that could
not be got, an update or CronJob trigger that failed, or with `--apply` the
CronJob firings it made could not be recorded), 64 on bad usage.


## `keelson-update-resource`: one update by hand

**Invoked by** a person, from a Pod shell, to move one workload to a chosen
image. Not used by the controller.

**Args:** `<kind> <namespace> <name> <container> <new-image> [--init|--volume]`.
`<kind>` is `Deployment`, `StatefulSet`, `DaemonSet`, `CronJob` or `Rollout`.
`--init` names an init container, `--volume` an image volume: names are unique
across the lists, but the field to write is not.

**Env:** the same settings as the controller, validated the same way before
anything is read. `KEELSON_DRY_RUN` is not read: running it is the decision to
write.

**Flow:**

1. Before reading anything, refuse an unsupported kind, a target that is not a
   container or volume name, and a new image without a tag, with a digest, or
   with a tag outside the image reference grammar.
2. Validate the settings, then read the workload: the target's running image and
   the workload's `keelson.pro/` and `keel.sh/` annotations.
3. Refuse a running image with no tag or with a digest, and a new image in
   another repository: only the tag may change.
4. Call `update_apply`, the controller's own update path, with the running tag
   as the one polled: owner detection, the strategy settings and the workload's
   `fieldManagerStrategy` annotation all apply.
5. On a CronJob it updated itself, fire the trigger as the poll would: with
   `triggerJobOnUpdate=true` and `spec.suspend: true`, create a Job, then record
   the firing in the state ConfigMap with every image the CronJob now runs. Not
   suspended: the trigger is refused with `cronjob-trigger-requires-suspend`. If
   the ConfigMap cannot be read, the Job is still created and nothing recorded.
   Either way the record protects little while the controller runs: it holds the
   ledger in memory from boot, and its next write of the ConfigMap replaces this
   one, so it may fire the CronJob once more.

**Exits** 0 when written; 3 when deliberately not written (already that image,
the image or its owner changed while it ran, or the workload was deleted); 1 on
failure, including an image written but its CronJob's Job not created, or
created but its firing not recorded; 64 on bad usage.


## How they fit together

```
Deployment
   ├── command:          keelson
   │       ├── validate_config
   │       └── loop_run
   │             ├── write status/heartbeat
   │             ├── write state ConfigMap (what the children spooled)
   │             ├── supervise watchers ──► kubectl get --watch &
   │             │      ├── on change ──► write status/watchers
   │             │      └── per watcher ──► write status/watcher-<target>
   │             ├── re-read queued ──► scan_refresh_queued ──► kubectl get &
   │             ├── poll what is due ──► scan_poll_due ──► skopeo, update_apply ──► kubectl &
   │             ├── reconcile scan ──► scan_run (cache only) ──► kubectl get &
   │             ├── full refresh, one kind ──► scan_refresh_kind ──► kubectl get &
   │             ├── rotate log if oversize
   │             └── sleep (tick - elapsed), or warn if over
   │
   ├── startupProbe:    keelson-probe startup
   ├── readinessProbe:  keelson-probe readiness
   └── livenessProbe:   keelson-probe liveness

people ──► keelson-user-recheck      scan_run with polling, one pass
people ──► keelson-update-resource   update_apply for one image
people ──► keelson-validate          the boot checks
```
