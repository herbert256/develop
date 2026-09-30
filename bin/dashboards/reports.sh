#!/usr/bin/env bash
#
# bin/dashboards/reports.sh — run every DASHBOARDS report script (no HTML):
# one page-spec .rpt per dashboard page into data/dashboards/reports/
# (TITLE/H1/DESC/INTRO + KPI and CARD lines + optional PAGE/FOOT).
#
# The aggregates come from the transfer caches and the already-computed
# transfer/server .rpt files (no multi-GB rescan), so this orchestrator must
# run AFTER bin/transfer/reports.sh and bin/server/reports.sh. Rendering is
# bin/dashboards/publish.sh. A report whose sources are missing removes its
# .rpt, so its page is simply not published.
#
# Usage:  bin/dashboards/reports.sh    (from any directory)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"   # REPORTS_DIR (the orphaned-temp sweep below)
rm -f "$REPORTS_DIR"/*.rpt.tmp   # orphaned atomic-write temps from a killed run

source "$SCRIPT_DIR/../timing.sh"   # timed: its TIME line (2026-09-29, build speed)
timed "$SCRIPT_DIR/reports/overview.sh"
# (the Monitor dashboard, monitor.sh, went 2026-09-30, user request)
# (ONE dashboard since 2026-07: the per-topic specs folded into overview.sh)

echo "All dashboards reports done." >&2
