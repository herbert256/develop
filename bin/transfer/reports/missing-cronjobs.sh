#!/usr/bin/env bash
#
# missing-cronjobs.sh
# The counterpart gap of the Cronjobs page: a configured subscription whose use
# case is CRON-TRIGGERED (uc_meta's trigger == "Cronjob" — UC3, and UC5's pull
# side) but which carries NO cron expression at all, so nothing ever makes it
# poll. UC1 is a client use case too, but it pushes on directory scanning rather
# than on a timer, so it is never flagged.
#
# This is the quietest failure mode on the site. Every other subscription signal
# needs the flow to have RUN at least once — something has to connect, fail or
# stage a file before there is anything to notice. A subscription with no cron
# expression never gets that far: no poll, no file, no error, and nothing in
# either log. It is invisible to every report that works from observed activity,
# and can sit in the configuration indefinitely looking like a flow that simply
# has nothing to fetch.
#
# PURE CONFIGURATION — the only transfer report that reads no log at all. It
# takes the FlowManager subscriptions export directly (the cron expressions live
# in .parameters, which bin/flow-manager.sh's caches do not carry), so the answer
# is the same whatever date range is being viewed and the table is `nofilter`.
# The report was a table on the analyses Cronjobs page until 2026-07, then its
# own analyses page, and is a transfer report from 2026-07 so its page and its
# script sit with the other subscription problems.
#
# Reads input/<env>/flow-manager/subscriptions.json (jq) + bin/uc-cases.sh.
# Writes data/<env>/transfer/reports/missing-cronjobs.rpt.
#
# Usage:
#   ./missing-cronjobs.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../uc-cases.sh"    # uc_meta: which use cases are cron-triggered
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/missing-cronjobs.rpt"

SUBJSON="$FM_INPUT_DIR/subscriptions.json"
if [ ! -f "$SUBJSON" ] || ! command -v jq >/dev/null 2>&1; then
    echo "No $SUBJSON (or no jq) — skipping missing-cronjobs." >&2
    rm -f "$OUT"          # no config for this ENV — page not published
    exit 0
fi
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SUBJSON" "$SCRIPT_DIR/../../uc-cases.sh"

# the cron-triggered use cases, from the one place that defines them
cron_ucs=""
for u in UC1 UC2 UC3 UC4 UC5 UC6 UC7 UC8; do
    [ "$(uc_meta "$u" | cut -f7)" = "Cronjob" ] && cron_ucs+="${cron_ucs:+|}$u"
done
if [ -z "$cron_ucs" ]; then
    echo "No cron-triggered use case in uc-cases.sh — skipping." >&2
    rm -f "$OUT"
    exit 0
fi
uclist=$(printf '%s' "$cron_ucs" | sed 's/|/, /g')

# A subscription of a cron use case with NO parameter whose name contains "cron"
# holding a non-empty value. Name-sorted, case-insensitively.
rows=$(jq -r --arg re "^($cron_ucs)_" '
        .[] | select(.name | test($re))
        | select([.parameters // {} | to_entries[]
                  | select(.key | test("cron")) | select(.value != null and .value != "")] | length == 0)
        | [ .name, (.name | capture("^(?<uc>UC[0-9]+)").uc) ] | @tsv
      ' "$SUBJSON" | LC_ALL=C sort -f)
nmiss=$(printf '%s\n' "$rows" | grep -c . || true)

{
    printf 'TITLE\tMissing cronjobs\n'
    printf 'DESC\tSubscriptions of a cron-triggered use case with no cron expression at all: nothing ever makes them poll, so they never run and leave no trace in either log.\n'
    if [ "$nmiss" -eq 0 ]; then
        printf 'INTRO\tEvery subscription of a cron-triggered use case (**%s**) has a cron expression configured. Nothing to report.\n' "$uclist"
    else
        printf 'INTRO\t**%s** subscription(s) of a cron-triggered use case (**%s**) have **no cron expression** configured, so nothing ever makes them poll the partner. Where we are the client and PULL, a Quartz cron expression is the ONLY thing that starts the flow — without one the subscription is complete in every other respect and simply never runs: no poll, no file, no error, and nothing in either log to notice. The schedules that ARE configured are on **Cronjobs**.\n' \
            "$nmiss" "$uclist"
    fi

    printf 'STAT\tred\t%s\tMissing a cronjob\n' "$nmiss"

    printf 'TABLE\tSubscriptions that can never poll\tnofilter\tnosearch\n'
    printf 'HEAD\tSubscription\tUse case\n'
    printf 'KIND\tsite\ttext\n'
    if [ "$nmiss" -eq 0 ]; then
        printf 'ROW\t@{colspan=2}Every cron-triggered subscription has a cron expression.\n'
    else
        # every row is a configuration gap, so every row is tinted the same
        printf '%s\n' "$rows" | awk -F'\t' 'NF && $1 != "" { printf "ROW\t%s\t%s\t@data:res=orange\n", $1, $2 }'
    fi
    printf 'TOTAL\tTotal (%s subscription(s))\t\n' "$nmiss"
    printf 'NOTE\tSource: the **subscriptions.json** export directly — the cron expressions live in each subscription'"'"'s `parameters`, which the config caches do not carry. This is PURE CONFIGURATION and reads no log, so the answer does not change with the date range and the table carries no date filter. A use case counts as cron-triggered when **uc-cases.sh** gives it the trigger "Cronjob" (%s today), so the list follows the use-case definitions rather than a hardcoded set here; **UC1** is a client use case too, but pushes on directory scanning, so it is never flagged.\n' "$uclist"
    printf 'KEYWORDS\tcron, cronjob, quartz, schedule, missing, no schedule, never polls, never runs, uc3, uc5, configuration gap\n'
    printf 'SUMMARY\tMissing a cronjob: %s subscription(s)  |  Cron-triggered use cases: %s\n' "$nmiss" "$uclist"
    printf 'FOOT\tGenerated on %s from the FlowManager subscriptions export\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($nmiss subscription(s) with no cron expression)." >&2
