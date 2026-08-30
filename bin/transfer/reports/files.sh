#!/usr/bin/env bash
#
# files.sh — MERGED report "File sizes & types" (2026-07 catalog cleanup, Tier 3). The
# component .rpt files stay on disk as unpublished intermediates; see
# bin/merge_rpt.sh. report_tabs names one tab per component TABLE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../merge_rpt.sh"
OUT="$REPORTS_DIR/files.rpt"
comps=(); exist=()
for c in size-dist file-type duplicate-files; do
    comps+=("$REPORTS_DIR/$c.rpt"); { [ -f "$REPORTS_DIR/$c.rpt" ] && exist+=("$REPORTS_DIR/$c.rpt"); } || true
done
if [ ${#exist[@]} -gt 0 ]; then
    skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../../merge_rpt.sh" "${exist[@]}"
fi
merge_rpt "$OUT" "File sizes & types" "Files bucketed by transfer size (plus the empty files delivered OK), split per file extension, and the business filenames delivered more than once." "The files themselves, in one report: the **size distribution** (with the zero-byte files that were delivered OK kept visible), the split **per file type** (extension), and the **duplicate deliveries** — business filenames delivered more than once, worst first, which catches replay loops and re-sends." "" "${comps[@]}"
