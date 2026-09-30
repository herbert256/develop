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
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

clabel="OK Files"; noun="OK File"   # the OK Files (2026-09-29 audit: "Files" read as every File beside an Error % over all Files)
OUT="$REPORTS_DIR/weekly.rpt"

# Group the normalized stream by ISO week (the week of the date's Thursday).
agg=$(awk -F'\t' "$AWKLIB"'
    {
        jd = $2 + 0
        thu = jd - (jd % 7) + 3
        split(fromjdn(thu), yy, "-")
        wk = int((thu - jdn(yy[1]+0, 1, 1)) / 7) + 1
        k = yy[1] * 100 + wk
        # VOLUME follows the Files column = the OK Files bytes (2026-09-29:
        # every File was summed beside an OK-only count)
        okb = ($4 == 1) ? $5 : 0
        cnt[k]++; vol[k] += okb; tcnt++; tvol += okb
        if ($4 == 1) { proc[k]++; tproc++ } else { fail[k]++; tfail++ }
        if (!((k, $1) in dseen)) { dseen[k, $1] = 1; wdays[k]++ }
        monday[k] = thu - 3
        wlabel[k] = sprintf("%04d-W%02d", yy[1], wk)
    }
    END {
        for (k in cnt) {
            pct = cnt[k] > 0 ? sprintf("%.1f", (fail[k]+0) * 100 / cnt[k]) : "0.0"
            printf "WK|%d|%s|%s|%s|%d|%d|%d|%d|%s|%d|%s\n", k, wlabel[k], fromjdn(monday[k]), fromjdn(monday[k] + 6), \
                wdays[k], cnt[k], fail[k]+0, proc[k]+0, pct, vol[k], hbytes2(vol[k])
        }
        tpct = tcnt > 0 ? sprintf("%.1f", tfail * 100 / tcnt) : "0.0"
        printf "TOT|%d|%d|%d|%s|%s\n", tcnt, tfail+0, tproc+0, tpct, hbytes2(tvol)
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
        # FILES = the delivered (OK) count, $9 (2026-09-13, user request: one
        # Files column, no Error / OK pair, no green/red cells, no drills);
        # Avg/day and the week-over-week delta follow it. Error % ($10) keeps
        # its base — errors over every File of the week.
        avg = $6 > 0 ? int($9 / $6) : 0
        delta = "-"
        if (NR > 1 && prev > 0) delta = sprintf("%+.1f%%", ($9 - prev) * 100 / prev)
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s%%\t%s\t%s\n", label, $4, $5, $6, $9, avg, $10, $12, delta
        prev = $9
    }
')

{
    printf 'TITLE\tPer Week\n'
    printf 'TABLE\tPer ISO week\twide\n'
    printf 'HEAD\tWeek\tFrom\tTo\tDays\t%s\tAvg/day\tError %%\tVolume\tΔ %ss\n' "$clabel" "$noun"
    printf 'KIND\ttext\ttext\ttext\tnum\tnum\tnum\tnum\tnum\tnum\n'
    printf '%s\n' "$rows"
    printf 'TOTAL\tTotal (%s week(s))\t\t\t\t@{class=num}%s\t\t@{class=num}%s%%\t@{class=num}%s\t\n' \
        "$nweeks" "$tot_proc" "$tot_pct" "$tot_vol"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($nweeks week(s), $tot_cnt $noun(s))." >&2
