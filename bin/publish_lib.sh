#!/usr/bin/env bash
#
# publish_lib.sh — shared machinery for every publish script:
#
#   bin/transfer/publish.sh   renders the transfer report pages (+ the Entities views)
#   bin/server/publish.sh     renders the server report pages
#   bin/analyses/publish*.sh  render the analyses pages (+ the partner groups, All files search)
#   bin/transfer/publish-details.sh  the detail pages
#   bin/dashboards/publish.sh, bin/day/publish.sh  the Dashboard and the day pages
#   bin/build/publish.sh      writes the home, the Reports start page, the tools/
#                             pages and the 404, then the group rows + tags
#
# Source this (it is not executable on its own). It cd's to the repo root, then
# computes the shared globals (report order, dates, dataset figures, top-bar menus)
# and defines every rendering helper the publish scripts use. The report scripts
# own aggregation and write .rpt descriptors; this owns ALL html/css — generated
# pages contain no <style> and no inline style=.
#
# A report whose .rpt contains more than one table is split into one HTML page
# per table (docs/<area>/<name>-<slug>.html), each carrying a tab bar linking to
# its siblings. Single-table reports render to docs/<area>/<name>.html.
#
set -euo pipefail
# This lib lives in bin/; operate from the repo root (its parent) so all the
# relative paths below (docs/, assets/, data/<area>/reports, data/<area>/cache)
# resolve — regardless of which publish script sourced us (BASH_SOURCE points here).
cd "$(dirname "${BASH_SOURCE[0]}")/.."

source bin/skiplist.sh    # SKIPLIST_FILE  — input/skip.txt (the ONE skip list)
source bin/fastawk.sh   # route unqualified `awk` to mawk when installed (see bin/fastawk.sh)
source bin/envlabel.sh  # ENV_LABEL — the checkout's environment label (input/environment.txt)
source bin/awklib.sh    # $AWKLIB — the shared awk helpers (bin/date.awk + bin/fmt.awk)

# One repo = one environment (2026-09-11): a publish run renders THE site tree
# (docs/…) from THE data tree (data/…) — flat, no environment segment. The
# hand-authored assets and help live at docs/assets/ and docs/help/.
DOCS="docs"
DATA="data"
# The FlowManager config exports every raw-JSON reader (the
# accounts insight page, reason-boxes.sh, uc3-polling.sh) should read: the
# SKIP-filtered copies bin/flow-manager.sh writes (input/skip.txt) when they
# exist, else the raw exports. (Repo-root-relative — publish_lib.sh cd's to ROOT.)
FM_CONFIG_DIR="input/flow-manager"
[ -f "$DATA/flow-manager/filtered/partners.json" ] && FM_CONFIG_DIR="$DATA/flow-manager/filtered"

# Cache-buster for the two shared assets: a content checksum appended as ?v=…
# to every stylesheet/script link html_head emits, so a browser (or the Pages
# CDN) never serves a stale style.css/report.js against freshly published HTML.
# Content-derived (not the build timestamp), so an assets-unchanged rebuild
# keeps the same URL and the cache stays warm.
ASSET_VER=$( (cksum docs/assets/style.css docs/assets/topbar.js docs/assets/report.js docs/assets/slotchart.js docs/assets/all-files-search.js docs/assets/sub-files.js 2>/dev/null || true) | cksum | cut -d' ' -f1 )

# ---- the render job pool ----------------------------------------------------
# Rendering a page is FORK-BOUND, not compute-bound: measured on a full rebuild,
# bin/transfer/publish.sh spent 5.9 s of user time against 7.2 s of SYSTEM time
# for 201 pages — the kernel spent longer creating processes than the work took.
# render_rpt.awk itself renders a page in ~5 ms; the observed cost was ~59 ms,
# so the rest is the shell around it. That is exactly the profile a job pool
# fixes, and every publish but bin/transfer/publish-details.sh ran SERIAL on a
# 10-core box until 2026-07.
#
# SAFE because a page render touches nothing shared: no writer here appends to a
# common file, render_report saves and restores the only two globals it assigns
# (CUR_DATES, DLINK_BASE — so a child's private copy behaves like the serial
# restore), every temp name is either mktemp or derived from the page path, and
# `mkdir -p` is idempotent. Two jobs never write the same page.
#
# Plain `&` + `wait`, no `wait -n` — bash 3.2 is the target (see Target
# environment). Same shape as the pool in bin/<area>/reports.sh and parse.sh.
PUB_NJOBS=${AXWAY_NJOBS:-$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )}
case $PUB_NJOBS in ''|*[!0-9]*) PUB_NJOBS=4 ;; esac
PUB_PIDS=()
PUB_RC=0
# Reap every recorded pid that is no longer running (instant — a terminated
# job's wait returns its remembered status). Called from every pub_run so
# the recorded backlog stays ~PUB_NJOBS: bash only REMEMBERS the statuses of
# the most recent CHILD_MAX terminated jobs, and a wait on a forgotten pid is
# "not a child of this shell", exit 127 — a single pub_wait after 7,040
# queued error-page renders (production 2026-08) aborted the publish on
# exactly that, with every page actually rendered fine.
# NO FORK PER PAGE (2026-09-27): liveness is `kill -0` (a builtin; bash reaps
# a finished child as it exits, so its pid stops answering), and the pool
# counts the recorded pids. The former `$(jobs -rp | …)` tests cost two
# subshells and three programs per page in the ONE dispatching shell — on a
# publish of a few thousand File pages, seconds of serial dispatch before
# the renders even ran.
pub_reap() {
    local p st keep=()
    for p in ${PUB_PIDS[@]+"${PUB_PIDS[@]}"}; do
        if kill -0 "$p" 2>/dev/null; then keep+=("$p")
        else st=0; wait "$p" || st=$?
             [ "$st" -ne 0 ] && PUB_RC=$st
        fi
    done
    PUB_PIDS=(${keep[@]+"${keep[@]}"})
}
pub_run() {    # run "$@" as a background job, at most PUB_NJOBS at once
    pub_reap
    while [ "${#PUB_PIDS[@]}" -ge "$PUB_NJOBS" ]; do sleep 0.02; pub_reap; done
    # a job of 2 s or more says so on the console (2026-09-29, build speed:
    # which page renders are a pool's long poles) — the render_report REPORT
    # name only, never a data-derived argument (a render_rpt path can carry a
    # subscription slug); $SECONDS, not date: no fork per page
    ( _ps=$SECONDS; "$@"; _st=$?; _pd=$((SECONDS - _ps))
      if [ "$_pd" -ge 2 ]; then
          if [ "$1" = render_report ]; then printf 'TIME %5ds  render %s/%s\n' "$_pd" "$2" "$3" >&2
          else printf 'TIME %5ds  render (%s)\n' "$_pd" "$1" >&2; fi
      fi
      exit "$_st" ) &
    PUB_PIDS+=("$!")
}
pub_wait() {   # reap every pooled job; abort the publish if any page failed
    local p st rc
    for p in ${PUB_PIDS[@]+"${PUB_PIDS[@]}"}; do
        st=0
        wait "$p" || st=$?
        [ "$st" -ne 0 ] && PUB_RC=$st
    done
    PUB_PIDS=()
    rc=$PUB_RC; PUB_RC=0
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: a page render failed (exit $rc) — aborting." >&2
        exit "$rc"
    fi
    return 0
}

# Per-AREA sorted list of report dates (ccyy-mm-dd) for the From/To selectors —
# taken from the area's day report, whose Date column is the canonical calendar
# of that dataset (transfer and server logs cover different windows, and other
# rpt files carry calendar labels — e.g. weekly's Mon/Sun range columns — that
# are not data days). Falls back to grepping the area's rpt files if there is
# no day report yet. render_rpt injects the list via CUR_DATES, set per area.
area_dates() {   # $1 area
    local dr="$DATA/$1/reports/day.rpt"
    [ -f "$dr" ] || dr="$DATA/$1/reports/topview.rpt"   # server: its Top view carries the per-day calendar (the day report was removed)
    # no day.rpt / topview.rpt: no dates (the pre-2026-07 glob fallback over
    # "<area>/data/*.rpt" matched nothing any more; it went 2026-09-29)
    [ -f "$dr" ] || return 0
    grep "^ROW"$'\t' "$dr" | cut -f2 | sed 's/^@{[^}]*}//' | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u | tr '\n' ',' | sed 's/,$//' || true
}
# Per-AREA list of days whose COLLECTION WINDOW ended mid-day — the exports are
# a snapshot, so the newest day almost always stops at the pull time (server
# 07:10 today, not 23:59). The rule is the one bin/transfer/reports/day.sh
# already prints as "(partial end)": an EDGE day (the last row, or one followed
# by a calendar gap) whose newest record is before 22:00. The transfer day
# report carries the marker in its Date cell; the server Top view carries the
# times, so the rule is applied here. Emitted as the report-partial meta and
# read by report.js, whose Week/Month presets end at the last FULL day —
# a half-day would otherwise silently shorten the range by nearly a day.
area_partial() {   # $1 area -> comma list of partial-END days ("" when none/unknown)
    local dr="$DATA/$1/reports/day.rpt"
    [ -f "$dr" ] || dr="$DATA/$1/reports/topview.rpt"
    [ -f "$dr" ] || return 0
    LC_ALL=C awk -F'\t' '
        function jdn(y, m, d,   a) { a = int((14 - m) / 12); y = y + 4800 - a; m = m + 12 * a - 3
            return d + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045 }
        $1 == "HEAD" { for (i = 2; i <= NF; i++) if ($i == "Last" || $i == "Last Time") lc = i; next }
        $1 != "ROW" { next }
        { d = $2; sub(/^@\{[^}]*\}/, "", d)
          if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) next
          n++
          MARK[n] = (index(d, "(partial end)") > 0 || index(d, "(partial)") > 0)
          DAY[n] = substr(d, 1, 10)
          J[n] = jdn(substr(d, 1, 4) + 0, substr(d, 6, 2) + 0, substr(d, 9, 2) + 0)
          LAST[n] = (lc ? $lc : "") }
        END {
            for (i = 1; i <= n; i++) {
                p = MARK[i]
                if (!p && LAST[i] ~ /^[0-9][0-9]:/ && (i == n || J[i + 1] - J[i] > 1) && LAST[i] < "22:00:00") p = 1
                if (p) out = out (out == "" ? "" : ",") DAY[i]
            }
            print out
        }
    ' "$dr"
}
TRANSFER_DATES=$(area_dates transfer)
SERVER_DATES=$(area_dates server)
TRANSFER_PARTIAL=$(area_partial transfer)
SERVER_PARTIAL=$(area_partial server)
CUR_DATES=""


# Ordered report basenames per area (defines index order; the .rpt files are the
# actual catalog — labels/descriptions come from each file's TITLE/DESC).
transfer_order=(topview subscription account login remote-host logical partner application domain bl entity-search file-journey file-in-file-out same-protocol activity cross-account cross-login cross-subscription cross-host cross-logical cross-partner cross-application cross-domain cross-bl entity-coverage skipped not-in-flow-manager ranking files failed episodes failed-files unknown-transfers waiting-expired retries pirates went-quiet failure-heatmap protocol security-params security-outreach av-scan connection-efficiency duration anomalies duration-longest duration-dwell duration-all)
server_order=(topview errors failure-flows io-errors routing-errors uc-status polling logons connections missing-entities)   # remote-poll: an unpublished intermediate since 2026-09-05 (its tables ride the UC status / UC3 tab); site-failures one since 2026-09-28 (its rows = the Per flow connection-failure rows); routing-errors = the 2026-09-28 merge of could-not-send, publish-failed and post-client-action

# ---- the analyses-housed area reports ---------------------------------------
# The reports whose PAGES live in docs/analyses/ — whatever area their DATA
# belongs to (transfer / server reports read those caches, run in those
# orchestrators and keep their .rpt in data/{transfer,server}/reports/; the
# analyses ones keep theirs in data/analyses/reports/). Same idea as the
# cross-* pages, one level shallower: docs/analyses/ is the same depth as
# transfer/ and server/, so the css/home/detail-link prefixes are unchanged
# and only the directory moves. Their group and first row come from
# _report_groups (analyses/<name> members) like every other report's.
#
# OWNERSHIP: bin/analyses/publish.sh renders them, NOT the area publishes —
# it clears docs/analyses/*.html and runs AFTER both, so a page written
# there by the transfer/server loop would be deleted again.
SUBS_GROUP_REPORTS=" transfer:failed analyses:failing-reasons server:uc-status server:polling analyses:partners-in analyses:partners-out "

is_subs_report() {   # $1 report basename -> 0 when its pages live in analyses/
    case $SUBS_GROUP_REPORTS in *:"$1 "*) return 0 ;; esac
    return 1
}

# (The BOXES-ONLY reports — pirates, waiting, expired (one Waiting & Expired report since 2026-09-30), went-quiet, went-kaput,
# 2026-07..09-29, reached only from the Boxes pages — are ordinary members of
# their report groups since the one Reports pulldown, 2026-09-29.)

# (The PAGELESS reports — merged-report components and the data producers
# whose rows ride another page or none (day, deploy-errors, missing-cronjobs, punctuality-src, fe-overview, the
# classic entity records …) — are simply the .rpt files no order list names.
# Their registry PAGELESS_REPORTS / is_pageless_report and subs_report_area
# went 2026-09-29: their one caller was What is new.)

# The cross reports' tabs are the second-entity list as-is — one table page
# per second entity, matching cross-reference.sh's emit order; render_report's
# cross-* branch renders them as two full entity rows (first / second, each
# graying out the other row's pick).
cross_tabs() { printf '%s' "$1"; }   # $1 = "Ent|Ent|..."

# Short tab labels (pipe-separated, one per table in order) for reports that
# should be split into per-table pages. Empty => single page. This is the only
# report-specific knowledge the renderer needs.
report_tabs() {
    case $1 in
        account|login|subscription|remote-host|logical|partner|application|domain|bl) echo "All|Seen|Not seen|OK|Warning|Error" ;;   # Entities group (pages under docs/<area>/entities/; default = All via first_page). Every view is listed so member-row links resolve to the same view (member_page_for_label).
        cross-account)      cross_tabs "Logins|Subscriptions|Hosts|Logical|Partners|Applications|Domains|BL" ;;
        cross-login)        cross_tabs "Accounts|Subscriptions|Hosts|Logical|Partners|Applications|Domains|BL" ;;
        cross-subscription) cross_tabs "Accounts|Logins|Hosts|Logical|Partners|Applications|Domains|BL" ;;
        cross-host)         cross_tabs "Accounts|Logins|Subscriptions|Logical|Partners|Applications|Domains|BL" ;;
        cross-logical)      cross_tabs "Accounts|Logins|Subscriptions|Hosts|Partners|Applications|Domains|BL" ;;
        cross-partner)      cross_tabs "Accounts|Logins|Subscriptions|Hosts|Logical|Applications|Domains|BL" ;;
        cross-application)  cross_tabs "Accounts|Logins|Subscriptions|Hosts|Logical|Partners|Domains|BL" ;;
        cross-domain)       cross_tabs "Accounts|Logins|Subscriptions|Hosts|Logical|Partners|Applications|BL" ;;
        cross-bl)           cross_tabs "Accounts|Logins|Subscriptions|Hosts|Logical|Partners|Applications|Domains" ;;
        files)         echo "By size|Empty files|By type|Duplicates|Largest files|Size regime|Stub shippers" ;;   # 2026-09-29: + top-transfers and size-profile
        went-quiet)    echo "Subscriptions|Accounts" ;;   # 2026-07 Tier 3: + stale-accounts
        # ---- the 2026-07 MERGED reports: one tab per component TABLE, in
        # component order — the tab count MUST equal the merged rpt's TABLE count
        activity)      echo "Per week|Per hour|Hour × weekday|Per weekday" ;;   # 2026-09-29: Per day went (= the Top view, Volume included)
        retries)       echo "Failing flows|Legs before success|Gave up|Retry spacing|Failing side|Resubmitted per day|Per subscription|Resubmission outcomes|Recovered files" ;;   # 2026-09-29: + recovered-files (its three tables on one tab)
        file-journey)  echo "Patterns|Leg count|Most legs|Protocol journey" ;;   # (Last leg + In and out went 2026-09-29, user request)
        file-in-file-out) echo "Handovers|UC4 to UC2" ;;   # 2026-09-29: + uc4-to-uc2 (each component's two tables on one tab)
        errors)        echo "Log reasons|Heatmap|Top messages" ;;   # 2026-09-29: "Log reasons" — server-log LINES by reason, not the Files in error the analyses Error reasons page counts   # 2026-09-29: Per component (the levels per component) rides the server Top view   # 2026-09-28: Per day went (= the Top view), By hour / By weekday folded into the Heatmap, Reasons carries the per-week table (tab=reasons)
        missing-entities) echo "Subscriptions|Accounts|Hosts|Whitelist|Logins" ;;   # the five unknown-* tables (retired and brought back 2026-09-29, user request)
        connections)   echo "Per day|By account|By address|Failure reasons|By remote host|Test connections|Host keys" ;;   # 2026-09-29: By protocol went (= the Per day column totals)   # 2026-08: + connection-diagnostics tables 4-5; 2026-09-28: Whitelist usage (= Incoming Allowed + Re-screens) and Test outcomes (empty by construction) gone
        logons)        echo "Scanners|By account|By source IP" ;;   # Incoming / Outgoing went 2026-09-30, user request (-> Partners in / Partners Out, analyses/)   # Near misses + Certificates went 2026-09-30, user request   # 2026-08: + the door-knocker tables (logon component tables 3-4); 2026-09-28: the ssh-key-auth tabs went (Key mismatches = Incoming Bad key, Lockouts now in Incoming Locked, Outbound key failures = a subset of Outgoing)
        uc-status)     echo "UC1|UC2|UC3|UC4" ;;
        protocol)      echo "Protocol × direction|Direction × action by|Mode" ;;   # 2026-09-29: the one-dimension tables (By protocol / By direction / By action by) went — the subtotals of the crosstabs   # the 2026-07 merge: + direction-action's Action By/Crosstab tables + the Mode split
        av-scan)       echo "Breakdown|Per day|Per protocol|Blocked|Not performed|Not first inbound" ;;
        # security-params: ONE table since 2026-09-29 (the six attribute tabs went)   # 2026-08: one tab per attribute; the report always emits all six tables (empty when absent) so the count matches in every env. Protocol table dropped — the protocol report owns it.
        ranking)       echo "Subscriptions|Accounts|Logins|Hosts|Logical|Partners|Applications|Domains|BL" ;;   # the 9 entity types, in ranking.sh's SPECS order
        # (anomalies had "Hourly|Daily" until 2026-08 — the two granularities
        # now share ONE page, Daily first, so the report is not split)
        pirates)       echo "Details|Per day" ;;   # the single-leg list + the count per day ("Top view" until 2026-09-30: the Top view is the transfer Top view)
        entity-coverage) echo "Accounts|Logical|Partners|Domains|Applications|BL" ;;   # one coverage table per entity; Accounts is the default (first_page). (The RULE rode on the basename until 2026-09-29 — -once/-ok/-diff; the verdicts are columns now.)
        *)             echo "" ;;
    esac
}

