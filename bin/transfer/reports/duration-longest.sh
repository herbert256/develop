#!/usr/bin/env bash
#
# duration-longest.sh — "Longest Files": the longest logical transfers by
# WALL-CLOCK duration (data/_files.tsv col 9, dur_ms — first record start to
# last record end, gaps included), split out of duration.sh 2026-09-03 (user
# request) into its own Performance-group page.
#
# ONE table: the DELIVERED Files only — outcome Processed; not Failed, not
# Expired and not Waiting either (2026-09-13, user request: a failed
# transfer's run time is a timeout, not a duration).
# 2026-09-30 (user request: "Switch the columns coreid and file name — Show
# 250 and not 50 files — Store all 250 files in /files/ — The complete row
# must link to the file in /files/ — Show max 10 rows of the same
# subscription"): the rows are EXACTLY the kind-L members of the published
# File-page set (bin/transfer/filepages.sh — the 250 longest, at most 10 per
# subscription; THE selection lives there, so every listed File has its
# docs/files/<coreid>.html page), ms descending, CoreId ascending on a tie;
# the WHOLE row opens that page (the rowlink modifier + @data:href).
# Columns: Duration (sorting by the exact milliseconds via @{sortval}), Start,
# End (_files.tsv col 24, the latest leg end), File, Subscription, CoreId
# (headed "Start Time" / "End Time" / "Destination Subscription" until
# 2026-09-30 — audit A2-06). Rows tint by the File colour (col 25).
#
# Usage:
#   ./duration-longest.sh    # -> data/transfer/reports/duration-longest.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/duration-longest.rpt"
FPF="$CACHE_DIR/_filepages.tsv"; [ -f "$FPF" ] || FPF=/dev/null   # the published File pages (kind L = this page's rows)
TOP_N=250 PER_SUB=10   # = bin/transfer/filepages.sh LONGEST_N / LONGEST_PER_SUB (the selection is made there)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# top_list — the kind-L Files of the published set (bin/transfer/filepages.sh
# selected them), ms-descending, CoreId ascending on a tie:
#   ms ⇥ coreid ⇥ "date time" ⇥ subscription ⇥ end ⇥ file ⇥ humandur ⇥ colour
top_list() {
    awk -F'\t' -v FPF="$FPF" "$AWKLIB"'
        BEGIN { while ((getline l < FPF) > 0) { split(l, a9, "\t"); if (a9[2] == "L") L[a9[1]] = 1 } close(FPF) }
        function clean(s){ gsub(/[\t\r]/, " ", s); return s }
        !($1 in L) { next }
        { ms = $9 + 0
          s = clean($12); if (s == "") s = "(no subscription)"
          printf "%d\t%s\t%s %s\t%s\t%s\t%s\t%s\t%s\n", ms, $1, $4, $5, s, clean($24), clean($11), hdurms(ms), $25 }   # 9 = the File colour (col 25)
    ' "$FILES" | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2
}
# the scope total (delivered Files with a duration), for the TOTAL row
count_scope() { awk -F'\t' '$2 == "Processed" && ($9 + 0) > 0 { n++ } END { print n + 0 }' "$FILES"; }

slow_ok=$(top_list)
n_ok=$(count_scope)
shown_ok=$(printf '%s\n' "$slow_ok" | awk 'length($0) { n++ } END { print n+0 }')

# rows: Duration (sortval = the exact ms) ⇥ Start ⇥ End ⇥ File ⇥
# Subscription ⇥ CoreId (2026-09-30: File and CoreId switched); every cell
# but the subscription's and the CoreId's opens the File page, and so does the
# whole row — the CoreId opens File Tracking (2026-10-02, user request: the
# File / CoreId rule; render_rpt drops a File-page link there anyway)
rows_of() {   # $1 the list
    printf '%s\n' "$1" | awk -F'\t' "$AWKLIB"'
    # (every listed File is in the published set: kind L — its page exists)
    length($0) {
        h = "href=../files/" $2 ".html,"
        # (@data:res FIRST: the row reads <tr data-res=… data-href=…>)
        printf "ROW\t@{%ssortval=%d}%s\t@{%ssortval=%d}%s\t@{%ssortval=%d}%s\t@{href=../files/%s.html}%s\t%s\t%s%s\t@data:href=../files/%s.html\n", h, $1, $7, h, $1, $3, h, $1, $5, $2, $6, $4, $2, ($8 ~ /^(green|orange|red)$/ ? "\t@data:res=" $8 : ""), $2 }'
}
{
    printf 'TITLE\tLongest Files\n'
    # rows tint by the File colour (2026-09-29): green, or orange after a
    # retry / resubmit; the whole row opens the File page (rowlink)
    printf 'TABLE\tTop %s longest Files by duration (at most %s per subscription)\twide\trestint\trowlink\n' "$TOP_N" "$PER_SUB"
    printf 'HEAD\tDuration\tStart\tEnd\tFile\tSubscription\tCoreId\n'
    printf 'KIND\ttext\ttext\ttext\tfile\tsite\tmono\n'
    rows_of "$slow_ok"
    printf 'TOTAL\tTop %s of %s Files\t\t\t\t\t\n' "$shown_ok" "$n_ok"
printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($shown_ok of $n_ok delivered Files)." >&2
