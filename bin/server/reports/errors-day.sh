#!/usr/bin/env bash
#
# errors-day.sh — server-log health per day and per component: record counts
# split by Level (Info / Warning / Error) with the error rate per day, plus a
# component x level breakdown. Reads the parse cache (data/_parse.tsv:
# 1=date, 2=time, 3=level letter, 4=component letter, 5=message).
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
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the cache (1=date, 2=time, 3=level, 4=component, 5=message):
# per-day level counts, per-component level counts (+ per-day buckets so the
# component table re-aggregates under the date filter).
# Emits: DAY|date|recs|info|warn|err|errpct  COMP|comp|info|warn|err|total|buckets
#        TOT|recs|info|warn|err|errpct|days
agg=$(awk -F'\t' "$LOGLINES_AWK"'
    function cname(x) {
        if (x == "T") return "TM"
        if (x == "P") return "PESITD"
        if (x == "S") return "SSHD"
        return x
    }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        lv = $3; cp = $4
        tot++; if (lv == "I") ti++; else if (lv == "W") tw++; else if (lv == "E") te++
        cr[cp]++
        if (lv == "I") ci[cp]++; else if (lv == "W") cw[cp]++; else if (lv == "E") ce[cp]++
        if (lv != "I" && d != "") {                  # drill-down: last warn/error lines per day + component
            addline("D" SUBSEP d, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
            addline("C" SUBSEP cp, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
        }
        if (d != "") {
            if (!(d in dseen)) { dseen[d] = 1; days++ }
            dr[d]++
            if (lv == "I") di[d]++; else if (lv == "W") dw[d]++; else if (lv == "E") de[d]++
            cdr[cp SUBSEP d]++
            if (lv == "I") cdi[cp SUBSEP d]++; else if (lv == "W") cdw[cp SUBSEP d]++; else if (lv == "E") cde[cp SUBSEP d]++
        }
    }
    END {
        for (k in cdr) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" (cdi[k]+0) ":" (cdw[k]+0) ":" (cde[k]+0) ":" cdr[k] }
        for (d in dseen) {
            ep = dr[d] > 0 ? sprintf("%.1f", (de[d]+0) * 100 / dr[d]) : "0.0"
            printf "DAY|%s|%d|%d|%d|%d|%s|%s\n", d, dr[d], di[d]+0, dw[d]+0, de[d]+0, ep, lastlines("D" SUBSEP d)
        }
        for (c in cr) printf "COMP|%s|%d|%d|%d|%d|%s|%s\n", cname(c), ci[c]+0, cw[c]+0, ce[c]+0, cr[c], bk[c], lastlines("C" SUBSEP c)
        tep = tot > 0 ? sprintf("%.1f", (te+0) * 100 / tot) : "0.0"
        printf "TOT|%d|%d|%d|%d|%s|%d\n", tot, ti+0, tw+0, te+0, tep, days+0
    }
' "$PARSED")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

IFS='|' read -r _ tot_rec tot_info tot_warn tot_err tot_pct day_count <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# The loglines field is LAST on purpose: log lines contain "|", and the last
# read variable takes the remainder of the line unsplit.
# Both row writers print STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
day_rows() {
    while IFS='|' read -r _ d recs info warn err ep lines; do
        [ -z "$d" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s%%\t@data:loglines=%s\n' "$d" "$recs" "$info" "$warn" "$err" "$ep" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep '^DAY|' | sort -t'|' -k2,2)"
}

comp_rows() {
    while IFS='|' read -r _ comp info warn err total bk lines; do
        [ -z "$comp" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$comp" "$info" "$warn" "$err" "$total" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep '^COMP|' | sort -t'|' -k6,6nr)"
}

{
    printf 'TITLE\tErrors & Warnings per Day\n'
    printf 'DESC\tServer-log records by level (Info/Warning/Error) per day and per component, with the error rate.\n'
    # META lines (not rendered) feed the root-index KPI strip in bin/build/publish.sh.
    printf 'META\terrors\t%s\n' "$tot_err"
    printf 'META\trecords\t%s\n' "$tot_rec"
    printf 'INTRO\t**%s** records across **%s** day(s): **%s** errors (**%s%%**), **%s** warnings. The per-day error rate surfaces bad days; the component table shows where the noise comes from.\n' \
        "$tot_rec" "$day_count" "$tot_err" "$tot_pct" "$tot_warn"

    printf 'TABLE\tLevels per day\tpct=5:4:1\n'
    printf 'HEAD\tDate\tRecords\tInfo\tWarnings\tErrors\tError %%\n'
    printf 'KIND\ttext\tnum\tnum\tnumwarn\tnumfailed\tnum\n'
    day_rows
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num warn}%s\t@{class=num failed}%s\t@{class=num}%s%%\n' \
        "$day_count" "$tot_rec" "$tot_info" "$tot_warn" "$tot_err" "$tot_pct"

    printf 'TABLE\tLevels per component\n'
    printf 'HEAD\tComponent\tInfo\tWarnings\tErrors\tRecords\n'
    printf 'KIND\ttext\tnum\tnumwarn\tnumfailed\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\ts3\n'
    comp_rows
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num warn}%s\t@{class=num failed}%s\t@{class=num}%s\n' \
        "$tot_info" "$tot_warn" "$tot_err" "$tot_rec"

    printf 'NOTE\tComponents: TM (transaction manager), PESITD, SSHD. Levels other than Info/Warning/Error (none expected) are counted in Records only. Click a row to expand its 10 most recent warning/error lines.\n'
    printf 'SUMMARY\tRecords: %s  |  Errors: %s (%s%%)  |  Warnings: %s\n' "$tot_rec" "$tot_err" "$tot_pct" "$tot_warn"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($day_count day(s), $tot_err error(s))." >&2
