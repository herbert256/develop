#!/usr/bin/env bash
#
# publish_lib.sh — shared machinery for the three publish scripts:
#
#   bin/transfer/publish.sh   renders the transfer report pages + detail pages
#   bin/server/publish.sh     renders the server report pages
#   bin/build/publish.sh            writes the three index pages (root + per area)
#
# Source this (it is not executable on its own). It cd's to the repo root, then
# computes the shared globals (report order, dates, dataset figures, top-bar menus)
# and defines every rendering helper the publish scripts use. The report scripts
# own aggregation and write .rpt descriptors; this owns ALL html/css — generated
# pages contain no <style> and no inline style=.
#
# A report whose .rpt contains more than one table is split into one HTML page
# per table (docs/<area>/<name>-<slug>.html), each carrying a tab bar linking to
# its siblings; the index lists one line per report with a bracketed link per
# table. Single-table reports render to docs/<area>/<name>.html.
#
set -euo pipefail
# This lib lives in bin/; operate from the repo root (its parent) so all the
# relative paths below (docs/, assets/, data/<area>/reports, data/<area>/cache)
# resolve — regardless of which publish script sourced us (BASH_SOURCE points here).
cd "$(dirname "${BASH_SOURCE[0]}")/.."

source bin/skiplist.sh    # SKIPLIST_FILE  — input/skip.txt (the ONE skip list)
source bin/fastawk.sh   # route unqualified `awk` to mawk when installed (see bin/fastawk.sh)
source bin/env.sh       # resolve $AXWAY_ENV (acceptance|production, default acceptance)

# The active ENVIRONMENT: every publish run renders ONE env's site tree
# (docs/<env>/…) from that env's data tree (data/<env>/…). The shared root
# artifacts — docs/assets/, docs/help/, docs/index.html — live
# at the docs root; html_head derives the extra ../ from SITE_ENV. The root
# home page writer (bin/build/publish.sh write_root_index) temporarily clears
# SITE_ENV to render the one shared page.
SITE_ENV="$AXWAY_ENV"
DOCS="docs/$SITE_ENV"
DATA="data/$SITE_ENV"
CSS_SRC="docs/assets/style.css"   # hand-authored + published in ONE place (see ensure_assets)
# The FlowManager config exports every raw-JSON reader (the
# accounts / cronjobs insight pages, publish-insights.sh) should read: the
# SKIP-filtered copies bin/flow-manager.sh writes (input/skip.txt) when they
# exist, else the raw exports. (Repo-root-relative — publish_lib.sh cd's to ROOT.)
FM_CONFIG_DIR="input/$SITE_ENV/flow-manager"
[ -f "$DATA/flow-manager/filtered/partners.json" ] && FM_CONFIG_DIR="$DATA/flow-manager/filtered"

# Build timestamp shown at the right of the footer bar on every page. Computed
# once when this library is sourced, so all pages of one publish run share it;
# honours an inherited GENERATED_AT (bin/build.sh exports one) so the whole site —
# rendered by three separate publish processes — carries a single stamp.
GENERATED_AT="${GENERATED_AT:-$(date '+%Y-%m-%d %H:%M')}"

