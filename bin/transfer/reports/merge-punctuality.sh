#!/usr/bin/env bash
#
# merge-punctuality.sh — "Punctuality" (2026-09-29): the arrival time-of-day
# model (punctuality-src.rpt, the Arrival time tab) and the arrival-cadence
# model (expected-arrival.rpt, its three tables on the Rhythm tab —
# tab=rhythm) on one tabbed page; the Expected arrival page went. Both judge
# each subscription against its OWN rhythm, one by the hour, one by the gap.
#
# Usage:
#   ./merge-punctuality.sh    # -> data/<env>/transfer/reports/punctuality.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/punctuality.rpt"
comps=("$REPORTS_DIR/punctuality-src.rpt" "$REPORTS_DIR/expected-arrival.rpt")
merge_rpt "$OUT" "Punctuality" "Each subscription against its own rhythm: the typical arrival time of day with late and missed days, and the typical gap between active days with an overdue verdict when the silence breaks it." "Each subscription judged against its **own** rhythm: the **arrival time** of day (typical slot, late arrivals, missed days) and the **gap** between active days (median and p90 gap, current silence, **overdue**), plus the weekday-locked flows." "punctuality, arrival, late, missed, rhythm, cadence, overdue, expected arrival, silence, weekday" "${comps[@]}"
