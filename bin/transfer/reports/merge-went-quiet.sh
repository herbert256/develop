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
comps=(); exist=()
for c in went-quiet-src stale-accounts; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "Went quiet" "Subscriptions that carried Files and then stopped, and accounts idle against their own transfer cadence." "The silence report, both units: **subscriptions** that carried Files and then stopped — no traffic at all in the last 7 days of the window, whatever the outcome used to be — and **accounts** whose idle time is long measured against their OWN cadence (a daily account three days quiet is news; a monthly one is not)." "" "${comps[@]}"
