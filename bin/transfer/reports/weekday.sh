#!/usr/bin/env bash
#
# weekday.sh — load by DAY OF WEEK (Mon..Sun). Per weekday: the number of
# calendar days observed, the Files count and average per day, the Failed/
# Processed split, failure rate and volume — useful for spotting weekday vs
# weekend batch patterns. The weekday is derived with Julian day numbers
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
ensure_parsed
skip_if_fresh "$REPORTS_DIR/weekday.rpt" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

names=(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

clabel="Files"; noun="File"; drillmod=""
OUT="$REPORTS_DIR/weekday.rpt"

# Bucket the normalized stream by weekday (jdn %% 7, 0=Mon). Same as before,
# reading cols 1=date 2=jdn 3=time 4=proc 5=size 6=sortkey 7=id.
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    {
        iso = $1; size = $5; pf = ($4 == 0); w = ($2 + 0) % 7
        wr[w]++; wb[w] += size; trec++; tbytes += size
        if (!(iso in seendate)) { seendate[iso] = 1; wdays[w]++ }
        if (pf) { wf[w]++; tf++ } else { wp[w]++; tp++ }
        wdl[w SUBSEP iso]++; wdf[w SUBSEP iso] += pf; wdp[w SUBSEP iso] += (!pf); wdb[w SUBSEP iso] += size
        addtop("W" SUBSEP w SUBSEP (pf ? "F" : "P"), $6, $1 " " $3, $7)
    }
    END {
        for (k in wdl) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" wdl[k] ":" (wdf[k]+0) ":" (wdp[k]+0) ":" wdb[k] }
        for (i = 0; i <= 6; i++) {
            rec = wr[i] + 0; days = wdays[i] + 0
            avg = days > 0 ? sprintf("%d", rec / days + 0.5) : "0"   # round HALF-UP, exactly report.js'\''s a-token (Math.round) — plain %d truncated and the value flicked by 1 after a date round-trip (audit C3)
            pct = rec > 0 ? sprintf("%.1f", (wf[i]+0) * 100 / rec) : "0.0"
            printf "WD|%d|%d|%d|%s|%d|%d|%s|%d|%s|%s|%s|%s\n", i, days, rec, avg, wf[i]+0, wp[i]+0, pct, wb[i]+0, human(wb[i]+0), bk[i], buildlist(top["W" SUBSEP i SUBSEP "F"]), buildlist(top["W" SUBSEP i SUBSEP "P"])
        }
        tpct = trec > 0 ? sprintf("%.1f", (tf+0) * 100 / trec) : "0.0"
        printf "TOT|%d|%d|%d|%s|%s\n", trec, tf+0, tp+0, tpct, human(tbytes)
    }
' <(activity_stream))

if [ -z "$agg" ]; then echo "No usable records found." >&2; exit 0; fi
IFS='|' read -r _ tot_rec tot_failed tot_processed tot_pct tot_human <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
n_wdays=$(printf '%s\n' "$agg" | grep -c '^WD|' || true)

# the Load bar scales each weekday's Avg/day against the BUSIEST weekday's
# average (not the raw sums — the observed day counts differ per weekday)
maxavg=$(printf '%s\n' "$agg" | grep '^WD|' | awk -F'|' 'BEGIN{m=0} $5+0>m{m=$5+0} END{print m}')

{
    printf 'TITLE\tLoad by Weekday\n'
    printf 'DESC\t%s, average per day, Error/OK, failure rate and volume by day of week, with a load bar.\n' "$clabel"
    printf 'INTRO\t%s by day of week (overall **%s%%** failed). "Avg/day" divides by the number of that weekday actually observed; the bar shows load relative to the busiest weekday (by average per day).\n' \
        "$clabel" "$tot_pct"
    printf 'TABLE\tBy day of week%s\n' "$drillmod"
    printf 'HEAD\tWeekday\tDays\t%s\tAvg/day\tError\tOK\tError %%\tVolume\tLoad\n' "$clabel"
    printf 'KIND\ttext\tnum\tnum\tnum\tnumfailed\tnumprocessed\tnum\tnum\tbar\n'
    printf 'RECALC\t-\tc\ts0\ta0\ts1\ts2\tp1.0\th3\tB0\n'
    # the rows go straight to the report — no per-row command substitution
    while IFS='|' read -r _ widx days rec avg fa pr pct bytes human bk ccf ccp; do
        [ -z "$widx" ] && continue
        lbar=0; [ "${maxavg:-0}" -gt 0 ] && lbar=$(( (avg * 100 + maxavg / 2) / maxavg ))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s%%\t%s\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n' \
            "${names[$widx]}" "$days" "$rec" "$avg" "$fa" "$pr" "$pct" "$human" "$lbar" "$bk" "$ccf" "$ccp"
    done <<< "$(printf '%s\n' "$agg" | grep '^WD|' | sort -t'|' -k2,2n)"
    printf 'TOTAL\tTotal (%s weekday(s))\t\t@{class=num}%s\t\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s%%\t@{class=num}%s\t\n' \
        "$n_wdays" "$tot_rec" "$tot_failed" "$tot_processed" "$tot_pct" "$tot_human"
    printf 'NOTE\tOne row = one day of week. Click an Error or OK count for that outcome'\''s 10 most recent %ss (newest first).\n' "$noun"
    printf 'SUMMARY\tTotal %ss: %s  |  Error: %s (%s%%)  |  Volume: %s\n' "$noun" "$tot_rec" "$tot_failed" "$tot_pct" "$tot_human"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($tot_rec $noun(s))." >&2
