#!/usr/bin/env bash
#
# file-in-file-out.sh — PARTNER-TO-PARTNER handovers carried by TWO
# subscriptions: the same filename is carried by two different flows within the
# window, with OpsWise copying it across in between. BOTH DIRECTIONS since
# 2026-09-19 (user request):
#   in → out   it ARRIVES from one partner, then LEAVES to another
#   out → in   it LEAVES to one partner, then ARRIVES from another
#   (lowercase like every Direction value, 2026-09-30 — "In --> Out" before)
# The two flows are named by their ORDER — First and Second — and the pair's
# Direction says which way round it was; a route is a (First, Second,
# Direction) triple.
#
# The platform has a documented single-subscription form of this (UC5 / UC8
# relays — 1 subscription each today). This report finds the undocumented form,
# which is far bigger: two ordinary subscriptions, nothing in the data linking
# them except the FILENAME. Example:
#
#   in   UC4_APS-COSMOS-TCF_APS-COSMOS-TCF        partner TCF_TCFIRM
#   out  UC1_CD_COSMOS_ROTAFORM_CD_COSMOS_ROTAFORM partner ROTAFORM
#
# DETECTION — one pass over _files.tsv (11=file, 12=subscription, 17=movement,
# 7=jdn, 5=time, 8=size, 20=partner, 4=date), then two sorts:
#   1. keep the named files with a known movement (in / out)
#   2. per FILENAME, pair each file with the next file of the OPPOSITE movement
#      on a DIFFERENT subscription that follows it within WINDOW_H hours
#   3. group the pairs into ROUTES (first flow -> second flow, per direction)
#
# Matching is on the basename ALONE, deliberately:
#   - size is NOT required to match. The biggest route re-encrypts in transit
#     (.afp.pgp, +4-19 KB), so requiring equal size misses it entirely — and
#     misses the DPL-AXINI-AO-IMPRESS example too (81886 -> 81888 bytes).
#     The size behaviour is REPORTED per route instead (Same size column), so a
#     byte-for-byte copy is visible as evidence rather than assumed.
#   - the window is wide (48 h default) because the copy is a scheduled OpsWise
#     batch, not an event: gaps run from 4 minutes to 47 hours. A 1-hour window
#     finds about a sixth of them.
#
# FALSE POSITIVES are possible where a filename is not unique (a fixed daily
# name could pair with an unrelated subscription), so the report shows the
# distinct-filename count per route: a route whose files all carry unique
# (timestamped) names cannot be coincidence. Routes whose two sides resolve to
# the SAME partner group are kept and marked — they are usually a pull-then-
# stage flow rather than a true partner-to-partner handover.
#
# Reads data/transfer/cache/_files.tsv. Writes data/transfer/reports/file-in-file-out.rpt.
#
# Usage:
#   ./file-in-file-out.sh    # reads input/*.csv (via the cache)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/file-in-file-out-src.rpt"   # a component since 2026-09-29: merge-file-in-file-out.sh adds the UC4 to UC2 tab
WINDOW_H=48        # an outbound file counts as the handover of an inbound one within this many hours
LATEST_N=100       # rows in the per-file table

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

TMP=$(mktemp "${TMPDIR:-/tmp}/fifo.XXXXXX")
trap 'rm -f "$TMP" "$TMP.pairs"' EXIT

# ---- 1. the candidate legs, sorted by filename then time ---------------------
# seconds = jdn*86400 + time-of-day, so the ordering is exact across midnight.
awk -F'\t' '
    $11 == "" || $12 == "" || $12 == "Unknown" { next }   # a handover between two SUBSCRIPTIONS: "Unknown" is none (2026-09-29)
    $17 != "in" && $17 != "out" { next }
    {
        split($5, t, ":")
        sec = $7 * 86400 + t[1] * 3600 + t[2] * 60 + int(t[3])
        printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $11, sec, $17, $12, $8, $20, $4, $5, $1
    }' "$FILES" | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2n > "$TMP"

