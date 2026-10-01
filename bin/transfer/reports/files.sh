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
for c in size-dist file-type duplicate-files top-transfers; do   # + Largest files (2026-09-29: its own page went); size-profile (Size regime + Stub shippers) went 2026-10-01, user request
    comps+=("$REPORTS_DIR/$c.rpt")
done
merge_rpt "$OUT" "Sizes & types" "${comps[@]}"
# the ENTITY row tint (2026-09-30 audit A2-03: every row tints by its entity
# result colour — bin/rpt-tint.awk, base cache col 3)
awk -F'\t' -v TABLES="Empty files delivered OK" -v BASE="$CONFIG_BASE/_subscriptions.tsv" -v COL=2 -f "$ROOT/bin/rpt-tint.awk" "$OUT" > "$OUT.tint" && mv "$OUT.tint" "$OUT"
# a size bucket with no Files keeps its row (the bucket ladder stays whole) but
# shows empty cells, the 0 count rule (2026-09-30 audit A5-06): Files, Volume
# and % of Files blank; the Error / OK zeros z-blank in the renderer
awk -F'\t' 'BEGIN { OFS = "\t" }
    $1 == "TABLE" { t = $2 }
    t == "Files by size bucket" && $1 == "ROW" && $3 == "0" { $3 = ""; $6 = ""; $7 = "" }
    { print }' "$OUT" > "$OUT.zero" && mv "$OUT.zero" "$OUT"
