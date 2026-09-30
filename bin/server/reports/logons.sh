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
comps=()
for c in logon auth-activity; do   # ssh-key-auth went 2026-09-28: Key mismatches = Incoming Bad key, Lockouts now in Incoming Locked, Outbound key failures = a subset of Outgoing
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "Logons" "The whole SSH authentication story: the incoming screening funnel (with bad keys and lockouts), successful logons per account and source IP and our outbound auth failures (with the subscription that tried)." "${comps[@]}"
