#!/usr/bin/env bash
#
# duration-distribution.sh — "Duration distribution": how many Files fall in
# each WALL-CLOCK duration band (data/_files.tsv col 9, dur_ms), split out of
# duration.sh 2026-09-03 (user request) into its own Performance-group page.
#
# TWO tables in ONE switch group on the page (the TABLE switch= modifier):
#   OK transfers   Processed Files only (the default) — Error transfers are
#                  mostly instant 0-byte attempts and would pile up in the
#                  first band
#   All transfers  every outcome with a measured duration
# Each row carries @data:buckets (date:count) so the From/To filter
# re-aggregates the counts and shares over the selected range.
#
# Usage:
#   ./duration-distribution.sh   # -> data/<env>/transfer/reports/duration-distribution.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/duration-distribution.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# bands OKONLY — one ROW per band (label ⇥ Files ⇥ Share ⇥ @data:buckets), then
# a "N" line with the scope total (the bash reader splits them apart)
bands() {
    awk -F'\t' -v okonly="$1" '
        function bkt(ms) {
            if (ms <=     100) return 0
            if (ms <=    1000) return 1
            if (ms <=   10000) return 2
            if (ms <=   60000) return 3
            if (ms <=  300000) return 4
            if (ms <= 1800000) return 5
            return 6
        }
        okonly && ($2 == "Failed" || $2 == "Expired") { next }
        {
            d = substr($4, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
            ms = $9 + 0; if (ms <= 0) next
            GN++; b = bkt(ms); bkc[b]++
            if (!((b SUBSEP d) in bkd)) { bkd[b SUBSEP d] = 0; if (!(d in dseen)) { dseen[d] = 1; days[++nd] = d } }
            bkd[b SUBSEP d]++
        }
        END {
            # the dates sorted (never hash order) so the buckets are deterministic
            for (i = 2; i <= nd; i++) { v = days[i]; j = i - 1; while (j >= 1 && days[j] > v) { days[j+1] = days[j]; j-- } days[j+1] = v }
            split("<= 100 ms|100 ms - 1 s|1 s - 10 s|10 s - 1 min|1 - 5 min|5 - 30 min|> 30 min", BL, "|")
            for (b = 0; b <= 6; b++) {
                bs = ""; for (i = 1; i <= nd; i++) { d = days[i]; c = ((b SUBSEP d) in bkd) ? bkd[b SUBSEP d] : 0; if (c > 0) bs = bs (bs ? "," : "") d ":" c }
                printf "ROW\t%s\t%d\t%.1f%%\t@data:buckets=%s\n", BL[b+1], bkc[b] + 0, (GN > 0 ? 100 * bkc[b] / GN : 0), bs
            }
            printf "N\t%d\n", GN + 0
        }
    ' "$FILES"
}
out_ok=$(bands 1); out_all=$(bands 0)
n_ok=$(printf '%s\n' "$out_ok" | awk -F'\t' '$1 == "N" { print $2 }'); n_all=$(printf '%s\n' "$out_all" | awk -F'\t' '$1 == "N" { print $2 }')
GENDATE=$(date '+%Y-%m-%d %H:%M:%S')
{
    printf 'TITLE\tDuration distribution\n'
    printf 'DESC\tHow many Files fall in each wall-clock duration band — up to 100 ms, 1 s, 10 s, 1 min, 5 min, 30 min and beyond — for delivered (OK) Files or every outcome.\n'
    printf 'INTRO\tA histogram of the Files by **wall-clock duration** — from the first record start to the last record end, store-and-forward gaps and retry idle included — in seven bands. **OK transfers** (the default) counts delivered Files only; **All transfers** adds the failed ones, whose duration is how long they ran before giving up. The **Share** column is each band'\''s part of the scope'\''s Files; a From/To range re-aggregates both.\n'
    printf 'TABLE\tDuration distribution\twide\tswitch=scope:OK transfers\n'
    printf 'HEAD\tDuration bucket\tFiles\tShare\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t%%0\n'
    printf '%s\n' "$out_ok" | command grep $'^ROW\t'
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}100.0%%\n' "${n_ok:-0}"
    printf 'TABLE\t\twide\tswitch=scope:All transfers\n'
    printf 'HEAD\tDuration bucket\tFiles\tShare\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t%%0\n'
    printf '%s\n' "$out_all" | command grep $'^ROW\t'
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}100.0%%\n' "${n_all:-0}"
    printf 'NOTE\tOne "File" = one logical transfer (all records sharing a CoreId). Error transfers are mostly instant 0-byte attempts, which is why the OK view is the default — in the All view they pile up in the first band. The per-day figures and percentiles are on the Duration page, the individual longest Files on the Longest Files page.\n'
    printf 'KEYWORDS\tduration,distribution,histogram,bands,buckets,seconds,minutes,wall-clock\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$GENDATE" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${n_ok:-0} OK Files, ${n_all:-0} in all)." >&2
