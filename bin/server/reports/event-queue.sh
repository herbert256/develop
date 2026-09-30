#!/usr/bin/env bash
#
# event-queue.sh — "EventQueue" (2026-09-14, user request): the server-log
# lines whose message STARTS WITH
#
#   [Pesit Default] Unable to submit event AgentEvent
#
# — the PeSIT service reporting that it could not submit an agent event.
# Counted whatever the level. NO PAGE since 2026-09-27 (user request: the
# Operations & Capacity group went) and NO .rpt since 2026-09-29 (its per-day
# table had no reader but bin/sample/verify.sh) — the sidecar below is what
# the site uses.
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
#   ./event-queue.sh   # -> data/server/reports/event-queue-slots.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
SLOTS="$REPORTS_DIR/event-queue-slots.tsv"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$SLOTS"   # no server data
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

TMP=$(mktemp -d "${TMPDIR:-/tmp}/evq.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ONE pass over the cache: the 30-minute slots
LC_ALL=C awk -F'\t' -v SLTF="$TMP/slots" '
    index($5, "[Pesit Default] Unable to submit event AgentEvent") != 1 { next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
        t = $2; n++
        s = int((substr(t, 1, 2) * 60 + substr(t, 4, 2)) / 30)
        SL[d SUBSEP s]++
    }
    END {
        for (k in SL) { split(k, a, SUBSEP); printf "%s\t%d\t%d\n", a[1], a[2], SL[k] > SLTF }
        printf "%d\n", n + 0
    }
' "$(srv_subset event-queue)" > "$TMP/total"   # its marker subset (2026-09-30)
touch "$TMP/slots"
n_lines=$(cat "$TMP/total")
TAB=$(printf '\t')

LC_ALL=C sort -t"$TAB" -k1,1 -k2,2n "$TMP/slots" > "$SLOTS.tmp" && mv "$SLOTS.tmp" "$SLOTS"

echo "Data written to $SLOTS (${n_lines:-0} EventQueue line(s))." >&2
