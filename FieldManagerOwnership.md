# Field Manager Ownership

Kubernetes has accumulated three field-ownership regimes since it first shipped.
Plain writes go back to Kubernetes 1.0 (2015). Client-side apply followed in
1.1.1 (2015). Server-Side Apply arrived years later, first available in 1.14
(2019). All three regimes coexist in every modern cluster, and their
interactions cause most field-ownership surprises.

**Plain writes** are the oldest mechanism, present at the 1.0 release: `kubectl
create`, `kubectl replace`, `kubectl edit`, or any controller that reads an
object, changes it in memory, and writes the whole thing back with `Update()` or
PUT. No diffing happens. The new object wins outright, guarded only by
`resourceVersion`, which blocks the write if someone else changed the object
since it was read but says nothing about which fields changed or who intended to
own what.

**Client-side apply**, the original `kubectl apply`, first shipped in Kubernetes
1.1.1 and predates ownership tracking entirely. It keeps a
`kubectl.kubernetes.io/last-applied-configuration` annotation on the object and
computes a three-way diff between that annotation, the live object, and the new
manifest on every run. Fields dropped from the manifest get pruned; fields never
mentioned are left alone. This mechanism knows nothing about `managedFields` and
never writes to it in a meaningful way. Two tools both using client-side apply
against the same object will happily overwrite each other's annotation, and
neither will see a conflict, warning, or error.

**Server-Side Apply (SSA)** reached alpha in Kubernetes 1.14 (2019), beta in
1.16 (2019), and went stable in 1.22 (2021). It moves the merge logic from the
client to the API server and records, per manager, exactly which fields that
manager last set in `metadata.managedFields`. Two operation types appear there:

- **Apply** entries come from SSA itself (`kubectl apply --server-side`, or a
  PATCH with `Content-Type: application/apply-patch+yaml`). These are
  conflict-checked: if a second manager tries to apply a field another manager
  already owns with a different value, the server rejects it unless the caller
  forces the conflict. A manager never conflicts with itself. If the second
  manager applies the same value the first manager already holds, no conflict
  occurs and both managers become co-owners of that field.
- **Update** entries come from the plain-write pattern above, even when the
  writer is otherwise a modern client-go controller. Updates are not
  conflict-checked. They win unconditionally and take ownership of whatever
  fields they touch, stripping that ownership from any manager, Apply or Update,
  that held it before.

A field's owner, if it has one, is whichever manager's entry currently lists
that field. Ownership is exclusive, with one exception: two Apply-type managers
can share a field if they last wrote the same value. Change the value and the
sharing ends. Apply and Update never share ownership of the same field. Forcing
a conflict only matters when the incoming value differs from the current
owner's: the write succeeds and ownership transfers entirely to the forcing
manager. When the value matches, force has no effect, since no conflict exists.

## The image auto-update problem

An image auto-updater updates one field on workloads it doesn't own: the
container image tag. It must never cause another controller's next reconcile to
fail, conflict, or revert. How an updater writes that field is important,
because the different write mechanisms carry different risks for whoever else
manages the object.

A plain write (PUT or `Update()`) takes the field unconditionally, regardless of
who held it before, with no signal to anyone that ownership changed. An SSA
apply under the updater's own identity, without checking who currently owns the
field, gets rejected outright when a real owner already holds it with a
different value. Forcing the conflict instead strips that owner's claim on the
field entirely. The true owner's next reconcile then no longer recognises the
field as its own. What happens from there depends on how the owner handles
fields it expected to control but no longer does.

A write that touches more of the object than intended, whether by re-sending
fields that weren't meant to change or by relying on a stale copy of the object
as the base, risks reverting or overwriting values that something else set in
the meantime.

A server-side apply under the real owner's name, sending the image alone, fails
differently: an apply is a manager's whole intent, so the server reads every
other field that owner applied, and left out now, as one it no longer wants, and
removes it.

## Keelson's approach

Keelson keys its write behaviour off field-manager state rather than guessing at
intent. Before every write it reads the workload fresh, `managedFields`
included, and asks who owns the image field. The answer puts the workload in one
of three states:

