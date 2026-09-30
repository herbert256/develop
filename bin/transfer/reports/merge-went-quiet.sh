#!/usr/bin/env bash
#
# merge-went-quiet.sh — MERGED report "Went quiet" (2026-07 catalog cleanup, Tier 3). The
# component .rpt files stay on disk as unpublished intermediates; see
# bin/merge_rpt.sh. report_tabs names one tab per component TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/went-quiet.rpt"
comps=()
for c in went-quiet-src stale-accounts; do
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "Went quiet" "${comps[@]}"
