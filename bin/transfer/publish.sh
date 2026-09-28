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

ensure_assets   # topbar-data.js (the menus' data file)

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

# laps (2026-09-27): TIME lines on the build console
_tp0=$(date +%s)
_tplap() { local _t1; _t1=$(date +%s); printf 'TIME %5ds  transfer publish: %s\n' "$((_t1 - _tp0))" "$1" >&2; _tp0=$_t1; }
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

# (the Seen-in-server-log matrix cell pages, docs/transfer/seenlog/, went with
# the BLUE server-log-only status and its report, 2026-09-27)
rm -rf "$DOCS/transfer/seenlog"

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

# Expired SUBSCRIPTION pages (2026-09-21, user request): expired.sh wrote one
# .rpt per subscription with expired Files into data/transfer/reports/expired/,
# listing those Files; render each to docs/transfer/expired/<slug>.html
# (2 levels deep -> ../../ css). The Expired cells of the Expired report's
# subscriptions table link here via @{href=expired/...}. No date filter (the
# Expired report is a current-state audit).
shopt -s nullglob
expp=("$DATA"/transfer/reports/expired/*.rpt)
shopt -u nullglob
# clear even when THIS run has no .rpt set (stale pages would survive forever)
mkdir -p "$DOCS/transfer/expired"
rm -f "$DOCS"/transfer/expired/*.html
if [ ${#expp[@]} -gt 0 ]; then
    CUR_DATES=""; DLINK_BASE="../../details/"
    for f in "${expp[@]}"; do
        b=${f##*/}; b=${b%.rpt}
        # report key per subscription, the latest/ pages' rule
        pub_run render_rpt "$f" "$DOCS/transfer/expired/$b.html" "../../assets/style.css" "../../index.html" "TRANSFER - Expired" "" "expired" "expired-$b"
    done
    pub_wait
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
    echo "Rendered docs/transfer/expired/ (${#expp[@]} subscription page(s))." >&2
fi

# Waiting SUBSCRIPTION pages (2026-09-21, user request — the Expired pages'
# twin): waiting.sh wrote one .rpt per subscription with Files still staged into
# data/transfer/reports/waiting/; render each to docs/transfer/waiting/<slug>.html
# (2 levels deep -> ../../ css). The Waiting Files cells of the Waiting report's
# first table link here via @{href=waiting/...}. No date filter (Waiting is a
# state at the dataset's end).
shopt -s nullglob
waip=("$DATA"/transfer/reports/waiting/*.rpt)
shopt -u nullglob
# clear even when THIS run has no .rpt set (stale pages would survive forever)
mkdir -p "$DOCS/transfer/waiting"
rm -f "$DOCS"/transfer/waiting/*.html
if [ ${#waip[@]} -gt 0 ]; then
    CUR_DATES=""; DLINK_BASE="../../details/"
    for f in "${waip[@]}"; do
        b=${f##*/}; b=${b%.rpt}
        # report key per subscription, the latest/ pages' rule
        pub_run render_rpt "$f" "$DOCS/transfer/waiting/$b.html" "../../assets/style.css" "../../index.html" "TRANSFER - Waiting" "" "waiting" "waiting-$b"
    done
    pub_wait
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
    echo "Rendered docs/transfer/waiting/ (${#waip[@]} subscription page(s))." >&2
fi

# THE FILE PAGES — docs/<env>/files/ (2026-09-21, user request: the error pages
# and the File pages share ONE directory; docs/<env>/errors/ is gone). failed.sh
# keeps TWO .rpt sets, because its reason-evidence pass globs the first and must
# not read an OK File's page; both render here, into the one docs directory:
#   data/<env>/transfer/reports/errors/   one per paged FAILED File (<coreid>),
#                                         plus one per server-failing subscription
#                                         (<slug>, named by the subscription)
#   data/<env>/transfer/reports/files/    one per File of ANY outcome another page
#                                         links (Transfer patterns "Last 5 files",
#                                         Longest Files, the detail "Latest OK" row)
# ONE level below the env root (like transfer/), so "../assets/style.css".
# CoreIds are lowercase UUIDs, so they are used as filenames verbatim. No date
# filter — a page is one file, not a period. The errors set renders LAST, after
# the files set has been waited for: should a CoreId ever sit in both, the
# failed-File page wins and the two renders never race on one path.
shopt -s nullglob
_tplap "report pages + sub-pages"
filp=("$DATA"/transfer/reports/files/*.rpt)
errp=("$DATA"/transfer/reports/errors/*.rpt)
shopt -u nullglob
# clear even when THIS run has no .rpt set (an env can lose the whole
# family — production 2026-08 — and stale pages would survive forever); the
# retired docs/<env>/errors/ goes too (a manual publish over a pre-merge tree)
mkdir -p "$DOCS/files"
rm -f "$DOCS"/files/*.html
rm -rf "$DOCS/errors"
# IN BATCHES (2026-09-27, speed round 9): thousands of ~10 ms renders, one
# pooled job EACH, spent more on the job fork and the pool's polling than on
# the pages — a job now renders a run of pages (4 runs per pool slot). The
# errors set still renders after the files set, so it wins a shared name.
render_files_run() {   # $@ = the .rpt files of one run
    local f b
    for f in "$@"; do
        b=${f##*/}; b=${b%.rpt}
        render_rpt "$f" "$DOCS/files/$b.html" "../assets/style.css" "../index.html" "TRANSFER" "" "failed" || return $?
    done
}
for set9 in filp errp; do
    if [ "$set9" = filp ]; then pages=(${filp[@]+"${filp[@]}"}); else pages=(${errp[@]+"${errp[@]}"}); fi
    [ ${#pages[@]} -gt 0 ] || continue
    CUR_DATES=""; DLINK_BASE="../details/"
    _per=$(( (${#pages[@]} + PUB_NJOBS * 4 - 1) / (PUB_NJOBS * 4) ))
    for ((_i = 0; _i < ${#pages[@]}; _i += _per)); do
        pub_run render_files_run "${pages[@]:_i:_per}"
    done
    pub_wait
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
done
echo "Rendered docs/files/ (${#errp[@]} failed-file page(s) + ${#filp[@]} File page(s))." >&2
_tplap "files/ pages"

# MONTH STATS (2026-09-13, user request): the 18 {this,previous} × entity
# pages of month-stats.sh -> docs/transfer/month-stats/ (publish_lib
# render_month_stats clears the dir itself)
render_month_stats transfer

# Redirect stubs were REMOVED 2026-07 (no backwards compatibility): the old
# flat entities/showseen/session/topview-split/direction-action/mode/inout-gap/
# entity-search/transfer-site URLs are gone — they 404.

echo "Rendered docs/transfer/ ($count report(s))." >&2

# Every menu/sitemap/group-tab option must exist in this env: write an
# empty-report placeholder for each order-listed report without a .rpt here.
render_missing_reports transfer

_tplap "month stats + placeholders"
