#!/usr/bin/env bash
#
# logons.sh — MERGED report "Logons" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/logons.rpt"
comps=(); exist=()
for c in logon auth-activity ssh-key-auth; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "Logons" "The whole SSH authentication story: the incoming screening funnel, successful logons per account and source IP, shared-certificate detection, key mismatches, lockouts and our outbound auth failures." "The whole SSH authentication story in one report: the **incoming screening funnel** per login, the **successful logons** per account and source IP (with shared-certificate detection), the **key-authentication failures** — key mismatches and account lockouts — and our **outbound** authentication failures at partner systems." "" "${comps[@]}"
