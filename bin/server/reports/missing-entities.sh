#!/usr/bin/env bash
#
# missing-entities.sh — MERGED report "Missing entities" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/missing-entities.rpt"
comps=()
for c in unknown-sites unknown-accounts unknown-hosts unknown-whitelisting unknown-logins; do
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "Missing entities" "Entity values referenced in server-log messages but absent from the transfer logs — subscriptions, accounts, hosts, whitelisted addresses and logins, one tab each." "${comps[@]}"
