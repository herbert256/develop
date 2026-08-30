#!/usr/bin/env bash
#
# expected-arrival.sh — per-subscription arrival-CADENCE model over the logical
# transfers (data/_files.tsv). For every subscription with at least 5 distinct
# active days: the median and p90 gap between consecutive active days, how many
# days it has now been silent (against the newest day in the whole cache), and
# a verdict — OVERDUE when the silence exceeds the flow's OWN rhythm
# (max(p90+1, median+2) days). Also detects weekday-locked flows (>= 75% of
# active days on one weekday) and long-period flows (median gap >= 20 days).
#
# This is deliberately different from went-quiet.sh (a FIXED 7-day cutoff for
# everybody) and punctuality.sh (a time-of-DAY model): here each flow is judged
# against its own day-to-day interval history.
#
# Reads data/_files.tsv (4 = date_iso, 7 = jdn, 12 = subscription). Writes
# data/expected-arrival.rpt.
#
# Usage:
#   ./expected-arrival.sh    # reads input/*.csv (via the cache), writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/expected-arrival.rpt"
MIN_DAYS=5      # a flow needs this many distinct active days to be modelable
LOCK_PCT=75     # weekday-locked: >= this share of active days on one weekday
LONG_MED=20     # long-period flag: median gap >= this many days

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over _files.tsv: per subscription the distinct active days (jdn),
# the Files count, then in END the sorted gap list -> median/p90, the silence
# vs the cache-wide newest day, and the weekday histogram.
agg=$(awk -F'\t' -v mindays="$MIN_DAYS" -v lockpct="$LOCK_PCT" -v longmed="$LONG_MED" '
    function qsort(A, lo, hi,   i, j, p, t) {
        while (lo < hi) { i = lo; j = hi; p = A[int((lo + hi) / 2)]
            while (i <= j) { while (A[i] < p) i++; while (A[j] > p) j--
                if (i <= j) { t = A[i]; A[i] = A[j]; A[j] = t; i++; j-- } }
            if (j - lo < hi - i) { if (lo < j) qsort(A, lo, j); lo = i }
            else                 { if (i < hi) qsort(A, i, hi); hi = j } } }
    function pctl(A, n, P) { return A[int((n - 1) * P / 100 + 0.5) + 1] }   # nearest rank
    function jdn2iso(j,   a, b, c, d, e, m, dy, mo, yr) {
        a = j + 32044; b = int((4*a + 3) / 146097); c = a - int(146097*b / 4)
        d = int((4*c + 3) / 1461); e = c - int(1461*d / 4); m = int((5*e + 2) / 153)
        dy = e - int((153*m + 2) / 5) + 1; mo = m + 3 - 12*int(m/10); yr = 100*b + d - 4800 + int(m/10)
        return sprintf("%04d-%02d-%02d", yr, mo, dy) }
    BEGIN { split("Monday Tuesday Wednesday Thursday Friday Saturday Sunday", WN, " ") }
    $12 == "" || $7 == "" { next }
    {
        s = $12; j = $7 + 0
        nf[s]++
        if (!((s SUBSEP j) in seen)) { seen[s SUBSEP j] = 1; nd[s]++; DJ[s SUBSEP nd[s]] = j }
        if (j > maxj) maxj = j
    }
    END {
        for (s in nd) {
            n = nd[s]
            if (n < mindays) { few++; continue }
            for (i = 1; i <= n; i++) A[i] = DJ[s SUBSEP i]
            qsort(A, 1, n)
            for (i = 2; i <= n; i++) G[i-1] = A[i] - A[i-1]
            ng = n - 1; qsort(G, 1, ng)
            med = pctl(G, ng, 50); p90 = pctl(G, ng, 90)
            lastj = A[n]; sil = maxj - lastj
            lim = p90 + 1; if (med + 2 > lim) lim = med + 2
            tot++
            flag = (med >= longmed) ? "long-period" : "on rhythm"
            if (sil > lim) {
                nod++
                printf "OD\t%08d\t%s\t%d\t%d\t%d\t%d\t%s\t%d\tOVERDUE (limit %d d)\n", \
                    99999999 - sil, s, nf[s], n, med, p90, jdn2iso(lastj), sil, lim
            } else {
                nok++
                printf "OK\t%08d\t%s\t%d\t%d\t%d\t%d\t%s\t%d\t%s (limit %d d)\n", \
                    99999999 - sil, s, nf[s], n, med, p90, jdn2iso(lastj), sil, flag, lim
            }
            # weekday-locked: the busiest weekday holds >= lockpct% of active days
            delete W
            for (i = 1; i <= n; i++) W[A[i] % 7]++
            best = 0; bw = 0
            for (w = 0; w <= 6; w++) if (W[w] + 0 > best) { best = W[w] + 0; bw = w }
            if (best * 100 / n >= lockpct) {
                nwl++
                d1 = lastj + 1; nx = d1 + ((bw - d1 % 7 + 7) % 7)   # first locked weekday AFTER the last arrival
                miss = (nx <= maxj) ? " (missed)" : ""
                printf "WL\t%08d\t%s\t%s\t%.0f%%\t%d\t%s\t%s%s\n", \
                    100000000 - best * 100 / n, s, WN[bw+1], best * 100 / n, n, jdn2iso(lastj), jdn2iso(nx), miss
            }
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%s\n", tot+0, nod+0, nok+0, nwl+0, few+0, jdn2iso(maxj)
    }
' "$FILES")

IFS=$'\t' read -r _ n_model n_od n_ok n_wl n_few maxdate <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"

# rows, sorted: overdue and on-rhythm by days-silent DESC (the inverted-silence
# sort key makes that an ascending text sort), weekday-locked by share DESC —
# each with the subscription name as the explicit tiebreaker.
od_rows=$(printf '%s\n' "$agg" | { grep $'^OD\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k3,3 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s d\t%s d\t%s\t%s d\t%s\t@data:res=red\n", $3, $4, $5, $6, $7, $8, $9, $10 }')
ok_rows=$(printf '%s\n' "$agg" | { grep $'^OK\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k3,3 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s d\t%s d\t%s\t%s d\t%s\n", $3, $4, $5, $6, $7, $8, $9, $10 }')
wl_rows=$(printf '%s\n' "$agg" | { grep $'^WL\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k3,3 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\n", $3, $4, $5, $6, $7, $8 }')

# per-table TOTAL sums (Files + Active days are additive; the model columns are not)
od_tot=$(printf '%s\n' "$agg" | { grep $'^OD\t' || true; } | awk -F'\t' '{ n++; f += $4; d += $5 } END { printf "%d\t%d\t%d", n+0, f+0, d+0 }')
ok_tot=$(printf '%s\n' "$agg" | { grep $'^OK\t' || true; } | awk -F'\t' '{ n++; f += $4; d += $5 } END { printf "%d\t%d\t%d", n+0, f+0, d+0 }')
wl_tot=$(printf '%s\n' "$agg" | { grep $'^WL\t' || true; } | awk -F'\t' '{ n++; d += $6 } END { printf "%d\t%d", n+0, d+0 }')
IFS=$'\t' read -r od_n od_f od_d <<< "$od_tot"
IFS=$'\t' read -r ok_n ok_f ok_d <<< "$ok_tot"
IFS=$'\t' read -r wl_n wl_d <<< "$wl_tot"

{
    printf 'TITLE\tExpected Arrival\n'
    printf 'DESC\tEach subscription judged against its OWN arrival rhythm: median and p90 gap between active days, current silence, and an OVERDUE verdict when the silence breaks the pattern — plus weekday-locked and long-period flows.\n'
    printf 'INTRO\tA cadence model per subscription, built from the gaps between its **active days** (days with at least one File). Of the **%s** modelable flows (**%s+ active days**), **%s** are **OVERDUE by their own rhythm**: silent longer than max(p90 gap + 1, median gap + 2) days, measured against the newest day in the data (**%s**). Unlike **Went quiet** (one fixed 7-day cutoff for every flow) and **Punctuality** (a time-of-day model for daily flows), this page compares each flow to its own day-to-day interval history — a weekly flow is not "quiet" after 5 days, and a twice-daily flow is overdue long before day 7. %s flow(s) with fewer than %s active days are not modelable and are left out.\n' \
        "$n_model" "$MIN_DAYS" "$n_od" "$maxdate" "$n_few" "$MIN_DAYS"

    printf 'TABLE\tOverdue by their own rhythm\twide\tnofilter\trestint\n'
    printf 'HEAD\tSubscription\tFiles\tActive days\tMedian gap\tp90 gap\tLast seen\tDays silent\tVerdict\n'
    printf 'KIND\tsite\tnum\tnum\tnum\tnum\ttext\tnum\ttext\n'
    if [ -n "$od_rows" ]; then
        printf '%s\n' "$od_rows"
        printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num}%s\t\t\t\t\t\n' "$od_n" "$od_f" "$od_d"
    else
        printf 'ROW\t@{colspan=8}No subscription is overdue by its own rhythm.\n'
        printf 'TOTAL\tTotal (0 subscriptions)\t\t\t\t\t\t\t\n'
    fi
    printf 'NOTE\tA flow is **OVERDUE** when its current silence exceeds **max(p90 gap + 1, median gap + 2)** days — a margin above its own historical worst-normal interval. The gaps are between consecutive ACTIVE days, so a flow that sends 40 files every Monday still has a 7-day gap pattern.\n'

    printf 'TABLE\tOn rhythm\twide\tnofilter\tpager=25\n'
    printf 'HEAD\tSubscription\tFiles\tActive days\tMedian gap\tp90 gap\tLast seen\tDays silent\tVerdict\n'
    printf 'KIND\tsite\tnum\tnum\tnum\tnum\ttext\tnum\ttext\n'
    if [ -n "$ok_rows" ]; then
        printf '%s\n' "$ok_rows"
        printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num}%s\t\t\t\t\t\n' "$ok_n" "$ok_f" "$ok_d"
    else
        printf 'ROW\t@{colspan=8}No modelable subscriptions in this dataset.\n'
        printf 'TOTAL\tTotal (0 subscriptions)\t\t\t\t\t\t\t\n'
    fi
    printf 'NOTE\tEvery modelable flow whose silence is still within its own limit, most-silent first — the top rows are the ones closest to going overdue. **long-period** marks a flow whose median gap is %s days or more (monthly-style cadence): one skipped period takes weeks to detect, by design.\n' "$LONG_MED"

    printf 'TABLE\tWeekday-locked flows\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tWeekday\tShare\tActive days\tLast seen\tNext expected\n'
    printf 'KIND\tsite\ttext\tnum\tnum\ttext\ttext\n'
    if [ -n "$wl_rows" ]; then
        printf '%s\n' "$wl_rows"
        printf 'TOTAL\tTotal (%s subscription(s))\t\t\t@{class=num}%s\t\t\n' "$wl_n" "$wl_d"
    else
        printf 'ROW\t@{colspan=6}No weekday-locked flows detected.\n'
        printf 'TOTAL\tTotal (0 subscriptions)\t\t\t\t\t\n'
    fi
    printf 'NOTE\tFlows where at least %s%% of the active days fall on ONE weekday — a weekly batch with a fixed slot. "Next expected" is the first such weekday after the last arrival; **(missed)** means that day already lies inside the observed window and nothing arrived.\n' "$LOCK_PCT"

    printf 'KEYWORDS\toverdue, cadence, rhythm, expected, arrival, interval, gap, silent, missing, late, weekday, weekly, schedule, pattern\n'
    printf 'SUMMARY\tModelable: %s  |  Overdue: %s  |  On rhythm: %s  |  Weekday-locked: %s\n' \
        "$n_model" "$n_od" "$n_ok" "$n_wl"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($n_model modelable, $n_od overdue, $n_wl weekday-locked)." >&2
