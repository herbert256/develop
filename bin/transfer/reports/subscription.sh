#!/usr/bin/env bash
#
# subscription.sh
#
# Per-subscription report — Files per subscription. A subscription is
# a per-row attribute (a transfer has a source subscription and a destination
# subscription), so a transfer is counted once per DISTINCT subscription it
# involves; the per-subscription counts can therefore sum to more than the
# number of distinct transfers. Failed / Processed is the transfer's delivered
# (final-row) outcome. ONE table, one ROW per subscription — the account.sh
# record (name · Files · Error · OK · newest Error / OK File start; trimmed
# 2026-09-29 to what its readers use). NO PAGE of its own: the Entities pages
# render from entities.sh's grouped entities/subscription.rpt (2026-09-13);
# this .rpt is the authoritative subscription ROSTER — read (its
# FIRST/Summary table, or just the ROW names) by showseen.sh (names + the two
# stamps), entity-search.sh (Files / Error / OK, ROW fields 3-5) and the
# server reports (the names). (The "Detail per
# Subscription / Date" table went 2026-09-29: no reader.)
#
# UI note: the Transfer Site entity is displayed as "Subscription".
#
# Usage:
#   ./subscription.sh    # reads input/*.csv (via the caches), writes data/subscription.rpt
#
# Requirements: bash, awk (mawk/gawk/POSIX awk all work), sort.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi

mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/subscription.rpt"

echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ---------------------------------------------------------------------------
# Two-pass join. Pass 1 (data/_files.tsv) loads per dated CoreId the logical
# outcome (2) and its start as "sortkey SUBSEP date time" (6, 4 5). Pass 2
# (data/_transfers.tsv) walks the rows; for each distinct (site, CoreId) pair —
# so a transfer is counted at most once per subscription — it counts the File
# into that subscription, split Error/OK by the delivered outcome, and keeps
# the newest Error / OK File start (see account.sh for the record). Rows with
# no site (blacklist-blanked) or whose transfer has no valid date are skipped.
# ---------------------------------------------------------------------------
LAST_AWK='
    function newest(k, v) { if (!(k in LT) || v > LT[k]) LT[k] = v }
    function lastts(k,   s, c) { if (!(k in LT)) return ""; s = LT[k]; s = substr(s, index(s, SUBSEP) + 1) "  "
        c = index(s, ","); if (c) s = substr(s, 1, c - 1); c = index(s, "  "); return c ? substr(s, 1, c - 1) : s }
'
agg=$(awk -F'\t' "$LAST_AWK"'
    FNR == 1 { fno++ }
    fno == 1 { if ($4 != "") { fe[$1] = ($2 == "Failed" || $2 == "Expired"); fk[$1] = $6 SUBSEP $4 " " $5 }; next }
    $6 == "" || $6 == "Unknown" { next }   # "Unknown" = no subscription (2026-09-29)
    {
        e = $6; cid = $1; pk = e SUBSEP cid
        if (pk in pseen) next                         # count each transfer once per subscription
        pseen[pk] = 1
        if (!(cid in fk)) next                        # no File or no valid date
        sc[e]++
        if (fe[cid]) { sfl[e]++; newest("F" SUBSEP e, fk[cid]) } else { spr[e]++; newest("P" SUBSEP e, fk[cid]) }
    }
    END { for (e in sc) printf "S|%s|%d|%d|%d|%s|%s\n", e, sc[e], sfl[e]+0, spr[e]+0, lastts("F" SUBSEP e), lastts("P" SUBSEP e) }
' "$FILES" "$PARSED")

# The rows, busiest first (by File count; the ORDER is kept — showseen.sh
# matches the configured subscriptions by prefix in this order).
summary_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | sort -t'|' -k3,3nr | awk -F'|' '
    $2 == "" { next }
    { printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, $7 }')

{
    printf 'TITLE\tSubscriptions\n'
    printf 'TABLE\tSummary per Subscription\n'
    printf 'HEAD\tSubscription\tFiles\tError\tOK\tLast Error\tLast OK\n'
    [ -n "$summary_rows" ] && printf '%s\n' "$summary_rows"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($(printf '%s\n' "$summary_rows" | grep -c '^ROW' || true) subscription(s))." >&2
