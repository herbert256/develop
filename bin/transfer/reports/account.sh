#!/usr/bin/env bash
#
# account.sh
#
# Per-account DATA from the logical-transfer cache (data/_files.tsv): ONE
# table, a summary per Account (Files, Error, OK, Retry, Resubmit, Volume,
# First/Last seen, the per-day buckets and the 10-newest drill lists). It
# counts Files — one logical transfer per CoreId — split into Error / OK by the
# delivered outcome. NO PAGE of its own: the Entities pages render from
# entities.sh's grouped entities/account.rpt (2026-09-13); this .rpt is read
# — its FIRST (Summary) table only — by showseen.sh, entity-search.sh and the
# server rosters (known_names). (The "Detail per Account / Date" table went
# 2026-09-29: no reader, ~90% of the file.)
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
# 2=outcome, 3=account, 4=date_iso, 5=time, 6=sortkey, 8=size. Per account keep
# the transfer count split Error/OK, the volume, the first/last seen
# date, the per-date base metrics (count:failed:processed:bytes:retry:resubmit) for the date
# filter, and (via COREIDS_AWK) the 10 most-recent transfers of each outcome for
# the drill-down.
# Transfers with no account or no valid date are skipped.
# ---------------------------------------------------------------------------
agg=$(awk -F'\t' -v PF="$PARSED" "$COREIDS_AWK"'
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    FILENAME == PF { if ($3 != "Processed") fl[$1] = 1; if ($22 == "true") rsb[$1] = 1; next }   # _transfers.tsv first: a Failed leg marks its File (Retry/Resubmit); a Resubmitted=true leg marks the operator resubmit
    $3 == "" || $4 == "" { next }
    {
        a = $3; f = ($2 == "Failed" || $2 == "Expired"); date = $4; sk = $6; disp = $4 " " $5; cid = $1; size = $8
        cu = (!f && (cid in fl)); rt = (cu && !(cid in rsb)); rs = (cu && (cid in rsb))   # CURED (an OK File that carried a failed leg — the home page rule): RETRY when no leg was resubmitted, RESUBMIT when one was (the Top view Automatic/Manual split)
        sc[a]++; if (f) sfl[a]++; else spr[a]++; if (rt) srt[a]++; if (rs) srs[a]++; sv[a] += size
        if (!(a in havemin) || sk < mink[a]) { mink[a] = sk; fst[a] = date; havemin[a] = 1 }
        if (!(a in havemax) || sk > maxk[a]) { maxk[a] = sk; lst[a] = date; havemax[a] = 1 }
        addtop("S" SUBSEP a SUBSEP (f ? "F" : "P"), sk, disp, cid)
        if (rt) addtop("R" SUBSEP a SUBSEP "T", sk, disp, cid); if (rs) addtop("R" SUBSEP a SUBSEP "S", sk, disp, cid)   # the Retry / Resubmit drill lists, 10 newest each (2026-09-13, user request)
        dk = a SUBSEP date; ds[dk] = 1; dl[dk]++; if (f) dfl[dk]++; else dpr[dk]++; if (rt) drt[dk]++; if (rs) drs[dk]++; ddb[dk] += size
        tc++; if (f) tfl++; else tpr++; if (rt) trt++; if (rs) trs++; tvol += size
    }
    END {
        for (dk in ds) { split(dk, kk, SUBSEP)
            bk[kk[1]] = bk[kk[1]] (bk[kk[1]] ? "," : "") kk[2] ":" dl[dk] ":" (dfl[dk]+0) ":" (dpr[dk]+0) ":" ddb[dk] ":" (drt[dk]+0) ":" (drs[dk]+0) }
        for (a in sc) { ns++
            sh = tc > 0 ? sprintf("%.1f", sc[a] * 100 / tc) : "0.0"
            printf "S|%s|%d|%d|%d|%d|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", a, sc[a], sfl[a]+0, spr[a]+0, srt[a]+0, srs[a]+0, human(sv[a]+0), sh, fst[a], lst[a], \
                bk[a], buildlist(top["S" SUBSEP a SUBSEP "F"]), buildlist(top["S" SUBSEP a SUBSEP "P"]), buildlist(top["R" SUBSEP a SUBSEP "T"]), buildlist(top["R" SUBSEP a SUBSEP "S"]) }
        printf "T|%d|%d|%d|%s|%d|%d|%d\n", tc+0, tfl+0, tpr+0, human(tvol+0), ns+0, trt+0, trs+0
    }
' "$PARSED" "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_records tot_failed tot_processed tot_human summary_row_count tot_retry tot_resub <<< "$(printf '%s\n' "$agg" | grep '^T|')"

# Summary rows, busiest first (by transfer count). ONE awk pass formats the
# sorted stream into finished ROW lines — a bash while-read with a $(printf)
# per row forked a subshell per account. The last field takes the line's
# remainder, like read into the final variable did.
summary_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | sort -t'|' -k3,3nr | awk -F'|' '
    $2 == "" { next }
    { ccp = $14   # field 14 = the OK list; 15/16 = the Retry / Resubmit lists (2026-09-13)
      printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\t@data:coreids-retry=%s\t@data:coreids-resubmit=%s\n", \
          $2, $3, $4, $5, $6, $7, $8, $10, $11, $12, $13, ccp, $15, $16 }')

{
    printf 'TITLE\tAccounts\n'
    printf 'DESC\tFiles per account, split into Error/OK.\n'
    printf 'INTRO\tEvery account with its **Files** (one per CoreId), Error/OK split (**Retry** / **Resubmit** = the OK Files that needed a retry — a failed leg, then delivered — healed by the platform'\''s own retry or by an operator'\''s resubmit, the log'\''s Resubmitted flag), volume and last sighting. The view tabs switch between the logged accounts (**Seen**), the whole configuration (**All** / **Not seen**) and the status subsets (**OK** / **Warning** / **Error**) — rows tint by each account'\''s status.\n'

    printf 'TABLE\tSummary per Account\twide\n'
    printf 'HEAD\tAccount\tFiles\tError\tOK\tRetry\tResubmit\tVolume\tFirst seen\tLast seen\n'
    printf 'KIND\tacct\tnum\tnumfailed\tnumprocessed\tnumwarn\tnumwarn\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\ts1\ts2\ts4\ts5\th3\t-\t-\n'
    [ -n "$summary_rows" ] && printf '%s\n' "$summary_rows"
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num}%s\t\t\n' \
        "$summary_row_count" "$tot_records" "$tot_failed" "$tot_processed" "$tot_retry" "$tot_resub" "$tot_human"

    printf 'NOTE\tCounts Files — one logical transfer each; volume is the file counted once. First/Last seen stay full-period under the date filter. Click an Error or OK count for that outcome'\''s 10 most recent Files (newest first, by start time).\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_records transfer(s))." >&2
