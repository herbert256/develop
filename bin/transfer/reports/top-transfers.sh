#!/usr/bin/env bash
#
# top-transfers.sh
# Lists the largest Files by size. Each row shows the file, account, site,
# outcome and timestamp for context. (The SLOWEST transfers moved to the
# Duration report, 2026-07.)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/top-transfers.rpt"

TOP_N=50


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

tmp="$(mktemp "${TMPDIR:-/tmp}/toptransfers.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# Read the logical-transfer cache (data/_files.tsv): one row per transfer,
# 2=outcome, 3=account, 4=date, 5=time, 8=size (the file), 9=dur_ms (wall-clock span),
# 11=file, 12=dest_site. Emit one typed row per transfer (not per cache row):
#   S|size_bytes|size_human|datetime|account|dest_site|outcome|file|thr
awk -F'\t' '
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " ")
        i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        if (i == 1) return sprintf("%d %s", v, u[i])
        return sprintf("%.2f %s", v, u[i])
    }
    function thr(bytes, ms) { return ms > 0 ? human(bytes * 1000 / ms) "/s" : "-" }
    function clean(s) { gsub(/\|/, "/", s); gsub(/[\t\r]/, " ", s); return s }   # keep | out of the S| delimiter stream
    {
        outcome = ($2 != "Failed" && $2 != "Expired" ? "OK" : "Error"); account = clean($3); dsite = clean($12)
        if (account == "") account = "(no account)"        # parenthesized pseudo-value -> unlinked
        if (dsite == "")   dsite = "(no subscription)"
        file = clean($11); ts = $4 " " $5
        size = $8
        d = $9 + 0                                   # transfer duration in ms (wall-clock span)
        tp = thr(size, d)                            # throughput (bytes/s), "-" if no duration
        printf "S|%d|%s|%s|%s|%s|%s|%s|%s\n", size, human(size), ts, account, dsite, outcome, file, tp
    }
' "$FILES" > "$tmp"

# Cap with `awk NR<=N` rather than `head` so sort is never SIGPIPE-killed under
# pipefail; `|| true` because an env with no Files yields zero S| rows and a
# zero-match grep exits 1 — set -e would kill the script on the empty case.
largest=$(grep '^S|' "$tmp" | sort -t'|' -k2,2 -rn | awk -v n="$TOP_N" 'NR<=n' || true)

# Cells are emitted raw (no HTML-escaping) — the renderer escapes. awk clean()
# already removed the pipe delimiter from values.
# The row loop runs INSIDE the report block below (a herestring keeps it in
# this shell), so its footer sums are ready for the TOTAL that follows it.
lg_n=0; lg_bytes=0

# footer figures: the shown rows' raw sums, humanized like the row cells
hum_bytes() { awk -v b="$1" 'BEGIN{ split("B KB MB GB TB PB",u," "); i=1; v=b+0; while(v>=1024&&i<6){v/=1024;i++}; if(i==1)printf "%d %s",v,u[i]; else printf "%.2f %s",v,u[i] }'; }

{
    printf 'TITLE\tLargest Files\n'
    printf 'DESC\tThe largest Files by size, with throughput and outcome.\n'
    printf 'INTRO\tThe %s largest Files by file size. One row = one File. The SLOWEST transfers live on the **Duration** report (2026-07: the former Slowest table here duplicated it).\n' "$TOP_N"

    printf 'TABLE\tTop %s largest Files\twide\n' "$TOP_N"
    printf 'HEAD\tSize\tThroughput\tStart Time\tAccount\tDestination Subscription\tOutcome\tFile\n'
    printf 'KIND\tnum\tnum\ttext\tacct\tsite\ttext\tfile\n'
    while IFS='|' read -r _ bytes human ts account dsite outcome file tp; do
        [ -z "$human" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$human" "$tp" "$ts" "$account" "$dsite" "$outcome" "$file"
        lg_n=$((lg_n + 1)); lg_bytes=$((lg_bytes + bytes))
    done <<< "$largest"
    printf 'TOTAL\tTotal (%s rows): %s\t\t\t\t\t\t\n' "$lg_n" "$(hum_bytes "$lg_bytes")"

    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (top $TOP_N largest & slowest)." >&2
