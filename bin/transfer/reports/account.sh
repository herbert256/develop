#!/usr/bin/env bash
#
# account.sh
#
# Per-account report from the logical-transfer cache (data/_files.tsv):
#   - a summary per Account (Files, Failed, Processed, Volume, % of
#     Files, First/Last seen) — the same column set as every Entities report
#   - a detail per Account / Date (Files, Failed, Processed)
# Both tables count Files — one logical transfer per CoreId — split into Failed /
# Processed by the delivered outcome; clicking a Failed or Processed cell reveals
# that outcome's 10 most recent Files (click-to-expand).
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

ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ---------------------------------------------------------------------------
# One pass over the logical-transfer cache (data/_files.tsv): 1=coreid,
# 2=outcome, 3=account, 4=date_iso, 5=time, 6=sortkey, 8=size. Per account keep
# the transfer count split Error/OK, the volume, the first/last seen
# date, the per-date base metrics (count:failed:processed:bytes) for the date
# filter, and (via COREIDS_AWK) the 10 most-recent transfers of each outcome for
# the drill-down — both summary (per account) and detail (per account/day).
# Transfers with no account or no valid date are skipped.
# ---------------------------------------------------------------------------
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    $3 == "" || $4 == "" { next }
    {
        a = $3; f = ($2 == "Failed" || $2 == "Expired"); date = $4; sk = $6; disp = $4 " " $5; cid = $1; size = $8
        sc[a]++; if (f) sfl[a]++; else spr[a]++; sv[a] += size
        if (!(a in havemin) || sk < mink[a]) { mink[a] = sk; fst[a] = date; havemin[a] = 1 }
        if (!(a in havemax) || sk > maxk[a]) { maxk[a] = sk; lst[a] = date; havemax[a] = 1 }
        addtop("S" SUBSEP a SUBSEP (f ? "F" : "P"), sk, disp, cid)
        dk = a SUBSEP date; ds[dk] = 1; dl[dk]++; if (f) dfl[dk]++; else dpr[dk]++; ddb[dk] += size
        addtop("D" SUBSEP a SUBSEP date SUBSEP (f ? "F" : "P"), sk, disp, cid)
        tc++; if (f) tfl++; else tpr++; tvol += size
    }
    END {
        for (dk in ds) { split(dk, kk, SUBSEP)
            bk[kk[1]] = bk[kk[1]] (bk[kk[1]] ? "," : "") kk[2] ":" dl[dk] ":" (dfl[dk]+0) ":" (dpr[dk]+0) ":" ddb[dk] }
        for (a in sc) { ns++
            sh = tc > 0 ? sprintf("%.1f", sc[a] * 100 / tc) : "0.0"
            printf "S|%s|%d|%d|%d|%s|%s|%s|%s|%s|%s|%s\n", a, sc[a], sfl[a]+0, spr[a]+0, human(sv[a]+0), sh, fst[a], lst[a], \
                bk[a], buildlist(top["S" SUBSEP a SUBSEP "F"]), buildlist(top["S" SUBSEP a SUBSEP "P"]) }
        for (dk in ds) { split(dk, x, SUBSEP); nd++
            printf "D|%s|%s|%d|%d|%d|%s|%s\n", x[1], x[2], dl[dk], dfl[dk]+0, dpr[dk]+0, \
                buildlist(top["D" SUBSEP x[1] SUBSEP x[2] SUBSEP "F"]), buildlist(top["D" SUBSEP x[1] SUBSEP x[2] SUBSEP "P"]) }
        printf "T|%d|%d|%d|%s|%d|%d\n", tc+0, tfl+0, tpr+0, human(tvol+0), ns+0, nd+0
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_records tot_failed tot_processed tot_human summary_row_count detail_row_count <<< "$(printf '%s\n' "$agg" | grep '^T|')"

# Summary rows, busiest first (by transfer count). ONE awk pass formats the
# sorted stream into finished ROW lines — a bash while-read with a $(printf)
# per row forked a subshell per account. The last field takes the line's
# remainder, like read into the final variable did.
summary_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | sort -t'|' -k3,3nr | awk -F'|' '
    $2 == "" { next }
    { ccp = $12; for (i = 13; i <= NF; i++) ccp = ccp "|" $i
      printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
          $2, $3, $4, $5, $6, $8, $9, $10, $11, ccp }')

# Detail rows, sorted by account then date (repeated account blanked in-browser).
detail_rows=$({ printf '%s\n' "$agg" | grep '^D|' || true; } | sort -t'|' -k2,2 -k3,3 | awk -F'|' '
    $2 == "" { next }
    { ccp = $8; for (i = 9; i <= NF; i++) ccp = ccp "|" $i
      printf "ROW\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
          $2, $3, $4, $5, $6, $7, ccp }')

{
    printf 'TITLE\tAccounts\n'
    printf 'DESC\tFiles per account: a per-account summary and a per-day detail, both split into Error/OK.\n'
    printf 'INTRO\tEvery account with its **Files** (one per CoreId), Error/OK split, volume and last sighting. The view tabs switch between the logged accounts (**Seen**), the whole configuration (**All** / **Not seen**), the status subsets (**OK** / **Warning** / **Error**) and the server-log-only ones (**Server**); the scope tabs decide whether a server-log sighting counts as seen (**+Server**, the default) or not (**Transfer**) — rows tint by each account'\''s status.\n'

    printf 'TABLE\tSummary per Account\twide\n'
    printf 'HEAD\tAccount\tFiles\tError\tOK\tVolume\tFirst seen\tLast seen\n'
    printf 'KIND\tacct\tnum\tnumfailed\tnumprocessed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\ts1\ts2\th3\t-\t-\n'
    [ -n "$summary_rows" ] && printf '%s\n' "$summary_rows"
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t\t\n' \
        "$summary_row_count" "$tot_records" "$tot_failed" "$tot_processed" "$tot_human"

    printf 'TABLE\tDetail per Account / Date\tgroup\n'
    printf 'HEAD\tAccount\tDate\tFiles\tError\tOK\n'
    printf 'KIND\tacct\ttext\tnum\tnumfailed\tnumprocessed\n'
    [ -n "$detail_rows" ] && printf '%s\n' "$detail_rows"
    printf 'TOTAL\t@{colspan=2}Total (%s row(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\n' \
        "$detail_row_count" "$tot_records" "$tot_failed" "$tot_processed"

    printf 'NOTE\tCounts Files — one logical transfer each; volume is the file counted once. First/Last seen stay full-period under the date filter. Click an Error or OK count for that outcome'\''s 10 most recent Files (newest first, by start time).\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_records transfer(s))." >&2
