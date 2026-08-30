#!/usr/bin/env bash
#
# site-failures.sh — CONNECTION FAILURES per transfer site, from the server
# log's "Connection failure while <SITE> tried to connect ..." ERROR messages.
# Counts every site (unknown-sites lists only the sites absent from the
# transfer logs; the failures of KNOWN sites — by far the biggest counts —
# are invisible there). Server messages truncate long site names, so each
# logged token is resolved against the transfer Transfer-Site report: a unique
# prefix match shows the full site name (linked to its detail page); the rest
# are listed as logged.
#
# Usage:
#   ./site-failures.sh    # reads input/*.csv (via the cache) + subscription.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/site-failures.rpt"

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

# Pass 1 (subscription.rpt): the known transfer sites (ROW field 2).
# Pass 2 (_parse.tsv): the site token of every connection-failure message,
# counted per token and per day. In END each token resolves to the unique
# known site it prefixes (server-side truncation), stays ambiguous, or is
# unknown. Emits TAB-separated: kind(R/U), count, display, buckets, first,
# last, share, loglines — the share of ALL failures is computed HERE (tot is
# right there in the END), so the row loop below stays fork-free.
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK"'
    BEGIN { rn_load(RNF) }
    NR == FNR { if ($1 == "ROW" && !($2 in known)) { known[$2] = 1 } next }
    $3 != "E" { next }
    $5 !~ /^Connection failure while / { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        m = substr($5, 26)                       # after "Connection failure while "
        # the site name may CONTAIN spaces ("Clone - UC3_..."): capture up to
        # the " tried to " delimiter, falling back to the first space
        sp = index(m, " tried to "); if (sp <= 1) sp = index(m, " ")
        if (sp <= 1) next
        tk = substr(m, 1, sp - 1)
        sub(/_(SS?|C)CP_.*$/, "", tk)                                        # canonical subscription name (drop the _SCP_ / _SSCP_ / _CCP_ tail)
        cnt[tk]++; tot++
        addline(tk, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
        if (d != "") {
            cd2[tk SUBSEP d]++
            if (!(tk in fst) || d < fst[tk]) fst[tk] = d
            if (!(tk in lst) || d > lst[tk]) lst[tk] = d
        }
    }
    END {
        for (k in cd2) { split(k, a, SUBSEP); bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" cd2[k] }
        for (t in cnt) {
            # RENAMES (2026-08): fold the logged token to the name the config
            # uses now BEFORE matching the roster, which carries current names.
            # A renamed flow then resolves into the KNOWN table instead of
            # sitting in the unresolved one under a name nothing else uses.
            c = rn_canon_pfx(t)
            if (c in known) { printf "R\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", cnt[t], c, bk[t], fst[t], lst[t], (tot > 0 ? sprintf("%.1f", cnt[t] * 100 / tot) : "0.0"), lastlines(t); continue }
            hits = 0; full = ""
            for (k in known) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) break }
            share = (tot > 0) ? sprintf("%.1f", cnt[t] * 100 / tot) : "0.0"
            if (hits == 1)      printf "R\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", cnt[t], full, bk[t], fst[t], lst[t], share, lastlines(t)
            else if (hits > 1)  printf "U\t%d\t%s (ambiguous prefix)\t%s\t%s\t%s\t%s\t%s\n", cnt[t], c, bk[t], fst[t], lst[t], share, lastlines(t)
            else                printf "U\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", cnt[t], c, bk[t], fst[t], lst[t], share, lastlines(t)
        }
        printf "TOT\t%d\n", tot
    }
' "$TSITE" "$PARSED")

tot_fail=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="TOT"{print $2}')
if [ -z "$tot_fail" ] || [ "$tot_fail" -eq 0 ]; then
    echo "No connection-failure messages found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
n_res=$(printf '%s\n' "$agg" | grep -c $'^R\t' || true)
n_unres=$(printf '%s\n' "$agg" | grep -c $'^U\t' || true)

