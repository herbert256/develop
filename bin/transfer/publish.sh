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
# Usage:  bin/transfer/publish.sh            (run after the transfer reports —
#                                             every page, docs/files/ included:
#                                             a manual publish is complete)
#         bin/transfer/publish.sh firstpass  (bin/build.sh's first transfer
#                                             publish only: every page BUT
#                                             docs/files/, which the catch-up
#                                             renders — once per build)
#         bin/transfer/publish.sh catchup    (bin/build.sh's transfer catch-up
#                                             step only — see THE CATCH-UP MODE)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; defines the renderer

# the MODE (2026-09-29): an explicit argument — never a freshness check
TP_MODE=${1:-full}
case $TP_MODE in
    full|firstpass|catchup) ;;
    *) printf 'usage: bin/transfer/publish.sh [firstpass|catchup]\n' >&2; exit 2 ;;
esac

ensure_assets   # topbar-data.js (the menus' data file)

# laps (2026-09-27): TIME lines on the build console
_tp0=$(date +%s)
_tplap() { local _t1; _t1=$(date +%s); printf 'TIME %5ds  transfer publish: %s\n' "$((_t1 - _tp0))" "$1" >&2; _tp0=$_t1; }

# THE FILE PAGES — docs/files/ (2026-09-21, user request: the error pages
# and the File pages share ONE directory; docs/errors/ is gone). failed.sh
# keeps TWO .rpt sets, because its reason-evidence pass globs the first and must
# not read an OK File's page; both render here, into the one docs directory:
#   data/transfer/reports/errors/   one per paged FAILED File (<coreid>),
#                                         plus one per server-failing subscription
#                                         (<slug>, named by the subscription)
#   data/transfer/reports/files/    one per File of ANY outcome another page
#                                         links (Transfer patterns "Last 5 files",
#                                         Longest Files, the detail "Latest OK" row)
# ONE level below the env root (like transfer/), so "../assets/style.css".
# CoreIds are lowercase UUIDs, so they are used as filenames verbatim. No date
# filter — a page is one file, not a period. The errors set renders LAST, after
# the files set has been waited for: should a CoreId ever sit in both, the
# failed-File page wins and the two renders never race on one path.
# The full mode and the catch-up render it; the firstpass mode does not.
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
render_file_pages() {
    local filp errp pages set9 _per _i
    shopt -s nullglob
    filp=("$DATA"/transfer/reports/files/*.rpt)
    errp=("$DATA"/transfer/reports/errors/*.rpt)
    shopt -u nullglob
    # clear even when THIS run has no .rpt set (an env can lose the whole
    # family — production 2026-08 — and stale pages would survive forever); the
    # retired docs/errors/ goes too (a manual publish over a pre-merge tree)
    mkdir -p "$DOCS/files"
    rm -f "$DOCS"/files/*.html
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
}

# ---- THE CATCH-UP MODE ------------------------------------------------------
# `bin/transfer/publish.sh catchup` (2026-09-29) is bin/build.sh's "publish:
# transfer catch-up" step. It runs after the report catch-ups (drill-files.sh,
# failed.sh, failed-files.sh, failing-reasons.sh) and the analyses publish
# catch-up, and re-renders ONLY the transfer pages that read what those steps
# rewrote after the first (full) run of this script. Until 2026-09-29 the
# step re-ran the whole script, every transfer page included.
# THE DEPENDENCY TRACE (keep it in step with the readers). What changed since
# the first run: failed.sh's outputs (failed.rpt, failed-sub-all.rpt,
# _failed-reasons.tsv, _errpage-evidence.tsv, _srvsubs.tsv, _srvsubs-map.tsv
# and the errors/ + files/ .rpt sets, rewritten whole), failed-files.rpt,
# failing-reasons.rpt, drill-files.sh's _drill-files.tsv, and
# analyses/reports/_subs-boxes.tsv (publish-insights.sh, in the analyses
# publishes, which run AFTER the first run of this script). Their transfer
# pages:
#   transfer/entities/subscription-*.html  the Error view's Reason column
#       (publish_lib render_entity_report) reads failed-sub-all.rpt,
#       _srvsubs.tsv and _subs-boxes.tsv; the six views render together (the
#       other five read nothing that moved, so they come out the same)
#   transfer/failed-files.html             failed-files.rpt
#   transfer/unknown-transfers.html        unknown-transfers.rpt (its File-page
#       links follow the errors/ + files/ sets; 2026-09-29)
#   files/*.html                           the errors/ + files/ .rpt sets —
#       cleared and rendered in full (render_file_pages): the ONLY render of
#       docs/files/ in a build, the first run being the firstpass mode
# Every other page of this script reads report-stage .rpt files and caches
# that no step since the first run rewrites (the render reads no docs/
# page). The analyses-housed failed / failed-sub-all / failing-reasons pages
# are bin/analyses/publish.sh catchup's; the detail pages publish-details.sh's.
# A NEW transfer-page reader of one of the files above joins this list.
if [ "$TP_MODE" = catchup ]; then
    CUR_DATES=$TRANSFER_DATES
    for name in subscription failed-files unknown-transfers; do
        rpt="$DATA/transfer/reports/$name.rpt"
        [ -f "$rpt" ] || { echo "  (no data yet: $name)" >&2; continue; }
        pub_run render_report "transfer" "$name" "$rpt"
    done
    # NO pub_wait here: the two report jobs (the Subscriptions entity views
    # are the slowest single render of the area, ~1 s on the sample) run
    # BESIDE the files/ batches — disjoint trees (docs/transfer/ vs
    # docs/files/), each job with its own CUR_DATES copy — and
    # render_file_pages' first pub_wait reaps them with its own jobs
    render_file_pages
    _tplap "catch-up: Subscriptions entity views + Failed files + Unknown transfers + files/ pages"
    echo "Rendered the transfer catch-up (the Subscriptions entity views, Failed files, Unknown transfers, docs/files/)." >&2
    exit 0
fi

mkdir -p "$DOCS/transfer"
rm -f "$DOCS"/transfer/*.html   # clear stale report pages (the index is rewritten by bin/build/publish.sh)
mkdir -p "$DOCS/transfer/entities"
rm -f "$DOCS"/transfer/entities/*.html   # the Entities All/Seen/Not seen/Server/OK/Warning/Error pages (render_entity_report)
mkdir -p "$DOCS/analyses/xref"
rm -f "$DOCS"/analyses/xref/*.html       # the cross-reference pages (render_report's cross-* branch, now under analyses/)

# (the per-entity detail pages moved to bin/transfer/publish-details.sh —
# their OWN bin/build.sh step since 2026-07)

# ---- render -----------------------------------------------------------------

count=0
CUR_DATES=$TRANSFER_DATES
for name in "${transfer_order[@]}"; do
    # the Subscriptions analyses group renders from bin/analyses/publish.sh —
    # it owns (and clears) docs/analyses/ and runs AFTER this script
    if is_subs_report "$name"; then continue; fi
    rpt="$DATA/transfer/reports/$name.rpt"
    [ -f "$rpt" ] || { echo "  (no data yet: $name)" >&2; continue; }
    pub_run render_report "transfer" "$name" "$rpt"
    count=$((count + 1))
done
pub_wait

# (the Longest Files record pages, docs/transfers/duration/top/<coreid>.html,
# went 2026-09-29: each was a copy of the File page docs/files/<coreid>.html,
# which the Longest Files cells open instead)

# (the Seen-in-server-log matrix cell pages, docs/transfer/seenlog/, went with
# the BLUE server-log-only status and its report, 2026-09-27)

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
        # one report key per subscription: a remembered search or sort belongs to THAT flow's page
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
        # one report key per subscription: a remembered search or sort belongs to THAT flow's page
        pub_run render_rpt "$f" "$DOCS/transfer/waiting/$b.html" "../../assets/style.css" "../../index.html" "TRANSFER - Waiting" "" "waiting" "waiting-$b"
    done
    pub_wait
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
    echo "Rendered docs/transfer/waiting/ (${#waip[@]} subscription page(s))." >&2
fi

# THE FILE PAGES — docs/files/ (render_file_pages above) — NOT in the
# FIRSTPASS mode (2026-09-29, bin/build.sh's first transfer publish): failed.sh
# rewrites both .rpt sets whole in the report catch-up and the transfer
# catch-up renders the directory from them, so a first-pass render was
# overwritten page for page — docs/files/ now renders ONCE per build. Checked:
# no step between the two reads docs/files/ (the detail, partner-group,
# server and analyses publishes, drill-files / failed / failed-files /
# failing-reasons and the dashboards + day reports read the data/ trees, the
# rosters included — never the pages; linkcheck and the all-files search run
# after the catch-up, and the search reads the data/ rosters anyway).
_tplap "report pages + sub-pages"
if [ "$TP_MODE" = full ]; then
    render_file_pages
    _tplap "files/ pages"
fi

# MONTH STATS (2026-09-13, user request; retired the morning of 2026-09-29
# and brought back the same day): the 18 {this,previous} × entity pages of
# month-stats.sh -> docs/transfer/month-stats/ (publish_lib
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