# ---- report groups ----------------------------------------------------------
# THE REPORT GROUPS (2026-09-29, user request: "just one pulldown named
# Reports, create logical groups, have all reports in the same group link to
# each other with the first selection buttons") live in _report_groups below
# — ONE table for the Reports menu, the reports start page, the sitemap, the
# h1 group tags and the ROW-1 buttons,
# whichever directory a member's page renders into. The functions here are
# what is left of the per-AREA groups (Transfer / Server, 2026-07..09-29): the
# two groups whose pages build their OWN first row at render time —
#   account-login-site  the nine Entities, one combined row "members | views"
#                       (render_entity_report — the view carries across members)
#   cross               the Cross References pair selector (two entity rows)
# Every other report's first row is injected by bin/build/publish.sh
# apply_report_groups (row + tag), so group_of returns "" for it and
# render_report writes no group row of its own.
group_members() {
    case $1 in
        account-login-site)  echo "subscription logical partner account login remote-host domain application bl" ;;
        cross)               echo "cross-account cross-login cross-subscription cross-host cross-logical cross-partner cross-application cross-domain cross-bl" ;;
    esac
}
group_of() {   # $1 area  $2 report basename -> group id (empty: its row comes from _report_groups)
    case $2 in
        account|login|subscription|remote-host|logical|partner|application|domain|bl) echo "account-login-site" ;;
        cross-account|cross-login|cross-subscription|cross-host|cross-logical|cross-partner|cross-application|cross-domain|cross-bl) echo "cross" ;;
        *)                                echo "" ;;
    esac
}
group_label() {
    case $1 in
        account-login-site)  echo "Entities" ;;
        cross)               echo "Cross References" ;;
    esac
}
member_label() {   # a report's own label: the group-row tab text (Entities / cross), the placeholder title
    # ONLY the names the callers pass — the transfer / server orders, the
    # SUBS_GROUP_REPORTS members, the Entities and cross members (2026-09-29:
    # 50 entries for merged-report components and pageless producers were
    # never asked for)
    case $1 in
        topview) echo "Top view" ;;
        entity-search) echo "Search" ;;
        activity) echo "Activity" ;;
        retries) echo "Retries & resubmissions" ;; file-journey) echo "File journey" ;;
        failed-files) echo "Failed files" ;; unknown-transfers) echo "Unknown transfers" ;; same-protocol) echo "Inbound and Outbound same Protocol" ;; security-outreach) echo "Security outreach" ;;
        connection-efficiency) echo "Connection efficiency" ;;
        failure-flows) echo "Per flow" ;; io-errors) echo "IO errors" ;; routing-errors) echo "Routing errors" ;;
        partners-in) echo "Partners in" ;; partners-out) echo "Partners Out" ;;   # 2026-09-30, user request (Partner scorecard, Blast radius and Application dependencies went the same day)
        errors) echo "Errors" ;; connections) echo "Connections" ;; logons) echo "Logons" ;;
        missing-entities) echo "Missing entities" ;;   # (ssh-security: SSH security went 2026-09-30 — its tables ride Security Parameters)
        uc-status) echo "UC status" ;; polling) echo "Polling" ;;
        anomalies) echo "Anomalies" ;;
        account) echo "Accounts" ;; login) echo "Logins" ;; subscription) echo "Subscriptions" ;;
        remote-host) echo "Hosts" ;;
        logical) echo "Logical" ;;
        partner) echo "Partners" ;; application) echo "Applications" ;; domain) echo "Domains" ;;
        bl) echo "BL" ;;
        cross-account) echo "Accounts" ;; cross-login) echo "Logins" ;; cross-subscription) echo "Subscriptions" ;;
        cross-host) echo "Hosts" ;; cross-logical) echo "Logical" ;;
        cross-partner) echo "Partners" ;; cross-application) echo "Applications" ;; cross-domain) echo "Domains" ;;
        cross-bl) echo "BL" ;;
        entity-coverage) echo "Entity coverage" ;; skipped) echo "Skipped" ;;
        files) echo "Sizes & types" ;;   # the MERGED report (size-dist + file-type + duplicate-files): its own group tab was an EMPTY span until 2026-09-13 (user report)
        failed) echo "Failed Subscriptions" ;; failing-reasons) echo "Error reasons" ;; episodes) echo "Recovered flows" ;; waiting-expired) echo "Waiting & Expired" ;; pirates) echo "One-legged" ;; went-quiet) echo "Went quiet" ;; failure-heatmap) echo "Failure heatmap" ;; not-in-flow-manager) echo "Not in Flow Manager" ;;
        file-in-file-out) echo "File in - File out" ;;
        protocol) echo "Protocol, Direction & Mode" ;;
        ranking) echo "Ranking" ;;
        duration|duration-all) echo "Duration" ;; duration-longest) echo "Longest Files" ;;
        duration-dwell) echo "Store-and-forward" ;;   # "Distribution & Store-and-forward" until 2026-09-30 (its Duration distribution table moved to Duration)
        security-params) echo "Security Parameters" ;; av-scan) echo "AV Scan" ;;
    esac
}
# First rendered page of a report (its first table page, or its single page).
first_page() {
    # The Entities reports live in the entities/ subdir and open on ALL
    # (logged + configured — the 2026-07 default; formerly Seen).
    case $1 in
        account|login|subscription|remote-host|logical|partner|application|domain|bl)
            echo "entities/$1-all.html"; return ;;
        entity-search) echo "../search/search.html"; return ;;    # published under search/ (2026-09-12; at the env root 2026-07..09)
    esac
    local labels; labels=$(report_tabs "$1")
    if [ -z "$labels" ]; then echo "$1.html"
    else local fl; IFS='|' read -r fl _ <<< "$labels"; echo "$1-$(slugify "$fl").html"; fi
}

# Landing page of a GROUP's index/dropdown entry — the first member's first
# page, unless overridden (the cross-reference entry opens on Account × Subscriptions).
group_home() {   # $1 group id
    case $1 in
        cross)        echo "xref/cross-account-subscriptions.html" ;;   # the cross pages live in docs/analyses/xref/ (analyses-relative href)
        account-login-site) first_page subscription ;;   # Entities DEFAULTS to Subscriptions / All — the same member the tab bar leads with
    esac   # (the two render-time groups only — every other group lands through rg_landing)
}

# ---- helpers ----------------------------------------------------------------

esc() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; ESC=$s; }

# One Top-5 card from a TOP rpt line (the day pages' protocol, shared with the
# Overview since 2026-08): TOP<TAB>kind<TAB>title<TAB>unit<TAB>href<TAB>
# name US value US … (US = \x1f)<TAB>slug US slug … . Kind P/S names the
# entity column and pins the card to its .daytop grid column (.dt-p / .dt-s),
# so a metric with nothing on one side leaves a hole instead of pulling the
# other side across. Each name with a slug links its detail page, the whole
# cell the target (2026-09-30 audit D-02 / L-03); both callers render pages
# one level below the docs root (day/, dashboards/), hence "../details/".
top_table() {   # $1 kind  $2 title  $3 unit  $4 href  $5 rows  [$6 slugs]
    local kind=$1 rows=$5 slugs=${6:-} nm val sl body="" ent sdir
    case $kind in P) ent="Partner"; sdir=partners ;; *) ent="Subscription"; sdir=subscriptions ;; esac
    esc "$2";    local et=$ESC
    esc "$3";    local eu=$ESC
    esc "$4";    local eh=$ESC     # the href carries &axway_sort= — esc makes it &amp;
    esc "$ent";  local ee=$ESC
    # walk the US-separated name/value pairs (bash 3.2: no readarray)
    while [ -n "$rows" ]; do
        nm=${rows%%$'\037'*}; rows=${rows#*$'\037'}
        val=${rows%%$'\037'*}
        if [ "$val" = "$rows" ]; then rows=""; else rows=${rows#*$'\037'}; fi
        sl=""
        if [ -n "$slugs" ]; then
            sl=${slugs%%$'\037'*}
            if [ "$sl" = "$slugs" ]; then slugs=""; else slugs=${slugs#*$'\037'}; fi
        fi
        esc "$nm"; local en=$ESC
        esc "$val"; local ev=$ESC
        if [ -n "$sl" ]; then
            esc "$sl"
            body+="<tr><td class=\"cl\"><a href=\"../details/$sdir/$ESC.html\">$en</a></td><td class=\"num\">$ev</td></tr>"
        else
            body+="<tr><td>$en</td><td class=\"num\">$ev</td></tr>"
        fi
    done
    [ -n "$body" ] || return 0
    local col; case $kind in P) col=dt-p ;; *) col=dt-s ;; esac
    printf '<section class="card %s"><h3>%s</h3><div class="tablewrap"><table><tr><th>%s</th><th class="num">%s</th></tr>%s</table></div><a class="seemore" href="%s">See more &rarr;</a></section>' \
        "$col" "$et" "$ee" "$eu" "$body" "$eh"
}

# Thousands separators with a dot (159048 -> 159.048); a non-integer (date,
# percent) passes through. PURE BASH (2026-09-29 audit: it was an awk per call,
# ~800 on the home page alone): dotify_v sets DOT without any fork, dotify
# prints it for the $( ) callers.
dotify_v() {
    local n=$1 s=""
    case $n in ''|*[!0-9]*) DOT=$n; return 0 ;; esac
    while [ ${#n} -gt 3 ]; do s=".${n: -3}$s"; n=${n:0:${#n}-3}; done
    DOT=$n$s
}
dotify() { dotify_v "$1"; printf '%s' "$DOT"; }

# (2026-09-28, speed round 24: the page and tab labels are plain words, and
# the pipeline cost four processes a call — ~1,600 calls per transfer
# publish. Input made ONLY of ASCII letters, digits, space, "_" and "-" (the
# set spelled out: a bracket RANGE would follow the locale collation) takes
# the fork-free loop, which produces the same bytes: lowercase, every run of
# other characters one "-", one leading and one trailing "-" dropped.
# Anything else takes the pipeline, the reference.)
slugify() {
    case $1 in
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789\ _-]*)
            printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -e 's/^-//' -e 's/-$//'; return ;;
    esac
    local s=$1 o="" c x i n=${#1} dash=0 U=ABCDEFGHIJKLMNOPQRSTUVWXYZ L=abcdefghijklmnopqrstuvwxyz
    for ((i = 0; i < n; i++)); do
        c=${s:i:1}
        case $c in
            [ABCDEFGHIJKLMNOPQRSTUVWXYZ]) x=${U%%"$c"*}; o+=${L:${#x}:1}; dash=0 ;;
            [abcdefghijklmnopqrstuvwxyz0123456789]) o+=$c; dash=0 ;;
            *) [ "$dash" = 1 ] || o+=-; dash=1 ;;
        esac
    done
    o=${o#-}; o=${o%-}
    printf '%s' "$o"
}

# Slug OVERRIDES for colliding entity names. details.sh suffixes a second entity
# whose name slugifies to an already-taken slug with -N and records
# "name<TAB>slug" in data/details/<sub>/_slugmap.tsv; without the override every
# name-derived link (the renderer's acct/site/login/host/ptn/app/dom cells)
# would send that entity's links to the FIRST collider's
# page. The renderer (bin/render_rpt.awk) loads the maps itself; this list
# ("<sub>=<path>", space-separated — the paths contain no spaces) tells it
# which files exist. Missing maps just leave it empty.
SLUGMAP_FILES=""
for _sm in "$DATA"/transfer/reports/details/*/_slugmap.tsv; do
    [ -f "$_sm" ] || continue
    _smsub=${_sm%/_slugmap.tsv}; _smsub=${_smsub##*/}
    SLUGMAP_FILES+="${SLUGMAP_FILES:+ }$_smsub=$PWD/$_sm"
done
unset _sm _smsub

# The .rpt -> HTML renderer program (the body of render_rpt below); resolved
# to an absolute path at source time, like the cd above, so render_rpt works
# from any later working directory.
RENDER_AWK="$PWD/bin/render_rpt.awk"
# ...run behind bin/fmt.awk (html_esc, slugof — its own esc / slugify copies
# went 2026-09-30): awk -f "$FMT_AWKF" -f "$RENDER_AWK"
FMT_AWKF="$PWD/bin/fmt.awk"
# the PUBLISHED File pages (bin/transfer/filepages.sh, 2026-09-29): render_rpt
# marks the drill lists whose first File has one (data-fp)
FILEPAGES_F="$PWD/data/transfer/cache/_filepages.tsv"; [ -f "$FILEPAGES_F" ] || FILEPAGES_F=""

# value of directive $1 in file $2. ONE awk with an early exit, not grep|cut: it
# is called a few hundred times per publish (the start page, the area indexes,
# the day pages) and halving two processes to one is worth ~0.3 s a run.
# (field2 — two directives in one awk — went 2026-09-29 with What is new, its
# one caller.)
field1() { LC_ALL=C awk -F'\t' -v k="$1" '$1 == k { i = index($0, "\t"); print (i ? substr($0, i + 1) : ""); exit }' "$2" 2>/dev/null || true; }
meta_val() { grep -m1 "^META"$'\t'"$2"$'\t' "$1" 2>/dev/null | cut -f3- || true; }   # META key $2 in file $1

html_head() {   # $1 title  $2 css_href  [$3 date-list]  [$4 unused (was the right label — replaced by the quick-search box)]  [$5 help slug]  [$6 area]  [$7 report key]  [$8 body class (the detail pages' direction/seen tint)]  [$9 extra asset scripts, space-separated basenames — the slot-chart pages ask for slotchart.js, the subscription pages for sub-files.js]
    esc "$1"
    # ONE depth prefix (2026-09-11, one repo = one environment): callers pass
    # their css href relative to the docs root ("../assets/style.css" from
    # docs/transfer/), and base is the path back to that root — the assets,
    # help/, index.html (home) and every in-site link hang off it.
    local base=${2%assets/style.css}
    printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n<meta name="viewport" content="width=device-width,initial-scale=1">\n<title>%s</title>\n' "$ESC"
    # never cache a page (2026-09-12, user request — stale pages in the local
    # browser): the http-equiv trio on EVERY document head. KEEP IN STEP with
    # the other head emitters — write_root_404 (bin/build/publish.sh), the
    # build report (bin/build.sh) and the hand-authored assets/help/*.html.
    # The assets keep their ?v= cache-busters (ASSET_VER) — these metas cover
    # the HTML document only, not its subresources.
    printf '<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">\n<meta http-equiv="Pragma" content="no-cache">\n<meta http-equiv="Expires" content="0">\n'
    [ -n "${3:-}" ] && printf '<meta name="report-dates" content="%s">\n' "$3"
    # The partial-END days of that same list (area_partial). The date list
    # identifies its area, so no caller has to pass anything: matching it
    # against the two area lists is enough — and when both areas happen to
    # cover the same days, the newest day is the pull day in either, so the
    # answer is the same one.
    if [ -n "${3:-}" ]; then
        _hh_part=""
        [ "$3" = "${TRANSFER_DATES:-}" ] && _hh_part=${TRANSFER_PARTIAL:-}
        [ -z "$_hh_part" ] && [ "$3" = "${SERVER_DATES:-}" ] && _hh_part=${SERVER_PARTIAL:-}
        [ -n "$_hh_part" ] && printf '<meta name="report-partial" content="%s">\n' "$_hh_part"
    fi
    # A stable per-AREA key for report.js's date-filter persistence — emitted
    # ONLY alongside a date list (pages without the From/To filter get neither).
    # A caller without an area (the analyses pages: Failed Subscriptions, UC
    # status, Polling, Triage, …) is keyed by the list it carries — an area's
    # own list IS that area, the match the partial days above make — so its
    # From/To joins that area's shared range instead of a silo keyed by the
    # whole date list (2026-09-29 audit).
    if [ -n "${3:-}" ]; then
        _hh_area=${6:-}
        if [ -z "$_hh_area" ]; then
            if [ "$3" = "${TRANSFER_DATES:-}" ]; then _hh_area=transfer
            elif [ "$3" = "${SERVER_DATES:-}" ]; then _hh_area=server; fi
        fi
        [ -n "$_hh_area" ] && printf '<meta name="report-area" content="%s">\n' "$_hh_area"
    fi
    # A stable per-REPORT key for report.js's search/sort persistence: identical
    # on every page of one report — all its table-tab pages — so e.g. Entity
    # Search keeps the typed search when switching All / Seen / Not Seen. Pages
    # without it (details) fall back to pageKeyBase()'s basename derivation.
    [ -n "${7:-}" ] && printf '<meta name="report-key" content="%s">\n' "$7"
    # (the dark-theme head script went 2026-09-29 with the theme, user request)
    printf '<link rel="stylesheet" href="%sassets/style.css%s">\n' "$base" "${ASSET_VER:+?v=$ASSET_VER}"
    topbar_scripts "$base"
    printf '<script src="%sassets/report.js%s" defer></script>\n' "$base" "${ASSET_VER:+?v=$ASSET_VER}"
    local _xs
    for _xs in ${9:-}; do printf '<script src="%sassets/%s%s" defer></script>\n' "$base" "$_xs" "${ASSET_VER:+?v=$ASSET_VER}"; done
    printf '</head>\n<body%s>\n' "${8:+ class=\"$8\"}"
    topbar_placeholder "$base" "${5:-}"
}

# THE TOP BAR (2026-09-30, the lean round: ONE implementation, assets/
# topbar.js, on EVERY page — the report pages, the help pages and the build
# report alike; the baked twin render_topbar / render_shared_topbar and its
# inline FITTOP_JS / AXWAY_ENVLINKS scripts are gone). A page bakes only a
# PLACEHOLDER — data-b the depth prefix back to the docs root, data-help the
# help slug — and loads topbar-data.js (the data, ensure_assets; ?v= TB_VER)
# then topbar.js (?v= ASSET_VER), both deferred and BEFORE report.js, which
# finds the bar built.
topbar_scripts() {   # $1 = the docs-root prefix
    printf '<script src="%sassets/topbar-data.js%s" defer></script>\n<script src="%sassets/topbar.js%s" defer></script>\n' \
        "$1" "${TB_VER:+?v=$TB_VER}" "$1" "${ASSET_VER:+?v=$ASSET_VER}"
}
topbar_placeholder() {   # $1 = the docs-root prefix  $2 = the help slug ("" = none)
    printf '<div class="topbar" data-b="%s"%s></div>\n' "$1" "${2:+ data-help=\"$2\"}"
}

# (The site-wide fixed FOOTER BAR was removed 2026-07, with its "Build report"
# link and build timestamp. The build report is reachable from the SITE MAP,
# which links the report of the run that built the site — see write_sitemap in
# bin/build/publish.sh. Nothing bakes a build identity into a page any more.)

# ---- report page renderer ---------------------------------------------------

