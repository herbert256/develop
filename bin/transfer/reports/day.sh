#!/usr/bin/env bash
#
# day.sh — the transfer log's CALENDAR: one row per calendar day (gaps filled),
# its newest record time, and the edge days flagged "(partial start)" /
# "(partial end)"; plus the META first / last record lines. A PAGELESS data
# producer: publish_lib.sh area_dates (the From/To date list), area_partial
# (the partial-END days) and TB_PERIOD (the top bar's data period) read it.
# (2026-09-29 audit: since the Activity page dropped its per-day tab the Files,
# Volume and First Time columns and the TOTAL had no reader — they went.)
#
# Usage:
#   ./day.sh    # reads the transfer caches, writes data/transfer/reports/day.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

OUT="$REPORTS_DIR/day.rpt"

# Per day: the first and last record time (the activity stream: 1=date
# 3=time) -> "date|first|last", date-sorted
sorted_stats=$(awk -F'\t' '
    { d = $1; t = $3
      if (!(d in first) || t < first[d]) first[d] = t
      if (!(d in last)  || t > last[d])  last[d]  = t }
    END { for (d in first) printf "%s|%s|%s\n", d, first[d], last[d] }
' <(activity_stream) | sort -t'|' -k1,1)

if [ -z "$sorted_stats" ]; then echo "No usable records found." >&2; exit 0; fi
first_record=$(printf '%s\n' "$sorted_stats" | awk -F'|' 'NR == 1 { print $1 " " $2; exit }')
last_record=$(printf '%s\n' "$sorted_stats" | awk -F'|' '{ l = $1 " " $3 } END { print l }')
total_days=$(printf '%s\n' "$sorted_stats" | awk 'NF { n++ } END { print n + 0 }')

rows=$(printf '%s\n' "$sorted_stats" | awk -F'|' '
    function jdn(y,m,d,   a) { a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    { split($1, p, "-"); date[NR]=$1; ft[NR]=$2; lt[NR]=$3; jday[NR]=jdn(p[1], p[2], p[3]); n=NR
      sub(/\.[0-9]+$/, "", ft[NR]); sub(/\.[0-9]+$/, "", lt[NR]) }   # without milliseconds (like topview.sh)
    END {
        for (i = 1; i <= n; i++) {
            if (i > 1) for (g = jday[i-1] + 1; g < jday[i]; g++) printf "ROW\t%s\t-\n", fromjdn(g)   # a calendar gap day
            mark = ""
            if ((i == 1 || jday[i] - jday[i-1] > 1) && ft[i] > "02:00:00") mark = " (partial start)"
            if ((i == n || (i < n && jday[i+1] - jday[i] > 1)) && lt[i] < "22:00:00") mark = (mark == "" ? " (partial end)" : " (partial)")
            printf "ROW\t%s%s\t%s\n", date[i], mark, lt[i]
        }
    }
')

{
    printf 'TITLE\tPer Day\n'
    printf 'META\tfirst\t%s\n' "$first_record"
    printf 'META\tlast\t%s\n' "$last_record"
    printf 'TABLE\tPer day\n'
    printf 'HEAD\tDate\tLast Time\n'
    printf 'KIND\ttext\ttext\n'
    printf '%s\n' "$rows"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($total_days day(s) with records)." >&2
