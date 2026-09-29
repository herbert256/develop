#!/usr/bin/env bash
#
# ssh-security.sh — MERGED report "SSH security" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/ssh-security.rpt"
comps=()
for c in ssh-crypto ssh-sessions; do
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "SSH security" "Negotiated SSH ciphers, key-exchange, MACs and key algorithms with weak ones flagged, deprecated-parameter warnings, and session lifecycle problems." "${comps[@]}"
