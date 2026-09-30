#!/usr/bin/env bash
#
# failure-flows.sh — "Failure reasons per flow": the server log's ERROR
# messages classified into the SAME reason buckets error-reasons.sh uses,
# attributed to the flow (subscription) each message names. error-reasons
# answers "what breaks platform-wide"; this answers "what breaks for WHICH
# flow, and when".
#
# Flow attribution, three message shapes (all observed in the data):
#   1. "Connection failure while <FLOW> tried to connect ..."      (site-failures.sh's token)
#   2. "... listing files from partner <FLOW> defined in account"  (UC3 listing failures)
#   3. "ARxxxx: [<PARTNER>] [<FLOW>]  ..."                         (advanced-routing lines;
#      the SECOND bracket token is the flow — the first is the partner folder or
#      SECURETRANSPORT; a lone bracket token like [Ssh Default] is a server name,
#      filtered by requiring an underscore, which every flow name carries)
# The _SCP_/_SSCP_/_CCP_ tail is dropped (canonical subscription name, same as
# site-failures.sh), and each token is resolved against the transfer
# subscription roster by unique prefix (server messages truncate long names).
# An E line naming no flow is excluded — so the table is a strict SUBSET of
# error-reasons' totals. (Its second table, the reason mix per ISO week over
# ALL E records, moved to the Errors / Reasons tab on 2026-09-28 — user
# request: fewer server reports; it tied to error-reasons exactly.)
#
# Reads the parse cache (data/_parse.tsv: 1=date, 2=time, 3=level, 5=message)
# + the transfer subscription report (the roster, like site-failures.sh).
#
# Usage:
#   ./failure-flows.sh    # reads input/*.csv (via the cache), writes data/failure-flows.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/failure-flows.rpt"

