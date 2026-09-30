#!/usr/bin/env bash
#
# merge-file-in-file-out.sh — "File in - File out" (2026-09-29): the partner-
# to-partner handovers (file-in-file-out-src.rpt, both tables on the first
# tab — tab=fifo) and the UC4 to UC2 pairs (uc4-to-uc2.rpt, both tables on
# the second — tab=uc4uc2) on one tabbed page; the UC4 to UC2 page went.
#
# Usage:
#   ./merge-file-in-file-out.sh    # -> data/transfer/reports/file-in-file-out.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/file-in-file-out.rpt"
comps=("$REPORTS_DIR/file-in-file-out-src.rpt" "$REPORTS_DIR/uc4-to-uc2.rpt")
merge_rpt "$OUT" "File in - File out" "${comps[@]}"