# Cache-buster for the two shared assets: a content checksum appended as ?v=…
# to every stylesheet/script link html_head emits, so a browser (or the Pages
# CDN) never serves a stale style.css/report.js against freshly published HTML.
# Content-derived (not the build timestamp), so an assets-unchanged rebuild
# keeps the same URL and the cache stays warm.
ASSET_VER=$( (cksum docs/assets/style.css docs/assets/report.js docs/assets/slotchart.js docs/assets/file-search.js 2>/dev/null || true) | cksum | cut -d' ' -f1 )

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
pub_reap() {
    local running p st keep=()
    running=" $(jobs -rp | tr '\n' ' ') "
    for p in ${PUB_PIDS[@]+"${PUB_PIDS[@]}"}; do
        case $running in
            *" $p "*) keep+=("$p") ;;
            *) st=0; wait "$p" || st=$?
               [ "$st" -ne 0 ] && PUB_RC=$st ;;
        esac
    done
    PUB_PIDS=(${keep[@]+"${keep[@]}"})
}
pub_run() {    # run "$@" as a background job, at most PUB_NJOBS at once
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PUB_NJOBS" ]; do sleep 0.05; done
    pub_reap
    "$@" &
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

# ---- publish freshness ------------------------------------------------------
# Rendering is the most expensive stage of a no-change build: every publish
# CLEARS its output dir and re-renders every page, so a build with nothing new
# still costs a minute and a half of step time. Each publish now drops a STAMP
# file when it finishes and skips itself next time when nothing it reads is
# newer than that stamp.
#
# What "reads" means here is the whole point — a page bakes in far more than
# its own .rpt, so the deps are:
#   * the publish script itself and everything in PUBLISH_CORE_DEPS below
#     (the renderer, this library, the awk shim, and the three HAND-AUTHORED
#     assets whose cksum is baked into every page as ?v=$ASSET_VER — an edit to
#     style.css must re-stamp all pages, which is exactly what ASSET_VER is);
#   * the .rpt / cache trees the caller names.
# The GENERATED asset topbar-data.js is deliberately NOT a dep: ensure_assets
# rewrites it every run, which would make every stamp stale forever. Its effect
# on a page is already covered by TB_VER (a cksum of the menus, which live in
# this library). (build-stamp.js was the other one; it went with the footer bar.)
#
# Deliberately NEVER a dep: a generated page under docs/. bin/build/crosslink.sh
# rewrites ~2700 of them at the end of every build to stamp the env-switch
# twins, so any docs-based dep would re-trigger every publish on the next run.
# The output DIRECTORY is checked for existence instead, so a hand-deleted tree
# is still rebuilt.
#
# AXWAY_FORCE_PUBLISH=1 re-renders everything regardless (as does deleting
# data/<env>/.publish/). NOTE the same second-granularity caveat the report
# guards have under bash 3.2: an input written in the SAME second as the stamp
# reads as "not newer".
PUBLISH_STAMP_DIR="$DATA/.publish"
PUBLISH_CORE_DEPS="bin/publish_lib.sh bin/render_rpt.awk bin/env.sh bin/fastawk.sh \
                   bin/uc-cases.sh docs/assets/style.css docs/assets/report.js docs/assets/slotchart.js"

# The dep list publish_is_fresh was last called with, so publish_stamp can
# record the same set without every caller repeating it.
PUBLISH_DEPS="$PUBLISH_CORE_DEPS"

# publish_dep_files — the count of regular files across the dep dirs. It is
# stored IN the stamp and re-checked, because the -newer test below only looks
# at FILES: a directory's own mtime is useless as a signal (every cmp-guarded
# writer in this repo creates and removes a .tmp beside its output, which bumps
# the dir mtime on a run that changed nothing — that alone kept every publish
# rebuilding). Files-only -newer catches every add and edit; the count catches
# a REMOVAL, which has no mtime of its own.
publish_dep_files() {
    local dep n=0
    for dep in $PUBLISH_DEPS; do
        [ -d "$dep" ] || continue
        n=$(( n + $(find "$dep" -type f 2>/dev/null | wc -l) ))
    done
    printf '%s\n' "$n"
}

# publish_is_fresh STAMP OUTDIR DEP... — true (0) when STAMP exists, OUTDIR
# exists, and nothing in PUBLISH_CORE_DEPS or DEP... has been added, edited or
# removed since STAMP. A DEP may be a file or a directory tree.
publish_is_fresh() {
    local stamp=$1 outdir=$2; shift 2
    PUBLISH_DEPS="$PUBLISH_CORE_DEPS $*"
    [ -z "${AXWAY_FORCE_PUBLISH:-}" ] || return 1
    [ -f "$stamp" ] || return 1
    [ -d "$outdir" ] || return 1
    # AXWAY_DEBUG_FRESH=1 names the dep that forced the rebuild — the only
    # practical way to chase down a publish that will not settle.
    local dep hit
    for dep in $PUBLISH_DEPS; do
        if [ -d "$dep" ]; then
            hit=$(find "$dep" -type f -newer "$stamp" -print -quit 2>/dev/null)
            if [ -n "$hit" ]; then
                [ -z "${AXWAY_DEBUG_FRESH:-}" ] || echo "  fresh? $stamp: NEWER $hit" >&2
                return 1
            fi
        elif [ -f "$dep" ] && [ "$dep" -nt "$stamp" ]; then
            [ -z "${AXWAY_DEBUG_FRESH:-}" ] || echo "  fresh? $stamp: NEWER $dep" >&2
            return 1
        fi
    done
    if [ "$(cat "$stamp" 2>/dev/null)" != "$(publish_stamp_value)" ]; then    # deletion, or a scope switch
        [ -z "${AXWAY_DEBUG_FRESH:-}" ] || echo "  fresh? $stamp: file count changed" >&2
        return 1
    fi
    return 0
}

# publish_stamp STAMP — record a completed publish. Call it LAST, after every
# page is written, so an interrupted run leaves the old (older) stamp and the
# next run redoes the work.
# What a stamp RECORDS: the dep-tree file COUNT, because a deletion has no mtime
# of its own. It briefly also carried the build-report href, back when the footer
# baked the scope — that made every scope switch re-render all 2372 pages. The
# href is resolved at runtime now, so the stamp is scope-free again.
# PUBLISH_STAMP_EXTRA lets a SINGLE publish add something to its own freshness
# signal. Only bin/build/publish.sh uses it, for the build SCOPE: its sitemap
# bakes the build-report link, so a scope switch must re-render that one page.
# Deliberately opt-in — putting the scope in EVERY stamp is what made a switch
# re-render all 2372 pages (31 s against 9 s).
publish_stamp_value() { printf '%s%s\n' "$(publish_dep_files)" "${PUBLISH_STAMP_EXTRA:+ $PUBLISH_STAMP_EXTRA}"; }
publish_stamp() { mkdir -p "$(dirname "$1")" && publish_stamp_value > "$1"; }

# publish_area_stamps — the per-AREA publish stamps of BOTH envs: the "did any
# page get re-rendered" signal for the three cross-cutting steps that run after
# the area publishes (the index pages, acc-vs-prod, crosslink), each of which
# writes into a dir the area publishes clear.
# Emitted as FILES, never as the .publish DIR: that dir also holds those three
# steps' OWN stamps, and they are written one after another — so a dir dep made
# each step invalidate the one before it on every single run.
publish_area_stamps() {
    local env area
    for env in acceptance production; do
        for area in transfer details server analyses dashboards day partner-groups; do
            printf '%s\n' "data/$env/.publish/$area.stamp"
        done
    done
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
    if [ -f "$dr" ]; then
        grep "^ROW"$'\t' "$dr" | cut -f2 | sed 's/^@{[^}]*}//' | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u | tr '\n' ',' | sed 's/,$//' || true
    else
        grep -hv '^FOOT' "$1"/data/*.rpt 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u | tr '\n' ',' | sed 's/,$//' || true
    fi
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
transfer_order=(topview subscription account login remote-host logical partner application domain bl entity-search file-journey file-in-file-out activity punctuality expected-arrival cross-account cross-login cross-subscription cross-host cross-logical cross-partner cross-application cross-domain cross-bl seen-in-server-log entity-coverage entity-coverage-once entity-coverage-ok entity-coverage-diff sources-and-targets skipped not-in-flow-manager volume files top-transfers route-throughput size-profile ranking failed failure-rate episodes recovered recovered-files from-green-to-red only-red waiting expired missing-cronjobs retries pirates went-quiet failure-heatmap protocol security-params security-outreach av-scan connection-efficiency anomalies duration duration-all duration-minmax duration-all-minmax dwell-time duration-trend account-sharing twins)
server_order=(topview errors failure-flows pickups uc-status uc2-visits went-kaput site-failures logons connections ssh-security platform-health capacity deploy-errors remote-poll transfer-site-missing no-remote-dir no-remote-files missing-entities)

# ---- the analyses-housed area reports ---------------------------------------
# FOUR reports whose DATA belongs to the transfer / server areas — they read
# those caches, their scripts run in those orchestrators and their .rpt still
# land in data/<env>/{transfer,server}/reports/ — but whose PAGES live in
# docs/<env>/analyses/ (all four are Configuration-group members there).
# Same idea as the cross-* pages, one level
# shallower: docs/<env>/analyses/ is the same depth as transfer/ and server/,
# so the css/home/detail-link prefixes are unchanged and only the directory
# moves. Being here means: NO area group (group_of returns ""), NO area menu
# entry, NO area index/sitemap card — they get the analyses group tab bar via
# analyses_grouprow_for instead. Their scripts live in bin/analyses/reports/.
#
# OWNERSHIP: bin/analyses/publish.sh renders them, NOT the area publishes —
# it clears docs/<env>/analyses/*.html and runs AFTER both, so a page written
# there by the transfer/server loop would be deleted again.
SUBS_GROUP_REPORTS=" transfer:failed analyses:failing-reasons server:uc-status server:uc2-visits transfer:account-sharing transfer:twins analyses:triage analyses:data-diff analyses:partner-scorecard analyses:blast-radius analyses:app-partners analyses:partner-lifecycle analyses:cleanup-backlog "

is_subs_report() {   # $1 report basename -> 0 when its pages live in analyses/
    case $SUBS_GROUP_REPORTS in *:"$1 "*) return 0 ;; esac
    return 1
}

# ---- the boxes-only reports (2026-07) ---------------------------------------
# The ELEVEN reports whose only navigation is the two Boxes pages: every one is
# linked from a box's explanation text on Subscriptions/Accounts in boxes, so
# they are dropped from the area dropdowns, the area index pages, the sitemap
# area cards and the group tab bars (group_of returns "" — their pages carry NO
# group row). Their PAGES STAY at the area URLs (docs/<env>/transfer/… and
# server/… — the boxes texts, the day-page problem lists and the cell links all
# point there), their scripts stay in the area orchestrators, and the sitemap
# lists them under the Boxes card; the report finder labels them Analyses.
# Names are unique across the two areas, so one flat list suffices.
BOXES_ONLY_REPORTS=" pirates from-green-to-red only-red waiting expired went-quiet missing-cronjobs went-kaput site-failures deploy-errors no-remote-dir no-remote-files "

# The 2026-07 MERGED-report components: their .rpt files stay on disk (they
# feed the merged reports and every other consumer) but they have NO page of
# their own — whats-new must not link them. ranking and double are retired
# outright; the four uc<n>-status merged into uc-status.
MERGED_COMPONENT_REPORTS=" day weekly hourly weekday retry attempts resubmissions patterns legs-count protocol-journey arrived-left errors-day error-timing error-reasons top-messages unknown-sites unknown-accounts unknown-hosts unknown-whitelisting unknown-logins inbound-connections connection-diagnostics logon auth-activity ssh-key-auth cluster-health stuck-events scheduler-overruns pesit file-cleanup ssh-crypto ssh-sessions uc1-status uc2-status uc3-status uc4-status double stale-accounts trend size-dist file-type duplicate-files "
is_merged_component() {
    case $MERGED_COMPONENT_REPORTS in *" $1 "*) return 0 ;; esac
    return 1
}
is_boxes_only() {   # $1 report basename -> 0 when only the Boxes pages link it
    case $BOXES_ONLY_REPORTS in *" $1 "*) return 0 ;; esac
    return 1
}
subs_report_area() {   # $1 report basename -> the area its .rpt lives in ("" if not a member)
    local spec
    for spec in $SUBS_GROUP_REPORTS; do
        [ "${spec#*:}" = "$1" ] && { printf '%s' "${spec%%:*}"; return 0; }
    done
    return 1
}

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
        account|login|subscription|remote-host|logical|partner|application|domain|bl) echo "All|Seen|Not seen|OK|Warning|Error|Server" ;;   # Entities group (pages under docs/<area>/entities/; default = All via first_page). Every view is listed so member-row links resolve to the same view (member_page_for_label) — Server included, though it is offered only in the +Server scope; the SCOPE (Transfer | +Server, a third tab group) rides on the filename suffix, added by render_entity_report.
        cross-account)      cross_tabs "Login|Subscriptions|Hosts|Logical|Partners|Applications|Domains|BL" ;;
        cross-login)        cross_tabs "Account|Subscriptions|Hosts|Logical|Partners|Applications|Domains|BL" ;;
        cross-subscription) cross_tabs "Account|Login|Hosts|Logical|Partners|Applications|Domains|BL" ;;
        cross-host)         cross_tabs "Account|Login|Subscriptions|Logical|Partners|Applications|Domains|BL" ;;
        cross-logical)      cross_tabs "Account|Login|Subscriptions|Hosts|Partners|Applications|Domains|BL" ;;
        cross-partner)      cross_tabs "Account|Login|Subscriptions|Hosts|Logical|Applications|Domains|BL" ;;
        cross-application)  cross_tabs "Account|Login|Subscriptions|Hosts|Logical|Partners|Domains|BL" ;;
        cross-domain)       cross_tabs "Account|Login|Subscriptions|Hosts|Logical|Partners|Applications|BL" ;;
        cross-bl)           cross_tabs "Account|Login|Subscriptions|Hosts|Logical|Partners|Applications|Domains" ;;
        volume)        echo "Per day|By direction|Top accounts|Went silent|Growers|Shrinkers" ;;   # 2026-07 Tier 3: + trend
        files)         echo "By size|Empty files|By type|Duplicates" ;;
        went-quiet)    echo "Subscriptions|Accounts" ;;   # 2026-07 Tier 3: + stale-accounts
        # ---- the 2026-07 MERGED reports: one tab per component TABLE, in
        # component order — the tab count MUST equal the merged rpt's TABLE count
        activity)      echo "Per day|Per week|Per hour|Hour × weekday|Per weekday" ;;
        retries)       echo "Failing flows|Legs before success|Gave up|Retry spacing|Failing side|Resubmitted per day|Per subscription|Resubmission outcomes" ;;   # 2026-08: + the server-log outcome table (resubmissions component table 3)
        file-journey)  echo "Patterns|Leg count|Most legs|Protocol journey|Last leg|In and out" ;;
        errors)        echo "Per day|Per component|By hour|By weekday|Heatmap|Reasons|Top messages" ;;
        missing-entities) echo "Subscriptions|Accounts|Hosts|Whitelist|Logins" ;;
        connections)   echo "By protocol|Per day|By account|By address|Whitelist usage|Failure reasons|By remote host|Test connections|Host keys|Test outcomes" ;;   # 2026-08: + connection-diagnostics tables 4-5
        logons)        echo "Incoming|Outgoing|Near misses|Scanners|By account|By source IP|Certificates|Key mismatches|Lockouts|Outbound key failures" ;;   # 2026-08: + the door-knocker tables (logon component tables 3-4)
        capacity)      echo "PeSIT per day|PeSIT problems|Problem types|Diagnostic codes|FPDU ledger|Local deletes|Remote deletes|Maintenance" ;;   # 2026-08: + the outbound FPDU ledger (pesit component table 5)
        uc-status)     echo "UC1|UC2|UC3|UC4" ;;
        failure-rate)  echo "Accounts|Subscriptions|Days" ;;
        protocol)      echo "Protocol|Direction|Crosstab|Action By|Direction x Action|Mode" ;;   # the 2026-07 merge: + direction-action's Action By/Crosstab tables + the Mode split
        av-scan)       echo "Breakdown|Per day|Per protocol|Blocked|Not performed|Not first inbound" ;;
        security-params) echo "TLS version|Cipher|Cipher suite|MAC|Key Exchange|Public Key" ;;   # 2026-08: one tab per attribute; the report always emits all six tables (empty when absent) so the count matches in every env. Protocol table dropped — the protocol report owns it.
        ranking)       echo "Subscriptions|Accounts|Logins|Hosts|Logical|Partners|Applications|Domains|BL" ;;   # the 9 entity types, in ranking.sh's SPECS order
        # (anomalies had "Hourly|Daily" until 2026-08 — the two granularities
        # now share ONE page, Daily first, so the report is not split)
        pirates)       echo "Details|Top view" ;;   # the single-leg list + the count per day
        entity-coverage|entity-coverage-ok|entity-coverage-once|entity-coverage-diff) echo "Accounts|Logical|Partners|Domains|Applications|BL" ;;   # one coverage table per entity; Accounts is the default (first_page). The RULE is a third row, riding on the basename like duration/duration-all.
        *)             echo "" ;;
    esac
}

# ---- report groups ----------------------------------------------------------
# Several reports are grouped under one index line, with a top row of tabs that
# switches between the grouped reports (and, for multi-table reports, a second
# row for that report's tables). group_members lists members in tab order;
# member_label is the row-1 button text; group_label/group_desc feed the index.
group_members() {
    case $1 in
        topview)             echo "topview" ;;
        entity-search)       echo "entity-search" ;;
        time)                echo "activity punctuality expected-arrival" ;;   # 2026-07: day/weekly/hourly/weekday merged into activity; 2026-08: + expected-arrival
        account-login-site)  echo "subscription logical partner account login remote-host domain application bl" ;;
        volume-files)        echo "volume files top-transfers route-throughput size-profile ranking" ;;   # ranking retired 2026-07; 2026-08: + route-throughput/size-profile
        failures)            echo "failure-rate episodes retries recovered recovered-files failure-heatmap" ;;   # from-green-to-red/only-red/waiting/expired/pirates/went-quiet are boxes-only (BOXES_ONLY_REPORTS); 2026-08: + recovered (the good-news mirror) + recovered-files (the per-File Recovered analysis)
        flow-shape)          echo "file-journey file-in-file-out" ;;   # 2026-07: patterns/arrived-left/legs-count/protocol-journey merged into file-journey; attempts/resubmissions into retries
        protocol-security)   echo "protocol security-params security-outreach av-scan connection-efficiency" ;;   # 2026-08: + security-outreach/connection-efficiency
        performance-session) echo "anomalies duration dwell-time duration-trend" ;;   # 2026-08: + duration-trend
        cross)               echo "cross-account cross-login cross-subscription cross-host cross-logical cross-partner cross-application cross-domain cross-bl" ;;
        srv-overview)        echo "topview" ;;
        srv-errors)          echo "errors failure-flows" ;;      # 2026-07: errors-day/error-timing/error-reasons/top-messages merged; 2026-08: + failure-flows (per-flow reason matrix)
        srv-transfers)       echo "pickups" ;;   # transfer-outcomes + file-freshness went with the dropped JSON bookend lines (2026-08)
        srv-connections)     echo "logons connections" ;;        # 2026-07 merges (logons leads since 2026-08); site-failures is boxes-only
        srv-security)        echo "ssh-security" ;;              # 2026-07: ssh-crypto + ssh-sessions merged
        srv-ops)             echo "platform-health capacity" ;;  # 2026-07: the seven ops reports merged into two
        srv-routing)         echo "remote-poll transfer-site-missing" ;;   # advanced-routing REMOVED 2026-08 (its AR0011/76/77 lines are noise-filtered); deploy-errors/no-remote-dir/no-remote-files are boxes-only
        srv-missing)         echo "missing-entities" ;;          # 2026-07: the five unknown-* merged (one script all along)
    esac
}
group_of() {   # $1 area (transfer|server)  $2 report basename -> group id (empty if ungrouped)
    case $2 in
        topview)             if [ "$1" = server ]; then echo "srv-overview"; else echo "topview"; fi ;;   # both areas have a topview report
        entity-search)       echo "entity-search" ;;
        activity|punctuality|expected-arrival)   echo "time" ;;
        account|login|subscription|remote-host|logical|partner|application|domain|bl) echo "account-login-site" ;;
        volume|files|top-transfers|route-throughput|size-profile|ranking) echo "volume-files" ;;
        failure-rate|episodes|retries|recovered|recovered-files|failure-heatmap) echo "failures" ;;   # missing-cronjobs is NOT here (boxes-only); the boxes-only reports return "" so their pages carry NO group row
        file-journey|file-in-file-out) echo "flow-shape" ;;
        protocol|security-params|security-outreach|av-scan|connection-efficiency) echo "protocol-security" ;;
        dwell-time|duration|duration-all|duration-minmax|duration-all-minmax|anomalies|duration-trend)     echo "performance-session" ;;   # the duration-* siblings: Duration's All-transfers / Percentage views (not group MEMBERS — they share Duration's slot)
        cross-account|cross-login|cross-subscription|cross-host|cross-logical|cross-partner|cross-application|cross-domain|cross-bl) echo "cross" ;;
                errors) echo "srv-errors" ;;
        failure-flows) echo "srv-errors" ;;
        pickups) echo "srv-transfers" ;;
        connections|logons) echo "srv-connections" ;;
        ssh-security) echo "srv-security" ;;
        platform-health|capacity) echo "srv-ops" ;;
        remote-poll|transfer-site-missing)  echo "srv-routing" ;;
        missing-entities) echo "srv-missing" ;;
        *)                                echo "" ;;
    esac
}
group_label() {
    case $1 in
        topview)             echo "Top view" ;;
        entity-search)       echo "Search" ;;
        time)                echo "Activity over Time" ;;
        account-login-site)  echo "Entities" ;;
        volume-files)        echo "Volume, Sizes & Files" ;;
        failures)            echo "Failures & Retries" ;;
        flow-shape)          echo "Patterns" ;;
        protocol-security)   echo "Protocol & Security" ;;
        performance-session) echo "Performance" ;;
        cross)               echo "Cross References" ;;
        srv-overview)        echo "Top view" ;;
        srv-errors)          echo "Errors" ;;
        srv-transfers)       echo "Transfers & Delivery" ;;
        srv-connections)     echo "Logons & Connections" ;;
        srv-security)        echo "Security" ;;
        srv-ops)             echo "Operations & Capacity" ;;
        srv-routing)         echo "Routing & Polling" ;;
        srv-missing)         echo "Missing Entities" ;;
    esac
}
group_desc() {
    case $1 in
        topview)             echo "The whole transfer log at a glance: per day, the Files and Transfers counts with their Ok/Error split and error rate, plus the Files by their final state (Processed/Failed/Waiting/Expired)." ;;
        entity-search)       echo "Search every account, subscription, login, remote host, logical flow, partner, application, domain and BL tag by name — with its Files count, Error/OK, and whether it appears in the server logs." ;;
        time)                echo "Files per calendar day, the week-over-week trend, and load by hour of day and day of week, plus each subscription's arrival punctuality — late files and missed expected days." ;;
        account-login-site)  echo "Files per subscription, logical flow, partner, account, login, remote host, domain, application and BL tag — each with a summary and per-day detail." ;;
        volume-files)        echo "Data volume per day and account, the size distribution (with the empty-but-OK deliveries), per-subscription growers and shrinkers, file types, the largest/slowest transfers, and every entity ranked by Files, Volume and Error rate." ;;
        failures)            echo "The last failed files, failure rate per account, destination subscription and day, failure episodes with their time to recovery, resubmissions, accounts gone quiet, and the day-by-hour failure heatmap." ;;
        flow-shape)          echo "The row/status shape of each File: patterns, arrival vs departure, legs per File, the protocol route, retry anatomy, the manually resubmitted legs, and the partner-to-partner handovers where a file arrives from one partner and the same filename leaves to another." ;;
        protocol-security)   echo "Transfers by protocol, direction, action-by and transfer mode (BINARY/ASCII) with crosstabs, the connection security parameters (ciphers, TLS versions), and the anti-virus scan outcomes." ;;
        performance-session) echo "Detected unusual hours and days (anomalies), how long transfers take end to end, and the store-and-forward wait inside SecureTransport." ;;
        cross)               echo "Which pairs of the nine entities belong together — green pairs appear in the transfer logs, red pairs are configured but never logged. Pick the first entity in the top row, the second below." ;;
        srv-overview)        echo "The server log at a glance: the wide per-day dashboard (records, level split, per-component activity)." ;;
        srv-errors)          echo "The error side of the server log: the Info/Warning/Error split per day and by hour/weekday, error reasons classified into failure buckets, and the most-repeated warn/error message shapes." ;;
        srv-transfers)       echo "The server's own view of the deliveries: which staged files the partners actually came to collect, and when." ;;
        srv-connections)     echo "The SSH logon screening (incoming funnel + outbound auth failures), successful authentication activity per account and source IP, the inbound connection volume per protocol/account/address, and connection diagnostics." ;;
        srv-security)        echo "The negotiated cipher/crypto posture with weak algorithms flagged, protocol and credential hygiene signals, and session lifecycle problems." ;;
        srv-ops)             echo "Scheduler overruns, PeSIT protocol activity and link problems, capacity and the retention sweeps, daemon/cluster health and stuck internal events." ;;
        srv-routing)         echo "Remote-poll effectiveness — whether the scheduled polls run and find anything — and the endpoints running transfers with no transfer site in their environment." ;;
        srv-missing)         echo "Entities that appear in the server messages but are absent from the transfer logs — subscriptions, accounts, IPs and logins." ;;
    esac
}
member_label() {   # row-1 tab text for a grouped report
    case $1 in
        topview) echo "Top view" ;;
        entity-search) echo "Search" ;;
        activity) echo "Activity" ;; punctuality) echo "Punctuality" ;; expected-arrival) echo "Expected arrival" ;;
        retries) echo "Retries & resubmissions" ;; file-journey) echo "File journey" ;;
        route-throughput) echo "Route throughput" ;; size-profile) echo "Size profile" ;;
        recovered) echo "Recovered flows" ;; recovered-files) echo "Recovered files" ;; security-outreach) echo "Security outreach" ;;
        connection-efficiency) echo "Connection efficiency" ;; duration-trend) echo "Duration trend" ;;
        failure-flows) echo "Per flow" ;;
        triage) echo "Triage" ;; data-diff) echo "Since yesterday" ;;
        partner-scorecard) echo "Partner scorecard" ;; blast-radius) echo "Blast radius" ;;
        app-partners) echo "Application dependencies" ;; partner-lifecycle) echo "Partner lifecycle" ;;
        cleanup-backlog) echo "Cleanup backlog" ;;
        errors) echo "Errors" ;; connections) echo "Connections" ;; logons) echo "Logons" ;;
        ssh-security) echo "SSH security" ;; platform-health) echo "Platform health" ;;
        capacity) echo "Capacity & sessions" ;; missing-entities) echo "Missing entities" ;;
        uc-status) echo "UC status" ;;
        anomalies) echo "Anomalies" ;;
        account) echo "Accounts" ;; login) echo "Logins" ;; subscription) echo "Subscriptions" ;;
        remote-host) echo "Hosts" ;;
        logical) echo "Logical" ;;
        partner) echo "Partners" ;; application) echo "Applications" ;; domain) echo "Domains" ;;
        bl) echo "BL" ;;
        cross-logical) echo "Logical" ;;
        cross-partner) echo "Partners" ;; cross-application) echo "Applications" ;; cross-domain) echo "Domains" ;;
        cross-bl) echo "BL" ;;

        volume) echo "Volume" ;; trend) echo "Growers & shrinkers" ;; size-dist) echo "Size distribution" ;;
        file-type) echo "File types" ;; top-transfers) echo "Largest files" ;; duplicate-files) echo "Duplicate files" ;;
        failed) echo "Failed Subscriptions" ;; failing-reasons) echo "Error reasons" ;; failure-rate) echo "Failure rate" ;; episodes) echo "Episodes" ;; from-green-to-red) echo "From green to red" ;; expired) echo "Expired" ;; missing-cronjobs) echo "Missing cronjobs" ;; only-red) echo "Only red" ;; waiting) echo "Waiting" ;; retry) echo "Repeat failures" ;; pirates) echo "One-legged" ;; stale-accounts) echo "Stale accounts" ;; went-quiet) echo "Went quiet" ;; failure-heatmap) echo "Failure heatmap" ;; not-in-flow-manager) echo "Not in Flow Manager" ;;
        patterns) echo "Patterns" ;; arrived-left) echo "Arrived / Left" ;; legs-count) echo "Legs count" ;; protocol-journey) echo "Protocol journey" ;; attempts) echo "Attempts" ;; resubmissions) echo "Resubmissions" ;; file-in-file-out) echo "File in - File out" ;;
        protocol) echo "Protocol, Direction & Mode" ;;
        dwell-time) echo "Store-and-forward" ;; ranking) echo "Ranking" ;;
        duration) echo "Duration" ;;
        security-params) echo "Security Parameters" ;; av-scan) echo "AV Scan" ;;
        cross-account) echo "Account" ;; cross-login) echo "Login" ;; cross-subscription) echo "Subscriptions" ;;
        cross-host) echo "Hosts" ;;
        went-kaput) echo "Trouble after success" ;;
        errors-day) echo "Errors per day" ;; error-timing) echo "Error timing" ;; error-reasons) echo "Error reasons" ;; top-messages) echo "Top messages" ;;
        site-failures) echo "Connection failures" ;; connection-diagnostics) echo "Diagnostics" ;; inbound-connections) echo "Inbound connections" ;; logon) echo "Logon" ;; auth-activity) echo "Auth activity" ;; ssh-key-auth) echo "Key auth" ;; uc1-status) echo "UC1 status" ;; uc2-status) echo "UC2 status" ;; uc4-status) echo "UC4 status" ;; uc2-visits) echo "UC2 pickup visits" ;; pickups) echo "Pickups" ;; account-sharing) echo "Account sharing" ;; twins) echo "Twins" ;;
        ssh-crypto) echo "Crypto" ;; ssh-sessions) echo "SSH sessions" ;;
        scheduler-overruns) echo "Scheduler" ;; pesit) echo "PeSIT" ;; cluster-health) echo "Cluster health" ;; stuck-events) echo "Stuck events" ;; file-cleanup) echo "File cleanup" ;;
        deploy-errors) echo "Deploy errors" ;; remote-poll) echo "Remote Polls" ;; transfer-site-missing) echo "Transfer site missing" ;; uc3-status) echo "UC3 status" ;; no-remote-dir) echo "No remote dir" ;; no-remote-files) echo "No remote files" ;;
        unknown-sites) echo "Subscriptions" ;; unknown-accounts) echo "Accounts" ;; unknown-hosts) echo "Hosts" ;; unknown-whitelisting) echo "Whitelist" ;; unknown-logins) echo "Logins" ;;
    esac
}
# First rendered page of a report (its first table page, or its single page).
first_page() {
    # The Entities reports live in the entities/ subdir and open on ALL
    # (logged + configured — the 2026-07 default; formerly Seen).
    case $1 in
        account|login|subscription|remote-host|logical|partner|application|domain|bl)
            echo "entities/$1-all.html"; return ;;
        entity-search) echo "../search.html"; return ;;    # published at the ENV ROOT (renamed 2026-07)
    esac
    local labels; labels=$(report_tabs "$1")
    if [ -z "$labels" ]; then echo "$1.html"
    else local fl; IFS='|' read -r fl _ <<< "$labels"; echo "$1-$(slugify "$fl").html"; fi
}

# Landing page of a GROUP's index/dropdown entry — the first member's first
# page, unless overridden (the cross-reference entry opens on Account × Subscriptions).
group_home() {   # $1 group id
    case $1 in
        cross)        echo "xref/cross-account-subscriptions.html" ;;   # the cross pages live in docs/<env>/analyses/xref/ (analyses-relative href)
        account-login-site) first_page subscription ;;   # Entities DEFAULTS to Subscriptions / All — the same member the tab bar leads with
        *)            local fm; fm=$(group_members "$1"); first_page "${fm%% *}" ;;
    esac
}

# ---- helpers ----------------------------------------------------------------

esc() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; ESC=$s; }

# One Top-5 card from a TOP rpt line (the day pages' protocol, shared with the
# Overview since 2026-08): TOP<TAB>kind<TAB>title<TAB>unit<TAB>href<TAB>
# name US value US … (US = \x1f). Kind P/A/S names the entity column and pins
# the card to its .daytop grid column (.dt-p / .dt-s), so a metric with nothing
# on one side leaves a hole instead of pulling the other side across.
top_table() {   # $1 kind  $2 title  $3 unit  $4 href  $5 rows
    local kind=$1 rows=$5 nm val body="" ent
    case $kind in P) ent="Partner" ;; A) ent="Account" ;; *) ent="Subscription" ;; esac
    esc "$2";    local et=$ESC
    esc "$3";    local eu=$ESC
    esc "$4";    local eh=$ESC     # the href carries &axway_sort= — esc makes it &amp;
    esc "$ent";  local ee=$ESC
    # walk the US-separated name/value pairs (bash 3.2: no readarray)
    while [ -n "$rows" ]; do
        nm=${rows%%$'\037'*}; rows=${rows#*$'\037'}
        val=${rows%%$'\037'*}
        if [ "$val" = "$rows" ]; then rows=""; else rows=${rows#*$'\037'}; fi
        esc "$nm"; local en=$ESC
        esc "$val"; local ev=$ESC
        body+="<tr><td>$en</td><td class=\"num\">$ev</td></tr>"
    done
    [ -n "$body" ] || return 0
    local col; case $kind in P) col=dt-p ;; *) col=dt-s ;; esac
    printf '<section class="card %s"><h3>%s</h3><div class="tablewrap"><table><tr><th>%s</th><th class="num">%s</th></tr>%s</table></div><a class="seemore" href="%s">See more &rarr;</a></section>' \
        "$col" "$et" "$ee" "$eu" "$body" "$eh"
}

# Thousands separators with a dot (159048 -> 159.048), POSIX awk; a non-integer
# (date, percent) passes through.
dotify() {
    awk -v n="$1" 'BEGIN{
        if (n !~ /^[0-9]+$/) { printf "%s", n; exit }
        s = ""; c = 0
        for (i = length(n); i >= 1; i--) { s = substr(n, i, 1) s; if (++c % 3 == 0 && i > 1) s = "." s }
        printf "%s", s
    }'
}

slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -e 's/^-//' -e 's/-$//'; }

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

# value of directive $1 in file $2. ONE awk with an early exit, not grep|cut: it
# is called a few hundred times per publish (the finder, What is new, the area
# indexes, the day pages) and halving two processes to one is worth ~0.3 s a run.
# field2 FILE A B -> the values of directives A and B, one per line (A first,
# blank when absent). One awk instead of two field1 calls — What is new asks for
# TITLE and INTRO of every report it lists.
field2() { LC_ALL=C awk -F'\t' -v a="$2" -v b="$3" '
    function v(l,   i) { i = index(l, "\t"); return (i ? substr(l, i + 1) : "") }
    $1 == a && !ga { ga = 1; va = v($0) }
    $1 == b && !gb { gb = 1; vb = v($0) }
    ga && gb { exit }
    END { print va; print vb }' "$1" 2>/dev/null || printf '\n\n'; }

field1() { LC_ALL=C awk -F'\t' -v k="$1" '$1 == k { i = index($0, "\t"); print (i ? substr($0, i + 1) : ""); exit }' "$2" 2>/dev/null || true; }
meta_val() { grep -m1 "^META"$'\t'"$2"$'\t' "$1" 2>/dev/null | cut -f3- || true; }   # META key $2 in file $1

html_head() {   # $1 title  $2 css_href  [$3 date-list]  [$4 unused (was the right label — replaced by the quick-search box)]  [$5 help slug]  [$6 area]  [$7 report key]  [$8 body class (the detail pages' direction/seen tint)]  [$9 extra asset scripts, space-separated basenames — only the slot-chart pages ask for slotchart.js]
    esc "$1"
    # TWO depth prefixes since the env split. Callers keep passing their css
    # href relative to the ENV root ("../assets/style.css" from
    # docs/<env>/transfer/) exactly as before the split:
    #   envbase = path back to the ENV root  (docs/<env>/)  — the in-env links:
    #             the report dropdowns, the Entities link, the search form
    #   base    = path back to the DOCS root (one level higher) — the shared
    #             artifacts: assets/, help/, index.html (home)
    # On a SITE_ENV-less page (the shared root home, the local build report)
    # base = the caller's prefix as-is and envbase points into acceptance/ (the
    # default env; report.js rewrites the links when Production is active).
    local envbase=${2%assets/style.css}
    local base envpair
    if [ -n "${SITE_ENV:-}" ]; then
        base="${envbase}../"
    else
        base=$envbase
        envbase="${base}acceptance/"
    fi
    local home=${base}index.html                         # home = the SHARED root index
    printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n<meta name="viewport" content="width=device-width,initial-scale=1">\n<title>%s</title>\n' "$ESC"
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
    # Env-prefixed so the two environments' date ranges never share a store.
    [ -n "${3:-}" ] && [ -n "${6:-}" ] && printf '<meta name="report-area" content="%s%s">\n' "${SITE_ENV:+$SITE_ENV-}" "$6"
    # A stable per-REPORT key for report.js's search/sort persistence: identical
    # on every page of one report — all its table-tab pages — so e.g. Entity
    # Search keeps the typed search when switching All / Seen / Not Seen. Pages
    # without it (details) fall back to pageKeyBase()'s basename derivation.
    [ -n "${7:-}" ] && printf '<meta name="report-key" content="%s">\n' "$7"
    printf '<link rel="stylesheet" href="%sassets/style.css%s">\n<script src="%sassets/topbar-data.js%s" defer></script>\n<script src="%sassets/report.js%s" defer></script>\n' "$base" "${ASSET_VER:+?v=$ASSET_VER}" "$base" "${TB_VER:+?v=$TB_VER}" "$base" "${ASSET_VER:+?v=$ASSET_VER}"
    local _xs
    for _xs in ${9:-}; do printf '<script src="%sassets/%s%s" defer></script>\n' "$base" "$_xs" "${ASSET_VER:+?v=$ASSET_VER}"; done
    printf '</head>\n<body%s>\n' "${8:+ class=\"$8\"}"
    # RUNTIME top bar (2026-07): every html_head page bakes only a compact
    # PLACEHOLDER — report.js (buildTopbar) renders the full bar client-side
    # from docs/assets/topbar-data.js (the menu strings, written once per
    # publish by ensure_assets) + these data attrs: data-eb/-b the two depth
    # prefixes, data-env the page's env (absent = the shared root pages, whose
    # bar gets the dual data-target env toggle), data-help the help slug, and
    # data-twin the OTHER env's twin page (stamped by bin/build/crosslink.sh after
    # both envs exist; absent -> report.js's pathname-swap fallback). The
    # baked-chrome pages (help, build report — render_shared_topbar) keep the
    # full bar; buildTopbar skips a non-empty topbar div.
    printf '<div class="topbar" data-eb="%s" data-b="%s"%s%s></div>\n' \
        "$envbase" "$base" "${SITE_ENV:+ data-env=\"$SITE_ENV\"}" "${5:+ data-help=\"$5\"}"
}

# The site-wide top bar. $1 base (docs-root prefix), $2 envbase (env-root
# prefix), $3 envpair HTML, $4 help slug (""=none). Called by html_head and the
# shared pages (render_shared_topbar), so all pages share one definition.
render_topbar() {
    local base=$1 envbase=$2 envpair=$3 helpslug=${4:-} home=${1}index.html
    # SIX evenly-spaced parts (the bar's justify-content:space-between does the
    # spacing — no pushing margins, 2026-07 redesign): 1 the brand (-> the
    # shared home) · 2 the ENV pair (report.js setupEnvSwitch) · 3 the Entities
    # link + search icon · 4 the three report dropdowns (Transfer/Server/
    # Analyses) · 5 the plain Dashboard link (ONE dashboard page — no dropdown)
    # · 6 the three right icons. The precomputed menu strings carry an "@"
    # placeholder; swap it for this page's ENV prefix.
    printf '<div class="topbar"><a class="brand" href="%s">Cloud</a><span class="envpair">%s</span><span class="entgroup"><a class="entlabel" href="%stransfer/entities/subscription-all.html">Entities</a><a class="searchbtn" href="%ssearch.html" title="Search" aria-label="Search">&#128269;</a></span>' "$home" "$envpair" "$envbase" "$envbase"
    # the FILE SEARCH entry (2026-08), mirroring report.js buildTopbar:
    # between the search icon and the report menus
    printf '<a class="dashlink" href="%sfile-search-24-hours.html">Files</a>' "$envbase"
    printf '<nav class="nav">'
    printf '<div class="dd"><span class="ddlabel">Transfer reports \342\226\276</span><div class="ddm">%s</div></div>' "${TRANSFER_MENU//@/$envbase}"
    [ -n "${SERVER_MENU:-}" ] && printf '<div class="dd"><span class="ddlabel">Server reports \342\226\276</span><div class="ddm">%s</div></div>' "${SERVER_MENU//@/$envbase}"
    [ -n "${ANALYSES_MENU:-}" ] && printf '<div class="dd"><span class="ddlabel">Analyses \342\226\276</span><div class="ddm">%s</div></div>' "${ANALYSES_MENU//@/$envbase}"
    printf '</nav>'
    printf '<a class="dashlink" href="%sdashboards/index.html">Dashboard</a>' "$envbase"
    # Top-bar right: the REPORT FINDER + SITE MAP magnifiers, then the help icon.
    printf '<span class="tr-group">'
    printf '<a class="searchbtn" href="%sreport-finder.html" title="Report finder" aria-label="Report finder">&#128270;</a>' "$envbase"
    printf '<a class="searchbtn" href="%ssitemap.html" title="Site map" aria-label="Site map">&#128506;</a>' "$envbase"
    [ -n "$helpslug" ] && printf '<a class="helpbtn" href="%shelp/%s.html" title="Help" aria-label="Help">?</a>' "$base" "$helpslug"
    printf '</span></div>\n'
}
# (The site-wide fixed FOOTER BAR was removed 2026-07, with its "Build report"
# link and build timestamp. The build report is reachable from the SITE MAP,
# which links the report of the run that built that env — see write_sitemap in
# bin/build/publish.sh. Nothing bakes a build identity into a page any more,
# which is also why a scope switch re-renders nothing.)
# The top bar for an ENV-NEUTRAL shared page (the local build report, help/…) whose
# docs-root prefix is $1: SITE_ENV-less, so the env pair toggles like the home's
# and the in-env links point into acceptance/ (report.js rewrites them when
# Production is active; on these pages the switch is inert — one page, no env
# data — which is fine, UI consistency matters more). $2 = help slug.
render_shared_topbar() {
    local base=$1 helpslug=${2:-}
    local envbase="${base}acceptance/"
    local envpair='<a class="envswitch" data-target="acceptance">Acceptance</a><span class="envsep">/</span><a class="envswitch" data-target="production">Production</a>'
    render_topbar "$base" "$envbase" "$envpair" "$helpslug"
}

# ---- report page renderer ---------------------------------------------------

render_rpt() {   # $1 rpt  $2 out-html  $3 css_href  $4 home-href  [$5 top-bar right label]  [$6 drop first table title]  [$7 help slug]
    local rpt=$1 out=$2 css=$3 home=$4 rlabel=${5:-} droptitle=${6:-} helpslug=${7:-} reportkey=${8:-}
    local title; title=$(grep -m1 "^TITLE"$'\t' "$rpt" | cut -f2- || true)
    # The page's AREA (the date-filter persistence key report.js uses), derived
    # from where the output lands — transfer report and detail pages share the
    # transfer dataset, server report pages the server one. Same derivation the
    # callers use for the CSS depth, so no caller needs a new argument.
    local rarea=""
    case $out in
        "$DOCS"/transfer/*|"$DOCS"/details/*) rarea="transfer" ;;
        "$DOCS"/server/*)                     rarea="server" ;;
    esac
    # The page body — the whole .rpt line protocol, tables and cells included —
    # is rendered by ONE awk pass (bin/render_rpt.awk): rendering it in bash
    # cost ~5 process forks per entity-linked cell and put a full transfer
    # publish at ~5 minutes. LC_ALL=C keeps the awk byte-oriented (tolower and
    # the slugify character classes fold ASCII only, like the tr|sed pipeline
    # the awk replaces).
    # The detail pages carry a direction/seen body tint: details.sh writes a
    # META dirclass line, html_head turns it into a <body> class (style.css).
    local bodyclass; bodyclass=$(meta_val "$rpt" dirclass)
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
        html_head "$title" "$css" "$CUR_DATES" "$rlabel" "$helpslug" "$rarea" "$reportkey" "$bodyclass"
        LC_ALL=C awk -F'\t' -v droptitle="$droptitle" -v dlink="${DLINK_BASE:-../details/}" \
            -v slugmaps="$SLUGMAP_FILES" -v resmaps="${RESMAP_FILES:-}" \
            -v subtint="${RPT_SUBTINT:-}" \
            -v grpicons="${GRPICON_MAP:-}" -v dropbuckets="$dropbuckets" \
            -f "$RENDER_AWK" "$rpt"
        printf '</body>\n</html>\n'
    } > "$out"
}

# Segment a .rpt (globals): HEADER (pre-table lines), FOOTER (trailing
# NOTE/SUMMARY/FOOT), NTAB, TBLOCK[1..NTAB] (each table's block of lines).
# A NOTE that sits BETWEEN tables belongs to the table it follows (e.g.
# volume's per-row note under "Volume by direction") and stays in that block,
# so it appears only on that table's page; NOTEs after the last table are
# report-wide and go to FOOTER (rendered on every split page), as before.
segment_rpt() {
    HEADER=""; FOOTER=""; NTAB=0; TBLOCK=()
    local line dir phase="head" pending=""
    while IFS= read -r line || [ -n "$line" ]; do
        dir=${line%%$'\t'*}
        case $dir in
            TABLE)
                if [ -n "$pending" ]; then TBLOCK[$NTAB]+=$'\n'"${pending%$'\n'}"; pending=""; fi
                phase="tab"; NTAB=$((NTAB+1)); TBLOCK[$NTAB]="$line" ;;
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
                else TBLOCK[$NTAB]+=$'\n'"$line"; fi
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
# every order-listed report whose .rpt is absent in THIS env (production's
# example data skips many). The menus, sitemap and group tab rows list ALL
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
        # the Subscriptions group's pages live in docs/<env>/analyses/, which
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
            printf '<p class="range">This report has <strong>no data in this environment</strong> — the log lines or configuration it reads are absent, so its report file was not produced. The report exists in the other environment when its data does; use the environment switch in the top bar.</p>\n'
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
# `docs/help/*.html` bullet; docs/help/index.html is the START PAGES' help text
# (data-help="index" on the three area start pages) — it catalogs nothing.
help_slug_for() {   # $1 area (transfer|server)  $2 report basename
    local area=$1 n=$2
    case $n in
        account|login|subscription|remote-host|logical|partner|application|domain|bl) echo "entities-$n" ;;
        skipped-*)                                                      echo "skipped" ;;   # the per-value Skipped pages share one help page
        failed-*)                                                       echo "failed" ;;    # the Failed Subscriptions view pages share one help page
        failing-reasons-*)                                              echo "failing-reasons" ;;  # the per-reason drill pages share the Error reasons help page
        duration-all|duration-minmax|duration-all-minmax)     echo "duration" ;;  # the All-transfers / Min-Avg-Max sibling views share the Duration help page
        entity-coverage-ok|entity-coverage-once|entity-coverage-diff)   echo "entity-coverage" ;;  # the OK-transfers / Once / Difference rule views share the Entity coverage help page
        cross-*)                                                        echo "cross-reference" ;;
        missing-entities)    echo "server-unknown-entities" ;;   # the merged report keeps the unknown-* family help page
        # the 2026-07 merged reports keep one component's existing help page
        activity)            echo "day" ;;
        retries)             echo "retry" ;;
        file-journey)        echo "patterns" ;;
        errors)              echo "server-errors-day" ;;
        connections)         echo "server-inbound-connections" ;;
        logons)              echo "server-logon" ;;
        platform-health)     echo "server-cluster-health" ;;
        capacity)            echo "server-pesit" ;;
        ssh-security)        echo "server-ssh-crypto" ;;
        uc-status)           echo "server-uc1-status" ;;
        files)               echo "size-dist" ;;
        *) if [ "$area" = server ]; then echo "server-$n"; else echo "$n"; fi ;;
    esac
}

# ---- Entities reports: views x scope ----------------------------------------
# Each Entities report renders TEN pages into docs/<area>/entities/
# (9 entities -> 90 pages), with three tab groups on the nav row: the entity
# members, the views, and the scope.
#   views  All | Seen | Not seen | OK | Warning | Error [| Server]
#   scope  Transfer | +Server   (2026-07; Transfer and Server used to be two of
#          the VIEWS, slicing the same catalog by a different question)
# The scope answers ONE question: does a SERVER-log sighting count as seen?
#   +Server   the DEFAULT and the site-wide model — an entity surfaced only by
#             the server log is result=blue and counts as SEEN. Pages keep the
#             bare name (<entity>-<view>.html), so every existing link holds.
#   Transfer  pretend the server log was never read: a blue entity is then just
#             configured-but-never-seen, so it tints ORANGE and moves out of
#             Seen into Not seen / Warning. Pages carry the -transfer suffix.
# Only THREE views are scope-dependent (the `dual` flags below): Seen, Not seen
# and Warning. All lists every configured + logged name either way, and no blue
# entity is ever green or red, so All / OK / Error are ONE page each — and on
# those the two scope tabs render DISABLED (dimmed, unlinked, neither selected)
# rather than pointing at two identical pages.
# SERVER is a SEVENTH view belonging to the +Server scope alone (`srvonly`): the
# blue names by themselves. It is offered, last in the view row, on every page
# the +Server reading applies to — the +Server pages AND the three
# scope-independent ones — and is absent from the -transfer pages, where those
# names are simply never seen. Its own page shows +Server active with Transfer
# disabled. It is what the status tables' Server column links.
# The scope pair is exactly the home page's "including server log" switch: its
# ON figures link the bare pages, its OFF figures the -transfer ones (for the
# three figures that have one — Total/Error/Ok link their single page).
# What each view holds:
#   All       the Summary rows plus one zero-blank row per configured-but-
#             never-seen name (the DEFAULT page — see first_page: every
#             entry/menu/group link lands here)
#   Seen      the .rpt's Summary table exactly as written
#   Not seen  only the configured-never-seen rows (no RECALC and no date
#             cells, so the page renders no From/To — zero date-aware tables)
#   OK/Warning/Error   the rows whose entity RESULT is green / orange / red
#   Server    the result=blue rows — seen in the server log, never in a
#             transfer (+Server scope only; name column, like Not seen)
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
        $1 == "HEAD" || $1 == "KIND" || $1 == "TOTAL" { print $1, $2; next }
        $1 == "ROW" { out = $1 OFS $2; for (i = 3; i <= NF; i++) if ($i ~ /^@data:/) out = out OFS $i; print out; next }
        { print }'
}
render_entity_report() {   # $1 area  $2 name  $3 rpt  $4 rlabel  $5 hslug  $6 rkey
    local area=$1 name=$2 rpt=$3 rlabel=$4 hslug=$5 rkey=$6
    segment_rpt "$rpt"                                  # TBLOCK[1]=Summary, TBLOCK[2]=Detail
    local sumblk=${TBLOCK[1]:-}
    local stable shead stotal srows snotes
    stable=$(printf '%s\n' "$sumblk" | grep -m1 $'^TABLE\t' || true)
    shead=$(printf '%s\n' "$sumblk" | grep -E $'^(HEAD|KIND|RECALC)\t' || true)
    stotal=$(printf '%s\n' "$sumblk" | grep -m1 $'^TOTAL\t' || true)
    srows=$(printf '%s\n' "$sumblk" | grep $'^ROW\t' || true)
    snotes=$(printf '%s\n' "$sumblk" | grep $'^NOTE\t' || true)
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
    # Server-log-only entities are result==blue in the member's base cache
    # (bin/build/seen-in-server-log.sh): they have NO real transfer (so they are not in the
    # .rpt Summary), and showseen counts them as seen (so the coverage TSV marks
    # them seen, not never-seen). ADD them here as BLANK blue rows — only the
    # name + the blue tint — so the Seen / All / Server views show them; their
    # Files/Error/OK/Volume/%/First/Last stay empty (no real sighting) and they
    # carry no drill/buckets (the date filter and drill-downs ignore them). The
    # numeric TOTAL is unchanged (blue = 0); only the "(N rows)" count grows.
    local bluebase="" bluerows="" nblue=0
    case $name in
        subscription) bluebase=_subscriptions ;; account) bluebase=_accounts ;; login) bluebase=_logins ;;
        remote-host) bluebase=_hosts ;; logical) bluebase=_logicals ;; partner) bluebase=_partners ;;
        application) bluebase=_apps ;; domain) bluebase=_domains ;; bl) bluebase=_bl ;;
    esac
    local bluef="$DATA/flow-manager/base/$bluebase.tsv"
    { [ -n "$bluebase" ] && [ -f "$bluef" ] && [ "${ncols:-0}" -gt 0 ]; } || bluef=""
    if [ -n "$bluef" ]; then
        bluerows=$(LC_ALL=C awk -F'\t' -v nc="$ncols" '$3=="blue"{ printf "ROW\t%s", $1; for(c=2;c<=nc;c++) printf "\t"; printf "\t@data:res=blue\n" }' "$bluef")
    fi
    if [ -n "$bluerows" ]; then
        nblue=$(printf '%s\n' "$bluerows" | grep -c $'^ROW\t' || true)
        sumblk=$(printf '%s\n' "$sumblk" | LC_ALL=C awk -F'\t' -v OFS='\t' -v br="$bluerows" -v nb="$nblue" '
            $1=="TOTAL" {
                print br                                          # blue rows just before the total
                if (match($2, /\([0-9,]+/)) { cnt=substr($2,RSTART+1,RLENGTH-1); gsub(/,/,"",cnt); sub(/\([0-9,]+/, "(" (cnt+nb), $2) }
                print; next }
            { print }')
        srows=$(printf '%s\n' "$sumblk" | grep $'^ROW\t' || true)
        stotal=$(printf '%s\n' "$sumblk" | grep -m1 $'^TOTAL\t' || true)
    fi
    # GHOST rows — configured names in NEITHER set: no report row, not blue
    # (bluerows folded into srows above), and no coverage row at all. Since
    # the Logical-based derivations (2026-08-30) key every coverage TSV by
    # the real member names this set is EMPTY on a healthy estate — what
    # still lands here is either a flow the COVERAGE TSV vouches for without
    # a report row (a UC3 clean-poll green: seen-with-blank-counts — VOUCHED,
    # stays on Seen exactly as before) or a flow configured with NO login and
    # NO host, whose direction-less rows every derived-coverage builder skips
    # — NO coverage row, NO evidence: that one belongs on NOT SEEN
    # (2026-08-31, user report: a config-only env showed 6% of Domains "Seen"
    # with zero logs — the old rule counted the evidence-free ghosts as seen,
    # and the home figure with them). Both kinds still render on All as blank
    # configured rows, tinted by their base RESULT like every row.
    local ghrows="" ghnsrows="" ngh=0 nghns=0 _ghall=""
    local ghbase="$DATA/flow-manager/base/${bluebase:-none}.tsv"
    if [ -n "$bluebase" ] && [ -f "$ghbase" ] && [ "${ncols:-0}" -gt 0 ]; then
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
    # (configured-never-seen, blue, ghost) have an empty cell, and numKey sorts
    # those last in either direction, so they collect at the bottom. The
    # name-only views (Not seen, Server) have no Files column and keep A-Z on
    # the name (sort=0:1). It is a page DEFAULT, not a user choice: a remembered
    # header click still wins, and the header toggle works from it.
    # The Not seen view also keeps the seenrows red tint, while the All view
    # tints rows by the entity RESULT instead (@data:res, injected below).
    tbl_variant() {   # $1 heading suffix  $2 space-separated extra modifiers
        printf '%s\n' "$stable" | LC_ALL=C awk -F'\t' -v OFS='\t' -v sfx="$1" -v mods="$2" '
            { $2 = $2 " \342\200\224 " sfx; n = split(mods, M, " "); for (i = 1; i <= n; i++) $0 = $0 OFS M[i]; print }'
    }
    # All = seen (green) + configured-never-seen (red) rows, MERGED by Files
    # DESCENDING (field 3, a bare integer; the count-less rows sort as 0 and
    # land at the bottom) with the name — case folded, byte-order tiebreak — as
    # the tiebreak, so the baked .rpt order MATCHES the initial sort and a
    # no-JS render shows the same order. The OK/Warning/Error blocks filter
    # these rows in place, so they inherit the order too.
    local all_rows=""
    [ -n "$srows" ]  && all_rows=$(printf '%s\n' "$srows" | sed $'s/$/\t@data:seen=1/')
    [ -n "$nsrows" ] && all_rows+=${all_rows:+$'\n'}$nsrows
    [ -n "$ghrows" ] && all_rows+=${all_rows:+$'\n'}$ghrows
    [ -n "$ghnsrows" ] && all_rows+=${all_rows:+$'\n'}$ghnsrows
    [ -n "$all_rows" ] && all_rows=$(printf '%s\n' "$all_rows" | LC_ALL=C sort -t$'\t' -k3,3nr -k2,2f -k2,2)
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
              if (r == "green" || r == "orange" || r == "red" || r == "blue") print $0, "@data:res=" r
              else print }' -)
    fi
    # Tint the ghost rows HERE, once: they go into the All view (below, where
    # the pass then skips them — it leaves an already-tinted row alone) AND
    # into the Seen view further down, which is assembled after that pass.
    if [ -n "$ghrows" ] && [ -n "$resfile" ]; then
        ghrows=$(printf '%s\n' "$ghrows" | LC_ALL=C awk -F'\t' -v OFS='\t' -v resf="$resfile" '
            BEGIN { while ((getline l < resf) > 0) { split(l, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) }
            { r = res[toupper($2)]
              if (r == "green" || r == "orange" || r == "red" || r == "blue") print $0, "@data:res=" r
              else print }' -)
    fi
    if [ -n "$ghnsrows" ] && [ -n "$resfile" ]; then
        ghnsrows=$(printf '%s\n' "$ghnsrows" | LC_ALL=C awk -F'\t' -v OFS='\t' -v resf="$resfile" '
            BEGIN { while ((getline l < resf) > 0) { split(l, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) }
            { r = res[toupper($2)]
              if (r == "green" || r == "orange" || r == "red" || r == "blue") print $0, "@data:res=" r
              else print }' -)
    fi
    # The blue rows added above already carry @data:res=blue, so the tint pass
    # passes them through untouched and only tints the real seen rows
    # (green/orange/red) and the never-seen rows.
    if [ -n "$all_rows" ] && [ -n "$resfile" ]; then
        all_rows=$(printf '%s\n' "$all_rows" | LC_ALL=C awk -F'\t' -v OFS='\t' -v resf="$resfile" '
            BEGIN { while ((getline l < resf) > 0) { split(l, a, "\t"); res[toupper(a[1])] = a[3] } close(resf) }
            /@data:res=/ { print; next }
            { r = res[toupper($2)]
              if (r == "green" || r == "orange" || r == "red") print $0, "@data:res=" r
              else print }' -)
    fi
    # The SEEN view tints its rows by the entity RESULT too (same lookup as
    # the All view; the blue rows already carry @data:res=blue). Non-ROW lines
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
        sumblk_tinted+=$'\n'"NOTE"$'\t'"Row colors: **light green** = last transfer OK, **light orange** = a mixed OK/Error rollup, **light red** = last transfer Error (or server-log Errors/Warnings after the last OK transfer), **light blue** = seen in the server log only. For entity types other than subscriptions the result rolls up from the connected subscriptions. An UNTINTED row was logged but is not configured in FlowManager — it has no result to color by."
    fi
    # datereset on the Seen view too (the All view's TABLE variant carries it,
    # and the OK/Warning/Error/Transfer variants below): every Entities view is
    # a CATALOG the status tables link into, so it opens at the full date range
    # whatever From/To the transfer area remembers. Narrowing stays page-local.
    # (and sort=1:-1 — Files descending, like every other counted view; the
    # Seen rows arrive Files-desc from the .rpt, so this only makes the page
    # default explicit and marks the sorted header.)
    sumblk_tinted=$(printf '%s\n' "$sumblk_tinted" | LC_ALL=C awk -F'\t' -v OFS='\t' '
        $1 == "TABLE" && !done { $0 = $0 OFS "sort=1:-1" OFS "datereset"; done = 1 } { print }')
    # The VOUCHED ghost rows belong on SEEN (2026-07): the coverage TSV — and
    # with it showseen, the analyses figures and the status tables' Seen
    # column — counts these names as seen (e.g. the UC3 clean-poll greens,
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
    blk_all="$(tbl_variant "all (logged + configured)" "sort=1:-1 datereset")"$'\n'"$shead"$'\n'"$tot_all"
    [ -n "$all_rows" ] && blk_all+=$'\n'"$all_rows"
    blk_all+=$'\n'"NOTE"$'\t'"Row colors: **light green** = last transfer OK, **light orange** = configured but never seen, **light red** = last transfer Error (or server-log Errors/Warnings after the last OK transfer), **light blue** = surfaced only by the Server → Transfer step (bin/build/seen-in-server-log.sh) with no real transfer. For entity types other than subscriptions the result rolls up from the connected subscriptions; configured-but-never-seen rows keep blank counts. A green/red-tinted row with BLANK counts was seen only through a sibling group — a shared endpoint whose Files are credited to the co-tenant, or one side of a two-partner account name. An UNTINTED row was logged but is not configured in FlowManager — it has no result to color by."
    [ -n "$snotes" ] && blk_all+=$'\n'"$snotes"
    shead_ns=$(printf '%s\n' "$shead" | grep -v $'^RECALC\t' || true)   # no buckets -> no RECALC -> no From/To on this page
    local nsrows_gh=$nsrows
    if [ -n "$ghnsrows" ]; then
        nsrows_gh=${nsrows:+$nsrows$'\n'}$ghnsrows
        nsrows_gh=$(printf '%s\n' "$nsrows_gh" | LC_ALL=C sort -t$'\t' -k2,2f -k2,2)
    fi
    blk_ns="$(tbl_variant "configured, never seen" "seenrows sort=0:1")"$'\n'"$shead_ns"$'\n'"$tot_ns"
    [ -n "$nsrows_gh" ] && blk_ns+=$'\n'"$nsrows_gh"
    blk_ns+=$'\n'"NOTE"$'\t'"Configured in FlowManager but never seen in this log window. Every name links to its detail page, which lists the configured cross-references."
    blk_ns=$(printf '%s\n' "$blk_ns" | entities_name_only)   # Not seen: name column only
    # ---- TRANSFER SCOPE: Seen and Not seen ---------------------------------
    # Seen (transfer) = the Seen rows MINUS the blue ones — the entities with a
    # REAL transfer (Seen = Transfer + Server). Same columns and RECALC as
    # Seen, since these rows carry their @data:buckets. It is what the status
    # tables' "Transfer" column links, so its row count must equal Seen −
    # Server; the numeric TOTAL is the Seen one unchanged (blue rows are blank).
    local blk_seen_tr transfer_rows ntransfer tot_transfer
    transfer_rows=$(printf '%s\n' "$sumblk_tinted" | grep $'^ROW\t' | grep -v '@data:res=blue' || true)
    ntransfer=$(printf '%s' "$transfer_rows" | grep -c $'^ROW\t' || true)
    tot_transfer=$(printf '%s\n' "$stotal" | LC_ALL=C awk -F'\t' -v OFS='\t' -v n="$ntransfer" '{ sub(/\([0-9,]+/, "(" n, $2); print }')
    blk_seen_tr="$(tbl_variant "seen in the transfer log" "sort=1:-1 datereset")"$'\n'"$shead"$'\n'"$tot_transfer"
    [ -n "$transfer_rows" ] && blk_seen_tr+=$'\n'"$transfer_rows"
    blk_seen_tr+=$'\n'"NOTE"$'\t'"The entities with at least one **real transfer** in this log window — the Seen view minus the server-log-only (blue) rows. Switch the scope to **+Server** to count a server-log sighting as seen. Row colors are the entity RESULT, as on Seen."
    # Not seen (transfer) = the configured-never-seen rows PLUS the blue ones:
    # with the server log out of scope those entities were never seen either.
    # They join as never-seen rows (@data:seen=0) and RETINT ORANGE — the
    # documented Transfer-scope rule (ARCHITECTURE: "blue tints orange and
    # moves into Not seen/Warning"), and exactly what the Warning (transfer)
    # view above already does; keeping the blue here made the two views of ONE
    # scope disagree about the same rows (2026-08-15 audit D2).
    local blk_ns_tr nsrows_tr=$nsrows_gh nns_tr=$((nns + nghns)) tot_ns_tr bluens
    if [ -n "$bluerows" ]; then
        bluens=$(printf '%s\n' "$bluerows" | LC_ALL=C sed $'s/@data:res=blue/@data:res=orange/; s/$/\t@data:seen=0/')
        nsrows_tr=${nsrows_gh:+$nsrows_gh$'\n'}$bluens
        nsrows_tr=$(printf '%s\n' "$nsrows_tr" | LC_ALL=C sort -t$'\t' -k2,2f -k2,2)
        nns_tr=$((nns + nghns + nblue))
    fi
    tot_ns_tr=$(printf '%s\n' "$stotal" | LC_ALL=C awk -F'\t' -v n="$nns_tr" '{ sub(/\([0-9,]+/, "(" n, $2); printf "TOTAL\t%s", $2; for (i = 3; i <= NF; i++) printf "\t"; print "" }')
    blk_ns_tr="$(tbl_variant "never seen in the transfer log" "seenrows sort=0:1")"$'\n'"$shead_ns"$'\n'"$tot_ns_tr"
    [ -n "$nsrows_tr" ] && blk_ns_tr+=$'\n'"$nsrows_tr"
    blk_ns_tr+=$'\n'"NOTE"$'\t'"Configured in FlowManager but never seen in the **transfer log** in this window — including the entities that DID appear in the server log (the **+Server** scope counts those as seen and lists them under Seen). Every name links to its detail page, which lists the configured cross-references."
    blk_ns_tr=$(printf '%s\n' "$blk_ns_tr" | entities_name_only)   # Not seen: name column only
    # Server view: ONLY the blue rows — the entities that appear in the server
    # logs but never in the transfer logs. A view of the +Server SCOPE ALONE
    # (in the Transfer scope those names are simply never seen, so the tab is
    # not offered there): the render loop lists it last in the view row on
    # every non-transfer page, and its own page shows +Server active with
    # Transfer disabled. Name-only, no RECALC -> no From/To.
    local blk_server tot_server
    tot_server=$(printf '%s\n' "$stotal" | LC_ALL=C awk -F'\t' -v n="$nblue" '{ sub(/\([0-9,]+/, "(" n, $2); printf "TOTAL\t%s", $2; for (i = 3; i <= NF; i++) printf "\t"; print "" }')
    # restint: its rows carry @data:res=blue but the table had no tint attribute
    # at all, so they rendered UNCOLOURED while their detail pages are blue.
    blk_server="$(tbl_variant "server-log only" "restint sort=0:1")"$'\n'"$shead_ns"$'\n'"$tot_server"
    [ -n "$bluerows" ] && blk_server+=$'\n'"$bluerows"
    blk_server+=$'\n'"NOTE"$'\t'"These entities appear in the **server logs** (runtime Transfer Manager messages) but never in the transfer logs — the Server → Transfer step (bin/build/seen-in-server-log.sh) marked them **blue** (result=blue) so they surface here. They are what the **+Server** scope adds to Seen; under the **Transfer** scope they count as never seen. Each name links to its detail page."
    blk_server=$(printf '%s\n' "$blk_server" | entities_name_only)   # Server: name column only
    local origlabel; origlabel=$(printf '%s\n' "$stotal" | cut -f2)
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
    entity_res_block() {   # $1 = green|orange|red   $2 = the All-view rows to filter
        printf '%s\n' "$2" | LC_ALL=C awk -F'\t' -v OFS='\t' -v want="@data:res=$1" -v lbl="$origlabel" '
            function human(b,   u,i,v){ split("B KB MB GB TB PB",u," "); i=1; v=b+0
                while (v>=1024 && i<6) { v/=1024; i++ }
                return (i==1)?sprintf("%d %s",v,u[i]):sprintf("%.2f %s",v,u[i]) }
            $1=="ROW" {
                hit=0; for (i=1;i<=NF;i++) if ($i==want) hit=1
                if (!hit) next
                f=$3; gsub(/[^0-9]/,"",f); e=$4; gsub(/[^0-9]/,"",e); o=$5; gsub(/[^0-9]/,"",o)
                sf+=f+0; se+=e+0; so+=o+0; cnt++
                for (i=1;i<=NF;i++) if ($i ~ /^@data:buckets=/) { split(substr($i,15),B,","); for (j in B){ split(B[j],C,":"); sb+=C[5]+0 } }
                rows[++nr]=$0 }
            END {
                l=lbl; sub(/\([0-9,]+/, "(" cnt, l)
                printf "TOTAL\t%s\t@{class=num}%d\t@{class=num failed}%d\t@{class=num processed}%d\t@{class=num}%s\t\t\n", l, sf, se, so, human(sb)
                for (i=1;i<=nr;i++) print rows[i] }'
    }
    # (the "% of Files" column was removed 2026-07 — the subset views use the
    # summary header unchanged)
    local shead_subset=$shead
    local blk_ok blk_err blk_warn n_ok n_err n_warn
    n_ok="Only the entities whose site-wide RESULT is **green**: their last transfer ended OK — for a type other than subscriptions, every connected subscription's did. Rows are shown light green."
    n_err="Only the entities whose site-wide RESULT is **red**: their last transfer ended in an Error (Failed, or a staged file that Expired before pickup) — for a type other than subscriptions, at least one connected subscription's did. Rows are shown light red."
    n_warn="Only the entities whose site-wide RESULT is **orange**: never seen in this log window, or a mix of OK and Error across their connected subscriptions. Rows are shown light orange."
    blk_ok="$(tbl_variant "OK (result green)" "sort=1:-1 datereset")"$'\n'"$shead_subset"$'\n'"$(entity_res_block green "$all_rows")"$'\n'"NOTE"$'\t'"$n_ok"
    blk_err="$(tbl_variant "Error (result red)" "sort=1:-1 datereset")"$'\n'"$shead_subset"$'\n'"$(entity_res_block red "$all_rows")"$'\n'"NOTE"$'\t'"$n_err"
    blk_warn="$(tbl_variant "Warning (result orange)" "sort=1:-1 datereset")"$'\n'"$shead_subset"$'\n'"$(entity_res_block orange "$all_rows")"$'\n'"NOTE"$'\t'"$n_warn"
    # ---- TRANSFER SCOPE: Warning -------------------------------------------
    # Retint the blue rows ORANGE (with the server log out of scope a
    # server-log-only entity is simply configured-but-never-seen, which IS
    # orange) and rebuild the orange subset from those rows, so Warning gains
    # the blue names. ONLY Seen / Not seen / Warning are scope-dependent —
    # All lists the same names either way (only the blue rows' tint would
    # differ) and no blue entity is ever green or red, so OK / Error are the
    # same set too. Those three views therefore have ONE page each, with the
    # scope tabs disabled on it (see the render loop).
    local all_rows_tr=$all_rows blk_warn_tr
    [ -n "$all_rows" ] && all_rows_tr=$(printf '%s\n' "$all_rows" | LC_ALL=C sed 's/@data:res=blue/@data:res=orange/')
    blk_warn_tr="$(tbl_variant "Warning (result orange), transfer log only" "sort=1:-1 datereset")"$'\n'"$shead_subset"$'\n'"$(entity_res_block orange "$all_rows_tr")"$'\n'"NOTE"$'\t'"Only the entities whose RESULT is **orange** with the server log OUT of scope: never seen in the transfer log in this window (server-log-only entities included), or a mix of OK and Error across their connected subscriptions. Rows are shown light orange."
    # --- Partner entity only: a Direction (connection/movement) column injected
    # as column 2, and a group-explanation icon on multi-token (merged) partner
    # names. Both are added at PUBLISH time so the .rpt — and showseen.sh /
    # entity-search.sh, which read it POSITIONALLY ($2=name,$3=Files,...) — stay
    # untouched. Injected into the COLUMN views only (the two Not seen views are
    # name-only). Connection = _partners.tsv
    # direction; Movement = the union of the partner's subscriptions' flowdir.
    local dirmapf="" grpmapf=""
    # DIRECTION for every entity: the CONNECTION/MOVEMENT pair (out/in) — the
    # same XXX/YYY the entity's detail page is titled with, so the Entities
    # views share ONE layout: Name · Direction · Files · Volume · OK · Error ·
    # Last seen. XXX = the base cache's own direction field; YYY = the union of
    # the entity's connected subscriptions' flowdir (relay counts as BOTH
    # sides), via the _<item>-subscriptions xref pair. A SUBSCRIPTION is its own
    # movement, so it reads flowdir directly. Partners were the only entity
    # showing the pair until 2026-07; this is that same computation for all
    # seven. render_rpt.awk's dirfold lowercases it.
    local _dbase="" _dsub=""
    case $name in
        account) _dbase=_accounts; _dsub=_accounts-subscriptions ;;
        subscription) _dbase=_subscriptions; _dsub=SELF ;;
        login) _dbase=_logins;    _dsub=_logins-subscriptions ;;
        remote-host) _dbase=_hosts; _dsub=_hosts-subscriptions ;;
        logical) _dbase=_logicals; _dsub=_logicals-subscriptions ;;
        partner) _dbase=_partners; _dsub=_partners-subscriptions ;;
        application) _dbase=_apps; _dsub=_apps-subscriptions ;;
        domain) _dbase=_domains;  _dsub=_domains-subscriptions ;;
        bl) _dbase=_bl;           _dsub=_bl-subscriptions ;;
    esac
    if [ -n "$_dbase" ] && [ -f "$DATA/flow-manager/base/$_dbase.tsv" ]; then
        local _ebase="$DATA/flow-manager/base/$_dbase.tsv"
        local _sfd="$DATA/flow-manager/xref/_subscriptions-flowdir.tsv"
        local _esub="$DATA/flow-manager/xref/$_dsub.tsv"
        dirmapf=$(mktemp "${TMPDIR:-/tmp}/edir.XXXXXX")
        # A SUBSCRIPTION is its own movement, so flowdir alone feeds both rules
        # — do NOT pass that file twice, the FILENAME==sfd rule would swallow
        # the second copy and every subscription would come out "out/?".
        if [ "$_dsub" = SELF ]; then _esub=""; fi
        if [ -f "$_sfd" ] && { [ -z "$_esub" ] || [ -f "$_esub" ]; }; then
            LC_ALL=C awk -F'\t' -v OFS='\t' -v sfd="$_sfd" -v esub="$_esub" -v ebase="$_ebase" '
                function side(s, k) { if(s=="relay"){hi[k]=1;ho[k]=1} else if(s=="in")hi[k]=1; else if(s=="out")ho[k]=1 }
                FILENAME==sfd  { fd[$1]=$2; if (esub=="") side($2, $1); next }        # subscription -> in|out|relay
                FILENAME==esub { side(fd[$2], $1); next }                            # entity -> its subscriptions
                FILENAME==ebase{ mv=(hi[$1]&&ho[$1])?"both":(hi[$1]?"in":(ho[$1]?"out":"?"))
                                 print toupper($1), ($2==""?"?":$2) "/" mv }
            ' "$_sfd" ${_esub:+"$_esub"} "$_ebase" > "$dirmapf" 2>/dev/null || : > "$dirmapf"
        else
            LC_ALL=C awk -F'\t' -v OFS='\t' '$1 != "" { print toupper($1), ($2 == "" ? "-" : $2) }' \
                "$_ebase" > "$dirmapf" 2>/dev/null || : > "$dirmapf"
        fi
    fi
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
        : # (inject_dir_col and entity_layout are defined below, for every entity)
    fi
    inject_dir_col() {   # stdin .rpt block -> Direction inserted as column 2
            LC_ALL=C awk -F'\t' -v OFS='\t' -v mapf="$dirmapf" '
                BEGIN { while((getline l<mapf)>0){ split(l,a,"\t"); dm[a[1]]=a[2] } close(mapf) }
                function shift3(v,   i,out){ out=$1 OFS $2 OFS v; for(i=3;i<=NF;i++) out=out OFS $i; return out }
                # The TABLE line carries modifiers, not cells — it must not be
                # shifted, but a sort=COL:DIR pointing at a column at or after
                # the insertion point (display column 1) has to follow the data
                # one place right, or Files-descending would sort Direction.
                $1=="TABLE"  { for (i=3; i<=NF; i++)
                                   if ($i ~ /^sort=[0-9]+:/) {
                                       split(substr($i,6), sp, ":")
                                       if (sp[1]+0 >= 1) $i = "sort=" (sp[1]+1) ":" sp[2] }
                               print; next }
                $1=="HEAD"   { print shift3("Direction"); next }
                $1=="KIND"   { print shift3("text"); next }
                $1=="RECALC" { print shift3("-"); next }
                $1=="TOTAL"  { print shift3(""); next }
                $1=="ROW"    { nm=$2; sub(/^@\{[^}]*\}/,"",nm); print shift3((toupper(nm) in dm)?dm[toupper(nm)]:""); next }
                { print }'
        }
    # ONE LAYOUT for every Entities view (2026-07):
    #   Name · Direction · Files · Volume · OK · Error · Last seen
    # inject_dir_col puts Direction in as column 2; entity_layout then reorders
    # the four figure columns (the .rpt carries Files·Error·OK·Volume), DROPS
    # First seen and keeps Last seen. RECALC tokens travel with their column —
    # they name a bucket metric, not a position — and the trailing @data: cells
    # (buckets, drills, seen, res) ride along untouched at the end of each ROW.
    # STRIP=1 keeps only Name · Direction: the views whose figures are blank by
    # construction — Not seen, Server, and Warning on SUBSCRIPTIONS, where
    # orange means never seen (for the other entities it means a connected
    # subscription is unseen, so their own figures are real).
    entity_layout() {   # $1 = 1 to strip the five figure columns
        LC_ALL=C awk -F'\t' -v OFS='\t' -v strip="${1:-0}" '
            function tail(from,   i, out) { out = ""; for (i = from; i <= NF; i++) out = out OFS $i; return out }
            function reord(   out, i) {
                if (NF < 9) return $0
                if (strip == 1) out = $1 OFS $2 OFS $3
                else            out = $1 OFS $2 OFS $3 OFS $4 OFS $7 OFS $6 OFS $5 OFS $9
                for (i = 10; i <= NF; i++) out = out OFS $i     # @data: cells
                return out
            }
            $1=="TABLE" { for (i = 3; i <= NF; i++)
                              if ($i ~ /^sort=[0-9]+:/) {        # Files stays column 2
                                  split(substr($i,6), sp, ":")
                                  if (strip == 1) $i = "sort=0:asc"; else if (sp[1]+0 >= 2) $i = "sort=2:" sp[2] }
                          print; next }
            $1=="HEAD" || $1=="KIND" || $1=="RECALC" || $1=="ROW" || $1=="TOTAL" { print reord(); next }
            { print }'
    }
    for _b in blk_all sumblk_tinted blk_ok blk_warn blk_err blk_seen_tr blk_warn_tr blk_ns blk_ns_tr blk_server; do
        eval "[ -n \"\${$_b:-}\" ] || continue"
        eval "$_b=\$(printf '%s\\n' \"\$$_b\" | inject_dir_col)"
    done
    # the figure columns: kept everywhere except the blank-by-construction views
    local _strip_warn=0; [ "$name" = subscription ] && _strip_warn=1
    blk_all=$(printf '%s\n' "$blk_all" | entity_layout 0)
    sumblk_tinted=$(printf '%s\n' "$sumblk_tinted" | entity_layout 0)
    blk_ok=$(printf '%s\n' "$blk_ok" | entity_layout 0)
    blk_err=$(printf '%s\n' "$blk_err" | entity_layout 0)
    blk_seen_tr=$(printf '%s\n' "$blk_seen_tr" | entity_layout 0)
    blk_warn=$(printf '%s\n' "$blk_warn" | entity_layout "$_strip_warn")
    blk_warn_tr=$(printf '%s\n' "$blk_warn_tr" | entity_layout "$_strip_warn")
    blk_ns=$(printf '%s\n' "$blk_ns" | entity_layout 1)
    blk_ns_tr=$(printf '%s\n' "$blk_ns_tr" | entity_layout 1)
    blk_server=$(printf '%s\n' "$blk_server" | entity_layout 1)
    # THE REASON COLUMN — the SUBSCRIPTIONS Error view only (2026-08): the
    # same per-flow Reason the home page's two red tables show, resolved by
    # the same chain (bin/build/publish.sh write_failing_now): the flow's
    # NEWEST red failed-sub-all row keeps ITS OWN verdict — the one baked into
    # the error page that home row opens — unless the flow is server-reddened
    # (blue/_redflip.tsv, home table 2's set); else the classified newest
    # server E line (_kaput-evidence.tsv through the shared
    # bin/flip-reason.awk); else the most specific box (_subs-boxes.tsv).
    # Appended AFTER Last seen, before the @data cells, so every baked column
    # index — and the ?axway_sort= links into these pages — stay put.
    # _subs-boxes.tsv is written by the LATER analyses publish, so a
    # box-FALLBACK reason can lag one build (fresh data/ included); the two
    # primary sources are report-stage and always current.
    if [ "$name" = subscription ] && [ -n "$blk_err" ]; then
        local _lfr="$DATA/$area/reports/failed-sub-all.rpt" _kap="$DATA/server/reports/_kaput-evidence.tsv"
        local _box="$DATA/analyses/reports/_subs-boxes.tsv" _rfl="$DATA/blue/_redflip.tsv" _reasonf
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
            # the failed-sub-all row is Subscription / Date/time / Reason
            # since 2026-08 — the CoreId page lives only in the @data:href
            # cell, and a server-failing row carries @data:srv=1 (the END
            # srvslug entries cover those)
            $1 == "ROW" {
                red = 0; srv = 0; pg = ""
                for (i = 2; i <= NF; i++) {
                    if ($i == "@data:res=red") red = 1
                    if ($i == "@data:srv=1") srv = 1
                    if (index($i, "@data:href=../errors/") == 1) pg = substr($i, 22)
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
        blk_err=$(printf '%s\n' "$blk_err" | LC_ALL=C awk -F'\t' -v OFS='\t' -v mapf="$_reasonf" '
            BEGIN { while ((getline l < mapf) > 0) { n = split(l, a, "\t")
                        u = toupper(a[1]); rm[u] = a[2]
                        rk[u] = (n >= 3) ? a[3] : ""; rc[u] = (n >= 4) ? a[4] : "" }
                    close(mapf) }
            # insert v as the display column after Last seen (field 8; the
            # trailing @data cells start at field 9 and ride along)
            function ins(v,   out, i) {
                out = $1
                for (i = 2; i <= 8; i++) out = out OFS (i <= NF ? $i : "")
                out = out OFS v
                for (i = 9; i <= NF; i++) out = out OFS $i
                return out
            }
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
                                 v = "@{href=../../errors/" rc[u] ".html}" v
                             else if (v != "")
                                 v = "@{alink=subscriptions/" nm "}" v
                             print ins(v); next }
            { print }')
        rm -f "$_reasonf"
    fi
    # The views. THREE are scope-dependent (dual=1: Seen / Not seen / Warning)
    # and render a second, "-transfer" page; All / OK / Error list the same
    # names in either scope, so they get ONE page whose scope tabs are DISABLED
    # (state 2 — dimmed, unlinked, neither selected). fil_trf of a single view
    # is its bare page, so a view tab clicked FROM a -transfer page lands on the
    # one page that exists. SERVER (srvonly=1) is a view of the +Server scope
    # ALONE: one page, listed LAST in the view row of every non-transfer page
    # and absent from the -transfer ones (in that scope its names are just never
    # seen), its own page showing +Server active and Transfer disabled.
    local labs=("All" "Seen" "Not seen" "OK" "Warning" "Error" "Server") \
          dual=(0 1 1 0 1 0 0) \
          srvonly=(0 0 0 0 0 0 1) \
          blk_srv=("$blk_all" "$sumblk_tinted" "$blk_ns" "$blk_ok" "$blk_warn" "$blk_err" "$blk_server") \
          blk_trf=("" "$blk_seen_tr" "$blk_ns_tr" "" "$blk_warn_tr" "" "")
    local nview=6   # last index of labs
    local fil_srv=() fil_trf=() i j s a vs nav prow1 tmp views scopes blkc outf
    for i in $(seq 0 $nview); do
        vs=$(slugify "${labs[$i]}")
        fil_srv[$i]="$name-$vs.html"
        if [ "${dual[$i]}" = 1 ]; then fil_trf[$i]="$name-$vs-transfer.html"; else fil_trf[$i]="$name-$vs.html"; fi
    done
    # The group (member) row is built for the current VIEW; on a Transfer-scope
    # page every one of its hrefs moves to that scope's page, so switching
    # entity keeps BOTH the view and the scope. Only ever applied on a dual
    # view, whose every member page has a -transfer twin.
    scope_hrefs_tr() { LC_ALL=C awk -F'\t' -v OFS='\t' '{ for (i=2;i<=NF;i++) sub(/\.html$/, "-transfer.html", $i); print }'; }
    local saved_dl=${DLINK_BASE:-}
    DLINK_BASE="../../details/"
    # render_rpt reads GRPICON_MAP (partner group name -> slug) to draw the icon;
    # empty for every non-partner entity, so no other page gets one.
    local GRPICON_MAP="$grpmapf"
    mkdir -p "$DOCS/$area/entities"
    for i in $(seq 0 $nview); do
        for s in 0 1; do        # 0 = +Server (default), 1 = Transfer
            [ "$s" = 1 ] && [ "${dual[$i]}" != 1 ] && continue   # one page for a scope-independent view
            # Row: entity members | All Seen Not-seen OK Warning Error [Server] | Transfer +Server
            views=""
            for j in $(seq 0 $nview); do
                # the Server view belongs to the +Server scope only
                [ "${srvonly[$j]}" = 1 ] && [ "$s" = 1 ] && continue
                a=0; [ "$j" = "$i" ] && a=1
                if [ "$s" = 0 ]; then views+=$'\t'"$a|${labs[$j]}|${fil_srv[$j]}"
                else                   views+=$'\t'"$a|${labs[$j]}|${fil_trf[$j]}"; fi
            done
            if [ "${srvonly[$i]}" = 1 ]; then
                # the Server view exists only under +Server: that tab is the
                # active one, Transfer is dimmed (no such page in that scope)
                scopes=$'\t'"2|Transfer|"$'\t'"1|+Server|${fil_srv[$i]}"
                blkc=${blk_srv[$i]}; outf=${fil_srv[$i]}
            elif [ "${dual[$i]}" != 1 ]; then
                # scope-independent view: both tabs dimmed, neither selected
                scopes=$'\t'"2|Transfer|"$'\t'"2|+Server|"
                blkc=${blk_srv[$i]}; outf=${fil_srv[$i]}
            elif [ "$s" = 0 ]; then
                scopes=$'\t'"0|Transfer|${fil_trf[$i]}"$'\t'"1|+Server|${fil_srv[$i]}"
                blkc=${blk_srv[$i]}; outf=${fil_srv[$i]}
            else
                scopes=$'\t'"1|Transfer|${fil_trf[$i]}"$'\t'"0|+Server|${fil_srv[$i]}"
                blkc=${blk_trf[$i]}; outf=${fil_trf[$i]}
            fi
            nav="NAV${views}"$'\t@sep'"${scopes}"
            prow1=$(group_nav_row "$area" "$name" "${labs[$i]}")
            [ "$s" = 1 ] && [ -n "$prow1" ] && prow1=$(printf '%s' "$prow1" | scope_hrefs_tr)
            [ -n "$prow1" ] && nav="${prow1}"$'\t@sep\t'"${nav#NAV$'\t'}"
            tmp=$(mktemp "${TMPDIR:-/tmp}/rpt.XXXXXX")
            { _hdr_with_nav "$HEADER" "$nav"; printf '%s\n' "$blkc"; printf '%s' "$FOOTER"; } > "$tmp"
            render_rpt "$tmp" "$DOCS/$area/entities/$outf" "../../assets/style.css" "../index.html" "$rlabel" 1 "$hslug" "$rkey"
            rm -f "$tmp"
        done
    done
    DLINK_BASE=$saved_dl
    [ -n "$dirmapf" ] && rm -f "$dirmapf"
    [ -n "$grpmapf" ] && rm -f "$grpmapf"
    return 0
}

# Render one report — single page, or split into per-table pages with a tab bar.
# Grouped reports get an extra top NAV row switching between the group's reports.
# Entity Search ships its rows as DATA, not as 7,465 <tr> in the page: the
# table is invisible until a query is typed (style.css hides every row of a
# data-start-empty table) and a typical query matches ~100 names, so parsing
# 45,000 DOM nodes up front bought nothing. This lifts the rendered data rows
# out of search.html into search-data.js as [name, type, rowHTML] triples and
# leaves the page with an empty table; report.js (esBuild) inserts the matching
# rows on each query, so the DOM holds only what is on screen.
#
# The rowHTML is the row EXACTLY as render_rpt wrote it — the links, classes,
# tints, data-seen/data-res and the 38 data-subrows payloads all survive
# untouched, which is why the built rows behave identically to the baked ones.
# A no-JS visitor loses nothing: the rows were already display:none for them.
split_search_rows() {   # $1 rendered search.html  $2 data file to write
    local page=$1 data=$2 tmp="$1.tmp.$$"
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
        printf 'window.AXWAY_SEARCH=`\n'
        cat "$data.rows"
        printf '`;\n'
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
    # Top-bar right text: "TRANSFER"/"SERVER" + this report's index-entry name.
    local rlabel; rlabel="$(printf '%s' "$area" | tr '[:lower:]' '[:upper:]') - $(entry_label "$area" "$name")"
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
    case $name in cross-*|entity-search|seen-in-server-log|entity-coverage|entity-coverage-*|sources-and-targets|skipped|skipped-*) CUR_DATES="" ;; esac
    # The Entities reports have their own four-page renderer (see above).
    case $name in
        account|login|subscription|remote-host|logical|partner|application|domain|bl)
            render_entity_report "$area" "$name" "$rpt" "$rlabel" "$hslug" "$rkey"
            CUR_DATES=$saved_dates
            return ;;
        entity-search)
            # published at the ENV ROOT as search.html — css depth 0, entity
            # links into details/ from the env root
            local saved_dl=${DLINK_BASE:-}
            DLINK_BASE="details/"
            render_rpt "$rpt" "$DOCS/search.html" "assets/style.css" "index.html" "$rlabel" 1 "$hslug" "$rkey"
            DLINK_BASE=$saved_dl
            split_search_rows "$DOCS/search.html" "$DOCS/search-data.js"
            CUR_DATES=$saved_dates
            return ;;
    esac
    # The Subscriptions analyses group: the DATA is this area's, the PAGE lives
    # in docs/<env>/analyses/ (same depth as the area dirs, so every relative
    # prefix is unchanged -- only the directory moves). group_of returns "" for
    # them, so row1 is empty and analyses_grouprow_for supplies the tab bar.
    local pagedir=$area
    if is_subs_report "$name"; then pagedir=analyses; fi   # if, not && — set -e
    local row1; row1=$(group_nav_row "$area" "$name")
    local labels; labels=$(report_tabs "$name")
    if [ -z "$labels" ]; then
        if [ -z "$row1" ]; then
            render_rpt "$rpt" "$DOCS/$pagedir/$name.html" "../assets/style.css" "index.html" "$rlabel" 1 "$hslug" "$rkey"
        else
            segment_rpt "$rpt"   # grouped single-page report: inject the group row, keep EVERY table
            # A report-emitted NAV (e.g. Duration's "OK transfers / All transfers"
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
        analyses_grouprow_for "$area" "$name"   # analyses group tab bar for entity-coverage/seen-in-server-log/skipped
        skipped_grouprow_for "$area" "$name"    # Skipped pages: the per-value button row, BELOW the intro prose
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
    # merge_rpt no-data stub and its page renders instead of 404ing.
    while [ "$NTAB" -lt "${#laba[@]}" ]; do
        NTAB=$((NTAB+1))
        TBLOCK[$NTAB]=$'TABLE\t\nNOTE\tThis view has no data in this environment.'
    done
    local i j files=() lbl
    for ((i=1; i<=NTAB; i++)); do
        lbl=${laba[$((i-1))]:-Table $i}
        files[$i]="$name-$(slugify "$lbl").html"
    done
    # The cross-reference pages are an ANALYSES feature, so they live in
    # docs/<env>/analyses/xref/ (same depth as the old transfer/xref/, so the
    # css/home/detail-link paths are unchanged — only the directory moves). They
    # are still rendered here in the transfer loop (area=transfer), so the write
    # path goes up-and-over via outsub. The in-page NAV hrefs are bare filenames.
    local outsub="" pcss="../assets/style.css" phome="index.html" saved_dl=${DLINK_BASE:-}
    case $name in cross-*)
        outsub="../analyses/xref/"; pcss="../../assets/style.css"; phome="../index.html"
        DLINK_BASE="../../details/"; mkdir -p "$DOCS/analyses/xref" ;;
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
            self=$(member_label "$name")                 # the page's first entity, e.g. "Account"
            # Row 1 — first entity: current member active; the member matching
            # the second entity disabled; the rest keep the same second-entity
            # tab (it exists on every other member, only the disabled one lacks it).
            prow1="NAV"
            for m in $(group_members cross); do
                ml=$(member_label "$m")
                if [ "$m" = "$name" ]; then prow1+=$'\t'"1|$ml|"
                elif [ "$ml" = "$cur2" ]; then prow1+=$'\t'"2|$ml|"
                else prow1+=$'\t'"0|$ml|$(member_page_for_label "$m" "$cur2")"
                fi
            done
            # Row 2 — second entity: all 8 in the same order (this member's tab
            # list is that order minus itself); the page's own entity disabled.
            nav="NAV"; e2=0
            for m in $(group_members cross); do
                ml=$(member_label "$m")
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
            for m2 in $(group_members cross); do
                [ "$(member_label "$m2")" = "$cur2" ] || continue
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
        # rule row — it has to live there to be per-entity) merges onto the
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
        # "Configuration" row that analyses_grouprow_for injects after the
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
        render_rpt "$tmp" "$DOCS/$pagedir/$outsub${files[$i]}" "$pcss" "$phome" "$rlabel" 1 "$hslug" "$rkey"
        rm -f "$tmp"
    done
    analyses_grouprow_for "$area" "$name"   # analyses group tab bar for the cross-reference pages
    DLINK_BASE=$saved_dl
    CUR_DATES=$saved_dates
}

# ---- the Subscriptions analyses group ---------------------------------------
# Called by bin/analyses/publish.sh, NOT by the area publishes: those run first
# and bin/analyses/publish.sh clears docs/<env>/analyses/*.html, so anything they
# wrote there would be deleted again. Each member renders from its own area's
# .rpt (render_report's pagedir sends the page to analyses/), or gets an
# empty-report placeholder when this env has no data for it — the same contract
# render_missing_reports gives the area reports.
render_subs_group_pages() {
    local spec area name rpt n=0 miss=0 saved=${CUR_DATES:-}
    for spec in $SUBS_GROUP_REPORTS; do
        area=${spec%%:*}; name=${spec#*:}
        rpt="$DATA/$area/reports/$name.rpt"
        # analyses-area members (2026-08): .rpt in data/<env>/analyses/reports/,
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
    printf 'Rendered %d Subscriptions group page(s) into docs/%s/analyses/' "$n" "$SITE_ENV" >&2
    [ "$miss" -gt 0 ] && printf ' (+%d empty-report placeholder(s))' "$miss" >&2
    printf '.\n' >&2
}

# One empty-report placeholder for a Subscriptions member with no .rpt in this
# env, carrying the analyses group tab bar so the group stays navigable.
_subs_placeholder() {   # $1 area  $2 name
    local area=$1 name=$2 fp out title html labels lbl pages pg
    fp=$(first_page "$name")
    title=$(member_label "$name"); [ -n "$title" ] || title=$(entry_label "$area" "$name")
    # h1 FIRST, then the group tab bar, then the prose — the same order the
    # rendered members get from _inject_after_h1 "above"
    html=""; if is_subs_report "$name"; then html=$(analyses_group_tabs_ctx "$fp" analyses) || html=""; fi
    # a TABBED member (uc-status) needs a placeholder for EVERY tab page —
    # other pages link the sibling tabs directly (a boxes explanation links
    # uc-status-uc3.html), and only stubbing the first left those links
    # broken in an env without the data (production 2026-08)
    pages="$fp"
    labels=$(report_tabs "$name")
    if [ -n "$labels" ]; then
        pages=""
        while IFS= read -r lbl; do
            [ -n "$lbl" ] && pages="$pages $name-$(slugify "$lbl").html"
        done <<< "$(printf '%s' "$labels" | tr '|' '\n')"
    fi
    for pg in $pages; do
        out="$DOCS/analyses/$pg"
        {
            html_head "$title" "../assets/style.css" "" "" "$(help_slug_for "$area" "$name")" "$area" "$name"
            esc "$title"; printf '<h1>%s</h1>\n' "$ESC"
            [ -n "$html" ] && printf '%s\n' "$html"
            printf '<p class="range">This report has <strong>no data in this environment</strong> — the log lines or configuration it reads are absent, so its report file was not produced. The report exists in the other environment when its data does; use the environment switch in the top bar.</p>\n'
            printf '</body>\n</html>\n'
        } > "$out"
    done
}

# ---- index helpers (shared by bin/build/publish.sh and the top-bar menus) ---------

# area_entries AREA NAME... — emit one "disp<TAB>desc<TAB>page" line per index
# entry for an area's ordered basenames: grouped reports collapse to a single
# line at their leader (group_label/group_desc), the rest use TITLE/DESC with the
# few label overrides. Shared by the index table and the top-bar dropdowns.
# entry_label AREA NAME — the label a report shows on its area index (grouped ->
# the group label; else its TITLE with the few index overrides). Also the name
# used in the top-bar right text, so the two never drift.
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
    case $name in
        day) echo "Day" ;;
        unknown-sites) echo "Missing subscriptions" ;;
        unknown-accounts) echo "Missing accounts" ;;
        unknown-hosts) echo "Missing hosts" ;;
        unknown-whitelisting) echo "Missing whitelist IPs" ;;
        unknown-logins) echo "Missing logins" ;;
        *) t=${t#Transfer }; echo "${t% Counts}" ;;
    esac
}
area_entries() {
    # NO existence filter (2026-07): the menus give ALL options in every env —
    # a report whose .rpt is absent here still gets its line (and an
    # empty-report placeholder page, render_missing_reports), so both envs'
    # menus are IDENTICAL and the shared assets/topbar-data.js is
    # env-independent.
    local area=$1; shift
    local name rpt d disp href g firstm
    for name in "$@"; do
        rpt="$DATA/$area/reports/$name.rpt"
        g=$(group_of "$area" "$name")
        if [ -n "$g" ]; then
            firstm=$(group_members "$g"); firstm=${firstm%% *}
            [ "$name" = "$firstm" ] || continue
            d=$(group_desc "$g"); href=$(group_home "$g")
        else
            d=""; [ -f "$rpt" ] && d=$(field1 DESC "$rpt")
            href=$(first_page "$name")
        fi
        disp=$(entry_label "$area" "$name")
        printf '%s\t%s\t%s\n' "$disp" "$d" "$href"
    done
}

# build_menu AREA NAME... — the top-bar dropdown links for an area; the href
# carries a leading "@" placeholder for the page's base prefix (html_head swaps
# "@" for the depth-appropriate "../…" so one precomputed string serves all pages).
build_menu() {
    local area=$1; shift
    local disp d href
    printf '<a class="ddtop" href="@%s/index.html">Start page</a>' "$area"   # -> the area index
    area_entries "$area" "$@" | while IFS=$'\t' read -r disp d href; do
        esc "$disp"; printf '<a href="@%s/%s">%s</a>' "$area" "$href" "$ESC"
    done
}

# Top-bar dropdown link lists (built once; html_head swaps the "@" base prefix
# per page). Every rendered page — reports, details, indexes — needs these, so
# they are computed here at source time. Cross References lives in its own
# "Analyses" dropdown (the 4th menu) and Entity Search behind the top-bar
# quick-search box, so the Transfer list skips both; the transfer index page
# still lists them.
transfer_menu_order=()
for _n in "${transfer_order[@]}"; do
    if is_subs_report "$_n"; then continue; fi   # the Subscriptions analyses group
    if is_boxes_only "$_n"; then continue; fi   # boxes-only: reached from the two Boxes pages, not the menu
    case $_n in cross-*|entity-search|seen-in-server-log|entity-coverage|entity-coverage-ok|entity-coverage-once|entity-coverage-diff|sources-and-targets|duration-all|duration-minmax|duration-all-minmax|skipped|not-in-flow-manager|missing-cronjobs) ;; *) transfer_menu_order+=("$_n") ;; esac
done
TRANSFER_MENU=$(build_menu transfer "${transfer_menu_order[@]}")
# The Analyses dropdown shows one line per GROUP (like the transfer/server
# menus); each line lands on its group's leader page, whose row-1 tab bar
# (analyses_group_tabs below) navigates within the group.
ANALYSES_MENU='<a class="ddtop" href="@analyses/index.html">Start page</a><a href="@transfer/entity-coverage-accounts.html">Coverage &amp; seen</a><a href="@analyses/use-cases.html">Configuration</a><a href="@analyses/partner-scorecard.html">Partners</a><a href="@analyses/accounts-in-boxes.html">Boxes</a><a href="@analyses/failed.html">Errors</a><a href="@analyses/acc-vs-prod-summary.html">Acceptance vs production</a>'

# The analyses report GROUPS — the single source of truth for the group tab
# bars, the group-of lookup and the h1 group tags. One line per group:
#   <group label>|<key1>=<Label1>|<key2>=<Label2>|...
# Keys are hrefs relative to docs/<env>/analyses/ (the transfer-area members —
# partner coverage, seen-in-server-log, skipped, cross references — carry a
# ../transfer/ prefix). Acceptance-vs-production keeps its own tab rows and is
# not listed. KEEP IN SYNC with ANALYSES_MENU and the analyses index/sitemap.
_analyses_groups() {
    printf '%s\n' \
        "Coverage & seen|../transfer/entity-coverage-accounts.html=Entity coverage|first-seen.html=First seen|data-diff.html=Since yesterday|../file-search-24-hours.html=File search|../transfer/seen-in-server-log.html=Seen in server log" \
        "Configuration|use-cases.html=Use cases|uc2-visits.html=UC2 pickup visits|subscriptions.html=Subscriptions|accounts.html=Accounts|account-sharing.html=Account sharing|twins.html=Twins|cronjobs.html=Cronjobs|config-hygiene.html=Config hygiene|whitelist-audit.html=Whitelist audit|cleanup-backlog.html=Cleanup backlog|../transfer/sources-and-targets.html=Sources and Targets|../transfer/skipped.html=Skipped|../transfer/not-in-flow-manager.html=Not in Flow Manager|$(group_home cross)=Cross References" \
        "Partners|partner-scorecard.html=Partner scorecard|blast-radius.html=Blast radius|app-partners.html=Application dependencies|partner-lifecycle.html=Partner lifecycle" \
        "Boxes|accounts-in-boxes.html=Accounts in boxes|subscriptions-in-boxes.html=Subscriptions in boxes|triage.html=Triage" \
        "Errors|failed.html=Failed Subscriptions|failing-reasons.html=Error reasons"
}
# _analyses_group_of CUR -> the group line ("label|key=Label|…") whose member
# keys include CUR; non-zero exit when CUR is not an analyses group member.
_analyses_group_of() {
    local cur=$1 line
    while IFS= read -r line; do
        case "|${line#*|}" in *"|$cur="*) printf '%s' "$line"; return 0 ;; esac
    done < <(_analyses_groups)
    return 1
}
# _agr_href HREF CTX — rewrite an analyses-relative group href for the page's
# location: analyses (as-is), transfer (a docs/<env>/transfer/ page) or xref
# (a docs/<env>/analyses/xref/ cross page). The cross href is analyses-relative
# ("xref/cross-…") since the cross pages moved under analyses/.
_agr_href() {
    local h=$1 ctx=$2
    case $ctx in
        transfer)
            case $h in
                ../transfer/*) printf '%s' "${h#../transfer/}" ;;
                *)             printf '../analyses/%s' "$h" ;;
            esac ;;
        xref)
            case $h in
                xref/*)        printf '%s' "${h#xref/}" ;;
                ../transfer/*) printf '../../transfer/%s' "${h#../transfer/}" ;;
                *)             printf '../%s' "$h" ;;
            esac ;;
        *) printf '%s' "$h" ;;
    esac
}
# analyses_group_tabs_ctx CUR CTX -> the <p class="tabs"> group bar for CUR's
# group, hrefs rewritten for CTX; "" (non-zero) when CUR is ungrouped.
analyses_group_tabs_ctx() {
    local cur=$1 ctx=$2 found; found=$(_analyses_group_of "$cur") || return 1
    local members=${found#*|} out="" e href lbl rh IFS='|'
    # a SINGLE-member group gets NO member row — a lone active chip says
    # nothing (the same rule group_nav_row applies)
    case $members in *"|"*) ;; *) return 1 ;; esac
    for e in $members; do
        href=${e%%=*}; lbl=${e#*=}
        if [ "$href" = "$cur" ]; then out+="<span class=\"tab active\">$lbl</span>"
        else rh=$(_agr_href "$href" "$ctx"); out+="<a class=\"tab\" href=\"$rh\">$lbl</a>"; fi
    done
    printf '<p class="tabs">%s</p>' "$out"
}
# analyses_group_tabs CURRENT — the row-1 group tab bar for an analyses-area
# page (hrefs as-is); "" when CURRENT is ungrouped. The transfer-area members
# get theirs injected by render_report (analyses_grouprow_for).
analyses_group_tabs() {
    local o; o=$(analyses_group_tabs_ctx "$1" analyses) || return 0
    printf '%s\n' "$o"
}
# analyses_grouprow_for AREA NAME — inject the analyses group tab bar after the
# <h1> of a transfer-area analyses member's rendered page(s) (the members whose
# pages render in docs/<env>/transfer/ via render_report, so they can't call
# analyses_group_tabs at write time like the analyses-area pages do).
analyses_grouprow_for() {
    local area=$1 name=$2 cur ctx html f
    case $name in
        # A report belongs to exactly ONE group. These six are analyses
        # "Coverage & seen" / "Configuration" members whose PAGE happens to
        # render into docs/<env>/transfer/, so group_of returns "" for them and
        # the analyses row injected here is their only group row.
        entity-coverage|entity-coverage-ok|entity-coverage-once|entity-coverage-diff)
                                                      cur="../transfer/entity-coverage-accounts.html"; ctx=transfer ;;   # TABBED: the group key is the FIRST page of the DEFAULT rule, so every rule view marks the group tab active
        seen-in-server-log|sources-and-targets|skipped|not-in-flow-manager|missing-cronjobs) cur="../transfer/$name.html"; ctx=transfer ;;
        skipped-*)                                    cur="../transfer/skipped.html"; ctx=transfer ;;
        uc-status)                                    cur="use-cases.html"; ctx=analyses ;;   # 2026-08: a Use-cases VIEW — Configuration row with Use cases active, the view row appended below  # a per-value page: Skipped active in the Configuration group
        cross-*)                                      cur="$(group_home cross)"; ctx=xref ;;
        # The Subscriptions group: pages already IN docs/<env>/analyses/, so the
        # key is a bare filename and the hrefs need no rewriting (ctx default).
        *)  if is_subs_report "$name"; then cur="$(first_page "$name")"; ctx=analyses
            else return 0; fi ;;
    esac
    html=$(analyses_group_tabs_ctx "$cur" "$ctx") || return 0
    [ -n "$html" ] || return 0
    # UC status carries the Use-cases view row (traffic|definitions|patterns|
    # status) UNDER the group row; _ucgroup_tabs is defined by the analyses
    # publish, the only place uc-status renders
    if [ "$name" = uc-status ] && command -v _ucgroup_tabs >/dev/null 2>&1; then
        html="$html$(_ucgroup_tabs status)"
    fi
    case $name in
        cross-*) for f in "$DOCS/analyses/xref/$name-"*.html; do [ -f "$f" ] && _inject_after_h1 "$f" "$html"; done ;;
        *)  if is_subs_report "$name"; then
                # a tabbed member (pirates: Details | Top view) injects into EVERY
                # one of its pages, each with its own tab marked active
                local labels; labels=$(report_tabs "$name")
                if [ -n "$labels" ]; then
                    local IFS='|' l lf
                    for l in $labels; do
                        lf="$name-$(slugify "$l").html"
                        { [ -f "$DOCS/analyses/$lf" ] && _inject_after_h1 "$DOCS/analyses/$lf" "$html"; } || true   # a padded no-data tab may still miss its page; the LAST miss must not fail the loop
                    done
                else
                    _inject_after_h1 "$DOCS/analyses/$name.html" "$html"
                fi
            else
                # a TABBED transfer-area member (entity-coverage) has one page per
                # tab, each needing the row; a single-page one has just the one
                local tlabels; tlabels=$(report_tabs "$name")
                if [ -n "$tlabels" ]; then
                    local IFS='|' tl tf
                    for tl in $tlabels; do
                        tf="$name-$(slugify "$tl").html"
                        { [ -f "$DOCS/$area/$tf" ] && _inject_after_h1 "$DOCS/$area/$tf" "$html"; } || true
                    done
                else
                    _inject_after_h1 "$DOCS/$area/$name.html" "$html"
                fi
            fi ;;
    esac
}
# The fragment lands DIRECTLY under the </h1>, before the report's intro — the
# site-wide rule: a page's tab bars are navigation, so they sit between the
# title and the prose. See _hdr_with_nav for the same rule on the .rpt side.
# Injecting several fragments into one page puts the LAST one on top.
# Use this for a row of GROUP MEMBERS only; a row that carries none of those
# (the Skipped per-value buttons) belongs under the prose — _inject_after_intro.
_inject_after_h1() {
    local f=$1 frag=$2 tmp; [ -f "$f" ] || return 0
    tmp=$(mktemp "${TMPDIR:-/tmp}/inj.XXXXXX")
    awk -v frag="$frag" '
        done     { print; next }
        /<\/h1>/ { print; print frag; done = 1; next }
                 { print }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# Insert a one-line HTML fragment AFTER the page's intro paragraph — the
# <p class="range"> / <p class="subtitle"> the renderer writes right after the
# <h1>. The site-wide "tab bars go between the title and the prose" rule covers
# rows of GROUP MEMBERS; a row that is a per-value view switch is not that, so
# it reads better under the introduction that explains what the values are (the
# Skipped intro literally says "the buttons below give a per-value report").
# Falls back to right after the </h1> on a page with no intro.
_inject_after_intro() {
    local f=$1 frag=$2 tmp; [ -f "$f" ] || return 0
    tmp=$(mktemp "${TMPDIR:-/tmp}/inj.XXXXXX")
    awk -v frag="$frag" '
        done                           { print; next }
        /<p class="(range|subtitle)">/ { print; print frag; done = 1; next }
                                       { print }
        END { if (!done) exit 1 }       # no intro on this page — signal the fallback
    ' "$f" > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; _inject_after_h1 "$f" "$frag"; }
}

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
# The skip-list values (input/skip.txt): "TOKEN<TAB>slug" per line. The slug is
# the per-value report basename suffix (skipped-<slug>). Used by the Skipped
# button row, the report finder and the sitemap.
skipped_tokens() {
    # The VALUES of every skip rule + its page slug. Reads input/skip.txt through
    # the shared format (bin/skiplist.sh): a three-field rule contributes its
    # value (field 3), a legacy bare token itself, and "#" comments/blanks are
    # dropped — so the button row and sitemap show the rules, not the file.
    local f="${SKIPLIST_FILE:-input/skip.txt}" l s
    [ -f "$f" ] || return 0
    while IFS= read -r l || [ -n "$l" ]; do
        l=${l%$'\r'}
        case $l in \#*|"") continue ;; esac
        case $l in *"$(printf '\t')"*) l=$(printf '%s' "$l" | cut -f3) ;; esac
        l="$(printf '%s' "$l" | awk '{$1=$1; print}')"
        [ -n "$l" ] || continue
        s=$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-'); s=${s%-}; s=${s#-}
        printf '%s\t%s\n' "$l" "${s:-_}"
    done < "$f"
}
# The Skipped pages' per-value button row (All + one per skip value). $1 = the
# current value slug ("" = the All / overview page).
skipped_tabs_html() {
    local cur=${1:-} out tok slug
    [ -z "$cur" ] && out="<span class=\"tab active\">All</span>" || out="<a class=\"tab\" href=\"skipped.html\">All</a>"
    while IFS=$'\t' read -r tok slug; do
        [ -n "$slug" ] || continue
        esc "$tok"
        if [ "$slug" = "$cur" ]; then out="$out<span class=\"tab active\">$ESC</span>"
        else out="$out<a class=\"tab\" href=\"skipped-$slug.html\">$ESC</a>"; fi
    done < <(skipped_tokens)
    [ -n "$out" ] && printf '<p class="tabs">%s</p>' "$out"
}
# Inject the per-value button row into a rendered Skipped page.
skipped_grouprow_for() {
    local area=$1 name=$2 cur html
    case $name in
        skipped)   cur="" ;;
        skipped-*) cur="${name#skipped-}" ;;
        *) return 0 ;;
    esac
    html=$(skipped_tabs_html "$cur") || return 0
    [ -n "$html" ] && _inject_after_intro "$DOCS/$area/$name.html" "$html"
}
# Append " <span class=grouptag>&larr; GROUP &larr; SECTION</span>" inside the
# first <h1> of a file (idempotent — skips a page already tagged). index()/substr
# avoids awk sub()'s "&" = whole-match replacement semantics (the tag contains
# &larr;/&amp;). SECTION is the top-bar area (Transfer / Server / Analyses), so an
# h1 reads "Title &larr; Group &larr; Section".
_tag_h1() {   # $1 file  $2 group label  $3 section
    local f=$1 lbl=$2 sect=$3 tmp; [ -f "$f" ] || return 0
    grep -q 'class="grouptag"' "$f" && return 0
    esc "$lbl"; local tag=" <span class=\"grouptag\">&larr; $ESC &larr; $sect</span>"
    tmp=$(mktemp "${TMPDIR:-/tmp}/h1.XXXXXX")
    awk -v tag="$tag" '
        !done { p = index($0, "</h1>"); if (p > 0) { $0 = substr($0, 1, p-1) tag substr($0, p); done = 1 } }
        { print }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
}
# _area_group_label AREA BASENAME -> the group LABEL for a transfer/server report
# page ("" when ungrouped). A multi-page variant file (anomalies-hourly,
# failure-rate-accounts, ranking-hosts, …) is not in group_of directly, so
# strip trailing -tokens until a group is found.
_area_group_label() {   # $1 area  $2 basename
    local g b=$2
    g=$(group_of "$1" "$b")
    while [ -z "$g" ] && [[ "$b" == *-* ]]; do b=${b%-*}; g=$(group_of "$1" "$b"); done
    # a group-less page (e.g. a redirect stub) yields no label — return 0 so the
    # `lbl=$(_area_group_label ...)` caller does not abort under set -e
    if [ -n "$g" ]; then group_label "$g"; fi
}
# Tag every report h1 with its group breadcrumb "Title &larr; Group &larr;
# Section". ANALYSES runs first — some of its members live in docs/<env>/
# transfer/ (entity-coverage, seen-in-server-log, the cross pages), so they are
# claimed with "Analyses" before the transfer sweep below (idempotent, so it then
# skips them). Run AFTER every area publish (bin/build/publish.sh, per env).
tag_analyses_group_h1s() {
    local line label rest e href f b
    # Every page EXPLICITLY listed as a group member, as "|base|base|…". The
    # "<base>-*.html" variant globs below are a heuristic for a member's own tab
    # pages, and they will just as happily claim a DIFFERENT member that shares
    # the prefix: Configuration's accounts.html swallowed accounts-in-boxes.html
    # (a Boxes member), and since Configuration is listed first and
    # _tag_h1 is idempotent, the wrong crumb won and the right one silently
    # skipped. A page that is itself a listed member is never another member's
    # variant, so the globs skip it.
    local _mb
    _mb="|$(_analyses_groups | awk -F'|' '{ for (i = 2; i <= NF; i++) { split($i, a, "=") ; h = a[1]
                sub(/^.*\//, "", h); sub(/\.html$/, "", h); if (h != "") printf "%s|", h } }')"
    _tag_variants() {   # $1 glob-expanded file  $2 label — skip other members
        [ -f "$1" ] || return 0
        case "$_mb" in *"|$(basename "$1" .html)|"*) return 0 ;; esac
        _tag_h1 "$1" "$2" "Analyses"
    }
    while IFS= read -r line; do
        label=${line%%|*}; rest=${line#*|}
        printf '%s\n' "${rest//|/$'\n'}" | while IFS= read -r e; do
            [ -n "$e" ] || continue
            href=${e%%=*}
            # a member's variant/tab pages (<base>-*.html: use-case-patterns,
            # first-seen-both, skipped-crg, …) carry the same group tag
            case $href in
                xref/*)             for f in "$DOCS/analyses/xref/"cross-*.html; do _tag_h1 "$f" "$label" "Analyses"; done ;;
                ../transfer/entity-coverage-*)
                                    # the member key is ONE rule-entity page
                                    # (entity-coverage-accounts); the other 15
                                    # rule/entity views are variants of the
                                    # FAMILY prefix, not of the member basename,
                                    # so the generic <base>-*.html glob below
                                    # would miss them — glob the family instead
                                    # (the member itself is tagged explicitly:
                                    # _tag_variants skips listed members)
                                    _tag_h1 "$DOCS/transfer/entity-coverage-accounts.html" "$label" "Analyses"
                                    for f in "$DOCS/transfer/entity-coverage-"*.html; do _tag_variants "$f" "$label"; done ;;
                ../transfer/*)      b=${href#../transfer/}; b=${b%.html}
                                    _tag_h1 "$DOCS/transfer/$b.html" "$label" "Analyses"
                                    for f in "$DOCS/transfer/$b-"*.html; do _tag_variants "$f" "$label"; done ;;
                use-cases.html)     _tag_h1 "$DOCS/analyses/use-cases.html" "$label" "Analyses"
                                    for f in "$DOCS/analyses/use-case-"*.html; do _tag_variants "$f" "$label"; done ;;
                *)                  b=${href%.html}
                                    _tag_h1 "$DOCS/analyses/$b.html" "$label" "Analyses"
                                    for f in "$DOCS/analyses/$b-"*.html; do _tag_variants "$f" "$label"; done ;;
            esac
        done
    done < <(_analyses_groups)
    # A TABBED Boxes-group member is keyed in _analyses_groups on its FIRST
    # page (pirates -> pirates-details.html), so the "<base>-*" glob above never
    # reaches its sibling tabs (pirates-top-view.html). Tag every tab page.
    local spec nm gline glabel tabs tab
    for spec in $SUBS_GROUP_REPORTS; do
        nm=${spec#*:}
        tabs=$(report_tabs "$nm"); [ -n "$tabs" ] || continue
        gline=$(_analyses_group_of "$(first_page "$nm")") || continue
        glabel=${gline%%|*}
        while IFS= read -r tab; do
            [ -n "$tab" ] || continue
            _tag_h1 "$DOCS/analyses/$nm-$(slugify "$tab").html" "$glabel" "Analyses"
        done < <(printf '%s\n' "${tabs//|/$'\n'}")
    done
    for f in "$DOCS/analyses/"acc-vs-prod-*.html; do [ -f "$f" ] || continue; _tag_h1 "$f" "Acceptance vs production" "Analyses"; done
}
tag_transfer_group_h1s() {   # the analyses members already in transfer/ are tagged; this skips them
    local f b lbl
    for f in "$DOCS/transfer/"*.html; do
        [ -f "$f" ] || continue
        b=$(basename "$f" .html); lbl=$(_area_group_label transfer "$b")
        [ -n "$lbl" ] && _tag_h1 "$f" "$lbl" "Transfer"
    done
    for f in "$DOCS/transfer/entities/"*.html; do [ -f "$f" ] || continue; _tag_h1 "$f" "Entities" "Transfer"; done
    return 0
}
tag_server_group_h1s() {
    local f b lbl
    for f in "$DOCS/server/"*.html; do
        [ -f "$f" ] || continue
        b=$(basename "$f" .html); lbl=$(_area_group_label server "$b")
        [ -n "$lbl" ] && _tag_h1 "$f" "$lbl" "Server"
    done
    return 0
}
# The Subscriptions analyses group members are dropped here the same way the
# transfer menu drops its analyses-owned reports — their pages are in the
# Analyses dropdown, not the Server one.
server_menu_order=()
for _n in ${server_order[@]+"${server_order[@]}"}; do
    if is_subs_report "$_n"; then continue; fi
    if is_boxes_only "$_n"; then continue; fi   # boxes-only: reached from the two Boxes pages, not the menu
    server_menu_order+=("$_n")
done
unset _n
SERVER_MENU=""
[ ${#server_menu_order[@]} -gt 0 ] && SERVER_MENU=$(build_menu server "${server_menu_order[@]}")
# (The graphical dashboard — bin/dashboards/publish.sh, ONE page since
# 2026-07 — is a plain top-bar link emitted by render_topbar; the former
# DASHBOARD_MENU dropdown is gone.)
# The RUNTIME top bar's menu-data version (the ?v= stamp html_head puts on
# assets/topbar-data.js): changes exactly when the menu content does, so a
# MENU change needs only a re-publish of the data file — no page re-render.
# Per-env "has a Monitor dashboard" flags for the runtime top bar: the flag IS
# the existence of that env's monitor.rpt (bin/dashboards/reports/monitor.sh
# writes it only when the transfer cache carries monitor rows). Baked into the
# SHARED topbar-data.js as a per-env map — buildTopbar shows the Monitor link
# only for an env whose flag is 1 — and folded into TB_VER so a flag flip
# re-stamps the data file's ?v=.
TB_MON_ACC=0; [ -f data/acceptance/dashboards/reports/monitor.rpt ] && TB_MON_ACC=1
TB_MON_PRD=0; [ -f data/production/dashboards/reports/monitor.rpt ] && TB_MON_PRD=1
TB_VER=$(printf '%s' "$TRANSFER_MENU$SERVER_MENU$ANALYSES_MENU$TB_MON_ACC$TB_MON_PRD" | cksum | cut -d' ' -f1)

# Copy the shared assets into docs/ and write .nojekyll. Idempotent, so each
# publish script can call it and still produce a valid site when run on its own.
# (redirect_html was REMOVED 2026-07 with every redirect stub — renamed or
# moved pages no longer keep their old URLs alive; they 404.)

ensure_assets() {
    # the assets and .nojekyll are SHARED by both env trees — they live at the
    # docs ROOT (docs/assets/), not under $DOCS (docs/<env>/); both env
    # publishes write the same bytes, so writing them is idempotent.
    # style.css / report.js / slotchart.js / file-search.js and docs/help/
    # are SEEDED from the repo-root assets/ by bin/build.sh (2026-08-29 —
    # every build clears its scope's docs tree first, so docs/ is pure build
    # output; EDIT IN assets/, a build overwrites the docs copies). Only the
    # GENERATED files below and .nojekyll are written here.
    mkdir -p docs/assets
    # the ONE file that changes every build: the footer timestamp source
    # (report.js reads window.AXWAY_BUILD and fills the "Build report"
    # anchor). Included WITHOUT a ?v= cache-buster — its content changes
    # every build, and versioning it would put the changing value back into
    # every page, defeating the point.
    # ATOMIC writes (2026-07): publishes now run CONCURRENTLY — the two
    # environments beside each other, and the report/detail pages within one —
    # so two processes write these same bytes at the same time. Same content
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
    # The runtime top bar's menu data (buildTopbar in report.js): the three
    # dropdown menu strings, env-root-relative with their "@" placeholder
    # kept verbatim (report.js swaps it for the page's data-eb prefix).
    local t=$TRANSFER_MENU s=${SERVER_MENU:-} a=${ANALYSES_MENU:-}
    t=${t//\\/\\\\}; t=${t//\"/\\\"}
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    a=${a//\\/\\\\}; a=${a//\"/\\\"}
    local _tb; printf -v _tb 'window.AXWAY_TB={transfer:"%s",server:"%s",analyses:"%s",monitor:{acceptance:%s,production:%s}};' "$t" "$s" "$a" "${TB_MON_ACC:-0}" "${TB_MON_PRD:-0}"
    _asset_put docs/assets/topbar-data.js "$_tb"
    [ -f docs/.nojekyll ] || : > docs/.nojekyll
}
