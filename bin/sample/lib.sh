# bin/sample/lib.sh — sourced by generate.sh / verify.sh. Paths, the safety
# marker, the seed.
#
# SAFETY: the generator OVERWRITES input/ — the one thing that must never
# happen in the runtime repo (real, irreplaceable exports). It therefore
# refuses to run unless input/.sample-estate exists. The marker is COMMITTED
# in the develop repo; input/ is never synced to runtime (runtime.sh copies
# bin/ and assets/ only), so a runtime checkout can never carry it.

SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SAMPLE_DIR/../.." && pwd)"
SEED_DIR="$SAMPLE_DIR/seed"
TPL_DIR="$SAMPLE_DIR/templates"
KNOBS="$SEED_DIR/knobs.tsv"
PARTNERS="$SEED_DIR/partners.tsv"
MARKER="$ROOT/input/.sample-estate"

AXWAY_SAMPLE_SEED="${AXWAY_SAMPLE_SEED:-42}"

sample_guard() {
    if [ ! -f "$MARKER" ]; then
        cat >&2 <<'EOF'
bin/sample: REFUSING to run — input/.sample-estate is missing.

This generator OVERWRITES everything under input/. That marker exists only in
the develop repo (sample data); a repo holding REAL exports must never have
it. If this IS the develop repo and the marker went missing, restore it with:

    touch input/.sample-estate
EOF
        exit 2
    fi
}

# awk with the shared prelude first (and the seed); callers append -f/-v args
sawk() { awk -v SEED="$AXWAY_SAMPLE_SEED" -f "$SAMPLE_DIR/prelude.awk" "$@"; }
