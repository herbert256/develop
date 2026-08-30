#!/usr/bin/env bash
#
# recovered.sh — "Recovered flows": the GOOD-NEWS mirror of from-green-to-red.
# Subscriptions that are GREEN RIGHT NOW (latest File OK, the bin/build/result.sh
# rule) but had a RED EPISODE earlier in the window — at least one day that
# ENDED on a failed File. Per qualifying subscription: when the most recent
# episode started and ended, how long the flow was red, how many Files failed
# during it, how many OK Files followed, and the day it recovered — the
# "did yesterday's fix work?" list.
#
# The episode is the most recent maximal run of consecutive ACTIVE days that
# each ended on a failed File (a green evening clears the day, matching the
# from-green-to-red day rule); "recovered on" is the first active day after it,
# which by construction ended green. State per the site-wide outcome policy:
# Waiting counts as OK (green), Expired as Error (red). Full-period semantics
# (`nofilter`, like from-green-to-red): the flip back is a sequence in time,
# so narrowing the date range would fabricate or hide recoveries.
#
# Reads data/_files.tsv (1=coreid, 2=outcome, 4=date_iso, 5=time, 6=sortkey,
# 7=jdn, 12=dest_site), sorted per subscription. Writes
# data/transfer/reports/recovered.rpt.
#
# Usage:
#   ./recovered.sh   # reads input/*.csv (via the cache), writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TRANSFER lib, not the analyses one: this is a transfer-DATA report (it reads
# the transfer caches and writes data/<env>/transfer/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as from-green-to-red.sh. bin/transfer/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/recovered.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Stream _files.tsv grouped by subscription, chronological inside each group.
# Per site, every ACTIVE day is recorded when the date changes (the final day
# in flush, with its current state — the latest File decides green-now). The
# drill lists are kept per (site, day) and merged over the episode/since span
# at flush, so they hold exactly the episode's failures and the OKs after it.
# Emits pipe-separated (drill lists carry no pipes):
#   S|site|redfrom|redto|outage|fails|okssince|recov|faildrill|okdrill
#   TOT|sites|green|recovered|maxdate
agg=$(LC_ALL=C sort -t"$(printf '\t')" -k12,12 -k6,6 "$FILES" | awk -F'\t' "$COREIDS_AWK"'
    function mergetop(dst, src,   mm,aa,ii,ff) {
        if (!(src in top)) return
        mm = split(top[src], aa, _US)
        for (ii = 1; ii <= mm; ii++) { split(aa[ii], ff, SUBSEP); addtop(dst, ff[1], ff[2], ff[3]) }
    }
    function closeday() {
        if (day == "") return
        nd++; DD[nd] = day; DR[nd] = !dayok; DJ[nd] = dayj; DF[nd] = dayf; DO[nd] = dayo
    }
    function flush(   e,s,i,ff,oks) {
        if (site == "") return
        closeday()
        nsites++
        if (lastfail) return                      # red now -> from-green-to-red territory
        ngreen++
        e = 0; for (i = nd; i >= 1; i--) if (DR[i]) { e = i; break }
        if (!e) return                            # never a red day: nothing recovered from
        s = e; while (s > 1 && DR[s-1]) s--
        ff = 0; for (i = s; i <= e; i++) { ff += DF[i]; mergetop("EF" SUBSEP site, "F" SUBSEP site SUBSEP DD[i]) }
        oks = 0; for (i = e+1; i <= nd; i++) { oks += DO[i]; mergetop("EP" SUBSEP site, "P" SUBSEP site SUBSEP DD[i]) }
        nrec++
        printf "S|%s|%s|%s|%d|%d|%d|%s|%s|%s\n", site, DD[s], DD[e], DJ[e]-DJ[s]+1, ff, oks, DD[e+1], \
            buildlist(top["EF" SUBSEP site]), buildlist(top["EP" SUBSEP site])
    }
    $12 == "" || $4 == "" { next }
    {
        if ($12 != site) { flush()
            site = $12; day = ""; nd = 0; lastfail = 0
            split("", DD); split("", DR); split("", DJ); split("", DF); split("", DO) }
        if ($4 != day) { closeday(); day = $4; dayok = 0; dayj = $7 + 0; dayf = 0; dayo = 0 }
        if ($7 + 0 > maxjd) { maxjd = $7 + 0; maxdate = $4 }
        if ($2 != "Failed" && $2 != "Expired") {
            dayok = 1; lastfail = 0; dayo++
            addtop("P" SUBSEP site SUBSEP $4, $6, $4 " " $5, $1)
        } else {
            dayok = 0; lastfail = 1; dayf++
            addtop("F" SUBSEP site SUBSEP $4, $6, $4 " " $5, $1)
        }
    }
    END {
        flush()
        printf "TOT|%d|%d|%d|%s\n", nsites+0, ngreen+0, nrec+0, maxdate
    }
')

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ n_sites n_green n_rec last_date <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

n_rows=0; sum_out=0; sum_ff=0; sum_ok=0

{
    printf 'TITLE\tRecovered flows\n'
    printf 'DESC\tSubscriptions back to green after a red episode: their latest File is OK, but earlier in the window whole days ended on failures — did yesterday'\''s fix work?\n'
    printf 'KEYWORDS\trecovered, fixed, back to green, working again, resolved, healed, restored, outage over, fix worked, good news\n'
    printf 'INTRO\tThe GOOD-NEWS mirror of **From green to red** — did yesterday'\''s fix work? Of the **%s** subscription(s) with Files, **%s** are **green right now** (latest File OK) — and **%s** of those went through a **red episode** earlier in the window: at least one day that ended on a failed File. They are listed here, most recent recovery first, so a fix applied yesterday shows up at the top with its first OK Files. Click the Error count for the episode'\''s 10 most recent failed Files, the OK count for the freshest successes since.\n' \
        "$n_sites" "$n_green" "$n_rec"
    printf 'TABLE\tSubscriptions back to green after a red episode\twide\tnofilter\n'
    printf 'HEAD\tSubscription\tRed from\tRed until\tOutage days\tError Files in episode\tOK Files since\tRecovered on\n'
    printf 'KIND\tsite\ttext\ttext\tnum\tnumfailed\tnumprocessed\ttext\n'
    # Most recent recoveries first (the freshest fixes are the ones to check),
    # printed straight into the report — no per-row command substitution.
    while IFS='|' read -r _ site redfrom redto outage ff oks recov fdrill pdrill; do
        [ -z "$site" ] && continue
        n_rows=$((n_rows + 1)); sum_out=$((sum_out + outage)); sum_ff=$((sum_ff + ff)); sum_ok=$((sum_ok + oks))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n' \
            "$site" "$redfrom" "$redto" "$outage" "$ff" "$oks" "$recov" "$fdrill" "$pdrill"
    done <<< "$(printf '%s\n' "$agg" | grep '^S|' | LC_ALL=C sort -t'|' -k8,8r -k2,2)"
    if [ "$n_rows" -eq 0 ]; then
        printf 'ROW\t@{colspan=7}No subscription recovered from a red episode — every currently-green subscription stayed green all window (and From green to red lists the ones broken now).\n'
    fi
    printf 'TOTAL\tTotal (%s subscriptions)\t\t\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t\n' \
        "$n_rows" "$sum_out" "$sum_ff" "$sum_ok"
    printf 'NOTE\tA subscription is **green** when its LATEST File'\''s outcome is OK, **red** otherwise — the same rule that colors it site-wide (Waiting counts as OK, Expired as Error). The **episode** is the most recent run of consecutive active days that each ENDED on a failed File (a day with a failure but a later OK stays green, matching From green to red); "Recovered on" is the first active day after it, which by construction ended green. Outage days span the episode'\''s calendar days; Error Files count the episode'\''s failures, OK Files everything delivered since (dataset end: %s). An earlier, already-recovered episode of the same subscription is not shown — only the most recent one. **This table always shows the full period** — the flip back is a sequence in time, so a narrowed From/To range would fabricate or hide recoveries.\n' "$last_date"
    printf 'SUMMARY\tSubscriptions: %s  |  Green now: %s  |  Recovered from a red episode: %s  |  Error Files in those episodes: %s  |  OK Files since: %s\n' \
        "$n_sites" "$n_green" "$n_rec" "$sum_ff" "$sum_ok"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_rec of $n_green green subscription(s) recovered from a red episode)." >&2
