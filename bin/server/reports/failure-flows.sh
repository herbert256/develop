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
# An E line naming no flow is excluded from table 1 — so table 1 is a strict
# SUBSET of error-reasons' totals; table 2 covers ALL E records and ties to
# error-reasons exactly.
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
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TSITE"
if [ ! -f "$TSITE" ]; then
    echo "Transfer-site list not found: $TSITE — run the transfer reports first." >&2
    exit 1
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Pass 1 (subscription.rpt): the known subscriptions (ROW field 2).
# Pass 2 (_parse.tsv): classify every E message with error-reasons.sh's EXACT
# bucket chain (keep the two in sync — the taxonomy must read identically on
# both pages), extract the flow token, aggregate per (flow, reason) and per
# (reason, ISO week). Emits TAB-separated rows for the two tables; the shares
# are computed HERE (tot is in the END), so the shell row loops stay fork-free.
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK"'
    BEGIN { rn_load(RNF) }
    function jdn(y, m, d,   a) { a = int((14-m)/12); y = y+4800-a; m = m+12*a-3
        return d + int((153*m+2)/5) + 365*y + int(y/4) - int(y/100) + int(y/400) - 32045 }
    # ISO week label from an ISO date: the calendar week of that date'"'"'s
    # THURSDAY (jdn%7: 0 = Monday, so Thursday = week start + 3).
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
    NR == FNR { if ($1 == "ROW" && !($2 in known)) { known[$2] = 1 } next }
    $3 != "E" { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        m = $5
        # ---- the reason buckets: error-reasons.sh VERBATIM ------------------
        if (m ~ /^Connection failure while / && m ~ /Received negative /) b = "PESIT: negative response (internal CFT)"
        else if (m ~ /^Connection failure while /)                  b = "Connection failure (partner unreachable)"
        else if (match(m, /reason=[A-Z_]+/))                        b = "PESIT: " substr(m, RSTART + 7, RLENGTH - 7)
        else if (m ~ /Received negative /)                          b = "PESIT: negative response"
        else if (m ~ /SSLException|TlsFatalAlert/)                  b = "TLS/SSL error"
        else if (m ~ /Network error: Connection reset/)             b = "Network error: connection reset"
        else if (m ~ /[Nn]etwork error|^Channel is not active/)     b = "Network error: other"
        else if (m ~ /listing files from partner/)                  b = "Listing files from partner failed"
        else if (m ~ /^AR[A-Za-z0-9]*: /)                           b = "Advanced-routing step failure"
        else if (m ~ /CONFIG_PASSWD/)                               b = "CONFIG_PASSWD state variable error"
        else if (m ~ /^Error during transfer operation: /)          b = "Transfer operation error (other)"
        else                                                        b = "Other"
        tot++
        # ---- table 2: reason x ISO week, ALL E records ----------------------
        if (d != "") {
            wk = isoweek(d)
            if (wk != "") {
                wcnt[b SUBSEP wk]++
                addline("W" SUBSEP b SUBSEP wk, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
            }
        }
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
        sub(/_(SS?|C)CP_.*$/, "", tk)                  # canonical subscription name
        cnt[tk SUBSEP b]++; attr++
        addline("F" SUBSEP tk SUBSEP b, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        if (d != "") {
            if (!((tk SUBSEP b) in fst) || d < fst[tk SUBSEP b]) fst[tk SUBSEP b] = d
            if (!((tk SUBSEP b) in lst) || d > lst[tk SUBSEP b]) lst[tk SUBSEP b] = d
        }
    }
    END {
        # resolve each distinct token ONCE against the roster (server-side
        # truncation): a unique prefix match shows the full linked name
        for (k in cnt) { split(k, a, SUBSEP); if (!(a[1] in res)) res[a[1]] = "?" }
        for (t in res) {
            # RENAMES first (2026-08): a server line keeps the name that was
            # current when it was written, so fold it before matching the
            # roster — which carries CURRENT names, the transfer parse having
            # folded them. rn_canon_pfx also covers the truncated old spelling.
            c = rn_canon_pfx(t)
            if (c in known) { res[t] = c; continue }
            hits = 0; full = ""
            for (k in known) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) break }
            if (hits == 1)      res[t] = full
            else if (hits > 1)  res[t] = c " (ambiguous prefix)"
            else                res[t] = c
        }
        for (k in cnt) {
            split(k, a, SUBSEP)
            share = (attr > 0) ? sprintf("%.1f", cnt[k] * 100 / attr) : "0.0"
            printf "F\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", cnt[k], res[a[1]], a[2], \
                   (k in fst ? fst[k] : ""), (k in lst ? lst[k] : ""), share, lastlines("F" SUBSEP a[1] SUBSEP a[2])
        }
        for (k in wcnt) {
            split(k, a, SUBSEP)
            printf "W\t%s\t%s\t%d\t%s\n", a[2], a[1], wcnt[k], lastlines("W" SUBSEP a[1] SUBSEP a[2])
        }
        printf "TOT\t%d\t%d\n", tot, attr
    }
