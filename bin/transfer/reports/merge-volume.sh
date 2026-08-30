#!/usr/bin/env bash
#
# merge-volume.sh — MERGED report "Volume" (2026-07 catalog cleanup, Tier 3). The
# component .rpt files stay on disk as unpublished intermediates; see
# bin/merge_rpt.sh. report_tabs names one tab per component TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/volume.rpt"
comps=(); exist=()
for c in volume-src trend; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "Volume" "Data volume moved per day and top accounts, the per-transfer direction split, and the per-subscription trend: growers, shrinkers and flows gone silent." "How much data moves and which way it is heading: **volume per day**, the **direction split**, the **top accounts** — and the **trend** view: the window split in half and each flow's Files/volume compared across the halves, so growers, shrinkers and flows gone silent stand out." "" "${comps[@]}"
