#!/usr/bin/env bash
#
# login.sh
#
# Per-login report — Files per login. A login is a per-row attribute
# (the Inbound and Outbound rows of a transfer may log different logins), so a
# transfer is counted once per DISTINCT login it involves; the per-login counts
# can therefore sum to more than the number of distinct transfers. Failed /
# Processed is the transfer's delivered (final-row) outcome and volume is the
# file counted once. Two tables:
#   - a summary per Login (Files, Failed, Processed, Volume, % of Files,
#     First/Last seen) — the same column set as every Entities report
#   - a detail per Login / Date (Files, Failed, Processed)
# Clicking a Failed or Processed cell reveals that outcome's 10 most recent
# Files (click-to-expand).
#
# Usage:
#   ./login.sh    # reads input/*.csv (via the caches), writes data/login.rpt
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
OUT="$REPORTS_DIR/login.rpt"

ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ---------------------------------------------------------------------------
# Two-pass join. Pass 1 (data/_files.tsv) loads per CoreId the logical
# outcome (2), file size (8), and start date/time/sortkey (4/5/6). Pass 2
# (data/_transfers.tsv) walks the rows; for each distinct (login, CoreId) pair —
# so a transfer is counted at most once per login — it accumulates the transfer
# into that login using the CoreId's logical facts: count split Error/OK
# by the delivered outcome, volume (file counted once), first/last seen date,
# per-date base metrics for the date filter, and (via COREIDS_AWK) the 10
# most-recent transfers of each outcome for the drill-down (summary and detail).
# Rows with no login (blacklist-blanked) or whose transfer has no valid date are
# skipped.
# ---------------------------------------------------------------------------
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    NR == FNR { oc[$1] = $2; sz[$1] = $8; dt[$1] = $4; tm[$1] = $5; skf[$1] = $6; next }
    $5 == "" { next }
    {
        e = $5; cid = $1; pk = e SUBSEP cid
        if (pk in pseen) next                         # count each transfer once per login
        pseen[pk] = 1
        date = dt[cid]; if (date == "") next
        f = (oc[cid] == "Failed" || oc[cid] == "Expired"); sk = skf[cid]; disp = date " " tm[cid]; size = sz[cid] + 0
        sc[e]++; if (f) sfl[e]++; else spr[e]++; sv[e] += size
        if (!(e in havemin) || sk < mink[e]) { mink[e] = sk; fst[e] = date; havemin[e] = 1 }
        if (!(e in havemax) || sk > maxk[e]) { maxk[e] = sk; lst[e] = date; havemax[e] = 1 }
        addtop("S" SUBSEP e SUBSEP (f ? "F" : "P"), sk, disp, cid)
        dk = e SUBSEP date; ds[dk] = 1; dl[dk]++; if (f) dfl[dk]++; else dpr[dk]++; ddb[dk] += size
        addtop("D" SUBSEP e SUBSEP date SUBSEP (f ? "F" : "P"), sk, disp, cid)
        tc++; if (f) tfl++; else tpr++; tvol += size
    }
    END {
        for (dk in ds) { split(dk, kk, SUBSEP)
            bk[kk[1]] = bk[kk[1]] (bk[kk[1]] ? "," : "") kk[2] ":" dl[dk] ":" (dfl[dk]+0) ":" (dpr[dk]+0) ":" ddb[dk] }
        for (e in sc) { ns++
            sh = tc > 0 ? sprintf("%.1f", sc[e] * 100 / tc) : "0.0"
            printf "S|%s|%d|%d|%d|%s|%s|%s|%s|%s|%s|%s\n", e, sc[e], sfl[e]+0, spr[e]+0, human(sv[e]+0), sh, fst[e], lst[e], \
                bk[e], buildlist(top["S" SUBSEP e SUBSEP "F"]), buildlist(top["S" SUBSEP e SUBSEP "P"]) }
        for (dk in ds) { split(dk, x, SUBSEP); nd++
            printf "D|%s|%s|%d|%d|%d|%s|%s\n", x[1], x[2], dl[dk], dfl[dk]+0, dpr[dk]+0, \
                buildlist(top["D" SUBSEP x[1] SUBSEP x[2] SUBSEP "F"]), buildlist(top["D" SUBSEP x[1] SUBSEP x[2] SUBSEP "P"]) }
        printf "T|%d|%d|%d|%s|%d|%d\n", tc+0, tfl+0, tpr+0, human(tvol+0), ns+0, nd+0
    }
' "$FILES" "$PARSED")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_records tot_failed tot_processed tot_human summary_row_count detail_row_count <<< "$(printf '%s\n' "$agg" | grep '^T|')"

# Summary rows, busiest first (by transfer count). ONE awk pass formats the
# sorted stream into finished ROW lines — a bash while-read with a $(printf)
# per row forked a subshell per login. The last field takes the line's
# remainder, like read into the final variable did.
summary_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | sort -t'|' -k3,3nr | awk -F'|' '
    $2 == "" { next }
    { ccp = $12; for (i = 13; i <= NF; i++) ccp = ccp "|" $i
      printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
          $2, $3, $4, $5, $6, $8, $9, $10, $11, ccp }')

# Detail rows, sorted by login then date (repeated login blanked in-browser).
detail_rows=$({ printf '%s\n' "$agg" | grep '^D|' || true; } | sort -t'|' -k2,2 -k3,3 | awk -F'|' '
    $2 == "" { next }
    { ccp = $8; for (i = 9; i <= NF; i++) ccp = ccp "|" $i
      printf "ROW\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
          $2, $3, $4, $5, $6, $7, ccp }')

{
    printf 'TITLE\tLogins\n'
    printf 'DESC\tFiles per login: a per-login summary and a per-day detail, both split into Error/OK.\n'
    printf 'INTRO\tEvery login with its **Files** (one per CoreId), Error/OK split, volume and last sighting. The view tabs switch between the logged logins (**Seen**), the whole configuration (**All** / **Not seen**), the status subsets (**OK** / **Warning** / **Error**) and the server-log-only ones (**Server**); the scope tabs decide whether a server-log sighting counts as seen (**+Server**, the default) or not (**Transfer**) — rows tint by each login'\''s status.\n'

    printf 'TABLE\tSummary per login\twide\n'
    printf 'HEAD\tLogin\tFiles\tError\tOK\tVolume\tFirst seen\tLast seen\n'
    printf 'KIND\tlogin\tnum\tnumfailed\tnumprocessed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\ts1\ts2\th3\t-\t-\n'
    [ -n "$summary_rows" ] && printf '%s\n' "$summary_rows"
    printf 'TOTAL\tTotal (%s login(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t\t\n' \
        "$summary_row_count" "$tot_records" "$tot_failed" "$tot_processed" "$tot_human"

    printf 'TABLE\tDetail per login / day\tgroup\n'
    printf 'HEAD\tLogin\tDate\tFiles\tError\tOK\n'
    printf 'KIND\tlogin\ttext\tnum\tnumfailed\tnumprocessed\n'
    [ -n "$detail_rows" ] && printf '%s\n' "$detail_rows"
    printf 'TOTAL\t@{colspan=2}Total (%s row(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\n' \
        "$detail_row_count" "$tot_records" "$tot_failed" "$tot_processed"

    printf 'NOTE\tCounts Files — one logical transfer each. A transfer is counted once per distinct login it involves (its Inbound and Outbound rows may log different logins), so the per-login counts can sum to more than the number of distinct transfers. Error/OK is the transfer'\''s delivered outcome; volume is the file counted once. Click an Error or OK count for that outcome'\''s 10 most recent Files (newest first, by start time).\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_records login-transfer(s))." >&2
