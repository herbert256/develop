#!/usr/bin/env bash
#
# subscription.sh
#
# Per-subscription report — Files per subscription. A subscription is
# a per-row attribute (a transfer has a source subscription and a destination
# subscription), so a transfer is counted once per DISTINCT subscription it
# involves; the per-subscription counts can therefore sum to more than the
# number of distinct transfers. Failed / Processed is the transfer's delivered
# (final-row) outcome and volume is the file counted once. Two tables:
#   - a summary per Subscription (Files, Failed, Processed, Volume, % of
#     Files, First/Last seen) — the same column set as every Entities report
#   - a detail per Subscription / Date (Files, Failed, Processed)
# Clicking a Failed or Processed cell reveals that outcome's 10 most recent
# Files (click-to-expand).
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

ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ---------------------------------------------------------------------------
# Two-pass join. Pass 1 (data/_files.tsv) loads per CoreId the logical
# outcome (2), file size (8), and start date/time/sortkey (4/5/6). Pass 2
# (data/_transfers.tsv) walks the rows; for each distinct (site, CoreId) pair — so
# a transfer is counted at most once per subscription — it accumulates the
# transfer into that subscription using the CoreId's logical facts (see the
# login report for the field layout). Rows with no site (blacklist-blanked) or
# whose transfer has no valid date are skipped.
# ---------------------------------------------------------------------------
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    FNR == 1 { fno++ }
    fno == 1 { oc[$1] = $2; sz[$1] = $8; dt[$1] = $4; tm[$1] = $5; skf[$1] = $6; next }
    fno == 2 { if ($3 != "Processed") fl[$1] = 1; if ($22 == "true") rsb[$1] = 1; next }   # every leg of every File: a Failed leg marks its File (Retry/Resubmit); a Resubmitted=true leg marks the operator resubmit
    $6 == "" { next }
    {
        e = $6; cid = $1; pk = e SUBSEP cid
        if (pk in pseen) next                         # count each transfer once per subscription
        pseen[pk] = 1
        date = dt[cid]; if (date == "") next
        f = (oc[cid] == "Failed" || oc[cid] == "Expired"); sk = skf[cid]; disp = date " " tm[cid]; size = sz[cid] + 0
        cu = (!f && (cid in fl)); rt = (cu && !(cid in rsb)); rs = (cu && (cid in rsb))   # CURED (an OK File that carried a failed leg — the home page rule): RETRY when no leg was resubmitted, RESUBMIT when one was (the Top view Automatic/Manual split)
        sc[e]++; if (f) sfl[e]++; else spr[e]++; if (rt) srt[e]++; if (rs) srs[e]++; sv[e] += size
        if (!(e in havemin) || sk < mink[e]) { mink[e] = sk; fst[e] = date; havemin[e] = 1 }
        if (!(e in havemax) || sk > maxk[e]) { maxk[e] = sk; lst[e] = date; havemax[e] = 1 }
        addtop("S" SUBSEP e SUBSEP (f ? "F" : "P"), sk, disp, cid)
        if (rt) addtop("R" SUBSEP e SUBSEP "T", sk, disp, cid); if (rs) addtop("R" SUBSEP e SUBSEP "S", sk, disp, cid)   # the Retry / Resubmit drill lists, 10 newest each (2026-09-13, user request)
        dk = e SUBSEP date; ds[dk] = 1; dl[dk]++; if (f) dfl[dk]++; else dpr[dk]++; if (rt) drt[dk]++; if (rs) drs[dk]++; ddb[dk] += size
        addtop("D" SUBSEP e SUBSEP date SUBSEP (f ? "F" : "P"), sk, disp, cid)
        if (rt) addtop("Q" SUBSEP e SUBSEP date SUBSEP "T", sk, disp, cid); if (rs) addtop("Q" SUBSEP e SUBSEP date SUBSEP "S", sk, disp, cid)
        tc++; if (f) tfl++; else tpr++; if (rt) trt++; if (rs) trs++; tvol += size
    }
    END {
        for (dk in ds) { split(dk, kk, SUBSEP)
            bk[kk[1]] = bk[kk[1]] (bk[kk[1]] ? "," : "") kk[2] ":" dl[dk] ":" (dfl[dk]+0) ":" (dpr[dk]+0) ":" ddb[dk] ":" (drt[dk]+0) ":" (drs[dk]+0) }
        for (e in sc) { ns++
            sh = tc > 0 ? sprintf("%.1f", sc[e] * 100 / tc) : "0.0"
            printf "S|%s|%d|%d|%d|%d|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", e, sc[e], sfl[e]+0, spr[e]+0, srt[e]+0, srs[e]+0, human(sv[e]+0), sh, fst[e], lst[e], \
                bk[e], buildlist(top["S" SUBSEP e SUBSEP "F"]), buildlist(top["S" SUBSEP e SUBSEP "P"]), buildlist(top["R" SUBSEP e SUBSEP "T"]), buildlist(top["R" SUBSEP e SUBSEP "S"]) }
        for (dk in ds) { split(dk, x, SUBSEP); nd++
            printf "D|%s|%s|%d|%d|%d|%d|%d|%s|%s|%s|%s\n", x[1], x[2], dl[dk], dfl[dk]+0, dpr[dk]+0, drt[dk]+0, drs[dk]+0, \
                buildlist(top["D" SUBSEP x[1] SUBSEP x[2] SUBSEP "F"]), buildlist(top["D" SUBSEP x[1] SUBSEP x[2] SUBSEP "P"]), buildlist(top["Q" SUBSEP x[1] SUBSEP x[2] SUBSEP "T"]), buildlist(top["Q" SUBSEP x[1] SUBSEP x[2] SUBSEP "S"]) }
        printf "T|%d|%d|%d|%s|%d|%d|%d|%d\n", tc+0, tfl+0, tpr+0, human(tvol+0), ns+0, nd+0, trt+0, trs+0
    }
