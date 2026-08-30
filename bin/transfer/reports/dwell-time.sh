#!/usr/bin/env bash
#
# dwell-time.sh — store-and-forward queue dwell: how long a file waits inside ST
# between finishing its INBOUND leg (arriving) and starting its first OUTBOUND leg
# (being forwarded). Nothing else measures this gap — duration.sh covers the
# end-to-end span, not the latency between legs. A rising dwell means files are queueing.
#
# Per CoreId (rows are CoreId-adjacent in _transfers.tsv): dwell = earliest outbound
# start − latest inbound completion (the raw end_time, "MM/DD/YYYY HH:MM:SS.mmm").
# Measurable = the CoreId has an inbound end AND an outbound start with the
# outbound not starting before the inbound finished. Date arithmetic uses a
# Julian-day-number helper (no `date` command), like the rest of the repo.
#
# Reads data/_transfers.tsv. Writes data/dwell-time.rpt.
#
# Usage:
#   ./dwell-time.sh    # reads input/*.csv (via the cache), writes data/dwell-time.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/dwell-time.rpt"
TOP_N=100

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

humandur() { awk -v ms="$1" 'BEGIN{
    if (ms < 1000) printf "%d ms", int(ms+0.5)
    else if (ms < 60000) printf "%.2f s", ms/1000
    else if (ms < 3600000) printf "%.1f min", ms/60000
    else printf "%.2f h", ms/3600000 }'; }

# One pass, grouping CoreId-adjacent rows. For each CoreId compute the dwell (ms),
# then accumulate the distribution, per-subscription stats (count/sum/max + drill)
# and per-date buckets; also emit one "DWELL <ms>" line per measurable CoreId for
# the overall percentiles.
#
# The B and P lines carry their DISPLAY values (the bucket share, and the avg/max
# dwell already run through humandur) as trailing fields, so the row builders below
# are one awk each instead of a fork per bucket and three per subscription. The
# fields ahead of them — including the sort keys — are unchanged.
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function humandur(ms) {
        if (ms < 1000)    return sprintf("%d ms", int(ms + 0.5))
        if (ms < 60000)   return sprintf("%.2f s", ms/1000)
        if (ms < 3600000) return sprintf("%.1f min", ms/60000)
        return sprintf("%.2f h", ms/3600000)
    }
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function secs(t,  p){ if (split(t, p, ":") < 3) return -1; return p[1]*3600 + p[2]*60 + p[3] }
    function ep_iso(di, t,  p, s){ if (split(di, p, "-") < 3) return -1; s=secs(t); if (s<0) return -1; return jdn(p[1]+0,p[2]+0,p[3]+0)*86400 + s }
    function ep_us(x,  a, dp, s){ if (split(x, a, " ") < 2) return -1; if (split(a[1], dp, "/") < 3) return -1; s=secs(a[2]); if (s<0) return -1; return jdn(dp[3]+0,dp[1]+0,dp[2]+0)*86400 + s }
    function flush(   dw, r, o, site2){
        if (in_end < 0 || out_start < 0 || out_start < in_end) { if (in_end>=0 && out_start>=0) neg++; return }
        dw = (out_start - in_end) * 1000                          # ms
        n++
        site2 = (gsite=="") ? "(none)" : gsite
        print "DWELL " int(dw+0.5)
        # distribution
        s = dw/1000
        if      (s < 1)   { o=0; b="< 1 s" }
        else if (s < 5)   { o=1; b="1 – 5 s" }
        else if (s < 30)  { o=2; b="5 – 30 s" }
        else if (s < 60)  { o=3; b="30 – 60 s" }
        else if (s < 300) { o=4; b="1 – 5 min" }
        else              { o=5; b="over 5 min" }
        dc[b]++; dord[b]=o
        if (gd != "") { dbd[b SUBSEP gd]++; if (!((b SUBSEP gd) in dbs)) dbl[b]=dbl[b] (dbl[b]?",":"") gd; dbs[b SUBSEP gd]=1 }
        # per subscription
        sc[site2]++; ss[site2]+=dw; if (dw>sm[site2]) sm[site2]=dw
        if (gd != "") { scd[site2 SUBSEP gd]++; ssd[site2 SUBSEP gd]+=dw; if (dw>smd[site2 SUBSEP gd]) smd[site2 SUBSEP gd]=dw
            if (!((site2 SUBSEP gd) in sds)) sdl[site2]=sdl[site2] (sdl[site2]?",":"") gd; sds[site2 SUBSEP gd]=1 }
        addtop(site2, gsk, gd " " gtime, gcid)
    }
    $1 != cur {
        if (cur != "") flush()
        cur=$1; in_end=-1; out_start=-1; gsite=""; gd=""; gtime=""; gsk=""; gcid=$1
    }
    {
        if ($2 == "Inbound" && $18 != "") { e = ep_us($18); if (e > in_end) in_end = e }
        if ($2 == "Outbound" && $12 ~ /^[0-9][0-9]:/) { s2 = ep_iso($11, $12); if (s2 >= 0 && (out_start < 0 || s2 < out_start)) { out_start = s2; gd=$11; gtime=$12; gsk=$13 } }
        if (gsite=="" && $6!="") gsite=$6
    }
    END {
        if (cur != "") flush()
        for (b in dc) { no=split(dbl[b],dz,","); bk=""; for(i=1;i<=no;i++){dd=dz[i]; bk=bk (bk?",":"") dd ":" dbd[b SUBSEP dd]}
            print "B\t" dord[b] "\t" b "\t" dc[b] "\t" bk "\t" sprintf("%.1f", n ? dc[b]*100/n : 0) }
        # A dwell carries fractional milliseconds, so format the SAME value the
        # printed columns 4/5 carry — round-tripped through CONVFMT (%.6g) — not
        # the raw double; the two disagree at the last decimal.
        for (p in sc) { no=split(sdl[p],dz,","); bk=""; for(i=1;i<=no;i++){dd=dz[i]; k=p SUBSEP dd; bk=bk (bk?",":"") dd ":" scd[k] ":" (ssd[k]+0) ":" (smd[k]+0)}
            psum=(ss[p] "")+0; pmax=(sm[p] "")+0
            print "P\t" p "\t" sc[p] "\t" ss[p] "\t" sm[p] "\t" bk "\t" buildlist(top[p]) "\t" humandur(int(psum/sc[p])) "\t" humandur(pmax) }
        print "TOT\t" n+0 "\t" neg+0
    }
