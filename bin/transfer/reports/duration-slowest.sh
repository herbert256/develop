#!/usr/bin/env bash
#
# duration-slowest.sh — "Slowest subscriptions": the top 25 subscriptions by
# p95 WALL-CLOCK duration of their Files (data/_files.tsv col 9, dur_ms; col
# 12 the subscription), split out of duration.sh 2026-09-05 (user request)
# into its own Performance-group page — the third split-off after the
# longest Files and the distribution (2026-09-03).
#
# TWO tables in ONE switch group on the page (the TABLE switch= modifier):
#   OK transfers   Processed Files only (the default) — Error transfers are
#                  mostly instant 0-byte attempts and would drag every
#                  percentile down
#   All transfers  every outcome with a measured duration, so a failed
#                  transfer's run time (a 2 h timeout) counts too
# Each row carries @data:buckets (date:count:sum:max) so the From/To filter
# re-aggregates Files (sum) and Max (max) over the selected range; Median
# and p95 stay at their full-period value (RECALC "-").
#
# Usage:
#   ./duration-slowest.sh   # -> data/<env>/transfer/reports/duration-slowest.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/duration-slowest.rpt"
TOP_SUB=25   # subscriptions shown

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# slowest OKONLY — the per-subscription rows, p95-descending and capped:
# "ROW ⇥ subscription ⇥ Files ⇥ Median ⇥ p95 ⇥ Max ⇥ @data:buckets", then a
# "N ⇥ subscriptions ⇥ Files" line with the scope totals. The spellings are
# humandur() — the site-wide one report.js humanDur matches.
slowest() {
    awk -F'\t' -v okonly="$1" -v top="$TOP_SUB" '
        function humandur(ms) {
            if (ms < 1000)    return sprintf("%d ms", ms)
            if (ms < 60000)   return sprintf("%.2f s", ms/1000)
            if (ms < 3600000) return sprintf("%.1f min", ms/60000)
            return sprintf("%.2f h", ms/3600000)
        }
        function qsort(A, lo, hi,   i, j, p, t) {
            while (lo < hi) {
                i = lo; j = hi; p = A[int((lo + hi) / 2)]
                while (i <= j) {
                    while (A[i] < p) i++
                    while (A[j] > p) j--
                    if (i <= j) { t = A[i]; A[i] = A[j]; A[j] = t; i++; j-- }
                }
                if (j - lo < hi - i) { if (lo < j) qsort(A, lo, j); lo = i }
                else                 { if (i < hi) qsort(A, i, hi); hi = j }
            }
        }
        function pctl(P) { return T[int((TN - 1) * P / 100 + 0.5) + 1] }
        okonly && ($2 == "Failed" || $2 == "Expired") { next }
        {
            d = substr($4, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
            ms = $9 + 0; if (ms <= 0) next
            GN++
            if (!(d in dseen)) { dseen[d] = 1; days[++nd] = d }
            s = $12; if (s == "") s = "(no subscription)"
            if (!(s in scnt)) subs[++ns] = s
            scnt[s]++; if (ms > smax[s]) smax[s] = ms
            SV[s SUBSEP scnt[s]] = ms
            sc[s SUBSEP d]++; sd[s SUBSEP d] += ms; if (ms > sm[s SUBSEP d]) sm[s SUBSEP d] = ms
        }
        END {
            # the dates sorted (never hash order) so the buckets are deterministic
            for (i = 2; i <= nd; i++) { v = days[i]; j = i - 1; while (j >= 1 && days[j] > v) { days[j+1] = days[j]; j-- } days[j+1] = v }
            for (k = 1; k <= ns; k++) {
                s = subs[k]; n = scnt[s]
                for (i = 1; i <= n; i++) T[i] = SV[s SUBSEP i]; TN = n; qsort(T, 1, n)
                p50[s] = pctl(50); p95[s] = pctl(95)
                # sort key: p95 descending, then Files descending, then the name
                K[k] = sprintf("%012d|%012d|%s", 999999999999 - p95[s], 999999999999 - n, s)
            }
            qsort(K, 1, ns)
            for (k = 1; k <= ns && k <= top; k++) {
                s = substr(K[k], index(K[k], "|") + 1); s = substr(s, index(s, "|") + 1)
                bs = ""; for (i = 1; i <= nd; i++) { d = days[i]; c = sc[s SUBSEP d] + 0
                    if (c > 0) bs = bs (bs ? "," : "") d ":" c ":" sd[s SUBSEP d] ":" sm[s SUBSEP d] }
                printf "ROW\t%s\t%d\t%s\t%s\t%s\t@data:buckets=%s\n", s, scnt[s], humandur(p50[s]), humandur(p95[s]), humandur(smax[s]), bs
            }
            printf "N\t%d\t%d\n", ns + 0, GN + 0
        }
    ' "$FILES"
}
out_ok=$(slowest 1); out_all=$(slowest 0)
read -r ns_ok n_ok  <<<"$(printf '%s\n' "$out_ok"  | awk -F'\t' '$1 == "N" { print $2, $3 }')"
read -r ns_all n_all <<<"$(printf '%s\n' "$out_all" | awk -F'\t' '$1 == "N" { print $2, $3 }')"
shown_ok=$(( ${ns_ok:-0} < TOP_SUB ? ${ns_ok:-0} : TOP_SUB )); shown_all=$(( ${ns_all:-0} < TOP_SUB ? ${ns_all:-0} : TOP_SUB ))
GENDATE=$(date '+%Y-%m-%d %H:%M:%S')
{
    printf 'TITLE\tSlowest subscriptions\n'
    printf 'DESC\tThe %s subscriptions whose Files take longest — ranked by the p95 wall-clock duration, with the Files count, median and maximum — for delivered (OK) Files or every outcome.\n' "$TOP_SUB"
    printf 'INTRO\tThe **%s slowest subscriptions** by the **p95** of their Files'"'"' **wall-clock duration** — from the first record start to the last record end, store-and-forward gaps and retry idle included; p95 rather than the maximum, so one freak transfer does not crown a flow. **OK transfers** (the default) ranks delivered Files only; **All transfers** adds the failed ones, whose duration is how long they ran before giving up. A From/To range re-aggregates **Files** and **Max**; **Median** and **p95** keep their full-period value. Click a subscription for its detail page.\n' "$TOP_SUB"
    printf 'TABLE\tSlowest subscriptions (top %s by p95 duration)\twide\tswitch=scope:OK transfers\n' "$TOP_SUB"
    printf 'HEAD\tSubscription\tFiles\tMedian\tp95\tMax\n'
    printf 'KIND\tsite\tnum\tnum\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t-\t-\tx2\n'
    printf '%s\n' "$out_ok" | command grep $'^ROW\t' || true
    printf 'TOTAL\tTop %s of %s subscriptions\t@{class=num}%s\t\t\t\n' "$shown_ok" "${ns_ok:-0}" "${n_ok:-0}"
    printf 'TABLE\t\twide\tswitch=scope:All transfers\n'
    printf 'HEAD\tSubscription\tFiles\tMedian\tp95\tMax\n'
    printf 'KIND\tsite\tnum\tnum\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t-\t-\tx2\n'
    printf '%s\n' "$out_all" | command grep $'^ROW\t' || true
    printf 'TOTAL\tTop %s of %s subscriptions\t@{class=num}%s\t\t\t\n' "$shown_all" "${ns_all:-0}" "${n_all:-0}"
    printf 'NOTE\tOne "File" = one logical transfer (all records sharing a CoreId); duration = its **wall-clock span** — from the first record start to the last record end, in milliseconds, gaps included — not the sum of the record durations. The per-day statistics are on the Duration page, the individual slowest transfers on the Longest Files page.\n'
    printf 'KEYWORDS\tduration,slowest,subscriptions,p95,percentile,median,wall-clock,top 25\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$GENDATE" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${ns_ok:-0} subscriptions with OK Files, ${ns_all:-0} in all)." >&2