TSITE="$TRANSFER_REPORTS/subscription.rpt"   # authoritative subscription list

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
if [ ! -f "$TSITE" ]; then
    echo "Transfer-site list not found: $TSITE — run the transfer reports first." >&2
    exit 1
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Pass 1 (subscription.rpt): the known subscriptions (ROW field 2).
# Pass 2 (_parse.tsv): classify every E message with error-reasons.sh's EXACT
# bucket chain (keep the two in sync — the taxonomy must read identically on
# both pages), extract the flow token, aggregate per (flow, reason). Emits
# TAB-separated rows; the shares are computed HERE (tot is in the END), so the
# shell row loop stays fork-free.
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK"'
    BEGIN { rn_load(RNF) }
    # the flow name of a bracketed AR line: the SECOND [token] when a pair
    # exists ("[PARTNER] [FLOW]"), the lone token otherwise
    function flowtok(m,   i, j, t, u) {
        i = index(m, "["); if (i == 0) return ""
        j = index(substr(m, i + 1), "]"); if (j == 0) return ""
        t = substr(m, i + 1, j - 1)
        u = substr(m, i + j + 1)
        i = index(u, "[")
        if (i > 0) { j = index(substr(u, i + 1), "]"); if (j > 0) return substr(u, i + 1, j - 1) }
        return t
    }
    # the token -> the flow name it counts under, ONCE per token and BEFORE
    # counting (2026-09-28 fix): a renamed or server-truncated spelling of one
    # flow is ONE row, not one per spelling
    function resolve(t,   c, k, hits, full) {
        if (t in RES) return RES[t]
        # RENAMES first (2026-08): a server line keeps the name that was
        # current when it was written, so fold it before matching the
        # roster — which carries CURRENT names, the transfer parse having
        # folded them. rn_canon_pfx also covers the truncated old spelling.
        c = rn_canon_pfx(t)
        if (c in known) return (RES[t] = c)
        hits = 0; full = ""
        for (k in known) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) break }
        if (hits == 1)     return (RES[t] = full)
        if (hits > 1)      return (RES[t] = c " (ambiguous prefix)")
        return (RES[t] = c)
    }
    NR == FNR { if ($1 == "ROW" && !($2 in known)) { known[$2] = 1 } next }
    $3 != "E" { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        m = $5
        # ---- the reason buckets: error-reasons.sh VERBATIM ------------------
        # (the two buckets it gained on 2026-08-31 — "Pull via FTPS failed"
        # first, "Delete remote file failed" before the transfer-operation
        # tail — were missing here, their lines read "Other": 2026-09-28 fix)
        if (m ~ /Pull via FTPS failed/)                             b = "Pull via FTPS failed"
        else if (m ~ /(^|[^A-Za-z])[Ii][Oo] [Ee]rror|[Ii]nput\/[Oo]utput [Ee]rror/) b = "IO error (local file)"   # the lines of the IO errors report (2026-09-06)
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
        else if (m ~ /[Cc]annot delete|[Cc]ould not delete|[Ff]ailed to delete/) b = "Delete remote file failed"
        else if (m ~ /^Error during transfer operation: /)          b = "Transfer operation error (other)"
        else                                                        b = "Other"
        tot++
        # ---- the flow token -------------------------------------------------
        tk = ""
        if (m ~ /^Connection failure while /) {
            u = substr(m, 26)                    # after "Connection failure while "
            sp = index(u, " tried to "); if (sp <= 1) sp = index(u, " ")
            if (sp > 1) tk = substr(u, 1, sp - 1)
        } else if ((p = index(m, "listing files from partner ")) > 0) {
            u = substr(m, p + 27)
            sp = index(u, " defined in account"); if (sp <= 1) sp = index(u, " ")
            if (sp > 1) tk = substr(u, 1, sp - 1)
        } else tk = flowtok(m)
        if (tk != "" && index(tk, "_") == 0) tk = ""   # [Ssh Default] etc — a server name, not a flow
        if (tk == "") next
        sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", tk)                  # canonical subscription name
        tk = resolve(tk)
        cnt[tk SUBSEP b]++; attr++
        addline("F" SUBSEP tk SUBSEP b, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        if (d != "") {
            if (!((tk SUBSEP b) in fst) || d < fst[tk SUBSEP b]) fst[tk SUBSEP b] = d
            if (!((tk SUBSEP b) in lst) || d > lst[tk SUBSEP b]) lst[tk SUBSEP b] = d
            # the per-day counts (2026-09-30: the From/To re-count, RECALC s0)
            if (!((tk SUBSEP b SUBSEP d) in BC)) BD[tk SUBSEP b] = BD[tk SUBSEP b] SUBSEP d
            BC[tk SUBSEP b SUBSEP d]++
        }
    }
    # the per-day counts of a (flow, reason) pair in the DATED bucket form
    # (date:count, date order)
    function bkt(k,   n, D, i, j, v, o) {
        n = split(substr(BD[k], 2), D, SUBSEP)
        for (i = 2; i <= n; i++) { v = D[i]; j = i - 1; while (j >= 1 && D[j] > v) { D[j + 1] = D[j]; j-- } D[j + 1] = v }
        o = ""; for (i = 1; i <= n; i++) o = o (i > 1 ? "," : "") D[i] ":" BC[k SUBSEP D[i]]
        return o
    }
    END {
        for (k in cnt) {
            split(k, a, SUBSEP)
            share = (attr > 0) ? sprintf("%.1f", cnt[k] * 100 / attr) : "0.0"
            printf "F\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", cnt[k], a[1], a[2], \
                   (k in fst ? fst[k] : ""), (k in lst ? lst[k] : ""), share, bkt(k), lastlines("F" SUBSEP a[1] SUBSEP a[2])
        }
        printf "TOT\t%d\t%d\n", tot, attr
    }
' "$TSITE" "$(srv_subset noninfo)")   # the non-Info lines (bin/server/subsets.sh — 2026-09-29, speed round 3)

tot_err=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="TOT"{print $2}')
tot_attr=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="TOT"{print $3}')
if [ -z "$tot_err" ] || [ "$tot_err" -eq 0 ]; then
    echo "No ERROR records found in the server logs." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
n_pairs=$(printf '%s\n' "$agg" | grep -c $'^F\t' || true)
n_flows=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="F" && !s[$3]++ {n++} END{print n+0}')
attr_share=$(awk -v c="$tot_attr" -v t="$tot_err" 'BEGIN { if (t > 0) printf "%.1f", c * 100 / t; else printf "0.0" }')

# The row writer prints STRAIGHT to stdout inside the page block below (a
# `$(printf …)` per row would fork a subshell per row — site-failures.sh's
# pattern). Sorts carry explicit tiebreakers: no output depends on awk
# hash-iteration order.
flow_rows() {
    while IFS=$'\t' read -r _k count disp reason fst lst share bk lines; do
        [ -z "$disp" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s%%\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$disp" "$reason" "$count" "$share" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^F\t' | sort -t"$(printf '\t')" -k2,2nr -k3,3 -k4,4)"
}

{
    printf 'TITLE\tPer flow\n'   # = its Reports menu label (2026-09-29)

    # DATE-AWARE since 2026-09-30 (user request: every Errors-group page gets
    # the From/To selection): Errors re-sums for the range from the per-day
    # buckets and Share re-divides over the visible rows (RECALC s0 %0); a
    # pair with nothing in the range hides; First / Last seen stay full-period
    printf 'TABLE\tSubscription × reason\twide\tpager=50\n'
    printf 'HEAD\tSubscription\tReason\tErrors\tShare\tFirst seen\tLast seen\n'
    printf 'KIND\tsite\ttext\tnumfailed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\t-\ts0\t%%0\t-\t-\n'
    flow_rows
    printf 'TOTAL\tTotal (%s pair(s))\t\t@{class=num failed}%s\t@{class=num}100.0%%\t\t\n' "$n_pairs" "$tot_attr"

    printf 'SUMMARY\tErrors naming a flow: %s of %s  |  Subscriptions: %s  |  Pairs: %s\n' "$tot_attr" "$tot_err" "$n_flows" "$n_pairs"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_attr of $tot_err error(s) attributed, $n_flows flow(s), $n_pairs pair(s))." >&2
