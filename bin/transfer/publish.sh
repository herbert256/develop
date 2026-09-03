#!/usr/bin/env bash
#
# bin/transfer/publish.sh — render the transfer area of the site:
#   docs/transfer/<name>.html        (one per transfer report .rpt, split into
#                                      per-table pages where the report has tabs)
#   docs/details/<sub>/<slug>.html    (one per account/subscription/login/host/
#                                      plus a browsable index per subdir)
#
# The report scripts (bin/transfer/reports.sh) must have written the .rpt files
# first; the index pages are written afterwards by bin/build/publish.sh. Reads whatever
# .rpt are on disk, so for HTML/CSS iteration keep them around (run the reports
# once) — this step never touches the input CSVs.
#
# Usage:  bin/transfer/publish.sh    (run after the transfer reports)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; defines the renderer

ensure_assets   # ALWAYS — topbar-data.js must refresh even on a fully skipped
                # publish (a MENU change needs no page re-render, only the data
                # file). The build-stamp asset it also used to write went with
                # the footer bar in 2026-07.

# Nothing to re-render when no .rpt (or config cache, which colours the entity
# cells) has changed since the last completed run. The whole reports tree is
# one dep: it holds the detail .rpt and slugmaps the entity links resolve
# through, so a details.sh rerun correctly invalidates these pages too.
STAMP="$PUBLISH_STAMP_DIR/transfer.stamp"
if publish_is_fresh "$STAMP" "$DOCS/transfer" "${BASH_SOURCE[0]}" \
       "$DATA/transfer/reports" "$DATA/flow-manager" \
       "$DATA/server/reports/_kaput-evidence.tsv" "$DATA/analyses/reports/_subs-boxes.tsv" \
       "$DATA/blue/_redflip.tsv" "bin/flip-reason.awk"; then
    echo "docs/$SITE_ENV/transfer/ is up to date; skipping." >&2
    exit 0
fi

mkdir -p "$DOCS/transfer"
rm -f "$DOCS"/transfer/*.html   # clear stale report pages (the index is rewritten by bin/build/publish.sh)
mkdir -p "$DOCS/transfer/entities"
rm -f "$DOCS"/transfer/entities/*.html   # the Entities All/Seen/Not seen/Server/OK/Warning/Error pages (render_entity_report)
mkdir -p "$DOCS/analyses/xref"
rm -f "$DOCS"/analyses/xref/*.html       # the cross-reference pages (render_report's cross-* branch, now under analyses/)
rm -rf "$DOCS/transfer/xref"             # the cross pages moved to analyses/xref/ (2026-07) — drop the old dir

# (the per-entity detail pages moved to bin/transfer/publish-details.sh —
# their OWN bin/build.sh step since 2026-07)

# ---- render -----------------------------------------------------------------

count=0
CUR_DATES=$TRANSFER_DATES
for name in "${transfer_order[@]}"; do
    # the Subscriptions analyses group renders from bin/analyses/publish.sh —
    # it owns (and clears) docs/<env>/analyses/ and runs AFTER this script
    if is_subs_report "$name"; then continue; fi
    rpt="$DATA/transfer/reports/$name.rpt"
    [ -f "$rpt" ] || { echo "  (no data yet: $name)" >&2; continue; }
    pub_run render_report "transfer" "$name" "$rpt"
    count=$((count + 1))
done

# The per-value Skipped reports (skipped-<slug>.rpt) are DYNAMIC — one per
# input/<env>/skip.txt value, not in transfer_order — so render whatever skipped.sh
# produced (the button row + finder/sitemap entries come from skipped_tokens).
for rpt in "$DATA"/transfer/reports/skipped-*.rpt; do
    [ -f "$rpt" ] || continue
    name=${rpt##*/}; name=${name%.rpt}
    pub_run render_report "transfer" "$name" "$rpt"
    count=$((count + 1))
done
pub_wait

# Duration report: per-transaction detail pages (the top-N longest transfers),
# each listing ALL of that transfer's _transfers.tsv records. duration.sh wrote
# one .rpt per transfer into data/transfer/reports/duration/top/; render each
# to docs/transfers/duration/top/<coreid>.html (3 levels deep -> ../../../ css).
# The Duration report's "Top N longest" table links its first 3 columns here.
shopt -s nullglob
dtop=("$DATA"/transfer/reports/duration/top/*.rpt)
shopt -u nullglob
# clear even when THIS run has no .rpt set (an env can lose the whole
# family — production 2026-08 — and stale pages would survive forever)
mkdir -p "$DOCS/transfers/duration/top"
rm -f "$DOCS"/transfers/duration/top/*.html
if [ ${#dtop[@]} -gt 0 ]; then
    CUR_DATES=""; DLINK_BASE="../../../details/"
    for f in "${dtop[@]}"; do
        b=${f##*/}; b=${b%.rpt}
        pub_run render_rpt "$f" "$DOCS/transfers/duration/top/$b.html" "../../../assets/style.css" "../../../index.html" "TRANSFER" "" "duration"
    done
    pub_wait
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
    echo "Rendered docs/transfers/duration/top/ (${#dtop[@]} transaction page(s))." >&2
fi

