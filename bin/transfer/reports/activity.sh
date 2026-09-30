#!/usr/bin/env bash
#
# activity.sh — MERGED report "Activity over time" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/activity.rpt"
comps=()
for c in weekly hourly weekday; do   # day (the per-day table) left 2026-09-29: the Top view carries it, Volume included
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "Activity" "${comps[@]}"