- **apply-owned**: a manager holds the image through an Apply entry, as Argo CD
  with server-side apply, Flux, Helm 4 or `kubectl apply --server-side` leave
  it.
- **update-owned**: a manager holds it through an Update entry, as Helm 3,
  `kubectl edit`, `kubectl set image` or a client-side `kubectl apply` leave it.
- **unowned**: no entry holds it, which is what an object written before
  `managedFields` existed looks like.

When more than one entry holds the image, an Apply entry is preferred over an
Update entry and the most recent write over an older one. Keelson's own entries
rank below every other manager's, so a real owner is always found when there is
one, whatever order the writes happened in.

Each state has a setting naming the strategy used for it (see
[Configuration.md](Configuration.md)), and a workload can override it with the
`fieldManagerStrategy` annotation. There are three strategies.

### mimic: write as the owner

Keelson writes under the owner's own manager name. This isn't a trick against
Kubernetes; it uses the identity field the API already exposes for exactly this
purpose. A manager never conflicts with itself, so when the owner next deploys
its own desired state (a newer tag, or a rollback), the server sees one manager
changing a field it already holds. No conflict, no force flag, nothing unusual
in the history.

For an **update-owned** image that is simple: a JSON patch as the owner, which
tests the container's name and current image and replaces the image. Update
entries are not conflict-checked, and the owner's entry stays the owner's.

For an **apply-owned** image it takes more care, because an apply is a manager's
whole intent: sending the image alone as the owner would tell the server the
owner no longer wants every other field it applied, and the server would remove
them. So Keelson rebuilds everything that owner applies from the live object,
with only the image changed, and sends that:

1. The owner's field set is projected from the live object: each field the owner
   holds, at its live value. A field the owner holds but the live object no
   longer has (a zero value the server dropped) is left out and noted. An owned
   `{}` on a map or struct that merges key by key (annotations and labels at
   every metadata position, a Deployment's `strategy`, a StatefulSet's or
   DaemonSet's `updateStrategy` and its `rollingUpdate`, a StatefulSet's
   `persistentVolumeClaimRetentionPolicy`, and in a pod template a container's
   `resources` and `securityContext` and the pod's `securityContext`) is sent as
   the `{}` the owner applied, so the values the server or a webhook filled in
   stay put and stay theirs.
2. A server-side dry run of that body, as the owner, with the read's
   `resourceVersion` and `uid` as preconditions.
3. The guard: the owner's field set after the dry run must be exactly its set
   before, less the fields noted in step 1. Anything else (a field gained, a
   field lost) means the write would change what the owner owns, and Keelson
   refuses rather than write.
4. The real apply, the same body under the same preconditions.

If the dry run conflicts only with managers that hold the image through Update
entries (a `kubectl set image`, Helm 3), the owner's own Update entry, or
Keelson's own entries, Keelson repeats the dry run forced, with the same guard,
and applies forced. Those writers do not apply, so there is nothing of theirs to
break, and the log line says who it forced past. A conflict with a second
manager that also applies the image is refused and named: two tools both
applying the same workload is a setup problem, and Keelson will not pick a
winner.

Mimic also refuses, naming the reason, when:

- an Update entry owns kubectl's `last-applied-configuration` annotation. A
  later `kubectl apply` would migrate that manager's fields into the applier's,
  so the write would not stay the size Keelson meant it to be;
- the owner is named `kubectl`, the object carries that annotation and no Apply
  entry owns it: kubectl would then send a second apply of its own, and print
  that one's result instead of the dry run's;
- the owner recorded the image's list whole under an Argo Rollouts CRD older
  than v1.9, and the server now records it field by field (a list still recorded
  whole is fine: the owner's whole list goes back with only the image changed);
- the object holds something the projection cannot reproduce exactly (a `*` or
  `?` in a map key, two elements with the same merge key).

A refusal writes nothing and is logged as an error every poll until it is fixed,
either at the source (remove the second applier, sync the owner) or by
annotating the workload with a claim strategy.

An **unowned** image has nobody to be. Mimic is not offered as the setting for
that state, and an annotation that asks for it falls back to claim-patch, as
`claim-patch (fallback from mimic)` in the log, unless that fallback has been
switched off.

### claim-patch: write as Keelson, the narrowest way

A JSON patch as `keelson` that tests the container's name and current image and
replaces the image: one field, nothing else on the object read back or re-sent.
The patch is an Update, so it takes the image from whoever held it and records
it under Keelson's own name. This is the default for unowned images. On an
apply-owned image it means the owner's next apply conflicts over the image until
it forces or adopts the new tag, which the boot log notes when it is configured
that way.

### claim-apply: write as Keelson, as an applier

A forced server-side apply as `keelson`. Keelson's own applied set is rebuilt
from the live object the same way mimic rebuilds an owner's, with the image set
in it or added to it, so claiming a second container does not drop the first.
Claim-apply refuses where sending the image alone would replace a whole list:
when any entry holds the list whole, or on a Rollout with no `managedFields` to
tell by. It also refuses, as mimic does, while an Update entry owns kubectl's
`last-applied-configuration`, which is any object deployed with client-side
`kubectl apply`; and an object with no `managedFields` that carries that
annotation, where kubectl's migration would hand the applier every field.
Claim-patch is the answer in all of those cases.

### Every write

Each strategy re-reads the workload before writing and checks that nothing moved
since the poll chose the update: the image must still be the one polled, and the
owner and its operation the ones the strategy was chosen for. If something
moved, Keelson writes nothing and the next poll decides again. A workload
deleted since the poll is skipped quietly. Applies carry the read's
`resourceVersion` and `uid`, so an apply raced by another write is refused by
the server and retried from a fresh read, up to three times, and an object
deleted and re-created in between is never written over unread. JSON patches
carry neither: they test the container's name and current image instead, which a
write that moved neither does not disturb.

Keelson's bump either becomes indistinguishable from the owner's own next write,
or shows up honestly under Keelson's own name. Either way nothing else on the
object changes hands, and nothing anyone else set is lost.

## Comparison with Keel

Keel also watches for new image tags and updates workloads automatically. Its
Kubernetes provider works as follows:

1. Keel maintains an in-memory cache of full resource objects, populated from a
   watch, not a fresh read per update.
2. When a new tag matches a workload's policy, Keel mutates the image field on
   its **cached copy** of that object.
3. Keel sends the entire mutated object back with a plain `Update()` call (a
   full PUT), stamping a `change-cause` annotation along the way.

There is no use of Server-Side Apply, field managers, or scoped patches anywhere
in Keel's codebase. Every write is a full-object replace, guarded only by
Kubernetes' standard `resourceVersion` optimistic-concurrency check.

This produces two problems Keelson's approach was built to avoid:

**Conflicting writes fail and don't retry promptly.** Keel's cache is
watch-based and stays close to current, so the window for a live object to
change between Keel's read and its write is narrow. If something does write to
the object in that window, Keel's `Update()` carries the stale `resourceVersion`
and the API server rejects it rather than silently overwriting anything. Keel
just logs the failure rather than retrying. The next attempt happens whenever
Keel receives another event for that image, not on any timer tied to the failed
write, so the tag bump can be delayed until then.

**No ownership signal.** Because Keel never participates in the field-manager
model, there's no way to later ask "did Keel actually intend to own this field,
or was it just present in the object at the moment of the PUT." Everything
present when Keel writes gets attributed to one coarse Update entry. Debugging
"who changed this and why" has nothing to go on beyond the annotation Keel
stamps at write time.

Keelson avoids both. Every write is made against a fresh read and checked
against it: an apply carries that read's `resourceVersion` and `uid`, a patch
tests the container's name and image, and when another write lands in between,
the write is retried from a new read rather than abandoned until the next event.
And the strategies keep `managedFields` legible: mimic continues an existing
owner's identity for continuity, and the claims put Keelson's own name on
exactly what it took.