# Seen-in-server-log matrix cell pages: seen-in-server-log.sh wrote one .rpt
# per nonzero "Why blue" cell into data/transfer/reports/seenlog/; render each
# to docs/transfer/seenlog/<row>-<col>.html (2 levels deep -> ../../ css).
# The matrix cells link here via @{href=seenlog/...}. No date filter.
shopt -s nullglob
slog=("$DATA"/transfer/reports/seenlog/*.rpt)
shopt -u nullglob
# clear even when THIS run has no .rpt set (an env can lose the whole
# family — production 2026-08 — and stale pages would survive forever)
mkdir -p "$DOCS/transfer/seenlog"
rm -f "$DOCS"/transfer/seenlog/*.html
if [ ${#slog[@]} -gt 0 ]; then
    CUR_DATES=""; DLINK_BASE="../../details/"
    for f in "${slog[@]}"; do
        b=${f##*/}; b=${b%.rpt}
        pub_run render_rpt "$f" "$DOCS/transfer/seenlog/$b.html" "../../assets/style.css" "../../index.html" "TRANSFER" "" "seen-in-server-log"
    done
    pub_wait
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
    echo "Rendered docs/transfer/seenlog/ (${#slog[@]} cell page(s))." >&2
fi

# Security-parameter VALUE pages: security-params.sh wrote one .rpt per
# (table, value) into data/transfer/reports/secparams/, listing the
# subscriptions that used that value; render each to
# docs/transfer/secparams/<slug>.html (2 levels deep -> ../../ css). The
# security-params tables' first column links here via @{link=secparams/...}.
# No date filter (full-period subscription lists).
shopt -s nullglob
spv=("$DATA"/transfer/reports/secparams/*.rpt)
shopt -u nullglob
# clear even when THIS run has no .rpt set (an env can lose the whole
# family — production 2026-08 — and stale pages would survive forever)
mkdir -p "$DOCS/transfer/secparams"
rm -f "$DOCS"/transfer/secparams/*.html
if [ ${#spv[@]} -gt 0 ]; then
    CUR_DATES=""; DLINK_BASE="../../details/"
    for f in "${spv[@]}"; do
        b=${f##*/}; b=${b%.rpt}
        pub_run render_rpt "$f" "$DOCS/transfer/secparams/$b.html" "../../assets/style.css" "../../index.html" "TRANSFER" "" "security-params"
    done
    pub_wait
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
    echo "Rendered docs/transfer/secparams/ (${#spv[@]} value page(s))." >&2
fi

# Failed-file DRILL pages: failed.sh wrote one .rpt per paged CoreId into
# data/<env>/transfer/reports/errors/, listing that file's individual transfer
# legs; render each to docs/<env>/errors/<coreid>.html. ONE level below the env
# root (like transfer/), so "../assets/style.css". The Failed Subscriptions
# table links here from both its CoreId and its Legs cell via @{href=../errors/…}.
# CoreIds are lowercase UUIDs, so they are used as filenames verbatim.
# No date filter — a drill page is one file, not a period.
shopt -s nullglob
errp=("$DATA"/transfer/reports/errors/*.rpt)
shopt -u nullglob
# clear even when THIS run has no .rpt set (an env can lose the whole
# family — production 2026-08 — and stale pages would survive forever)
mkdir -p "$DOCS/errors"
rm -f "$DOCS"/errors/*.html
if [ ${#errp[@]} -gt 0 ]; then
    CUR_DATES=""; DLINK_BASE="../details/"
    for f in "${errp[@]}"; do
        b=${f##*/}; b=${b%.rpt}
        pub_run render_rpt "$f" "$DOCS/errors/$b.html" "../assets/style.css" "../index.html" "TRANSFER" "" "failed"
    done
    pub_wait
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
    echo "Rendered docs/errors/ (${#errp[@]} failed-file page(s))." >&2
fi

# FILE pages (2026-09-03, user request): failed.sh also writes one .rpt per
# CoreId the Transfer patterns page's "Last 5 files" cells link — ANY outcome,
# the failed-file page layout — into data/<env>/transfer/reports/files/;
# render each to docs/<env>/files/<coreid>.html, a sibling of errors/.
shopt -s nullglob
filp=("$DATA"/transfer/reports/files/*.rpt)
shopt -u nullglob
mkdir -p "$DOCS/files"
rm -f "$DOCS"/files/*.html
if [ ${#filp[@]} -gt 0 ]; then
    CUR_DATES=""; DLINK_BASE="../details/"
    for f in "${filp[@]}"; do
        b=${f##*/}; b=${b%.rpt}
        pub_run render_rpt "$f" "$DOCS/files/$b.html" "../assets/style.css" "../index.html" "TRANSFER" "" "failed"
    done
    pub_wait
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
    echo "Rendered docs/files/ (${#filp[@]} File page(s))." >&2
fi

# Redirect stubs were REMOVED 2026-07 (no backwards compatibility): the old
# flat entities/showseen/session/topview-split/direction-action/mode/inout-gap/
# entity-search/transfer-site URLs are gone — they 404.

echo "Rendered docs/transfer/ ($count report(s))." >&2

# Every menu/sitemap/group-tab option must exist in this env: write an
# empty-report placeholder for each order-listed report without a .rpt here.
render_missing_reports transfer

publish_stamp "$STAMP"
