#!/usr/bin/env bash
#
# patterns.sh — the SHAPE of a logical transfer.
#
# A logical transfer is all the records that share one CoreId: an Inbound row,
# an Outbound row, and (when the Outbound fails) up to 5 Outbound retries — and
# the Inbound can retry too. For each distinct PATTERN — the ordered sequence of
# "Direction / Status" lines across a CoreId's rows — count how many logical
# transfers matched it. Status is shown raw (so "Failed Subtransmission" appears
# verbatim). Rows are ordered Inbound-first, then by Start Time (retry order).
#
# TWO tables since 2026-09-03 (user request), one switch group on the page:
# the pattern as above ("Protocol off", the default) and the pattern with the
# leg's PROTOCOL as the second element of every line ("Protocol on":
# "Outbound / ssh / Processed"). report.js shows one at a time behind a
# button row (the TABLE switch= modifier). Both list the 5 most recent Files
# of each pattern, a File a LINK to its own page (docs/files/<coreid>.html)
# when it has one — since 2026-09-29 only the Files bin/transfer/filepages.sh
# publishes (per subscription the newest OK File and the three newest Failed
# Files, _filepages.tsv); the others are plain lines.
#
# Usage:
#   ./patterns.sh    # reads input/*.csv (via the cache), writes data/patterns.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/patterns.rpt"
FPF="$CACHE_DIR/_filepages.tsv"; [ -f "$FPF" ] || FPF=/dev/null   # the published File pages (bin/transfer/filepages.sh)

