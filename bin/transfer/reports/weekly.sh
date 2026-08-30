#!/usr/bin/env bash
#
# weekly.sh — TREND per ISO week: the Files count, average per day, Failed/
# Processed split, failure rate, volume, and the week-over-week change. Weeks
# are ISO-8601 (Mon-Sun), derived with Julian day numbers (portable). A week
# observed on fewer than 7 days is "(partial)" — the data window's edges. Emits
# weekly.rpt from the shared normalized stream (lib.sh activity_stream):
# 1=date 2=jdn 3=time 4=proc 5=size 6=sortkey 7=id.
#
# Usage:
#   ./weekly.sh    # reads input/*.csv (via the caches), writes data/weekly.rpt
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
skip_if_fresh "$REPORTS_DIR/weekly.rpt" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

clabel="Files"; noun="File"; drillmod=""
OUT="$REPORTS_DIR/weekly.rpt"

# Group the normalized stream by ISO week (the week of the date's Thursday).
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function jdn(y,m,d,   a) { a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    {
        jd = $2 + 0
        thu = jd - (jd % 7) + 3
        split(fromjdn(thu), yy, "-")
        wk = int((thu - jdn(yy[1]+0, 1, 1)) / 7) + 1
        k = yy[1] * 100 + wk
        cnt[k]++; vol[k] += $5; tcnt++; tvol += $5
        if ($4 == 1) { proc[k]++; tproc++ } else { fail[k]++; tfail++ }
        if (!((k, $1) in dseen)) { dseen[k, $1] = 1; wdays[k]++ }
        monday[k] = thu - 3
        wlabel[k] = sprintf("%04d-W%02d", yy[1], wk)
        addtop(k SUBSEP ($4 == 1 ? "P" : "F"), $6, $1 " " $3, $7)   # drill: 10 most recent of each outcome, that week
    }
    END {
        for (k in cnt) {
            pct = cnt[k] > 0 ? sprintf("%.1f", (fail[k]+0) * 100 / cnt[k]) : "0.0"
            printf "WK|%d|%s|%s|%s|%d|%d|%d|%d|%s|%d|%s|%s|%s\n", k, wlabel[k], fromjdn(monday[k]), fromjdn(monday[k] + 6), \
                wdays[k], cnt[k], fail[k]+0, proc[k]+0, pct, vol[k], human(vol[k]), buildlist(top[k SUBSEP "F"]), buildlist(top[k SUBSEP "P"])
        }
        tpct = tcnt > 0 ? sprintf("%.1f", tfail * 100 / tcnt) : "0.0"
        printf "TOT|%d|%d|%d|%s|%s\n", tcnt, tfail+0, tproc+0, tpct, human(tvol)
    }
' <(activity_stream))

# The awk END always emits a TOT| line, so guard on the presence of WK| rows:
# an empty counting unit yields no weeks, and the row pipeline below (a
# grep|sort|awk in a $()) would otherwise die under set -euo pipefail.
# Pure-bash pattern test, NOT `printf | grep -q` — grep -q exits at the first
# match and SIGPIPEs the printf once $agg outgrows grep's first read, which
# pipefail turns into a bogus "no records" (the trap that emptied topview).
nl=$'\n'
case "$agg" in "WK|"*|*"${nl}WK|"*) : ;; *) echo "No usable records found." >&2; exit 0 ;; esac
IFS='|' read -r _ tot_cnt tot_fail tot_proc tot_pct tot_vol <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
nweeks=$(printf '%s\n' "$agg" | grep -c '^WK|' || true)

rows=$(printf '%s\n' "$agg" | grep '^WK|' | sort -t'|' -k2,2n | awk -F'|' '
    {
        label = $3; if ($6 + 0 < 7) label = label " (partial)"
        avg = $6 > 0 ? int($7 / $6) : 0
        delta = "-"
        if (NR > 1 && prev > 0) delta = sprintf("%+.1f%%", ($7 - prev) * 100 / prev)
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%%\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", label, $4, $5, $6, $7, avg, $8, $9, $10, $12, delta, $13, $14
        prev = $7
    }
')

{
    printf 'TITLE\tPer Week\n'
    printf 'DESC\t%s, failure rate, volume and week-over-week change per ISO week.\n' "$clabel"
    printf 'INTRO\t**%s** ISO week(s) (Mon-Sun). "Δ %ss" compares each week'\''s count with the previous week; **(partial)** marks a week observed on fewer than 7 days — the edges of the data window — whose delta is not meaningful.\n' "$nweeks" "$noun"
    printf 'TABLE\tPer ISO week\twide%s\n' "$drillmod"
    printf 'HEAD\tWeek\tFrom\tTo\tDays\t%s\tAvg/day\tError\tOK\tError %%\tVolume\tΔ %ss\n' "$clabel" "$noun"
    printf 'KIND\ttext\ttext\ttext\tnum\tnum\tnum\tnumfailed\tnumprocessed\tnum\tnum\tnum\n'
    printf '%s\n' "$rows"
    printf 'TOTAL\tTotal (%s week(s))\t\t\t\t@{class=num}%s\t\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s%%\t@{class=num}%s\t\n' \
        "$nweeks" "$tot_cnt" "$tot_fail" "$tot_proc" "$tot_pct" "$tot_vol"
    printf 'NOTE\tOne row = one ISO week (Monday-Sunday) by start date. "Days" counts the calendar days with data; Avg/day divides by it. The From/To dates make the date filter hide out-of-range weeks. Click an Error or OK count for that outcome'\''s 10 most recent %ss (newest first).\n' "$noun"
    printf 'SUMMARY\tWeeks: %s  |  Total %ss: %s  |  Error: %s (%s%%)  |  Volume: %s\n' "$nweeks" "$noun" "$tot_cnt" "$tot_fail" "$tot_pct" "$tot_vol"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($nweeks week(s), $tot_cnt $noun(s))." >&2