# ---- 2. pair each file with the next one of the OPPOSITE movement -----------
# One filename group at a time, in TWO PASSES (2026-09-19, user request: the
# report lists out -> in handovers too, not only in -> out):
#   pass 1  in -> out, EXACTLY the original rule: each out leg takes the MOST
#           RECENT still-unmatched in leg of a different subscription inside
#           the window, so a repeated filename pairs in order instead of all
#           rows binding to the first;
#   pass 2  out -> in, the same rule mirrored, over the legs pass 1 LEFT OVER.
# Two passes, not one symmetric greedy walk: a single walk lets an in leg
# claim the out leg seconds BEFORE it, which consumes the very in leg the real
# in -> out handover needed — on the sample estate the 3,125-file UC4 -> UC2
# route vanished and its legs re-paired as two out -> in routes. With in -> out
# first, every route the report showed before is byte-for-byte unchanged and
# out -> in only ever pairs what nothing else wanted. A leg belongs to at most
# ONE pair. The FIRST leg's movement rides along as field 15 — the Direction.
# (Rows are time-sorted, so walking back the gap only grows: past the window
# the scan can stop, which keeps a fixed daily filename's big group cheap.)
awk -F'\t' -v W="$((WINDOW_H * 3600))" '
    function emit(i, j) {   # i = the first leg, j = the second
        # route(first,second), gap, first-size, second-size, first-partner,
        # second-partner, file, first-date, first-time, second-date,
        # second-time, first-coreid, second-coreid, FIRST MOVEMENT
        printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
               sub_[i], sub_[j], ts[j] - ts[i], sz[i], sz[j], pt[i], pt[j], f[i], dt[i], tm[i], dt[j], tm[j], cid[i], cid[j], mv[i]
    }
    function pass(first, second,   i, j) {
        for (j = 1; j <= n; j++) {
            if (used[j] || mv[j] != second) continue
            for (i = j - 1; i >= 1; i--) {
                if (ts[j] - ts[i] > W) break
                if (used[i] || mv[i] != first || sub_[i] == sub_[j] || ts[j] <= ts[i]) continue
                used[i] = 1; used[j] = 1; emit(i, j); break
            }
        }
    }
    function flush() { if (n > 0) { pass("in", "out"); pass("out", "in") }; n = 0 }
    ($1 "") != prev { flush(); prev = $1 }   # a STRING compare: mawk compared "0123" and "123" numerically, one group (2026-09-29)
    { n++; f[n]=$1; ts[n]=$2; mv[n]=$3; sub_[n]=$4; sz[n]=$5; pt[n]=$6; dt[n]=$7; tm[n]=$8; cid[n]=$9; used[n]=0 }
    END { flush() }' "$TMP" > "$TMP.pairs"