' "$PARSED")

IFS=$'\t' read -r _ n_meas n_neg <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${n_meas:-0}" -eq 0 ]; then
    # No data (e.g. a minimal dataset) is not an error — write an empty-state
    # page and exit 0, so the build's report pool does not abort.
    {
        printf 'TITLE\tStore-and-Forward\n'
        printf 'DESC\tHow long a file waits inside SecureTransport between finishing its inbound leg and starting its outbound leg — the store-and-forward queue dwell time, which no other report measures.\n'
        printf 'INTRO\tNo files had a measurable store-and-forward dwell in this dataset (an inbound leg finishing, then a matching outbound leg).\n'
        printf 'TABLE\tStore-and-forward dwell\n'
        printf 'HEAD\tDwell\n'
        printf 'KIND\ttext\n'
        printf 'ROW\tNo measurable store-and-forward transfers in this dataset.\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "No measurable store-and-forward transfers found — wrote empty-state $OUT." >&2
    exit 0
fi

# overall percentiles from the DWELL lines (no early awk `exit` — it would SIGPIPE
# the upstream printf under pipefail; just select the row and read to EOF)
sorted=$(printf '%s\n' "$agg" | awk '/^DWELL /{print $2}' | sort -n)
med_idx=$(( (n_meas + 1) / 2 )); [ "$med_idx" -lt 1 ] && med_idx=1
p95_idx=$(awk -v n="$n_meas" 'BEGIN{i=int(n*0.95); print (i<1?1:i)}')
med_ms=$(printf '%s\n' "$sorted" | awk -v i="$med_idx" 'NR==i{print}')
p95_ms=$(printf '%s\n' "$sorted" | awk -v i="$p95_idx" 'NR==i{print}')
max_ms=$(printf '%s\n' "$sorted" | tail -1)
med=$(humandur "${med_ms:-0}"); p95=$(humandur "${p95_ms:-0}"); mx=$(humandur "${max_ms:-0}")

dist_rows=$(printf '%s\n' "$agg" | grep $'^B\t' | sort -t"$(printf '\t')" -k2,2n \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:ord=%s\n", $3, $4, $6, $5, $2 }')
[ -n "$dist_rows" ] && dist_rows+=$'\n'

site_rows=$(printf '%s\n' "$agg" | grep $'^P\t' | sort -t"$(printf '\t')" -k5,5nr \
    | awk -F'\t' -v n="$TOP_N" 'NR<=n { printf "ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids=%s\n", $2, $3, $8, $9, $6, $7 }')
n_site=$(printf '%s\n' "$agg" | grep -c $'^P\t' || true)
sitecap=""; [ "$n_site" -gt "$TOP_N" ] && sitecap=$(printf ' (top %s of %s subscriptions by max dwell)' "$TOP_N" "$n_site")

{
    printf 'TITLE\tStore-and-Forward\n'
    printf 'DESC\tHow long a file waits inside SecureTransport between finishing its inbound leg and starting its outbound leg — the store-and-forward queue dwell time, which no other report measures.\n'
    printf 'INTRO\t**%s** Files had a measurable store-and-forward dwell (inbound completed, then forwarded). **Median %s**, **p95 %s**, **max %s**. %s File(s) forwarded before the inbound finished (overlapping legs) are excluded. Dwell = earliest outbound start − latest inbound completion. Click a subscription for its 10 most recent Files.\n' \
        "$n_meas" "$med" "$p95" "$mx" "$n_neg"

    printf 'TABLE\tDwell-time distribution\n'
    printf 'HEAD\tDwell\tFiles\tShare\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t%%0\n'
    printf '%s' "$dist_rows"
    printf '%s' "$dist_rows" | awk -F'\t' '/^ROW/{n++; c+=$3} END{printf "TOTAL\tTotal (%d rows)\t@{class=num}%d\t100%%\n", n+0, c+0}'
    printf 'NOTE\tHow the measurable dwell times are distributed. Most files forward almost immediately; the long tail is where store-and-forward latency lives. Re-aggregates over the selected dates.\n'

    printf 'TABLE\tDwell by subscription\twide\n'
    printf 'HEAD\tSubscription\tFiles\tAvg dwell\tMax dwell\n'
    printf 'KIND\tsite\tnum\tnum\tnum\n'
    printf 'RECALC\t-\ts0\tq1.0\tx2\n'
    printf '%s\n' "$site_rows"
    printf '%s\n' "$site_rows" | awk -F'\t' '/^ROW/{n++; c+=$3} END{printf "TOTAL\tTotal (%d rows)\t@{class=num}%d\t\t\n", n+0, c+0}'
    printf 'NOTE\tAverage and maximum dwell per subscription%s, slowest-first. Avg and Max re-aggregate over the selected dates. Click a subscription for its 10 most recent Files.\n' "$sitecap"

# The report is assembled in THREE writes (this block, the gap-per-day append,
# the SUMMARY/FOOT append) — all land in $OUT.tmp; the mv after the last one
# publishes the complete file atomically, so a killed run can never leave a
# truncated $OUT with a fresh mtime for skip_if_fresh to trust.
} > "$OUT.tmp"

# ---- Inbound / Outbound gap per day (formerly inout-gap.sh, absorbed 2026-07):
# gap = outbound start - (inbound start + inbound duration), single-leg-each
# delivered Files only — the same wait measured per DAY with percentiles.
(

awk -F'\t' -v GENDATE="$(date '+%Y-%m-%d %H:%M:%S')" -v NFILES="${#files[@]}" '
    # HH:MM:SS.mmm -> ms since midnight ("" -> 0)
    function hms(t,   a) { if (t == "") return 0; split(t, a, "[:.]"); return ((a[1]*3600) + (a[2]*60) + a[3]) * 1000 + a[4] }
    # compact cell format (mirrors duration.sh hd()): ms<5000, then whole s<300s,
    # then whole m<300m, then whole h. report.js parseNum reads ms/s/m/h so the
    # columns still sort. Handles a negative gap (should not occur) as "-N ...".
    function hd(ms,   s) { ms = ms + 0; s = ""; if (ms < 0) { s = "-"; ms = -ms }
        if (ms < 5000)     return s sprintf("%d ms", ms)
        if (ms < 300000)   return s sprintf("%d s", int(ms/1000 + 0.5))
        if (ms < 18000000) return s sprintf("%d m", int(ms/60000 + 0.5))
        return s sprintf("%d h", int(ms/3600000 + 0.5)) }
    function qsort(A, lo, hi,   i, j, p, t) {
        while (lo < hi) { i = lo; j = hi; p = A[int((lo + hi) / 2)]
            while (i <= j) { while (A[i] < p) i++; while (A[j] > p) j--
                if (i <= j) { t = A[i]; A[i] = A[j]; A[j] = t; i++; j-- } }
            if (j - lo < hi - i) { if (lo < j) qsort(A, lo, j); lo = i }
            else                 { if (i < hi) qsort(A, i, hi); hi = j } } }
    function pct(A, n, P) { return A[int((n - 1) * P / 100 + 0.5) + 1] }   # nearest-rank over A[1..n]
    # a CoreId group closes: keep it only when it is exactly 1 Inbound + 1
    # Outbound, both Processed and both dated, then bank its gap under the
    # inbound date.
    function flush(   istart, iend, ostart, gap, d) {
        if (prev == "") return
        if (ni == 1 && no == 1 && ist == "Processed" && ost == "Processed" && ijdn != "" && ojdn != "") {
            istart = ijdn * 86400000 + hms(itm)
            iend   = istart + (idur + 0 > 0 ? idur + 0 : 0)
            ostart = ojdn * 86400000 + hms(otm)
            gap = ostart - iend
            d = idate
            if (d ~ /^[0-9][0-9][0-9][0-9]-/) { dc[d]++; DV[d SUBSEP dc[d]] = gap; ALL[++AN] = gap }
        }
    }
    {
        if ($1 != prev) { flush(); prev = $1; ni = 0; no = 0; ist = ""; ost = ""; ijdn = ""; ojdn = "" }
        if ($2 == "Inbound")       { ni++; ijdn = $14; itm = $12; idur = $15; ist = $3; idate = $11 }
        else if ($2 == "Outbound") { no++; ojdn = $14; otm = $12; ost = $3 }
    }
    END {
        flush()
        nd = 0; for (d in dc) days[++nd] = d
        for (i = 2; i <= nd; i++) { v = days[i]; j = i - 1; while (j >= 1 && days[j] > v) { days[j+1] = days[j]; j-- } days[j+1] = v }

        if (AN > 0) { for (k = 1; k <= AN; k++) O[k] = ALL[k]; qsort(O, 1, AN)
            gmin = hd(O[1]); gmed = hd(pct(O,AN,50)); gmax = hd(O[AN])
            g25 = hd(pct(O,AN,25)); g50 = hd(pct(O,AN,50)); g75 = hd(pct(O,AN,75)); g95 = hd(pct(O,AN,95)); g99 = hd(pct(O,AN,99)) }
        else { gmin = gmed = gmax = g25 = g50 = g75 = g95 = g99 = "-" }

        printf "INTRO\tInbound-to-outbound gap for the **%d** delivered (OK) Files that have exactly one Inbound and one Outbound record, over **%d** day(s). Overall **min %s**, **median (p50) %s**, **p95 %s**, **p99 %s**, **max %s**. The gap is the outbound record start minus the inbound record END (its start plus its duration) — how long a file waits inside SecureTransport between arriving and leaving. Per-day columns are shown as **ms / s / m / h** (whole units); a narrowed date range keeps each day but blanks the non-additive totals.\n", AN, nd, gmin, gmed, g95, g99, gmax

        print "TABLE\tGap per day\twide\ttotaltop\tnoagg=2,3,4,5,6,7,8,9"
        print "HEAD\tDate\tFiles\tMin\tMedian\tMax\tP25\tP50\tP75\tP95\tP99"
        print "KIND\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tnum\tnum\tnum"
        printf "TOTAL\tOverall (%d days)\t@{class=num}%d\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\n", nd, AN, gmin, gmed, gmax, g25, g50, g75, g95, g99
        for (i = 1; i <= nd; i++) { d = days[i]; n = dc[d]
            for (k = 1; k <= n; k++) T[k] = DV[d SUBSEP k]; qsort(T, 1, n)
            printf "ROW\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", d, n, hd(T[1]), hd(pct(T,n,50)), hd(T[n]), hd(pct(T,n,25)), hd(pct(T,n,50)), hd(pct(T,n,75)), hd(pct(T,n,95)), hd(pct(T,n,99)) }

        print "NOTE\tOne \"File\" = one logical transfer (all records sharing a CoreId). Only Files with **exactly one Inbound and one Outbound** record, **both status Processed**, are counted (retries and any failed leg are excluded). **Gap = outbound start - (inbound start + inbound duration)** — the wait inside SecureTransport between the two legs. Per-day min/median/max and percentiles are **not additive**: a narrowed date range keeps each day row but blanks the total. Median is the same value as P50. Percentiles use the nearest-rank method."
    }
' "$PARSED" >> "$OUT.tmp"

)

{
    printf 'SUMMARY\tMeasurable: %s  |  Median: %s  |  p95: %s  |  Max: %s\n' "$n_meas" "$med" "$p95" "$mx"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} >> "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_meas measurable, median $med, p95 $p95, max $mx)." >&2
