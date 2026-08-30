#!/usr/bin/env bash
#
# hourly.sh — LOAD BY HOUR OF DAY (00-23). Per hour across all days: the Files
# count, Error/OK split, volume and a relative-load bar; plus an hour ×
# weekday heatmap. Emits hourly.rpt from the shared normalized stream
# (lib.sh activity_stream): 1=date 2=jdn 3=time 4=proc 5=size 6=sortkey 7=id.
#
# Usage:
#   ./hourly.sh    # reads input/*.csv (via the caches), writes data/hourly.rpt
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
skip_if_fresh "$REPORTS_DIR/hourly.rpt" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

clabel="Files"; noun="File"; drillmod=""
OUT="$REPORTS_DIR/hourly.rpt"

# ONE walk over the normalized stream feeds both tables: the per-hour aggregate
# goes to stdout as HOUR|/TOT| lines, the hour × weekday heatmap — whose cells
# are already .rpt ROW lines — to $HEAT beside it.
HEAT=$(mktemp "${TMPDIR:-/tmp}/hourly.XXXXXX")
trap 'rm -f "$HEAT"' EXIT

agg=$(activity_stream | awk -F'\t' -v heat="$HEAT" "$COREIDS_AWK"'
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    {
        size = $5; t = $3; d = $1; pf = ($4 == 0)
        if (t !~ /^[0-9][0-9]:/) next
        h = substr(t, 1, 2)
        hrec[h]++; hbytes[h] += size; trec++; tbytes += size
        if (pf) { hfail[h]++; tfail++ } else { hproc[h]++; tproc++ }
        hdr[h SUBSEP d]++; hdf[h SUBSEP d] += pf; hdp[h SUBSEP d] += (!pf); hdb[h SUBSEP d] += size
        addtop("H" SUBSEP h SUBSEP (pf ? "F" : "P"), $6, $1 " " $3, $7)
        # the same File on the heatmap grid: hour × weekday (2=jdn), each cell
        # keeping its own per-date series for report.js recalcHeat
        w = ($2 + 0) % 7
        c[h SUBSEP w]++; if (c[h SUBSEP w] > max) max = c[h SUBSEP w]; tot[w]++
        if (d != "") { hwd = h SUBSEP w SUBSEP d; if (!(hwd in cd)) ord[h SUBSEP w] = ord[h SUBSEP w] (ord[h SUBSEP w] ? "," : "") d; cd[hwd]++ }
    }
    END {
        maxrec = 0
        for (k in hrec) if (hrec[k] > maxrec) maxrec = hrec[k]
        for (k in hdr) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" hdr[k] ":" (hdf[k]+0) ":" (hdp[k]+0) ":" hdb[k] }
        for (i = 0; i < 24; i++) {
            hh = sprintf("%02d", i)
            printf "HOUR|%s|%d|%d|%d|%d|%s|%s|%s|%s\n", hh, hrec[hh]+0, hfail[hh]+0, hproc[hh]+0, hbytes[hh]+0, human(hbytes[hh]+0), bk[hh], buildlist(top["H" SUBSEP hh SUBSEP "F"]), buildlist(top["H" SUBSEP hh SUBSEP "P"])
        }
        printf "TOT|%d|%d|%d|%d|%s|%d\n", trec, tfail+0, tproc+0, tbytes, human(tbytes), maxrec
        # The heatmap rows, written as finished .rpt lines. Each cell carries
        # its own per-date bucket (@data:h<weekday>=date:count,…) so the
        # recalcHeat pass in report.js can re-sum every cell for the selected
        # range and re-tint by the new quartile — the one 2-D table that needs
        # a per-CELL series.
        if (max < 1) max = 1
        for (i = 0; i < 24; i++) {
            hh = sprintf("%02d", i); line = "ROW\t" hh ":00"
            for (w = 0; w <= 6; w++) {
                v = c[hh SUBSEP w] + 0
                if (v == 0) cell = ""
                else { r = v / max; ht = (r <= 0.25) ? 1 : (r <= 0.5) ? 2 : (r <= 0.75) ? 3 : 4; cell = "@{class=heat" ht "}" v }
                line = line "\t" cell
            }
            for (w = 0; w <= 6; w++) {
                hbk = ""; nn = split(ord[hh SUBSEP w], dz, ","); for (qq = 1; qq <= nn; qq++) { dd = dz[qq]; hbk = hbk (hbk ? "," : "") dd ":" cd[hh SUBSEP w SUBSEP dd] }
                line = line "\t@data:h" w "=" hbk
            }
            print line > heat
        }
        tl = "TOTAL\tTotal"
        for (w = 0; w <= 6; w++) tl = tl "\t@{class=num}" tot[w]+0
        print tl > heat
    }
')

if [ -z "$agg" ]; then echo "No usable records found." >&2; exit 0; fi
IFS='|' read -r _ tot_rec tot_failed tot_processed tot_bytes tot_human max_rec <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
[ "${max_rec:-0}" -eq 0 ] && max_rec=1
n_hours=$(printf '%s\n' "$agg" | grep -c '^HOUR|' || true)

{
    printf 'TITLE\tLoad by Hour\n'
    printf 'DESC\t%s, Error/OK and volume per hour of day, with a load bar.\n' "$clabel"
    printf 'INTRO\t%s across the 24 hours of the day, by start time. The bar shows load relative to the busiest hour.\n' "$clabel"
    printf 'TABLE\tPer hour of day%s\n' "$drillmod"
    printf 'HEAD\tHour\t%s\tError\tOK\tVolume\tLoad\n' "$clabel"
    printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum\tbar\n'
    printf 'RECALC\t-\ts0\ts1\ts2\th3\tb0\n'
    # the 24 hour rows, the Load bar scaled against the busiest hour
    printf '%s\n' "$agg" | grep '^HOUR|' | awk -F'|' -v mx="$max_rec" '
        $2 != "" { printf "ROW\t%s:00\t%s\t%s\t%s\t%s\t%d\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
                          $2, $3, $4, $5, $7, int($3 * 100 / mx), $8, $9, $10 }' || true
    printf 'TOTAL\tTotal (%s hour(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t\n' \
        "$n_hours" "$tot_rec" "$tot_failed" "$tot_processed" "$tot_human"
    printf 'NOTE\tClick an Error or OK count for that outcome'\''s 10 most recent %ss (newest first).\n' "$noun"

    printf 'TABLE\tHour × weekday\theat\n'
    printf 'HEAD\tHour\tMonday\tTuesday\tWednesday\tThursday\tFriday\tSaturday\tSunday\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tnum\n'
    cat "$HEAT"
    printf 'NOTE\tEach cell counts the %ss starting in that hour on that weekday, tinted by quartile of the busiest cell — batch windows show as dark blocks. The date filter re-sums every cell and re-tints for the selected range.\n' "$noun"
    printf 'SUMMARY\tTotal %ss: %s  |  Error: %s  |  OK: %s  |  Volume: %s\n' "$noun" "$tot_rec" "$tot_failed" "$tot_processed" "$tot_human"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($tot_rec $noun(s))." >&2
