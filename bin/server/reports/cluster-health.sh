#!/usr/bin/env bash
#
# cluster-health.sh — the platform's own infrastructure story: daemon lifecycle,
# service watchdog and cluster/streaming health. Two views:
#   Daemon & service events   protocol daemons starting/stopping ("Starting SSH
#                             server with name …", "Daemon SSH stopped.", bind/
#                             listener lines) and the watchdog's "Service …
#                             appears to be unresponsive or stopped" warnings.
#   Cluster distress          the low-volume, high-signal warnings: Oracle
#                             Coherence cluster formation delays, "No peer has
#                             been selected by the dispatch policy", "Streaming
#                             not ready yet", streaming completion-token timeouts.
#
# No other report reads these messages: a daemon that restarted twelve times in
# a month is invisible in the transfer logs by design.
# Reads the parse cache (data/_parse.tsv). Writes data/cluster-health.rpt.
#
# Usage:
#   ./cluster-health.sh    # reads input/*.csv (via the cache), writes data/cluster-health.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/cluster-health.rpt"

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

# One pass. Emits TAB-separated:
#   D <TAB> signal <TAB> count <TAB> comps <TAB> buckets <TAB> first <TAB> last <TAB> loglines   (daemon/service events)
#   X <TAB> signal <TAB> count <TAB> comps <TAB> buckets <TAB> first <TAB> last <TAB> loglines   (cluster distress)
#   TOT <TAB> devt <TAB> ndev <TAB> xevt <TAB> nx <TAB> starts <TAB> stops <TAB> watchdog
agg=$(awk -F'\t' "$LOGLINES_AWK"'
    function acc(ns, cat, d, cn,   k, dk) { k = ns SUBSEP cat; cnt[k]++
        if (cn != "" && !index(comps[k], cn)) comps[k] = comps[k] (comps[k] ? "/" : "") cn
        if (d != "") { dk = k SUBSEP d; dd[dk]++
            if (!(dk in dseen)) { dseen[dk]=1; dlist[k] = dlist[k] (dlist[k]?",":"") d }
            if (!(k in fst) || d < fst[k]) fst[k]=d
            if (!(k in lst) || d > lst[k]) lst[k]=d } }
    {
        m = $5
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        line = lvlname($3) " " compname($4) "  " substr(m, 1, 200)

        # --- daemon & service events ---
        cat = ""; x = ""
        if (m ~ /^Starting [A-Za-z]+ server with name /) {
            split(m, w, " "); cat = w[2] " daemon starting"; starts++
        }
        else if (m ~ /^Stopping [A-Za-z]+ server with name /) {
            split(m, w, " "); cat = w[2] " daemon stopping"; stops++
        }
        else if (m ~ /^Daemon SSH stopped/)                     cat = "SSH daemon stopped"
        else if (m ~ /^Got request to shutdown SSH daemon/)     cat = "SSH daemon shutdown requested"
        else if (m ~ /^SSH listener started listening on port/) cat = "SSH listener bound"
        else if (m ~ /^Bind addresses:/)                        cat = "Daemon bind addresses set"
        else if (m ~ /appears to be unresponsive or stopped/) { cat = "Service unresponsive (watchdog)"; watchdog++ }
        else if (m ~ /^Invalid shutdown command/)               cat = "Invalid shutdown command"
        # --- cluster distress ---
        else if ($3 != "I" && m ~ /Oracle Coherence/)                  x = "Coherence cluster warning"
        else if (m ~ /No peer has been selected by the dispatch policy/) x = "No streaming peer selectable"
        else if (m ~ /^Streaming not ready yet/)                       x = "Streaming not ready"
        else if (m ~ /Timing out - AsynchronousCompletionToken/)       x = "Streaming completion timeout"

        if (cat != "") { acc("D", cat, d, compname($4)); devt++
            addline("D" SUBSEP cat, $1 " " $2, line) }
        else if (x != "") { acc("X", x, d, compname($4)); xevt++
            addline("X" SUBSEP x, $1 " " $2, line) }
    }
    END {
        ndev=0; nx=0
        for (k in cnt) {
            split(k, a, SUBSEP); nsp=a[1]; cat=a[2]
            m2 = split(dlist[k], dz, ","); bk=""
            for (i=1;i<=m2;i++){ dd2=dz[i]; bk=bk (bk?",":"") dd2 ":" dd[k SUBSEP dd2] }
            if (nsp=="D") ndev++; else nx++
            printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", nsp, cat, cnt[k], comps[k], bk, fst[k], lst[k], lastlines(k)
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", devt+0, ndev, xevt+0, nx, starts+0, stops+0, watchdog+0
    }
' "$PARSED")

IFS=$'\t' read -r _ t_dev n_dev t_x n_x t_starts t_stops t_watch <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ $(( ${t_dev:-0} + ${t_x:-0} )) -eq 0 ]; then
    # No cluster/service messages in this log window — write an EMPTY-STATE page
    # (so the report still renders and its group-nav link never 404s) and exit 0.
    echo "No cluster/service health messages found — writing an empty report." >&2
    {
        printf 'TITLE\tCluster & Service Health\n'
        printf 'DESC\tDaemon lifecycle events, service-watchdog warnings and cluster distress signals — the platform infrastructure story the transfer logs cannot show.\n'
    printf 'KEYWORDS\tCoherence, restart, unresponsive, dispatch policy, bind, listener\n'
        printf 'INTRO\tNo daemon, watchdog or cluster messages in this log window.\n'
        printf 'TABLE\tDaemon & service events\twide\n'
        printf 'HEAD\tSignal\tCount\tComponent\tFirst\tLast\n'
        printf 'KIND\ttext\tnum\ttext\ttext\ttext\n'
        printf 'ROW\t@{colspan=5}No daemon, watchdog or cluster messages in this data window.\n'
        printf 'SUMMARY\tCluster/service events: 0\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    exit 0
fi

sig_rows() {   # $1 = namespace (D|X)
    while IFS=$'\t' read -r _ cat count comps bk fst lst lines; do
        [ -z "$cat" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$cat" "$count" "$comps" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $"^$1"$'\t' | sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

{
    printf 'TITLE\tCluster & Service Health\n'
    printf 'DESC\tDaemon lifecycle events, service-watchdog warnings and cluster distress signals — the platform infrastructure story the transfer logs cannot show.\n'
    printf 'KEYWORDS\tCoherence, restart, unresponsive, dispatch policy, bind, listener\n'
    printf 'INTRO\tThe platform'\''s own health: **%s** daemon/service event(s) (**%s** daemon start(s), **%s** stop(s), **%s** watchdog unresponsive-service warning(s)) and **%s** cluster distress signal(s). A daemon restart never reaches the transfer logs — this page is where it shows. Click a row for its 10 most recent messages.\n' \
        "$t_dev" "$t_starts" "$t_stops" "$t_watch" "$t_x"

    if [ "${t_dev:-0}" -gt 0 ]; then
        printf 'TABLE\tDaemon & service events\twide\n'
        printf 'HEAD\tSignal\tCount\tComponent\tFirst\tLast\n'
        printf 'KIND\ttext\tnum\ttext\ttext\ttext\n'
        printf 'RECALC\t-\ts0\t-\t-\t-\n'
        printf '%s\n' "$(sig_rows D)"
        printf 'TOTAL\tTotal (%s signal(s))\t@{class=num}%s\t\t\t\n' "$n_dev" "$t_dev"
        printf 'NOTE\tProtocol daemons starting/stopping (each restart logs several lines: the stop/shutdown request, then the start, bind and listener lines) and the watchdog'\''s "Service … appears to be unresponsive or stopped" warnings. Counts are additive and re-total under the date filter. Click a signal for its 10 most recent messages.\n'
    fi

    if [ "${t_x:-0}" -gt 0 ]; then
        printf 'TABLE\tCluster distress signals\n'
        printf 'HEAD\tSignal\tCount\tComponent\tFirst\tLast\n'
        printf 'KIND\ttext\tnumwarn\ttext\ttext\ttext\n'
        printf 'RECALC\t-\ts0\t-\t-\t-\n'
        printf '%s\n' "$(sig_rows X)"
        printf 'TOTAL\tTotal (%s signal(s))\t@{class=num warn}%s\t\t\t\n' "$n_x" "$t_x"
        printf 'NOTE\tLow-volume but high-signal warnings from the streaming/cluster layer: Oracle Coherence cluster-formation delays, the dispatch policy finding no usable peer, streaming not ready, and streaming completion-token timeouts. Any sustained rise here deserves attention before it becomes transfer failures.\n'
    fi

    printf 'SUMMARY\tDaemon/service events: %s (%s starts, %s stops)  |  Watchdog warnings: %s  |  Distress signals: %s\n' \
        "$t_dev" "$t_starts" "$t_stops" "$t_watch" "$t_x"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_dev daemon event(s), $t_x distress)." >&2
