#!/usr/bin/env bash
#
# size-dist.sh
# Distribution of transfers by SIZE (field 19), bucketed into powers-of-1000-ish
# ranges from "0 B" up to ">= 1 GB". Shows record count, Error/OK split,
# volume, share of records and a relative-count bar per bucket. The 0-byte bucket
# (dominated by failed attempts) gets its own row. "Failed Subtransmission" folds
# into Failed.
#
# Usage:
#   ./size-dist.sh    # reads input/*.csv, writes data/size-dist.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/size-dist.rpt"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Read the logical-transfer cache (data/_files.tsv): 2=outcome, 8=size (the
# file, counted once per transfer). Distribution is over logical transfers.
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
    function bucket(b) {
        if (b == 0)            return 0
        if (b < 1024)          return 1
        if (b < 10240)         return 2
        if (b < 102400)        return 3
        if (b < 1048576)       return 4
        if (b < 10485760)      return 5
        if (b < 104857600)     return 6
        if (b < 1073741824)    return 7
        return 8
    }
    {
        outcome = $2
        size = $8; d = $4; pf = (outcome == "Failed" || outcome == "Expired")
        i = bucket(size + 0)
        br[i]++; bb[i] += size; trec++; tbytes += size
        if (pf) { bf[i]++; tfl++ } else { bp[i]++; tpr++ }
        if (br[i] > maxrec) maxrec = br[i]
        if (d != "") { bdr[i SUBSEP d]++; bdf[i SUBSEP d] += pf; bdp[i SUBSEP d] += (!pf); bdb[i SUBSEP d] += size }
        addtop("Z" SUBSEP i SUBSEP (pf ? "F" : "P"), $6, $4 " " $5, $1)
        # empty-but-OK deliveries per subscription — an empty "successful"
        # export is often a real business fault upstream
        if (!pf && size + 0 == 0 && $12 != "") {
            es[$12]++; etot++
            if (d != "") { edd[$12 SUBSEP d]++
                if (!(($12 SUBSEP d) in eds)) { eds[$12 SUBSEP d] = 1; edl[$12] = edl[$12] (edl[$12] ? "," : "") d }
                if (!($12 in ef) || d < ef[$12]) ef[$12] = d
                if (!($12 in el) || d > el[$12]) el[$12] = d }
            addtop("E" SUBSEP $12, $6, $4 " " $5, $1)
        }
    }
    END {
        split("0 B|1 B - 1 KB|1 KB - 10 KB|10 KB - 100 KB|100 KB - 1 MB|1 MB - 10 MB|10 MB - 100 MB|100 MB - 1 GB|>= 1 GB", lab, "|")
        if (maxrec < 1) maxrec = 1
        for (k in bdr) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" bdr[k] ":" (bdf[k]+0) ":" (bdp[k]+0) ":" bdb[k] }
        for (i = 0; i <= 8; i++) {
            sh = trec > 0 ? sprintf("%.1f", (br[i]+0) * 100 / trec) : "0.0"
            w = int((br[i]+0) * 100 / maxrec)
            printf "BKT|%s|%d|%d|%d|%d|%s|%s|%d|%s|%s|%s\n", lab[i+1], br[i]+0, bf[i]+0, bp[i]+0, bb[i]+0, human(bb[i]+0), sh, w, bk[i], buildlist(top["Z" SUBSEP i SUBSEP "F"]), buildlist(top["Z" SUBSEP i SUBSEP "P"])
        }
        esub = 0
        for (s in es) { esub++
            m2 = split(edl[s], dz, ","); ebk = ""
            for (i2 = 1; i2 <= m2; i2++) { dd2 = dz[i2]; ebk = ebk (ebk ? "," : "") dd2 ":" edd[s SUBSEP dd2] }
            printf "EMP|%08d|%s|%s|%s|%s|%s\n", es[s], s, ef[s], el[s], ebk, buildlist(top["E" SUBSEP s])
        }
        printf "TOT|%d|%d|%d|%d|%s|%d|%d\n", trec, tfl+0, tpr+0, tbytes, human(tbytes), etot+0, esub
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_rec tot_failed tot_processed tot_bytes tot_human tot_empty n_empty_sub <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# Both row loops live inside the report block below (a herestring keeps them in
# this shell), so their counters are ready for the lines that follow them.
ord=0
n_emp=0

{
    printf 'TITLE\tTransfer Size Distribution\n'
    printf 'DESC\tFiles, Error/OK and volume bucketed by transfer size — plus the zero-byte files that were delivered OK.\n'
    printf 'KEYWORDS\tempty file, zero byte, 0 B, empty export\n'
    printf 'INTRO\t%s total volume across all Files, bucketed by size (one File = its file, counted once). The 0 B bucket is mostly failed Files.\n' \
        "$tot_human"
    printf 'TABLE\tFiles by size bucket\n'
    printf 'HEAD\tSize range\tFiles\tError\tOK\tVolume\t%% of Files\tDistribution\n'
    printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum\tnum\tbar\n'
    printf 'RECALC\t-\ts0\ts1\ts2\th3\t%%0\tb0\n'
    while IFS='|' read -r _ label rec fa pr bytes human sh w bk ccf ccp; do
        [ -z "$label" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s%%\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\t@data:ord=%s\n' "$label" "$rec" "$fa" "$pr" "$human" "$sh" "$w" "$bk" "$ccf" "$ccp" "$ord"
        ord=$((ord + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^BKT|')"
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num}100.0%%\t\n' \
        "$tot_rec" "$tot_failed" "$tot_processed" "$tot_human"
    printf 'NOTE\tClick an Error or OK count for that outcome'\''s 10 most recent Files (newest first).\n'

    printf 'TABLE\tEmpty files delivered OK\twide\n'
    printf 'HEAD\tSubscription\tEmpty OK Files\tFirst\tLast\n'
    printf 'KIND\tsite\tnumwarn\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\n'
    while IFS='|' read -r _ ecnt esite efirst elast ebk edrill; do
        [ -z "$esite" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids=%s\n' "$esite" $((10#$ecnt)) "$efirst" "$elast" "$ebk" "$edrill"
        n_emp=$((n_emp + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^EMP|' | LC_ALL=C sort -t'|' -k2,2r -k3,3)"
    # No trailing newline on the empty-state row — it never had one (it came out
    # of a $(printf …), which strips it), so the TOTAL below runs onto its line.
    if [ "$n_emp" -eq 0 ]; then
        printf 'ROW\t@{colspan=4}No zero-byte Files were delivered OK in this data window.'
    fi
    printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num warn}%s\t\t\n' "$n_empty_sub" "$tot_empty"
    printf 'NOTE\tZero-byte Files whose delivery ended **OK** — the transfer worked, but the file was EMPTY, which usually means the upstream export produced nothing. A flow that legitimately ships empty markers recurs steadily here; a subscription appearing suddenly deserves a look. The failed 0-byte attempts stay in the 0 B bucket above. Click a row for its 10 most recent empty Files.\n'
    printf 'SUMMARY\tTotal Files: %s  |  Total volume: %s  |  Empty OK Files: %s across %s subscription(s)\n' "$tot_rec" "$tot_human" "$tot_empty" "$n_empty_sub"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_rec record(s))." >&2
