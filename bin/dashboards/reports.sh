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
source "$SCRIPT_DIR/lib.sh"   # REPORTS_DIR (for the stale-rpt cleanup below)
rm -f "$REPORTS_DIR"/*.rpt.tmp   # orphaned atomic-write temps from a killed run

"$SCRIPT_DIR/reports/overview.sh"
"$SCRIPT_DIR/reports/monitor.sh"     # writes monitor.rpt ONLY when the env has monitor rows
# ONE dashboard (2026-07): the per-topic specs folded into overview.sh —
# their stale rpts are removed so the finder/sitemap loops stop seeing them
rm -f "$REPORTS_DIR"/{transfer,server,failures,volume,connections,pesit,security}.rpt

echo "All dashboards reports done." >&2
