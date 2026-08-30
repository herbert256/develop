#!/usr/bin/env bash
#
# file-type.sh
# Breaks transfers down by FILE TYPE — the extension of the File column
# (field 10) — with record count, Error/OK split, data volume and
# share of records. Files with no extension (e.g. Outbound records whose File
# is the account name) are grouped as "(none)"; purely numeric suffixes (batch
# sequence numbers) as "(numeric)". "Failed Subtransmission" folds into Failed.
#
# Usage:
#   ./file-type.sh    # reads input/*.csv, writes data/file-type.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/file-type.rpt"

TOP_N=40   # how many file types to list (the long tail is folded into a note)


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Read the shared parse cache (3=status, 8=file, 9=size).
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
    {
        status = $3; sub(/ Subtransmission$/, "", status); pf = (status != "Processed")
        file = $8
        size = $9; d = $11
        ext = "(none)"
        # No interval expression ({1,10}) here — mawk does not support them and
        # would silently never match. Match an unbounded extension and length-cap
        # it instead (RLENGTH counts the dot, so <= 11 means ext <= 10 chars).
        if (match(file, /\.[A-Za-z0-9]+$/) && RLENGTH <= 11) ext = tolower(substr(file, RSTART + 1))
        if (ext ~ /^[0-9]+$/) ext = "(numeric)"

        if (!(ext in er)) ec++          # distinct-type counter (POSIX; length(array) is an extension)
        er[ext]++; eb[ext] += size; trec++; tbytes += size
        if (pf) { ef[ext]++; tf++ } else { ep[ext]++; tp++ }
        if (d != "") { edl[ext SUBSEP d]++; edf[ext SUBSEP d] += pf; edp[ext SUBSEP d] += (!pf); edb[ext SUBSEP d] += size }
        addtop("E" SUBSEP ext SUBSEP (pf ? "F" : "P"), $13, $11 " " $12, $23)
    }
    function rshare(x) { return trec > 0 ? sprintf("%.1f", x * 100 / trec) : "0.0" }
    END {
        for (k in edl) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" edl[k] ":" (edf[k]+0) ":" (edp[k]+0) ":" edb[k] }
        for (k in er) printf "EXT|%s|%d|%d|%d|%d|%s|%s|%s|%s|%s\n", k, er[k], ef[k]+0, ep[k]+0, eb[k], human(eb[k]), rshare(er[k]), bk[k], buildlist(top["E" SUBSEP k SUBSEP "F"]), buildlist(top["E" SUBSEP k SUBSEP "P"])
        printf "TOT|%d|%d|%d|%d|%s|%d\n", trec, tf+0, tp+0, tbytes, human(tbytes), ec+0
    }
' "$PARSED")

# No emptiness guard on $agg: the awk END always emits the TOT| line, so it is
# never empty — a zero-record parse still renders a page with zero counts.

IFS='|' read -r _ tot_rec tot_failed tot_processed tot_bytes tot_human ext_count <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# `|| true`: an empty parse yields no EXT| rows at all, and a zero-match grep
# exits 1 under set -euo pipefail; the row loop below skips blank lines.
top_ext=$(printf '%s\n' "$agg" | grep '^EXT|' | sort -t'|' -k3,3nr | awk -v n="$TOP_N" 'NR<=n' || true)
shown=$(printf '%s\n' "$top_ext" | grep -c '^EXT|' || true)

{
    printf 'TITLE\tTransfer File Types\n'
    printf 'DESC\tTransfers, Error/OK, volume and share per file extension.\n'
    printf 'INTRO\t**%s** distinct file types (%s total volume). Extension is taken from the File column.\n' \
        "$ext_count" "$tot_human"
    printf 'TABLE\tBy file type\tdrill=transfer\n'
    printf 'HEAD\tFile type\tTransfers\tError\tOK\tVolume\t%% of transfers\n'
    printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\th3\t%%0\n'
    # one printf per row, straight into the report — no command substitution
    while IFS='|' read -r _ ext rec fa pr by hu sh bk ccf ccp; do
        [ -z "$ext" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n' "$ext" "$rec" "$fa" "$pr" "$hu" "$sh" "$bk" "$ccf" "$ccp"
    done <<< "$top_ext"
    printf 'TOTAL\tTotal (%s of %s types)\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num}100.0%%\n' \
        "$shown" "$ext_count" "$tot_rec" "$tot_failed" "$tot_processed" "$tot_human"
    if [ "$shown" -lt "$ext_count" ]; then
        printf 'NOTE\tShowing the top %s file types by transfer count; %s rarer types are not listed but are included in the total.\n' \
            "$shown" "$((ext_count - shown))"
    fi
    printf 'NOTE\tCounts individual transfers (legs), not Files — a file appears on both its Inbound and Outbound leg. Click an Error or OK count for that outcome'\''s 10 most recent transfers (newest first).\n'
    printf 'SUMMARY\tFile types: %s  |  Total transfers: %s  |  Total volume: %s\n' "$ext_count" "$tot_rec" "$tot_human"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($ext_count file type(s))." >&2