' "$TSITE" "$PARSED")

tot_err=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="TOT"{print $2}')
tot_attr=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="TOT"{print $3}')
if [ -z "$tot_err" ] || [ "$tot_err" -eq 0 ]; then
    echo "No ERROR records found in the server logs." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
n_pairs=$(printf '%s\n' "$agg" | grep -c $'^F\t' || true)
n_weeks=$(printf '%s\n' "$agg" | grep -c $'^W\t' || true)
n_flows=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="F" && !s[$3]++ {n++} END{print n+0}')
attr_share=$(awk -v c="$tot_attr" -v t="$tot_err" 'BEGIN { if (t > 0) printf "%.1f", c * 100 / t; else printf "0.0" }')

# Row writers print STRAIGHT to stdout inside the page block below (a
# `$(printf …)` per row would fork a subshell per row — site-failures.sh's
# pattern). Sorts carry explicit tiebreakers: no output depends on awk
# hash-iteration order.
flow_rows() {
    while IFS=$'\t' read -r _k count disp reason fst lst share lines; do
        [ -z "$disp" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s%%\t%s\t%s\t@data:loglines=%s\n' \
            "$disp" "$reason" "$count" "$share" "$fst" "$lst" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^F\t' | sort -t"$(printf '\t')" -k2,2nr -k3,3 -k4,4)"
}
week_rows() {
    while IFS=$'\t' read -r _k wk reason count lines; do
        [ -z "$wk" ] && continue
        printf 'ROW\t%s\t%s\t%s\t@data:loglines=%s\n' "$wk" "$reason" "$count" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^W\t' | sort -t"$(printf '\t')" -k2,2r -k4,4nr -k3,3)"
}

{
    printf 'TITLE\tFailure reasons per flow\n'
    printf 'DESC\tServer-log ERROR messages classified by reason and attributed to the subscription each message names, with the reason mix per ISO week.\n'
    printf 'INTRO\t**%s** of the **%s** server-log ERROR records (**%s%%**) name a flow: **%s** subscription(s), **%s** subscription-and-reason pair(s), classified with the same reason buckets as the **Transfer Error Reasons** report. The transfer logs record only OK/Error with no reason; this page says what breaks for **which flow** — and, below, how the reason mix moves week by week.\n' \
        "$tot_attr" "$tot_err" "$attr_share" "$n_flows" "$n_pairs"
    printf 'KEYWORDS\tfailure,reasons,flow,subscription,error,classified,week,pesit,connection,network,refused,timeline\n'

    printf 'TABLE\tSubscription × reason\twide\tnofilter\tpager=50\n'
    printf 'HEAD\tSubscription\tReason\tErrors\tShare\tFirst seen\tLast seen\n'
    printf 'KIND\tsite\ttext\tnumfailed\tnum\ttext\ttext\n'
    flow_rows
    printf 'TOTAL\tTotal (%s pair(s))\t\t@{class=num failed}%s\t@{class=num}100.0%%\t\t\n' "$n_pairs" "$tot_attr"

    printf 'TABLE\tReasons over time\twide\tnofilter\n'
    printf 'HEAD\tISO week\tReason\tErrors\n'
    printf 'KIND\ttext\ttext\tnumfailed\n'
    week_rows
    printf 'TOTAL\tTotal (%s row(s))\t\t@{class=num failed}%s\n' "$n_weeks" "$tot_err"

    printf 'NOTE\tThe reason buckets are the **Transfer Error Reasons** buckets, verbatim — the first table narrows them to the ERROR lines that name a flow (a connection-failure line, a partner-listing failure, or an advanced-routing line'"'"'s bracketed flow token), so its total is a subset of that report'"'"'s; the second table counts ALL classified ERROR records per ISO week and ties to it exactly. Server messages truncate long subscription names: a name resolving to exactly one configured subscription is shown in full (and linked); the rest appear as logged. Both tables always show the full period. Click a row to expand its 10 most recent error lines.\n'
    printf 'SUMMARY\tErrors naming a flow: %s of %s  |  Subscriptions: %s  |  Pairs: %s\n' "$tot_attr" "$tot_err" "$n_flows" "$n_pairs"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_attr of $tot_err error(s) attributed, $n_flows flow(s), $n_pairs pair(s))." >&2
