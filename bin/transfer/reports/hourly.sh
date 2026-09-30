#!/usr/bin/env bash
#
# hourly.sh — LOAD BY HOUR OF DAY (00-23). Per hour across all days: the
# delivered (OK) Files, volume and a relative-load bar; plus an hour ×
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
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

noun="File"
OUT="$REPORTS_DIR/hourly.rpt"

# ONE walk over the normalized stream feeds both tables: the per-hour aggregate
# goes to stdout as HOUR|/TOT| lines, the hour × weekday heatmap — whose cells
# are already .rpt ROW lines — to $HEAT beside it.
HEAT=$(mktemp "${TMPDIR:-/tmp}/hourly.XXXXXX")
trap 'rm -f "$HEAT"' EXIT

agg=$(activity_stream | awk -F'\t' -v heat="$HEAT" "$AWKLIB"'
    {
        size = $5; t = $3; d = $1; pf = ($4 == 0)
        if (t !~ /^[0-9][0-9]:/) next
        h = substr(t, 1, 2)
        # VOLUME follows the Delivered column = the OK Files bytes (2026-09-29:
        # every File was summed beside an OK-only count)
        okb = pf ? 0 : size
        hrec[h]++; hbytes[h] += okb; trec++; tbytes += okb
        if (pf) { hfail[h]++; tfail++ } else { hproc[h]++; tproc++ }
        hdr[h SUBSEP d]++; hdf[h SUBSEP d] += pf; hdp[h SUBSEP d] += (!pf); hdb[h SUBSEP d] += okb
        # the same OK File on the heatmap grid: hour × weekday (2=jdn), each
        # cell keeping its own per-date series for report.js recalcHeat — OK
        # Files like its sibling tabs (2026-09-30 audit T-07: the grid counted
        # EVERY File, 33620 against the 32062 OK Files beside it)
        if (!pf) {
            w = ($2 + 0) % 7
            c[h SUBSEP w]++; if (c[h SUBSEP w] > max) max = c[h SUBSEP w]; tot[w]++
            if (d != "") { hwd = h SUBSEP w SUBSEP d; if (!(hwd in cd)) ord[h SUBSEP w] = ord[h SUBSEP w] (ord[h SUBSEP w] ? "," : "") d; cd[hwd]++ }
        }
    }
    END {
        for (k in hdr) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" hdr[k] ":" (hdf[k]+0) ":" (hdp[k]+0) ":" hdb[k] }
        for (i = 0; i < 24; i++) {
            hh = sprintf("%02d", i)
            printf "HOUR|%s|%d|%d|%d|%d|%s|%s\n", hh, hrec[hh]+0, hfail[hh]+0, hproc[hh]+0, hbytes[hh]+0, hbytes2(hbytes[hh]+0), bk[hh]
        }
        printf "TOT|%d|%d|%d|%s\n", trec, tfail+0, tproc+0, hbytes2(tbytes)
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
IFS='|' read -r _ tot_rec tot_failed tot_processed tot_human <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
n_hours=$(printf '%s\n' "$agg" | grep -c '^HOUR|' || true)

{
    printf 'TITLE\tLoad by Hour\n'
    printf 'TABLE\tPer hour of day\n'
    # FILES = the delivered (OK) count, HOUR field 5 (2026-09-13, user request:
    # one Files column, no Error / OK pair, no green/red cells, no drills);
    # the bucket payload keeps all four metrics, so the tokens read metric 2
    # (ok) for Files and the bar, metric 3 for Volume
    # the column reads "Delivered" (2026-09-29): it counts the OK Files only,
    # and the Volume beside it is their bytes; the grid below counts the OK
    # Files too (every File until 2026-09-30)
    printf 'HEAD\tHour\tOK Files\tVolume\tLoad\n'   # OK = Processed + Waiting (2026-09-29 audit: "Delivered" held the staged Waiting Files)
    printf 'KIND\ttext\tnum\tnum\tbar\n'
    printf 'RECALC\t-\ts2\th3\tb2\n'
    # the 24 hour rows, the Load bar scaled against the busiest hour (by OK Files)
    max_ok=$(printf '%s\n' "$agg" | grep '^HOUR|' | awk -F'|' 'BEGIN{m=0} $5+0>m{m=$5+0} END{print m}')
    [ "${max_ok:-0}" -eq 0 ] && max_ok=1
    printf '%s\n' "$agg" | grep '^HOUR|' | awk -F'|' -v mx="$max_ok" '
        $2 != "" { printf "ROW\t%s:00\t%s\t%s\t%d\t@data:buckets=%s\n", $2, $5, $7, int($5 * 100 / mx), $8 }' || true
    printf 'TOTAL\tTotal (%s hour(s))\t@{class=num}%s\t@{class=num}%s\t\n' \
        "$n_hours" "$tot_processed" "$tot_human"

    printf 'TABLE\tHour × weekday\theat\n'
    printf 'HEAD\tHour\tMonday\tTuesday\tWednesday\tThursday\tFriday\tSaturday\tSunday\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tnum\n'
    cat "$HEAT"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($tot_rec $noun(s))." >&2
