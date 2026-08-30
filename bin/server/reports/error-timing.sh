#!/usr/bin/env bash
#
# error-timing.sh — WHEN errors and warnings happen. Errors per Day answers
# "which day"; this answers "which hour / which weekday", so batch-window and
# nightly-maintenance failure patterns stand out. Three views over the Error (E)
# and Warning (W) messages: by hour of day, by weekday, and an hour × weekday
# heatmap (the same 2-D heat table the transfer Load-by-Hour report uses).
#
# Weekday is the Julian-day-number mod 7 (0 = Monday), computed from the date in
# awk (no `date` command, for portability). Reads data/_parse.tsv. Writes
# data/error-timing.rpt.
#
# Usage:
#   ./error-timing.sh    # reads input/*.csv (via the cache), writes data/error-timing.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/error-timing.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over E/W messages. Emits pipe-delimited HOUR/WD lines, the heat ROW/
# TOTAL grid (TAB), and a TOT line.
agg=$(awk -F'\t' "$LOGLINES_AWK"'
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    ($3 != "E" && $3 != "W") { next }
    $2 !~ /^[0-9][0-9]:/ { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        h = substr($2, 1, 2)
        w = jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) % 7
        er = ($3 == "E"); wa = ($3 == "W")
        line = lvlname($3) " " compname($4) "  " substr($5, 1, 200)

        # per hour
        he[h] += er; hw[h] += wa; ht[h]++; tot++; if (er) toterr++; else totwarn++
        hbe[h SUBSEP d] += er; hbw[h SUBSEP d] += wa; hbt[h SUBSEP d]++
        if (!((h SUBSEP d) in hseen)) { hseen[h SUBSEP d]=1; hdl[h] = hdl[h] (hdl[h]?",":"") d }
        addline("H" SUBSEP h, $1 " " $2, line)

        # per weekday
        we[w] += er; ww[w] += wa; wt[w]++
        wbe[w SUBSEP d] += er; wbw[w SUBSEP d] += wa; wbt[w SUBSEP d]++
        if (!((w SUBSEP d) in wseen)) { wseen[w SUBSEP d]=1; wdl[w] = wdl[w] (wdl[w]?",":"") d }
        addline("W" SUBSEP w, $1 " " $2, line)

        # heat cell (hour × weekday), total issues
        c[h SUBSEP w]++; if (c[h SUBSEP w] > cmax) cmax = c[h SUBSEP w]; wtot[w]++
        cbd = h SUBSEP w SUBSEP d
        if (!(cbd in cd)) cord[h SUBSEP w] = cord[h SUBSEP w] (cord[h SUBSEP w] ? "," : "") d
        cd[cbd]++
    }
    END {
        mrec = 0
        for (i=0;i<24;i++){ hh=sprintf("%02d",i); if (ht[hh]>mrec) mrec=ht[hh] }
        # per-hour buckets (date:err:warn:total)
        for (k in hbt){ split(k,a,SUBSEP); hbk[a[1]] = hbk[a[1]] (hbk[a[1]]?",":"") a[2] ":" (hbe[k]+0) ":" (hbw[k]+0) ":" hbt[k] }
        for (i=0;i<24;i++){ hh=sprintf("%02d",i)
            printf "HOUR|%s|%d|%d|%d|%s|%s\n", hh, he[hh]+0, hw[hh]+0, ht[hh]+0, hbk[hh], lastlines("H" SUBSEP hh) }
        # per-weekday buckets
        for (k in wbt){ split(k,a,SUBSEP); wbk[a[1]] = wbk[a[1]] (wbk[a[1]]?",":"") a[2] ":" (wbe[k]+0) ":" (wbw[k]+0) ":" wbt[k] }
        for (w=0;w<=6;w++){ printf "WD|%d|%d|%d|%d|%s|%s\n", w, we[w]+0, ww[w]+0, wt[w]+0, wbk[w], lastlines("W" SUBSEP w) }
        # heatmap grid
        if (cmax < 1) cmax = 1
        for (i=0;i<24;i++){ hh=sprintf("%02d",i); linexx = "HROW\t" hh ":00"
            for (w=0;w<=6;w++){ v=c[hh SUBSEP w]+0
                if (v==0) cell=""
                else { r=v/cmax; tt=(r<=0.25)?1:(r<=0.5)?2:(r<=0.75)?3:4; cell="@{class=heat" tt "}" v }
                linexx = linexx "\t" cell }
            for (w=0;w<=6;w++){ bk=""; nn=split(cord[hh SUBSEP w],dz,","); for(qq=1;qq<=nn;qq++){ dd=dz[qq]; bk=bk (bk?",":"") dd ":" cd[hh SUBSEP w SUBSEP dd] }
                linexx = linexx "\t@data:h" w "=" bk }
            print linexx }
        tl = "HTOT\tTotal"; for (w=0;w<=6;w++) tl = tl "\t@{class=num}" wtot[w]+0; print tl
        printf "TOT|%d|%d|%d|%d\n", tot+0, toterr+0, totwarn+0, mrec+0
    }
