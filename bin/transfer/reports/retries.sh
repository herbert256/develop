#!/usr/bin/env bash
#
# retries.sh — MERGED report "Retries & resubmissions" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/retries.rpt"
comps=(); exist=()
for c in retry attempts resubmissions; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "Retries & resubmissions" "Everything about retried and resubmitted transfers: failing flows, the retry anatomy of delivered and abandoned Files, retry spacing, which side fails, and the manual resubmissions." "Everything about transfers that did not succeed at the first attempt: the **failing flows** (by failure count, with successes and last failure), the **retry anatomy** — how many failed legs before delivery or before giving up, the spacing between attempts and **which side fails** — and the **manual resubmissions** (Resubmitted=true legs), per day and per subscription." "" "${comps[@]}"