' "$FILES" "$PARSED" "$PARSED")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_records tot_failed tot_processed tot_human summary_row_count detail_row_count tot_retry tot_resub <<< "$(printf '%s\n' "$agg" | grep '^T|')"

# Summary rows, busiest first (by transfer count). ONE awk pass formats the
# sorted stream into finished ROW lines — a bash while-read with a $(printf)
# per row forked a subshell per subscription. The last field takes the line's
# remainder, like read into the final variable did.
summary_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | sort -t'|' -k3,3nr | awk -F'|' '
    $2 == "" { next }
    { ccp = $14   # field 14 = the OK list; 15/16 = the Retry / Resubmit lists (2026-09-13)
      printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\t@data:coreids-retry=%s\t@data:coreids-resubmit=%s\n", \
          $2, $3, $4, $5, $6, $7, $8, $10, $11, $12, $13, ccp, $15, $16 }')

# Detail rows, sorted by subscription then date (repeated site blanked in-browser).
detail_rows=$({ printf '%s\n' "$agg" | grep '^D|' || true; } | sort -t'|' -k2,2 -k3,3 | awk -F'|' '
    $2 == "" { next }
    { ccp = $10   # field 10 = the OK list; 11/12 = the Retry / Resubmit lists (2026-09-13)
      printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\t@data:coreids-retry=%s\t@data:coreids-resubmit=%s\n", \
          $2, $3, $4, $5, $6, $7, $8, $9, ccp, $11, $12 }')

{
    printf 'TITLE\tSubscriptions\n'
    printf 'DESC\tFiles per subscription: a per-subscription summary and a per-day detail, both split into Error/OK.\n'
    printf 'INTRO\tEvery subscription with its **Files** (one per CoreId), Error/OK split (**Retry** / **Resubmit** = the OK Files that needed a retry — a failed leg, then delivered — healed by the platform'\''s own retry or by an operator'\''s resubmit, the log'\''s Resubmitted flag), volume and last sighting. The view tabs switch between the logged subscriptions (**Seen**), the whole configuration (**All** / **Not seen**), the status subsets (**OK** / **Warning** / **Error**) and the server-log-only ones (**Server**); the scope tabs decide whether a server-log sighting counts as seen (**+Server**, the default) or not (**Transfer**) — rows tint by each subscription'\''s status.\n'

    printf 'TABLE\tSummary per Subscription\twide\n'
    printf 'HEAD\tSubscription\tFiles\tError\tOK\tRetry\tResubmit\tVolume\tFirst seen\tLast seen\n'
    printf 'KIND\tsite\tnum\tnumfailed\tnumprocessed\tnumwarn\tnumwarn\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\ts1\ts2\ts4\ts5\th3\t-\t-\n'
    [ -n "$summary_rows" ] && printf '%s\n' "$summary_rows"
    printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num warn}%s\t@{class=num warn}%s\t@{class=num}%s\t\t\n' \
        "$summary_row_count" "$tot_records" "$tot_failed" "$tot_processed" "$tot_retry" "$tot_resub" "$tot_human"

    printf 'TABLE\tDetail per Subscription / Date\tgroup\n'
    printf 'HEAD\tSubscription\tDate\tFiles\tError\tOK\tRetry\tResubmit\n'
    printf 'KIND\tsite\ttext\tnum\tnumfailed\tnumprocessed\tnumwarn\tnumwarn\n'
    [ -n "$detail_rows" ] && printf '%s\n' "$detail_rows"
    printf 'TOTAL\t@{colspan=2}Total (%s row(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num warn}%s\t@{class=num warn}%s\n' \
        "$detail_row_count" "$tot_records" "$tot_failed" "$tot_processed" "$tot_retry" "$tot_resub"

    printf 'NOTE\tCounts Files — one logical transfer each. A transfer is counted once per distinct subscription it involves (a transfer has a source and a destination subscription), so the per-subscription counts can sum to more than the number of distinct transfers. Error/OK is the transfer'\''s delivered outcome; volume is the file counted once. Click an Error or OK count for that outcome'\''s 10 most recent Files (newest first, by start time).\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_records subscription-transfer(s))." >&2
