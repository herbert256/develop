#!/usr/bin/env bash
#
# uc-status.sh — MERGED report "UC status" (2026-07 catalog cleanup): one report built
# from the component reports' .rpt files, which stay on disk as unpublished
# intermediates (their data still feeds every other consumer). bin/merge_rpt.sh
# owns the merge; report_tabs in publish_lib names one tab per TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../server/lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/uc-status.rpt"
comps=()
for c in uc1-status uc2-status uc2-visits pickups uc3-status uc3-polling no-remote-dir no-remote-files uc4-status; do
    # no-remote-dir + no-remote-files RIDE the UC3 tab too (2026-09-29: their
    # pages went — tab=uc3, stacked under the polling tables); only beside it
    case $c in no-remote-dir|no-remote-files) [ -f "$REPORTS_DIR/uc3-status.rpt" ] || continue ;; esac
    # uc2-visits + pickups RIDE the UC2 tab (2026-09-29: their pages went —
    # tab=uc2, stacked under the UC2 status table); only beside it
    case $c in uc2-visits|pickups) [ -f "$REPORTS_DIR/uc2-status.rpt" ] || continue ;; esac
    # uc3-polling RIDES the UC3 tab (2026-09-05: its tables carry tab=uc3 —
    # the Remote polls tables and the cron schedules, stacked under the UC3
    # status table). With no uc3-status.rpt to join, they would open a fifth
    # tab page, so the component is included only beside it.
    if [ "$c" = uc3-polling ] && [ ! -f "$REPORTS_DIR/uc3-status.rpt" ]; then continue; fi
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "UC status" "${comps[@]}"
