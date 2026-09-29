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
comps=()
for c in size-dist file-type duplicate-files top-transfers size-profile; do   # + Largest files and Size profile (2026-09-29: their own pages went)
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "Sizes & types" "Files bucketed by transfer size (plus the empty files delivered OK), split per file extension, the business filenames transferred more than once (any outcome), the 50 largest Files and the per-subscription size profile." "The files themselves, in one report: the **size distribution** (with the zero-byte files that were delivered OK kept visible), the split **per file type** (extension), the **duplicate deliveries** — business filenames delivered more than once, worst first — the **largest Files**, and the per-subscription **size profile**: flows whose typical file size changed, and flows that mostly ship stubs." "" "${comps[@]}"
