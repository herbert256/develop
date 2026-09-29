#!/usr/bin/env bash
#
# episodes.sh — failure EPISODES and OPEN INCIDENTS per subscription. Every
# other failure report shows failure RATES; this one shows failure RUNS IN
# TIME: consecutive failed Files collapsed into episodes, with how long each
# outage lasted before the next OK (time to recovery) — and, as the headline,
# the subscriptions that are broken RIGHT NOW (their latest File failed, with
# 3+ consecutive failures behind it — counted in the SUMMARY; the Open
# incidents TABLE went 2026-09-29: Failed Subscriptions lists every red flow
# with its Failures in a row, Days red and Last green day). Two views over
# logical transfers (_files.tsv, delivered outcome, chronological per
# subscription):
#   Episodes per subscription  every subscription with failures: episode count,
#                         longest run, and how its closed episodes healed
#                         (within an hour / within a day / longer).
#   Time to recovery      the distribution over all closed episodes.
#
# Full-period semantics (`nofilter`, like stale-accounts): an episode is a
# sequence in time, so narrowing the date range would break the runs.
#
# Reads data/_files.tsv (2=outcome, 4=date_iso, 5=time, 6=sortkey,
# 12=dest_site), sorted per subscription. Writes data/episodes.rpt.
#
# Usage:
#   ./episodes.sh    # reads input/*.csv (via the cache), writes data/episodes.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/episodes-src.rpt"   # a component since 2026-09-29: merge-episodes.sh adds the Recovered flows tab