TOP_N=200   # patterns to list (there are only ~41; this is a safety cap)
LAST_N=5    # the most recent Files listed per pattern

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Read the cache in row order (1=coreid; 2=direction so Inbound precedes Outbound;
# 13=sortkey so retries are chronological). Build each CoreId's pattern from its
# rows' "Direction / Status" (3=raw status) — and, for the second table, the
# rows' "Direction / Protocol / Status" (10=protocol) — joined by \x1f (the
# renderer turns it into line breaks), and count how many Files share each.
# Emits one line per (variant, pattern): variant ⇥ files ⇥ legs ⇥ transfers ⇥
# buckets ⇥ last-5 cell ⇥ pattern.
agg=$(LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k13,13 "$PARSED" | awk -F'\t' -v LASTN="$LAST_N" -v FPF="$FPF" '
    BEGIN { US = sprintf("%c", 31)
            while ((getline l < FPF) > 0) { split(l, a9, "\t"); if (a9[1] != "") FP[a9[1]] = 1 } close(FPF) }
    # Keep, per (variant, pattern), the LASTN most-recent Files (by transfer
    # start sortkey), each stored as "sortkey SUBSEP disp SUBSEP coreid" and
    # held sorted desc.
    function addtop(p, sk, disp, cid,   key, n, arr, i, pos, m, out) {
        key = sk SUBSEP disp SUBSEP cid
        n = (p in top) ? split(top[p], arr, US) : 0
        pos = n + 1
        for (i = 1; i <= n; i++) if (key > arr[i]) { pos = i; break }
        if (pos > LASTN) return
        for (i = (n < LASTN ? n : LASTN - 1); i >= pos; i--) arr[i+1] = arr[i]   # shift right, cap at LASTN
        arr[pos] = key
        m = (n < LASTN) ? n + 1 : LASTN
        out = arr[1]; for (i = 2; i <= m; i++) out = out US arr[i]
        top[p] = out
    }
    function account(v, p,   k, L) {
        k = v SUBSEP p
        cnt[k]++                                    # logical transfers with this pattern
        pl[k SUBSEP d]++                            # ... on date d
        L = split(p, tmp, US)                       # rows in the pattern
        pp[k SUBSEP d] += L                         # physical transfers (rows) on date d
        addtop(k, csk, cdisp, ccid)                 # remember this CoreId for the recent list
    }
    function flush() {
        if (prev == "") return
        account("A", pat); account("P", patp)
    }
    {
        # d/csk/cdisp/ccid = the first (earliest) row of the CoreId = transfer start.
        if ($1 != prev) { flush(); pat = ""; patp = ""; prev = $1; d = $11; csk = $13; cdisp = $11 " " $12; ccid = $1 }
        line = $2 " / " $3
        pat = (pat == "" ? line : pat US line)
        linep = $2 " / " ($10 != "" ? $10 : "?") " / " $3   # Direction / Protocol / Status (the protocol SECOND, 2026-09-03 user request)
        patp = (patp == "" ? linep : patp US linep)
    }
    END {
        flush()
        # Per (variant, pattern), a per-date bucket "date:logical:physical,..." for the filter.
        for (k in pl) { n9 = split(k, a, SUBSEP); kk = a[1] SUBSEP a[2]; b[kk] = b[kk] (b[kk] ? "," : "") a[3] ":" pl[k] ":" pp[k] }
        for (k in cnt) {
            split(k, a, SUBSEP); v = a[1]; p = a[2]
            rows = split(p, tmp, US)
            # the last-N cell: one line per File, most recent first — a LINK
            # ("href|label", the clinks kind) when its page is published
            cc = ""; n = split(top[k], arr, US)
            for (i = 1; i <= n; i++) { split(arr[i], f, SUBSEP); cc = cc (cc ? US : "") ((f[3] in FP) ? "../files/" f[3] ".html|" : "") f[2] "  " f[3] }
            printf "%s\t%d\t%d\t%d\t%s\t%s\t%s\n", v, cnt[k], rows, cnt[k] * rows, b[k], cc, p
        }
    }
')

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 0   # empty estate (config-only clone): placeholder page, not a failed build
fi


# figures from the plain variant (the same Files, just grouped coarser)
tot=$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "A" { s += $2 } END { print s + 0 }')    # logical transfers
phys=$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "A" { s += $4 } END { print s + 0 }')   # physical transfers
np=$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "A"' | grep -c . || true)
npp=$(printf '%s\n' "$agg" | awk -F'\t' '$1 == "P"' | grep -c . || true)

# one table per variant: rows by frequency, capped at TOP_N
emit_rows() {   # $1 variant
    printf '%s\n' "$agg" | awk -F'\t' -v v="$1" '$1 == v' | sort -t"$(printf '\t')" -k2,2nr | awk -v n="$TOP_N" 'NR<=n' \
    | while IFS=$'\t' read -r _ logical legs physical bucket files pattern; do
        [ -z "$logical" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\n' "$pattern" "$legs" "$logical" "$physical" "$files" "$bucket"
    done
}
shown=$(printf '%s\n' "$agg" | awk -F'\t' -v n="$TOP_N" '$1 == "A" { c++ } END { print (c > n ? n : c) + 0 }')

{
    printf 'TITLE\tTransfer Patterns\n'
    printf 'TABLE\tTransfer patterns\tnosearch\tswitch=protocol:Protocol off\n'
    printf 'HEAD\tPattern\tLegs\tFiles\tTransfers\tLast 5 Files\n'
    printf 'KIND\tclines\tnum\tnum\tnum\tclinks\n'
    printf 'RECALC\t-\t-\ts0\ts1\t-\n'
    emit_rows A
    printf 'TOTAL\tTotal (%s patterns)\t\t@{class=num}%s\t@{class=num}%s\t\n' "$np" "$tot" "$phys"
    printf 'TABLE\t\tnosearch\tswitch=protocol:Protocol on\n'   # no heading: the page title says it, and the first table (whose <h2> the page drops) sets the layout
    printf 'HEAD\tPattern\tLegs\tFiles\tTransfers\tLast 5 Files\n'
    printf 'KIND\tclines\tnum\tnum\tnum\tclinks\n'
    printf 'RECALC\t-\t-\ts0\ts1\t-\n'
    emit_rows P
    printf 'TOTAL\tTotal (%s patterns)\t\t@{class=num}%s\t@{class=num}%s\t\n' "$npp" "$tot" "$phys"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($np pattern(s), $npp with the protocol, $tot transfer(s))." >&2
