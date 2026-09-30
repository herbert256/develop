#!/usr/bin/env bash
#
# error-timing.sh — WHEN errors and warnings happen. The Top view answers
# "which day"; this answers "which hour / which weekday", so batch-window and
# nightly-maintenance failure patterns stand out. ONE view over the Error (E)
# and Warning (W) messages: the hour × weekday heatmap (the same 2-D heat table
# the transfer Load-by-Hour report uses) with the per-hour Errors / Warnings /
# Total beside it and the per-weekday total under it. Until 2026-09-28 the two
# marginals were tables of their own (By hour, By weekday — user request:
# fewer server reports); a heat row still expands to that hour's 10 most
# recent messages.
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
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over E/W messages. Emits the heat ROW/TOTAL grid (TAB) and a TOT line.
agg=$(awk -F'\t' "$LOGLINES_AWK$AWKLIB"'
    ($3 != "E" && $3 != "W") { next }
    $2 !~ /^[0-9][0-9]:/ { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        h = substr($2, 1, 2)
        w = jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) % 7
        er = ($3 == "E"); wa = ($3 == "W")
        line = lvlname($3) " " compname($4) "  " substr($5, 1, 200)

        # per hour (the heat row Errors / Warnings / Total + its drill-down)
        he[h] += er; hw[h] += wa; ht[h]++; tot++; if (er) toterr++; else totwarn++
        hbe[h SUBSEP d] += er; hbw[h SUBSEP d] += wa; hbt[h SUBSEP d]++
        addline("H" SUBSEP h, $1 " " $2, line)

        # heat cell (hour × weekday), total issues
        c[h SUBSEP w]++; if (c[h SUBSEP w] > cmax) cmax = c[h SUBSEP w]; wtot[w]++
        cbd = h SUBSEP w SUBSEP d
        if (!(cbd in cd)) cord[h SUBSEP w] = cord[h SUBSEP w] (cord[h SUBSEP w] ? "," : "") d
        cd[cbd]++
    }
    END {
        # per-hour buckets (date:err:warn:total) — report.js recalcHeat re-sums
        # the Errors / Warnings / Total cells from them under the date filter
        for (k in hbt){ split(k,a,SUBSEP); hbk[a[1]] = hbk[a[1]] (hbk[a[1]]?",":"") a[2] ":" (hbe[k]+0) ":" (hbw[k]+0) ":" hbt[k] }
        # heatmap grid: Hour, the 7 weekday cells, Errors, Warnings, Total
        if (cmax < 1) cmax = 1
        for (i=0;i<24;i++){ hh=sprintf("%02d",i); linexx = "HROW\t" hh ":00"
            for (w=0;w<=6;w++){ v=c[hh SUBSEP w]+0
                if (v==0) cell=""
                else { r=v/cmax; tt=(r<=0.25)?1:(r<=0.5)?2:(r<=0.75)?3:4; cell="@{class=heat" tt "}" v }
                linexx = linexx "\t" cell }
            # (plain values: the column KINDs numfailed / numwarn / num give
            # the classes — an explicit copy doubled them, 2026-09-30 audit S-09)
            linexx = linexx "\t" he[hh]+0 "\t" hw[hh]+0 "\t" ht[hh]+0
            for (w=0;w<=6;w++){ bk=""; nn=split(cord[hh SUBSEP w],dz,","); for(qq=1;qq<=nn;qq++){ dd=dz[qq]; bk=bk (bk?",":"") dd ":" cd[hh SUBSEP w SUBSEP dd] }
                linexx = linexx "\t@data:h" w "=" bk }
            linexx = linexx "\t@data:buckets=" hbk[hh] "\t@data:loglines=" lastlines("H" SUBSEP hh)
            print linexx }
        tl = "HTOT\tTotal"; for (w=0;w<=6;w++) tl = tl "\t@{class=num}" wtot[w]+0
        tl = tl "\t@{class=num failed}" toterr+0 "\t@{class=num warn}" totwarn+0 "\t@{class=num}" tot+0; print tl
        printf "TOT|%d|%d|%d\n", tot+0, toterr+0, totwarn+0
    }
' "$(srv_subset noninfo)")   # the non-Info lines (bin/server/subsets.sh — 2026-09-29, speed round 3)

IFS='|' read -r _ t_tot t_err t_warn <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
if [ "${t_tot:-0}" -eq 0 ]; then
    echo "No Error/Warning messages found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

heat_rows=$(printf '%s\n' "$agg" | grep $'^HROW\t\|^HTOT\t' | sed 's/^HROW\t/ROW\t/; s/^HTOT\t/TOTAL\t/')

{
    printf 'TITLE\tError Timing\n'

    printf 'TABLE\tHour × weekday heatmap\theat\n'
    printf 'HEAD\tHour\tMonday\tTuesday\tWednesday\tThursday\tFriday\tSaturday\tSunday\tErrors\tWarnings\tTotal\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tnum\tnumfailed\tnumwarn\tnum\n'
    printf '%s\n' "$heat_rows"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_tot msg(s): $t_err err, $t_warn warn)." >&2
