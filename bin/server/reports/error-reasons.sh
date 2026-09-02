#!/usr/bin/env bash
#
# error-reasons.sh — classifies the server log's ERROR messages into failure
# REASON buckets: connection failures, PESIT protocol refusals (by their
# reason= code), network resets, partner-listing failures, advanced-routing
# step errors, config errors. The transfer logs record only OK/Error —
# their "Additional info" / "Pesit Message" fields are always UNKNOWN — so this
# is the only place the WHY of the ~45% failure rate is visible.
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
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Classify every E-level message. The buckets mirror the message families that
# actually occur (checked against the data); a PESIT reason= code becomes its
# own bucket so refusal kinds stay separate. Everything unmatched lands in
# "Other" with an example, so new families surface instead of vanishing.
# Emits TAB-separated (messages may contain "|"): count, share, bucket, per-day
# buckets, example (the chronologically FIRST message by "date time" sortkey —
# the cache is NOT in chronological order — truncated).
agg=$(awk -F'\t' "$LOGLINES_AWK"'
    $3 != "E" { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        m = $5
        # the verbatim "Pull via FTPS failed" string is its own bucket
        # (2026-08-31, user request) — before every other family, so a line
        # carrying it never reads as a generic connection/transfer error
        if (m ~ /Pull via FTPS failed/)                             b = "Pull via FTPS failed"
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
        else if (m ~ /[Cc]annot delete|[Cc]ould not delete|[Ff]ailed to delete/) b = "Remote delete failed"
        else if (m ~ /^Error during transfer operation: /)          b = "Transfer operation error (other)"
        else                                                        b = "Other"
        cnt[b]++; tot++
        addline(b, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        sk = $1 " " $2
        if (!(b in exk) || sk < exk[b]) { exk[b] = sk; ex[b] = substr(m, 1, 160) }
        if (d != "") cd2[b SUBSEP d]++
    }
    END {
        for (k in cd2) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" cd2[k] }
        # share is field 2 — computed HERE, where the pass total already is, not
        # by an awk fork per row down in the shell
        for (b in cnt) printf "%d\t%.1f\t%s\t%s\t%s\t%s\n", cnt[b], (tot ? cnt[b]*100/tot : 0), b, bk[b], ex[b], lastlines(b)
        printf "TOT\t%d\n", tot
    }
' "$PARSED")

tot_err=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="TOT"{print $2}')
if [ -z "$tot_err" ] || [ "$tot_err" -eq 0 ]; then
    echo "No ERROR records found in the server logs." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
nreasons=$(printf '%s\n' "$agg" | grep -cv '^TOT' || true)

# The row writer prints STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
rows() {
    while IFS=$'\t' read -r count share reason bk example lines; do
        [ -z "$reason" ] && continue
        printf 'ROW\t%s\t%s\t%s%%\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$reason" "$count" "$share" "$example" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep -v '^TOT' | sort -t"$(printf '\t')" -k1,1nr)"
}

{
    printf 'TITLE\tTransfer Error Reasons\n'
    printf 'DESC\tServer-log ERROR messages classified by failure reason (connection, PESIT refusal codes, network, routing).\n'
    printf 'INTRO\t**%s** ERROR records classified into **%s** reason bucket(s). The transfer logs record only OK/Error with no reason (their detail fields are always UNKNOWN); the server log carries the why — partner connection failures, PESIT refusal codes (`reason=…`), network resets, routing-step errors.\n' \
        "$tot_err" "$nreasons"
    printf 'TABLE\tErrors by reason\twide\n'
    printf 'HEAD\tReason\tErrors\tShare\tExample message\n'
    printf 'KIND\ttext\tnumfailed\tnum\tfile\n'
    printf 'RECALC\t-\ts0\t%%0\t-\n'
    rows
    printf 'TOTAL\tTotal (%s reason(s))\t@{class=num failed}%s\t@{class=num}100.0%%\t\n' "$nreasons" "$tot_err"
    printf 'NOTE\tOne row per reason bucket; PESIT reason= codes get their own bucket each. "Example message" is the first occurrence, truncated. Unrecognized error families land in "Other" so new problems surface rather than vanish. Click a row to expand its 10 most recent error lines.\n'
    printf 'SUMMARY\tErrors: %s  |  Reason buckets: %s\n' "$tot_err" "$nreasons"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_err error(s), $nreasons reason(s))." >&2