# The awk already carried the share, so the loop only assembles the ROW line —
# no fork per row (a `$(printf …)` per row is a subshell, and these two tables
# run to ~100 rows).
build_rows() {   # $1 = R or U
    local kind=$1 rows="" _k count disp bk fst lst share lines
    while IFS=$'\t' read -r _k count disp bk fst lst share lines; do
        [ -z "$disp" ] && continue
        rows+="ROW"$'\t'"$disp"$'\t'"$count"$'\t'"${share}%"$'\t'"$fst"$'\t'"$lst"$'\t'"@data:buckets=$bk"$'\t'"@data:loglines=$lines"$'\n'
    done <<< "$(printf '%s\n' "$agg" | grep "^$kind"$'\t' | sort -t$'\t' -k2,2nr)"
    printf '%s' "$rows"
}
res_rows=$(build_rows R)
unres_rows=$(build_rows U)
# Per-table failure sums + each table's share of ALL failures (for the TOTAL rows).
res_sum=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="R"{s+=$2} END{print s+0}')
unres_sum=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="U"{s+=$2} END{print s+0}')
res_share=$(awk -v c="$res_sum" -v t="$tot_fail" 'BEGIN { if (t > 0) printf "%.1f", c * 100 / t; else printf "0.0" }')
unres_share=$(awk -v c="$unres_sum" -v t="$tot_fail" 'BEGIN { if (t > 0) printf "%.1f", c * 100 / t; else printf "0.0" }')

# P14303_CFT01 (the internal cluster CFT, blanked from the transfer logs by the
# parse-time blacklist — see bin/transfer/parse.sh) can only ever land in the
# unresolved table. Keep the row (its failures are real), but say what it is.
# (Pure-bash substring test: a `grep -q` would exit at the first match and
# SIGPIPE the printf feeding it, which pipefail turns into a failure.)
cft_note=""
if [ "${unres_rows#*P14303_CFT01}" != "$unres_rows" ]; then
    cft_note=" **P14303_CFT01** is the internal cluster CFT — a platform-internal endpoint (blanked from the transfer logs), not a partner."
fi

{
    printf 'TITLE\tConnection Failures per Subscription\n'
    printf 'DESC\tServer-log connection failures counted per subscription (known subscriptions linked, truncated names listed as logged).\n'
    printf 'INTRO\t**%s** connection-failure messages: **%s** subscription(s) resolved to a known subscription, **%s** name(s) unresolved (truncated beyond a unique match, or absent from the transfer logs — see the Missing subscriptions report). Repeated connection failures are retry storms toward an unreachable partner.\n' \
        "$tot_fail" "$n_res" "$n_unres"

    printf 'TABLE\tKnown subscriptions\twide\n'
    printf 'HEAD\tSubscription\tConnection failures\tShare\tFirst seen\tLast seen\n'
    printf 'KIND\tsite\tnumfailed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t%%0\t-\t-\n'
    printf '%s\n' "$res_rows"      # %s\n: $(build_rows) stripped the trailing newline
    printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num failed}%s\t@{class=num}%s%%\t\t\n' "$n_res" "$res_sum" "$res_share"

    printf 'TABLE\tUnresolved subscription names (as logged)\twide\n'
    printf 'HEAD\tSubscription (as logged by the server)\tConnection failures\tShare\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnumfailed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t%%0\t-\t-\n'
    printf '%s\n' "$unres_rows"
    printf 'TOTAL\tTotal (%s name(s))\t@{class=num failed}%s\t@{class=num}%s%%\t\t\n' "$n_unres" "$unres_sum" "$unres_share"

    printf 'NOTE\tServer messages truncate long subscription names; a name is shown in full (and linked) when it is the prefix of exactly one subscription. Share is of all connection failures across both tables at the full range (a narrowed date range re-shares over each table separately).%s Click a row to expand its 10 most recent failure lines.\n' "$cft_note"
    printf 'SUMMARY\tConnection failures: %s  |  Resolved subscriptions: %s  |  Unresolved names: %s\n' "$tot_fail" "$n_res" "$n_unres"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_fail failure(s), $n_res resolved site(s))." >&2
