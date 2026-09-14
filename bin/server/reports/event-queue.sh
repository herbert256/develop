#!/usr/bin/env bash
#
# event-queue.sh — "EventQueue" (2026-09-14, user request): the server-log
# lines whose message STARTS WITH
#
#   [Pesit Default] Unable to submit event AgentEvent
#
# — the PeSIT service reporting that it could not submit an agent event.
# Counted whatever the level. Two tables: Per day (lines, first and last
# time; the Date opens that day's page on its EventQueue chart view) and the
# newest 1000 Lines verbatim (cut at 300 characters). No prose on the page
# (help page server-event-queue).
#
# SIDECAR event-queue-slots.tsv — one "date <TAB> slot <TAB> lines" row per
# nonzero 30-minute slot (slot 0-47): the EventQueue chart view of the
# dashboards overview (summed to 1 hour .. 1 day, bin/dashboards/reports/
# overview.sh) and of every day page (30 minutes and 1 hour, bin/day/
# reports.sh) — the pesit-slots.tsv pattern.
#
# Reads the parse cache (data/server/cache/_parse.tsv: 1=date, 2=time,
# 3=level, 4=component, 5=message, 6=session).
#
# Usage:
#   ./event-queue.sh   # -> data/server/reports/event-queue.rpt + event-queue-slots.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/event-queue.rpt"
SLOTS="$REPORTS_DIR/event-queue-slots.tsv"
LCAP=1000   # the Lines table shows at most this many newest lines

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT" "$SLOTS"   # no server data — page not published
    exit 0
fi
ensure_parsed
[ -f "$SLOTS" ] || rm -f "$OUT"   # a missing sidecar must force a rebuild (skip_if_fresh checks $OUT only)
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

TMP=$(mktemp -d "${TMPDIR:-/tmp}/evq.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ONE pass over the cache: the per-day figures, the 30-minute slots and
# every matching line (to a file — sorted and capped below)
LC_ALL=C awk -F'\t' -v LINF="$TMP/lines" -v DAYF="$TMP/days" -v SLTF="$TMP/slots" "$LOGLINES_AWK"'
    index($5, "[Pesit Default] Unable to submit event AgentEvent") != 1 { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
        t = $2; n++
        D[d]++
        if (!(d in DF) || t < DF[d]) DF[d] = t
        if (!(d in DL) || t > DL[d]) DL[d] = t
        s = int((substr(t, 1, 2) * 60 + substr(t, 4, 2)) / 30)
        SL[d SUBSEP s]++
        m = $5; gsub(/\t/, " ", m); if (length(m) > 300) m = substr(m, 1, 300) "..."
        printf "%s %s\tROW\t%s %s\t%s\t%s\t%s\n", d, t, d, substr(t, 1, 8), lvlname($3), compname($4), m > LINF
    }
    END {
        for (d in D) printf "%s\tROW\t@{href=../day/%s.html?axway_hero=EventQueue}%s\t%d\t%s\t%s\n", d, d, d, D[d], substr(DF[d], 1, 8), substr(DL[d], 1, 8) > DAYF
        for (k in SL) { split(k, a, SUBSEP); printf "%s\t%d\t%d\n", a[1], a[2], SL[k] > SLTF }
        printf "%d\n", n + 0
    }
' "$PARSED" > "$TMP/total"
touch "$TMP/lines" "$TMP/days" "$TMP/slots"
n_lines=$(cat "$TMP/total")
n_days=$(wc -l < "$TMP/days" | tr -d ' ')
d_first=$(LC_ALL=C sort "$TMP/days" | awk -F'\t' 'NR == 1 { print $1 }')
d_last=$(LC_ALL=C sort -r "$TMP/days" | awk -F'\t' 'NR == 1 { print $1 }')
TAB=$(printf '\t')

LC_ALL=C sort -t"$TAB" -k1,1 -k2,2n "$TMP/slots" > "$SLOTS.tmp" && mv "$SLOTS.tmp" "$SLOTS"

{
    printf 'TITLE\tEventQueue\n'
    printf 'DESC\tThe server-log lines starting with "[Pesit Default] Unable to submit event AgentEvent" — the PeSIT service could not submit an agent event: per day and line by line, newest first.\n'
    printf 'KEYWORDS\teventqueue,event queue,agentevent,unable to submit event,pesit,pesit default,queue full,server log\n'
    printf 'TABLE\tPer day\tsort=0:-1\n'
    printf 'HEAD\tDate\tLines\tFirst\tLast\n'
    printf 'KIND\ttext\tnumwarn\ttext\ttext\n'
    LC_ALL=C sort -t"$TAB" -k1,1r "$TMP/days" | cut -f2-
    printf 'TOTAL\tTotal (%s days)\t@{class=num warn}%s\t\t\n' "${n_days:-0}" "${n_lines:-0}"
    printf 'TABLE\tLines\twide\tpager=100\tsort=0:-1\n'
    printf 'HEAD\tDate & time\tLevel\tComponent\tMessage\n'
    printf 'KIND\ttext\ttext\ttext\ttext\n'
    LC_ALL=C sort -t"$TAB" -k1,1r "$TMP/lines" | awk -v c="$LCAP" 'NR <= c' | cut -f2-
    printf 'SUMMARY\tEventQueue lines: %s  |  Days: %s  |  First: %s  |  Last: %s\n' "${n_lines:-0}" "${n_days:-0}" "${d_first:--}" "${d_last:--}"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${n_lines:-0} EventQueue line(s) on ${n_days:-0} day(s))." >&2
