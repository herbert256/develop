#!/usr/bin/env bash
#
# duration-longest.sh — "Longest Files": the TOP_N longest logical transfers
# by WALL-CLOCK duration (data/_files.tsv col 9, dur_ms — first record start
# to last record end, gaps included), split out of duration.sh 2026-09-03
# (user request) into its own Performance-group page.
#
# ONE table: the DELIVERED Files only — outcome Processed; not Failed, not
# Expired and not Waiting either (2026-09-13, user request: the former
# "All transfers" switch view, every outcome with a measured duration, is
# gone — a failed transfer's run time is a timeout, not a duration). Every
# cell of a row opens the File's page, docs/files/<coreid>.html (2026-09-29:
# the per-transfer record pages under docs/transfers/duration/top/ went —
# the File page carries the same records).
# Columns: Duration (sorting by the exact milliseconds via @{sortval}), Start
# Time, End Time (_files.tsv col 24, the latest leg end — 2026-09-21, user
# request: it took the Size column's place), CoreId, Destination Subscription,
# File — the former "Duration
# (ms)" and "Account" columns went with the split (user request). A listed
# File opens its File page docs/files/<coreid>.html when it has one — since
# 2026-09-29 only the published set of bin/transfer/filepages.sh (per
# subscription the newest OK File + the three newest Failed ones); until then
# every listed File was paged from this report's own sidecar.
#
# Usage:
#   ./duration-longest.sh    # -> data/transfer/reports/duration-longest.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/duration-longest.rpt"
FPF="$CACHE_DIR/_filepages.tsv"; [ -f "$FPF" ] || FPF=/dev/null   # the published File pages
TOP_N=50

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# top_list — the TOP_N longest DELIVERED Files (outcome Processed), ms-descending:
#   ms ⇥ coreid ⇥ "date time" ⇥ subscription ⇥ end ⇥ file ⇥ humandur
top_list() {
    awk -F'\t' '
        function clean(s){ gsub(/[\t\r]/, " ", s); return s }
        function humandur(ms) {
            if (ms < 1000)    return sprintf("%d ms", ms)
            if (ms < 60000)   return sprintf("%.2f s", ms/1000)
            if (ms < 3600000) return sprintf("%.1f min", ms/60000)
            return sprintf("%.2f h", ms/3600000)
        }
        $2 != "Processed" { next }   # delivered Files only: no Failed, no Expired, no Waiting
        { ms = $9 + 0; if (ms <= 0) next
          s = clean($12); if (s == "") s = "(no subscription)"
          printf "%d\t%s\t%s %s\t%s\t%s\t%s\t%s\t%s\n", ms, $1, $4, $5, s, clean($24), clean($11), humandur(ms), $25 }   # 9 = the File colour (col 25)
    ' "$FILES" | LC_ALL=C sort -t$'\t' -k1,1nr | awk -v n="$TOP_N" 'NR<=n'
}
# the scope total (delivered Files with a duration), for the TOTAL row
count_scope() { awk -F'\t' '$2 == "Processed" && ($9 + 0) > 0 { n++ } END { print n + 0 }' "$FILES"; }

slow_ok=$(top_list)
n_ok=$(count_scope)
shown_ok=$(printf '%s\n' "$slow_ok" | awk 'length($0) { n++ } END { print n+0 }')

# rows: Duration (sortval = the exact ms) ⇥ Start Time ⇥ End Time ⇥ CoreId ⇥
# Subscription ⇥ File; the Duration, Start Time, End Time and CoreId cells
# open the File page
rows_of() {   # $1 the list
    printf '%s\n' "$1" | awk -F'\t' -v FPF="$FPF" '
    BEGIN { while ((getline l < FPF) > 0) { split(l, a9, "\t"); if (a9[1] != "") FP[a9[1]] = 1 } close(FPF) }
    # lit(): a raw name starting with @ would read as renderer metadata; the empty block @{} keeps it literal (audit 2026-09-29 F07)
    function lit(s) { return (substr(s, 1, 1) == "@") ? "@{}" s : s }
    length($0) {
        h = ($2 in FP) ? "href=../files/" $2 ".html," : ""   # a published File page only (2026-09-29)
        printf "ROW\t@{%ssortval=%d}%s\t@{%ssortval=%d}%s\t@{%ssortval=%d}%s\t@{%ssortval=%d}%s\t%s\t%s%s\n", h, $1, $7, h, $1, $3, h, $1, $5, h, $1, $2, $4, lit($6), ($8 ~ /^(green|orange|red)$/ ? "\t@data:res=" $8 : "") }'
}
{
    printf 'TITLE\tLongest Files\n'
    printf 'DESC\tThe %s longest delivered Files by wall-clock duration.\n' "$TOP_N"
    printf 'TABLE\tTop %s longest Files by duration\twide\trestint\n' "$TOP_N"   # rows tint by the File colour (2026-09-29): green, or orange after a retry / resubmit
    printf 'HEAD\tDuration\tStart Time\tEnd Time\tCoreId\tDestination Subscription\tFile\n'
    printf 'KIND\ttext\ttext\ttext\tmono\tsite\tfile\n'
    rows_of "$slow_ok"
    printf 'TOTAL\tTop %s of %s Files\t\t\t\t\t\n' "$shown_ok" "$n_ok"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($shown_ok of $n_ok delivered Files)." >&2