render_rpt() {   # $1 rpt  $2 out-html  $3 css_href  $4 (unused)  $5 (unused)  [$6 drop first table title]  [$7 help slug]  [$8 report key]
    # ($4 was the home href, $5 the top-bar right label — neither is read since
    # the runtime top bar; the slots stay so no caller renumbers)
    local rpt=$1 out=$2 css=$3 droptitle=${6:-} helpslug=${7:-} reportkey=${8:-}
    # the TITLE and the META dirclass value (below) in ONE awk read — the two
    # grep|cut pipelines cost two subshells and four programs per page, and a
    # build renders several thousand pages (2026-09-27); same values: the
    # first line opening "TITLE<TAB>" / "META<TAB>dirclass<TAB>", the rest of it
    local title="" bodyclass="" xassets="" _rl=""
    # NO PROCESS for the title of a page outside docs/details/ (2026-09-27,
    # speed round 9): every writer puts TITLE on line 1, which a builtin read
    # takes — the awk below is a fork + exec per page (thousands of files/
    # pages, rendered twice per build). META dirclass (the body tint) exists
    # only in the detail-page .rpt files — details_writer.awk and the
    # incoming-connection pages, both rendered into docs/details/ — at their
    # END, so those still scan the whole file; so does any .rpt whose line 1
    # is not a TITLE. The same scan spots a subscription page's Files table
    # (TABLE ... subfiles=<slug>, 2026-09-29): its page loads the engine,
    # assets/sub-files.js (html_head's extra-scripts argument).
    if [ "${out#"$DOCS"/details/}" = "$out" ] && IFS= read -r _rl < "$rpt" 2>/dev/null && [ "${_rl#TITLE$'\t'}" != "$_rl" ]; then
        title=${_rl#TITLE$'\t'}
    else
    IFS=$'\037' read -r title bodyclass xassets < <(LC_ALL=C awk '
        !t && index($0, "TITLE\t") == 1 { t = 1; ti = substr($0, 7) }
        !m && index($0, "META\tdirclass\t") == 1 { m = 1; bc = substr($0, 15) }
        !x && index($0, "TABLE\t") == 1 && index($0, "\tsubfiles=") > 0 { x = 1; xa = "sub-files.js" }
        END { printf "%s\037%s\037%s\n", ti, bc, xa }' "$rpt" 2>/dev/null) || true
    fi
    # The page's AREA (the date-filter persistence key report.js uses), derived
    # from where the output lands — transfer report and detail pages share the
    # transfer dataset, server report pages the server one. Same derivation the
    # callers use for the CSS depth, so no caller needs a new argument.
    local rarea=""
    case $out in
        "$DOCS"/transfer/*|"$DOCS"/details/*|"$DOCS"/search/all-files.html) rarea="transfer" ;;   # all-files.html: the shared transfer From/To (2026-09-27)
        "$DOCS"/server/*)                     rarea="server" ;;
    esac
    # (a page outside those trees that carries a date list — the analyses
    # pages — gets its area from that list in html_head)
    # The page body — the whole .rpt line protocol, tables and cells included —
    # is rendered by ONE awk pass (bin/render_rpt.awk): rendering it in bash
    # cost ~5 process forks per entity-linked cell and put a full transfer
    # publish at ~5 minutes. LC_ALL=C keeps the awk byte-oriented (tolower and
    # the slugify character classes fold ASCII only, like the tr|sed pipeline
    # the awk replaces).
    # The detail pages carry a direction/seen body tint: details.sh writes a
    # META dirclass line, html_head turns it into a <body> class (style.css).
    # (bodyclass: read with the title above — the meta_val "$rpt" dirclass value)
    # (the FlowManager deep links — FMLINK_MAPS/META fmlink — were removed
    # 2026-07; the { } config-JSON link went earlier, no META jsonlink exists)
    # A page rendered with NO date list (CUR_DATES empty -> html_head emits no
    # report-dates meta -> report.js never builds a From/To filter) has no
    # consumer for the @data:buckets re-aggregation payloads — strip them at
    # render time. (The detail writers stopped emitting buckets in 2026-07;
    # this stays as the guard for any future writer that emits them on a
    # no-dates page.)
    local dropbuckets=0; [ -z "$CUR_DATES" ] && dropbuckets=1
    {
        html_head "$title" "$css" "$CUR_DATES" "" "$helpslug" "$rarea" "$reportkey" "$bodyclass" "$xassets"
        LC_ALL=C awk -F'\t' -v droptitle="$droptitle" -v dlink="${DLINK_BASE:-../details/}" \
            -v slugmaps="$SLUGMAP_FILES" -v resmaps="${RESMAP_FILES:-}" \
            -v subtint="${RPT_SUBTINT:-}" \
            -v grpicons="${GRPICON_MAP:-}" -v dropbuckets="$dropbuckets" \
            -v rdates="$CUR_DATES" \
            -v noprose="${RPT_NOPROSE:-0}" -v fpages="$FILEPAGES_F" \
            -f "$FMT_AWKF" -f "$RENDER_AWK" "$rpt"
        printf '</body>\n</html>\n'
    } > "$out"
}

# Segment a .rpt (globals): HEADER (pre-table lines), FOOTER (trailing
# NOTE/SUMMARY/FOOT), NTAB, TBLOCK[1..NTAB] (each table's block of lines).
# A NOTE that sits BETWEEN tables belongs to the table it follows (e.g.
# volume's per-row note under "Volume by direction") and stays in that block,
# so it appears only on that table's page; NOTEs after the last table are
# report-wide and go to FOOTER (rendered on every split page), as before.
# ONE AWK PASS (2026-09-28, speed round 15): the bash loop below appended
# every line to a growing string — 6.4 s for a 21k-row report (failed-files
# at production scale), quadratic in its size. SEGMENT_AWK applies the SAME
# rules (the bash version below stays their reference and the fallback when
# awk fails) and prints bash assignments — $'...' strings, only backslash
# and quote escaped — which segment_rpt evals.
SEGMENT_AWK='
# (lines kept in arrays and printed at END — string growth by concatenation
# is quadratic in mawk too)
function esc(s,   n, a, i, o) {   # backslash and quote escaped for a bash $'"'"'...'"'"' string
    if (index(s, "\\")) { n = split(s, a, "\\"); o = a[1]; for (i = 2; i <= n; i++) o = o "\\\\" a[i]; s = o }
    if (index(s, "\047")) { n = split(s, a, "\047"); o = a[1]; for (i = 2; i <= n; i++) o = o "\\\047" a[i]; s = o }
    return s }
function chomp1(s) { return (substr(s, length(s)) == "\n") ? substr(s, 1, length(s) - 1) : s }
function after(line, mk,   p, r) { r = line; while ((p = index(r, mk)) > 0) r = substr(r, p + length(mk)); return r }   # the text after the LAST mk
function addT(n, line) { TB[n, ++TN[n]] = line; if (TN[n] > 1 && substr(line, 1, 5) == "HEAD\t") TH[n] = 1 }   # TH: the block holds a HEAD line (not as its first)
function lines(s, into,   z, m, k) { m = split(chomp1(s), z, "\n"); for (k = 1; k <= m; k++) { if (into == "F") FL[++FN] = z[k]; else addT(into, z[k]) } }
BEGIN { phase = "head" }
{
    line = $0
    p = index(line, "\t"); dir = p ? substr(line, 1, p - 1) : line
    if (dir == "TABLE") {
        if (pending != "") { lines(pending, N); pending = "" }
        sw = ""; if (index(line, "\tswitch=")) { sw = after(line, "\tswitch="); p = index(sw, "\t"); if (p) sw = substr(sw, 1, p - 1); p = index(sw, ":"); if (p) sw = substr(sw, 1, p - 1) }
        tk = ""; if (index(line, "\ttab=")) { tk = after(line, "\ttab="); p = index(tk, "\t"); if (p) tk = substr(tk, 1, p - 1) }
        if (phase == "tab" && ((sw != "" && sw == lastsw) || (tk != "" && tk == lasttab))) addT(N, line)
        else { phase = "tab"; N++; addT(N, line) }
        lastsw = sw; lasttab = tk
    } else if (dir == "NOTE" || dir == "LINK") {
        if (phase == "tab") pending = pending line "\n"; else FL[++FN] = line
    } else if (dir == "SUMMARY" || dir == "FOOT") {
        if (pending != "") {
            if (TH[N]) lines(pending, "F")
            else if (N > 0) lines(pending, N)
            else lines(pending, "F")
            pending = ""
        }
        FL[++FN] = line
    } else if (phase == "head") HL[++HN] = line
    else {
        if (pending != "") { lines(pending, N); pending = "" }
        addT(N, line)
    }
}
END {
    if (pending != "") lines(pending, "F")
    printf "NTAB=%d\nHEADER=$\047", N; for (k = 1; k <= HN; k++) printf "%s\n", esc(HL[k]); printf "\047\n"
    printf "FOOTER=$\047"; for (k = 1; k <= FN; k++) printf "%s\n", esc(FL[k]); printf "\047\n"
    for (i = 1; i <= N; i++) { printf "TBLOCK[%d]=$\047", i
        for (k = 1; k <= TN[i]; k++) printf "%s%s", (k > 1 ? "\n" : ""), esc(TB[i, k]); printf "\047\n" }
}'
# Most .rpt files are short, where the fork-free loop beats an awk start
# (~13 ms): the loop runs first and hands over past 500 lines.
segment_rpt() {
    segment_rpt_bash "$1" 500 && return 0
    local _seg
    if _seg=$(LC_ALL=C awk "$SEGMENT_AWK" "$1"); then HEADER=""; FOOTER=""; NTAB=0; TBLOCK=(); eval "$_seg"; return 0; fi
    segment_rpt_bash "$1"
}
segment_rpt_bash() {   # $1 = the .rpt  [$2 = a line cap: return 3, state partial, past it]
    HEADER=""; FOOTER=""; NTAB=0; TBLOCK=()
    local line dir phase="head" pending="" sw="" lastsw="" tk="" lasttab="" cap=${2:-0} nl=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$cap" -gt 0 ]; then nl=$((nl + 1)); [ "$nl" -le "$cap" ] || return 3; fi
        dir=${line%%$'\t'*}
        case $dir in
            TABLE)
                if [ -n "$pending" ]; then TBLOCK[$NTAB]+=$'\n'"${pending%$'\n'}"; pending=""; fi
                # a switch=KEY table (2026-09-03) whose KEY the previous table of the
                # block carries STAYS IN THAT BLOCK — one tab page, report.js
                # shows one of the group at a time — so the tab count stays
                # the count of switch GROUPS, not of tables
                sw=""; case $line in *$'\t'switch=*) sw=${line##*$'\t'switch=}; sw=${sw%%$'\t'*}; sw=${sw%%:*} ;; esac
                # a tab=KEY table (2026-09-05) likewise STAYS in the block of a
                # previous table carrying the same KEY — but VISIBLE, stacked
                # under it: several component tables on ONE tab page (the UC3
                # tab of UC status: the status table plus uc3-polling's four).
                # render_rpt.awk treats the modifier as inert; the tab count
                # stays the count of blocks.
                tk=""; case $line in *$'\t'tab=*) tk=${line##*$'\t'tab=}; tk=${tk%%$'\t'*} ;; esac
                if [ "$phase" = tab ] && { { [ -n "$sw" ] && [ "$sw" = "$lastsw" ]; } || { [ -n "$tk" ] && [ "$tk" = "$lasttab" ]; }; }; then
                    TBLOCK[$NTAB]+=$'\n'"$line"
                else phase="tab"; NTAB=$((NTAB+1)); TBLOCK[$NTAB]="$line"; fi
                lastsw=$sw; lasttab=$tk ;;
            NOTE|LINK)
                if [ "$phase" = tab ]; then pending+="$line"$'\n'
                else FOOTER+="$line"$'\n'; fi ;;
            SUMMARY|FOOT)
                # a NOTE directly followed by the report trailer is trailing
                # too (report-level: repeated on every tab page) — UNLESS the
                # current table is a BARE stub (no HEAD: the merge_rpt no-data
                # pad), whose note IS the stub's content and must stay with
                # it. Before this rule the last pad's "This view has no data"
                # note footered onto all ten Logons tab pages (2026-08).
                if [ -n "$pending" ]; then
                    case ${TBLOCK[$NTAB]:-} in
                        *$'\n'HEAD$'\t'*) FOOTER+="$pending" ;;
                        *) if [ "$NTAB" -gt 0 ]; then TBLOCK[$NTAB]+=$'\n'"${pending%$'\n'}"; else FOOTER+="$pending"; fi ;;
                    esac
                    pending=""
                fi
                FOOTER+="$line"$'\n' ;;
            *)
                if [ "$phase" = head ]; then HEADER+="$line"$'\n'
                else
                    # a pending NOTE stays BEFORE the line that follows it —
                    # an INTRO paragraph opening the next section used to jump
                    # ahead of the previous table's note (2026-09-05)
                    if [ -n "$pending" ]; then TBLOCK[$NTAB]+=$'\n'"${pending%$'\n'}"; pending=""; fi
                    TBLOCK[$NTAB]+=$'\n'"$line"
                fi
                ;;
        esac
    done < "$1"
    [ -n "$pending" ] && FOOTER+="$pending"
    return 0
}

# Page of a member report carrying the table-tab LABEL, or its first page when
# it has no tab of that name. Lets the group nav keep the reader on the same
# view when switching reports (Detail -> the sibling's Detail).
member_page_for_label() {   # $1 member  $2 current table label ("" = first page)
    local labels; labels=$(report_tabs "$1")
    if [ -n "$2" ] && [ -n "$labels" ]; then
        local IFS='|' l
        for l in $labels; do
            if [ "$l" = "$2" ]; then printf '%s-%s.html' "$1" "$(slugify "$l")"; return; fi
        done
    fi
    first_page "$1"
}

# render_missing_reports AREA — write an "empty report" placeholder page for
# every order-listed report whose .rpt is absent in this checkout (a small
# estate skips many). The menus, sitemap and group tab rows list ALL
# options unconditionally (2026-07), so every listed page must exist: a
# data-less report shows a page saying so, never a 404. EVERY tab page of a
# split report is written (2026-08 — formerly only the first): the group
# nav's same-label carry (member_page_for_label) links a sibling's page of
# the SAME label from every tab, so a missing report's deeper label pages
# are linked after all. Standard chrome incl. the group tab row, so
# navigation continues from it.
# Call AFTER the area's real pages are rendered (the dir clear precedes both).
render_missing_reports() {
    local area=$1 order=() name fp out title g members m ml n=0
    local labels lbl mpages
    if [ "$area" = transfer ]; then order=("${transfer_order[@]}"); else order=("${server_order[@]}"); fi
    for name in "${order[@]}"; do
        [ -f "$DATA/$area/reports/$name.rpt" ] && continue
        # the Subscriptions group's pages live in docs/analyses/, which
        # bin/analyses/publish.sh owns and clears — it writes their placeholders
        if is_subs_report "$name"; then continue; fi
        fp=$(first_page "$name")
        case $fp in ../*|*/*) continue ;; esac   # env-root pages (search) / subdir pages (entities — always rendered from the transfer rpts)
        mpages=("$fp")
        labels=$(report_tabs "$name")
        g=$(group_of "$area" "$name")
        if [ -n "$labels" ] && [ -n "$g" ]; then
            local mlaba mout; IFS='|' read -r -a mlaba <<< "$labels"
            members=$(group_members "$g")
            for lbl in "${mlaba[@]}"; do
                mout="$name-$(slugify "$lbl").html"
                [ "$mout" = "$fp" ] && continue
                # a deeper label page ONLY when a sibling member carries the
                # same label — that sibling's group nav (same-label carry,
                # member_page_for_label) is what links it; an unshared
                # label's placeholder would itself be an orphan
                for m in $members; do
                    [ "$m" = "$name" ] && continue
                    case "|$(report_tabs "$m")|" in
                        *"|$lbl|"*) mpages+=("$mout"); break ;;
                    esac
                done
            done
        fi
        for fp in "${mpages[@]}"; do
        out="$DOCS/$area/$fp"
        [ -f "$out" ] && continue
        # grouped report: the MEMBER label (its tab name) — the group label
        # already appears in the h1 group tag; ungrouped: the entry label
        title=$(member_label "$name")
        [ -n "$title" ] || title=$(entry_label "$area" "$name")
        {
            html_head "$title" "../assets/style.css" "" "" "$(help_slug_for "$area" "$name")" "$area" "$name"
            esc "$title"; printf '<h1>%s</h1>\n' "$ESC"
            # group tab bar between the title and the prose, like every other page
            g=$(group_of "$area" "$name")
            if [ -n "$g" ]; then
                members=$(group_members "$g")
                case $members in *' '*)
                    printf '<p class="tabs">'
                    for m in $members; do
                        ml=$(member_label "$m"); [ -n "$ml" ] || ml=$m
                        esc "$ml"
                        if [ "$m" = "$name" ]; then printf '<span class="tab active">%s</span>' "$ESC"
                        else printf '<a class="tab" href="%s">%s</a>' "$(first_page "$m")" "$ESC"; fi
                    done
                    printf '</p>\n' ;;
                esac
            fi
            printf '<p class="range">This report has <strong>no data in this environment</strong> — the log lines or configuration it reads are absent, so its report file was not produced.</p>\n'
            printf '</body>\n</html>\n'
        } > "$out"
        n=$((n + 1))
        done
    done
    [ "$n" -gt 0 ] && echo "Wrote $n empty-report placeholder(s) to $DOCS/$area/." >&2
    return 0
}

# Build the group row-1 NAV (a tab per grouped report) for a member, or "" if
# the report is ungrouped or its group has only one member. The current member's
# tab is active. $3 is the current page's table-tab label: a sibling with the
# same tab links to that page (e.g. from an Entities Detail page every entity
# tab goes to Detail).
group_nav_row() {   # $1 area  $2 report name  [$3 current table label]
    local g; g=$(group_of "$1" "$2"); [ -z "$g" ] && return
    local members; members=$(group_members "$g")
    case $members in *' '*) ;; *) return 0 ;; esac   # single-member group (entity-search): no member row
    local nav="NAV" m a
    for m in $members; do
        a=0; [ "$m" = "$2" ] && a=1
        # ALL members get a tab (2026-07, formerly filtered on the .rpt):
        # a member without data in this env has an empty-report placeholder
        # page (render_missing_reports), so the tab always lands somewhere
        nav+=$'\t'"$a|$(member_label "$m")|$(member_page_for_label "$m" "${3:-}")"
    done
    printf '%s' "$nav"
}

# Grouped multi-table reports render their group-member row and their
# table-tab row as ONE row (sections separated by @sep).
combine_group_nav() { [ -n "$(group_of "$1" "$2")" ]; }   # $1 area  $2 report name

# help_slug_for AREA REPORT-BASENAME -> the docs/help/<slug>.html its top-bar
# help icon links to. The help pages are HAND-AUTHORED and PERSISTENT (never
# regenerated by the publish scripts — see ensure_assets/CLAUDE.md), so this
# mapping only chooses the URL; a few report FAMILIES that are the same feature
# applied to different entities share one page: the Entities reports
# (entities-<name>), cross-reference (cross-*) and the
# server unknown-* reports. Everything else is
# 1:1 with its basename. SERVER basenames are prefixed "server-" so they can
# never collide with a transfer slug of the same name (both areas have their
# own "topview" report).
# KEEP IN SYNC: a new/renamed/regrouped report needs its help page created (or
# an existing one extended) or its help icon 404s — see CLAUDE.md's
# `docs/help/*.html` bullet; docs/help/index.html is the Reports START PAGE's
# help text (data-help="index" on docs/reports/index.html) — it catalogs nothing.
help_slug_for() {   # $1 area (transfer|server)  $2 report basename
    local area=$1 n=$2
    case $n in
        account|login|subscription|remote-host|logical|partner|application|domain|bl) echo "entities-$n" ;;
        failed-files)                                                   echo "failed-files" ;;   # its own page (2026-09-29 fix: failed-* below caught it)
        failed-*)                                                       echo "failed" ;;    # the Failed Subscriptions view pages share one help page
        duration-all)     echo "duration" ;;  # the All-transfers sibling view shares the Duration help page (the Min/Avg/Max pages are gone, 2026-09-13)
        cross-*)                                                        echo "cross-reference" ;;
        missing-entities)    echo "server-unknown-entities" ;;   # the merged report keeps the unknown-* family help page
        # the 2026-07 merged reports keep one component's existing help page
        activity)            echo "day" ;;
        retries)             echo "retry" ;;
        file-journey)        echo "patterns" ;;
        errors)              echo "server-errors-day" ;;
        connections)         echo "server-inbound-connections" ;;
        logons)              echo "server-logon" ;;
        uc-status)           echo "server-uc1-status" ;;
        files)               echo "size-dist" ;;
        episodes)            echo "recovered" ;;   # 2026-09-29: its Episodes tab went — the report IS Recovered flows
        duration-dwell)      echo "duration-dwell" ;;   # 2026-09-05 merge: its own help page (assets/help/duration-dwell.html, the two components' help merged)
        *) if [ "$area" = server ]; then echo "server-$n"; else echo "$n"; fi ;;
    esac
}
# tab_help_slug AREA REPORT LABEL — the help slug of ONE tab page of a split
# report: the report's own slug (help_slug_for) unless that tab has a help
# page of its own. The four UC status tabs do (assets/help/server-uc1..uc4-
# status.html; the UC3 one also documents the polling tables the tab carries
# since 2026-09-05).
tab_help_slug() {
    case "$2/$3" in
        uc-status/UC1) echo server-uc1-status ;;
        uc-status/UC2) echo server-uc2-status ;;
        uc-status/UC3) echo server-uc3-status ;;
        uc-status/UC4) echo server-uc4-status ;;
        file-in-file-out/UC4\ to\ UC2) echo uc4-to-uc2 ;;
        retries/Recovered\ files) echo recovered-files ;;
        *) help_slug_for "$1" "$2" ;;
    esac
}

