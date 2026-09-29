#!/usr/bin/env bash
#
# protocol-journey.sh — "Protocol journey": the ordered PROTOCOL CHAIN of each
# File's legs (chronological), consecutive repeats collapsed to "proto+" so
# every UC2 repeat-collect variant folds into ONE journey (pesit → routing+ →
# ssh+). Patterns shows the Direction/Status shape; this shows the technical
# ROUTE the file took. (The second table — the protocol of each File's LAST
# leg — went 2026-09-29 with its File journey tab, user request.)
#
# Usage:
#   ./protocol-journey.sh   # reads input/*.csv (via the caches), writes data/protocol-journey.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/protocol-journey.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Pass 1 = $FILES (outcome/date/size per CoreId), pass 2 = $PARSED sorted
# chronologically (coreid, sortkey): build each group's collapsed chain.
agg=$( { cat "$FILES"; printf '###SPLIT###\n'; LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k13,13 "$PARSED"; } | awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
    function flush(   ch, pf, k, st) {
        if (cur == "") return
        if (run > 1) chain = chain "+"
        ch = chain
        if (!(cur in FOUT)) { reset(); return }   # missing group
        pf = (FOUT[cur] == "Failed" || FOUT[cur] == "Expired")
        # Volume = the OK Files'"'"' bytes, the Files column'"'"'s own scope (2026-09-29)
        cr[ch]++; if (!pf) { cb[ch] += FSZ[cur]; tpb += FSZ[cur] }; trec++
        if (pf) { cf[ch]++; tfl++ } else { cp[ch]++; tpr++ }
        if (cr[ch] > maxrec) maxrec = cr[ch]
        d = FDT[cur]
        if (d != "") { cdr[ch SUBSEP d]++; cdf[ch SUBSEP d] += pf; cdp[ch SUBSEP d] += (!pf); if (!pf) cdb[ch SUBSEP d] += FSZ[cur] }
        addtop("J" SUBSEP ch SUBSEP (pf ? "F" : "P"), FSK[cur], FDT[cur] " " FTM[cur], cur)
        reset()
    }
    function reset() { cur = ""; chain = ""; prevp = ""; run = 0 }
    /^###SPLIT###$/ { mode = 1; next }
    mode == 0 { FOUT[$1] = $2; FDT[$1] = $4; FTM[$1] = $5; FSK[$1] = $6; FSZ[$1] = $8 ; next }
    {
        if ($1 != cur) { flush(); cur = $1 }
        p = $10; if (p == "") p = "?"
        if (p == prevp) { run++ }
        else {
            if (run > 1) chain = chain "+"
            chain = chain (chain == "" ? "" : " \342\206\222 ") p
            prevp = p; run = 1
        }
    }
    END {
        flush()
        if (maxrec < 1) maxrec = 1
        for (k in cdr) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" cdr[k] ":" (cdf[k]+0) ":" (cdp[k]+0) ":" cdb[k] }
        # share and bar over the DELIVERED (OK) count (2026-09-13, user request:
        # the one Files column of the table is the OK count — no Error / OK pair)
        maxpr = 0; for (ch in cr) if (cp[ch] + 0 > maxpr) maxpr = cp[ch] + 0
        if (maxpr < 1) maxpr = 1
        for (ch in cr) {
            if (cp[ch] + 0 == 0) continue   # no OK File: nothing this table counts (2026-09-29)
            sh = tpr > 0 ? sprintf("%.1f", (cp[ch]+0) * 100 / tpr) : "0.0"
            w = int((cp[ch]+0) * 100 / maxpr)
            printf "CHN|%s|%d|%d|%d|%s|%s|%d|%s|%s|%s\n", ch, cr[ch], cf[ch]+0, cp[ch]+0, human(cb[ch]+0), sh, w, bk[ch], buildlist(top["J" SUBSEP ch SUBSEP "F"]), buildlist(top["J" SUBSEP ch SUBSEP "P"])
        }
        printf "TOT|%d|%d|%d|%s\n", trec, tfl+0, tpr+0, human(tpb+0)
    }
')

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_rec tot_failed tot_processed tot_vol <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

{
    printf 'TITLE\tProtocol Journey\n'

    printf 'TABLE\tFiles by protocol journey\n'
    # FILES = the delivered (OK) count (2026-09-13, user request: the Patterns
    # group tables carry ONE Files column, no Error / OK pair, no green/red
    # cells, no drills); the bucket payload keeps all four metrics, so the
    # tokens read metric 2 (ok) for Files, the share and the bar
    printf 'HEAD\tJourney\tFiles\tVolume\t%% of Files\tDistribution\n'
    printf 'KIND\tmono\tnum\tnum\tnum\tbar\n'
    printf 'RECALC\t-\ts2\th3\t%%2\tb2\n'
    # straight into the report — no per-row command substitution
    while IFS='|' read -r _ chain rec fa pr human sh w bk ccf ccp; do
        [ -z "$chain" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s%%\t%s\t@data:buckets=%s\n' "$chain" "$pr" "$human" "$sh" "$w" "$bk"
    done <<< "$(printf '%s\n' "$agg" | grep '^CHN|' | sort -t'|' -k5,5nr)"
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}%s\t@{class=num}100.0%%\t\n' "$tot_processed" "$tot_vol"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_rec File(s))." >&2