OPEN_MIN=3   # consecutive tail failures at/above which an incident is "open"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Stream _files.tsv grouped by subscription, chronological inside each group.
# Emits pipe-separated (drill lists carry no pipes):
#   S|site|files|fails|episodes|maxrun|lastok|r1h|r24|rgt|drill
#   TOT|sites|nfail|open|worsttail|closed|b5m|b1h|b24|b3d|bgt|neverok|maxrecdays
agg=$(LC_ALL=C sort -t"$(printf '\t')" -k12,12 -k6,6 "$FILES" | awk -F'\t' -v OPENMIN="$OPEN_MIN" "$COREIDS_AWK"'
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function tsec(d,t){ split(d,p,"-"); return jdn(p[1]+0,p[2]+0,p[3]+0)*86400 + substr(t,1,2)*3600 + substr(t,4,2)*60 + substr(t,7,2) }
    function flush(   i) {
        if (site == "") return
        n++
        L[n] = site "|" files "|" fails "|" episodes "|" maxrun "|" lastok "|" r1h+0 "|" r24+0 "|" rgt+0 "|" buildlist(top["F" SUBSEP site])
        if (fails > 0) nfail++
        if (run >= OPENMIN) { open++; if (run > worsttail) worsttail = run
            if (lastok == "") neverok++ }
    }
    $12 == "" || $4 == "" { next }
    {
        if ($12 != site) { flush()
            site = $12; files=0; fails=0; episodes=0; maxrun=0; run=0
            lastok=""; r1h=0; r24=0; rgt=0 }
        files++
        if ($2 != "Failed" && $2 != "Expired") {
            if (run > 0) {  # an episode just closed: time to recovery
                rec = tsec($4, $5) - fs; closed++
                if      (rec <= 300)    b5m++
                else if (rec <= 3600)   b1h++
                else if (rec <= 86400)  b24++
                else if (rec <= 259200) b3d++
                else                    bgt++
                if      (rec <= 3600)  r1h++
                else if (rec <= 86400) r24++
                else                   rgt++
                if (rec > maxrec) maxrec = rec
            }
            run = 0; lastok = $4
        } else {
            fails++
            if (run == 0) { episodes++; fs = tsec($4, $5) }
            run++
            if (run > maxrun) maxrun = run
            addtop("F" SUBSEP site, $6, $4 " " $5, $1)
        }
    }
    END {
        flush()
        for (i = 1; i <= n; i++) print "S|" L[i]
        printf "TOT|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%.1f\n", n+0, nfail+0, open+0, worsttail+0, closed+0, b5m+0, b1h+0, b24+0, b3d+0, bgt+0, neverok+0, maxrec/86400
    }
' OPENMIN="$OPEN_MIN")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ n_sites n_fail n_open worst_tail n_closed b5m b1h b24 b3d bgt n_neverok max_rec <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"

# S fields: 2=site 3=files 4=fails 5=episodes 6=maxrun 7=lastok 8=r1h 9=r24
#           10=rgt 11=drill
# ONE awk pass per view formats the sorted stream into finished ROW lines
# (filter included) — a bash while-read with a $(printf) per row forked a
# subshell per subscription. The drill takes the line's remainder, like read
# into the final variable did.
ep_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | LC_ALL=C sort -t'|' -k5,5nr -k6,6nr -k2,2 | awk -F'|' '
    $2 == "" { next }
    $4 + 0 > 0 {
        ok = $7; if (ok == "") ok = "@{class=failed}never"
        d = $11; for (i = 12; i <= NF; i++) d = d "|" $i
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\n", $2, $3, $4, $5, $6, $8, $9, $10, ok, d }')
[ -n "$ep_rows" ] && ep_rows+=$'\n'
[ -z "$ep_rows" ] && ep_rows='ROW	@{colspan=9}No failed Files in this data window.'$'\n'

rec_rows=""
if [ "${n_closed:-0}" -gt 0 ]; then
    for pair in "Within 5 minutes|$b5m" "5 minutes - 1 hour|$b1h" "1 - 24 hours|$b24" "1 - 3 days|$b3d" "Over 3 days|$bgt"; do
        lbl=${pair%|*}; cnt=${pair#*|}
        sh=$(awk -v c="$cnt" -v t="$n_closed" 'BEGIN{printf "%.1f", t? c*100/t : 0}')
        cell=$cnt; case $lbl in "1 - 3 days"|"Over 3 days") [ "$cnt" -gt 0 ] && cell="@{class=failed}$cnt" ;; esac
        rec_rows+=$(printf 'ROW\t%s\t%s\t%s%%' "$lbl" "$cell" "$sh")
        rec_rows+=$'\n'
    done
else
    rec_rows=$(printf 'ROW\t@{colspan=3}No closed episodes (no failure was followed by an OK) in this data window.')$'\n'
fi

{
    printf 'TITLE\tEpisodes\n'   # = its Reports menu label (2026-09-29)
    printf 'DESC\tConsecutive failures collapsed into episodes: how often each subscription breaks, and how long outages last before they recover.\n'
    printf 'KEYWORDS\topen incident, outage, broken, recovery, consecutive failures, time to recovery, never delivered\n'
    printf 'INTRO\tFailure RUNS in time, per subscription: **%s** of **%s** subscription(s) failed at least once; **%s** are in an **open incident** right now (latest File failed, %s+ consecutive failures — worst run: **%s**), **%s** of them have NEVER delivered an OK File. Of the **%s** closed episode(s), most self-heal quickly but the slow tail is real (longest recovery: **%s** days). The other failure reports show failure rates; this one shows how failures cluster and how long they last. Click a row for its 10 most recent failed Files.\n' \
        "$n_fail" "$n_sites" "$n_open" "$OPEN_MIN" "$worst_tail" "$n_neverok" "$n_closed" "$max_rec"

    # tab=episodes (2026-09-29): the two tables ride ONE tab of the Episodes page
    printf 'TABLE\tEpisodes per subscription\twide\tnofilter\ttab=episodes\n'
    printf 'HEAD\tSubscription\tFiles\tError\tEpisodes\tLongest run\tHealed <= 1 h\t1 - 24 h\tOver 24 h\tLast OK\n'
    printf 'KIND\tsite\tnum\tnumfailed\tnum\tnum\tnumprocessed\tnum\tnumwarn\ttext\n'
    printf '%s' "$ep_rows"
    printf 'NOTE\tOne episode = an unbroken run of failed Files ended by the next OK (or still open). The healed columns split the CLOSED episodes by their time to recovery; a subscription with many quick-healing episodes flaps, one with few long ones breaks hard. Sorted by episode count. Click the Error count for the 10 most recent failed Files.\n'

    printf 'TABLE\tTime to recovery\tnofilter\ttab=episodes\n'
    printf 'HEAD\tRecovered within\tEpisodes\tShare\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf '%s' "$rec_rows"
    printf 'TOTAL\tTotal (closed episodes)\t@{class=num}%s\t100.0%%\n' "$n_closed"
    printf 'NOTE\tThe distribution over all closed episodes: from the episode'\''s first failure to the next OK File of the same subscription. Open incidents (no OK yet) are not counted here.\n'

    printf 'SUMMARY\tSubscriptions with failures: %s of %s  |  Open incidents: %s (worst run %s, never-OK %s)  |  Closed episodes: %s  |  Longest recovery: %s days\n' \
        "$n_fail" "$n_sites" "$n_open" "$worst_tail" "$n_neverok" "$n_closed" "$max_rec"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_sites subscription(s), $n_open open incident(s), $n_closed closed episode(s))." >&2
