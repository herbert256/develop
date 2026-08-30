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
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# _files.tsv: 1=coreid 2=outcome 3=account 4=date 5=time 6=sortkey 8=size
# 10=rows(legs) 11=file 12=site. Bucket = the leg count itself for 1..10,
# then two ranges for the repeat-collect tail.
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
    function bucket(n) { if (n <= 10) return n; if (n <= 100) return 11; return 12 }
    {
        legs = $10 + 0; d = $4; size = $8 + 0
        pf = ($2 == "Failed" || $2 == "Expired")
        i = bucket(legs)
        br[i]++; bb[i] += size; trec++
        if (pf) { bf[i]++; tfl++ } else { bp[i]++; tpr++ }
        if (br[i] > maxrec) maxrec = br[i]
        if (d != "") { bdr[i SUBSEP d]++; bdf[i SUBSEP d] += pf; bdp[i SUBSEP d] += (!pf); bdb[i SUBSEP d] += size }
        addtop("L" SUBSEP i SUBSEP (pf ? "F" : "P"), $6, $4 " " $5, $1)
        # bounded top-25 by legs (ties: newest start first via the sortkey)
        tk = sprintf("%012d", legs) $6
        pay = legs "\t" $4 " " $5 "\t" $12 "\t" $3 "\t" $11 "\t" $1
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
        for (i = 1; i <= 12; i++) {
            if (br[i] + 0 == 0) continue
            sh = trec > 0 ? sprintf("%.1f", (br[i]+0) * 100 / trec) : "0.0"
            w = int((br[i]+0) * 100 / maxrec)
            printf "BKT|%s|%d|%d|%d|%d|%s|%s|%d|%s|%s|%s\n", lab[i], br[i]+0, bf[i]+0, bp[i]+0, bb[i]+0, human(bb[i]+0), sh, w, bk[i], buildlist(top["L" SUBSEP i SUBSEP "F"]), buildlist(top["L" SUBSEP i SUBSEP "P"])
        }
        # top-25, most legs first (selection sort on the padded keys)
        for (z = 1; z <= tn; z++) for (y = z + 1; y <= tn; y++) if (TK[y] > TK[z]) { t2 = TK[z]; TK[z] = TK[y]; TK[y] = t2; t2 = TV[z]; TV[z] = TV[y]; TV[y] = t2 }
        for (z = 1; z <= tn; z++) printf "TOP|%s\n", TV[z]
        printf "TOT|%d|%d|%d\n", trec, tfl+0, tpr+0
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_rec tot_failed tot_processed <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# Both row loops run INSIDE the report block below (a herestring keeps them in
# this shell), so their counters are ready for the TOTAL line that follows them.
ord=0
top_n=0

{
    printf 'TITLE\tLegs Count\n'
    printf 'DESC\tFiles by their number of legs (physical rows per CoreId) — the shape of the store-and-forward, retries and UC2 pickups.\n'
    printf 'KEYWORDS\tlegs, rows per file, leg count, retries, repeat collect, single leg, one-legged\n'
    printf 'INTRO\tEvery File is a set of physical log rows sharing one CoreId — its **legs**. A clean store-and-forward is **2 legs** (Inbound + Outbound), retries add legs, a **UC2 pickup is 4+** (arrival, the staging pair, then one leg per partner collect — repeat collectors reach hundreds), and **1 leg** is a one-sided crossing (see One-legged). **%s** Files: **%s** Error, **%s** OK.\n' "$tot_rec" "$tot_failed" "$tot_processed"

    printf 'TABLE\tFiles by leg count\n'
    printf 'HEAD\tLegs\tFiles\tError\tOK\tVolume\t%% of Files\tDistribution\n'
    printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum\tnum\tbar\n'
    printf 'RECALC\t-\ts0\ts1\ts2\th3\t%%0\tb0\n'
    while IFS='|' read -r _ label rec fa pr bytes human sh w bk ccf ccp; do
        [ -z "$label" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s%%\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\t@data:ord=%s\n' "$label" "$rec" "$fa" "$pr" "$human" "$sh" "$w" "$bk" "$ccf" "$ccp" "$ord"
        ord=$((ord + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^BKT|')"
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t\t@{class=num}100.0%%\t\n' \
        "$tot_rec" "$tot_failed" "$tot_processed"
    printf 'NOTE\tClick an Error or OK count for that bucket'\''s 10 most recent Files. The **1 leg** bucket is the One-legged (Pirates) population.\n'
    printf 'LINK\tpirates-details.html\tOne-legged transfers (the 1-leg Files, per subscription)\n'

    printf 'TABLE\tFiles with the most legs\n'
    printf 'HEAD\tLegs\tDate & time\tSubscription\tAccount\tFile\tCoreId\n'
    printf 'KIND\tnum\ttext\tsite\tacct\tfile\tmono\n'
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf 'ROW\t%s\n' "${line#TOP|}"
        top_n=$((top_n + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^TOP|')"
    printf 'TOTAL\tTop %s of %s Files\t\t\t\t\t\n' "$top_n" "$tot_rec"
    printf 'NOTE\tThe extreme repeat-collectors: a UC2 file the partner keeps re-collecting adds one ssh leg per pickup, so its CoreId accumulates legs for as long as it stays staged.\n'

    printf 'SUMMARY\tFiles: %s | Error: %s | OK: %s\n' "$tot_rec" "$tot_failed" "$tot_processed"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_rec File(s))." >&2