# ---- Entities reports: the views ------------------------------------------
# Each Entities report renders SIX pages into docs/<area>/entities/ (9 entities
# -> 54 pages), with two tab groups on the nav row: the entity members and the
# views. (A third group — the Transfer | +Server SCOPE, with a seventh Server
# view — went with the BLUE server-log-only status, 2026-09-27: without it the
# two scopes listed the same entities.)
#   views  All | Seen | Not seen | OK | Warning | Error
# What each view holds:
#   All       the Summary rows plus one zero-blank row per configured-but-
#             never-seen name (the DEFAULT page — see first_page: every
#             entry/menu/group link lands here)
#   Seen      the .rpt's Summary table exactly as written
#   Not seen  only the configured-never-seen rows (no RECALC and no date
#             cells, so the page renders no From/To — zero date-aware tables)
#   OK/Warning/Error   the rows whose entity RESULT is green / orange / red
# The not-seen names come from showseen.sh's coverage TSVs (col 1 = configured
# name, col 3 = seen flag; a PDA name may appear once per DIRECTION — seen when
# ANY of its rows is), so this view and Show Seen can never disagree. The
# <entity>.rpt itself stays UNCHANGED: the server rosters (site-failures,
# unknown-*) and showseen.sh keep reading it as before. Every name links to
# its detail page through the entity KIND + slugmap; the All / Not seen tables
# carry seenrows for the green/red row tint.
entity_cov_base() {
    case $1 in
        account) echo accounts ;;  login) echo logins ;;  subscription) echo subscriptions ;;
        remote-host) echo hosts ;;  logical) echo logicals ;;
        partner) echo partners ;;  application) echo applications ;; domain) echo domains ;;
        bl) echo bl ;;
    esac
}
# Reduce an Entities block to its FIRST (Name) column only: drop the Files/Error/
# OK/Volume/%/First seen/Last seen cells from every HEAD/KIND/TOTAL/ROW, keeping
# the name + any trailing @data:* cells (the seen/res tint). Used by the two Not
# seen views, where the seven metric columns carry no information.
entities_name_only() {
    LC_ALL=C awk -F'\t' -v OFS='\t' '
        # the GHEAD banner spans columns the name-only view lacks, and so do
        # the column-group / drill / ratio TABLE modifiers — drop them
        $1 == "GHEAD" { next }
        $1 == "TABLE" { out = $1; drop = 0
                        for (i = 2; i <= NF; i++) { if (i > 2 && ($i ~ /^(gsep|drillcols|pct|noagg|autohide)=/ || $i == "datereset")) drop = 1; else out = out OFS $i }
                        if (drop) print out; else print
                        next }
        # the RECALC tokens re-aggregate columns a names-only table lacks — and
        # with them the page offered a From/To over nothing (2026-09-29)
        $1 == "RECALC" { next }
        $1 == "HEAD" || $1 == "KIND" || $1 == "TOTAL" { print $1, $2; next }
        $1 == "ROW" { out = $1 OFS $2; for (i = 3; i <= NF; i++) if ($i ~ /^@data:/) out = out OFS $i; print out; next }
        { print }'
}
render_entity_report() {   # $1 area  $2 name  $3 rpt (bin/transfer/reports/entities.sh's entities/<name>.rpt)  $4 rlabel  $5 hslug  $6 rkey
    local area=$1 name=$2 rpt=$3 rlabel=$4 hslug=$5 rkey=$6
    local _evp=() _ev   # the view renders in flight (see the view loop)
    # THE GROUPED LAYOUT (2026-09-13, user request — built the same day as a
    # twin under transfer/entities2/, then made THE layout; the classic Name ·
    # Direction · Files · Volume · OK · Retry · Resubmit · Error · Last seen
    # pages are gone): the .rpt is already in display order — Name, then the
    # Files / Retry-Resubmit / Duration / Volume / Transfers / State / Dates
    # column groups (a GHEAD banner + gsep dividers) — its rows baked
    # busiest-first with no sort= marker. Below: the views, the
    # subset totals re-summing the grouped columns (entity_res_block), an
    # empty group hidden per view (entity_hide_groups), the TOTAL row last
    # (entity_total_last). The nine classic <name>.rpt records (written by
    # entities.sh too) are DATA (showseen, entity-search, the rosters) and
    # render no page.
    local _nreal=23   # the directive + Name + 21 figure columns (the Reason column follows Days)
    segment_rpt "$rpt"                                  # TBLOCK[1]=Summary
    local sumblk=${TBLOCK[1]:-}
    local stable shead stotal srows
    stable=$(printf '%s\n' "$sumblk" | grep -m1 $'^TABLE\t' || true)
    shead=$(printf '%s\n' "$sumblk" | grep -E $'^(GHEAD|HEAD|KIND|RECALC)\t' || true)   # GHEAD = the group banner row
    stotal=$(printf '%s\n' "$sumblk" | grep -m1 $'^TOTAL\t' || true)
    srows=$(printf '%s\n' "$sumblk" | grep $'^ROW\t' || true)
    # a not-seen row = the name + one empty cell per remaining HEAD column
    local ncols; ncols=$(printf '%s\n' "$shead" | awk -F'\t' '/^HEAD\t/{ print NF - 1; exit }')
    local covf="$DATA/$area/reports/coverage/$(entity_cov_base "$name").tsv" nsrows=""
    if [ -f "$covf" ] && [ "${ncols:-0}" -gt 0 ]; then
        nsrows=$(printf '%s\n' "$srows" | LC_ALL=C awk -F'\t' -v nc="$ncols" -v mem="$name" '
            # Input 1 (stdin) = the Summary ROWs: a name with logged traffic is
            # SEEN per definition, even when its only coverage-TSV row says 0
            # (a both-ways partner whose Out side hides behind an endpoint row
            # — STATER — kept only its seen=0 In row and got listed TWICE).
            FNR == NR { if ($1 == "ROW") insum[toupper($2)] = 1; next }
            # partners.tsv keeps one Out row PER ENDPOINT for a both-ways
            # organisation (named by the endpoint, covlink hosts/..., col 8 =
            # the In partner — external_partners_tsv); those are endpoint
            # aliases for the coverage cell pages, NOT partner names — the
            # Entities views must not list them (e.g. uk2.mft.aon.com).
            mem == "partner" && $4 ~ /^hosts\// { next }
            { if (!($1 in seen)) { ord[++n] = $1; seen[$1] = 0 }
              if ($3 == "1" || toupper($1) in insum) seen[$1] = 1 }
            END { for (i = 1; i <= n; i++) { nm = ord[i]
                      if (seen[nm] == 0) { printf "ROW\t%s", nm
                          for (c = 2; c <= nc; c++) printf "\t"
                          printf "\t@data:seen=0\n" } } }' - "$covf")
    fi
    # the member's base cache (name, direction, result)
    local basen=""
    case $name in
        subscription) basen=_subscriptions ;; account) basen=_accounts ;; login) basen=_logins ;;
        remote-host) basen=_hosts ;; logical) basen=_logicals ;; partner) basen=_partners ;;
        application) basen=_apps ;; domain) basen=_domains ;; bl) basen=_bl ;;
    esac
    # GHOST rows — configured names in NEITHER set: no report row and no
    # coverage row at all. Since
    # the Logical-based derivations (2026-08-30) key every coverage TSV by
    # the real member names this set is EMPTY on a healthy estate — what
    # still lands here is either a flow the COVERAGE TSV vouches for without
    # a report row (a name seen with blank counts — VOUCHED, stays on Seen exactly
    # as before; the UC3 clean-poll greens were that case until 2026-09-28) or a flow configured with NO login and
    # NO host, whose direction-less rows every derived-coverage builder skips
    # — NO coverage row, NO evidence: that one belongs on NOT SEEN
    # (2026-08-31, user report: a config-only env showed 6% of Domains "Seen"
    # with zero logs — the old rule counted the evidence-free ghosts as seen,
    # and the home figure with them). Both kinds still render on All as blank
    # configured rows, tinted by their base RESULT like every row.
    local ghrows="" ghnsrows="" ngh=0 nghns=0 _ghall=""
    local ghbase="$DATA/flow-manager/base/${basen:-none}.tsv"
    if [ -n "$basen" ] && [ -f "$ghbase" ] && [ "${ncols:-0}" -gt 0 ]; then
        _ghall=$(printf '%s\n%s\n' "$srows" "$nsrows" | LC_ALL=C awk -F'\t' -v nc="$ncols" -v basef="$ghbase" \
            -v covf="${covf:-}" -v mem="$name" '
            $1 == "ROW" { have[toupper($2)] = 1 }
            END {
                if (covf != "") { while ((getline l < covf) > 0) { n2 = split(l, a, "\t")
                        if (mem == "partner" && n2 >= 4 && a[4] ~ /^hosts\//) continue
                        if (a[1] != "" && a[3] == "1") covseen[toupper(a[1])] = 1 }
                    close(covf) }
                while ((getline l < basef) > 0) { split(l, a, "\t")
                    if (a[1] != "" && !(toupper(a[1]) in have)) {
                        v = (toupper(a[1]) in covseen) ? 1 : 0
                        printf "%d\tROW\t%s", v, a[1]
                        for (c = 2; c <= nc; c++) printf "\t"
                        printf "\t@data:seen=%d\n", v } } close(basef) }')
        ghrows=$(printf '%s\n' "$_ghall" | { grep $'^1\t' || true; } | cut -f2-)
        ghnsrows=$(printf '%s\n' "$_ghall" | { grep $'^0\t' || true; } | cut -f2-)
    fi
    local nseen nns
    nseen=$(printf '%s' "$srows" | grep -c $'^ROW\t' || true)
    nns=$(printf '%s' "$nsrows" | grep -c $'^ROW\t' || true)
    ngh=$(printf '%s' "$ghrows" | grep -c $'^ROW\t' || true)
    nghns=$(printf '%s' "$ghnsrows" | grep -c $'^ROW\t' || true)
    # TOTAL variants: patch the "(N" count; the Not seen total keeps only the label
    local tot_all tot_ns
    tot_all=$(printf '%s\n' "$stotal" | LC_ALL=C awk -F'\t' -v OFS='\t' -v n="$((nseen + nns + ngh + nghns))" '{ sub(/\([0-9,]+/, "(" n, $2); print }')
    tot_ns=$(printf '%s\n' "$stotal" | LC_ALL=C awk -F'\t' -v n="$((nns + nghns))" '{ sub(/\([0-9,]+/, "(" n, $2); printf "TOTAL\t%s", $2; for (i = 3; i <= NF; i++) printf "\t"; print "" }')
    # TABLE-line variants: view suffix on the heading plus per-view modifiers.
    # SORT (sort=COL:DIR -> data-sort-init): every view that CARRIES the count
    # columns opens on Files DESCENDING (sort=1:-1) — the busiest entity first,
    # which is what these pages are read for; rows with no Files of their own
    # (configured-never-seen, ghost) have an empty cell, and numKey sorts
    # those last in either direction, so they collect at the bottom. The
    # name-only view (Not seen) has no Files column and keep A-Z on
    # the name (sort=0:1). It is a page DEFAULT, not a user choice: a remembered
    # header click still wins, and the header toggle works from it.
    # The Not seen view also keeps the seenrows red tint, while the All view
    # tints rows by the entity RESULT instead (@data:res, injected below).
    tbl_variant() {   # $1 heading suffix  $2 space-separated extra modifiers
        printf '%s\n' "$stable" | LC_ALL=C awk -F'\t' -v OFS='\t' -v sfx="$1" -v mods="$2" '
            { $2 = $2 " \342\200\224 " sfx; n = split(mods, M, " "); for (i = 1; i <= n; i++) $0 = $0 OFS M[i]; print }'
    }
    # All = the seen rows + the configured-never-seen / ghost rows. The seen
    # rows keep their BAKED busiest-first order (there is no single Files
    # column to sort on); the never-seen / ghost rows follow, by name (case
    # folded, byte-order tiebreak). The OK/Warning/Error blocks filter these
    # rows in place, so they inherit the order too.
    local _blank=""
    [ -n "$nsrows" ] && _blank=$nsrows
    [ -n "$ghrows" ] && _blank+=${_blank:+$'\n'}$ghrows
    [ -n "$ghnsrows" ] && _blank+=${_blank:+$'\n'}$ghnsrows
    [ -n "$_blank" ] && _blank=$(printf '%s\n' "$_blank" | LC_ALL=C sort -t$'\t' -k2,2f -k2,2)
    local all_rows=""
    [ -n "$srows" ] && all_rows=$(printf '%s\n' "$srows" | sed $'s/$/\t@data:seen=1/')
    [ -n "$_blank" ] && all_rows+=${all_rows:+$'\n'}$_blank
    # the All view tints every row by the entity RESULT (the base caches'
    # third field, bin/build/result.sh): @data:res green / orange / red -> the
    # tr[data-res] rules in style.css (like the coverage pages and Search)
    local resb="" resfile=""
    case $name in
        subscription) resb=_subscriptions ;; account) resb=_accounts ;; login) resb=_logins ;;
        remote-host) resb=_hosts ;; logical) resb=_logicals ;; partner) resb=_partners ;;
        application) resb=_apps ;; domain) resb=_domains ;; bl) resb=_bl ;;
    esac
    [ -n "$resb" ] && resfile="$DATA/flow-manager/base/$resb.tsv"
    [ -f "$resfile" ] || resfile=""
    # The NOT SEEN rows carry the entity RESULT too, so every row shows ITS OWN
    # colour — the same one that paints the background of that entity's detail
    # page (body.res-*, from the same base cache column). Without @data:res the
    # generic seenrows rule painted the lot red ("configured only"), which reads
    # as "last transfer errored" for entities that never transferred at all.
    # style.css already carries the overrides (tr[data-seen="0"][data-res=…]),
    # they just had nothing to match on. A never-seen SUBSCRIPTION is orange by
    # definition, but a rolled-up type (account/login/host) can be green or red
    # here — it has no File of its own while its connected subscriptions do.
    if [ -n "$nsrows" ] && [ -n "$resfile" ]; then
        nsrows=$(printf '%s\n' "$nsrows" | LC_ALL=C awk -F'\t' -v OFS='\t' -v resf="$resfile" '
            BEGIN { while ((getline l < resf) > 0) { split(l, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) }
            /@data:res=/ { print; next }
            { r = res[toupper($2)]
              if (r == "green" || r == "orange" || r == "red") print $0, "@data:res=" r
              else print }' -)
    fi
    # Tint the ghost rows HERE, once: they go into the All view (below, where
    # the pass then skips them — it leaves an already-tinted row alone) AND
    # into the Seen view further down, which is assembled after that pass.
    if [ -n "$ghrows" ] && [ -n "$resfile" ]; then
        ghrows=$(printf '%s\n' "$ghrows" | LC_ALL=C awk -F'\t' -v OFS='\t' -v resf="$resfile" '
            BEGIN { while ((getline l < resf) > 0) { split(l, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) }
            { r = res[toupper($2)]
              if (r == "green" || r == "orange" || r == "red") print $0, "@data:res=" r
              else print }' -)
    fi
    if [ -n "$ghnsrows" ] && [ -n "$resfile" ]; then
        ghnsrows=$(printf '%s\n' "$ghnsrows" | LC_ALL=C awk -F'\t' -v OFS='\t' -v resf="$resfile" '
            BEGIN { while ((getline l < resf) > 0) { split(l, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) }
            { r = res[toupper($2)]
              if (r == "green" || r == "orange" || r == "red") print $0, "@data:res=" r
              else print }' -)
    fi
    # The tint pass: the real seen rows (green/orange/red) and the never-seen
    # rows; a row that already carries @data:res passes through untouched.
    if [ -n "$all_rows" ] && [ -n "$resfile" ]; then
        all_rows=$(printf '%s\n' "$all_rows" | LC_ALL=C awk -F'\t' -v OFS='\t' -v resf="$resfile" '
            BEGIN { while ((getline l < resf) > 0) { split(l, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) }
            /@data:res=/ { print; next }
            { r = res[toupper($2)]
              if (r == "green" || r == "orange" || r == "red") print $0, "@data:res=" r
              else print }' -)
    fi
    # The SEEN view tints its rows by the entity RESULT too (same lookup as
    # the All view). Non-ROW lines
    # pass through, so the Summary keeps its TABLE/HEAD/TOTAL/NOTEs verbatim.
    local sumblk_tinted=$sumblk
    if [ -n "$resfile" ]; then
        sumblk_tinted=$(printf '%s\n' "$sumblk" | LC_ALL=C awk -F'\t' -v OFS='\t' -v resf="$resfile" '
            BEGIN { while ((getline l < resf) > 0) { split(l, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) }
            $1 != "ROW" { print; next }
            /@data:res=/ { print; next }
            { r = res[toupper($2)]
              if (r == "green" || r == "orange" || r == "red") print $0, "@data:res=" r
              else print }' -)
    fi
    # datereset on the Seen view too (the All view's TABLE variant carries it,
    # and the OK/Warning/Error/Transfer variants below): every Entities view is
    # a CATALOG the status tables link into, so it opens at the full date range
    # whatever From/To the transfer area remembers. Narrowing stays page-local.
    # (and sort=1:-1 — Files descending, like every other counted view; the
    # Seen rows arrive Files-desc from the .rpt, so this only makes the page
    # default explicit and marks the sorted header.)
    sumblk_tinted=$(printf '%s\n' "$sumblk_tinted" | LC_ALL=C awk -F'\t' -v OFS='\t' '
        $1 == "TABLE" && !done { $0 = $0 OFS "datereset"; done = 1 } { print }')
    # The VOUCHED ghost rows belong on SEEN (2026-07): the coverage TSV — and
    # with it showseen, the analyses figures and the status tables' Seen
    # column — counts these names as seen (a green with no report row of its own,
    # seen-with-blank-counts). The EVIDENCE-FREE ghosts go to Not seen
    # instead (2026-08-31); pda_seen_total moved in lockstep.
    if [ -n "$ghrows" ]; then
        sumblk_tinted=$(printf '%s\n' "$sumblk_tinted" | LC_ALL=C awk -F'\t' -v OFS='\t' -v gr="$ghrows" -v ng="$ngh" '
            $1=="TOTAL" {
                print gr
                if (match($2, /\([0-9,]+/)) { cnt=substr($2,RSTART+1,RLENGTH-1); gsub(/,/,"",cnt); sub(/\([0-9,]+/, "(" (cnt+ng), $2) }
                print; next }
            { print }')
    fi
    local blk_all blk_ns shead_ns
    # datereset: the All view is the catalog (the home status tables link it) —
    # it always OPENS at the full date range, ignoring a remembered From/To
    # (and never saves one); narrowing it stays page-local.
    blk_all="$(tbl_variant "all (logged + configured)" "datereset")"$'\n'"$shead"$'\n'"$tot_all"
    [ -n "$all_rows" ] && blk_all+=$'\n'"$all_rows"
    shead_ns=$(printf '%s\n' "$shead" | grep -v $'^RECALC\t' || true)   # no buckets -> no RECALC -> no From/To on this page
    local nsrows_gh=$nsrows
    if [ -n "$ghnsrows" ]; then
        nsrows_gh=${nsrows:+$nsrows$'\n'}$ghnsrows
        nsrows_gh=$(printf '%s\n' "$nsrows_gh" | LC_ALL=C sort -t$'\t' -k2,2f -k2,2)
    fi
    blk_ns="$(tbl_variant "configured, never seen" "seenrows sort=0:1")"$'\n'"$shead_ns"$'\n'"$tot_ns"
    [ -n "$nsrows_gh" ] && blk_ns+=$'\n'"$nsrows_gh"
    blk_ns=$(printf '%s\n' "$blk_ns" | entities_name_only)   # Not seen: name column only
    # OK / Warning / Error views: the entities whose site-wide RESULT (the base
    # caches' third column, bin/build/result.sh) is green / orange / red. ONE
    # definition for the three — the same one the row tints, the coverage
    # pages, Entity Search and the status tables' Ok/Warning/Error columns use,
    # so a status figure and the view it links list the same entities (2026-07;
    # OK/Error formerly filtered the Seen rows by their own LAST TRANSFER
    # outcome, which for a rolled-up type — account/login/host — is a different
    # set than its result, e.g. 149 accounts vs the 121 the home called Ok).
    # Filter the All rows, which already carry @data:res, and re-sum the
    # subset TOTAL (Files/Error/OK from the integer cells, Volume from the
    # @data:buckets bytes).
    # The subset TOTAL of the OK / Warning / Error views: the @data:res filter,
    # re-summing the grouped columns — the count cells, the Files total and
    # bytes from the buckets (metrics 0 and 4), Days = the DISTINCT bucket
    # dates, the Duration percentiles from the rows' merged @data:durdays
    # per-day histograms (display-grid values, the writer's nearest-rank
    # rule) — into the writer's own baked TOTAL line, whose @{class=…} cell
    # prefixes are kept (the formatting lives in the writer: whole-unit
    # bytes, an empty rate beside an empty Error, no In/Out 0, the s/m/h/d
    # durations tinted by unit — the Duration cells are rebuilt whole, their
    # tint following the subset value). Template cells (the 2026-09-13
    # order, Transfers after Volume): 2 label · 3 In · 4 Out · 5 Error ·
    # 6 Error % · 7 Auto · 8 Ok · 9 Error · 10 p90 · 11 p95 · 12 p99 ·
    # 13 p100 · 14 Total · 15 Avg · 16 Ok · 17 Error · 18 Error % ·
    # 19 Waiting · 20 Expired · 21 First · 22 Last · 23 Days.
    entity_res_block() {   # $1 = green|orange|red   $2 = the All-view rows to filter
        # (the whole-unit byte format hbytes0 and the quicksort qsortn come
        # from $AWKLIB — bin/fmt.awk, 2026-09-30; pasted copies before)
        printf '%s\n' "$2" | LC_ALL=C awk -F'\t' -v OFS='\t' -v want="@data:res=$1" -v tmpl="$stotal" "$AWKLIB"'
            function hshort(ms,   v) { v = ms / 1000; if (v < 59.5) return sprintf("%.0f s", v)
                v /= 60; if (v < 59.5) return sprintf("%.0f m", v); v /= 60; if (v < 23.5) return sprintf("%.0f h", v); return sprintf("%.0f d", v / 24) }
            function dtint(ms,   v) { v = ms / 1000; if (v < 59.5) return "processed"; if (v / 60 < 59.5) return "warn"; return "failed" }
            function dcell(ms) { return (ms == "") ? "" : "@{class=" dtint(ms) "}" hshort(ms) }
            function pr(x, c) { if (x + 0 == 0 || c + 0 == 0) return ""; return sprintf("%.1f%%", x * 100 / c) }
            function nz(x) { return (x + 0 == 0) ? "" : x + 0 }
            function n(s) { gsub(/[^0-9]/, "", s); return s + 0 }
            function prank(P,   r, cum, i2) { r = int((HN - 1) * P / 100 + 0.5) + 1; cum = 0
                for (i2 = 1; i2 <= hq; i2++) { cum += HC[i2]; if (cum >= r) return HQ[i2] } return HQ[hq] }
            $1=="ROW" {
                hit=0; for (i=1;i<=NF;i++) if ($i==want) hit=1
                if (!hit) next
                cnt++
                for (c = 3; c <= 20; c++) if (c != 6 && c != 18 && !(c >= 10 && c <= 15)) S[c] += n($c)   # the count cells: In Out Error | Auto Ok Error | Ok Error | Waiting Expired
                for (i=1;i<=NF;i++) {
                    if ($i ~ /^@data:buckets=/) { nb = split(substr($i,15),B,","); for (j=1;j<=nb;j++){ split(B[j],C,":"); files += C[2]+0; sb += C[6]+0; dd[C[1]] = 1 } }
                    else if ($i ~ /^@data:durdays=/) { nb = split(substr($i,15),B,","); for (j=1;j<=nb;j++){ p = index(B[j], ":"); if (p < 1) continue
                        nq = split(substr(B[j],p+1),QQ,";"); for (m=1;m<=nq;m++){ p2 = index(QQ[m], "."); if (p2 > 1) HH[substr(QQ[m],1,p2-1)+0] += substr(QQ[m],p2+1)+0 } } }
                }
                rows[++nr]=$0 }
            END {
                for (d in dd) days++
                # the merged histogram, sorted by grid value — a QUICKSORT of
                # the distinct values (speed round 5: an insertion sort here
                # was O(n^2) on production histograms of thousands of values)
                hq = 0; HN = 0
                for (k in HH) { HQ[++hq] = k + 0; HN += HH[k] }
                qsortn(HQ, 1, hq)
                for (j = 1; j <= hq; j++) HC[j] = HH[HQ[j]]
                V[3]=nz(S[3]); V[4]=nz(S[4]); V[5]=S[5]+0; V[6]=pr(S[5], files); V[7]=S[7]+0; V[8]=S[8]+0; V[9]=S[9]+0
                W[10] = (HN > 0) ? dcell(prank(90)) : ""; W[11] = (HN > 0) ? dcell(prank(95)) : ""; W[12] = (HN > 0) ? dcell(prank(99)) : ""; W[13] = (HN > 0) ? dcell(prank(100)) : ""   # WHOLE cells (their tint follows the value)
                V[14]=hbytes0(sb); V[15]=hbytes0(files > 0 ? sb / files : 0); V[16]=S[16]+0; V[17]=S[17]+0; V[18]=pr(S[17], S[16]+S[17]); V[19]=S[19]+0; V[20]=S[20]+0; V[23]=days+0
                nt = split(tmpl, T, "\t"); while (nt > 2 && T[nt] ~ /^@data:/) nt--   # the All total own distinct @data:buckets never ride a SUBSET total (2026-09-29)
                if (cnt + 0 == 0) { V[14] = ""; V[15] = ""; V[23] = "" }   # an EMPTY view (2026-09-29): no "0 B" / 0 days in its total
                l = T[2]; sub(/\([0-9,]+/, "(" (cnt + 0), l); out = T[1] OFS l
                for (c = 3; c <= nt; c++) { cell = T[c]
                    if (c in W) cell = W[c]
                    else if (c in V) { if (match(cell, /^@\{[^}]*\}/)) cell = substr(cell, 1, RLENGTH) V[c]; else cell = V[c] }
                    out = out OFS cell }
                print out
                for (i=1;i<=nr;i++) print rows[i] }'
    }
    # The TOTAL row LAST (2026-09-13, user request). Every block assembles it
    # before the rows and the page opens unsorted in its baked order — hold
    # it and print it after the rows, before the NOTEs.
    entity_total_last() {
        LC_ALL=C awk -F'\t' '
            $1 == "TOTAL" { held = held (held == "" ? "" : "\n") $0; next }
            $1 == "ROW"   { print; next }
            { if (held != "") { print held; held = "" } print }
            END { if (held != "") print held }'
    }
    # HIDE an EMPTY group (2026-09-13, user request) — the Retry /
    # Resubmit group (Auto · Ok · Error, .rpt fields 7-9, display columns
    # 5-7, banner cell 4) and the State group (Waiting · Expired, fields
    # 19-20, columns 17-18, banner cell 7) — on a view whose rows carry no
    # such value at all. At the full range that holds for every narrower
    # range too, so the page drops the columns for good: the fields of every
    # HEAD/KIND/RECALC/ROW/TOTAL line (a trailing Reason column shifts left
    # with the rest), the banner cell, and the TABLE modifiers that name
    # columns by index (gsep=, noagg=, pct=, drillcols= — remapped past the
    # dropped columns, the dropped groups' own entries removed). Name-only
    # views (a HEAD under 20 fields) pass through.
    entity_hide_groups() {
        LC_ALL=C awk -F'\t' -v OFS='\t' '
            function nm(d,   k, c) { c = 0; for (k in DD) if (k + 0 < d) c++; return d - c }   # a display index, the dropped columns before it removed
            function remap_list(s,   m, A, i, out) { m = split(s, A, ","); out = ""
                for (i = 1; i <= m; i++) { if ((A[i] + 0) in DD) continue; out = out (out == "" ? "" : ",") nm(A[i] + 0) } return out }
            function remap_pct(s,   m, A, i, p, P, j, q, B, k2, x, w, out) {   # "col:num+num:den+den;…"
                m = split(s, A, ";"); out = ""
                for (i = 1; i <= m; i++) { p = split(A[i], P, ":"); q = ""
                    for (j = 1; j <= p; j++) { k2 = split(P[j], B, "+"); w = ""
                        for (x = 1; x <= k2; x++) w = w (w == "" ? "" : "+") nm(B[x] + 0)
                        q = q (q == "" ? "" : ":") w }
                    out = out (out == "" ? "" : ";") q }
                return out }
            function remap_drills(s,   m, A, i, P, out) { m = split(s, A, ","); out = ""
                for (i = 1; i <= m; i++) { split(A[i], P, ":"); if ((P[2] + 0) in DD) continue
                    out = out (out == "" ? "" : ",") P[1] ":" nm(P[2] + 0) (P[3] != "" ? ":" P[3] : "") } return out }
            function keep(   out, i) { out = ""; for (i = 1; i <= NF; i++) { if (i in DF) continue; out = out (i == 1 ? "" : OFS) $i } return out }
            { L[++n] = $0
              if ($1 == "HEAD" && NF < 20) skip = 1
              if ($1 == "ROW") { for (i = 7; i <= 9; i++) { v = $i; gsub(/[^0-9]/, "", v); if (v + 0 > 0) hasR = 1 }
                                 for (i = 19; i <= 20; i++) { v = $i; gsub(/[^0-9]/, "", v); if (v + 0 > 0) hasS = 1 } } }
            END {
                if (skip || (hasR && hasS)) { for (k = 1; k <= n; k++) print L[k]; exit }
                # DF = the .rpt fields to drop, DD = the same as display columns, DB = the banner cells
                if (!hasR) { DF[7] = 1; DF[8] = 1; DF[9] = 1; DD[5] = 1; DD[6] = 1; DD[7] = 1; DB[4] = 1 }
                # the banner cells: GHEAD $3 Files · $4 Retry / Resubmit · $5 Duration ·
                # $6 Volume · $7 Transfers · $8 State · $9 Dates (2026-09-29 fix: State
                # dropped $7 since Transfers moved in front of it, 2026-09-13 — a view
                # without Waiting / Expired lost the Transfers BANNER and kept "State"
                # over the Transfers columns, the Hosts page)
                if (!hasS) { DF[19] = 1; DF[20] = 1; DD[17] = 1; DD[18] = 1; DB[8] = 1 }
                for (k = 1; k <= n; k++) { $0 = L[k]
                    if ($1 == "TABLE") {
                        for (i = 3; i <= NF; i++) {
                            if ($i ~ /^gsep=/)           $i = "gsep=" remap_list(substr($i, 6))
                            else if ($i ~ /^noagg=/)     $i = "noagg=" remap_list(substr($i, 7))
                            else if ($i ~ /^pct=/)       $i = "pct=" remap_pct(substr($i, 5))
                            else if ($i ~ /^drillcols=/) $i = "drillcols=" remap_drills(substr($i, 11)) }
                        print; continue }
                    if ($1 == "GHEAD") { out = ""; for (i = 1; i <= NF; i++) { if (i in DB) continue; out = out (i == 1 ? "" : OFS) $i } print out; continue }
                    if ($1 == "HEAD" || $1 == "KIND" || $1 == "RECALC" || $1 == "ROW" || $1 == "TOTAL") { print keep(); continue }
                    print } }'
    }
    # (the "% of Files" column was removed 2026-07 — the subset views use the
    # summary header unchanged)
    local shead_subset=$shead
    local blk_ok blk_err blk_warn
    blk_ok="$(tbl_variant "OK (result green)" "datereset")"$'\n'"$shead_subset"$'\n'"$(entity_res_block green "$all_rows")"
    blk_err="$(tbl_variant "Error (result red)" "datereset")"$'\n'"$shead_subset"$'\n'"$(entity_res_block red "$all_rows")"
    blk_warn="$(tbl_variant "Warning (result orange)" "datereset")"$'\n'"$shead_subset"$'\n'"$(entity_res_block orange "$all_rows")"
    # the partner GROUP icon map (multi-token merged partner names): render_rpt
    # reads GRPICON_MAP (group name -> slug) to draw the icon; empty for every
    # other entity, so no other page gets one
    local grpmapf=""
    if [ "$name" = partner ]; then
        local grpf="$DATA/flow-manager/xref/_partner-groups.tsv"
        local pslug="$DATA/$area/reports/details/partners/_slugmap.tsv"
        # group name -> slug (reuse the partners detail slugmap so the icon target
        # and the generated page agree); only multi-member groups get a row here.
        if [ -f "$grpf" ] && [ -f "$pslug" ]; then
            grpmapf=$(mktemp "${TMPDIR:-/tmp}/pgrp.XXXXXX")
            LC_ALL=C awk -F'\t' -v OFS='\t' -v sm="$pslug" '
                BEGIN { while((getline l<sm)>0){ split(l,a,"\t"); s[toupper(a[1])]=a[2] } close(sm) }
                { k=toupper($1); if (k in s) print $1, s[k] }' "$grpf" > "$grpmapf" 2>/dev/null || { rm -f "$grpmapf"; grpmapf=""; }
        fi
    fi
    # The blank-by-construction Warning views of SUBSCRIPTIONS strip to the
    # name (orange = never seen there; for the other entities orange means a
    # connected subscription is unseen, so their own figures are real). Not
    # seen was stripped above.
    if [ "$name" = subscription ]; then
        blk_warn=$(printf '%s\n' "$blk_warn" | entities_name_only)
    fi
    # THE REASON COLUMN — the SUBSCRIPTIONS Error view only (2026-08): the
    # per-flow Reason the home page's two red tables showed until 2026-09-29,
    # resolved by the same chain: the flow's
    # NEWEST red failed-sub-all row keeps ITS OWN verdict — the one baked into
    # the error page that row opens — unless the flow is server-reddened
    # (colour/_redflip.tsv); else the classified newest
    # server E line (_kaput-evidence.tsv through the shared
    # bin/flip-reason.awk); else the most specific box (_subs-boxes.tsv).
    # Appended AFTER Last seen, before the @data cells, so every baked column
    # index — and the ?axway_sort= links into these pages — stay put.
    # _subs-boxes.tsv is final before every publish (bin/build/reason-boxes.sh,
    # report stage, 2026-09-30), like the two primary sources.
    if [ "$name" = subscription ] && [ -n "$blk_err" ]; then
        local _lfr="$DATA/$area/reports/failed-sub-all.rpt" _kap="$DATA/server/reports/_kaput-evidence.tsv"
        local _box="$DATA/analyses/reports/_subs-boxes.tsv" _rfl="$DATA/colour/_redflip.tsv" _reasonf
        local _svs="$DATA/$area/reports/_srvsubs.tsv"
        [ -f "$_lfr" ] || _lfr=/dev/null
        [ -f "$_kap" ] || _kap=/dev/null
        [ -f "$_box" ] || _box=/dev/null
        [ -f "$_rfl" ] || _rfl=/dev/null
        [ -f "$_svs" ] || _svs=/dev/null
        _reasonf=$(mktemp "${TMPDIR:-/tmp}/ereason.XXXXXX")
        # the map order cannot leak: it is a name-keyed lookup, every key
        # printed once, so hash iteration in END never reaches the page
        LC_ALL=C awk -F'\t' -v RF="$_rfl" -v KAP="$_kap" -v BOXES="$_box" -v SVS="$_svs" "$(cat bin/flip-reason.awk)"'
            BEGIN {
                while ((getline l < RF) > 0) { n = split(l, a, "\t"); if (n >= 1 && a[1] != "") rfs[toupper(a[1])] = 1 }
                close(RF)
                while ((getline l < KAP) > 0) { n = split(l, a, "\t")
                    if (n < 5 || a[1] == "" || a[5] == "") continue
                    r = flip_reason(a[5]); if (r != "") kapall[toupper(a[1])] = r }
                close(KAP)
                while ((getline l < BOXES) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") why[toupper(a[1])] = a[2] }
                close(BOXES)
                # the SERVER-FAILING sidecar (failed.sh: name ⇥ slug ⇥ stamp ⇥
                # reason ⇥ kind): every red flow with a subscription-named
                # errors/<slug> page — the slug is taken from here, never
                # re-derived (the twin-collision suffix)
                while ((getline l < SVS) > 0) { n = split(l, a, "\t")
                    if (n >= 2 && a[1] != "" && a[2] != "") { k = toupper(a[1])
                        srvslug[k] = a[2]; srvre[k] = (n >= 4) ? a[4] : "" } }
                close(SVS)
            }
            # the newest red failed-sub-all row claims its flow (newest-first:
            # the first row wins), even when its own Reason cell is blank —
            # exactly the home table-1 rule. Map: name ⇥ reason ⇥ kind ⇥ page —
            # kind E = a TRANSFER error (the cell links the file'\''s error
            # page by CoreId), S = a server-failing flow (the cell links its
            # subscription-named errors/<slug> page), D = a boxes verdict with
            # no page (the cell links the subscription'\''s detail page).
            # the failed-sub-all row is Subscription / Date/time / Reason /
            # CoreId (2026-09-29: the Environment column in front went;
            # 2026-09-21 added the CoreId last) — the CoreId page still comes
            # from the @data:href cell, and a server-failing row carries
            # @data:srv=1 (the END srvslug entries cover those)
            $1 == "ROW" {
                red = 0; srv = 0; pg = ""
                for (i = 2; i <= NF; i++) {
                    if ($i == "@data:res=red") red = 1
                    if ($i == "@data:srv=1") srv = 1
                    if (index($i, "@data:href=../files/") == 1) pg = substr($i, 21)
                }
                if (!red || srv) next
                site = $2; sub(/^@\{[^}]*\}/, "", site)
                k = toupper(site)
                if (site == "" || (k in claimed) || (k in rfs)) next
                claimed[k] = 1
                sub(/\.html$/, "", pg)
                if ($4 != "" && pg != "") print site "\t" $4 "\tE\t" pg
            }
            END {
                for (k in srvslug) if (!(k in claimed)) { claimed[k] = 1
                    r = (srvre[k] != "") ? srvre[k] : ((k in kapall) ? kapall[k] : ((k in why) ? why[k] : ""))
                    if (r != "") print k "\t" r "\tS\t" srvslug[k] }
                for (k in kapall) if (!(k in claimed)) { print k "\t" kapall[k] "\tD\t"; claimed[k] = 1 }
                for (k in why) if (!(k in claimed)) print k "\t" why[k] "\tD\t"
            }' "$_lfr" > "$_reasonf"
        blk_err=$(printf '%s\n' "$blk_err" | LC_ALL=C awk -F'\t' -v OFS='\t' -v mapf="$_reasonf" -v nreal="$_nreal" '
            BEGIN { while ((getline l < mapf) > 0) { n = split(l, a, "\t")
                        u = toupper(a[1]); rm[u] = a[2]
                        rk[u] = (n >= 3) ? a[3] : ""; rc[u] = (n >= 4) ? a[4] : "" }
                    close(mapf) }
            # insert v as the display column after the LAST figure column —
            # nreal = the real fields incl. the directive: 10 on the classic
            # layout (Last seen, since the Retry/Resubmit columns), 19 on the
            # Entities2 twin (Avg); the trailing @data cells start at nreal+1
            # and ride along
            function ins(v,   out, i) {
                out = $1
                for (i = 2; i <= nreal; i++) out = out OFS (i <= NF ? $i : "")
                out = out OFS v
                for (i = nreal + 1; i <= NF; i++) out = out OFS $i
                return out
            }
            $1 == "GHEAD"  { print $0 OFS ""; next }   # the banner row gains the Reason column'"'"'s empty cell (2026-09-29: it was one short)
            $1 == "HEAD"   { print ins("Reason"); next }
            $1 == "KIND"   { print ins("text"); next }
            $1 == "RECALC" { print ins("-"); next }
            $1 == "TOTAL"  { print ins(""); next }
            # the Reason cell LINKS its evidence (2026-08): a transfer error
            # (kind E, from the failed-sub-all row) opens the file'\''s own
            # error page by CoreId; a server-failing flow (kind S) opens its
            # subscription-named errors/<slug> page — both live one level
            # under the env root; a boxes verdict with no page (kind D) opens
            # the subscription'\''s detail page (alink, slugmap-resolved)
            $1 == "ROW"    { nm = $2; sub(/^@\{[^}]*\}/, "", nm); u = toupper(nm)
                             v = (u in rm) ? rm[u] : ""
                             if (v != "" && (rk[u] == "E" || rk[u] == "S") && rc[u] != "")
                                 v = "@{href=../../files/" rc[u] ".html}" v
                             else if (v != "")
                                 v = "@{alink=subscriptions/" nm "}" v
                             print ins(v); next }
            { print }')
        rm -f "$_reasonf"
    fi
    for _b in blk_all sumblk_tinted blk_ok blk_warn blk_err blk_ns; do
        eval "[ -n \"\${$_b:-}\" ] || continue"
        eval "$_b=\$(printf '%s\\n' \"\$$_b\" | entity_hide_groups | entity_total_last)"
    done
    # The six views, one page each: <entity>-<view>.html
    local labs=("All" "Seen" "Not seen" "OK" "Warning" "Error") \
          blks=("$blk_all" "$sumblk_tinted" "$blk_ns" "$blk_ok" "$blk_warn" "$blk_err")
    local nview=5   # last index of labs
    local fil=() i j a nav prow1 tmp views
    for i in $(seq 0 $nview); do fil[$i]="$name-$(slugify "${labs[$i]}").html"; done
    local saved_dl=${DLINK_BASE:-}
    DLINK_BASE="../../details/"
    # render_rpt reads GRPICON_MAP (partner group name -> slug) to draw the icon;
    # empty for every non-partner entity, so no other page gets one.
    local GRPICON_MAP="$grpmapf"
    mkdir -p "$DOCS/$area/entities"
    for i in $(seq 0 $nview); do
        # Row: entity members | All Seen Not-seen OK Warning Error
        views=""
        for j in $(seq 0 $nview); do
            a=0; [ "$j" = "$i" ] && a=1
            views+=$'\t'"$a|${labs[$j]}|${fil[$j]}"
        done
        nav="NAV${views}"
        prow1=$(group_nav_row "$area" "$name" "${labs[$i]}")
        [ -n "$prow1" ] && nav="${prow1}"$'\t@sep\t'"${nav#NAV$'\t'}"
        tmp=$(mktemp "${TMPDIR:-/tmp}/rpt.XXXXXX")
        { _hdr_with_nav "$HEADER" "$nav"; printf '%s\n' "${blks[$i]}"; printf '%s' "$FOOTER"; } > "$tmp"
        # the views render FOUR AT A TIME (2026-09-27): the nine entity
        # reports start first and each rendered its pages one after
        # another, holding nine of the pool slots while the other ~60
        # reports queued behind them; each view writes its own page
        { render_rpt "$tmp" "$DOCS/$area/entities/${fil[$i]}" "../../assets/style.css" "../index.html" "$rlabel" 1 "$hslug" "$rkey"; rm -f "$tmp"; } &
        _evp+=("$!")
        if [ "${#_evp[@]}" -ge 4 ]; then wait "${_evp[0]}"; _evp=("${_evp[@]:1}"); fi
    done
    for _ev in ${_evp[@]+"${_evp[@]}"}; do wait "$_ev"; done
    entity_payload_split "$DOCS/$area/entities" "$name" "${fil[@]}"
    DLINK_BASE=$saved_dl
    [ -n "$grpmapf" ] && rm -f "$grpmapf"
    return 0
}

# THE ENTITIES ROW PAYLOAD, ONCE PER ENTITY (2026-09-30, the lean round —
# the six views of an entity repeated the same per-row data about three
# times over, ~17 MB of the sample site): every data ROW's payload
# attributes — data-buckets, data-durdays, data-fp and the data-coreids-*
# drill lists — move out of the six rendered view pages into ONE
# <entity>-data.js (window.AXWAY_EP: a template string of
# `<tr data-k="N" …payload…></tr>` lines, each distinct payload once, the
# All view's rows first); each page row keeps its other attributes
# (data-res: the home consistency gate counts it) plus data-k="N", and the
# page loads the .js before report.js, whose attachEntityPayload() puts
# the attributes back on the rows FIRST in init() — every later reader
# (recalc, drills, totals, the seen / date filters) sees the page as it was.
# The TOTAL row keeps its own buckets (they differ per view). linkcheck
# reads the data-fp edges from the .js. $1 dir  $2 entity  $3.. the view
# page basenames, All first.
entity_payload_split() {
    local dir=$1 name=$2; shift 2
    local js="$dir/$name-data.js" f ck files=()
    for f in "$@"; do [ -f "$dir/$f" ] && files+=("$dir/$f"); done
    [ ${#files[@]} -gt 0 ] || return 0
    LC_ALL=C awk -v JS="$js.tmp" -v JSNAME="$name-data.js" '
        BEGIN { printf "window.AXWAY_EP=`" > JS; n = 0 }
        FNR == 1 { if (out != "") close(out); out = FILENAME ".ep" }
        # the data.js script goes in right before report.js (deferred
        # scripts run in document order, so it has run when init() does)
        index($0, "<script src=\"") == 1 && index($0, "assets/report.js") > 0 {
            print "<script src=\"" JSNAME "?v=@EPV@\" defer></script>" > out
            print > out; next
        }
        /^<tr [^>]*data-(buckets|durdays|fp|coreids-[a-z0-9]+)="/ && index($0, "<tr class=\"total\"") != 1 {
            rest = substr($0, 4); blob = ""; kept = ""
            # walk the tag attribute by attribute (values never hold a raw
            # quote: the renderer escapes them)
            while (match(rest, /^ [A-Za-z0-9-]+="[^"]*"/)) {
                at = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
                if (at ~ /^ data-(buckets|durdays|fp|coreids-[a-z0-9]+)="/) blob = blob at
                else kept = kept at
            }
            if (blob == "") { print > out; next }
            if (!(blob in IDX)) {
                IDX[blob] = n
                b = blob; gsub(/\\/, "\\\\", b); gsub(/`/, "\\`", b); gsub(/\$\{/, "\\${", b)
                printf "%s<tr data-k=\"%d\"%s></tr>", (n ? "\n" : ""), n, b > JS
                n++
            }
            print "<tr data-k=\"" IDX[blob] "\"" kept rest > out
            next
        }
        { print > out }
        END { printf "`;\n" > JS; close(JS); if (out != "") close(out) }
    ' "${files[@]}" || return 1
    ck=$(cksum < "$js.tmp" | awk '{ print $1 }')
    mv "$js.tmp" "$js"
    for f in "${files[@]}"; do
        LC_ALL=C awk -v ck="$ck" '{ i = index($0, "?v=@EPV@"); if (i) $0 = substr($0, 1, i + 2) ck substr($0, i + 8); print }' "$f.ep" > "$f" && rm -f "$f.ep"
    done
    return 0
}

split_search_rows() {   # $1 rendered search.html  $2 data file to write
    split_table_rows "$1" "$2" 'window.AXWAY_SEARCH=`' '`;'
}

# The row lifter behind split_search_rows: every rendered data row of PAGE
# (a <tr> line with a <td>, total rows excepted) moves into DATA between the
# PROLOGUE and EPILOGUE lines, the page keeps its header and total, and the
# payload's <script> tag goes in before report.js. (Its second user, the
# Latest files pages' docs/latest/<slug>.js, went 2026-09-29.)
split_table_rows() {   # $1 page  $2 data file  $3 prologue  $4 epilogue
    local page=$1 data=$2 pro=$3 epi=$4 tmp="$1.tmp.$$"
    [ -f "$page" ] || return 0
    : > "$data.rows"
    # Encoding: ONE JS template literal, one rendered row per line, and NOTHING
    # else — no name/type prefix. Carrying them alongside cost 21 KB gzipped
    # (measured), while report.js can slice them out of the row string once on
    # first use for ~10 ms. A template literal needs only three escapes (\ ` ${)
    # where a JSON string would escape every attribute quote; backslashes are
    # escaped because subscription paths are full of them (F:\Data\Opswise\...).
    awk -v rowfile="$data.rows" '
        function esc(x) { gsub(/\\/, "\\\\", x); gsub(/`/, "\\`", x); gsub(/\$\{/, "\\${", x); return x }
        /^<tr[ >]/ && /<td/ && $0 !~ /class="total"/ {
            printf "%s\n", esc($0) > rowfile
            next
        }
        { print }
    ' "$page" > "$tmp"
    {
        printf '%s\n' "$pro"
        cat "$data.rows"
        printf '%s\n' "$epi"
    } > "$data"
    rm -f "$data.rows"
    mv "$tmp" "$page"
    # BEFORE report.js: defer scripts execute in document order, so the payload
    # must already be on window when report.js's init runs — otherwise a page
    # opened with ?axway_search=… (or a remembered query) builds nothing.
    # ?v= = the data file's own cksum (the ASSET_VER pattern): the tag has no
    # cache-buster of its own, so a browser kept serving a STALE payload —
    # rows for entities the parse has since re-attributed — under a fresh page.
    local dver; dver=$(cksum < "$data" | awk '{print $1}')
    awk -v ins="<script src=\"$(basename "$data")?v=$dver\" defer></script>" \
        '/<script src=[^>]*report\.js/ && !done { print ins; done = 1 } { print }' "$page" > "$page.tmp2.$$" \
        && mv "$page.tmp2.$$" "$page"
}

render_report() {   # $1 area  $2 name  $3 rpt
    local area=$1 name=$2 rpt=$3
    # NO PROSE ON THE REPORT PAGES (2026-09-13, user request): the .rpt INTRO
    # and NOTE lines are not rendered on any report page — every page this
    # function (and the functions it calls) renders; the report's hand-written
    # HELP page explains it (assets/help/), the Report finder shows the DESC. The drill and
    # record pages (files/ — the error and File pages, the record and value pages, the detail
    # pages) keep their INTRO — there it states facts, not explanations.
    local RPT_NOPROSE=1
    # (the top-bar right label — "TRANSFER - <entry label>", two subshells +
    # tr + awk per report — went 2026-09-29: html_head has not printed it since
    # the quick-search box replaced it; the positional slot stays, empty)
    local rlabel=""
    local hslug; hslug=$(help_slug_for "$area" "$name")
    # The search/sort persistence key (html_head's report-key meta): the same on
    # every page of this report — all its table-tab pages — so a typed search
    # survives tab switches.
    local rkey=$name
    # The cross pages (configured vs logged pairs) and Entity Search (static
    # name lists) are not date-bound — no From/To selectors: suppress the
    # report-dates meta (html_head emits it from CUR_DATES) while rendering,
    # in the single-page and per-table branches alike.
    local saved_dates=${CUR_DATES:-}
    case $name in cross-*|entity-search|entity-coverage|skipped) CUR_DATES="" ;; esac
    # The Entities reports have their own four-page renderer (see above).
    case $name in
        account|login|subscription|remote-host|logical|partner|application|domain|bl)
            # the Entities PAGES render from bin/transfer/reports/entities.sh's
            # grouped entities/<name>.rpt (2026-09-13); the classic <name>.rpt
            # ($rpt) is a DATA producer only — showseen, entity-search, the
            # server rosters read it — and renders no page
            if [ -f "$DATA/$area/reports/entities/$name.rpt" ]; then
                render_entity_report "$area" "$name" "$DATA/$area/reports/entities/$name.rpt" "$rlabel" "$hslug" "$rkey"
            else
                echo "  (no entities/$name.rpt yet — bin/transfer/reports/entities.sh writes it)" >&2
            fi
            CUR_DATES=$saved_dates
            return ;;
        entity-search)
            # published under docs/search/ as search.html (2026-09-12, user
            # request — at the docs root 2026-07..09; the six File search
            # pages moved with it) — css depth 1, entity links into
            # ../details/; the row payload search-data.js sits beside it
            local saved_dl=${DLINK_BASE:-}
            DLINK_BASE="../details/"
            mkdir -p "$DOCS/search"
            render_rpt "$rpt" "$DOCS/search/search.html" "../assets/style.css" "../index.html" "$rlabel" 1 "$hslug" "$rkey"
            DLINK_BASE=$saved_dl
            split_search_rows "$DOCS/search/search.html" "$DOCS/search/search-data.js"
            CUR_DATES=$saved_dates
            return ;;
    esac
    # The Subscriptions analyses group: the DATA is this area's, the PAGE lives
    # in docs/analyses/ (same depth as the area dirs, so every relative
    # prefix is unchanged -- only the directory moves). group_of returns "" for
    # them, so row1 is empty (the group row comes from apply_report_groups).
    local pagedir=$area
    if is_subs_report "$name"; then pagedir=analyses; fi   # if, not && — set -e
    local row1; row1=$(group_nav_row "$area" "$name")
    local labels; labels=$(report_tabs "$name")
    if [ -z "$labels" ]; then
        if [ -z "$row1" ]; then
            render_rpt "$rpt" "$DOCS/$pagedir/$name.html" "../assets/style.css" "index.html" "$rlabel" 1 "$hslug" "$rkey"
        else
            segment_rpt "$rpt"   # grouped single-page report: inject the group row, keep EVERY table
            # A report-emitted NAV (e.g. Duration's "Delivered Files / All Files"
            # view buttons) merges onto the group row to the RIGHT (@sep) — like a
            # tabbed report's table-tabs — instead of rendering as its own row.
            local mynav; mynav=$(printf '%s' "$HEADER" | awk -F'\t' '$1=="NAV"{print; exit}')
            [ -n "$mynav" ] && row1="${row1}"$'\t@sep\t'"${mynav#NAV$'\t'}"
            local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/rpt.XXXXXX")
            # The group tab bar sits right under the h1, ABOVE the intro; any
            # STAT info boxes render below both (tabs are navigation, so they
            # stay on top).
            { _hdr_with_nav "$(printf '%s' "$HEADER" | awk -F'\t' '$1!="STAT" && $1!="NAV"')" "$row1"
              printf '%s' "$HEADER" | awk -F'\t' '$1=="STAT"'
              local bi
              for ((bi=1; bi<=NTAB; bi++)); do printf '%s\n' "${TBLOCK[$bi]}"; done
              printf '%s' "$FOOTER"; } > "$tmp"
            render_rpt "$tmp" "$DOCS/$pagedir/$name.html" "../assets/style.css" "index.html" "$rlabel" 1 "$hslug" "$rkey"
            rm -f "$tmp"
        fi
        CUR_DATES=$saved_dates
        return
    fi
    segment_rpt "$rpt"
    local laba; IFS='|' read -r -a laba <<< "$labels"
    # PAD to the label count: a component writing its own single-table
    # empty state (config-only estate — no logs at all) leaves the report
    # with fewer TABLEs than report_tabs lists, but the group nav's
    # same-label carry (member_page_for_label) links EVERY label's page from
    # the sibling reports — so each missing trailing table gets the
    # merge_rpt no-data stub and its page renders instead of 404ing. The pad
    # carries an (empty) HEAD: a report page renders no NOTE, and a header row
    # over zero data rows is what report.js reads as "no rows" and says so.
    while [ "$NTAB" -lt "${#laba[@]}" ]; do
        NTAB=$((NTAB+1))
        TBLOCK[$NTAB]=$'TABLE\t\nHEAD\t\nNOTE\tThis view has no data in this environment.'
    done
    local i j files=() lbl
    for ((i=1; i<=NTAB; i++)); do
        lbl=${laba[$((i-1))]:-Table $i}
        files[$i]="$name-$(slugify "$lbl").html"
    done
    # The cross-reference pages are an ANALYSES feature, so they live in
    # docs/analyses/xref/ (same depth as the old transfer/xref/, so the
    # css/home/detail-link paths are unchanged — only the directory moves). They
    # are still rendered here in the transfer loop (area=transfer), so the write
    # path goes up-and-over via outsub. The in-page NAV hrefs are bare filenames.
    local outsub="" pcss="../assets/style.css" phome="index.html" saved_dl=${DLINK_BASE:-}
    # (the cross members, their labels and this page's own label ONCE per
    # report — 2026-09-28, speed round 24: the three member loops below forked
    # ~30 label subshells per page, ~2,000 per publish)
    local _cxn=() _cxl=() _cxk _cxself=""
    case $name in cross-*)
        outsub="../analyses/xref/"; pcss="../../assets/style.css"; phome="../index.html"
        DLINK_BASE="../../details/"; mkdir -p "$DOCS/analyses/xref"
        for _cxk in $(group_members cross); do _cxn+=("$_cxk"); _cxl+=("$(member_label "$_cxk")"); done
        _cxself=$(member_label "$name") ;;
    esac
    for ((i=1; i<=NTAB; i++)); do
        local nav="NAV" a prow1="" ei vi e2 v2 a2 lbl2
        for ((j=1; j<=NTAB; j++)); do
            a=0; [ "$j" = "$i" ] && a=1
            nav+=$'\t'"$a|${laba[$((j-1))]}|${files[$j]}"
        done
        # The cross reports' tables are one per SECOND entity. They render TWO
        # full entity rows — row 1 picks the FIRST entity, row 2 the SECOND —
        # each listing all 9 entities in the same canonical order (the group
        # member order). An entity can't cross itself, so each row grays out
        # the entity the OTHER row has selected (NAV state 2: unlinked, dimmed).
        case $name in cross-*)
            local cur2 self m ml
            cur2=${laba[$((i-1))]}                       # the page's second entity, e.g. "Login"
            self=$_cxself                                # the page's first entity, e.g. "Account"
            # Row 1 — first entity: current member active; the member matching
            # the second entity disabled; the rest keep the same second-entity
            # tab (it exists on every other member, only the disabled one lacks it).
            prow1="NAV"
            for ((_cxk = 0; _cxk < ${#_cxn[@]}; _cxk++)); do
                m=${_cxn[_cxk]}; ml=${_cxl[_cxk]}
                if [ "$m" = "$name" ]; then prow1+=$'\t'"1|$ml|"
                elif [ "$ml" = "$cur2" ]; then prow1+=$'\t'"2|$ml|"
                else prow1+=$'\t'"0|$ml|$(member_page_for_label "$m" "$cur2")"
                fi
            done
            # Row 2 — second entity: all 8 in the same order (this member's tab
            # list is that order minus itself); the page's own entity disabled.
            nav="NAV"; e2=0
            for ((_cxk = 0; _cxk < ${#_cxn[@]}; _cxk++)); do
                m=${_cxn[_cxk]}; ml=${_cxl[_cxk]}
                if [ "$ml" = "$self" ]; then nav+=$'\t'"2|$ml|"
                else
                    a2=0; [ "$e2" = "$((i-1))" ] && a2=1
                    nav+=$'\t'"$a2|$ml|${files[$((e2+1))]}"
                    e2=$((e2+1))
                fi
            done
            # SWAP (2026-08-29): the same pair the other way around — the
            # second entity's own member page showing THIS page's first
            # entity as ITS second (cross-account-subscriptions <->
            # cross-subscription-account). Appended after a gap on the
            # second-entity row; hrefs here are bare filenames like the rest.
            local m2 swapf=""
            for ((_cxk = 0; _cxk < ${#_cxn[@]}; _cxk++)); do
                m2=${_cxn[_cxk]}
                [ "${_cxl[_cxk]}" = "$cur2" ] || continue
                swapf=$(member_page_for_label "$m2" "$self"); break
            done
            [ -n "$swapf" ] && nav+=$'\t@sep\t'"0|Swap|$swapf"
        ;; esac
        # Per-page group row: siblings with the same table tab link to that
        # tab, so the reader stays on Summary/Detail when switching. (The
        # cross-* branch above builds its own two rows — skip it there.)
        if [ -n "$row1" ] && [ -z "$prow1" ]; then
            prow1=$(group_nav_row "$area" "$name" "${laba[$((i-1))]:-}")
            if combine_group_nav "$area" "$name"; then   # members | table tabs on ONE row
                nav="${prow1}"$'\t@sep\t'"${nav#NAV$'\t'}"; prow1=""
            fi
        fi
        # A NAV the REPORT itself emits INSIDE a table block (entity-coverage's
        # rule row until 2026-09-29 — it had to live there to be per-entity;
        # no report emits one now, the hook stays generic) merges onto the
        # table-tab row to the RIGHT (@sep) instead of rendering as its own
        # row below it: the same treatment duration's own NAV gets on the
        # single-page branch above. So the page reads "entity buttons | gap |
        # rule buttons" on ONE line.
        local blk=${TBLOCK[$i]} blknav
        blknav=$(printf '%s\n' "$blk" | awk -F'\t' '$1=="NAV"{print; exit}')
        if [ -n "$blknav" ]; then
            nav="${nav}"$'\t@sep\t'"${blknav#NAV$'\t'}"
            blk=$(printf '%s\n' "$blk" | awk -F'\t' '$1!="NAV"')
        fi
        # Cross pages: the shared HEADER's TITLE names only the FIRST entity —
        # append this page's second entity ("Cross Reference: Application -
        # Partners") so every pair page is titled by BOTH its entities.
        local phdr="$HEADER"
        case $name in cross-*)
            phdr=$(printf '%s' "$HEADER" | awk -F'\t' -v add=" - ${laba[$((i-1))]}" \
                'BEGIN { OFS = FS } $1 == "TITLE" { $2 = $2 add } { print }')$'\n'
        ;; esac
        local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/rpt.XXXXXX")
        # The title-first placement is for the GROUP MEMBER buttons: the block
        # moves up only when it actually carries them (row1 non-empty — either
        # as its own prow1, or merged into nav by combine_group_nav). A report
        # whose only row is its own table tabs (pirates: Details | Top view)
        # keeps them under the intro, where every ungrouped report has always
        # had them.
        #
        # The CROSS pages are the exception: their group row is the analyses
        # "Configuration" row that apply_report_groups injects after the
        # </h1>, so the two rows built above are the report's OWN entity
        # selectors, not group members. They belong under the intro that
        # explains what a cross reference is — h1 -> group row -> intro ->
        # first entity -> second entity, the same shape a Skipped page reads
        # (group row -> intro -> per-value row).
        local navfirst=0
        if [ -n "$row1" ] || [ -n "$prow1" ]; then navfirst=1; fi
        case $name in cross-*) navfirst=0 ;; esac
        local navblk=$nav; [ -n "$prow1" ] && navblk="$prow1"$'\n'"$nav"
        { if [ "$navfirst" = 1 ]; then
              _hdr_with_nav "$phdr" "$navblk"
          else
              printf '%s' "$phdr"; printf '%s\n' "$navblk"
          fi
          printf '%s\n' "$blk"; printf '%s' "$FOOTER"; } > "$tmp"
        render_rpt "$tmp" "$DOCS/$pagedir/$outsub${files[$i]}" "$pcss" "$phome" "$rlabel" 1 "$(tab_help_slug "$area" "$name" "${laba[$((i-1))]:-}")" "$rkey"
        rm -f "$tmp"
    done
    DLINK_BASE=$saved_dl
    CUR_DATES=$saved_dates
}

# ---- the Subscriptions analyses group ---------------------------------------
# Called by bin/analyses/publish.sh, NOT by the area publishes: those run first
# and bin/analyses/publish.sh clears docs/analyses/*.html, so anything they
# wrote there would be deleted again. Each member renders from its own area's
# .rpt (render_report's pagedir sends the page to analyses/), or gets an
# empty-report placeholder when this env has no data for it — the same contract
# render_missing_reports gives the area reports.
render_subs_group_pages() {
    local spec area name rpt n=0 miss=0 saved=${CUR_DATES:-}
    for spec in $SUBS_GROUP_REPORTS; do
        area=${spec%%:*}; name=${spec#*:}
        rpt="$DATA/$area/reports/$name.rpt"
        # analyses-area members (2026-08): .rpt in data/analyses/reports/,
        # transfer date range (they read the transfer caches)
        if [ "$area" = transfer ] || [ "$area" = analyses ]; then CUR_DATES=$TRANSFER_DATES; else CUR_DATES=$SERVER_DATES; fi
        # a SERVER member gets the same subscription row tints its area pages
        # get (bin/server/publish.sh) — the page lands here, the report is still
        # a server report
        RPT_SUBTINT=""
        if [ "$area" = server ] && [ -f "$DATA/flow-manager/base/_subscriptions.tsv" ]; then
            RPT_SUBTINT="$DATA/flow-manager/base/_subscriptions.tsv $DATA/flow-manager/base/_accounts.tsv"
        fi
        if [ -f "$rpt" ]; then
            render_report "$area" "$name" "$rpt"
            n=$((n + 1))
        else
            _subs_placeholder "$area" "$name"
            miss=$((miss + 1))
        fi
    done
    CUR_DATES=$saved; RPT_SUBTINT=""
    printf 'Rendered %d Subscriptions group page(s) into docs/analyses/' "$n" >&2
    [ "$miss" -gt 0 ] && printf ' (+%d empty-report placeholder(s))' "$miss" >&2
    printf '.\n' >&2
}

# One empty-report placeholder for a Subscriptions member with no .rpt in this
# env; bin/build/publish.sh apply_report_groups gives it its group's first row
# like any member page, so the group stays navigable.
_subs_placeholder() {   # $1 area  $2 name
    local area=$1 name=$2 fp out title html labels lbl pages pg
    fp=$(first_page "$name")
    title=$(member_label "$name"); [ -n "$title" ] || title=$(entry_label "$area" "$name")
    # a TABBED member (uc-status) needs a placeholder for EVERY tab page —
    # other pages link the sibling tabs directly (a boxes explanation links
    # uc-status-uc3.html), and only stubbing the first left those links
    # broken in an env without the data (production 2026-08)
    # one "page<TAB>label" line per placeholder (the label picks the tab's
    # help page, tab_help_slug)
    pages="$fp"$'\t'$'\n'
    labels=$(report_tabs "$name")
    if [ -n "$labels" ]; then
        pages=""
        while IFS= read -r lbl; do
            [ -n "$lbl" ] && pages="$pages$name-$(slugify "$lbl").html"$'\t'"$lbl"$'\n'
        done <<< "$(printf '%s' "$labels" | tr '|' '\n')"
    fi
    while IFS=$'\t' read -r pg lbl; do
        [ -n "$pg" ] || continue
        out="$DOCS/analyses/$pg"
        {
            html_head "$title" "../assets/style.css" "" "" "$(tab_help_slug "$area" "$name" "$lbl")" "$area" "$name"
            esc "$title"; printf '<h1>%s</h1>\n' "$ESC"
            printf '<p class="range">This report has <strong>no data in this environment</strong> — the log lines or configuration it reads are absent, so its report file was not produced.</p>\n'
            printf '</body>\n</html>\n'
        } > "$out"
    done <<< "$pages"
}

# ---- index helpers -----------------------------------------------------------

# entry_label AREA NAME — a report's title where no member label exists (the
# empty-report placeholders): grouped -> the group label; else its TITLE, else
# the static member label, else the basename.
entry_label() {   # $1 area  $2 basename
    local area=$1 name=$2 g t
    g=$(group_of "$area" "$name")
    if [ -n "$g" ]; then group_label "$g"; return; fi
    t=""
    [ -f "$DATA/$area/reports/$name.rpt" ] && t=$(field1 TITLE "$DATA/$area/reports/$name.rpt")
    # no .rpt in this env (the menus/sitemap list ALL reports, 2026-07):
    # fall back to the static member label, else the basename
    if [ -z "$t" ]; then
        t=$(member_label "$name")
        [ -n "$t" ] || t=$name
    fi
    t=${t#Transfer }; echo "${t% Counts}"
}
# ---- Month stats (2026-09-13, user request) ---------------------------------
# The 18 pages of the month stats (bin/transfer/reports/entities.sh's
# month_stats part; month-stats.sh until 2026-09-30) — {this,previous} × the
# nine entities — under docs/<area>/month-stats/, the Reports pulldown's
# Activity & volume group (retired and brought back 2026-09-29). Two tab rows: the MONTH (Current month · Previous month, each
# with its yyyy-mm from the .rpt META) and the ENTITY (the Entities order).
# No date filter (a page IS one month); no prose (help page month-stats).
render_month_stats() {   # $1 area
    local area=$1
    local rdir="$DATA/$area/reports/month-stats" odir="$DOCS/$area/month-stats"
    mkdir -p "$odir"; rm -f "$odir"/*.html
    [ -f "$rdir/this-subscription.rpt" ] || { echo "  (no month-stats .rpt yet — bin/transfer/reports/entities.sh writes them)" >&2; return 0; }
    local ents="subscription logical partner account login remote-host domain application bl"
    local w e a rpt tmp nav row1 row2 lbl n=0 mon_this mon_prev
    mon_this=$(meta_val "$rdir/this-subscription.rpt" month); mon_prev=$(meta_val "$rdir/previous-subscription.rpt" month)
    local saved_dates=${CUR_DATES:-} saved_dl=${DLINK_BASE:-}
    CUR_DATES=""; DLINK_BASE="../../details/"
    for w in this previous; do
        for e in $ents; do
            rpt="$rdir/$w-$e.rpt"; [ -f "$rpt" ] || continue
            row1=""
            for a in this previous; do
                if [ "$a" = this ]; then lbl="Current month ($mon_this)"; else lbl="Previous month ($mon_prev)"; fi   # "Current", like the date preset (2026-09-29)
                if [ "$a" = "$w" ]; then row1+=$'\t'"1|$lbl|$a-$e.html"; else row1+=$'\t'"0|$lbl|$a-$e.html"; fi
            done
            row2=""
            for a in $ents; do
                if [ "$a" = "$e" ]; then row2+=$'\t'"1|$(member_label "$a")|$w-$a.html"; else row2+=$'\t'"0|$(member_label "$a")|$w-$a.html"; fi
            done
            nav="NAV${row1}"$'\t@sep'"${row2}"
            segment_rpt "$rpt"
            tmp=$(mktemp "${TMPDIR:-/tmp}/rpt.XXXXXX")
            { _hdr_with_nav "$HEADER" "$nav"; printf '%s\n' "${TBLOCK[1]:-}"; printf '%s' "$FOOTER"; } > "$tmp"
            RPT_NOPROSE=1 render_rpt "$tmp" "$odir/$w-$e.html" "../../assets/style.css" "../index.html" "TRANSFER - Month stats" 1 "month-stats" "month-stats"
            rm -f "$tmp"; n=$((n + 1))
        done
    done
    CUR_DATES=$saved_dates; DLINK_BASE=$saved_dl
    echo "Rendered docs/$area/month-stats/ ($n page(s))." >&2
}

# ---- THE REPORT GROUPS: one "Reports" pulldown (2026-09-29, user request) ---
# "Reorganise Transfer Reports and Server Reports and Analyses and Goodies,
# just one pulldown named Reports, create logical groups, have all reports in
# the same group link to each other with the first selection buttons." The
# four dropdowns (Transfer reports / Server reports / Analyses / Goodies) and
# their three start pages are gone: the Reports pulldown lists these groups,
# each line landing on the group's FIRST member, and every page of every
# member carries the group's members as its FIRST row of buttons (injected by
# bin/build/publish.sh apply_report_groups — Entities keeps its native
# members | views row). THE SINGLE SOURCE OF TRUTH for the menu, the start
# page (reports/index.html), the sitemap's group cards, the h1 group tags
# and the rows.
# One line per group: "<Group label>|<member>|<member>|…", member =
# "<dir>/<stem>=<Label>":
#   dir   transfer | server | analyses — the docs/ directory the page renders
#         into (the SUBS_GROUP_REPORTS render into analyses/ whatever their
#         data area) — plus transfer/entities (the nine Entities, landing on
#         <stem>-all.html), analyses/xref (Cross References, stem cross) and
#         transfer/month-stats (Month stats: EVERY page of the directory, the
#         {this,previous}-<entity> pairs; stem "this", landing on
#         this-subscription.html — 2026-09-29)
#   stem  the report basename, or a hand-written page's name; the member's
#         pages are <dir>/<stem>.html and <dir>/<stem>-*.html (its tabs and
#         views), a LONGER member stem in the same dir winning (duration vs
#         duration-longest / duration-dwell)
# A report in no group has no row and no menu line — every published report
# belongs to one (the former boxes-only reports included). The "Server log
# errors" group was folded into Failures (2026-09-29, user request), and
# Failures was renamed ERRORS the same day (user request: "Rename Failures to
# Errors") — out of the pulldown, a top-bar link of its own (assets/topbar.js).
_report_groups() {
    # Performance is the FIRST pulldown line (2026-09-30, user request "Have
    # Performance as first row in the Reports pulldown"): Overview, Entities
    # and Errors above it are top-bar links, not menu lines.
    printf '%s\n' \
        "Overview|transfer/topview=Transfer top view|server/topview=Server top view" \
        "Entities|transfer/entities/subscription=Subscriptions|transfer/entities/logical=Logical|transfer/entities/partner=Partners|transfer/entities/account=Accounts|transfer/entities/login=Logins|transfer/entities/remote-host=Hosts|transfer/entities/domain=Domains|transfer/entities/application=Applications|transfer/entities/bl=BL" \
        "Errors|analyses/failed=Failed Subscriptions|analyses/failing-reasons=Error reasons|transfer/failed-files=Failed files|transfer/unknown-transfers=Unknown transfers|transfer/pirates=One-legged|transfer/episodes=Recovered flows|transfer/retries=Retries & resubmissions|transfer/failure-heatmap=Failure heatmap|server/errors=Errors|server/failure-flows=Per flow|server/io-errors=IO errors|server/routing-errors=Routing errors" \
        "Performance|transfer/duration=Duration|transfer/duration-longest=Longest Files|transfer/duration-dwell=Store-and-forward|transfer/anomalies=Anomalies" \
        "Use cases & delivery|analyses/use-cases=Use cases|analyses/uc-status=UC status|analyses/polling=Polling|transfer/waiting-expired=Waiting & Expired|transfer/went-quiet=Went quiet" \
        "Activity & volume|transfer/activity=Activity|transfer/ranking=Ranking|transfer/files=Sizes & types|transfer/month-stats/this=Month stats" \
        "Flow patterns|transfer/file-journey=File journey|transfer/file-in-file-out=File in - File out|transfer/same-protocol=Inbound and Outbound same Protocol" \
        "Protocols & security|transfer/protocol=Protocol, Direction & Mode|transfer/security-params=Security Parameters|transfer/security-outreach=Security outreach|transfer/av-scan=AV Scan|transfer/connection-efficiency=Connection efficiency" \
        "Logons & connections|server/logons=Logons|server/connections=Connections" \
        "Partners|analyses/partners-in=Partners in|analyses/partners-out=Partners Out" \
        "Configuration|analyses/subscriptions=Configured subscriptions|analyses/accounts=Configured accounts|analyses/logical-detection=Logical detection|analyses/xref/cross=Cross References" \
        "Coverage|analyses/first-seen=First seen|transfer/entity-coverage=Entity coverage|transfer/not-in-flow-manager=Not in Flow Manager|transfer/skipped=Skipped|server/missing-entities=Missing entities"
}
# THE SUB-ROWS (2026-09-29, user request: "On the group Failures move the 4
# server logs to 4 buttons as [a second] selection, have "Server log" as first
# selection for it"): members of a group that collapse into ONE entry of the
# group's first row — its label, landing on the sub-row's first member — and
# get a SECOND row of their own on their pages (apply_report_groups).
# One line per sub-row: "<Group>|<Entry label>|<member>|<member>|…", every
# member also a member of that group in _report_groups (their order and
# labels come from there; the entry sits where the first of them is).
_report_subrows() {
    printf '%s\n' \
        "Errors|Server log|server/errors|server/failure-flows|server/io-errors|server/routing-errors"
}
# rg_landing MEMBER ("dir/stem") -> RG_LANDING, the member's landing page,
# docs-root-relative (a variable, not stdout: the callers loop over hundreds of
# pages and a $( ) per call is a fork)
rg_landing() {
    local dir=${1%/*} stem=${1##*/}
    case $dir in
        transfer/entities) RG_LANDING="transfer/entities/$stem-all.html" ;;
        analyses/xref)     RG_LANDING="analyses/$(group_home cross)" ;;
        transfer/month-stats) RG_LANDING="transfer/month-stats/this-subscription.html" ;;
        *)                 RG_LANDING="$dir/$(first_page "$stem")" ;;
    esac
}
# rg_rel FROM TO -> RG_REL, page TO as an href from page FROM (both
# docs-root-relative): the directories the two share dropped, one "../" per
# directory of FROM left over, then the rest of TO (analyses/xref/a.html ->
# analyses/b.html = ../b.html; transfer/x.html -> server/y.html = ../server/y.html)
rg_rel() {
    local fd=$1 td=$2 up="" a b
    case $fd in */*) fd=${fd%/*}/ ;; *) fd="" ;; esac
    while [ -n "$fd" ]; do
        a=${fd%%/*}
        case $td in "$a"/*) ;; *) break ;; esac
        fd=${fd#*/}; td=${td#*/}
    done
    while [ -n "$fd" ]; do up="../$up"; fd=${fd#*/}; done
    RG_REL="$up$td"
}

# THE REPORTS PULLDOWN — Start page (reports/index.html) + one line per group,
# landing on its first member. "@" = the page's docs-root prefix, swapped per
# page by assets/topbar.js (topbar-data.js `reports`).
# NOT Entities (2026-09-29, user request): the top bar's own Entities link
# opens them; the group stays for the start page, the finder and the h1 tags.
# NOT Errors either (2026-09-29, user request: "Remove Failures from the
# Reports Pulldown, have it as an own link in the Top Menu bar"): its link is
# ERRORS_HREF, the group's first member's landing page.
# NOT Overview either (2026-09-29, user request: "Move Overview from the
# Reports pulldown to the top menu bar, just before Entities"): OVERVIEW_HREF.
# NOT Partners either (2026-09-30, user request: "Remove Partners from the
# Reports pulldown"): the top bar links Partners in, whose group row reaches
# Partners Out; the group stays for the start page, the sitemap and the rows.
REPORTS_MENU='<a class="ddtop" href="@reports/index.html">Start page</a>'
ERRORS_HREF=""; OVERVIEW_HREF=""
while IFS= read -r _rgl; do
    [ -n "$_rgl" ] || continue
    case ${_rgl%%|*} in Entities|Partners) continue ;; esac
    if [ "${_rgl%%|*}" = Errors ] || [ "${_rgl%%|*}" = Overview ]; then
        _rgf=${_rgl#*|}; _rgf=${_rgf%%|*}; rg_landing "${_rgf%%=*}"
        if [ "${_rgl%%|*}" = Errors ]; then ERRORS_HREF=$RG_LANDING; else OVERVIEW_HREF=$RG_LANDING; fi
        continue
    fi
    _rgf=${_rgl#*|}; _rgf=${_rgf%%|*}; _rgf=${_rgf%%=*}
    rg_landing "$_rgf"; esc "${_rgl%%|*}"
    REPORTS_MENU+="<a href=\"@$RG_LANDING\">$ESC</a>"
done < <(_report_groups)
unset _rgl _rgf

# (The former analyses group rows — _analyses_groups and its no-op stubs
# analyses_group_tabs[_ctx] / analyses_grouprow_for — went 2026-09-29: every
# group row comes from _report_groups via apply_report_groups.)

# Insert a one-line HTML fragment DIRECTLY BEFORE the page's first table wrap
# — the slot for a row that must sit UNDER the From/To date controls (report.js
# inserts those before the first h2/tablewrap, and hoists its anchor back over
# a "p.tabs.undertabs" row, so the order comes out controls -> row -> table).
# The Failed Subscriptions view switches use this.
_inject_before_table() {
    local f=$1 frag=$2 tmp; [ -f "$f" ] || return 0
    tmp=$(mktemp "${TMPDIR:-/tmp}/inj.XXXXXX")
    awk -v frag="$frag" '
        done                       { print; next }
        /<div class="tablewrap">/  { print frag; print; done = 1; next }
                                   { print }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# _hdr_with_nav HEADER NAVBLOCK — emit a report HEADER with the NAV line(s)
# placed DIRECTLY after its TITLE, so the rendered page reads
# <h1> -> tab bar(s) -> intro rather than <h1> -> intro -> tab bar(s).
# NAVBLOCK may hold several newline-separated NAV lines (the cross pages' two
# entity rows); a header with no TITLE gets them appended, so nothing is lost.
_hdr_with_nav() {
    printf '%s' "$1" | awk -F'\t' -v nav="$2" '
        BEGIN { n = split(nav, NV, "\n") }
        function emit(   i) { if (d) return; d = 1
                              for (i = 1; i <= n; i++) if (NV[i] != "") print NV[i] }
        { print; if ($1 == "TITLE") emit() }
        END { emit() }'
}
# apply_report_groups — THE FIRST ROW OF BUTTONS and the h1 group tag on
# every page of every _report_groups member (2026-09-29, user request: "have
# all reports in the same group link to each other with the first selection
# buttons"). One pass over the finished site, run by bin/build/publish.sh
# after every page writer (it replaced the three per-area tag_*_group_h1s and
# the analyses row injections): the row lists the group's members — the
# page's own member a highlighted span, the others links to their landing
# pages (rg_rel: relative from THIS page's directory, so a transfer page links
# ../server/… and ../analyses/…) — and lands DIRECTLY under the </h1>, above
# the report's own tab / view rows; the tag " ← Group" goes inside the h1.
# A member's pages are <dir>/<stem>.html and <dir>/<stem>-*.html, a longer
# member stem in the same directory winning; the Entities pages get the tag
# only (their native members | views row carries the view across members), a
# one-member group gets no row. Idempotent: a page already carrying a
# grouptag is left alone (a re-run of bin/build/publish.sh alone).
apply_report_groups() {
    local q line glabel rest allstems=" " e m dir stem f b s st best page row tag i j n k sline sm sfx tgt mj
    local -a arr MP ML MLAND fam SUBOF SL_LBL SL_FIRST sarr
    q=$(mktemp "${TMPDIR:-/tmp}/axrg.XXXXXX")
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS='|' read -r -a arr <<< "${line#*|}"
        for e in "${arr[@]}"; do allstems+="${e%%=*} "; done
    done < <(_report_groups)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        glabel=${line%%|*}
        IFS='|' read -r -a arr <<< "${line#*|}"
        n=${#arr[@]}; MP=(); ML=(); MLAND=()
        for ((i = 0; i < n; i++)); do
            e=${arr[$i]}; MP[$i]=${e%%=*}; ML[$i]=${e#*=}
            rg_landing "${MP[$i]}"; MLAND[$i]=$RG_LANDING
        done
        # this group's SUB-ROWS (_report_subrows): SUBOF[j] = the sub-row
        # member j belongs to (-1: none), SL_FIRST[k] = its first member in
        # group order — where the sub-row's one entry sits in the first row
        SUBOF=(); SL_LBL=(); SL_FIRST=(); k=0
        for ((j = 0; j < n; j++)); do SUBOF[$j]=-1; done
        while IFS= read -r sline; do
            [ "${sline%%|*}" = "$glabel" ] || continue
            IFS='|' read -r -a sarr <<< "${sline#*|}"
            SL_LBL[$k]=${sarr[0]}; SL_FIRST[$k]=-1
            for sm in "${sarr[@]:1}"; do
                for ((j = 0; j < n; j++)); do [ "${MP[$j]}" = "$sm" ] && SUBOF[$j]=$k; done
            done
            k=$((k + 1))
        done < <(_report_subrows)
        for ((j = 0; j < n; j++)); do
            k=${SUBOF[$j]}
            [ "$k" -ge 0 ] && [ "${SL_FIRST[$k]}" -lt 0 ] && SL_FIRST[$k]=$j
        done
        esc "$glabel"; tag=" <span class=\"grouptag\">&larr; $ESC</span>"
        for ((i = 0; i < n; i++)); do
            m=${MP[$i]}; dir=${m%/*}; stem=${m##*/}; fam=()
            case $dir in
                transfer/entities) for f in "$DOCS/$dir/$stem"-*.html; do [ -f "$f" ] && fam+=("$f"); done ;;
                analyses/xref)     for f in "$DOCS/$dir/cross"-*.html; do [ -f "$f" ] && fam+=("$f"); done ;;
                transfer/month-stats) for f in "$DOCS/$dir"/*.html; do [ -f "$f" ] && fam+=("$f"); done ;;   # this-* AND previous-*
                *)  for f in "$DOCS/$dir/$stem.html" "$DOCS/$dir/$stem"-*.html; do
                        [ -f "$f" ] || continue
                        b=${f##*/}; b=${b%.html}; best=""
                        for s in $allstems; do
                            [ "${s%/*}" = "$dir" ] || continue
                            st=${s##*/}
                            if [ "$b" = "$st" ] || [ "${b#"$st"-}" != "$b" ]; then
                                [ ${#st} -gt ${#best} ] && best=$st
                            fi
                        done
                        [ "$best" = "$stem" ] && fam+=("$f")
                    done ;;
            esac
            for f in ${fam[@]+"${fam[@]}"}; do
                page=${f#"$DOCS/"}; row=""
                # THE VIEW CARRY (2026-09-30, user request: switching between
                # Partners in and Partners Out "must keep the active second
                # selection"): a page <stem>-<view>.html links a sibling member
                # at ITS <stem>-<view>.html when that page exists (partners-in-
                # accounts <-> partners-out-accounts), else at its landing page;
                # the special families (entities, xref, month stats) never carry
                sfx=""
                case $dir in transfer/entities|analyses/xref|transfer/month-stats) ;; *)
                    b=${f##*/}; b=${b%.html}
                    [ "${b#"$stem"-}" != "$b" ] && sfx=-${b#"$stem"-} ;;
                esac
                if [ "$glabel" != Entities ] && [ "$n" -gt 1 ]; then
                    row='<p class="tabs">'
                    for ((j = 0; j < n; j++)); do
                        k=${SUBOF[$j]}
                        if [ "$k" -ge 0 ]; then
                            # a sub-row: ONE entry, at its first member
                            [ "${SL_FIRST[$k]}" = "$j" ] || continue
                            esc "${SL_LBL[$k]}"
                            if [ "${SUBOF[$i]}" = "$k" ]; then row+="<span class=\"tab active\">$ESC</span>"
                            else rg_rel "$page" "${MLAND[$j]}"; row+="<a class=\"tab\" href=\"$RG_REL\">$ESC</a>"; fi
                            continue
                        fi
                        esc "${ML[$j]}"
                        if [ "$j" = "$i" ]; then row+="<span class=\"tab active\">$ESC</span>"
                        else
                            tgt=${MLAND[$j]}; mj=${MP[$j]}
                            if [ -n "$sfx" ]; then
                                case ${mj%/*} in transfer/entities|analyses/xref|transfer/month-stats) ;; *)
                                    [ -f "$DOCS/$mj$sfx.html" ] && tgt="$mj$sfx.html" ;;
                                esac
                            fi
                            rg_rel "$page" "$tgt"; row+="<a class=\"tab\" href=\"$RG_REL\">$ESC</a>"
                        fi
                    done
                    row+='</p>'
                    # a sub-row member's page: the SECOND row, its sub-row's
                    # members (no newline — the queue is one line per page)
                    k=${SUBOF[$i]}
                    if [ "$k" -ge 0 ]; then
                        row+='<p class="tabs">'
                        for ((j = 0; j < n; j++)); do
                            [ "${SUBOF[$j]}" = "$k" ] || continue
                            esc "${ML[$j]}"
                            if [ "$j" = "$i" ]; then row+="<span class=\"tab active\">$ESC</span>"
                            else rg_rel "$page" "${MLAND[$j]}"; row+="<a class=\"tab\" href=\"$RG_REL\">$ESC</a>"; fi
                        done
                        row+='</p>'
                    fi
                fi
                printf '%s\t%s\t%s\n' "$f" "$tag" "$row" >> "$q"
            done
        done
    done < <(_report_groups)
    # ONE perl for the whole queue: the tag in front of the first </h1>, the
    # row on its own line right after the line that closes the h1
    perl -e '
        while (my $l = <STDIN>) {
            chomp $l; my ($f, $tag, $row) = split /\t/, $l, 3;
            open(my $h, "<", $f) or next; my $c = do { local $/; <$h> }; close $h;
            next if index($c, q{class="grouptag"}) >= 0;
            my $p = index($c, "</h1>"); next if $p < 0;
            my $nl = index($c, "\n", $p); $nl = length($c) if $nl < 0;
            my $n = substr($c, 0, $p) . $tag . substr($c, $p, $nl - $p) . "\n";
            $n .= $row . "\n" if length $row;
            $n .= substr($c, $nl + 1) if $nl + 1 <= length($c);
            $n .= "\n" if length($n) && substr($n, -1) ne "\n";
            open(my $o, ">", $f) or die "rows: $f: $!"; print $o $n; close $o or die "rows: $f: $!";
        }' < "$q"
    rm -f "$q"
}
# (The graphical dashboard — bin/dashboards/publish.sh, ONE page since
# 2026-07 — is a plain top-bar link (assets/topbar.js); the former
# DASHBOARD_MENU dropdown is gone.)
# The RUNTIME top bar's menu-data version (the ?v= stamp html_head puts on
# assets/topbar-data.js): changes exactly when the menu content does, so a
# MENU change needs only a re-publish of the data file — no page re-render.
# (The "has a Monitor dashboard" flag TB_MON — topbar-data.js `monitor` —
# went 2026-09-30 with that dashboard, user request.)
# The CoreId -> SecureTransport File Tracking URL template (2026-09-07, user
# request): input/coreid-url.txt, ONE line carrying @COREID@ where the id goes
# (comment and blank lines skipped) — hand-maintained per checkout; a runtime
# repo carries the real admin host, develop's sample an .example one. Baked
# into topbar-data.js (report.js addCoreIdLinks wraps every id on a page with
# it; a checkout without the file gets an empty template and no links) and
# folded into TB_VER so a URL change re-stamps the data file's ?v=. So is the
# ENVIRONMENT LABEL (bin/envlabel.sh), which the bar shows as a static span.
_coreid_url() { [ -f "$1" ] && awk '/^[ \t]*#/ || /^[ \t]*$/ { next } { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print; exit }' "$1" || true; }
TB_CID=$(_coreid_url input/coreid-url.txt)
# THE ENVIRONMENT SWITCH (2026-09-12, user request — back after the 2026-09-11
# env split retired the data-twin crosslink): a RUNTIME checkout's top bar
# leads with "Acceptance / Production" — the ACTIVE one bold and yellow, its
# link the home page; the OTHER one the SAME PAGE on the other site, which
# must serve its own 404 when the page is not there (GitHub Pages: docs/
# 404.html). The other site's host differs per viewer, so the hrefs are
# computed in the browser (never baked): on localhost the local checkouts,
# anywhere else the GitHub Pages sites. ENV_SITES_JS holds the four URLs,
# shipped as topbar-data.js `sites`; assets/topbar.js (envLinks — the ONE
# implementation since 2026-09-30, a baked ENVSWITCH_JS string before) fills
# every a[data-envto] from its data-root (the page's docs-root prefix). The
# develop/sample checkout keeps its single "Sample" brand link.
# FROM THE FILE SYSTEM (location.protocol file:, 2026-09-14, user request)
# there is no other site to switch to: topbar.js REMOVES the other
# environment's link and the separator, so only the current environment
# shows — its link the home page (the page-relative index.html, which works
# from disk too).
ENV_SITES_JS='{local:{acceptance:"http://localhost/acceptance/",production:"http://localhost/production/"},remote:{acceptance:"https://probable-adventure-l6y6k83.pages.github.io/",production:"https://expert-adventure-9myme9m.pages.github.io/"}}'
# (THE DATA PERIOD in the top bar — "yyyy-mm-dd / yyyy-mm-dd" from the day
# report's META first/last, topbar-data.js `period`, 2026-09-13 — went
# 2026-09-30, user request: "remove 2026-08-31 / 2026-09-30".)
TB_VER=$(printf '%s' "$REPORTS_MENU$ERRORS_HREF$OVERVIEW_HREF$TB_CID${ENV_LABEL:-}${ENV_KEY:-}$ENV_SITES_JS" | cksum | cut -d' ' -f1)

# Copy the shared assets into docs/ and write .nojekyll. Idempotent, so each
# publish script can call it and still produce a valid site when run on its own.
# (redirect_html was REMOVED 2026-07 with every redirect stub — renamed or
# moved pages no longer keep their old URLs alive; they 404.)

ensure_assets() {
    # the assets and .nojekyll live at the docs ROOT (docs/assets/); every
    # publish writes the same bytes, so writing them is idempotent.
    # style.css / topbar.js / report.js / slotchart.js / all-files-search.js / sub-files.js and docs/help/
    # are SEEDED from the repo-root assets/ by bin/build.sh (2026-08-29 —
    # every build clears the docs tree first, so docs/ is pure build
    # output; EDIT IN assets/, a build overwrites the docs copies). Only the
    # GENERATED files below and .nojekyll are written here.
    mkdir -p docs/assets
    # ATOMIC writes (2026-07): publishes run CONCURRENTLY (the report and
    # detail pages beside each other), so two processes write these same
    # bytes at the same time. Same content
    # either way, but a plain redirect truncates first: a reader (or the other
    # writer) can catch an empty file. tmp + mv makes each swap atomic.
    _asset_put() {   # $1 target  $2 content (a trailing newline is appended)
        local _tmp; _tmp=$(mktemp "${1}.XXXXXX") || return 1
        # chmod: mktemp creates 0600 and mv preserves it — fine for Pages (git
        # stores 100644) but a local httpd running as ANOTHER user 403s the
        # asset and every dropdown goes empty in preview
        printf '%s\n' "$2" > "$_tmp" && chmod 644 "$_tmp" && mv -f "$_tmp" "$1"
    }
    # (build-stamp.js is GONE with the footer bar: no page shows a build time
    # any more, so there is nothing to stamp.)
    # The runtime top bar's menu data (assets/topbar.js): the ONE
    # Reports pulldown string (2026-09-29: the transfer / server / analyses /
    # goodies keys went with their four dropdowns), docs-root-relative with
    # its "@" placeholder kept verbatim (topbar.js swaps it for the page's
    # data-b prefix).
    local r=$REPORTS_MENU
    r=${r//\\/\\\\}; r=${r//\"/\\\"}
    # + the CoreId -> File Tracking URL template (TB_CID) and the environment
    # label (ENV_LABEL), both baked as plain strings
    local c=${TB_CID:-} e=${ENV_LABEL:-} k=${ENV_KEY:-}
    c=${c//\\/\\\\}; c=${c//\"/\\\"}
    e=${e//\\/\\\\}; e=${e//\"/\\\"}
    k=${k//\\/\\\\}; k=${k//\"/\\\"}
    # + envkey (topbar.js renders the Acceptance / Production pair for the
    # two runtime keys) and the switch's four site URLs (`sites`,
    # ENV_SITES_JS — a JS object literal, baked verbatim)
    # + errors: the top bar's Errors link (ERRORS_HREF, docs-root-relative —
    # a plain page path, nothing to escape)
    local _tb; printf -v _tb 'window.AXWAY_TB={reports:"%s",errors:"%s",overview:"%s",coreid:"%s",env:"%s",envkey:"%s",sites:%s};' "$r" "${ERRORS_HREF:-}" "${OVERVIEW_HREF:-}" "$c" "$e" "$k" "$ENV_SITES_JS"
    _asset_put docs/assets/topbar-data.js "$_tb"
    [ -f docs/.nojekyll ] || : > docs/.nojekyll
}
