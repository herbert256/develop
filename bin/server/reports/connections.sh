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
comps=()
for c in inbound-connections connection-diagnostics; do
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "Connections" "Connection volume in and out per day, account and address, and why our outbound connections fail: failure reasons, per remote host, test connections and rejected host keys." "${comps[@]}"
