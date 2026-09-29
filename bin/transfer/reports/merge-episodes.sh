#!/usr/bin/env bash
#
# merge-episodes.sh — "Failure Episodes" (2026-09-29): the episodes report
# (episodes-src.rpt: Episodes per subscription and Time to recovery, both on
# the first tab, tab=episodes — the Open incidents table went the same day,
# Failed Subscriptions carries Failures in a row / Days red) and the
# subscriptions back to green after a red episode (recovered.rpt) on one
# tabbed page; the Recovered flows page went.
#
# Usage:
#   ./merge-episodes.sh    # -> data/transfer/reports/episodes.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/episodes.rpt"
comps=("$REPORTS_DIR/episodes-src.rpt" "$REPORTS_DIR/recovered.rpt")
merge_rpt "$OUT" "Episodes" "Every red run of each subscription with its time to recovery, and the subscriptions that came back to green after a red episode." "The failure **episodes** — every run of failed Files per subscription and the **time to recovery** — and the subscriptions that **recovered**: back to green after a red episode." "episode, outage, incident, open, recovery, time to recovery, recovered, back to green, mttr" "${comps[@]}"
