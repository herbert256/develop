#!/usr/bin/env bash
#
# failure-heatmap.sh — WHEN transfers fail. The Load-by-Hour and Load-by-Weekday
# reports show volume separately and by unit; this one focuses on FAILURES and
# combines the two axes into an hour × weekday heatmap, so a recurring failure
# window (a Monday-morning batch, a nightly poll) stands out at a glance. Three
# views over logical transfers (_files.tsv, delivered outcome): by hour of
# day, by weekday, and the hour × weekday failure heatmap.
#
# Reads data/_files.tsv (1=coreid, 2=outcome, 4=date_iso, 5=time, 6=sortkey,
# 7=jdn). Weekday = jdn mod 7 (0 = Monday). Writes data/failure-heatmap.rpt.
#
# Usage:
#   ./failure-heatmap.sh    # reads input/*.csv (via the cache), writes data/failure-heatmap.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/failure-heatmap.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over _files.tsv. Emits pipe-delimited HOUR/WD lines, the heat grid
# (TAB), and a TOT line. Failed = outcome != Processed. The per-hour/weekday
# Failed cell drills to that bucket's 10 most recent failed CoreIds.
agg=$(awk -F'\t' "$COREIDS_AWK"'
    $5 !~ /^[0-9][0-9]:/ { next }
    {
        oc = $2; d = $4; if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        h = substr($5, 1, 2); w = ($7 + 0) % 7
        f = (oc == "Failed" || oc == "Expired")
        ht[h]++; if (f) hf[h]++; tot++; if (f) totf++
        hbt[h SUBSEP d]++; hbf[h SUBSEP d] += f
        if (!((h SUBSEP d) in hseen)) { hseen[h SUBSEP d]=1; hdl[h] = hdl[h] (hdl[h]?",":"") d }
        wt[w]++; if (f) wf[w]++
        wbt[w SUBSEP d]++; wbf[w SUBSEP d] += f
        if (!((w SUBSEP d) in wseen)) { wseen[w SUBSEP d]=1; wdl[w] = wdl[w] (wdl[w]?",":"") d }
        if (f) {
            c[h SUBSEP w]++; if (c[h SUBSEP w] > cmax) cmax = c[h SUBSEP w]
            cbd = h SUBSEP w SUBSEP d; if (!(cbd in cd)) cord[h SUBSEP w] = cord[h SUBSEP w] (cord[h SUBSEP w] ? "," : "") d; cd[cbd]++
            addtop("H" SUBSEP h, $6, $4 " " $5, $1); addtop("W" SUBSEP w, $6, $4 " " $5, $1)
        }
    }
    END {
        mf = 0
        for (i=0;i<24;i++){ hh=sprintf("%02d",i); if (hf[hh]>mf) mf=hf[hh] }
        for (k in hbt){ split(k,a,SUBSEP); hbk[a[1]] = hbk[a[1]] (hbk[a[1]]?",":"") a[2] ":" hbt[k] ":" (hbf[k]+0) }
        for (i=0;i<24;i++){ hh=sprintf("%02d",i)
            hp = (ht[hh]+0) ? sprintf("%.1f", (hf[hh]+0)*100/(ht[hh]+0)) : "0.0"
            printf "HOUR|%s|%d|%d|%s|%s|%s\n", hh, ht[hh]+0, hf[hh]+0, hp, hbk[hh], buildlist(top["H" SUBSEP hh]) }
        for (k in wbt){ split(k,a,SUBSEP); wbk[a[1]] = wbk[a[1]] (wbk[a[1]]?",":"") a[2] ":" wbt[k] ":" (wbf[k]+0) }
        for (w=0;w<=6;w++){ wp = (wt[w]+0) ? sprintf("%.1f", (wf[w]+0)*100/(wt[w]+0)) : "0.0"
            printf "WD|%d|%d|%d|%s|%s|%s\n", w, wt[w]+0, wf[w]+0, wp, wbk[w], buildlist(top["W" SUBSEP w]) }
        if (cmax < 1) cmax = 1
        for (i=0;i<24;i++){ hh=sprintf("%02d",i); linexx = "HROW\t" hh ":00"
            for (w=0;w<=6;w++){ v=c[hh SUBSEP w]+0
                if (v==0) cell=""
                else { r=v/cmax; tt=(r<=0.25)?1:(r<=0.5)?2:(r<=0.75)?3:4; cell="@{class=heat" tt "}" v }
                linexx = linexx "\t" cell }
            for (w=0;w<=6;w++){ bk=""; nn=split(cord[hh SUBSEP w],dz,","); for(qq=1;qq<=nn;qq++){ dd=dz[qq]; bk=bk (bk?",":"") dd ":" cd[hh SUBSEP w SUBSEP dd] }
                linexx = linexx "\t@data:h" w "=" bk }
            print linexx }
        tl = "HTOT\tTotal"; for (w=0;w<=6;w++) tl = tl "\t@{class=num failed}" wf[w]+0; print tl
        printf "TOT|%d|%d|%d\n", tot+0, totf+0, mf+0
    }
' "$FILES")

IFS='|' read -r _ t_tot t_fail max_f <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
if [ "${t_tot:-0}" -eq 0 ]; then
    echo "No transfers found." >&2
    exit 0   # empty estate (config-only clone): placeholder page, not a failed build
fi
[ "${max_f:-0}" -eq 0 ] && max_f=1
tot_pct=$(awk -v f="$t_fail" -v t="$t_tot" 'BEGIN{printf "%.1f", t? f*100/t : 0}')

wdname=(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
wd_maxf=$(printf '%s\n' "$agg" | grep '^WD|' | awk -F'|' 'BEGIN{m=1}{if($4>m)m=$4}END{print m}')

heat_rows=$(printf '%s\n' "$agg" | grep $'^HROW\t\|^HTOT\t' | sed 's/^HROW\t/ROW\t/; s/^HTOT\t/TOTAL\t/')

{
    printf 'TITLE\tFailure Heatmap\n'
    printf 'DESC\tWhen transfers fail — by hour of day, by weekday, and an hour × weekday failure heatmap. Surfaces recurring failure windows that a per-day view hides.\n'
    printf 'INTRO\t**%s** Files (one logical transfer each), **%s** failed (**%s%%**). Below: the failure split by **hour of day**, by **weekday**, and a **heatmap** of failures per hour × weekday — darker cells are more failures. Click an Error count for that bucket'\''s 10 most recent failed Files.\n' \
        "$t_tot" "$t_fail" "$tot_pct"

    printf 'TABLE\tBy hour of day\n'
    printf 'HEAD\tHour\tFiles\tError\tError %%\tFailures\n'
    printf 'KIND\ttext\tnum\tnumfailed\tnum\tbar\n'
    printf 'RECALC\t-\ts0\ts1\tp1.0\tb1\n'
    # The Error % arrives with the row (the agg awk rounds it); the bar width is
    # plain shell arithmetic — so the loop forks nothing per row.
    while IFS='|' read -r _ hh tot fail pct bk drill; do
        [ -z "$hh" ] && continue
        width=$(( fail * 100 / max_f ))
        printf 'ROW\t%s:00\t%s\t%s\t%s%%\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\n' "$hh" "$tot" "$fail" "$pct" "$width" "$bk" "$drill"
    done <<< "$(printf '%s\n' "$agg" | grep '^HOUR|')"
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num failed}%s\t@{class=num}%s%%\t\n' "$t_tot" "$t_fail" "$tot_pct"
    printf 'NOTE\tFiles by the hour of their start time, all days combined; the Failures bar is that hour'\''s failed count relative to the busiest hour. Re-aggregates over the selected dates. Click an Error count for its 10 most recent failed Files.\n'

    printf 'TABLE\tBy weekday\n'
    printf 'HEAD\tWeekday\tFiles\tError\tError %%\tFailures\n'
    printf 'KIND\ttext\tnum\tnumfailed\tnum\tbar\n'
    printf 'RECALC\t-\ts0\ts1\tp1.0\tb1\n'
    while IFS='|' read -r _ w tot fail pct bk drill; do
        [ -z "$w" ] && continue
        width=$(( fail * 100 / wd_maxf ))
        printf 'ROW\t%s\t%s\t%s\t%s%%\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\n' "${wdname[$w]}" "$tot" "$fail" "$pct" "$width" "$bk" "$drill"
    done <<< "$(printf '%s\n' "$agg" | grep '^WD|')"
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num failed}%s\t@{class=num}%s%%\t\n' "$t_tot" "$t_fail" "$tot_pct"
    printf 'NOTE\tThe same counts by day of week (Monday first). Re-aggregates over the selected dates.\n'

    printf 'TABLE\tHour × weekday failure heatmap\theat\n'
    printf 'HEAD\tHour\tMonday\tTuesday\tWednesday\tThursday\tFriday\tSaturday\tSunday\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tnum\n'
    printf '%s\n' "$heat_rows"
    printf 'NOTE\tEach cell is the number of FAILED Files for that hour and weekday; cells are tinted by quartile (darker = more failures). The date filter re-sums and re-tints every cell for the selected range.\n'

    printf 'SUMMARY\tFiles: %s  |  Error: %s (%s%%)\n' "$t_tot" "$t_fail" "$tot_pct"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_tot CoreId(s), $t_fail failed)." >&2
