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
# Usage:
#   ./patterns.sh    # reads input/*.csv (via the cache), writes data/patterns.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/patterns.rpt"

TOP_N=200   # patterns to list (there are only ~41; this is a safety cap)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Read the cache in row order (1=coreid; 2=direction so Inbound precedes Outbound;
# 13=sortkey so retries are chronological). Build each CoreId's pattern from its
# rows' "Direction / Status" (3=raw status) joined by \x1f (the renderer turns it
# into line breaks), and count how many Files share each pattern.
agg=$(LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k13,13 "$PARSED" | awk -F'\t' '
    BEGIN { US = sprintf("%c", 31) }
    # Keep, per pattern, the 10 most-recent Files (by transfer start sortkey),
    # each stored as "sortkey SUBSEP disp SUBSEP coreid" and held sorted desc.
    function addtop(p, sk, disp, cid,   key, n, arr, i, pos, m, out) {
        key = sk SUBSEP disp SUBSEP cid
        n = (p in top) ? split(top[p], arr, US) : 0
        pos = n + 1
        for (i = 1; i <= n; i++) if (key > arr[i]) { pos = i; break }
        if (pos > 10) return
        for (i = (n < 10 ? n : 9); i >= pos; i--) arr[i+1] = arr[i]   # shift right, cap at 10
        arr[pos] = key
        m = (n < 10) ? n + 1 : 10
        out = arr[1]; for (i = 2; i <= m; i++) out = out US arr[i]
        top[p] = out
    }
    function flush(   L) {
        if (prev == "") return
        cnt[pat]++                                  # logical transfers with this pattern
        pl[pat SUBSEP d]++                          # ... on date d
        L = split(pat, tmp, US)                     # rows in the pattern
        pp[pat SUBSEP d] += L                        # physical transfers (rows) on date d
        addtop(pat, csk, cdisp, ccid)               # remember this CoreId for the recent-10 list
    }
    {
        # d/csk/cdisp/ccid = the first (earliest) row of the CoreId = transfer start.
        if ($1 != prev) { flush(); pat = ""; prev = $1; d = $11; csk = $13; cdisp = $11 " " $12; ccid = $1 }
        line = $2 " / " $3
        pat = (pat == "" ? line : pat US line)
    }
    END {
        flush()
        # Per pattern, a per-date bucket "date:logical:physical,..." for the filter.
        for (k in pl) { split(k, a, SUBSEP); b[a[1]] = b[a[1]] (b[a[1]] ? "," : "") a[2] ":" pl[k] ":" pp[k] }
        for (p in cnt) {
            rows = split(p, tmp, US)
            cc = ""; n = split(top[p], arr, US)     # the last-10 list, \x1f-joined (most recent first)
            for (i = 1; i <= n; i++) { split(arr[i], f, SUBSEP); cc = cc (cc ? US : "") f[2] "  " f[3] }
            printf "%d\t%d\t%d\t%s\t%s\t%s\n", cnt[p], rows, cnt[p] * rows, b[p], cc, p
        }
    }
')

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 0   # empty estate (config-only clone): placeholder page, not a failed build
fi

tot=$(printf '%s\n' "$agg" | awk -F'\t' '{s += $1} END {print s + 0}')    # logical transfers (sum of pattern counts)
phys=$(printf '%s\n' "$agg" | awk -F'\t' '{s += $3} END {print s + 0}')   # physical transfers (sum of rows = total rows)
np=$(printf '%s\n' "$agg" | grep -c . || true)
top=$(printf '%s\n' "$agg" | sort -t"$(printf '\t')" -k1,1nr | awk -v n="$TOP_N" 'NR<=n')
shown=$(printf '%s\n' "$top" | grep -c . || true)

{
    printf 'TITLE\tTransfer Patterns\n'
    printf 'DESC\tThe row/status shape of a File (the transfers sharing it) and how often each occurs.\n'
    printf 'INTRO\tEach **File** is the set of records sharing it — an Inbound row, an Outbound row, and any retries. Every row is one distinct pattern of **Direction / Status** lines (in order). **Legs** counts the lines in the pattern; **Files** counts the Files that matched; **Transfers** counts their individual rows (Files × Legs). **Last 10 files** lists the pattern'"'"'s 10 most recent Files (by start time). The Pattern and Last 10 files cells load collapsed to their first and last line — **click a cell** to expand or collapse it.\n'
    printf 'TABLE\tTransfer patterns\tnosearch\n'
    printf 'HEAD\tPattern\tLegs\tFiles\tTransfers\tLast 10 files\n'
    printf 'KIND\tclines\tnum\tnum\tnum\tclines\n'
    printf 'RECALC\t-\t-\ts0\ts1\t-\n'
    # straight into the report — no per-row command substitution
    while IFS=$'\t' read -r logical legs physical bucket files pattern; do
        [ -z "$logical" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\n' "$pattern" "$legs" "$logical" "$physical" "$files" "$bucket"
    done <<< "$top"
    printf 'TOTAL\tTotal (%s patterns)\t\t@{class=num}%s\t@{class=num}%s\t\n' "$np" "$tot" "$phys"
    if [ "$shown" -lt "$np" ]; then
        printf 'NOTE\tShowing the top %s of %s patterns by frequency.\n' "$shown" "$np"
    fi
    printf 'SUMMARY\tDistinct patterns: %s  |  Files: %s  |  Transfers: %s\n' "$np" "$tot" "$phys"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($np pattern(s), $tot transfer(s))." >&2
