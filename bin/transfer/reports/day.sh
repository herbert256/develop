#!/usr/bin/env bash
#
# day.sh — activity per CALENDAR DAY: per day the Files count, Error/OK
# split, volume, and first/last time; calendar gaps filled with "0" rows and
# edge days flagged partial. Emits day.rpt from the shared normalized stream
# (lib.sh activity_stream): 1=date 2=jdn 3=time 4=proc 5=size 6=sortkey 7=id.
# Also carries the META lines (first/last record, physical + logical counts)
# that feed the transfer index header and the home page.
#
# Usage:
#   ./day.sh    # reads input/*.csv (via the caches), writes data/day.rpt
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
ensure_parsed
skip_if_fresh "$REPORTS_DIR/day.rpt" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Physical rows, for the records META. Deliberately NOT `wc -l`: mawk never
# splits a field it is not asked for, so this scan costs 0.02 s on the 133 MB
# acceptance cache while `wc -l` on the same file costs 0.08 s (BSD wc walks it
# a byte at a time, C locale or not). Both count the same rows — the cache
# always ends in a newline.
phys_records=$(awk 'END { print NR }' "$PARSED")

clabel="Files"; noun="File"
OUT="$REPORTS_DIR/day.rpt"

# Per day: count, Error/OK, volume, first/last time. Emits
# date|count|failed|processed|bytes|human|first|last.
raw_stats=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    {
        d = $1; t = $3; pf = ($4 != 1)
        count[d]++; bytes[d] += $5
        if ($4 == 1) proc[d]++; else fail[d]++
        if (!(d in first) || t < first[d]) first[d] = t
        if (!(d in last)  || t > last[d])  last[d]  = t
        addtop(d SUBSEP (pf ? "F" : "P"), $6, $1 " " $3, $7)   # drill: 10 most recent of each outcome, that day
    }
    END {
        for (d in count) printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", d, count[d], fail[d]+0, proc[d]+0, bytes[d]+0, human(bytes[d]+0), first[d], last[d], buildlist(top[d SUBSEP "F"]), buildlist(top[d SUBSEP "P"])
    }
' <(activity_stream))

if [ -z "$raw_stats" ]; then echo "No usable records found." >&2; exit 0; fi
sorted_stats=$(printf '%s\n' "$raw_stats" | sort -t'|' -k1,1)

total_records=0; total_days=0; total_failed=0; total_processed=0; total_bytes=0
first_record=""; last_record=""
while IFS='|' read -r day count failed processed bytes human first last ccf ccp; do
    [ -z "$day" ] && continue
    total_records=$((total_records + count)); total_failed=$((total_failed + failed))
    total_processed=$((total_processed + processed)); total_bytes=$((total_bytes + bytes))
    total_days=$((total_days + 1))
    [ -z "$first_record" ] && first_record="$day $first"
    last_record="$day $last"
done <<< "$sorted_stats"
total_human=$(awk -v b="$total_bytes" 'BEGIN { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
    while (v >= 1024 && i < 6) { v /= 1024; i++ }
    if (i == 1) printf "%d %s", v, u[i]; else printf "%.2f %s", v, u[i] }')
[ -z "$first_record" ] && first_record="N/A"
[ -z "$last_record" ] && last_record="N/A"

rows_html=$(printf '%s\n' "$sorted_stats" | awk -F'|' '
    function jdn(y,m,d,   a) { a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    { split($1, p, "-"); date[NR]=$1; cnt[NR]=$2; fa[NR]=$3; pr[NR]=$4; hu[NR]=$6; ft[NR]=$7; lt[NR]=$8; ccf[NR]=$9; ccp[NR]=$10; jday[NR]=jdn(p[1], p[2], p[3]); n=NR
      sub(/\.[0-9]+$/, "", ft[NR]); sub(/\.[0-9]+$/, "", lt[NR]) }   # display without milliseconds (like topview.sh)
    END {
        for (i = 1; i <= n; i++) {
            if (i > 1) for (g = jday[i-1] + 1; g < jday[i]; g++) printf "ROW\t%s\t0\t0\t0\t0 B\t-\t-\n", fromjdn(g)
            mark = ""
            if ((i == 1 || jday[i] - jday[i-1] > 1) && ft[i] > "02:00:00") mark = " (partial start)"
            if ((i == n || (i < n && jday[i+1] - jday[i] > 1)) && lt[i] < "22:00:00") mark = (mark == "" ? " (partial end)" : " (partial)")
            printf "ROW\t%s%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", date[i], mark, cnt[i], fa[i], pr[i], hu[i], ft[i], lt[i], ccf[i], ccp[i]
        }
    }
')
nodata_days=$(printf '%s\n' "$rows_html" | awk -F'\t' '$3=="0" && $7=="-"{c++} END{print c+0}')

{
    printf 'TITLE\tPer Day\n'
    printf 'DESC\t%s per calendar day: Error/OK, volume, first and last time.\n' "$clabel"
    printf 'META\tfirst\t%s\n' "$first_record"
    printf 'META\tlast\t%s\n' "$last_record"
    printf 'META\ttransfers\t%s\n' "$total_records"
    printf 'META\trecords\t%s\n' "$phys_records"
    printf 'INTRO\t**%s** %ss over **%s** day(s) with data: **%s** failed, **%s** processed, **%s** total volume.\n' \
        "$total_records" "$noun" "$total_days" "$total_failed" "$total_processed" "$total_human"
    printf 'TABLE\tPer day\n'
    printf 'HEAD\tDate\t%s\tError\tOK\tVolume\tFirst Time\tLast Time\n' "$clabel"
    printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum\ttext\ttext\n'
    printf '%s\n' "$rows_html"
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t\t\n' \
        "$((total_days + nodata_days))" "$total_records" "$total_failed" "$total_processed" "$total_human"
    printf 'NOTE\tOne row = one calendar day. A "0" row with no times is a day with no %ss; "(partial start/end)" marks a day whose collection window began or ended mid-day. Click an Error or OK count for that outcome'\''s 10 most recent %ss (newest first). The Top view shows this same per-day table together with each day'\''s active accounts, subscriptions, flows, hosts and logins.\n' "$noun" "$noun"
    if [ "$nodata_days" -gt 0 ]; then
        printf 'SUMMARY\tDays with data: %s  |  Days with no data: %s  |  Total %ss: %s  |  Volume: %s\n' "$total_days" "$nodata_days" "$noun" "$total_records" "$total_human"
    else
        printf 'SUMMARY\tDays with data: %s  |  Total %ss: %s  |  Volume: %s\n' "$total_days" "$noun" "$total_records" "$total_human"
    fi
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($total_days day(s), $total_records $noun(s))." >&2
