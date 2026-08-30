#!/usr/bin/env bash
#
# stuck-events.sh — internal event-queue / worker health, from two TM messages:
#   Detections  "Possible stuck events with expired heartbeat timeout detected.
#                Number of suspected events: N" — the worker found events whose
#                heartbeat expired (a poll/route event that isn't progressing).
#   Recovery    "Events recovery process has finished. … Number of recovered
#                events: N" — the periodic sweep that re-queues stuck events.
#
# This is queue/worker health, distinct from Scheduler Overruns (a poll running
# too long) and Concurrency (session load). A rising suspected-event gauge, or
# recoveries that lag detections, points at a stalled worker. Per-day view.
#
# Reads the parse cache (data/_parse.tsv). Writes data/stuck-events.rpt.
#
# Usage:
#   ./stuck-events.sh    # reads input/*.csv (via the cache), writes data/stuck-events.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/stuck-events.rpt"

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
#   D <TAB> date <TAB> detections <TAB> peaksuspected <TAB> first <TAB> last <TAB> loglines
#   R <TAB> date <TAB> runs <TAB> recovered <TAB> first <TAB> last <TAB> loglines
#   TOT <TAB> detections <TAB> peakoverall <TAB> recovered <TAB> runs <TAB> ndetdays
agg=$(awk -F'\t' "$LOGLINES_AWK"'
    function tm(t){ sub(/\.[0-9]+$/, "", t); return t }
    {
        m = $5
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        line = lvlname($3) " " compname($4) "  " substr(m, 1, 200)
        if (m ~ /stuck events with expired heartbeat/) {
            det[d]++; tdet++
            # counts >= 1,000 log with a thousands separator ("1,216") —
            # accept and strip it before the numeric read
            v = 0; if (match(m, /suspected events: [0-9][0-9,]*/)) { v = substr(m, RSTART+18, RLENGTH-18); gsub(/,/, "", v); v += 0 }
            if (v > peak[d]) peak[d] = v; if (v > peakall) peakall = v
            if (!(d in dfst) || $2 < dfst[d]) dfst[d] = $2; if (!(d in dlst) || $2 > dlst[d]) dlst[d] = $2
            addline("D" SUBSEP d, $1 " " $2, line)
        } else if (m ~ /Events recovery process has finished/) {
            rn[d]++; truns++
            r = 0; if (match(m, /recovered events: [0-9]+/)) r = substr(m, RSTART+18, RLENGTH-18)+0
            rec[d] += r; trec += r
            if (!(d in rfst) || $2 < rfst[d]) rfst[d] = $2; if (!(d in rlst) || $2 > rlst[d]) rlst[d] = $2
            addline("R" SUBSEP d, $1 " " $2, line)
        }
    }
    END {
        nd=0
        for (d in det) { nd++; printf "D\t%s\t%d\t%d\t%s\t%s\t%s\n", d, det[d], peak[d]+0, tm(dfst[d]), tm(dlst[d]), lastlines("D" SUBSEP d) }
        for (d in rn)  { printf "R\t%s\t%d\t%d\t%s\t%s\t%s\n", d, rn[d], rec[d]+0, tm(rfst[d]), tm(rlst[d]), lastlines("R" SUBSEP d) }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\n", tdet+0, peakall+0, trec+0, truns+0, nd+0
    }
' "$PARSED")

IFS=$'\t' read -r _ t_det peak_all t_rec t_runs n_days <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ $(( t_det + t_runs )) -eq 0 ]; then
    echo "No stuck-event / recovery messages found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

# Both row writers print STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
det_rows() {
    while IFS=$'\t' read -r _ d det peak fst lst lines; do
        [ -z "$d" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:loglines=%s\n' "$d" "$det" "$peak" "$fst" "$lst" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^D\t' | sort -t"$(printf '\t')" -k2,2)"
}

rec_rows() {
    while IFS=$'\t' read -r _ d runs rec fst lst lines; do
        [ -z "$d" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:loglines=%s\n' "$d" "$runs" "$rec" "$fst" "$lst" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^R\t' | sort -t"$(printf '\t')" -k2,2)"
}

{
    printf 'TITLE\tStuck Events\n'
    printf 'DESC\tInternal event-queue / worker health — detections of events whose heartbeat expired (stuck), and the recovery sweeps that re-queue them. Distinct from scheduler overruns and session concurrency.\n'
    printf 'INTRO\t**%s** stuck-event detection(s) over **%s** day(s), peaking at **%s** suspected event(s) at once, with **%s** recovery run(s) clearing **%s** event(s) in total. A rising suspected gauge, or recoveries that lag detections, points at a stalled worker. Click a day to see its 10 most recent messages.\n' \
        "$t_det" "$n_days" "$peak_all" "$t_runs" "$t_rec"

    printf 'TABLE\tStuck-event detections per day\twide\tnoagg=2\n'
    printf 'HEAD\tDate\tDetections\tPeak suspected\tFirst time\tLast time\n'
    printf 'KIND\ttext\tnumwarn\tnumwarn\ttext\ttext\n'
    det_rows
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num warn}%s\t\t\t\n' "$n_days" "$t_det"
    printf 'NOTE\tSource: "Possible stuck events with expired heartbeat timeout detected. Number of suspected events: N." Detections are additive; Peak suspected is the highest N that day and does not sum, so a narrowed range blanks its total. Click a day for its 10 most recent detections.\n'

    printf 'TABLE\tEvent recovery runs per day\n'
    printf 'HEAD\tDate\tRuns\tEvents recovered\tFirst time\tLast time\n'
    printf 'KIND\ttext\tnum\tnumprocessed\ttext\ttext\n'
    rec_rows
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num processed}%s\t\t\n' "$t_runs" "$t_rec"
    printf 'NOTE\tSource: "Events recovery process has finished. … Number of recovered events: N." The periodic sweep that re-queues stuck events; both columns are additive.\n'

    printf 'SUMMARY\tDetections: %s (peak %s)  |  Recovery runs: %s  |  Events recovered: %s\n' "$t_det" "$peak_all" "$t_runs" "$t_rec"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_det detection(s), peak $peak_all, $t_runs recovery run(s))." >&2
