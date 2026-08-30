#!/usr/bin/env bash
#
# bin/server/publish.sh — render the server area of the site:
#   docs/server/<name>.html    (one per server report .rpt, split into per-table
#                               pages where the report has tabs)
#
# The report scripts (bin/server/reports.sh) must have written the .rpt files
# first; the index pages are written afterwards by bin/build/publish.sh. If there are
# no server reports, the server area is dropped. This step never touches the
# input CSVs — it reads whatever .rpt are on disk.
#
# Usage:  bin/server/publish.sh    (run after the server reports)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; defines the renderer

ensure_assets   # ALWAYS — see the note in bin/transfer/publish.sh

# The server .rpt tree, plus the transfer detail slugmaps its @{alink=} cells
# resolve entity links through and the config caches carrying the cell tints.
STAMP="$PUBLISH_STAMP_DIR/server.stamp"
if publish_is_fresh "$STAMP" "$DOCS/server" "${BASH_SOURCE[0]}" \
       "$DATA/server/reports" "$DATA/transfer/reports/details" "$DATA/flow-manager"; then
    echo "docs/$SITE_ENV/server/ is up to date; skipping." >&2
    exit 0
fi

# Guard the expansion: under `set -u`, bash 3.2 errors on "${empty_array[@]}".
if [ ${#server_order[@]} -eq 0 ]; then
    rm -rf "$DOCS/server"   # no server reports -> drop the (now stale) server area
    echo "No server reports; dropped docs/server/." >&2
    exit 0
fi

mkdir -p "$DOCS/server"
rm -f "$DOCS"/server/*.html   # clear stale report pages (the index is rewritten by bin/build/publish.sh)

# SUBSCRIPTION ROW TINTS (2026-08): every server table with a Subscription
# column paints its rows in that subscription's RESULT colour — the same tint
# the entity pages and the Entities views give it, so a server report reads as
# "which of these flows is actually broken" without a lookup. The renderer
# decides per table (it needs the header) and leaves a row the report tinted
# itself alone; the accounts cache is second because deploy-errors' one column
# names either kind. Error/OK cells keep their own background (the restint CSS
# excludes .failed/.processed).
RPT_SUBTINT="$DATA/flow-manager/base/_subscriptions.tsv $DATA/flow-manager/base/_accounts.tsv"
[ -f "${RPT_SUBTINT%% *}" ] || RPT_SUBTINT=""

count=0
CUR_DATES=$SERVER_DATES
for name in "${server_order[@]}"; do
    # the Subscriptions analyses group renders from bin/analyses/publish.sh —
    # it owns (and clears) docs/<env>/analyses/ and runs AFTER this script
    if is_subs_report "$name"; then continue; fi
    rpt="$DATA/server/reports/$name.rpt"
    [ -f "$rpt" ] || { echo "  (no data yet: $name)" >&2; continue; }
    pub_run render_report "server" "$name" "$rpt"
    count=$((count + 1))
done
pub_wait

# Redirect stubs were REMOVED 2026-07 (no backwards compatibility): the old
# failed-logins/logon/pesit-problems URLs 404.

echo "Rendered docs/server/ ($count report(s))." >&2

# Every menu/sitemap/group-tab option must exist in this env: write an
# empty-report placeholder for each order-listed report without a .rpt here.
render_missing_reports server

publish_stamp "$STAMP"
