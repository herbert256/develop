#!/usr/bin/env bash
#
# file-journey.sh — MERGED report "File journey" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/file-journey.rpt"
comps=(); exist=()
for c in patterns legs-count protocol-journey arrived-left; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "File journey" "The shape of each File through the platform: row/status patterns, leg counts, the ordered protocol chain, and how files arrive vs how they leave." "How a File moves through the platform, in one report: the **row/status patterns** (the transfers sharing a CoreId), the **leg counts** (the shape of store-and-forward, retries and UC2 pickups), the ordered **protocol journey** of each File, and **how files arrive vs how they leave** (first Inbound and last Outbound protocol with the delivered outcome)." "" "${comps[@]}"
