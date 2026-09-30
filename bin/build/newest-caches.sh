#!/usr/bin/env bash
#
# newest-caches.sh — the NEWEST-FIRST copies of the two transfer caches
# (2026-09-30, the lean round: R-XFER X-01 / X-02). A build-only step, run by
# bin/build.sh once the transfer caches are FINAL (after expire-files and the
# bookend settle, both of which rewrite _files.tsv) and before any reader
# starts — details.sh (background slot 2) and the transfer phase-1 pool.
#
#   data/transfer/cache/newest/_files.tsv       _files.tsv sorted by the File
#       start (col 6, the sortkey) DESCENDING, CoreId ascending on a tie
#       (sort -s: a full tie keeps the canonical order)
#   data/transfer/cache/newest/_transfers.tsv   _transfers.tsv with the legs
#       ordered by their FILE's start descending, CoreId ascending, stable —
#       every CoreId's legs stay together in their canonical order; a leg
#       whose CoreId has no _files row (none today) sorts last
#
# WHY: the top-10 drill rings (COREIDS_AWK addtop) fill with their newest
# Files first when the walk is newest-first, so every later File hits the
# cheap sortkey REJECT — details.sh -25 % CPU, entities.sh / duration.sh /
# duplicate-files.sh -20..-25 % at production scale; the outputs are
# byte-identical (their ring keys are unique per File and a tie keeps the
# CoreId-ascending first-seen order). Readers that are ORDER-SENSITIVE
# (dwell-time, recovered-files, file-type, retry, resubmissions, size-dist,
# failure-heatmap — their results depend on the walk order) keep the
# canonical caches.
#
# The copies keep the canonical BASENAMES (in a subdirectory) so every reader's
# `FILENAME ~ /_files\.tsv$/` dispatch still holds. Readers pick them through
# transfer/lib.sh `use_newest_caches`, which falls back to the canonical
# caches when a copy is missing or NOT newer than its canonical cache (a
# manual re-parse after a build).
#
# Usage:  bin/build/newest-caches.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../transfer/lib.sh"
TAB=$(printf '\t')
ND="$CACHE_DIR/newest"
mkdir -p "$ND"
rm -f "$ND/_files.tsv" "$ND/_transfers.tsv" "$ND"/*.tmp
if [ ! -s "$FILES" ] || [ ! -s "$PARSED" ]; then
    echo "newest-caches: no transfer cache — no newest-first copies (the readers use the canonical caches)." >&2
    exit 0
fi
# sort(1)'s buffer flag, feature-detected (bin/server/parse.sh's rule)
SORT_FLAGS=""; printf 'a\n' | sort -S1M >/dev/null 2>&1 && SORT_FLAGS="-S30%"
# the two copies side by side (disjoint outputs); the big one goes through
# `cat` (CLAUDE.md BUILD SPEED: big writes, 4 KB chunks)
{
    LC_ALL=C sort -t"$TAB" $SORT_FLAGS -s -k6,6r -k1,1 "$FILES" > "$ND/_files.tsv.tmp"
    mv "$ND/_files.tsv.tmp" "$ND/_files.tsv"
} &
fpid=$!
# the legs: prefix each with its File's start (col 6 of _files) — the key the
# stable sort orders by, CoreId (the leg's col 1) second — then strip it
LC_ALL=C awk -F'\t' 'NR == FNR { sk[$1] = $6; next }
    { print (($1 in sk) ? sk[$1] : "") "\t" $0 }' "$FILES" "$PARSED" \
  | LC_ALL=C sort -t"$TAB" $SORT_FLAGS -s -k1,1r -k2,2 \
  | LC_ALL=C awk '{ print substr($0, index($0, "\t") + 1) }' \
  | cat > "$ND/_transfers.tsv.tmp"
mv "$ND/_transfers.tsv.tmp" "$ND/_transfers.tsv"
wait "$fpid"
echo "newest-caches: wrote $ND/_files.tsv + _transfers.tsv (newest-first copies)." >&2
