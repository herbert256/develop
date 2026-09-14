#!/usr/bin/env bash
#
# uc4-to-uc2.sh — "UC4 to UC2" (2026-09-14, user request): Files a partner
# DELIVERED on a UC4 subscription that a UC2 subscription then COLLECTED —
# the delivered file did not move on to the CFT quickly enough, so the
# partner's own pickup took it back.
#
# A pair is one UC2 File and one UC4 File with
#   - the SAME file name                         (_files.tsv col 11)
#   - the SAME login                             (col 14, case-insensitive)
#   - the SAME subscription name after the UC4 / UC2 prefix (col 12 minus its
#     first three characters, case-insensitive: UC4-X pairs with UC2-X)
#   - the UC4 File STARTING EARLIER than the UC2 File (col 6, the sort key)
# Each UC2 File pairs with the NEWEST such UC4 File. The use case is the
# subscription NAME prefix only: a name without UC2/UC4 cannot take part.
#
# Two tables: per subscription pair and login (Files, fastest / median /
# slowest gap, first and last collect — whole-window aggregates, so nofilter)
# and every pair as a row, newest collect first (File, Login, both
# subscriptions and times, the gap, both CoreIds; the date filter reads the
# UC4 date/time). No prose on the page (help page uc4-to-uc2).
#
# Usage:
#   ./uc4-to-uc2.sh   # reads the transfer cache, writes data/transfer/reports/uc4-to-uc2.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/uc4-to-uc2.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

TMP=$(mktemp -d "${TMPDIR:-/tmp}/uc42.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
TAB=$(printf '\t')

# 1. the UC4 / UC2 Files: key (file US LOGIN US BASE), sort key, use case,
#    subscription, date, time, seconds (jdn*86400 + time of day), CoreId, login
LC_ALL=C awk -F'\t' -v OFS='\t' '
    $11 != "" && $4 != "" && $12 ~ /^[Uu][Cc][24]/ {
        u = toupper(substr($12, 1, 3))
        k = $11 "\037" toupper($14) "\037" toupper(substr($12, 4))
        sec = $7 * 86400 + substr($5, 1, 2) * 3600 + substr($5, 4, 2) * 60 + substr($5, 7)
        # printf, NOT print: print renders a non-integer through OFMT (%.6g),
        # which turns ~2.1e11 seconds into 2.12654e+11 and every gap into noise
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n", k, $6, u, $12, $4, $5, sec, $1, $14
    }' "$FILES" | LC_ALL=C sort -t"$TAB" -k1,1 -k2,2 > "$TMP/legs"

# 2. walk each key in time order: a UC2 File pairs with the newest UC4 File of
#    its key that started strictly earlier (two UC4 rows kept, for an equal
#    sort key)
LC_ALL=C awk -F'\t' -v OFS='\t' '
    $1 != cur { cur = $1; n4 = 0 }
    $3 == "UC4" { if (n4 && s4k == $2) next; p_sk = s4k; p_sub = s4; p_d = d4; p_t = t4; p_sec = sec4; p_cid = c4
                  s4k = $2; s4 = $4; d4 = $5; t4 = $6; sec4 = $7; c4 = $8; n4++; next }
    $3 == "UC2" && n4 {
        if (s4k < $2)          { a_sub = s4;    a_d = d4;  a_t = t4;  a_sec = sec4;  a_cid = c4 }
        else if (n4 > 1 && p_sk < $2) { a_sub = p_sub; a_d = p_d; a_t = p_t; a_sec = p_sec; a_cid = p_cid }
        else next
        split($1, kk, "\037")
        # uc4 sub, uc2 sub, login, file, uc4 date, uc4 time, uc2 date, uc2 time, gap s, uc4 cid, uc2 cid, uc2 sortkey
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n", a_sub, $4, $9, kk[1], a_d, a_t, $5, $6, int($7 - a_sec + 0.5), a_cid, $8, $2
    }' "$TMP/legs" > "$TMP/pairs"
np=$(wc -l < "$TMP/pairs" | tr -d ' ')

HD='function hd(s) { if (s < 90) return sprintf("%d s", s)
                    if (s < 5400) return sprintf("%.0f min", s / 60)
                    if (s < 172800) return sprintf("%.1f h", s / 3600)
                    return sprintf("%.1f d", s / 86400) }'

{
    printf 'TITLE\tUC4 to UC2\n'
    printf 'DESC\tFiles a partner delivered on a UC4 subscription that the same-named UC2 subscription then collected with the same login: the delivered file did not move on to the CFT in time.\n'
    printf 'KEYWORDS\tuc4 to uc2,uc4,uc2,collected back,picked up,pickup,delivered,same file name,same login,cft,staging,twin\n'
    printf 'TABLE\tPer subscription pair\twide\tnofilter\n'
    printf 'HEAD\tUC4 subscription\tUC2 subscription\tLogin\tFiles\tFastest\tMedian\tSlowest\tFirst\tLast\n'
    printf 'KIND\tsite\tsite\tlogin\tnum\ttext\ttext\ttext\ttext\ttext\n'
    # grouped by pair + login, gaps ascending so the median is the middle row
    LC_ALL=C sort -t"$TAB" -k1,1 -k2,2 -k3,3 -k9,9n "$TMP/pairs" | awk -F'\t' "$HD"'
        function flush() { if (n == 0) return
            printf "%d\tROW\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", n, a, b, l, n, hd(g[1]), hd(g[int((n + 1) / 2)]), hd(g[n]), first, last }
        { k = $1 SUBSEP $2 SUBSEP $3 }
        k != cur { flush(); cur = k; a = $1; b = $2; l = $3; n = 0; delete g; first = ""; last = "" }
        { n++; g[n] = $9; c = $7 " " substr($8, 1, 8)
          if (first == "" || c < first) first = c
          if (c > last) last = c }
        END { flush() }' | LC_ALL=C sort -t"$TAB" -k1,1nr | cut -f2- | awk -F'\t' '{ print; n++; f += $5 } END { printf "TOTAL\tTotal (%d pair(s))\t\t\t@{class=num}%d\t\t\t\t\t\n", n + 0, f + 0 }'
    printf 'TABLE\tFiles\twide\tpager=500\n'
    printf 'HEAD\tFile\tLogin\tUC4 subscription\tUC4 date/time\tUC2 subscription\tUC2 date/time\tGap\tUC4 CoreId\tUC2 CoreId\n'
    printf 'KIND\tfile\tlogin\tsite\ttext\tsite\ttext\ttext\ttext\ttext\n'
    LC_ALL=C sort -t"$TAB" -k12,12r "$TMP/pairs" | awk -F'\t' "$HD"'
        { printf "ROW\t%s\t%s\t%s\t%s %s\t%s\t%s %s\t%s\t@{class=mono}%s\t@{class=mono}%s\n", $4, $3, $1, $5, $6, $2, $7, $8, hd($9), $10, $11 }'
    printf 'SUMMARY\tUC4 to UC2 Files: %s\n' "${np:-0}"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${np:-0} UC4 to UC2 File(s))." >&2
