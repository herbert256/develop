#!/usr/bin/env bash
#
# duration-trend.sh — is a flow getting SLOWER (or faster) over time? The
# delivered (Processed) logical transfers from data/_files.tsv, split at the
# midpoint of the observed window (by Julian day): per subscription with at
# least 15 delivered Files in EACH half, the median duration per half and the
# ratio between them. The average file size per half is shown beside it, so a
# "slowdown" that is really just bigger files is visible at a glance.
#
# Medians are computed sort-then-scan (collect every value, one qsort per
# subscription in END) — NEVER per-row insertion into a sorted list, which is
# O(n^2) and measured over 120 s on this dataset.
#
# Reads data/_files.tsv (2 = outcome, 7 = jdn, 8 = size, 9 = dur_ms,
# 12 = subscription). Writes data/duration-trend.rpt.
#
# Usage:
#   ./duration-trend.sh    # reads input/*.csv (via the cache), writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/duration-trend.rpt"
MIN_HALF=15    # delivered Files needed in EACH half before a flow is compared
SLOW_R="1.3"   # second-half median / first-half median at or above -> slower
FAST_R="0.7"   # ... at or below -> faster

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass collecting per-subscription duration/size/jdn triples; END finds the
# window midpoint, splits each flow's values, qsorts each half once (sort-then-
# scan medians) and emits the flows whose ratio crosses a threshold.
agg=$(awk -F'\t' -v minhalf="$MIN_HALF" -v slowr="$SLOW_R" -v fastr="$FAST_R" '
    function humandur(ms) {
        if (ms < 1000)    return sprintf("%d ms", ms)
        if (ms < 60000)   return sprintf("%.2f s", ms/1000)
        if (ms < 3600000) return sprintf("%.1f min", ms/60000)
        return sprintf("%.2f h", ms/3600000) }
    function humanbytes(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    function qsort(A, lo, hi,   i, j, p, t) {
        while (lo < hi) { i = lo; j = hi; p = A[int((lo + hi) / 2)]
            while (i <= j) { while (A[i] < p) i++; while (A[j] > p) j--
                if (i <= j) { t = A[i]; A[i] = A[j]; A[j] = t; i++; j-- } }
            if (j - lo < hi - i) { if (lo < j) qsort(A, lo, j); lo = i }
            else                 { if (i < hi) qsort(A, i, hi); hi = j } } }
    function median(A, n) { return A[int((n - 1) * 50 / 100 + 0.5) + 1] }   # nearest rank
    function jdn2iso(j,   a, b, c, d, e, m, dy, mo, yr) {
        a = j + 32044; b = int((4*a + 3) / 146097); c = a - int(146097*b / 4)
        d = int((4*c + 3) / 1461); e = c - int(1461*d / 4); m = int((5*e + 2) / 153)
        dy = e - int((153*m + 2) / 5) + 1; mo = m + 3 - 12*int(m/10); yr = 100*b + d - 4800 + int(m/10)
        return sprintf("%04d-%02d-%02d", yr, mo, dy) }
    $2 != "Processed" { next }
    $12 == "" || $7 == "" || $9 + 0 <= 0 { next }
    {
        s = $12; j = $7 + 0
        nv[s]++; VJ[s SUBSEP nv[s]] = j; VD[s SUBSEP nv[s]] = $9 + 0; VS[s SUBSEP nv[s]] = $8 + 0
        if (minj == 0 || j < minj) minj = j
        if (j > maxj) maxj = j
        tf++
    }
    END {
        if (tf == 0) { print "EMPTY"; exit }
        mid = int((minj + maxj) / 2)
        for (s in nv) {
            n = nv[s]; n1 = 0; n2 = 0; z1 = 0; z2 = 0
            for (i = 1; i <= n; i++) {
                if (VJ[s SUBSEP i] <= mid) { A[++n1] = VD[s SUBSEP i]; z1 += VS[s SUBSEP i] }
                else                       { B[++n2] = VD[s SUBSEP i]; z2 += VS[s SUBSEP i] }
            }
            if (n1 < minhalf || n2 < minhalf) continue
            cand++
            qsort(A, 1, n1); qsort(B, 1, n2)
            m1 = median(A, n1); m2 = median(B, n2)
            if (m1 <= 0) continue
            r = m2 / m1
            if (r >= slowr || r <= fastr) {
                tag = (r >= slowr) ? "SL" : "FA"
                printf "%s\t%012.6f\t%s\t%s\t%s\t%.2f\t%s\t%s\t%d\t%d\n", \
                    tag, r, s, humandur(m1), humandur(m2), r, \
                    humanbytes(int(z1 / n1)), humanbytes(int(z2 / n2)), n1, n2
            }
        }
        printf "TOT\t%d\t%d\t%s\t%s\t%s\n", tf, cand+0, jdn2iso(minj), jdn2iso(mid), jdn2iso(maxj)
    }
' "$FILES")

if [ "$(printf '%s\n' "$agg" | awk 'NR==1 { print $1 }')" = "EMPTY" ]; then
    {
        printf 'TITLE\tDuration Trend\n'
        printf 'DESC\tFlows whose median transfer duration changed between the first and second half of the data window — slower and faster movers, with the average file size beside them.\n'
        printf 'INTRO\tNo delivered Files with a measured duration in this dataset.\n'
        printf 'TABLE\tDuration trend\tnofilter\n'
        printf 'HEAD\tSubscription\n'
        printf 'KIND\ttext\n'
        printf 'ROW\tNo delivered Files with a measured duration in this dataset.\n'
        printf 'TOTAL\tTotal (0 rows)\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "No delivered Files with a duration — wrote empty-state $OUT." >&2
    exit 0
fi

IFS=$'\t' read -r _ t_files t_cand w_start w_mid w_end <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"

# slower: biggest ratio first; faster: smallest ratio first — the zero-padded
# fixed-point ratio is the sort key, the subscription name the tiebreaker.
sl_rows=$(printf '%s\n' "$agg" | { grep $'^SL\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k2,2r -k3,3 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s\303\227\t%s\t%s\t%s / %s\n", $3, $4, $5, $6, $7, $8, $9, $10 }')
fa_rows=$(printf '%s\n' "$agg" | { grep $'^FA\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k3,3 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s\303\227\t%s\t%s\t%s / %s\n", $3, $4, $5, $6, $7, $8, $9, $10 }')
sl_tot=$(printf '%s\n' "$agg" | { grep $'^SL\t' || true; } | awk -F'\t' '{ n++; a += $9; b += $10 } END { printf "%d\t%d\t%d", n+0, a+0, b+0 }')
fa_tot=$(printf '%s\n' "$agg" | { grep $'^FA\t' || true; } | awk -F'\t' '{ n++; a += $9; b += $10 } END { printf "%d\t%d\t%d", n+0, a+0, b+0 }')
IFS=$'\t' read -r sl_n sl_a sl_b <<< "$sl_tot"
IFS=$'\t' read -r fa_n fa_a fa_b <<< "$fa_tot"

{
    printf 'TITLE\tDuration Trend\n'
    printf 'DESC\tFlows whose median transfer duration changed between the first and second half of the data window — slower and faster movers, with the average file size beside them.\n'
    printf 'INTRO\tThe **%s** delivered (OK) Files with a measured duration, window **%s → %s**, split at **%s**. Per subscription with **%s+ delivered Files in each half**: the median duration per half and the ratio between them. **%s** of the **%s** comparable flows moved: **%s got slower** (ratio ≥ %s×) and **%s got faster** (ratio ≤ %s×). The average file size per half sits beside the medians — when the size grew with the duration, the flow is not degrading, the files are just bigger.\n' \
        "$t_files" "$w_start" "$w_end" "$w_mid" "$MIN_HALF" "$(( sl_n + fa_n ))" "$t_cand" "$sl_n" "$SLOW_R" "$fa_n" "$FAST_R"

    printf 'TABLE\tSlower than they were\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tMedian (1st half)\tMedian (2nd half)\tRatio\tAvg size (1st)\tAvg size (2nd)\tFiles (1st / 2nd)\n'
    printf 'KIND\tsite\tnum\tnum\tnum\tnum\tnum\tmono\n'
    if [ -n "$sl_rows" ]; then
        printf '%s\n' "$sl_rows"
        printf 'TOTAL\tTotal (%s subscription(s))\t\t\t\t\t\t@{class=num}%s / %s\n' "$sl_n" "$sl_a" "$sl_b"
    else
        printf 'ROW\t@{colspan=7}No flow got slower by %s\303\227 or more.\n' "$SLOW_R"
        printf 'TOTAL\tTotal (0 subscriptions)\t\t\t\t\t\t\n'
    fi
    printf 'NOTE\tBiggest slowdown first. Read the size columns before alarming: a ratio of 2\303\227 with the average size also doubling is load growth, not degradation — a slowdown at UNCHANGED size is the interesting row.\n'

    printf 'TABLE\tFaster than they were\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tMedian (1st half)\tMedian (2nd half)\tRatio\tAvg size (1st)\tAvg size (2nd)\tFiles (1st / 2nd)\n'
    printf 'KIND\tsite\tnum\tnum\tnum\tnum\tnum\tmono\n'
    if [ -n "$fa_rows" ]; then
        printf '%s\n' "$fa_rows"
        printf 'TOTAL\tTotal (%s subscription(s))\t\t\t\t\t\t@{class=num}%s / %s\n' "$fa_n" "$fa_a" "$fa_b"
    else
        printf 'ROW\t@{colspan=7}No flow got faster by %s\303\227 or less.\n' "$FAST_R"
        printf 'TOTAL\tTotal (0 subscriptions)\t\t\t\t\t\t\n'
    fi
    printf 'NOTE\tBiggest speed-up first — usually good news (a fixed route, smaller files, an off-peak reschedule), but a sudden drop can also mean the flow now ships stubs instead of real content: check the size columns and the Size profile report.\n'

    printf 'NOTE\tOnly **delivered (Processed)** Files count — a failed transfer'\''s run time is a timeout artefact, not a trend. Duration is the File'\''s wall-clock span (first record start to last record end, store-and-forward gap included). Medians use the nearest-rank method over each half; flows without %s Files in both halves are not compared.\n' "$MIN_HALF"
    printf 'KEYWORDS\tslower, faster, trend, degradation, regression, duration, median, speed, performance, over time, drift\n'
    printf 'SUMMARY\tComparable flows: %s  |  Slower: %s  |  Faster: %s  |  Window: %s → %s\n' \
        "$t_cand" "$sl_n" "$fa_n" "$w_start" "$w_end"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($t_cand comparable, $sl_n slower, $fa_n faster)." >&2
