#!/usr/bin/env bash
#
# connections.sh — MERGED report "Connections" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/connections.rpt"
comps=(); exist=()
for c in inbound-connections connection-diagnostics; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "Connections" "Who connects in (protocol, account, source address, whitelist usage) and why our outbound connections fail (failure reasons, per remote host, test connections)." "Both directions of the connection story in one report. **Inbound**: who connects in to SecureTransport, over which protocol, from which addresses, and how the whitelist policies are used. **Outbound**: why and where our own connections fail — the failure-reason breakdown, the per-remote-host view and the test connections." "" "${comps[@]}"
