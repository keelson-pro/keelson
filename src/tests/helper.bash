# Shared test scaffolding.
# Sourced by every .bats file via `load helper`.

# tmp_dir_init
# Sets TMP_DIR to this test's own working directory, empty.
#
# Under the build output directory rather than mktemp -d, and cleared on the
# way in rather than on the way out. A failing test's evidence is the shims it
# installed and the files it wrote, and deleting those in teardown threw away
# exactly what you need to read afterwards. Clearing on entry gets the same
# isolation without it: a run never sees the last run's leftovers, and the
# last run's leftovers are still there when it finishes.
#
# One directory per test, named after the suite and the test, so the layout
# says what wrote what.
tmp_dir_init() {
    local root=${KEELSON_TEST_WORK_DIR:-}
    if [ -z "$root" ]; then
        root="${BATS_TEST_DIRNAME}/../../${OUTPUT_SUB_PATH:-kaptain-out}/keelson-test"
    fi
    TMP_DIR="${root}/$(basename "$BATS_TEST_FILENAME" .bats)/${BATS_TEST_NAME}"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
}
