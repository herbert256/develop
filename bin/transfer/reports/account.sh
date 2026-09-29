#!/usr/bin/env bash
#
# account.sh
#
# Per-account DATA from the logical-transfer cache (data/_files.tsv): ONE
# table, one ROW per logged account — name · Files · Error · OK · the start
# ("date time") of its newest Error File · of its newest OK File. It counts
# Files — one logical transfer per CoreId — split into Error / OK by the
# delivered outcome. NO PAGE of its own: the Entities pages render from
# entities.sh's grouped entities/account.rpt (2026-09-13); this .rpt is read
# by showseen.sh (the names + the two stamps), entity-search.sh (Files /
# Error / OK) and the server rosters (known_names: the ROW names). Its
# existence also gates the Entities page render (bin/transfer/publish.sh).
# (2026-09-29: trimmed to what those readers use — the Retry / Resubmit /
# Volume / First / Last seen columns, the per-day buckets and the drill
# lists had no reader; the "Detail per Account / Date" table went earlier.)
#
# Usage:
#   ./account.sh    # reads input/*.csv (via the caches), writes data/account.rpt
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
OUT="$REPORTS_DIR/account.rpt"

echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ---------------------------------------------------------------------------
# One pass over the logical-transfer cache (data/_files.tsv): 1=coreid,
# 2=outcome, 3=account, 4=date_iso, 5=time, 6=sortkey. Per account: the Files
# count split Error/OK and the start stamp of its NEWEST Error File and NEWEST
# OK File (by sortkey — the first entry the former 10-newest drill lists
# held, which is all showseen.sh read of them).
# Transfers with no account or no valid date are skipped.
# ---------------------------------------------------------------------------
# newest(k, v) keeps the greatest "sortkey SUBSEP date time" per key in LT;
# lastts(k) hands out its "date time" read the way showseen.sh read the first
# entry of a drill list (cut at the first "," and the first double space)
LAST_AWK='
    function newest(k, v) { if (!(k in LT) || v > LT[k]) LT[k] = v }
    function lastts(k,   s, c) { if (!(k in LT)) return ""; s = LT[k]; s = substr(s, index(s, SUBSEP) + 1) "  "
        c = index(s, ","); if (c) s = substr(s, 1, c - 1); c = index(s, "  "); return c ? substr(s, 1, c - 1) : s }
'
agg=$(awk -F'\t' "$LAST_AWK"'
    $3 == "" || $4 == "" { next }
    {
        a = $3; sc[a]++
        if ($2 == "Failed" || $2 == "Expired") { sfl[a]++; newest("F" SUBSEP a, $6 SUBSEP $4 " " $5) }
        else                                   { spr[a]++; newest("P" SUBSEP a, $6 SUBSEP $4 " " $5) }
    }
    END { for (a in sc) printf "S|%s|%d|%d|%d|%s|%s\n", a, sc[a], sfl[a]+0, spr[a]+0, lastts("F" SUBSEP a), lastts("P" SUBSEP a) }
' "$FILES")

# The rows, busiest first (by File count; the ORDER is kept — showseen.sh
# matches configured subscriptions by prefix in this order).
summary_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | sort -t'|' -k3,3nr | awk -F'|' '
    $2 == "" { next }
    { printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, $7 }')

{
    printf 'TITLE\tAccounts\n'
    printf 'TABLE\tSummary per Account\n'
    printf 'HEAD\tAccount\tFiles\tError\tOK\tLast Error\tLast OK\n'
    [ -n "$summary_rows" ] && printf '%s\n' "$summary_rows"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($(printf '%s\n' "$summary_rows" | grep -c '^ROW' || true) account(s))." >&2