nh=$(grep -c . "$TMP.pairs" || true)
if [ "${nh:-0}" -eq 0 ]; then
    {
        printf 'TITLE\tFile in - File out\n'
        printf 'TABLE\tHandover routes\ttab=fifo\n'
        printf 'HEAD\tRoute\n'
        printf 'KIND\ttext\n'
        printf 'ROW\tNo partner-to-partner handovers detected.\n'
        printf 'FOOT\n'
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "No handovers found — wrote empty-state $OUT." >&2
    exit 0
fi

# ---- 3. per-route summary ---------------------------------------------------
# Sorted by route then gap, so the MEDIAN is the middle row of each group (no
# in-awk sort: a route can hold 30,000 gaps and an insertion sort would crawl).
# the DIRECTION is part of the route key (2026-09-19): the same two flows can
# in principle hand over both ways, and those are two different routes.
route_rows=$(LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k15,15 -k3,3n "$TMP.pairs" | awk -F'\t' '
    function hd(s) { if (s < 90) return sprintf("%d s", s)
                     if (s < 5400) return sprintf("%.0f min", s/60)
                     if (s < 172800) return sprintf("%.1f h", s/3600)
                     return sprintf("%.1f d", s/86400) }
    function flush(   med, samesz, i) {
        if (n == 0) return
        med = g[int((n + 1) / 2)]
        printf "R\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\n", \
               ink, outk, n, nf, hd(gmin), hd(med), hd(gmax), inp, outp, same, n - same, dirlbl
    }
    { k = $1 SUBSEP $2 SUBSEP $15 }
    k != cur { flush(); cur = k; ink = $1; outk = $2; n = 0; nf = 0; same = 0
               dirlbl = ($15 == "out") ? "out → in" : "in → out"
               delete g; delete fseen; gmin = $3; gmax = $3 }
    {
        n++; g[n] = $3
        if ($3 < gmin) gmin = $3
        if ($3 > gmax) gmax = $3
        if ($4 == $5) same++
        if (!($8 in fseen)) { fseen[$8] = 1; nf++ }
        inp = ($6 == "" ? "-" : $6); outp = ($7 == "" ? "-" : $7)
    }
    END { flush() }')

# ---- 4. the .rpt ------------------------------------------------------------
# route count + how many of them cross partner groups, in one pass
IFS=' ' read -r nroutes ncross <<< "$(printf '%s\n' "$route_rows" | awk -F'\t' '$1=="R"{n++; if ($9 != $10) x++} END{print n+0, x+0}')"

{
    printf 'TITLE\tFile in - File out\n'

    # nofilter: the route figures (files, median gap, size split, first/last)
    # are whole-window aggregates with no per-day buckets behind them, so a
    # narrowed From/To cannot re-compute them — without this the table kept
    # showing "30,202 files" while the page claimed a single day. The per-file
    # table below IS date-aware and filters normally.
    # FIRST / SECOND / DIRECTION (2026-09-19, user request): the two flows are
    # named by their ORDER in the handover, not by a movement — the report
    # carries out -> in routes too now; the partner and size columns follow
    # the same order wording. The route's first / last date columns were
    # DROPPED the same day (user request) — they had been renamed First seen /
    # Last seen to stay apart from the First flow, and went altogether.
    printf 'TABLE\tHandover routes\twide\tnofilter\ttab=fifo\n'
    printf 'HEAD\tFirst\tSecond\tDirection\tFiles\tFilenames\tFirst partner\tSecond partner\tFastest\tMedian\tSlowest\tSame size\tSize changed\n'
    printf 'KIND\tsite\tsite\ttext\tnum\tnum\tptn\tptn\ttext\ttext\ttext\tnum\tnum\n'
    # the sorted rows first, then the TOTAL summed off the same stream as it
    # passes by (the route figures all survive into the ROW line)
    printf '%s\n' "$route_rows" | awk -F'\t' '$1=="R"{
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
               $2,$3,$13,$4,$5,$9,$10,$6,$7,$8,$11,$12 }' | LC_ALL=C sort -t"$(printf '\t')" -k5,5nr \
        | awk -F'\t' '{ print; n++; f+=$5; nf+=$6; s+=$12; c+=$13 }
            END{printf "TOTAL\tTotal (%d route(s))\t\t\t@{class=num}%d\t@{class=num}%d\t\t\t\t\t\t@{class=num}%d\t@{class=num}%d\n", n+0, f+0, nf+0, s+0, c+0}'

    printf 'TABLE\tLatest handovers\twide\ttab=fifo\n'
    printf 'HEAD\tFile\tFirst time\tFirst\tSecond time\tSecond\tDirection\tGap\tSize first\tSize second\n'
    printf 'KIND\tfile\ttext\tsite\ttext\tsite\ttext\ttext\tnum\tnum\n'
    # one sort of the pairs, newest first: the same awk emits the rows and the
    # TOTAL it sums on the way through
    LC_ALL=C sort -t"$(printf '\t')" -k9,9r -k10,10r "$TMP.pairs" | awk -F'\t' -v n="$LATEST_N" '
        function hd(s) { if (s < 90) return sprintf("%d s", s)
                         if (s < 5400) return sprintf("%.0f min", s/60)
                         if (s < 172800) return sprintf("%.1f h", s/3600)
                         return sprintf("%.1f d", s/86400) }
        # sizes read like every other size cell ("16 B", "1.2 MB" — raw
        # bytes until 2026-09-30); report.js parses them back for its totals
        function hsz(v) { if (v >= 1073741824) return sprintf("%.1f GB", v/1073741824)
                          if (v >= 1048576) return sprintf("%.1f MB", v/1048576)
                          if (v >= 1024)    return sprintf("%.1f KB", v/1024)
                          return v " B" }
        NR <= n { printf "ROW\t%s\t%s %s\t%s\t%s %s\t%s\t%s\t%s\t%s\t%s\n", $8, $9, $10, $1, $11, $12, $2, ($15 == "out" ? "out → in" : "in → out"), hd($3), hsz($4 + 0), hsz($5 + 0)
                  c++; a += $4; b += $5 }
        END { printf "TOTAL\tTotal (%d row(s))\t\t\t\t\t\t\t@{class=num}%s\t@{class=num}%s\n", c+0, hsz(a+0), hsz(b+0) }'

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($nroutes route(s), $nh handover(s))." >&2