' "$PARSED")

IFS='|' read -r _ t_tot t_err t_warn max_rec <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
if [ "${t_tot:-0}" -eq 0 ]; then
    echo "No Error/Warning messages found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
[ "${max_rec:-0}" -eq 0 ] && max_rec=1

# Both row writers print STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
hour_rows() {
    while IFS='|' read -r _ hh err warn tot bk lines; do
        [ -z "$hh" ] && continue
        width=$(( tot * 100 / max_rec ))
        printf 'ROW\t%s:00\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$hh" "$err" "$warn" "$tot" "$width" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep '^HOUR|')"
}

wdname=(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
wd_max=$(printf '%s\n' "$agg" | grep '^WD|' | awk -F'|' 'BEGIN{m=1}{if($5>m)m=$5}END{print m}')
wd_rows() {
    while IFS='|' read -r _ w err warn tot bk lines; do
        [ -z "$w" ] && continue
        width=$(( tot * 100 / wd_max ))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "${wdname[$w]}" "$err" "$warn" "$tot" "$width" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep '^WD|')"
}

heat_rows=$(printf '%s\n' "$agg" | grep $'^HROW\t\|^HTOT\t' | sed 's/^HROW\t/ROW\t/; s/^HTOT\t/TOTAL\t/')

{
    printf 'TITLE\tError Timing\n'
    printf 'DESC\tWhen errors and warnings happen — by hour of day, by weekday, and an hour × weekday heatmap. Surfaces batch-window and nightly-maintenance failure patterns that a per-day view hides.\n'
    printf 'INTRO\t**%s** Error/Warning messages (**%s** errors, **%s** warnings). Below: the split by **hour of day**, by **weekday**, and a **heatmap** of the two combined — darker cells are busier hours. Click an hour or weekday row for its 10 most recent messages.\n' \
        "$t_tot" "$t_err" "$t_warn"

    printf 'TABLE\tBy hour of day\n'
    printf 'HEAD\tHour\tErrors\tWarnings\tTotal\tLoad\n'
    printf 'KIND\ttext\tnumfailed\tnumwarn\tnum\tbar\n'
    printf 'RECALC\t-\ts0\ts1\ts2\tb2\n'
    hour_rows
    printf 'TOTAL\tTotal\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num}%s\t\n' "$t_err" "$t_warn" "$t_tot"
    printf 'NOTE\tError (red) and Warning (amber) messages by hour of the day, all days combined; the Load bar is the hour total relative to the busiest hour. Additive; re-aggregates over the selected dates. Click an hour for its 10 most recent messages.\n'

    printf 'TABLE\tBy weekday\n'
    printf 'HEAD\tWeekday\tErrors\tWarnings\tTotal\tLoad\n'
    printf 'KIND\ttext\tnumfailed\tnumwarn\tnum\tbar\n'
    printf 'RECALC\t-\ts0\ts1\ts2\tb2\n'
    wd_rows
    printf 'TOTAL\tTotal\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num}%s\t\n' "$t_err" "$t_warn" "$t_tot"
    printf 'NOTE\tThe same Error/Warning counts by day of week (Monday first). Re-aggregates over the selected dates.\n'

    printf 'TABLE\tHour × weekday heatmap\theat\n'
    printf 'HEAD\tHour\tMonday\tTuesday\tWednesday\tThursday\tFriday\tSaturday\tSunday\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tnum\n'
    printf '%s\n' "$heat_rows"
    printf 'NOTE\tEach cell is the total Error + Warning count for that hour and weekday; cells are tinted by quartile (darker = busier). The date filter re-sums and re-tints every cell for the selected range. Heatmap cells are not clickable — use the hour and weekday tables above for the click-to-expand view of the most recent messages.\n'

    printf 'SUMMARY\tError/Warning messages: %s  |  Errors: %s  |  Warnings: %s\n' "$t_tot" "$t_err" "$t_warn"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_tot msg(s): $t_err err, $t_warn warn)." >&2
