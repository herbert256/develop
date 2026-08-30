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
comps=(); exist=()
for c in errors-day error-timing error-reasons top-messages; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "Errors" "Server-log errors and warnings from every angle: levels per day and component, timing by hour and weekday, the failure-reason classification and the most-repeated message shapes." "The errors and warnings of the server log from every angle, in one report: **levels per day** and **per component**, **when** they happen (hour of day, weekday, the hour × weekday heatmap), the **failure-reason classification** (connection, PESIT refusal codes, network, routing) and the **most-repeated message shapes** (numbers, IDs and quoted values normalized away)." "" "${comps[@]}"
