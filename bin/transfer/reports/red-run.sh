#!/usr/bin/env bash
#
# red-run.sh — the RED RUN of every subscription that is red now by its Files
# (2026-09-30: from-green-to-red.sh + only-red.sh folded into one producer —
# their pages went into Failed Subscriptions 2026-09-29 and their report-format
# .rpt files had no renderer, only three readers taking a few fields).
#
# Writes data/transfer/reports/_red-run.tsv, one line per subscription whose
# LAST File is an Error (Failed or Expired — the outcome policy):
#   1 subscription
#   2 kind     G = went red FROM GREEN (it ended a day on an OK File before;
#                  the former From green to red)
#              N = NEVER delivered an OK File (the former Only red)
#   3 last green day  (G: the last day that ENDED on an OK File; N: "never")
#   4 since    G: the first File of the current failing run (date time) —
#                 the flip moment; N: the first failure (date time)
#   5 days red  the newest File day minus field 4's day (exclusive — the one
#               Days red / Days failing rule since 2026-09-29)
#   6 run      G: consecutive failures (the current run); N: its Files
# A red flow that delivered OK Files but never ENDED a day on one is on
# neither kind (as before: it was on neither page).
#
# Readers: bin/transfer/reports/failed.sh (Failed Subscriptions' Last green
# day · Days red · Failures in a row), bin/day/reports.sh (the per-day
# "went red" / "never delivered" problem lines, field 4 by kind) and
# bin/build/reason-boxes.sh (boxes 2 and 4 of the Reason sidecar).
#
# Source: $FILES (_files.tsv): col 12 subscription, 2 outcome, 4 date, 5 time,
# 6 sortkey, 7 jdn. "Unknown" (no subscription) and undated Files are skipped.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/_red-run.tsv"

# Stream _files.tsv grouped by subscription, chronological inside each group.
# A day "ends green" when its last File that day is OK; the day-end states are
# recorded when the date changes, so the final (red) day never registers as a
# green day.
LC_ALL=C sort -t"$(printf '\t')" -k12,12 -k6,6 "$FILES" | awk -F'\t' -v OFS='\t' '
    function flush() {
        if (site == "" || !lastfail) return
        if (ok == 0)             L[++nl] = site OFS "N" OFS "never" OFS firstfail OFS firstjd OFS fcnt
        else if (greenday != "") L[++nl] = site OFS "G" OFS greenday OFS tailsince OFS tailjd OFS run
    }
    $12 == "" || $12 == "Unknown" || $4 == "" { next }   # "Unknown" = no subscription (2026-09-29)
    {
        if ($12 != site) { flush()
            site = $12; fcnt = 0; ok = 0; run = 0; firstfail = ""; firstjd = 0
            day = ""; dayok = 0; greenday = ""; tailsince = ""; tailjd = 0; lastfail = 0 }
        if ($4 != day) { if (day != "" && dayok) greenday = day; day = $4 }
        fcnt++
        if ($7 + 0 > maxjd) maxjd = $7 + 0
        if ($2 != "Failed" && $2 != "Expired") {
            ok++; run = 0; dayok = 1; lastfail = 0
        } else {
            dayok = 0; lastfail = 1
            if (firstfail == "") { firstfail = $4 " " substr($5, 1, 8); firstjd = $7 + 0 }
            if (run == 0) { tailsince = $4 " " substr($5, 1, 8); tailjd = $7 + 0 }
            run++
        }
    }
    END {
        flush()
        # field 5 = days red: the newest File day minus the run start day
        for (i = 1; i <= nl; i++) { split(L[i], f, OFS); print f[1], f[2], f[3], f[4], maxjd - f[5], f[6] }
    }
' | LC_ALL=C sort > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($(awk -F'\t' '$2 == "G"' "$OUT" | wc -l | tr -d ' ') went red from green, $(awk -F'\t' '$2 == "N"' "$OUT" | wc -l | tr -d ' ') never delivered)." >&2
