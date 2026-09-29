#!/usr/bin/env bash
#
# merge-episodes.sh — "Recovered flows" (2026-09-29): the subscriptions back
# to green after a red episode (recovered.rpt), published as the episodes
# report. Its Episodes tab (episodes-src.rpt: Episodes per subscription and
# Time to recovery) went the same day (user request) with episodes.sh.
#
# Usage:
#   ./merge-episodes.sh    # -> data/transfer/reports/episodes.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/episodes.rpt"
comps=("$REPORTS_DIR/recovered.rpt")
merge_rpt "$OUT" "Recovered flows" "The subscriptions that came back to green after a red episode." "${comps[@]}"
