#!/usr/bin/env bash
#
# volume.sh
# Reports the DATA VOLUME (bytes, from the "Size" column, field 19) moved through
# the Axway FlowManager transfer logs — per day, per direction, and the top
# accounts by volume. Record counts are shown alongside for context.
#
# Usage:
#   ./volume.sh    # reads every *.csv in input/, writes output/volume.html
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/volume-src.rpt"

TOP_N=25   # how many accounts to list in the "top accounts by volume" table


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Logical volume from _files.tsv — the file counted ONCE per transfer
# (3=account, 4=date_iso, 8=size). Emits DAY|date|transfers|bytes|human,
# ACC|account|transfers|bytes|human|share, TOT|transfers|bytes|human.
aggt=$(awk -F'\t' '
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i])
    }
    function share(x) { return tbytes > 0 ? sprintf("%.1f", x * 100 / tbytes) : "0.0" }
    $4 == "" { next }
    { acct = ($3 == "") ? "(no account)" : $3; day = $4; size = $8
      dayrec[day]++; daybytes[day] += size
      accrec[acct]++; accbytes[acct] += size
      trec++; tbytes += size
      acd[acct SUBSEP day]++; acb[acct SUBSEP day] += size }
    END {
        for (k in acd) { split(k, a, SUBSEP); abk[a[1]] = abk[a[1]] (abk[a[1]] ? "," : "") a[2] ":" acd[k] ":" acb[k] }
        for (k in dayrec) printf "DAY|%s|%d|%d|%s\n", k, dayrec[k], daybytes[k], human(daybytes[k])
        for (k in accrec) printf "ACC|%s|%d|%d|%s|%s|%s\n", k, accrec[k], accbytes[k], human(accbytes[k]), share(accbytes[k]), abk[k]
        printf "TOT|%d|%d|%s\n", trec, tbytes, human(tbytes)
    }
' "$FILES")

# Per-row volume by direction from _transfers.tsv — each row counted (a transfer
# moves its file IN then OUT), so this totals ~2x the logical file volume.
aggl=$(awk -F'\t' "$COREIDS_AWK"'
    function human(b,   u, i, v) {
        split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i])
    }
    { dir = $2; if (dir == "") dir = "UNKNOWN"; size = $9; d = $11
      status = $3; sub(/ Subtransmission$/, "", status); f = (status != "Processed"); oc = f ? "F" : "P"
      dirrow[dir]++; dirbytes[dir] += size; tb += size; if (f) dirf[dir]++; else dirp[dir]++; tf += f; tp += (!f)
      addtop(dir SUBSEP oc, $13, $11 " " $12, $23)
      if (d != "") { dld[dir SUBSEP d]++; dlf[dir SUBSEP d] += f; dlp[dir SUBSEP d] += (!f); dlb[dir SUBSEP d] += size } }
    END {
        for (k in dld) { split(k, a, SUBSEP); dbk[a[1]] = dbk[a[1]] (dbk[a[1]] ? "," : "") a[2] ":" dld[k] ":" (dlf[k]+0) ":" (dlp[k]+0) ":" dlb[k] }
        for (k in dirrow) printf "DIR|%s|%d|%d|%d|%d|%s|%s|%s|%s|%s\n", k, dirrow[k], dirf[k]+0, dirp[k]+0, dirbytes[k], human(dirbytes[k]), (tb > 0 ? sprintf("%.1f", dirbytes[k] * 100 / tb) : "0.0"), dbk[k], buildlist(top[k SUBSEP "F"]), buildlist(top[k SUBSEP "P"])
        printf "LTOT|%d|%d|%d|%s\n", tb, tf+0, tp+0, human(tb)
    }
' "$PARSED")

# No emptiness guard on $aggt: the awk END always emits the TOT| line, so it
# is never empty — an empty dataset still renders a page with zero counts.

IFS='|' read -r _ tot_rec tot_bytes tot_human <<< "$(printf '%s\n' "$aggt" | grep '^TOT|')"
IFS='|' read -r _ row_bytes row_failed row_processed row_human <<< "$(printf '%s\n' "$aggl" | grep '^LTOT|')"
row_rows=$((row_failed + row_processed))
day_count=$(printf '%s\n' "$aggt" | grep -c '^DAY|' || true)

{
    printf 'TITLE\tTransfer Volume\n'
    printf 'DESC\tData volume moved per day and top accounts (Files), plus a per-transfer direction split.\n'
    printf 'INTRO\tTotal volume: **%s** across **%s** Files (%s day(s)) — the file counted once per File.\n' \
        "$tot_human" "$tot_rec" "$day_count"

    printf 'TABLE\tVolume per day\n'
    printf 'HEAD\tDate\tFiles\tVolume\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf '%s\n' "$aggt" | { grep '^DAY|' || true; } | sort -t'|' -k2,2 | while IFS='|' read -r _ day rec bytes human; do
        printf 'ROW\t%s\t%s\t%s\n' "$day" "$rec" "$human"
    done
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num}%s\t@{class=num}%s\n' "$day_count" "$tot_rec" "$tot_human"

    printf 'TABLE\tVolume by direction\tdrill=transfer\n'
    printf 'HEAD\tDirection\tTransfers\tError\tOK\tVolume\t%% of volume\n'
    printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\th3\t%%3\n'
    printf '%s\n' "$aggl" | { grep '^DIR|' || true; } | sort -t'|' -k6,6 -rn | while IFS='|' read -r _ dir rows failed processed bytes human pct bk ccf ccp; do
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n' "$dir" "$rows" "$failed" "$processed" "$human" "$pct" "$bk" "$ccf" "$ccp"
    done
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num}100.0%%\n' "$row_rows" "$row_failed" "$row_processed" "$row_human"
    printf 'NOTE\tThis table counts technical transfers (rows), not Files: a File moves its file in on the Inbound row and out on the Outbound row, so the total (%s) is roughly twice the logical volume above. Error/OK split those transfers by status; click a count for that outcome'\''s 10 most recent transfers.\n' "$row_human"

    top_acc=$(printf '%s\n' "$aggt" | grep '^ACC|' | sort -t'|' -k4,4 -rn | awk -v n="$TOP_N" 'NR<=n' || true)
    total_acc=$(printf '%s\n' "$aggt" | grep -c '^ACC|' || true)
    printf 'TABLE\tTop %s accounts by volume\n' "$TOP_N"
    printf 'HEAD\tAccount\tFiles\tVolume\t%% of volume\n'
    printf 'KIND\tacct\tnum\tnum\tnum\n'
    printf 'RECALC\t-\ts0\th1\t%%1\n'
    printf '%s\n' "$top_acc" | while IFS='|' read -r _ acc rec bytes human pct bk; do
        [ -z "$acc" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\n' "$acc" "$rec" "$human" "$pct" "$bk"
    done
    printf '%s\n' "$top_acc" | awk -F'|' -v tot="$tot_bytes" -v total_acc="$total_acc" '
        function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i=1; v=b+0; while (v>=1024 && i<6) { v/=1024; i++ } return (i==1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
        { rec+=$3; by+=$4; c++ }
        END { printf "TOTAL\tTop %d of %d accounts\t@{class=num}%d\t@{class=num}%s\t@{class=num}%.1f%%\n", c, total_acc, rec, human(by), (tot>0 ? by*100/tot : 0) }
    '

    printf 'SUMMARY\tTotal volume: %s  |  Total Files: %s\n' "$tot_human" "$tot_rec"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_human, $tot_rec record(s))." >&2
