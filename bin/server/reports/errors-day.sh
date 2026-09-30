#!/usr/bin/env bash
#
# errors-day.sh — server-log levels per component: record counts split by
# Level (Info / Warning / Error) for TM / PESITD / SSHD. Reads the parse cache
# (data/_parse.tsv: 1=date, 2=time, 3=level letter, 4=component letter,
# 5=message). The per-day level table went 2026-09-28 (user request: fewer
# server reports) — it repeated the Top view's Records / Info / Warnings /
# Errors / Error % per date number for number; the Top view is that table.
#
# Usage:
#   ./errors-day.sh    # reads input/*.csv (via the cache), writes data/errors-day.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/errors-day.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the cache (1=date, 2=time, 3=level, 4=component, 5=message):
# per-component level counts (+ per-day buckets so the component table
# re-aggregates under the date filter).
# Emits: COMP|comp|info|warn|err|total|buckets  TOT|recs|info|warn|err|errpct|days
# The counts come from the COUNTS table (bin/server/subsets.sh — a full cache
# pass of its own until 2026-09-30), the drill lines from the non-Info subset
# (in cache order). An UNDATED line counts for the totals and its component,
# never for a day (date "" in the table).
CNTF=$(srv_counts)
agg=$(awk -F'\t' -v CNTF="$CNTF" "$LOGLINES_AWK"'
    function cname(x) {
        if (x == "T") return "TM"
        if (x == "P") return "PESITD"
        if (x == "S") return "SSHD"
        return x
    }
    FILENAME == CNTF {   # C date hour level component count  (T lines: not read here)
        if ($1 != "C") next
        d = $2; n = $6 + 0; lv = $4; cp = $5
        tot += n; if (lv == "I") ti += n; else if (lv == "W") tw += n; else if (lv == "E") te += n
        cr[cp] += n
        if (lv == "I") ci[cp] += n; else if (lv == "W") cw[cp] += n; else if (lv == "E") ce[cp] += n
        if (d != "") {
            if (!(d in dseen)) { dseen[d] = 1; days++ }
            cdr[cp SUBSEP d] += n
            if (lv == "I") cdi[cp SUBSEP d] += n; else if (lv == "W") cdw[cp SUBSEP d] += n; else if (lv == "E") cde[cp SUBSEP d] += n
        }
        next
    }
    {   # the non-Info lines, in cache order: the last warn/error lines per component
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        addline("C" SUBSEP $4, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
    }
    END {
        for (k in cdr) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" (cdi[k]+0) ":" (cdw[k]+0) ":" (cde[k]+0) ":" cdr[k] }
        for (c in cr) printf "COMP|%s|%d|%d|%d|%d|%s|%s\n", cname(c), ci[c]+0, cw[c]+0, ce[c]+0, cr[c], bk[c], lastlines("C" SUBSEP c)
        tep = tot > 0 ? sprintf("%.1f", (te+0) * 100 / tot) : "0.0"
        printf "TOT|%d|%d|%d|%d|%s|%d\n", tot, ti+0, tw+0, te+0, tep, days+0
    }
' "$CNTF" "$(srv_subset noninfo)")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

IFS='|' read -r _ tot_rec tot_info tot_warn tot_err tot_pct day_count <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# The loglines field is LAST on purpose: log lines contain "|", and the last
# read variable takes the remainder of the line unsplit.
# The row writer prints STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
comp_rows() {
    while IFS='|' read -r _ comp info warn err total bk lines; do
        [ -z "$comp" ] && continue
        # a 0 count shows empty, like the Top view per-day cells (2026-09-30 audit;
        # the Warnings / Errors kinds z-blank themselves)
        [ "$info" = 0 ] && info=""; [ "$total" = 0 ] && total=""
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$comp" "$info" "$warn" "$err" "$total" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep '^COMP|' | sort -t'|' -k6,6nr)"
}

{
    printf 'TITLE\tErrors & Warnings per Component\n'

    printf 'TABLE\tLevels per component\n'
    printf 'HEAD\tComponent\tInfo\tWarnings\tErrors\tRecords\n'
    printf 'KIND\ttext\tnum\tnumwarn\tnumfailed\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\ts3\n'
    comp_rows
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num warn}%s\t@{class=num failed}%s\t@{class=num}%s\n' \
        "$tot_info" "$tot_warn" "$tot_err" "$tot_rec"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($day_count day(s), $tot_err error(s))." >&2
