#!/usr/bin/env bash
#
# missing-cronjobs.sh
# The counterpart gap of the Configured cronjobs table (UC status / UC3 tab since
# 2026-09-05, the analyses Cronjobs page before): a configured subscription whose use
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
# The report was a table on the analyses Cronjobs page until 2026-07 (that page
# itself folded into the UC3 tab 2026-09-05), then its
# own analyses page, and is a transfer report from 2026-07 so its page and its
# script sit with the other subscription problems.
#
# Reads input/flow-manager/subscriptions.json (jq) + bin/uc-cases.sh.
# Writes data/transfer/reports/missing-cronjobs.rpt.
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
# the DERIVED use case map (bin/flow-manager.sh): a production hybrid flow
# carries no UC prefix, so the name test alone made this page a false
# all-clear for exactly the flows it exists to catch (2026-08-31 audit)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null

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

# A subscription of a cron use case — UC-NAMED, or DERIVED as one (the
# name -> use case object below, cron use cases only) — with NO parameter whose
# name contains "cron" holding a non-empty value. Name-sorted, case-insensitively.
ucd_json=$(awk -F'\t' -v re="^($cron_ucs)\$" 'BEGIN { printf "{" } $2 ~ re && $1 != "" { printf "%s\"%s\":\"%s\"", (n++ ? "," : ""), $1, $2 } END { printf "}" }' "$UCDF")
rows=$(jq -r --arg re "^($cron_ucs)_" --argjson ucd "$ucd_json" '
        .[] | select((.name | test($re)) or ($ucd[.name] != null))
        | select([.parameters // {} | to_entries[]
                  | select(.key | test("cron")) | select(.value != null and .value != "")] | length == 0)
        | .name
      ' "$SUBJSON" | LC_ALL=C sort -f)
nmiss=$(printf '%s\n' "$rows" | grep -c . || true)

{
    printf 'TITLE\tMissing cronjobs\n'

    # PAGELESS: its reader, reason-boxes.sh box 9, takes ROW field 2 (the
    # Polling page shows the rows as Schedule "no cron" from its own join) —
    # the Use case column, the row tint, the empty-state row and the TOTAL
    # went with the second 2026-09-29 audit
    printf 'TABLE\tSubscriptions that can never poll\n'
    printf 'HEAD\tSubscription\n'
    [ "$nmiss" -eq 0 ] || printf '%s\n' "$rows" | awk 'NF && $1 != "" { printf "ROW\t%s\n", $0 }'
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($nmiss subscription(s) with no cron expression)." >&2
