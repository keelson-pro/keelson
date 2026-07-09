# Field Manager Ownership

Kubernetes has accumulated three field-ownership regimes since it first
shipped. Plain writes go back to Kubernetes 1.0 (2015). Client-side apply
followed in 1.1.1 (2015). Server-Side Apply arrived years later, first
available in 1.14 (2019). All three regimes coexist in every modern
cluster, and their interactions cause most field-ownership surprises.

**Plain writes** are the oldest mechanism, present at the 1.0 release:
`kubectl create`, `kubectl replace`, `kubectl edit`, or any controller that
reads an object, changes it in memory, and writes the whole thing back with
`Update()` or PUT. No diffing happens. The new object wins outright, guarded
only by `resourceVersion`, which blocks the write if someone else changed the
object since it was read but says nothing about which fields changed or who
intended to own what.

**Client-side apply**, the original `kubectl apply`, first shipped in
Kubernetes 1.1.1 and predates ownership tracking entirely. It keeps a
`kubectl.kubernetes.io/last-applied-configuration` annotation on the object
and computes a three-way diff between that annotation, the live object, and
the new manifest on every run. Fields dropped from the manifest get pruned;
fields never mentioned are left alone. This mechanism knows nothing about
`managedFields` and never writes to it in a meaningful way. Two tools both
using client-side apply against the same object will happily overwrite each
other's annotation, and neither will see a conflict, warning, or error.

**Server-Side Apply (SSA)** reached alpha in Kubernetes 1.14 (2019), beta in
1.16 (2019), and went stable in 1.22 (2021). It moves the merge logic from the
client to the API server and records, per manager, exactly which fields that
manager last set in `metadata.managedFields`. Two operation types appear
there:

- **Apply** entries come from SSA itself (`kubectl apply --server-side`, or
  a PATCH with `Content-Type: application/apply-patch+yaml`). These are
  conflict-checked: if a second manager tries to apply a field another
  manager already owns with a different value, the server rejects it unless
  the caller forces the conflict. A manager never conflicts with itself. If
  the second manager applies the same value the first manager already holds,
  no conflict occurs and both managers become co-owners of that field.
- **Update** entries come from the plain-write pattern above, even when the
  writer is otherwise a modern client-go controller. Updates are not
  conflict-checked. They win unconditionally and take ownership of whatever
  fields they touch, stripping that ownership from any manager, Apply or
  Update, that held it before.

A field's owner, if it has one, is whichever manager's entry currently lists
that field. Ownership is exclusive, with one exception: two Apply-type
managers can share a field if they last wrote the same value. Change the
value and the sharing ends. Apply and Update never share ownership of the
same field. Forcing a conflict only matters when the incoming value differs
from the current owner's: the write succeeds and ownership transfers
entirely to the forcing manager. When the value matches, force has no
effect, since no conflict exists.

## The image auto-update problem

An image auto-updater updates one field on workloads it doesn't own: the
container image tag. It must never cause another controller's next
reconcile to fail, conflict, or revert. How an updater writes that field is
important, because the different write mechanisms carry different risks for
whoever else manages the object.

A plain write (PUT or `Update()`) takes the field unconditionally,
regardless of who held it before, with no signal to anyone that ownership
changed. An SSA apply under the updater's own identity, without checking who
currently owns the field, gets rejected outright when a real owner already
holds it with a different value. Forcing the conflict instead strips that
owner's claim on the field entirely. The true owner's next reconcile then
no longer recognises the field as its own. What happens from there depends
on how the owner handles fields it expected to control but no longer does.

A write that touches more of the object than intended, whether by
re-sending fields that weren't meant to change or by relying on a stale
copy of the object as the base, risks reverting or overwriting values that
something else set in the meantime.

## Keelson's approach

Keelson avoids the risks above by keying its write behaviour directly off
field-manager state rather than guessing at intent. Because ownership of a
field is always exclusive, a fresh read of `managedFields` gives a clean
answer before every write: an Apply-type manager currently holds the field,
or none does. An Update-type entry doesn't count: those writes aren't
conflict-checked, so there is nothing to mimic. That state, combined with
a small set of configuration values, determines which of two approaches
Keelson takes. Operators can change both defaults for the Keelson
instance, and override the behaviour per workload via annotation.

With an Apply-type owner, Keelson writes under that owner's own manager
name. This isn't a trick against Kubernetes; it uses the identity field
the API already exposes for exactly this purpose. SSA guarantees only that
a manager never conflicts with itself. Writing the image field under the
real owner's name leans on exactly that: when that owner later re-applies
its own desired state (even a different value, such as a rollback), the
server sees one manager updating a field it already holds. No conflict,
no force flag, nothing unusual in the history.

Without an Apply-type owner, Keelson writes as itself, scoped to the image
field alone. There's no existing owner to protect, so there's nothing to
disguise, and no reason to touch anything beyond the one field being
changed.

Every Keelson write, mimicked or not, is scoped to exactly the field it
changes. It never reads a full object, mutates a local copy, and sends the
whole thing back. That discipline keeps Keelson from displacing anything
else on the object, regardless of which write mechanism the real owner
itself is using.

Keelson's bump either becomes indistinguishable from the owner's own next
write, or, when there's no owner to protect, shows up honestly under
Keelson's own name, scoped narrowly enough that nothing else on the object
is at risk.

## Comparison with Keel

Keel also watches for new image tags and updates workloads automatically.
Its Kubernetes provider works as follows:

1. Keel maintains an in-memory cache of full resource objects, populated from
   a watch, not a fresh read per update.
2. When a new tag matches a workload's policy, Keel mutates the image field on
   its **cached copy** of that object.
3. Keel sends the entire mutated object back with a plain `Update()` call
   (a full PUT), stamping a `change-cause` annotation along the way.

There is no use of Server-Side Apply, field managers, or scoped patches
anywhere in Keel's codebase. Every write is a full-object replace, guarded
only by Kubernetes' standard `resourceVersion` optimistic-concurrency check.

This produces two problems Keelson's approach was built to avoid:

**Conflicting writes fail and don't retry promptly.** Keel's cache is
watch-based and stays close to current, so the window for a live object to
change between Keel's read and its write is narrow. If something does write
to the object in that window, Keel's `Update()` carries the stale
`resourceVersion` and the API server rejects it rather than silently
overwriting anything. Keel just logs the failure rather than retrying. The
next attempt happens whenever Keel receives another event for that image,
not on any timer tied to the failed write, so the tag bump can be delayed
until then.

**No ownership signal.** Because Keel never participates in the field-manager
model, there's no way to later ask "did Keel actually intend to own this
field, or was it just present in the object at the moment of the PUT."
Everything present when Keel writes gets attributed to one coarse Update
entry. Debugging "who changed this and why" has nothing to go on beyond the
annotation Keel stamps at write time.

Keelson avoids both. SSA applies and scoped PATCH requests operate without
requiring the object to be read and re-sent with a matching
`resourceVersion` first, so there's no stale-version window in which a
write can be lost. The two-tier ownership
model (mimic when there's a real Apply owner to protect, honest
self-attribution otherwise) addresses the ownership-signal problem:
`managedFields` stays legible, either because Keelson deliberately continued
an existing owner's identity for continuity, or because Keelson's own name
appears, scoped to exactly what it touched.
