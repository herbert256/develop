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
comps=(); exist=()
for c in day weekly hourly weekday; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "Activity over time" "Files, Error/OK and volume per calendar day, ISO week, hour of day and weekday — one activity report, one tab per resolution." "Transfer activity at every resolution in one report: **per day**, **per ISO week**, **per hour of day** (plus the hour × weekday grid) and **per weekday**. The tabs switch the resolution; the figures are the same Files, Error/OK split and volume throughout." "" "${comps[@]}"
