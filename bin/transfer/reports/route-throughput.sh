#!/usr/bin/env bash
#
# route-throughput.sh — wire speed per ROUTE (subscription x protocol x
# direction) over the physical log records (data/_transfers.tsv). Only legs
# that actually measure a rate count: duration > 500 ms AND size > 1 MB — the
# rate of a tiny or instant leg is dominated by session setup, not the wire.
# MB/s = total bytes moved / total wire time of the route's counted legs.
# Slowest routes first, plus a per-protocol rollup and a first-half vs
# second-half trend per route.
#
# Reads data/_transfers.tsv (2 = direction, 6 = subscription, 9 = size,
# 10 = protocol, 14 = jdn, 15 = duration ms). Writes data/route-throughput.rpt.
#
# Usage:
#   ./route-throughput.sh    # reads input/*.csv (via the cache), writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/route-throughput.rpt"
MIN_DUR=500        # ms — a leg must run longer than this to measure a rate
MIN_SIZE=1048576   # bytes — and move more than this
MIN_HALF=3         # legs per window half needed before a trend is shown

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass: per (subscription, protocol, direction) the leg count, byte and
# wire-time sums — also bucketed per jdn so END can split the observed window
# at its midpoint for the trend column.
agg=$(awk -F'\t' -v mindur="$MIN_DUR" -v minsize="$MIN_SIZE" -v minhalf="$MIN_HALF" '
    function humanbytes(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    function humandur(ms) {
        if (ms < 1000)    return sprintf("%d ms", ms)
        if (ms < 60000)   return sprintf("%.2f s", ms/1000)
        if (ms < 3600000) return sprintf("%.1f min", ms/60000)
        return sprintf("%.2f h", ms/3600000) }
    function rate(bytes, ms) { return (ms > 0) ? (bytes / 1048576) / (ms / 1000) : 0 }
    $15 + 0 <= mindur || $9 + 0 <= minsize { next }
    {
        s = $6; if (s == "") s = "(no subscription)"
        k = s SUBSEP $10 SUBSEP $2
        n[k]++; sz[k] += $9; du[k] += $15
        j = $14 + 0
        jn[k SUBSEP j]++; jsz[k SUBSEP j] += $9; jdu[k SUBSEP j] += $15
        if (minj == 0 || j < minj) minj = j
        if (j > maxj) maxj = j
        pn[$10]++; psz[$10] += $9; pdu[$10] += $15
        tn++; tsz += $9; tdu += $15
    }
    END {
        if (tn == 0) { print "EMPTY"; exit }
        mid = int((minj + maxj) / 2)
        for (k in n) {
            split(k, p, SUBSEP)
            n1 = 0; s1 = 0; d1 = 0; n2 = 0; s2 = 0; d2 = 0
            for (j = minj; j <= maxj; j++) {
                kk = k SUBSEP j
                if (kk in jn) {
                    if (j <= mid) { n1 += jn[kk]; s1 += jsz[kk]; d1 += jdu[kk] }
                    else          { n2 += jn[kk]; s2 += jsz[kk]; d2 += jdu[kk] }
                }
            }
            trend = "-"
            if (n1 >= minhalf && n2 >= minhalf) {
                r1 = rate(s1, d1); r2 = rate(s2, d2)
                arrow = "\342\206\222"                                    # -> steady
                if (r1 > 0 && r2 / r1 >= 1.25) arrow = "\342\206\221"     # up: faster
                else if (r1 > 0 && r2 / r1 <= 0.8) arrow = "\342\206\223" # down: slower
                trend = sprintf("%.2f \342\206\222 %.2f  %s", r1, r2, arrow)
            }
            printf "R\t%012.6f\t%s\t%s\t%s\t%d\t%s\t%s\t%.2f\t%s\n", \
                rate(sz[k], du[k]), p[1], p[2], p[3], n[k], humanbytes(sz[k]), humandur(du[k]), rate(sz[k], du[k]), trend
        }
        for (q in pn)
            printf "P\t%012.6f\t%s\t%d\t%s\t%s\t%.2f\n", \
                rate(psz[q], pdu[q]), q, pn[q], humanbytes(psz[q]), humandur(pdu[q]), rate(psz[q], pdu[q])
        printf "TOT\t%d\t%s\t%s\t%.2f\t%d\t%d\n", tn, humanbytes(tsz), humandur(tdu), rate(tsz, tdu), mid - minj + 1, maxj - mid
    }
' "$PARSED")

if [ "$(printf '%s\n' "$agg" | awk 'NR==1 { print $1 }')" = "EMPTY" ]; then
    {
        printf 'TITLE\tRoute Throughput\n'
        printf 'DESC\tWire speed (MB/s) per subscription x protocol x direction, slowest routes first, with a per-protocol rollup and a first-half vs second-half trend.\n'
        printf 'INTRO\tNo legs above the measurement floors (duration > 500 ms and size > 1 MB) in this dataset.\n'
        printf 'TABLE\tThroughput per route\tnofilter\n'
        printf 'HEAD\tRoute\n'
        printf 'KIND\ttext\n'
        printf 'ROW\tNo measurable legs in this dataset.\n'
        printf 'TOTAL\tTotal (0 rows)\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "No measurable legs found — wrote empty-state $OUT." >&2
    exit 0
fi

IFS=$'\t' read -r _ t_n t_vol t_wire t_rate t_h1 t_h2 <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
n_routes=$(printf '%s\n' "$agg" | grep -c $'^R\t' || true)
n_protos=$(printf '%s\n' "$agg" | grep -c $'^P\t' || true)

# slowest first: the zero-padded fixed-point rate is the ascending text/number
# sort key; subscription, protocol and direction break ties.
route_rows=$(printf '%s\n' "$agg" | grep $'^R\t' | LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k3,3 -k4,4 -k5,5 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $3, $4, $5, $6, $7, $8, $9, $10 }')
proto_rows=$(printf '%s\n' "$agg" | grep $'^P\t' | LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k3,3 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s\t%s\n", $3, $4, $5, $6, $7 }')

{
    printf 'TITLE\tRoute Throughput\n'
    printf 'DESC\tWire speed (MB/s) per subscription x protocol x direction, slowest routes first, with a per-protocol rollup and a first-half vs second-half trend.\n'
    printf 'INTRO\tHow fast the bytes actually move, per **route** (subscription x protocol x direction). Only legs that measure a real rate count: **duration > 500 ms** and **size > 1 MB** — **%s** such Transfers, moving **%s** in **%s** of wire time (**%.2f MB/s** overall). Slowest routes first: a PeSIT route at 0.2 MB/s and an SFTP route at 40 MB/s are both normal, but a route far below its protocol peers is worth a look. The Trend column compares the first half of the observed window with the second.\n' \
        "$t_n" "$t_vol" "$t_wire" "$t_rate"

    printf 'TABLE\tThroughput per route\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tProtocol\tDirection\tTransfers\tVolume\tWire time\tMB/s\tTrend (MB/s)\n'
    printf 'KIND\tsite\ttext\ttext\tnum\tnum\tnum\tnum\tmono\n'
    printf '%s\n' "$route_rows"
    printf 'TOTAL\tTotal (%s route(s))\t\t\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\n' \
        "$n_routes" "$t_n" "$t_vol" "$t_wire" "$t_rate"
    printf 'NOTE\tMB/s = the route'\''s counted bytes divided by its summed leg durations (a volume-weighted rate, so one big slow file outweighs ten quick ones). The **500 ms / 1 MB floors** drop the legs whose measured rate is mostly session setup and rounding. A leg'\''s duration is the log record'\''s own wire time — the store-and-forward dwell BETWEEN legs is never in it (the Store-and-Forward report measures that). Trend: first-half vs second-half MB/s of the window; shown when both halves have at least %s Transfers.\n' "$MIN_HALF"

    printf 'TABLE\tPer protocol\tnofilter\n'
    printf 'HEAD\tProtocol\tTransfers\tVolume\tWire time\tMB/s\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\n'
    printf '%s\n' "$proto_rows"
    printf 'TOTAL\tTotal (%s protocol(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\n' \
        "$n_protos" "$t_n" "$t_vol" "$t_wire" "$t_rate"
    printf 'NOTE\tThe same figures rolled up per protocol — the fair baseline for a route: PeSIT throttles far below SFTP by design. `routing` is the internal store-and-forward leg between the inbound and outbound sides.\n'

    printf 'KEYWORDS\tthroughput, MB/s, bandwidth, speed, slow, wire time, rate, transfer speed, pesit, sftp, ssh, performance\n'
    printf 'SUMMARY\tRoutes: %s  |  Measured Transfers: %s  |  Volume: %s  |  Overall: %s MB/s\n' \
        "$n_routes" "$t_n" "$t_vol" "$t_rate"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($n_routes routes, $t_n measured Transfers, $t_rate MB/s overall)." >&2
