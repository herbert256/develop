#!/usr/bin/env bash
#
# size-profile.sh — what a flow's files WEIGH, per subscription, over the
# logical transfers (data/_files.tsv), for every subscription with at least 20
# Files: the overall median size, the median of the flow's FIRST half of files
# vs its SECOND half (chronological, count split — the drift ratio), and the
# stub share: files smaller than max(1 KB, 1% of the flow's median).
#
# Two-regime flows (a data file plus a 0-byte/tiny semaphore companion) are
# legitimate — the stub table shows the MIX and is informational, not an alarm.
#
# Reads data/_files.tsv (6 = sortkey, 7 = jdn, 8 = size, 12 = subscription).
# Writes data/size-profile.rpt.
#
# Usage:
#   ./size-profile.sh    # reads input/*.csv (via the cache), writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/size-profile.rpt"
MIN_FILES=20      # Files needed before a flow gets a size profile
DRIFT_HI=3        # 2nd-half median / 1st-half median at or above -> regime change
STUB_PCT=10       # stub share (percent) at or above -> listed as stub shipper

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass collecting per-subscription (sortkey, size) pairs; END qsorts each
# flow once by time (the fixed-width sortkey makes "sortkey|size" a sortable
# string) and once by size — sort-then-scan medians, never insertion sorts.
agg=$(awk -F'\t' -v minfiles="$MIN_FILES" -v drifthi="$DRIFT_HI" -v stubpct="$STUB_PCT" '
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
    $12 == "" || $7 == "" { next }
    {
        s = $12
        n[s]++
        CH[s SUBSEP n[s]] = sprintf("%s|%015d", $6, $8 + 0)   # time-sortable, size recoverable
        tf++
    }
    END {
        if (tf == 0) { print "EMPTY"; exit }
        for (s in n) {
            m = n[s]
            if (m < minfiles) continue
            prof++
            for (i = 1; i <= m; i++) T[i] = CH[s SUBSEP i]
            qsort(T, 1, m)                               # chronological
            for (i = 1; i <= m; i++) Z[i] = substr(T[i], index(T[i], "|") + 1) + 0
            h = int(m / 2)
            for (i = 1; i <= h; i++)     A[i]     = Z[i]
            for (i = h + 1; i <= m; i++) B[i - h] = Z[i]
            qsort(Z, 1, m); mo = median(Z, m)            # overall median (Z now size-sorted)
            qsort(A, 1, h); m1 = median(A, h)
            qsort(B, 1, m - h); m2 = median(B, m - h)
            # stub share against max(1 KB, 1% of the flow median)
            thr = 1024; if (mo * 0.01 > thr) thr = mo * 0.01
            st = 0
            for (i = 1; i <= m; i++) { if (Z[i] < thr) st++; else break }   # Z is sorted
            share = st * 100 / m
            # drift: ratio of the half medians; a zero first-half median with a
            # real second half (or vice versa) is an extreme regime change
            drift = ""; ext = 0
            if (m1 > 0) {
                r = m2 / m1
                if (r >= drifthi || r <= 1 / drifthi) {
                    if (r >= 1) drift = (r < 100) ? sprintf("%.2f\303\227", r) : sprintf("%d\303\227", r)
                    else {                                   # shrink: keep the sortable ratio, add the inverse factor
                        inv = 1 / r
                        drift = sprintf("%.2f\303\227 (\303\267%s)", r, (inv < 100) ? sprintf("%.1f", inv) : sprintf("%d", inv))
                    }
                    ext = (r >= 1) ? r : inv
                }
            }
            else if (m2 > 0) { drift = "\342\210\236"; ext = 999999 }       # 0 -> real: infinite
            if (drift != "")
                printf "D\t%012.4f\t%s\t%d\t%s\t%s\t%s\t%s\n", \
                    ext, s, m, humanbytes(mo), humanbytes(m1), humanbytes(m2), drift
            if (share >= stubpct)
                printf "S\t%08.3f\t%09d\t%s\t%d\t%d\t%.1f%%\t%s\t%s\n", \
                    share, st, s, m, st, share, humanbytes(int(thr)), humanbytes(mo)
        }
        printf "TOT\t%d\t%d\n", tf, prof+0
    }
' "$FILES")

if [ "$(printf '%s\n' "$agg" | awk 'NR==1 { print $1 }')" = "EMPTY" ]; then
    {
        printf 'TITLE\tSize Profile\n'
        printf 'DESC\tPer-subscription file-size fingerprint: median size, first-half vs second-half drift, and the share of stub (near-empty) files.\n'
        printf 'INTRO\tNo Files in this dataset.\n'
        printf 'TABLE\tSize profile\tnofilter\n'
        printf 'HEAD\tSubscription\n'
        printf 'KIND\ttext\n'
        printf 'ROW\tNo Files in this dataset.\n'
        printf 'TOTAL\tTotal (0 rows)\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "No Files found — wrote empty-state $OUT." >&2
    exit 0
fi

IFS=$'\t' read -r _ t_files t_prof <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"

# regime changes: most extreme drift first; stub shippers: biggest share first
# (then most stubs) — zero-padded sort keys, subscription name as tiebreaker.
d_rows=$(printf '%s\n' "$agg" | { grep $'^D\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k2,2r -k3,3 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\n", $3, $4, $5, $6, $7, $8 }')
s_rows=$(printf '%s\n' "$agg" | { grep $'^S\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k2,2r -k3,3r -k4,4 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\n", $4, $5, $6, $7, $8, $9 }')
d_tot=$(printf '%s\n' "$agg" | { grep $'^D\t' || true; } | awk -F'\t' '{ n++; f += $4 } END { printf "%d\t%d", n+0, f+0 }')
s_tot=$(printf '%s\n' "$agg" | { grep $'^S\t' || true; } | awk -F'\t' '{ n++; f += $5; s += $6 } END { printf "%d\t%d\t%d\t%.1f%%", n+0, f+0, s+0, (f ? s*100/f : 0) }')
IFS=$'\t' read -r d_n d_f <<< "$d_tot"
IFS=$'\t' read -r s_n s_f s_s s_share <<< "$s_tot"

{
    printf 'TITLE\tSize Profile\n'
    printf 'DESC\tPer-subscription file-size fingerprint: median size, first-half vs second-half drift, and the share of stub (near-empty) files.\n'
    printf 'INTRO\tWhat each flow'\''s files weigh, over the **%s** subscriptions with **%s+ Files** (of %s Files total). Two findings: **%s** flows whose typical file size **changed regime** — the median of their first half of files vs their second half (chronological) drifted by **%s\303\227 or more** in either direction — and **%s** flows shipping **stubs**: %s%%+ of their files smaller than max(1 KB, 1%% of the flow'\''s own median).\n' \
        "$t_prof" "$MIN_FILES" "$t_files" "$d_n" "$DRIFT_HI" "$s_n" "$STUB_PCT"

    printf 'TABLE\tSize regime changed\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tFiles\tMedian (all)\tMedian (1st half)\tMedian (2nd half)\tDrift\n'
    printf 'KIND\tsite\tnum\tnum\tnum\tnum\tnum\n'
    if [ -n "$d_rows" ]; then
        printf '%s\n' "$d_rows"
        printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t\t\t\t\n' "$d_n" "$d_f"
    else
        printf 'ROW\t@{colspan=6}No flow'\''s median size drifted by %s\303\227 or more.\n' "$DRIFT_HI"
        printf 'TOTAL\tTotal (0 subscriptions)\t\t\t\t\t\n'
    fi
    printf 'NOTE\tThe halves are the flow'\''s OWN files split by count in chronological order (not calendar halves), so a burst-shaped flow is still compared fairly. Drift = 2nd-half median / 1st-half median; \342\210\236 marks a flow whose first-half median was 0 bytes. A regime change is worth understanding — a new file format, a changed upstream export, or content replaced by placeholders — but is not by itself an error.\n'

    printf 'TABLE\tStub shippers\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tFiles\tStubs\tStub share\tStub limit\tMedian (all)\n'
    printf 'KIND\tsite\tnum\tnum\tnum\tnum\tnum\n'
    if [ -n "$s_rows" ]; then
        printf '%s\n' "$s_rows"
        printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\t\n' "$s_n" "$s_f" "$s_s" "$s_share"
    else
        printf 'ROW\t@{colspan=6}No flow ships %s%%+ stub files.\n' "$STUB_PCT"
        printf 'TOTAL\tTotal (0 subscriptions)\t\t\t\t\t\n'
    fi
    printf 'NOTE\tA **stub** is a file smaller than max(1 KB, 1%% of the flow'\''s median size) — the per-flow limit is in the Stub limit column. **Two-regime flows are often legitimate**: a data file plus a 0-byte semaphore/flag companion produces a steady ~50%% stub share by design. This table shows the mix so an UNEXPECTED stub surge (real content replaced by empties) stands out — it is informational, not an alarm list.\n'

    printf 'KEYWORDS\tsize, stub, empty, zero byte, semaphore, flag file, regime, drift, grew, shrank, median size, small files, placeholder\n'
    printf 'SUMMARY\tProfiled flows: %s  |  Regime changes: %s  |  Stub shippers: %s\n' \
        "$t_prof" "$d_n" "$s_n"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($t_prof profiled, $d_n regime changes, $s_n stub shippers)." >&2
