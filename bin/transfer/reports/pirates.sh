#!/usr/bin/env bash
#
# pirates.sh — "Pirates": logical transfers (CoreIds) that have only ONE leg
# (one technical row in the transfer log). A complete transfer is normally
# store-and-forward — an Inbound leg (the partner → ST) AND an Outbound leg
# (ST → the partner), commonly 2–7 rows. A CoreId with a SINGLE leg is an
# incomplete transfer: one side was logged, the counterpart leg never happened,
# so the file never actually made the full crossing (it ends up Failed).
#
# The Details tab is a per-SUBSCRIPTION rollup — Subscription, Count, First
# date, Last date of its single-leg transfers; the Top view tab counts them
# per day. Reads the shared caches: _files.tsv ($FILES, one row per CoreId;
# col 10 = leg/row count), joined to _transfers.tsv ($PARSED) for the single
# leg's raw Direction (kept in the agg for the per-day Error/OK split).
#
# Usage:
#   ./pirates.sh   # reads input/*.csv (via the caches), writes data/pirates.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TRANSFER lib, not the analyses one: this is a transfer-DATA report (it reads
# the transfer caches and writes data/<env>/transfer/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/transfer/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/pirates.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Per single-leg CoreId, tab-separated:
#   datetime  direction  outcome  account  site  partner  size_bytes  size_human  file  coreid
agg=$(awk -F'\t' '
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? v " " u[i] : sprintf("%.1f %s", v, u[i]) }
    FNR==NR { dir[$1] = $2; next }                 # _transfers.tsv: coreid -> its (single) leg direction
    $10 == 1 {                 # _files.tsv: exactly one leg
        oc = ($2 != "Failed" && $2 != "Expired") ? "OK" : "Error"
        printf "%s %s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n", \
            $4, $5, (($1 in dir) ? dir[$1] : ""), oc, $3, $12, $20, $8, human($8), $11, $1
    }
' "$PARSED" "$FILES")

n_total=$(printf '%s\n' "$agg" | grep -c . || true)

# Per-day counts for the "Top view" tab: date (first token of the datetime) ->
# total, Error, OK. Deterministic (sort by date), newest first.
pd=$(printf '%s\n' "$agg" | awk -F'\t' '
        { split($1, dt, " "); d = dt[1]; if (d == "") next
          c[d]++; if ($3 == "Error") e[d]++; else if ($3 == "OK") o[d]++ }
        END { for (d in c) printf "%s\t%d\t%d\t%d\n", d, c[d], e[d] + 0, o[d] + 0 }' \
    | LC_ALL=C sort -t$'\t' -k1,1r)

{
    printf 'TITLE\tOne-Legged Transfers\n'
    printf 'DESC\tLogical transfers (CoreIds) with only ONE leg — an incomplete, one-sided crossing that never completed.\n'
    printf 'KEYWORDS\tpirates,single leg,one leg,one-sided,incomplete transfer,coreid,orphan,half transfer,per day,count\n'
    printf 'INTRO\t**Pirates** — logical transfers (CoreIds) that have only **one leg** (one technical row). A complete transfer is store-and-forward: an **Inbound** leg (partner → ST) and an **Outbound** leg (ST → partner). A single-leg CoreId is one-sided — the counterpart leg never happened — so the file never made the full crossing. **Details** counts them per subscription; **Top view** the count per day.\n'

    # ---- tab 1: Details — per-subscription rollup of the single-leg transfers ----
    if [ "$n_total" -eq 0 ]; then
        printf 'TABLE\tDetails\tnofilter\tnosort\n'
        printf 'HEAD\tSubscription\tCount\tFirst date\tLast date\n'
        printf 'KIND\tsite\tnum\ttext\ttext\n'
        printf 'ROW\t(none)\t\t\t\n'
    else
        printf 'TABLE\tDetails\n'
        printf 'HEAD\tSubscription\tCount\tFirst date\tLast date\n'
        printf 'KIND\tsite\tnum\ttext\ttext\n'
        # most single-leg transfers first, subscription name as the tiebreaker
        printf '%s\n' "$agg" | awk -F'\t' '
                { s = ($5 == "") ? "(no subscription)" : $5
                  split($1, dt, " "); d = dt[1]
                  c[s]++
                  if (d != "") { if (f[s] == "" || d < f[s]) f[s] = d; if (d > l[s]) l[s] = d } }
                END { for (s in c) printf "%d\t%s\t%s\t%s\n", c[s], s, f[s], l[s] }' \
            | LC_ALL=C sort -t$'\t' -k1,1rn -k2,2 \
            | awk -F'\t' '
                { printf "ROW\t%s\t%s\t%s\t%s\n", $2, $1, $3, $4; t += $1 }
                END { printf "TOTAL\tTotal (%d subscription(s))\t@{class=num}%d\t\t\n", NR, t }'
    fi
    # this NOTE sits between the two tables, so it stays on the Details page only
    printf 'NOTE\tOne row per subscription: how many of its transfers were single-leg, and the first and last date one occurred. Single-leg transfers do not complete the store-and-forward, so they end up **Error**. The Subscription links to its detail page.\n'

    # ---- tab 2: Top view — the count of single-leg transfers per day ----
    if [ -z "$pd" ]; then
        printf 'TABLE\tSingle-leg transfers per day\tnofilter\tnosort\n'
        printf 'HEAD\tDate\tSingle-leg transfers\tError\tOK\n'
        printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\n'
        printf 'ROW\t(none)\t\t\t\n'
    else
        printf 'TABLE\tSingle-leg transfers per day\n'
        printf 'HEAD\tDate\tSingle-leg transfers\tError\tOK\n'
        printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\n'
        printf '%s\n' "$pd" | awk -F'\t' '
            { printf "ROW\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4; t += $2; te += $3; to += $4 }
            END { printf "TOTAL\tTotal (%d day(s))\t@{class=num}%d\t@{class=num failed}%d\t@{class=num processed}%d\n", NR, t, te, to }'
    fi

    printf 'SUMMARY\tSingle-leg (pirate) transfers: %s\n' "$n_total"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_total single-leg transfer(s))." >&2
