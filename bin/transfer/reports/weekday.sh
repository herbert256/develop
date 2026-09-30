#!/usr/bin/env bash
#
# weekday.sh — load by DAY OF WEEK (Mon..Sun). Per weekday: the number of
# calendar days observed, the OK Files count and average per day and their
# volume — useful for spotting weekday vs weekend batch patterns. (The Error %
# column went 2026-09-30, user request "Remove the Error column, rename OK
# Files to Files" — the column is labelled Files, it still counts the OK
# Files, Processed + Waiting; the buckets carry only what is left: ok and
# bytes.) The weekday is derived with Julian day numbers
# (portable). Emits weekday.rpt from the shared normalized stream
# (lib.sh activity_stream): 1=date 2=jdn 3=time 4=proc 5=size 6=sortkey 7=id.
#
# Usage:
#   ./weekday.sh    # reads input/*.csv (via the caches), writes data/weekday.rpt
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

names=(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

clabel="Files"; noun="OK File"   # the OK Files (2026-09-29 audit), labelled "Files" since 2026-09-30 (user request)
OUT="$REPORTS_DIR/weekday.rpt"

# Bucket the normalized stream by weekday (jdn %% 7, 0=Mon). Same as before,
# reading cols 1=date 2=jdn 3=time 4=proc 5=size 6=sortkey 7=id.
agg=$(awk -F'\t' "$AWKLIB"'
    {
        iso = $1; size = $5; pf = ($4 == 0); w = ($2 + 0) % 7
        # VOLUME follows the Files column = the OK Files bytes (2026-09-29:
        # every File was summed beside an OK-only count)
        okb = pf ? 0 : size
        wb[w] += okb; trec++; tbytes += okb
        if (!(iso in seendate)) { seendate[iso] = 1; wdays[w]++ }
        if (!pf) { wp[w]++; tp++ }
        wdl[w SUBSEP iso]++; wdp[w SUBSEP iso] += (!pf); wdb[w SUBSEP iso] += okb
    }
    END {
        # bucket = date:ok:bytes (metrics 0 and 1)
        for (k in wdl) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" (wdp[k]+0) ":" wdb[k] }
        for (i = 0; i <= 6; i++) {
            days = wdays[i] + 0
            avg = days > 0 ? sprintf("%d", (wp[i]+0) / days + 0.5) : "0"   # the OK count per observed day (Files = delivered since 2026-09-13); round HALF-UP, exactly report.js'\''s a-token (Math.round) — plain %d truncated and the value flicked by 1 after a date round-trip (audit C3)
            printf "WD|%d|%d|%s|%d|%s|%s\n", i, days, avg, wp[i]+0, hbytes2(wb[i]+0), bk[i]
        }
        printf "TOT|%d|%d|%s\n", trec, tp+0, hbytes2(tbytes)
    }
' <(activity_stream))

if [ -z "$agg" ]; then echo "No usable records found." >&2; exit 0; fi
IFS='|' read -r _ tot_rec tot_processed tot_human <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
n_wdays=$(printf '%s\n' "$agg" | grep -c '^WD|' || true)

# the Load bar scales each weekday's Avg/day against the BUSIEST weekday's
# average (not the raw sums — the observed day counts differ per weekday)
maxavg=$(printf '%s\n' "$agg" | grep '^WD|' | awk -F'|' 'BEGIN{m=0} $4+0>m{m=$4+0} END{print m}')

{
    printf 'TITLE\tLoad by Weekday\n'
    printf 'TABLE\tBy day of week\n'
    # FILES = the delivered (OK) count (2026-09-13, user request: one Files
    # column, no Error / OK pair, no green/red cells, no drills; the Error %
    # column went 2026-09-30): Files and the bar read metric 0 (ok), Avg/day
    # = ok per observed day, Volume metric 1
    printf 'HEAD\tWeekday\tDays\t%s\tAvg/day\tVolume\tLoad\n' "$clabel"
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\tbar\n'
    printf 'RECALC\t-\tc\ts0\ta0\th1\tB0\n'
    # the rows go straight to the report — no per-row command substitution
    while IFS='|' read -r _ widx days avg pr human bk; do
        [ -z "$widx" ] && continue
        lbar=0; [ "${maxavg:-0}" -gt 0 ] && lbar=$(( (avg * 100 + maxavg / 2) / maxavg ))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\n' \
            "${names[$widx]}" "$days" "$pr" "$avg" "$human" "$lbar" "$bk"
    done <<< "$(printf '%s\n' "$agg" | grep '^WD|' | sort -t'|' -k2,2n)"
    printf 'TOTAL\tTotal (%s weekday(s))\t\t@{class=num}%s\t\t@{class=num}%s\t\n' \
        "$n_wdays" "$tot_processed" "$tot_human"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($tot_processed $noun(s))." >&2
