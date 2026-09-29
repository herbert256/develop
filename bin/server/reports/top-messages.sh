#!/usr/bin/env bash
#
# top-messages.sh — the server log's WARNING and ERROR messages clustered into
# repeated SHAPES: quoted strings, UUIDs, IP addresses and numbers are
# normalized away so the 250k warn/error records collapse into a short list of
# distinct message families, ranked by how often they repeat. The top family
# alone ("TaskProcessorSynchronizer swallowed an exception.") accounts for ~40%
# of all warnings. Info records are excluded (3.2M routine lines).
#
# Usage:
#   ./top-messages.sh    # reads input/*.csv (via the cache), writes data/top-messages.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/top-messages.rpt"

TOP_N=50   # message shapes to list

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Normalize each W/E message to its shape: "…" -> "…", UUIDs -> UUID, dotted
# quads -> IP, free-standing digit runs -> N (a run right after a letter or
# "_" is part of a name or code and stays: 2026-09-29 audit — UC1_X, UC3_X
# and UC4_X all read "UCN_X", a name that exists nowhere, and folded three
# flows into one shape; ARRC0029 kept its number too); truncate so endless
# stack-trace tails cluster too. Emits TAB-separated: count, level letter, buckets, first, last, shape.
agg=$(awk -F'\t' "$LOGLINES_AWK"'
    function numn(s,   out, pre) {
        out = ""
        while (match(s, /[0-9]+/)) {
            pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
            out = out substr(s, 1, RSTART - 1) ((pre ~ /[A-Za-z_]/) ? substr(s, RSTART, RLENGTH) : "N")
            s = substr(s, RSTART + RLENGTH)
        }
        return out s
    }
    $3 == "I" { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        raw = $5
        m = $5
        gsub(/"[^"]*"/, "\"…\"", m)
        gsub(/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f-]*[0-9a-f]/, "UUID", m)
        gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "IP", m)
        m = numn(m)
        m = substr(m, 1, 160)
        if (m == "") m = "(empty message)"   # never empty: the row is TAB-read in bash, which collapses it (2026-09-28)
        k = $3 SUBSEP m
        cnt[k]++; tot++
        addline(k, $1 " " $2, lvlname($3) " " compname($4) "  " substr(raw, 1, 200))   # the RAW line behind the shape
        if (d != "") {
            cd2[k SUBSEP d]++
            if (!(k in fst) || d < fst[k]) fst[k] = d
            if (!(k in lst) || d > lst[k]) lst[k] = d
        }
    }
    END {
        for (x in cd2) {
            n = split(x, a, SUBSEP)                        # level, shape, date
            kk = a[1] SUBSEP a[2]
            bk[kk] = bk[kk] (bk[kk] ? "," : "") a[3] ":" cd2[x]
        }
        for (k in cnt) { split(k, a, SUBSEP); shapes++
            printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", cnt[k], a[1], bk[k], fst[k], lst[k], a[2], lastlines(k) }
        printf "TOT\t%d\t%d\n", tot+0, shapes+0
    }
' "$(srv_subset noninfo)")   # the non-Info lines (bin/server/subsets.sh — 2026-09-29, speed round 3)

IFS=$'\t' read -r _ tot_msgs shape_count <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${tot_msgs:-0}" -eq 0 ]; then
    echo "No warning/error records found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

# -k2,2 -k6,6 (level, shape) break count ties deterministically — without them
# equal-count rows land in awk hash-iteration order
top=$(printf '%s\n' "$agg" | grep -v $'^TOT\t' | sort -t"$(printf '\t')" -k1,1nr -k2,2 -k6,6 | awk -v n="$TOP_N" 'NR<=n')
shown=$(printf '%s\n' "$top" | grep -c . || true)
shown_msgs=$(printf '%s\n' "$top" | awk -F'\t' '{s += $1} END {print s + 0}')

# The row writer prints STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
rows() {
    while IFS=$'\t' read -r count lvl bk fst lst shape lines; do
        [ -z "$shape" ] && continue
        case $lvl in
            E) lcell="@{class=failed}Error" ;;
            W) lcell="@{class=warn}Warning" ;;
            *) lcell="$lvl" ;;
        esac
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$lcell" "$count" "$fst" "$lst" "$shape" "$bk" "$lines"
    done <<< "$top"
}

{
    printf 'TITLE\tTop Warning & Error Messages\n'
    printf 'TABLE\tMost repeated message shapes\twide\tsort=1:-1\n'
    printf 'HEAD\tLevel\tCount\tFirst\tLast\tMessage shape\n'
    printf 'KIND\ttext\tnum\ttext\ttext\tfile\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    rows
    printf 'TOTAL\tTop %s of %s shapes\t@{class=num}%s\t\t\t\n' "$shown" "$shape_count" "$shown_msgs"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($shape_count shape(s), top $shown listed)." >&2
