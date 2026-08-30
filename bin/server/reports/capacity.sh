#!/usr/bin/env bash
#
# capacity.sh — MERGED report "Capacity & sessions" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/capacity.rpt"
comps=(); exist=()
for c in pesit file-cleanup; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "Capacity & sessions" "PeSIT activity and its problem codes, and the file retention / cleanup sweeps." "How busy the platform is and what it cleans up: **PeSIT activity** — logins, transfers, resets, ceiling hits and diagnostic codes — and the **file retention / cleanup** sweeps per account and remote directory. (The session-concurrency view went with the session bookkeeping lines the server parse now drops — 2026-08.)" "" "${comps[@]}"
