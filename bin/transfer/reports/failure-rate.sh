#!/usr/bin/env bash
#
# failure-rate.sh
# Reports the FAILURE RATE (Failed / Total, as a percentage) of Axway
# FlowManager transfers, per account and per transfer site (ranked worst-first)
# and per day (chronological). "Failed Subtransmission" is folded into "Failed".
#
# Usage:
#   ./failure-rate.sh    # reads input/*.csv, writes output/failure-rate.html
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/failure-rate.rpt"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Read the logical-transfer cache (data/_files.tsv): one row per transfer,
# 2=outcome (delivered), 3=account, 4=date_iso, 12=dest_site. Failure rate is
# per logical transfer; the "site" table is keyed on the transfer's DESTINATION
# site. Emits typed pipe rows: TYPE|key|total|failed|processed|pct
agg=$(awk -F'\t' "$COREIDS_AWK"'
    function pct(f, t) { return t ? sprintf("%.1f", f * 100 / t) : "0.0" }
    $4 == "" { next }
    {
        outcome = $2; account = $3; site = $12; day = $4
        # blank = every row had a blacklisted value (parse.sh); keep the
        # transfer in the totals under a parenthesized pseudo-row (unlinked).
        if (account == "") account = "(no account)"
        if (site == "")    site = "(no subscription)"

        at[account]++; st[site]++; dt[day]++; tt++
        aday[account SUBSEP day] = 1; sday[site SUBSEP day] = 1
        if (outcome != "Failed" && outcome != "Expired") { ap[account]++; sp[site]++; dp2[day]++; tp++; adp[account SUBSEP day]++; sdp[site SUBSEP day]++ }
        else                        { af[account]++; sf[site]++; df[day]++; tf++; adf[account SUBSEP day]++; sdf[site SUBSEP day]++ }
        oc = (outcome != "Failed" && outcome != "Expired") ? "P" : "F"     # per (dimension,value,outcome): 10 most-recent transfers
        addtop("A" SUBSEP account SUBSEP oc, $6, $4 " " $5, $1)
        addtop("S" SUBSEP site    SUBSEP oc, $6, $4 " " $5, $1)
        addtop("D" SUBSEP day     SUBSEP oc, $6, $4 " " $5, $1)
    }
    END {
        # per-account / per-site day buckets "day:total:failed:processed,..." so
        # the client can re-aggregate these tables for a selected date range.
        for (k in aday) { split(k, a, SUBSEP); ab[a[1]] = ab[a[1]] (ab[a[1]] ? "," : "") a[2] ":" (adf[k]+adp[k]) ":" (adf[k]+0) ":" (adp[k]+0) }
        for (k in sday) { split(k, a, SUBSEP); sb[a[1]] = sb[a[1]] (sb[a[1]] ? "," : "") a[2] ":" (sdf[k]+sdp[k]) ":" (sdf[k]+0) ":" (sdp[k]+0) }
        for (k in at) printf "ACC|%s|%d|%d|%d|%s|%s|%s|%s\n",  k, at[k], af[k]+0, ap[k]+0, pct(af[k]+0, at[k]), ab[k], buildlist(top["A" SUBSEP k SUBSEP "F"]), buildlist(top["A" SUBSEP k SUBSEP "P"])
        for (k in st) printf "SITE|%s|%d|%d|%d|%s|%s|%s|%s\n", k, st[k], sf[k]+0, sp[k]+0, pct(sf[k]+0, st[k]), sb[k], buildlist(top["S" SUBSEP k SUBSEP "F"]), buildlist(top["S" SUBSEP k SUBSEP "P"])
        for (k in dt) printf "DAY|%s|%d|%d|%d|%s|%s:%d:%d:%d|%s|%s\n", k, dt[k], df[k]+0, dp2[k]+0, pct(df[k]+0, dt[k]), k, dt[k], df[k]+0, dp2[k]+0, buildlist(top["D" SUBSEP k SUBSEP "F"]), buildlist(top["D" SUBSEP k SUBSEP "P"])
        printf "TOT|%d|%d|%d|%s\n", tt, tf+0, tp+0, pct(tf+0, tt)
    }
' "$FILES")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_total tot_failed tot_processed tot_pct <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# render_rows PREFIX SORT-ARG...  -> emits ROW lines (Error/OK tinted, %).
# ONE awk pass formats the sorted stream into finished ROW lines — a bash
# while-read with a $(printf) per row forked a subshell per row, three tables
# over. The last field takes the line's remainder, like read into the final
# variable did.
render_rows() {
    local prefix=$1; shift
    { printf '%s\n' "$agg" | grep "^$prefix|" || true; } | sort "$@" | awk -F'|' '
        $2 == "" { next }
        { ccp = $9; for (i = 10; i <= NF; i++) ccp = ccp "|" $i
          printf "ROW\t%s\t%s\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
              $2, $3, $4, $5, $6, $7, $8, ccp }'
}

# accounts with ZERO errors are not listed (2026-08-31, user request) — the
# table is a failure ranking; zerohide=1 keeps a narrowed date range clean too
acc_rows=$(render_rows "ACC"  -t'|' -k6,6nr -k3,3nr | awk -F'\t' '$4+0 > 0')
site_rows=$(render_rows "SITE" -t'|' -k6,6nr -k3,3nr)
day_rows=$(render_rows "DAY"  -t'|' -k2,2)

# The engine recomputes the total row from each table's visible column sums, so
# it needs no buckets of its own.
total_row=$(printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s%%' \
    "$tot_total" "$tot_failed" "$tot_processed" "$tot_pct")

{
    printf 'TITLE\tTransfer Failure Rates\n'
    printf 'DESC\tFailed vs total Files, as a percentage, per account, destination subscription and day.\n'
    # META lines (not rendered) feed the root-index KPI strip in bin/build/publish.sh.
    printf 'META\tfailpct\t%s\n' "$tot_pct"
    printf 'META\tfailed\t%s\n' "$tot_failed"
    printf 'INTRO\tOverall **%s%%** of Files failed (**%s** of **%s**). A File counts as Error when its final row did not deliver.\n' \
        "$tot_pct" "$tot_failed" "$tot_total"

    printf 'TABLE\tFailure rate per account\tzerohide=1\n'
    printf 'HEAD\tAccount\tFiles\tError\tOK\tError %%\n'
    printf 'KIND\tacct\tnum\tnumfailed\tnumprocessed\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\tp1.0\n'
    printf '%s\n' "$acc_rows"; printf '%s\n' "$total_row"

    printf 'TABLE\tFailure rate per destination subscription\n'
    printf 'HEAD\tDestination Subscription\tFiles\tError\tOK\tError %%\n'
    printf 'KIND\tsite\tnum\tnumfailed\tnumprocessed\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\tp1.0\n'
    printf '%s\n' "$site_rows"; printf '%s\n' "$total_row"

    printf 'TABLE\tFailure rate per day\n'
    printf 'HEAD\tDate\tFiles\tError\tOK\tError %%\n'
    printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\tp1.0\n'
    printf '%s\n' "$day_rows"; printf '%s\n' "$total_row"

    printf 'NOTE\tCounts Files — one logical transfer each; a File counts as Error when its final row did not deliver (the delivered rule). The account table lists only accounts with at least one Error. The Subscriptions entity pages count individual transfers (legs) by default, so their Error figures differ from the per-subscription numbers here. Click an Error or OK count for that outcome'\''s 10 most recent Files (newest first).\n'
    printf 'SUMMARY\tOverall File failure rate: %s%% (%s of %s)\n' "$tot_pct" "$tot_failed" "$tot_total"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (overall $tot_pct% failed)." >&2
