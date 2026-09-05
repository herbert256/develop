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
comps=(); exist=()
for c in uc1-status uc2-status uc3-status uc3-polling uc4-status; do
    # uc3-polling RIDES the UC3 tab (2026-09-05: its tables carry tab=uc3 —
    # the Remote polls tables and the cron schedules, stacked under the UC3
    # status table). With no uc3-status.rpt to join, they would open a fifth
    # tab page, so the component is included only beside it.
    if [ "$c" = uc3-polling ] && [ ! -f "$REPORTS_DIR/uc3-status.rpt" ]; then continue; fi
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "UC status" "Every configured subscription of each use case in one status view per UC — healthy, failing, failing after a working history, or never seen — from the server log." "Every configured subscription classified per use case, one tab each: **UC1** (the partner pushes a file in), **UC2** (we stage, the partner collects), **UC3** (we poll the partner and pull) and **UC4** (we deliver out to the partner). The statuses come from the server log, so a flow shows up here even when it never produced a transfer. The **UC3** tab is the one report about us polling partners (2026-09-05): under the status table sit the polls per subscription, the remote directory listing failures, the configured cron schedules against what the log observed, and the schedules that never complete a poll." "uc status,uc1,uc2,uc3,uc4,poll,polls,polling,remote poll,empty polls,listing failures,cron,cronjobs,schedule,quartz,observed" "${comps[@]}"
