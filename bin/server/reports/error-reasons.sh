#!/usr/bin/env bash
#
# error-reasons.sh — classifies the server log's ERROR messages into failure
# REASON buckets: connection failures, PESIT protocol refusals (by their
# reason= code), network resets, partner-listing failures, advanced-routing
# step errors, config errors. The transfer logs record only OK/Error —
# their "Additional info" / "Pesit Message" fields are always UNKNOWN — so this
# is the only place the WHY of the ~45% failure rate is visible.
#
# Two tables on ONE tab page (both carry tab=reasons): the buckets, and the
# same buckets per ISO week — the "Reasons over time" table that sat on the
# Per flow page until 2026-09-28 (user request: fewer server reports; it
# counted these same E lines and tied to this total exactly).
#
# Reads the parse cache (data/_parse.tsv: 1=date, 2=time, 3=level, 5=message).
#
# Usage:
#   ./error-reasons.sh    # reads input/*.csv (via the cache), writes data/error-reasons.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/error-reasons.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Classify every E-level message. The buckets mirror the message families that
# actually occur (checked against the data); a PESIT reason= code becomes its
# own bucket so refusal kinds stay separate. Everything unmatched lands in
# "Other" with an example, so new families surface instead of vanishing.
# Emits TAB-separated (messages may contain "|"): count, share, bucket, per-day
# buckets, example (the chronologically FIRST message by "date time" sortkey —
# the cache is NOT in chronological order — truncated); W lines = bucket x ISO
# week.
agg=$(awk -F'\t' "$LOGLINES_AWK$AWKLIB"'
    # ISO week label from an ISO date: the calendar week of that date Thursday
    # (jdn%7: 0 = Monday, so Thursday = week start + 3).
    function isoweek(ds,   y, j, tj, ty) {
        y = substr(ds, 1, 4) + 0
        if (y < 1900) return ""
        j = jdn(y, substr(ds, 6, 2) + 0, substr(ds, 9, 2) + 0)
        tj = j - (j % 7) + 3
        ty = y
        if (jdn(ty, 1, 1) > tj) ty--
        else if (jdn(ty + 1, 1, 1) <= tj) ty++
        return sprintf("%04d-W%02d", ty, int((tj - jdn(ty, 1, 1)) / 7) + 1)
    }
    $3 != "E" { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        m = $5
        # the verbatim "Pull via FTPS failed" string is its own bucket
        # (2026-08-31, user request) — before every other family, so a line
        # carrying it never reads as a generic connection/transfer error
        if (m ~ /Pull via FTPS failed/)                             b = "Pull via FTPS failed"
        # the platform failing to read (or write) a file on its OWN storage —
        # "IO Error reading file /data/FlowManager/…" (its own report: IO
        # errors, 2026-09-06). Before the AR/transfer-operation families, whose
        # prefixes such a line may carry.
        else if (m ~ /(^|[^A-Za-z])[Ii][Oo] [Ee]rror|[Ii]nput\/[Oo]utput [Ee]rror/) b = "IO error (local file)"
        # a "Connection failure while ..." carrying a negative PeSIT response
        # is a refusal by the internal cluster CFT, NOT an unreachable partner
        else if (m ~ /^Connection failure while / && m ~ /Received negative /) b = "PESIT: negative response (internal CFT)"
        else if (m ~ /^Connection failure while /)                  b = "Connection failure (partner unreachable)"
        else if (match(m, /reason=[A-Z_]+/))                        b = "PESIT: " substr(m, RSTART + 7, RLENGTH - 7)
        else if (m ~ /Received negative /)                          b = "PESIT: negative response"
        else if (m ~ /SSLException|TlsFatalAlert/)                  b = "TLS/SSL error"
        else if (m ~ /Network error: Connection reset/)             b = "Network error: connection reset"
        else if (m ~ /[Nn]etwork error|^Channel is not active/)     b = "Network error: other"
        else if (m ~ /listing files from partner/)                  b = "Listing files from partner failed"
        else if (m ~ /^AR[A-Za-z0-9]*: /)                           b = "Advanced-routing step failure"
        else if (m ~ /CONFIG_PASSWD/)                               b = "CONFIG_PASSWD state variable error"
        # the post-download remote DELETE failing ("No such file: Cannot
        # delete file.") — its own bucket, the flip-reason.awk verdict
        else if (m ~ /[Cc]annot delete|[Cc]ould not delete|[Ff]ailed to delete/) b = "Delete remote file failed"
        else if (m ~ /^Error during transfer operation: /)          b = "Transfer operation error (other)"
        else                                                        b = "Other"
        cnt[b]++; tot++
        addline(b, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        sk = $1 " " $2
        if (!(b in exk) || sk < exk[b]) { exk[b] = sk; ex[b] = (m == "") ? "(empty message)" : substr(m, 1, 160) }   # never empty: a TAB read collapses it (2026-09-28)
        if (d != "") {
            cd2[b SUBSEP d]++
            wk = isoweek(d)
            if (wk != "") {
                wcnt[b SUBSEP wk]++
                addline("W" SUBSEP b SUBSEP wk, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
            }
        }
    }
    # a (reason, week) row in the DATED bucket form: its days in date order,
    # each with the reason count of that day (cd2)
    function wbkt(b, k,   n, D, i, j, v, o) {
        n = split(substr(WD[k], 2), D, SUBSEP)
        for (i = 2; i <= n; i++) { v = D[i]; j = i - 1; while (j >= 1 && D[j] > v) { D[j + 1] = D[j]; j-- } D[j + 1] = v }
        o = ""; for (i = 1; i <= n; i++) o = o (i > 1 ? "," : "") D[i] ":" cd2[b SUBSEP D[i]]
        return o
    }
    END {
        for (k in cd2) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" cd2[k] }
        # share is field 2 — computed HERE, where the pass total already is, not
        # by an awk fork per row down in the shell
        for (b in cnt) printf "%d\t%.1f\t%s\t%s\t%s\t%s\n", cnt[b], (tot ? cnt[b]*100/tot : 0), b, bk[b], ex[b], lastlines(b)
        # the days of each (reason, ISO week) row — its per-day counts are the
        # row buckets of the Reasons over time table (2026-09-30: date-aware)
        for (k in cd2) { split(k, a, SUBSEP); wk = isoweek(a[2]); if (wk != "") WD[a[1] SUBSEP wk] = WD[a[1] SUBSEP wk] SUBSEP a[2] }
        for (k in wcnt) {
            split(k, a, SUBSEP)
            printf "W\t%s\t%s\t%d\t%s\t%s\n", a[2], a[1], wcnt[k], wbkt(a[1], k), lastlines("W" SUBSEP a[1] SUBSEP a[2])
        }
        printf "TOT\t%d\n", tot
    }
' "$(srv_subset noninfo)")   # the non-Info lines (bin/server/subsets.sh — 2026-09-29, speed round 3)

tot_err=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="TOT"{print $2}')
if [ -z "$tot_err" ] || [ "$tot_err" -eq 0 ]; then
    echo "No ERROR records found in the server logs." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
nreasons=$(printf '%s\n' "$agg" | grep -cEv $'^(TOT|W)\t' || true)
n_weeks=$(printf '%s\n' "$agg" | grep -c $'^W\t' || true)

# The row writers print STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing. Sorts
# carry explicit tiebreakers: no output depends on awk hash-iteration order.
rows() {
    while IFS=$'\t' read -r count share reason bk example lines; do
        [ -z "$reason" ] && continue
        printf 'ROW\t%s\t%s\t%s%%\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$reason" "$count" "$share" "$example" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep -Ev $'^(TOT|W)\t' | sort -t"$(printf '\t')" -k1,1nr -k3,3)"
}
week_rows() {
    while IFS=$'\t' read -r _k wk reason count bk lines; do
        [ -z "$wk" ] && continue
        printf 'ROW\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$wk" "$reason" "$count" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^W\t' | sort -t"$(printf '\t')" -k2,2r -k4,4nr -k3,3)"
}

{
    printf 'TITLE\tTransfer Error Reasons\n'
    printf 'TABLE\tLog lines by reason\twide\ttab=reasons\n'
    printf 'HEAD\tReason\tErrors\tShare\tExample message\n'
    printf 'KIND\ttext\tnumfailed\tnum\tprose\n'   # prose: a log message never wraps (.logline, 2026-09-30 audit A3-06)
    printf 'RECALC\t-\ts0\t%%0\t-\n'
    rows
    printf 'TOTAL\tTotal (%s reason(s))\t@{class=num failed}%s\t@{class=num}100.0%%\t\n' "$nreasons" "$tot_err"

    # DATE-AWARE since 2026-09-30 (user request: every Errors-group page gets
    # the From/To selection): each (week, reason) row carries its per-day
    # counts, so Errors re-sums over the days of the week inside the range
    # (a week cut by the range shows its partial count) and a row with no
    # day in the range hides
    printf 'TABLE\tReasons over time\twide\ttab=reasons\n'
    printf 'HEAD\tISO week\tReason\tErrors\n'
    printf 'KIND\ttext\ttext\tnumfailed\n'
    printf 'RECALC\t-\t-\ts0\n'
    week_rows
    printf 'TOTAL\tTotal (%s row(s))\t\t@{class=num failed}%s\n' "$n_weeks" "$tot_err"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_err error(s), $nreasons reason(s))." >&2
