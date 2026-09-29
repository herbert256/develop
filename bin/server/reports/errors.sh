#!/usr/bin/env bash
#
# errors.sh — MERGED report "Errors" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/errors.rpt"
comps=()
for c in error-reasons error-timing top-messages; do   # Reasons leads since 2026-09-28 (the menu lands on the first tab; Per day, the old leader, = the Top view); errors-day (the levels per component) rides the Top view since 2026-09-29
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "Errors" "Server-log errors and warnings from every angle: the hour × weekday heatmap, the failure-reason classification (also per week) and the most-repeated message shapes." "${comps[@]}"
