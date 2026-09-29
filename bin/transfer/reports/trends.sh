#!/usr/bin/env bash
#
# trends.sh — "Trends" (2026-09-29): the first-half-vs-second-half reports on
# one page, a tab per table — the per-subscription Files/volume growers and
# shrinkers (trend.rpt) and the per-subscription duration slower/faster
# (duration-trend.rpt). Replaces the Volume page (its Per day, By direction,
# Top accounts and Went silent tabs repeated the Top view, the Protocol
# report, the Entities pages and Expected arrival) and the Duration trend page.
# The components stay unpublished intermediates (merge_rpt).
#
# Usage:
#   ./trends.sh    # -> data/<env>/transfer/reports/trends.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/trends.rpt"
rm -f "$REPORTS_DIR/volume.rpt" "$REPORTS_DIR/volume-src.rpt"   # the retired Volume page and its component
comps=("$REPORTS_DIR/trend.rpt" "$REPORTS_DIR/duration-trend.rpt")
merge_rpt "$OUT" "Trends" "The window split in half, each subscription compared across the halves: the flows whose Files grew or shrank, and the flows whose transfers got slower or faster." "Which flows are changing: the data window split at its midpoint and every subscription compared across the two halves — **growers** and **shrinkers** by Files and volume, and the flows whose median duration got **slower** or **faster**." "trend, growth, shrink, decline, slower, faster, regression, duration trend, first half, second half" "${comps[@]}"
