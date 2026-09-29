#!/usr/bin/env bash
#
# from-green-to-red.sh — "From green to red" (Failures & Retries group):
# subscriptions that FLIPPED from green to red — their latest File failed
# (state red, the bin/build/result.sh rule), but on an EARLIER day they were green
# (that day ended on an OK File). The regression list: flows that used to
# work and are broken now — excluding the never-green ones (flows that have
# never delivered an OK File; Failure Episodes shows those as "never").
#
# Per qualifying subscription: the last day it ended green, the moment it
# went red (the first failure of the current run), how many days it has been
# red (vs the dataset's end), the consecutive failures since, and its
# lifetime OK/Files counts — with the standard Error/OK drill-downs.
#
# State per the site-wide outcome policy: Waiting counts as OK (green),
# Expired as Error (red). Full-period semantics (`nofilter`, like episodes/
# stale-accounts): the flip is a sequence in time, so narrowing the date
# range would fabricate or hide flips.
#
# Reads data/_files.tsv (1=coreid, 2=outcome, 4=date_iso, 5=time, 6=sortkey,
# 7=jdn, 11=file, 12=dest_site), sorted per subscription. Writes
# data/transfer/reports/from-green-to-red.rpt.
#
# Usage:
#   ./from-green-to-red.sh   # reads input/*.csv (via the cache), writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TRANSFER lib, not the analyses one: this is a transfer-DATA report (it reads
# the transfer caches and writes data/transfer/reports/). It lives HERE
# because it reads the transfer caches (its page, if any, is placed by the one
# Reports menu — _report_groups). bin/transfer/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/from-green-to-red.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Stream _files.tsv grouped by subscription, chronological inside each group.
# A day "ends green" when its last File that day is OK; the day-end states are
# recorded when the date changes, so the final (red) day never registers as a
# green day. Emits pipe-separated (drill lists carry no pipes):
#   S|site|greenday|flipmoment|daysred|run|ok|fails|files|faildrill|okdrill
#   TOT|sites|red|flipped|maxdate
agg=$(LC_ALL=C sort -t"$(printf '\t')" -k12,12 -k6,6 "$FILES" | awk -F'\t' "$COREIDS_AWK"'
    function flush() {
        if (site == "") return
        nsites++
        if (lastfail) {
            nred++
            # never green = red and NEVER one OK File — the Only red definition
            # (2026-09-28 fix: red minus flipped also counted a red flow that
            # did deliver OK Files but never ENDED a day on one, and such a
            # flow is on neither page)
            if (ok == 0) nnever++
            if (greenday != "") {
                nflip++
                L[nflip] = site "|" greenday "|" tailsince "|" tailjd "|" run "|" ok "|" fails "|" fcnt "|" buildlist(top["F" SUBSEP site]) "|" buildlist(top["P" SUBSEP site])
            }
        }
    }
    $12 == "" || $4 == "" { next }
    {
        if ($12 != site) { flush()
            site = $12; fcnt=0; ok=0; fails=0; run=0
            day=""; dayok=0; greenday=""; tailsince=""; tailjd=0; lastfail=0 }
        if ($4 != day) { if (day != "" && dayok) greenday = day; day = $4 }
        fcnt++
        if ($7 + 0 > maxjd) { maxjd = $7 + 0; maxdate = $4 }
        if ($2 != "Failed" && $2 != "Expired") {
            ok++; run = 0; dayok = 1; lastfail = 0
            addtop("P" SUBSEP site, $6, $4 " " $5, $1)
        } else {
            fails++; dayok = 0; lastfail = 1
            if (run == 0) { tailsince = $4 " " substr($5, 1, 8); tailjd = $7 + 0 }
            run++
            addtop("F" SUBSEP site, $6, $4 " " $5, $1)
        }
    }
    END {
        flush()
        for (i = 1; i <= nflip; i++) {
            split(L[i], f, "|")
            printf "S|%s|%s|%s|%d|%s|%s|%s|%s|%s|%s\n", f[1], f[2], f[3], maxjd - f[4], f[5], f[6], f[7], f[8], f[9], f[10]
        }
        printf "TOT|%d|%d|%d|%s|%d\n", nsites+0, nred+0, nflip+0, maxdate, nnever+0
    }
')

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ n_sites n_red n_flip last_date n_never <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
n_rows=0

{
    printf 'TITLE\tFrom green to red\n'
    printf 'DESC\tSubscriptions that flipped from green to red: their latest File failed, but on an earlier day they were green — flows that used to work and are broken now.\n'
    printf 'INTRO\tThe REGRESSION list: of the **%s** subscription(s) with Files, **%s** are **red right now** (latest File Failed or Expired) — and **%s** of those were **green on an earlier day** (that day ended on an OK File). They are listed here, newest flip first; the other **%s** never delivered an OK File at all and belong on the Only red view, not here. Click the Error count for the 10 most recent failed Files, the OK count for the last successful ones.\n' \
        "$n_sites" "$n_red" "$n_flip" "$n_never"
    printf 'TABLE\tSubscriptions now red that were green before\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tLast green day\tWent red on\tDays red\tConsecutive failures\tOK Files\tFiles\n'
    printf 'KIND\tsite\ttext\ttext\tnum\tnumfailed\tnumprocessed\tnum\n'
    # Newest flips first (the freshest regressions are the actionable ones),
    # printed straight into the report — no per-row command substitution.
    while IFS='|' read -r _ site greenday flip daysred run ok fails fcnt fdrill pdrill; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n' \
            "$site" "$greenday" "$flip" "$daysred" "$run" "$ok" "$fcnt" "$fdrill" "$pdrill"
        n_rows=$((n_rows + 1))
    done <<< "$(printf '%s\n' "$agg" | grep '^S|' | LC_ALL=C sort -t'|' -k4,4r -k2,2)"
    # the empty-state row ends its line like every other (2026-09-28 fix: it
    # used to run into the next NOTE/TOTAL line, rendering that text as a cell)
    if [ "$n_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=7}No subscription flipped from green to red — every currently-red subscription has never delivered an OK File (the Only red view lists those).\n'
    fi
    if [ "$n_flip" -gt 0 ]; then
        printf 'TOTAL\tTotal (%s subscriptions)\t\t\t\t\t\t\n' "$n_flip"
    fi
    printf 'NOTE\tA subscription counts as **red** here when its LATEST File'\''s outcome is an Error — Failed or Expired (Waiting counts as OK), the outcome policy; the site-wide subscription colour differs for an Expired last File, which reads ORANGE there. "Last green day" is the most recent day that ENDED on an OK File; "Went red on" is the first failure of the current run (an OK and a failure on the same day leave that day red, so the two can sit days apart). Days red counts to the dataset'\''s last day (%s), not today. OK Files and Files are lifetime counts for the subscription. **This table always shows the full period** — the flip is a sequence in time, so a narrowed From/To range would fabricate or hide flips.\n' "$last_date"
    printf 'SUMMARY\tSubscriptions: %s  |  Red now: %s  |  Flipped from green: %s  |  Never green: %s\n' \
        "$n_sites" "$n_red" "$n_flip" "$n_never"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_flip of $n_red red subscription(s) flipped from green)." >&2
