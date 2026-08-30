#!/usr/bin/env bash
#
# retry.sh
# REPEAT FAILURES: transfer "flows" — (Account, Transfer Site) pairs — ranked by
# how persistently they fail. For each flow it shows the number of distinct days
# it failed on, failure and success counts, the last failure time, and whether it
# EVER succeeded. Flows that never succeeded (broken) are listed first, then the
# flakiest by failure count. With a ~45% overall failure rate this separates
# chronically-broken flows from occasionally-flaky ones. Filenames carry
# timestamps (so exact retries don't repeat); the Account+Site pair is the stable
# flow key. "Failed Subtransmission" folds into Failed.
#
# Usage:
#   ./retry.sh    # reads input/*.csv, writes data/retry.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/retry.rpt"

TOP_N=60   # how many failing flows to list


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Read the shared parse cache: 3=status, 4=account, 6=site, 11=date_iso,
# 12=time, 13=sortkey, 22=resubmitted, 23=transfer_id. Every row is counted (proc
# vs fail); per-day fail/success/resubmit buckets feed the date filter (the
# d0 token recomputes "Fail days" as the in-range days with failures).
agg=$(awk -F'\t' "$COREIDS_AWK"'
    {
        status = $3; sub(/ Subtransmission$/, "", status)
        account = $4; site = $6
        key = account SUBSEP site
        kacct[key] = account; ksite[key] = site
        iso = $11
        pr = (status == "Processed")
        rs = ($22 == "true")
        if (pr) { proc[key]++; tproc++ } else { fail[key]++; tfail++ }
        if (rs) resub[key]++
        if (iso != "") {
            kd = key SUBSEP iso; dseen[kd] = 1
            if (pr) dp2[kd]++; else {
                df2[kd]++
                if (!(kd in fdmark)) { fdmark[kd] = 1; faildays[key]++ }
                if ($13 > lastkey[key]) { lastkey[key] = $13; lastdisp[key] = iso " " $12 }
            }
            if (rs) dr2[kd]++
        }
        addtop("RT" SUBSEP key SUBSEP (pr ? "P" : "F"), $13, $11 " " $12, $23)
    }
    END {
        for (kd in dseen) { split(kd, a, SUBSEP); k = a[1] SUBSEP a[2]
            bk[k] = bk[k] (bk[k] ? "," : "") a[3] ":" (df2[kd]+0) ":" (dp2[kd]+0) ":" (dr2[kd]+0) }
        for (k in kacct) {
            if (fail[k]+0 == 0) continue          # only flows that failed at least once
            never = (proc[k]+0 == 0) ? 0 : 1      # 0 => never succeeded (sorts first)
            if (never == 0) chronic++
            pairs++
            printf "PAIR|%d|%d|%s|%s|%d|%d|%d|%s|%s|%s|%s\n", never, fail[k], kacct[k], ksite[k], faildays[k]+0, proc[k]+0, resub[k]+0, (lastdisp[k] == "" ? "-" : lastdisp[k]), bk[k], buildlist(top["RT" SUBSEP k SUBSEP "F"]), buildlist(top["RT" SUBSEP k SUBSEP "P"])
        }
        printf "TOT|%d|%d|%d|%d\n", pairs+0, chronic+0, tfail+0, tproc+0
    }
' "$PARSED")

# No emptiness guard on $agg: the awk END always emits the TOT| line, so it is
# never empty — a zero-record window still renders a page with zero counts.

IFS='|' read -r _ pair_count chronic_count tot_fail tot_proc <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# never-succeeded first (k2 asc), then most failures (k3 desc); cap to TOP_N.
# `|| true`: zero PAIR| rows is the HEALTHY no-failures state — without the
# guard a clean window kills the script (a zero-match grep exits 1 under
# set -euo pipefail); the row loop below already skips blank lines.
top=$(printf '%s\n' "$agg" | grep '^PAIR|' | sort -t'|' -k2,2n -k3,3nr | awk -v n="$TOP_N" 'NR<=n' || true)
shown=$(printf '%s\n' "$top" | grep -c '^PAIR|' || true)

# The TOTAL line used to come from a second awk pass over the row text; the
# four columns it summed are all %d integers, so bash adds them up as the rows
# stream past (the loop runs inside the report block, via a herestring).
n_rows=0; sum_failures=0; sum_successes=0; sum_resubs=0

{
    printf 'TITLE\tRepeat Failures\n'
    printf 'DESC\tAccount/subscription flows by failure count, with successes, resubmissions and last-failure time.\n'
    printf 'INTRO\t**%s** account/subscription flows failed at least once; **%s** never succeeded in this window. %s failures vs %s successes overall.\n' \
        "$pair_count" "$chronic_count" "$tot_fail" "$tot_proc"
    printf 'TABLE\tFailing flows\twide\tdrill=transfer\n'
    printf 'HEAD\tAccount\tSubscription\tFail days\tFailures\tSuccesses\tResubmitted\tLast failure\tOutcome\n'
    printf 'KIND\tacct\tsite\tnum\tnumfailed\tnumprocessed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\t-\td0\ts0\ts1\ts2\t-\t-\n'
    while IFS='|' read -r _ never failures account site faildays successes resubs lastfail bk ccf ccp; do
        [ -z "$never" ] && continue                     # blank line guard
        [ -z "$account" ] && account="(no account)"     # blacklisted/blank entity — keep the flow
        [ -z "$site" ] && site="(no subscription)"      # countable, matching failure-rate's convention
        if [ "$never" = 0 ]; then outcome="@{class=failed}Never succeeded"; else outcome="Has successes"; fi
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n' \
            "$account" "$site" "$faildays" "$failures" "$successes" "$resubs" "$lastfail" "$outcome" "$bk" "$ccf" "$ccp"
        n_rows=$((n_rows + 1))
        sum_failures=$((sum_failures + failures))
        sum_successes=$((sum_successes + successes)); sum_resubs=$((sum_resubs + resubs))
    done <<< "$top"
    # the Fail days TOTAL cell stays BLANK (audit C1): its RECALC token is d0
    # (distinct days with failures), which the client-side total aggregate
    # cannot recompute — a baked number there rewrites to 0 on any date change.
    # Blank is the house pattern for a/c/d/q/x-token total cells (cf. weekday).
    printf 'TOTAL\tTotal (%d rows)\t\t\t@{class=num failed}%d\t@{class=num processed}%d\t@{class=num}%d\t\t\n' \
        "$n_rows" "$sum_failures" "$sum_successes" "$sum_resubs"
    if [ "$shown" -lt "$pair_count" ]; then
        printf 'NOTE\tShowing the top %s of %s failing flows (never-succeeded first, then by failure count). "Fail days" is the number of distinct days the flow failed on; "Resubmitted" counts rows flagged as resubmissions. Failures and Successes count individual transfers (legs), so a failed leg later re-sent successfully appears on both sides — the File-level reports fold such intra-File recoveries into one OK File (the delivered rule). Click a Failures or Successes count for that outcome'\''s 10 most recent transfers (newest first).\n' \
            "$shown" "$pair_count"
    else
        printf 'NOTE\t"Fail days" is the number of distinct days the flow failed on; "Never succeeded" flows had zero OK records in this window. "Resubmitted" counts rows flagged as resubmissions. Failures and Successes count individual transfers (legs), so a failed leg later re-sent successfully appears on both sides — the File-level reports fold such intra-File recoveries into one OK File (the delivered rule). Click a Failures or Successes count for that outcome'\''s 10 most recent transfers (newest first).\n'
    fi
    printf 'SUMMARY\tFailing flows: %s  |  Never succeeded: %s  |  Total failures: %s\n' "$pair_count" "$chronic_count" "$tot_fail"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($pair_count failing flow(s), $chronic_count never succeeded)." >&2
