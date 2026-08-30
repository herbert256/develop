#!/usr/bin/env bash
#
# platform-health.sh — MERGED report "Platform health" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/platform-health.rpt"
comps=(); exist=()
for c in cluster-health stuck-events scheduler-overruns; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "Platform health" "The platform infrastructure story on one page: daemon lifecycle and cluster distress, stuck internal events and scheduler overruns." "The health of the platform itself on one page — the infrastructure story the transfer figures never show: **daemon lifecycle and cluster distress** signals, **stuck internal events** (expired heartbeats and the recovery sweeps) and **scheduler overruns** (tasks skipped because the previous run was still going). (The Sentinel event-feed view went with the per-message acknowledgement lines the server parse now drops — 2026-08.)" "" "${comps[@]}"
