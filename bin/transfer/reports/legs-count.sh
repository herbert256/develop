#!/usr/bin/env bash
#
# legs-count.sh — "Legs count": distribution of Files by their number of LEGS
# (physical rows sharing the CoreId — _files.tsv col 10). A complete transfer
# is normally 2 legs (Inbound + Outbound), retries add more, a UC2 pickup has
# 4+ (arrival, staging pair, then one leg per partner collect — repeat
# collectors reach hundreds), and 1 leg = a one-sided crossing (the Pirates
# report). Counts 1..10 get their own row, the long tail is bucketed.
#
# Usage:
#   ./legs-count.sh   # reads input/*.csv (via the caches), writes data/legs-count.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/legs-count.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# _files.tsv: 1=coreid 2=outcome 3=account 4=date 5=time 6=sortkey 8=size
# 10=rows(legs) 11=file 12=site. Bucket = the leg count itself for 1..10,
# then two ranges for the repeat-collect tail.
# the published File pages (bin/transfer/filepages.sh): a Most-legs CoreId
# links its page when it has one (2026-09-30 audit T-08, like Longest Files)
FPF="$CACHE_DIR/_filepages.tsv"; [ -f "$FPF" ] || FPF=/dev/null
agg=$(awk -F'\t' -v FPF="$FPF" '
    BEGIN { while ((getline l < FPF) > 0) { split(l, a9, "\t"); if (a9[1] != "") FP[a9[1]] = 1 } close(FPF) }
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
    function bucket(n) { if (n <= 10) return n; if (n <= 100) return 11; return 12 }
    # lit(): a raw name starting with @ would read as renderer metadata; the empty block @{} keeps it literal (audit 2026-09-29 F07)
    function lit(s) { return (substr(s, 1, 1) == "@") ? "@{}" s : s }
    {
        legs = $10 + 0; d = $4; size = $8 + 0
        pf = ($2 == "Failed" || $2 == "Expired")
        i = bucket(legs)
        # Volume = the OK Files'"'"' bytes, the Files column'"'"'s own scope (2026-09-29:
        # every File'"'"'s — a "1 leg | 0 | 104 MB" row)
        br[i]++; if (!pf) { bb[i] += size; tpb += size }; trec++
        if (pf) { bf[i]++; tfl++ } else { bp[i]++; tpr++ }
        if (br[i] > maxrec) maxrec = br[i]
        if (d != "") { bdr[i SUBSEP d]++; bdf[i SUBSEP d] += pf; bdp[i SUBSEP d] += (!pf); if (!pf) bdb[i SUBSEP d] += size }
        # bounded top-25 by legs (ties: newest start first via the sortkey)
        tk = sprintf("%012d", legs) $6
        pay = legs "\t" $4 " " $5 "\t" $12 "\t" $3 "\t" lit($11) "\t" (($1 in FP) ? "@{href=../files/" $1 ".html}" : "") $1 (($25 ~ /^(green|orange|red)$/) ? "\t@data:res=" $25 : "")   # the File colour, col 25
        if (tn < 25) { tn++; TK[tn] = tk; TV[tn] = pay }
        else {
            mi = 1; for (z = 2; z <= tn; z++) if (TK[z] < TK[mi]) mi = z
            if (tk > TK[mi]) { TK[mi] = tk; TV[mi] = pay }
        }
    }
    END {
        split("1 leg|2 legs|3 legs|4 legs|5 legs|6 legs|7 legs|8 legs|9 legs|10 legs|11 - 100 legs|> 100 legs", lab, "|")
        if (maxrec < 1) maxrec = 1
        for (k in bdr) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" bdr[k] ":" (bdf[k]+0) ":" (bdp[k]+0) ":" bdb[k] }
        # share and bar over the DELIVERED (OK) count (2026-09-13, user request:
        # the one Files column of the table is the OK count — no Error / OK pair)
        maxpr = 0; for (i = 1; i <= 12; i++) if (bp[i] + 0 > maxpr) maxpr = bp[i] + 0
        if (maxpr < 1) maxpr = 1
        for (i = 1; i <= 12; i++) {
            if (bp[i] + 0 == 0) continue   # no OK File: nothing this table counts (2026-09-29: rows of 0)
            sh = tpr > 0 ? sprintf("%.1f", (bp[i]+0) * 100 / tpr) : "0.0"
            w = int((bp[i]+0) * 100 / maxpr)
            # (the per-bucket Error / OK drill lists went 2026-09-30: no row
            # has shipped them since the one Files column, 2026-09-13)
            printf "BKT|%s|%d|%d|%d|%d|%s|%s|%d|%s\n", lab[i], br[i]+0, bf[i]+0, bp[i]+0, bb[i]+0, human(bb[i]+0), sh, w, bk[i]
        }
        # top-25, most legs first (selection sort on the padded keys)
        for (z = 1; z <= tn; z++) for (y = z + 1; y <= tn; y++) if (TK[y] > TK[z]) { t2 = TK[z]; TK[z] = TK[y]; TK[y] = t2; t2 = TV[z]; TV[z] = TV[y]; TV[y] = t2 }
        for (z = 1; z <= tn; z++) printf "TOP|%s\n", TV[z]
        printf "TOT|%d|%d|%d|%s\n", trec, tfl+0, tpr+0, human(tpb+0)
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_rec tot_failed tot_processed tot_vol <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# Both row loops run INSIDE the report block below (a herestring keeps them in
# this shell), so their counters are ready for the TOTAL line that follows them.
ord=0
top_n=0

{
    printf 'TITLE\tLegs Count\n'

    printf 'TABLE\tFiles by leg count\n'
    # FILES = the delivered (OK) count (2026-09-13, user request: the Patterns
    # group tables carry ONE Files column, no Error / OK pair, no green/red
    # cells, no drills); the bucket payload keeps all four metrics, so the
    # tokens read metric 2 (ok) for Files, the share and the bar
    printf 'HEAD\tLegs\tFiles\tVolume\t%% of Files\tDistribution\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tbar\n'
    printf 'RECALC\t-\ts2\th3\t%%2\tb2\n'
    while IFS='|' read -r _ label rec fa pr bytes human sh w bk; do
        [ -z "$label" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s%%\t%s\t@data:buckets=%s\t@data:ord=%s\n' "$label" "$pr" "$human" "$sh" "$w" "$bk" "$ord"
        ord=$((ord + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^BKT|')"
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}%s\t@{class=num}100.0%%\t\n' "$tot_processed" "$tot_vol"
    printf 'LINK\tpirates-details.html\tOne-legged Files (the 1-leg Files, per subscription)\n'

    printf 'TABLE\tFiles with the most legs\trestint\n'   # rows tint by the File colour (2026-09-29)
    printf 'HEAD\tLegs\tDate & time\tSubscription\tAccount\tFile\tCoreId\n'
    printf 'KIND\tnum\ttext\tsite\tacct\tfile\tmono\n'
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf 'ROW\t%s\n' "${line#TOP|}"
        top_n=$((top_n + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^TOP|')"
    printf 'TOTAL\tTop %s of %s Files\t\t\t\t\t\n' "$top_n" "$tot_rec"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_rec File(s))." >&2
