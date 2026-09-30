#!/usr/bin/env bash
#
# pirates.sh — "Pirates": logical transfers (CoreIds) that have only ONE leg
# (one technical row in the transfer log). A complete transfer is normally
# store-and-forward — an Inbound leg (the partner → ST) AND an Outbound leg
# (ST → the partner), commonly 2–7 rows. A CoreId with a SINGLE leg is an
# incomplete transfer: one side was logged, the counterpart leg never happened,
# so the file never actually made the full crossing (it ends up Failed).
#
# The Details tab is a per-SUBSCRIPTION rollup — Subscription, One-legged
# Files (drilling to its 10 newest), First date, Last date; the Per day tab
# counts them per day. Reads _files.tsv ($FILES, one row per CoreId; col 10 =
# leg/row count). (2026-09-30 audit: the _transfers.tsv join for the leg
# direction went — nothing read it; the Details count became "One-legged
# Files" with a File drill — the page had no way to reach the Files; the
# Unknown subscription is skipped in Details like every subscription-keyed
# table, the Per day tab still counts it.)
#
# Usage:
#   ./pirates.sh   # reads input/*.csv (via the caches), writes data/pirates.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TRANSFER lib, not the analyses one: this is a transfer-DATA report (it reads
# the transfer caches and writes data/transfer/reports/). It lives HERE
# because it reads the transfer caches (its page, if any, is placed by the one
# Reports menu — _report_groups). bin/transfer/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/pirates.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Per single-leg CoreId, tab-separated:
#   date  time  site  sortkey  coreid
agg=$(awk -F'\t' '
    $10 == 1 {                 # _files.tsv: exactly one leg
        printf "%s\t%s\t%s\t%s\t%s\n", $4, $5, $12, $6, $1
    }
' "$FILES")

n_total=$(printf '%s\n' "$agg" | grep -c . || true)

# Per-day counts for the "Per day" tab: date -> the count. Deterministic (sort
# by date), newest first.
pd=$(printf '%s\n' "$agg" | awk -F'\t' '
        { d = $1; if (d == "") next
          c[d]++ }
        END { for (d in c) printf "%s\t%d\n", d, c[d] }' \
    | LC_ALL=C sort -t$'\t' -k1,1r)

{
    printf 'TITLE\tOne-legged\n'   # = its Reports menu label (2026-09-29)
    printf 'DESC\tFiles (CoreIds) with only ONE leg — an incomplete, one-sided crossing that never completed.\n'

    # ---- tab 1: Details — per-subscription rollup of the single-leg transfers ----
    if [ "$n_total" -eq 0 ]; then
        printf 'TABLE\tDetails\tnofilter\tnosort\n'
        printf 'HEAD\tSubscription\tOne-legged Files\tFirst date\tLast date\n'
        printf 'KIND\tsite\tnumfailed\ttext\ttext\n'
        printf 'ROW\t(none)\t\t\t\n'
    else
        # DATE-AWARE (2026-09-30, user request: every Errors-group page gets
        # the From/To selection; the audit T-03 nofilter of the same morning
        # went): each row carries its per-day counts (@data:buckets) and
        # One-legged Files re-sums for the range (RECALC s0); a subscription
        # with none in the range hides; First / Last date and the drill stay
        # full-period (the site rule)
        printf 'TABLE\tDetails\tdrill=File\n'
        printf 'HEAD\tSubscription\tOne-legged Files\tFirst date\tLast date\n'
        printf 'KIND\tsite\tnumfailed\ttext\ttext\n'
        printf 'RECALC\t-\ts0\t-\t-\n'
        # most one-legged Files first, subscription name as the tiebreaker;
        # the count cell drills to its 10 newest Files (coreids-failed binds
        # the one numfailed cell). "Unknown" = no subscription: skipped here
        # (the Unknown transfers report lists those Files)
        printf '%s\n' "$agg" | awk -F'\t' "$COREIDS_AWK"'
                $3 == "" || $3 == "Unknown" { next }
                { s = $3; d = $1
                  c[s]++
                  if (d != "") { if (f[s] == "" || d < f[s]) f[s] = d; if (d > l[s]) l[s] = d
                                 if (!((s SUBSEP d) in BC)) BD[s] = BD[s] SUBSEP d; BC[s SUBSEP d]++ }
                  addtop(s, $4, $1 " " $2, $5) }
                # the per-day counts in the DATED bucket form (date:count, date order)
                function bkt(s,   n, D, i, j, v, o) {
                    n = split(substr(BD[s], 2), D, SUBSEP)
                    for (i = 2; i <= n; i++) { v = D[i]; j = i - 1; while (j >= 1 && D[j] > v) { D[j + 1] = D[j]; j-- } D[j + 1] = v }
                    o = ""; for (i = 1; i <= n; i++) o = o (i > 1 ? "," : "") D[i] ":" BC[s SUBSEP D[i]]
                    return o }
                END { for (s in c) printf "%d\t%s\t%s\t%s\t%s\t%s\n", c[s], s, f[s], l[s], buildlist(top[s]), bkt(s) }' \
            | LC_ALL=C sort -t$'\t' -k1,1rn -k2,2 \
            | awk -F'\t' '
                { printf "ROW\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:buckets=%s\n", $2, $1, $3, $4, $5, $6; t += $1 }
                END { printf "TOTAL\tTotal (%d subscription(s))\t@{class=num failed}%d\t\t\n", NR, t }'
    fi

    # ---- tab 2: Per day — the one-legged Files per day ("Top view" until
    # 2026-09-30) ----
    # (2026-09-29 audit: "Single-leg transfers" + Error / OK columns — the
    # count is FILES, and a lone leg is Failed by the outcome rule, so Error
    # always equalled the count and OK was always empty: one column now)
    if [ -z "$pd" ]; then
        printf 'TABLE\tOne-legged Files per day\tnofilter\tnosort\n'
        printf 'HEAD\tDate\tOne-legged Files\n'
        printf 'KIND\ttext\tnumfailed\n'
        printf 'ROW\t(none)\t\n'
    else
        printf 'TABLE\tOne-legged Files per day\n'
        printf 'HEAD\tDate\tOne-legged Files\n'
        printf 'KIND\ttext\tnumfailed\n'
        printf '%s\n' "$pd" | awk -F'\t' '
            { printf "ROW\t%s\t%s\n", $1, $2; t += $2 }
            END { printf "TOTAL\tTotal (%d day(s))\t@{class=num failed}%d\n", NR, t }'
    fi

    printf 'SUMMARY\tOne-legged Files: %s\n' "$n_total"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_total one-legged File(s))." >&2
