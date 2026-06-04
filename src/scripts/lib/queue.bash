# Work-queue primitives for Keelson.
# Sourced; not directly executable.
#
# The queue is a directory on a writable volume at /keelson/work/queue
# (the keelson-base-image creates /keelson/work as the WORKDIR and the
# Deployment mounts an emptyDir over it). Each entry is a file named
# after the workload identity (kind, namespace, name); the file body is
# the same identity as a single space-separated line for the drain
# consumer.
#
# Dedupe is implicit: two enqueues of the same identity collide on the
# same filename, collapsing into one queue entry.
#
# Tests override KEELSON_QUEUE_DIR by reassigning it AFTER sourcing this
# file; production code does not read it from the environment.

KEELSON_QUEUE_DIR=/keelson/work/queue

# queue_init
# Ensures the queue directory exists. Idempotent.
queue_init() {
    mkdir -p "$KEELSON_QUEUE_DIR"
}

# queue_enqueue <kind> <namespace> <name>
# Writes a queue file for the workload identity. Idempotent: a second
# enqueue for the same identity overwrites the same file.
queue_enqueue() {
    local kind=$1 ns=$2 name=$3
    local safe="${kind}--${ns}--${name}"
    printf '%s %s %s' "$kind" "$ns" "$name" > "$KEELSON_QUEUE_DIR/$safe"
}

# queue_drain
# Emits each queue entry on stdout, one per line as "<kind> <ns> <name>",
# and removes each file as it is read. Safe to interleave with concurrent
# enqueues: a new file written after the iteration starts may be picked up
# on this drain or the next, depending on directory ordering.
queue_drain() {
    local f
    shopt -s nullglob
    for f in "$KEELSON_QUEUE_DIR"/*; do
        cat "$f"
        printf '\n'
        rm -f "$f"
    done
    shopt -u nullglob
}

# queue_size
# Echoes the number of pending queue entries.
queue_size() {
    local f n=0
    shopt -s nullglob
    for f in "$KEELSON_QUEUE_DIR"/*; do
        n=$(( n + 1 ))
    done
    shopt -u nullglob
    printf '%s' "$n"
}
