#!/usr/bin/env bash
#
# build.sh — the whole pipeline in one command (formerly all.sh): the three
# stages parse -> report -> publish run PER ENVIRONMENT (acceptance, then
# production — AXWAY_ENV exported per pass; an env without FlowManager exports
# is skipped). NO git step (removed 2026-07): the build only renders docs/ —
# committing and pushing is a separate, manual decision. Every step is timed
# and its output captured, and the run is written up as an HTML build report:
#
#   build/index.html    the report — one row per step (command, start time,
#                       duration, OK/FAILED) plus each step's captured output,
#                       rewritten on every run. It is finalized from an EXIT
#                       trap, so a FAILED or interrupted run still gets its
#                       report, with the failing step on record.
#   build/step-NN.log   the raw per-step output the report embeds.
#   (the docs/ copies — docs/build.html and the scoped docs/<env>/build.html —
#   were REMOVED 2026-08-29: the report is a LOCAL artifact only, and no page
#   on the published site references a build any more)
#
# build/ is gitignored like data/ — a per-run local artifact, safe to delete.
#
# The stages (each is a separate script):
#
#   1. parse    bin/flow-manager.sh (pre-parse: input/flow-manager/*.json -> data/flow-manager/*.tsv
#               configured entity lists), then bin/transfer/parse.sh +
#               bin/server/parse.sh tokenize the input CSVs into the gitignored
#               caches (only when stale — new/changed input or a changed parse.sh),
#               then bin/expire-files.sh (flip Waiting files whose staged copy
#               the File Maintenance sweep deleted to Expired — _files.tsv
#               cols 2/22), bin/build/seen-in-server-log.sh (mark server-log-only entities
#               BLUE in the base result column — no fake rows are injected) and
#               bin/build/result.sh (fill the remaining base results, preserving blue)
#   2. report   bin/transfer/reports.sh, then bin/server/reports.sh, then
#               bin/analyses/reports.sh + bin/dashboards/reports.sh
#               -> data/<area>/reports/*.rpt + data/coverage/*.rpt (no HTML).
#               The dependencies are ONE-way:
#               server's site-failures.sh (and a dozen more) read transfer's
#               <entity>.rpt name rosters (a TRANSFER report output) and
#               `exit 1` if missing — so server must never run before transfer
#               (the unknown-* reports read the parse cache instead and already
#               ran in stage 1, via bin/build/seen-in-server-log.sh). The analyses reports read
#               transfer outputs too (showseen.sh's coverage TSVs/METAs, the
#               detail-page slugmaps), and the dashboards reports read the
#               transfer caches + transfer/server .rpt outputs — so both run
#               after transfer and server.
#               Transfer reads nothing from the server REPORTS (its
#               detail-page server KPI comes from the server PARSE cache,
#               built in stage 1), so one pass suffices.
#   3. publish  bin/transfer/publish.sh + bin/server/publish.sh +
#               bin/analyses/publish.sh + bin/dashboards/publish.sh +
#               bin/build/publish.sh render the .rpt files into docs/ (report +
#               detail + coverage + dashboard pages), then the index pages
#               LAST (they live in dirs the per-area publish scripts clear,
#               so bin/build/publish.sh must run after them; its root Analyses and
#               Dashboards cards link the index pages those publishes write)
# (There is no git stage: commit and push docs/ manually when the result
# should go live — GitHub Pages redeploys on push.)
#
# Each step reuses the caches and skips reports whose data file is already newer
# than the inputs and scripts, so a re-run with unchanged input is fast.
#
# Usage (from any directory):
#
#   bin/build.sh        both environments — the bigger one in the foreground,
#                       the smaller beside it in the background.
#   bin/build.sh acc    ONLY acceptance, in the foreground.
#   bin/build.sh prd    ONLY production, in the foreground.
#
# Whatever the scope, the report goes to build/index.html and nowhere else
# (2026-08-29; the sitemap link and the docs/ snapshots are gone — before
# that, the footer bar's link went 2026-07). The published HTML is identical
# whichever scope built it.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ---- scope ------------------------------------------------------------------
BUILD_SCOPE=both
case "${1:-}" in
    "")                 BUILD_SCOPE=both ;;
    acc|acceptance)     BUILD_SCOPE=acceptance ;;
    prd|prod|production) BUILD_SCOPE=production ;;
    -h|--help|help)
        sed -n 's/^# \{0,1\}//; 2,/^$/p' "${BASH_SOURCE[0]}" >&2
        printf 'usage: bin/build.sh [acc|prd]\n' >&2; exit 0 ;;
    *)  printf 'bin/build.sh: unknown argument %s\n' "$1" >&2
        printf 'usage: bin/build.sh [acc|prd]   (no argument = both environments)\n' >&2
        exit 2 ;;
esac
# The report is LOCAL ONLY (2026-08-29): build/index.html, never published
# into docs/ — no page on the site references a build any more.

# ---- build lock -------------------------------------------------------------
# ONE build per checkout: the chains clear and rewrite shared trees (data/,
# docs/, build/), so two overlapping runs — a second terminal, an automation
# overlap — would interleave destructive cleanups and writes. mkdir is the
# atomic primitive (bash-3.2-safe; macOS has no flock); the owner PID is
# recorded so a lock whose holder died is reclaimed automatically instead of
# demanding a manual rm. Released by the EXIT trap (finalize_report).
BUILD_LOCK="data/.buildlock"
mkdir -p data
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    lock_pid=$(cat "$BUILD_LOCK/pid" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        printf 'bin/build.sh: another build (PID %s) is already running — refusing to overlap.\n' "$lock_pid" >&2
        exit 1
    fi
    printf 'bin/build.sh: reclaiming stale build lock (PID %s not running).\n' "${lock_pid:-unknown}" >&2
    rm -rf "$BUILD_LOCK"
    if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
        printf 'bin/build.sh: lost the lock race to another build — refusing to overlap.\n' >&2
        exit 1
    fi
fi
printf '%s\n' "$$" > "$BUILD_LOCK/pid"

# ---- CLEAR + SEED docs/ (2026-08-29, user decision) -------------------------
# Every build CLEARS its scope's docs tree and re-seeds the hand-authored
# files from the repo-root assets/ — docs/ is pure build output again, and a
# build can never leave a stale page behind. assets/ is the ONE place to
# edit style.css / report.js / slotchart.js / file-search.js and the help
# pages (see assets/README.txt); .nojekyll and topbar-data.js stay generated
# (ensure_assets). A SCOPED run clears only its env tree — the other env's
# pages and the shared root artifacts survive until their own build.
# rm -rf with a .DS_Store retry: Finder can drop one into a directory WHILE
# rm walks the tree ("Directory not empty") — sweep them and try again; the
# last attempt keeps stderr, so a genuine failure still stops the build.
clear_tree() {
    local d=$1 attempt
    for attempt in 1 2; do
        rm -rf "$d" 2>/dev/null && return 0
        find "$d" -name .DS_Store -delete 2>/dev/null || true
    done
    rm -rf "$d"
}
case $BUILD_SCOPE in
    both)       clear_tree docs ;;
    acceptance) clear_tree docs/acceptance ;;
    production) clear_tree docs/production ;;
esac
mkdir -p docs/assets docs/help
cp assets/style.css assets/report.js assets/slotchart.js assets/file-search.js docs/assets/
cp -R assets/help/. docs/help/

BUILD_DIR="build"
REPORT="$BUILD_DIR/index.html"
mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR"/step-*.log "$BUILD_DIR"/prod-step-*.log "$BUILD_DIR"/prod-steps.records

BUILD_T0=$(date +%s)
BUILD_START=$(date '+%Y-%m-%d %H:%M:%S')
STEP_N=0
STEPS=()    # one 'label|command|start|seconds|status|logfile' record per step

# seconds -> '7 s' / '4:05 min' / '1:02:03'
hms() {
    local s=$1
    if   [ "$s" -ge 3600 ]; then printf '%d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
    elif [ "$s" -ge 60 ];   then printf '%d:%02d min' $((s/60)) $((s%60))
    else printf '%d s' "$s"; fi
}

# bytes -> "12.3 GB" / "375.7 MB" / "168.2 KB". The report shows a 10 GB server
# export beside a 172 KB production one, so a fixed GB unit would print the
# example env as "0.0 GB" — the unit follows the value.
hbytes() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1073741824) printf "%.1f GB", b/1073741824
        else if (b >= 1048576) printf "%.1f MB", b/1048576
        else if (b >= 1024)    printf "%.1f KB", b/1024
        else                   printf "%d B", b }'
}
# 13349081 -> 13,349,081
hnum() { awk -v n="${1:-0}" 'BEGIN { s = sprintf("%d", n)
            while (length(s) > 3 && match(s, /[0-9][0-9][0-9][0-9]($|,)/))
                s = substr(s, 1, RSTART) "," substr(s, RSTART + 1)
            print s }'; }

# count_stats KEY FILE… -> "<files>\t<lines>\t<bytes>", CACHED.
# Counting lines means reading every byte: the acceptance server export alone is
# 10.3 GB (~6.5 s) and the parse cache 2.3 GB, which would put ~8 s on a 39 s
# no-change build purely to fill in a report line. So the answer is cached under
# a SIGNATURE of the file list (name + size + mtime): unchanged inputs are never
# re-read, and a changed one recounts that group only. It lives in data/ because
# it is derived and `rm -rf data/` must stay safe.
BUILD_STATS_DIR="data/.buildstats"
count_stats() {
    local key=$1; shift
    local cache="$BUILD_STATS_DIR/$key" sig cached f
    set -- ${1+"$@"}
    [ "$#" -gt 0 ] || { printf '0\t0\t0'; return 0; }
    sig=$(for f in "$@"; do [ -f "$f" ] && stat -f'%N %z %m' "$f"; done | cksum | cut -d' ' -f1)
    if [ -f "$cache" ]; then
        cached=$(head -1 "$cache")
        case $cached in "$sig	"*) printf '%s' "${cached#*	}"; return 0 ;; esac
    fi
    mkdir -p "$BUILD_STATS_DIR"
    local nf=0 nl=0 nb=0 l b
    for f in "$@"; do
        [ -f "$f" ] || continue
        nf=$((nf + 1))
        l=$(wc -l < "$f" | tr -d ' '); nl=$((nl + l))
        b=$(stat -f%z "$f");           nb=$((nb + b))
    done
    printf '%s\t%d\t%d\t%d\n' "$sig" "$nf" "$nl" "$nb" > "$cache"
    printf '%d\t%d\t%d' "$nf" "$nl" "$nb"
}

# HTML-escape stdin (the report embeds commands and raw step output)
esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# run_step LABEL COMMAND [ARG...] — run one step, teeing its output to
# build/step-NN.log and recording label/command/start/duration/status for the
# report. A failing step stops the build; the EXIT trap still writes the
# report, with the failure on record.
run_step() {
    local label=$1; shift
    STEP_N=$((STEP_N+1))
    local logf; logf=$BUILD_DIR/step-$(printf '%02d' "$STEP_N").log
    local start; start=$(date '+%H:%M:%S')
    printf '\n=== %d. %s ===\n' "$STEP_N" "$label" >&2
    local t0 t1 status=0
    t0=$(date +%s)
    "$@" 2>&1 | tee "$logf" || status=$?   # pipefail: tee cannot mask a failure
    t1=$(date +%s)
    # \037 (unit separator), not '|', so a step whose command legitimately
    # contains a pipe can never misalign the 6-field read in the report.
    STEPS+=("$label"$'\037'"$*"$'\037'"$start"$'\037'"$((t1-t0))"$'\037'"$status"$'\037'"$logf")
    if [ "$status" -ne 0 ]; then
        printf '*** step %d FAILED (exit %d): %s\n' "$STEP_N" "$status" "$label" >&2
        exit "$status"
    fi
}

# write_report FILE RC [NOTE] — render the report of the steps recorded so
# far. Called from the EXIT trap for the local build/index.html — on success,
# on a failed step, and on interruption, so the report always reflects the
# run. It links the site stylesheet for the standard top bar but keeps its
# own inline <style> for the rest: the page must render even when a build
# died before docs/assets/ existed.
write_report() {
    local out=$1 rc=$2 note=${3:-}
    local t1 total end
    # The Input/Cached figures are gathered BEFORE the end timestamp, so the
    # Duration row covers them. On a cold cache that is ~10 s of reading 10 GB,
    # and time the build really did take — reporting "6 s" for a 17 s run would
    # be worse than reporting the truth. With the cache warm it is ~0.
    local envs
    case $BUILD_SCOPE in
        both) envs="acceptance production" ;;
        *)    envs=$BUILD_SCOPE ;;
    esac
    local e sfiles=0 slines=0 sbytes=0 tfiles=0 tlines=0 tbytes=0
    local cslines=0 csbytes=0 ctlines=0 ctbytes=0 r a b c
    # NOTE the two-step read. `IFS=$'\t' read … <<<"$(f $(ls …))"` looks
    # equivalent and is not: the assignment is already in effect when the INNER
    # substitution is word-split, so newline stops separating and all 35 export
    # paths arrive as ONE argument — every Input figure came out 0. Globs into
    # an array instead: no ls fork, and safe for spaces.
    local -a g
    shopt -s nullglob
    for e in $envs; do
        g=("input/$e/server"/*.csv)
        r=$(count_stats "in-$e-server" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r a b c <<<"$r"
        sfiles=$((sfiles+a)); slines=$((slines+b)); sbytes=$((sbytes+c))
        g=("input/$e/transfer"/*.csv)
        r=$(count_stats "in-$e-transfer" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r a b c <<<"$r"
        tfiles=$((tfiles+a)); tlines=$((tlines+b)); tbytes=$((tbytes+c))
        g=("data/$e/server/cache/_parse.tsv")
        r=$(count_stats "cache-$e-server" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r a b c <<<"$r"
        cslines=$((cslines+b)); csbytes=$((csbytes+c))
        g=("data/$e/transfer/cache/_files.tsv")
        r=$(count_stats "cache-$e-transfer" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r a b c <<<"$r"
        ctlines=$((ctlines+b)); ctbytes=$((ctbytes+c))
    done
    shopt -u nullglob
    t1=$(date +%s); total=$((t1 - BUILD_T0)); end=$(date '+%Y-%m-%d %H:%M:%S')
    # The report carries the site's standard fixed top bar (the help pages'
    # plain-link style — no dropdown machinery, the report must render even
    # when a build died before any publish). The report's own styles below
    # scope to .buildwrap so style.css keeps the body padding that clears the
    # fixed bar; without the stylesheet (a from-scratch clone) the page still
    # renders, just with a plain bar. build/index.html sits OUTSIDE docs/, so
    # everything resolves through ../docs/.
    local base="../docs/"
    {
        cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Build report — Cloud Reports</title>
HTML
        printf '<link rel="stylesheet" href="%sassets/style.css">\n' "$base"
        cat <<'HTML'
<style>
.buildwrap{font:14px/1.5 -apple-system,"Segoe UI",Roboto,sans-serif;color:#222;max-width:64rem;margin:0 auto;padding:0 1rem}
.buildwrap h1{font-size:1.5rem}
.buildwrap h2{font-size:1.15rem;margin-top:1.6rem}
.buildwrap table{border-collapse:collapse;width:100%;margin:1rem 0;box-shadow:none}
.buildwrap th,.buildwrap td{border:1px solid #ddd;padding:.3rem .6rem;text-align:left;vertical-align:top;white-space:normal}
.buildwrap th{background:#f5f5f5;color:#222}
.buildwrap td.r{text-align:right;white-space:nowrap}
code,pre,td.cmd{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:.92em}
.ok{color:#1a7f37}
.failed{color:#c0392b;font-weight:600}
.banner{padding:.5rem .8rem;border-radius:4px;font-weight:600;margin:1rem 0}
.banner.ok{background:#e6f4ea;color:#1a7f37}
.banner.failed{background:#fdecea;color:#c0392b}
.buildwrap tr.total td{font-weight:600;background:#fafafa}
.bstats{display:flex;flex-wrap:wrap;gap:.6rem 1.4rem;margin:1rem 0}
.bstats.bsrow{flex-wrap:nowrap;overflow-x:auto;margin-top:.2rem}   /* Input/Cache/Output share ONE row */
.bs{flex:1 1 auto}
.bs h3{font-size:.8rem;text-transform:uppercase;letter-spacing:.05em;color:#667;margin:0 0 .25rem}
.bs table{margin:0;width:auto}
.bs tr{background:none}   /* style.css zebra-stripes table rows; these are 2-3 row fact blocks, not data */
.bs td{border:0;padding:.1rem .9rem .1rem 0;white-space:nowrap}
.bs td.v{font-variant-numeric:tabular-nums;padding-right:0}
.bsnote{color:#667;font-size:.92em;margin:.2rem 0 0}
details{margin:.6rem 0}
summary{cursor:pointer}
pre{background:#f8f8f8;border:1px solid #eee;padding:.6rem;overflow-x:auto;margin:.4rem 0 0}
</style>
</head>
<body>
HTML
        # Top bar: reuse the site's EXACT chrome (render_shared_topbar from
        # publish_lib.sh — env pair, dropdowns, Entities + search,
        # finder/sitemap/help icons), so the build report looks like every other
        # page. (There is no footer bar any more — removed 2026-07.) Captured in a subshell so publish_lib's cd/globals stay
        # isolated; a from-scratch clone (or a build that died before any data)
        # yields empty strings and we fall back to a plain-link bar.
        local BUILD_TB   # base-dependent, so captured per call (2 per build)
        BUILD_TB=$( AXWAY_ENV=acceptance; source bin/publish_lib.sh >/dev/null 2>&1; render_shared_topbar "$base" "index" ) || true
        local envbase="${base}acceptance/"
        if [ -n "${BUILD_TB:-}" ]; then printf '%s' "$BUILD_TB"
        else
            printf '<div class="topbar"><a class="brand" href="%sindex.html">Cloud</a><nav class="nav"><a href="%stransfer/index.html">Transfer reports</a><a href="%sserver/index.html">Server reports</a><a href="%sdashboards/index.html">Dashboards</a><a href="%sanalyses/index.html">Analyses</a></nav><span class="tr-group"><span class="tright">Build report</span></span></div>\n' \
                "$base" "$envbase" "$envbase" "$envbase" "$envbase"
        fi
        # THE TIMINGS LIVE IN THE TITLE (2026-08): start → end and the
        # duration are the h1's tail, not a fact block — the end collapses to
        # its time of day when the build stayed inside one calendar day.
        local endshow=$end
        [ "${end%% *}" = "${BUILD_START%% *}" ] && endshow=${end#* }
        printf '<div class="buildwrap">\n<h1>Build report &mdash; %s &rarr; %s &middot; %s</h1>\n' \
            "$BUILD_START" "$endshow" "$(hms "$total")"
        # THE FILE-SEARCH CAP WARNING (2026-08): file-search.sh writes
        # file-search-capped.txt when a page hit its row cap and dropped
        # files — a RED banner per capped page, impossible to miss.
        local _cwf _cwp _cws _cwk
        for e in $envs; do
            _cwf="data/$e/analyses/reports/file-search-capped.txt"
            [ -s "$_cwf" ] || continue
            while IFS=$'\t' read -r _cwp _cws _cwk; do
                [ -n "$_cwp" ] || continue
                printf '<p class="banner failed">WARNING: [%s] %s is CAPPED — %s files shipped, %s files in the window are NOT searchable</p>\n' \
                    "$e" "$_cwp" "$_cws" "$_cwk"
            done < "$_cwf"
        done
        if [ "$rc" -eq 0 ]; then
            printf '<p class="banner ok">Build succeeded</p>\n'
        else
            printf '<p class="banner failed">Build FAILED (exit %d)</p>\n' "$rc"
        fi
        # ---- Input / Cached files / Output (the timings sit in the h1) -------
        # (the Input/Cached figures were gathered at the top, before the clock)
        local nhtml obytes=0
        nhtml=$(find docs -name '*.html' 2>/dev/null | wc -l | tr -d ' ')
        [ "${nhtml:-0}" -gt 0 ] && obytes=$(find docs -name '*.html' -exec stat -f%z {} + 2>/dev/null \
                                            | awk '{ s += $1 } END { printf "%d", s + 0 }')
        printf '<div class="bstats bsrow">\n'   # Input/Cache/Output on one row
        printf '<div class="bs"><h3>Input</h3><table>'
        printf '<tr><td>Server logs</td><td class="v">%s files, %s lines, %s</td></tr>' \
            "$(hnum "$sfiles")" "$(hnum "$slines")" "$(hbytes "$sbytes")"
        printf '<tr><td>Transfer logs</td><td class="v">%s files, %s lines, %s</td></tr></table></div>\n' \
            "$(hnum "$tfiles")" "$(hnum "$tlines")" "$(hbytes "$tbytes")"
        printf '<div class="bs"><h3>Cached files</h3><table>'
        printf '<tr><td>Server <code>_parse.tsv</code></td><td class="v">%s lines, %s</td></tr>' \
            "$(hnum "$cslines")" "$(hbytes "$csbytes")"
        printf '<tr><td>Transfer <code>_files.tsv</code></td><td class="v">%s lines, %s</td></tr></table></div>\n' \
            "$(hnum "$ctlines")" "$(hbytes "$ctbytes")"
        printf '<div class="bs"><h3>Output</h3><table>'
        printf '<tr><td>HTML files</td><td class="v">%s</td></tr>' "$(hnum "$nhtml")"
        printf '<tr><td>Size</td><td class="v">%s</td></tr></table></div>\n' "$(hbytes "$obytes")"
        printf '</div>\n'
        [ -n "$note" ] && printf '<p>%s</p>\n' "$note"
        printf '<table>\n<tr><th>#</th><th>Step</th><th>Command</th><th>Started</th><th>Duration</th><th>Status</th></tr>\n'
        local rec label cmd start dur status logf i=0
        for rec in ${STEPS[@]+"${STEPS[@]}"}; do
            i=$((i+1))
            IFS=$'\037' read -r label cmd start dur status logf <<<"$rec"
            printf '<tr><td class="r">%d</td><td>%s</td><td class="cmd">%s</td><td class="r">%s</td><td class="r">%s</td>' \
                "$i" "$(printf '%s' "$label" | esc)" "$(printf '%s' "$cmd" | esc)" "$start" "$(hms "$dur")"
            if [ "$status" -eq 0 ]; then
                printf '<td class="ok">OK</td></tr>\n'
            else
                printf '<td class="failed">FAILED (exit %d)</td></tr>\n' "$status"
            fi
        done
        printf '<tr class="total"><td></td><td>Total (%d steps)</td><td></td><td></td><td class="r">%s</td><td></td></tr>\n' \
            "$i" "$(hms "$total")"
        printf '</table>\n'
        if [ "$i" -gt 0 ]; then
            printf '<h2>Step output</h2>\n'
            local open word
            i=0
            for rec in ${STEPS[@]+"${STEPS[@]}"}; do
                i=$((i+1))
                IFS=$'\037' read -r label cmd start dur status logf <<<"$rec"
                open=''; word='OK'
                if [ "$status" -ne 0 ]; then open=' open'; word="FAILED (exit $status)"; fi
                printf '<details%s><summary>%d. %s &mdash; %s &mdash; %s</summary><pre>' \
                    "$open" "$i" "$(printf '%s' "$label" | esc)" "$(hms "$dur")" "$word"
                if [ -s "$logf" ]; then esc < "$logf"; else printf '(no output)'; fi
                printf '</pre></details>\n'
            done
        fi
        printf '<p>Written by <code>bin/build.sh</code> &mdash; raw step logs in <code>build/step-NN.log</code>. Build finished at %s.</p>\n' "$end"
        printf '</div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# kill_tree PID — terminate PID and its whole DESCENDANT tree. The background
# chains spawn their own worker pools (parse/report/publish children, awk,
# sort); killing only the direct shell would orphan those workers, which keep
# writing into data/ and docs/ after the build has already failed. Children
# are enumerated BEFORE the parent is signalled (a dead parent's children are
# reparented and no longer found via -P), then each subtree is walked.
kill_tree() {
    local p kids
    kids=$(pgrep -P "$1" 2>/dev/null || true)
    kill "$1" 2>/dev/null || true
    for p in $kids; do kill_tree "$p"; done
}

# EXIT trap: the complete local report, every step included. A background
# step still in flight when the build dies (a failed foreground step) is
# killed — with its whole worker tree — and reaped, so nothing can keep
# writing while the tree is in a failed state. The build lock is released
# LAST, after every writer this build owns is confirmed gone.
finalize_report() {
    local rc=$?
    if [ -n "${BG_PID:-}" ]; then kill_tree "$BG_PID"; wait "$BG_PID" 2>/dev/null || true; fi
    if [ -n "${PROD_PID:-}" ]; then kill_tree "$PROD_PID"; wait "$PROD_PID" 2>/dev/null || true; fi
    write_report "$REPORT" "$rc"
    printf '\nBuild report: %s\n' "$REPORT" >&2
    rm -rf "$BUILD_LOCK"
}
trap finalize_report EXIT

# --- stages 1-3, PER ENVIRONMENT (env-major: every intra-env dependency —
#     transfer reports before server reports, analyses before
#     seen-in-server-log, publishes last — holds within each pass; the shared
#     root home is rewritten by each pass's bin/build/publish.sh reading both envs
#     from disk, so the order of the two passes doesn't matter).
#     An env whose FlowManager exports are missing is skipped with a note, so
#     a clone holding only acceptance data still builds.
#
# PARALLEL SHAPE (2026-07): when both envs are present, the whole PRODUCTION
# chain (parse -> report -> publish) runs in the BACKGROUND while the
# acceptance steps run in the foreground — production is a fraction of
# acceptance's size, so its wall clock disappears. What stays serialized:
#   - the config steps of BOTH envs run FIRST, sequentially. This used to be
#     REQUIRED: flow-manager's fwd seeding wrote a SHARED input/hostnames/ cache,
#     as did each parse's automatic ip -> name rules. That map is per-env since
#     2026-07 (input/<env>/ip/), so the chains now share no input/ writer at all
#     and the order is kept only because it costs nothing.
#   - acceptance's "publish: index pages" (the shared root home, which reads
#     BOTH env trees) runs AFTER the production chain has finished.
#   - accvsprod / crosslink were already after both envs.
# Within the acceptance pass, the TWO PARSES also overlap: bin/server/parse.sh
# runs in the background beside bin/transfer/parse.sh (independent inputs and
# caches; the transfer parse's trailing session-sites/expire-files re-marks
# are suppressed via AXWAY_SKIP_SESSIONS=1/AXWAY_SKIP_EXPIRE=1 — they would
# read the server cache mid-rewrite — and the explicit steps right after the
# barrier do them instead).
#
# Within one env:
# 1. parse — flow-manager.sh (config caches), the two
#    parse.sh, then session-sites.sh (learn the real subscription of UCx
#    groups from the server log's route lines, by the shared session id;
#    re-derives the transfer caches when it learned something) and
#    expire-files.sh (needs both parse caches: flips Waiting
#    files whose staged copy the File Maintenance sweep deleted to Expired,
#    _files.tsv cols 2/22), seen-in-server-log.sh (marks the server-log-only entities
#    blue) and result.sh (fills the rest of the base result columns,
#    preserving blue).
# 2. report — transfer BEFORE server and analyses (both read transfer report
#    outputs); the analyses step ends with seen-in-server-log (fresh pda.rpt);
#    dashboards + day after both areas.
# 3. publish — per-area publishes, then bin/build/publish.sh (the index pages live
#    in dirs the per-area scripts clear; it also (re)writes the shared home).
export GENERATED_AT="$(date '+%Y-%m-%d %H:%M')"   # one footer stamp shared by all publish processes, both envs

# bg_step_start LABEL COMMAND [ARG...] / bg_step_wait — one step running in
# the background beside the foreground run_steps: output goes to its own log
# only (no console tee — two live streams would interleave), and the STEPS
# record is appended at WAIT time with the full start->finish span. At most
# ONE bg step may be in flight (single set of globals); the production chain
# uses its own PROD_* set below.
BG_LABEL=""; BG_CMD=""; BG_START=""; BG_T0=""; BG_LOGF=""; BG_PID=""
bg_step_start() {
    BG_LABEL=$1; shift
    STEP_N=$((STEP_N+1))
    BG_LOGF=$BUILD_DIR/step-$(printf '%02d' "$STEP_N").log
    BG_START=$(date '+%H:%M:%S'); BG_T0=$(date +%s); BG_CMD="$*"
    printf '\n=== %d. %s (in background) ===\n' "$STEP_N" "$BG_LABEL" >&2
    "$@" > "$BG_LOGF" 2>&1 &
    BG_PID=$!
}
bg_step_wait() {
    local status=0 t1
    wait "$BG_PID" || status=$?
    t1=$(date +%s)
    STEPS+=("$BG_LABEL"$'\037'"$BG_CMD"$'\037'"$BG_START"$'\037'"$((t1-BG_T0))"$'\037'"$status"$'\037'"$BG_LOGF")
    if [ "$status" -ne 0 ]; then
        printf '*** background step FAILED (exit %d): %s — output:\n' "$status" "$BG_LABEL" >&2
        tail -40 "$BG_LOGF" >&2
        exit "$status"
    fi
    BG_PID=""
}

# The per-env chain, parse through the per-area publishes (everything EXCEPT
# the final "publish: index pages" — the caller sequences that around the
# production barrier). Uses run_step per step; the two parses overlap.
env_steps() {
    bg_step_start "[$AXWAY_ENV] parse: server log cache"                  bin/server/parse.sh
    run_step "[$AXWAY_ENV] parse: transfer log cache"                     env AXWAY_SKIP_EXPIRE=1 AXWAY_SKIP_SESSIONS=1 bin/transfer/parse.sh
    bg_step_wait
    # the two server-log -> transfer joins, in this order: the session step
    # may re-derive _files.tsv (resetting col 22), so expire re-marks after it
    run_step "[$AXWAY_ENV] server log -> transfer: attribute UCx flows by session" bin/session-sites.sh
    run_step "[$AXWAY_ENV] server log -> transfer: mark expired staged files" bin/expire-files.sh
    run_step "[$AXWAY_ENV] server log -> transfer: mark server-only entities blue" bin/build/seen-in-server-log.sh
    run_step "[$AXWAY_ENV] result: subscription outcomes -> base caches"  bin/build/result.sh
    # The blue step may APPEND SSH-logon-discovered names to the base rosters —
    # names the server parse's mention scan (which ran above) did not know, so
    # their detail pages would lose the server-log table on a from-scratch
    # build. It drops a .rescan-mentions marker then; this re-run rescans
    # exactly once (tokenize skips via the manifest; without the marker the
    # whole call is a seconds-long no-op). 2026-08-15 fresh-build fix.
    if [ -f "data/$AXWAY_ENV/server/cache/.rescan-mentions" ]; then
        run_step "[$AXWAY_ENV] parse: rescan server mentions (appended names)" bin/server/parse.sh
    # WENT-KAPUT EARLY (2026-08): its inputs are all parse-phase artifacts
    # (_files.tsv, the mention caches, the xref pairs, the base colours), and
    # its _kaput-evidence.tsv sidecar is the one stamp source failed.sh used
    # to gain only in the evidence catch-up — running it here makes the
    # reddening-session tables (and so the _srvsubs-map) FINAL on failed.sh's
    # FIRST run, which lets the expensive details catch-up self-gate to a
    # skip. The server-reports step re-invokes it later and skips (fresh).
    run_step "[$AXWAY_ENV] report: went-kaput (early — the failed/details evidence)" bin/server/reports/went-kaput.sh
    fi

    # details.sh is the longest report step and only the transfer PHASE 2
    # (showseen, ranking — they read its .rpts/slugmaps) needs it, so it runs
    # in the BACKGROUND (2026-07) while phase 1 and then the server reports
    # (whose rosters are phase-1 outputs) go through in the foreground.
    bg_step_start "[$AXWAY_ENV] report: detail pages .rpt files"          bin/transfer/reports/details.sh
    run_step "[$AXWAY_ENV] report: transfer .rpt files (phase 1)"         bin/transfer/reports.sh phase1
    run_step "[$AXWAY_ENV] report: server .rpt files"                     bin/server/reports.sh
    bg_step_wait
    run_step "[$AXWAY_ENV] report: transfer .rpt files (phase 2)"         bin/transfer/reports.sh phase2
    run_step "[$AXWAY_ENV] report: analyses .rpt files"                   bin/analyses/reports.sh
    # (seen-in-server-log runs INSIDE the analyses step now — last, after the
    # pda.rpt it reads; cross-reference runs there too since the 2026-07 move
    # of the Analyses-menu reports into bin/analyses/reports/)
    # dashboards and day both need the two areas' reports and nothing of each
    # other — disjoint output dirs, so they overlap (2026-08)
    bg_step_start "[$AXWAY_ENV] report: dashboards .rpt files"            bin/dashboards/reports.sh
    run_step "[$AXWAY_ENV] report: day pages .rpt files"                  bin/day/reports.sh
    bg_step_wait

    # the two heaviest publishes write DISJOINT trees — docs/<env>/transfer vs
    # docs/<env>/details — so the detail pages render in the background beside
    # the report pages (2026-07; ~11 s off the critical path)
    bg_step_start "[$AXWAY_ENV] publish: detail pages"                     bin/transfer/publish-details.sh
    run_step "[$AXWAY_ENV] publish: transfer report pages"                bin/transfer/publish.sh
    bg_step_wait
    run_step "[$AXWAY_ENV] publish: partner group pages"                  bin/analyses/publish-partner-groups.sh
    run_step "[$AXWAY_ENV] publish: server report pages"                  bin/server/publish.sh
    run_step "[$AXWAY_ENV] publish: analyses + coverage pages"            bin/analyses/publish.sh
    # THE EVIDENCE CATCH-UP (2026-08): three reports read evidence that steps
    # AFTER them produce — failed.sh the kaput/boxes classifications (the
    # server reports and publish-insights above), failing-reasons.sh reads
    # failed.rpt, and details.sh the _srvsubs.tsv map failed.sh writes. On a
    # fresh data/ their first runs happened before that evidence existed, and
    # closing the gaps used to take a whole SECOND build. Re-running them
    # here folds the convergence into THIS build. Self-gating: every input is
    # cmp-guarded and listed in the consumer's skip_if_fresh deps, so a warm
    # build skips each step in ~0 s.
    run_step "[$AXWAY_ENV] report catch-up: failed subscriptions"         bin/transfer/reports/failed.sh
    run_step "[$AXWAY_ENV] report catch-up: error reasons"                bin/analyses/reports/failing-reasons.sh
    # The DETAIL-PAGES catch-up runs in the BACKGROUND beside everything
    # below (2026-08): it touches only data/…/details + docs/…/details,
    # which none of the remaining steps read. With the _srvsubs-map split it
    # fires only when the section membership/stamps truly changed (a fresh
    # estate, a flow entering/leaving the server-failing set) — a reason-only
    # rerun of failed.sh above leaves the map byte-identical and this pair
    # skips in ~0 s.
    bg_step_start "[$AXWAY_ENV] catch-up: detail pages (.rpt + publish)"  bash -c 'bin/transfer/reports/details.sh && bin/transfer/publish-details.sh'
    run_step "[$AXWAY_ENV] publish catch-up: analyses (failed pages)"     bin/analyses/publish.sh
    # THE BOXES-REASON CATCH-UP (2026-08): the Entities Error view's Reason
    # column reads analyses/reports/_subs-boxes.tsv, which the analyses
    # publish above (publish-insights.sh) writes AFTER the transfer publish
    # already ran — on a fresh data/ the box-tier reasons would render blank
    # until the NEXT build. Re-invoking the transfer publish here folds the
    # catch-up into THIS build (it also re-renders the errors/ pages the
    # failed.sh catch-up refreshed). Self-gating: the sidecar is cmp-guarded
    # and a dep of the transfer stamp, so when its content did not change
    # this step skips in ~0 s.
    run_step "[$AXWAY_ENV] publish: transfer catch-up (boxes reasons)"    bin/transfer/publish.sh
    run_step "[$AXWAY_ENV] publish: dashboards"                           bin/dashboards/publish.sh
    run_step "[$AXWAY_ENV] publish: day pages"                            bin/day/publish.sh
    bg_step_wait
}

# The BACKGROUND production pass. Each step runs through prod_step, which
# times it, captures its output in its own build/prod-step-NN.log and appends
# a report record to $PROD_STEPS_FILE — the barrier below merges those into
# STEPS, so the report lists every production step INDIVIDUALLY (like the
# old serial env loop), not one opaque chain row.
# AXWAY_NJOBS=3: production's data is a fraction of acceptance's, so wide
# pools gain it nothing — at full width BOTH envs spawned core-count pools
# during the overlap (2x oversubscription). The chain's wall time under the
# overlap is elastic either way (measured ~1:07 solo vs ~4:30 beside
# acceptance — plain CPU competition); it stays off the critical path as
# long as it finishes before acceptance's last pre-barrier step.
PROD_STEPS_FILE=$BUILD_DIR/prod-steps.records
prod_step() {
    local label=$1; shift
    PROD_N=$(( ${PROD_N:-0} + 1 ))
    local logf; logf=$BUILD_DIR/prod-step-$(printf '%02d' "$PROD_N").log
    local start t0 t1 status=0
    start=$(date '+%H:%M:%S'); t0=$(date +%s)
    "$@" > "$logf" 2>&1 || status=$?
    t1=$(date +%s)
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$label" "$*" "$start" "$((t1-t0))" "$status" "$logf" >> "$PROD_STEPS_FILE"
    return "$status"
}
bg_env_chain() {
    set -e
    export AXWAY_NJOBS=3
    : > "$PROD_STEPS_FILE"
    # the two parses OVERLAP (2026-08), like the foreground chain: the server
    # parse is this lane's longest step and used to run serially after the
    # transfer parse (43 s + 1:28 sequential on a cold production estate).
    # The bg record runs in a subshell with its own PROD_N BASE so its
    # prod-step-NN.log name cannot collide with the foreground numbering;
    # both append single-line records to $PROD_STEPS_FILE (O_APPEND-safe).
    ( PROD_N=89; prod_step "[$AXWAY_ENV] parse: server log cache (in background)" bin/server/parse.sh ) &
    _pparse=$!
    prod_step "[$AXWAY_ENV] parse: transfer log cache"                     env AXWAY_SKIP_EXPIRE=1 AXWAY_SKIP_SESSIONS=1 bin/transfer/parse.sh
    wait "$_pparse"
    prod_step "[$AXWAY_ENV] server log -> transfer: attribute UCx flows by session" bin/session-sites.sh
    prod_step "[$AXWAY_ENV] server log -> transfer: mark expired staged files" bin/expire-files.sh
    prod_step "[$AXWAY_ENV] server log -> transfer: mark server-only entities blue" bin/build/seen-in-server-log.sh
    prod_step "[$AXWAY_ENV] result: subscription outcomes -> base caches"  bin/build/result.sh
    # went-kaput early — see the foreground chain's comment
    prod_step "[$AXWAY_ENV] report: went-kaput (early — the failed/details evidence)" bin/server/reports/went-kaput.sh
    prod_step "[$AXWAY_ENV] report: detail pages .rpt files"               bin/transfer/reports/details.sh
    prod_step "[$AXWAY_ENV] report: transfer .rpt files"                   bin/transfer/reports.sh
    prod_step "[$AXWAY_ENV] report: server .rpt files"                     bin/server/reports.sh
    prod_step "[$AXWAY_ENV] report: analyses .rpt files"                   bin/analyses/reports.sh
    prod_step "[$AXWAY_ENV] report: dashboards .rpt files"                 bin/dashboards/reports.sh
    prod_step "[$AXWAY_ENV] report: day pages .rpt files"                  bin/day/reports.sh
    prod_step "[$AXWAY_ENV] publish: transfer report pages"                bin/transfer/publish.sh
    prod_step "[$AXWAY_ENV] publish: detail pages"                         bin/transfer/publish-details.sh
    prod_step "[$AXWAY_ENV] publish: partner group pages"                  bin/analyses/publish-partner-groups.sh
    prod_step "[$AXWAY_ENV] publish: server report pages"                  bin/server/publish.sh
    prod_step "[$AXWAY_ENV] publish: analyses + coverage pages"            bin/analyses/publish.sh
    # the evidence + boxes-reason catch-ups — see the foreground chain's comments
    prod_step "[$AXWAY_ENV] report catch-up: failed subscriptions"         bin/transfer/reports/failed.sh
    prod_step "[$AXWAY_ENV] report catch-up: error reasons"                bin/analyses/reports/failing-reasons.sh
    prod_step "[$AXWAY_ENV] report catch-up: detail pages .rpt"            bin/transfer/reports/details.sh
    prod_step "[$AXWAY_ENV] publish catch-up: analyses (failed pages)"     bin/analyses/publish.sh
    prod_step "[$AXWAY_ENV] publish catch-up: detail pages"                bin/transfer/publish-details.sh
    prod_step "[$AXWAY_ENV] publish: transfer catch-up (boxes reasons)"    bin/transfer/publish.sh
    prod_step "[$AXWAY_ENV] publish: dashboards"                           bin/dashboards/publish.sh
    prod_step "[$AXWAY_ENV] publish: day pages"                            bin/day/publish.sh
    prod_step "[$AXWAY_ENV] publish: index pages"                          bin/build/publish.sh
}

HAVE_ACC=0; HAVE_PROD=0
[ -f input/acceptance/flow-manager/partners.json ] && [ -f input/acceptance/flow-manager/subscriptions.json ] && HAVE_ACC=1
[ -f input/production/flow-manager/partners.json ] && [ -f input/production/flow-manager/subscriptions.json ] && HAVE_PROD=1
[ "$HAVE_ACC" = 1 ] || printf '\n=== skipping environment acceptance: no input/acceptance/flow-manager/{partners,subscriptions}.json ===\n' >&2
[ "$HAVE_PROD" = 1 ] || printf '\n=== skipping environment production: no input/production/flow-manager/{partners,subscriptions}.json ===\n' >&2
# A scoped run drops the other env entirely — from the config loop, the chains
# and the cross-env steps alike.
case $BUILD_SCOPE in
    acceptance) HAVE_PROD=0 ;;
    production) HAVE_ACC=0 ;;
esac
if [ "$BUILD_SCOPE" != both ] && [ "$HAVE_ACC$HAVE_PROD" = "00" ]; then
    printf 'bin/build.sh: %s has no input/%s/flow-manager exports — nothing to build.\n' "$BUILD_SCOPE" "$BUILD_SCOPE" >&2
    exit 1
fi
printf '\n=== build scope: %s (report -> %s) ===\n' "$BUILD_SCOPE" "$REPORT" >&2

# Config/hostname steps of BOTH envs first. These no longer CONTEND — the
# address<->endpoint map is per-env (input/<env>/ip/), so the cross-env write
# that forced this order is gone. PARALLEL when both envs are present
# (2026-08): a from-scratch config pass is ~9 s per env these days (the
# "under a second" era predates the PDA/partner-group work), the two runs
# touch disjoint trees, and the shared awk shim is pre-created below before
# either starts — so overlapping them takes ~8 s off every cold build.
. "$(dirname "${BASH_SOURCE[0]}")/fastawk.sh"   # create data/.awkshim ONCE, before parallel children race for it
if [ "$HAVE_ACC" = 1 ] && [ "$HAVE_PROD" = 1 ]; then
    bg_step_start "[acceptance] config: extract the configured entity lists" env AXWAY_ENV=acceptance bin/flow-manager.sh
    run_step "[production] config: extract the configured entity lists"      env AXWAY_ENV=production bin/flow-manager.sh
    bg_step_wait
else
    for AXWAY_ENV in acceptance production; do
        export AXWAY_ENV
        if [ "$AXWAY_ENV" = acceptance ]; then [ "$HAVE_ACC" = 1 ] || continue; else [ "$HAVE_PROD" = 1 ] || continue; fi
        run_step "[$AXWAY_ENV] config: extract the configured entity lists"  bin/flow-manager.sh
    done
fi

# FOREGROUND env = the one with MORE INPUT DATA, measured per run (production
# is expected to outgrow acceptance): the big env drives the wall clock, so
# it gets the full pools and the live per-step console; the SMALL env runs
# beside it in the background (pools capped via AXWAY_NJOBS in bg_env_chain).
# Ties (and today) fall to acceptance.
env_input_bytes() {   # $1 env -> KB of its raw log exports
    du -sk "input/$1/transfer" "input/$1/server" 2>/dev/null | awk '{s+=$1} END{print s+0}'
}
FG_ENV=""; BG_ENV=""
if [ "$HAVE_ACC" = 1 ] && [ "$HAVE_PROD" = 1 ]; then
    FG_ENV=acceptance; BG_ENV=production
    if [ "$(env_input_bytes production)" -gt "$(env_input_bytes acceptance)" ]; then
        FG_ENV=production; BG_ENV=acceptance
    fi
elif [ "$HAVE_ACC" = 1 ]; then FG_ENV=acceptance
elif [ "$HAVE_PROD" = 1 ]; then FG_ENV=production
fi

PROD_PID=""; PROD_LOGF=""; PROD_START=""; PROD_T0=""; PROD_STEPNO=""   # PROD_* = the BACKGROUND env's chain (historical name)
if [ -n "$BG_ENV" ]; then
    STEP_N=$((STEP_N+1)); PROD_STEPNO=$STEP_N
    PROD_LOGF=$BUILD_DIR/step-$(printf '%02d' "$STEP_N").log
    PROD_START=$(date '+%H:%M:%S'); PROD_T0=$(date +%s)
    printf '\n=== %d. [%s] full chain (in background beside %s) ===\n' "$STEP_N" "$BG_ENV" "$FG_ENV" >&2
    ( export AXWAY_ENV=$BG_ENV; bg_env_chain ) > "$PROD_LOGF" 2>&1 &
    PROD_PID=$!
fi

if [ -n "$FG_ENV" ]; then
    export AXWAY_ENV=$FG_ENV
    env_steps
fi

if [ -n "$PROD_PID" ]; then
    # barrier: the foreground env's index step below rewrites the SHARED root
    # home reading BOTH env trees — the background env must be complete first
    prod_status=0
    wait "$PROD_PID" || prod_status=$?
    # merge the chain's per-step records into the report — every production
    # step gets its own row (label, start, duration, status, log), numbered
    # in sequence at the barrier position
    if [ -f "$PROD_STEPS_FILE" ]; then
        while IFS=$'\037' read -r pl pc ps pd pst plog; do
            [ -n "$pl" ] || continue
            STEP_N=$((STEP_N+1))
            STEPS+=("$pl"$'\037'"$pc"$'\037'"$ps"$'\037'"$pd"$'\037'"$pst"$'\037'"$plog")
        done < "$PROD_STEPS_FILE"
    fi
    if [ "$prod_status" -ne 0 ]; then
        printf '*** background env chain (%s) FAILED (exit %d) — the last [%s] step:\n' "$BG_ENV" "$prod_status" "$BG_ENV" >&2
        if [ -f "$PROD_STEPS_FILE" ]; then
            plog=$(tail -1 "$PROD_STEPS_FILE" | awk -F'\037' '{print $6}')
            [ -f "$plog" ] && tail -40 "$plog" >&2
        fi
        tail -10 "$PROD_LOGF" >&2
        exit "$prod_status"
    fi
    PROD_PID=""
fi

if [ -n "$FG_ENV" ]; then
    export AXWAY_ENV=$FG_ENV
    run_step "[$FG_ENV] publish: index pages"                             bin/build/publish.sh
fi

# After BOTH env trees exist: the Acceptance-vs-production pages compare the
# two trees, so each env's copy is REBUILT here with the other env's COMPLETE
# data (inside the loop the acceptance pass reads production's previous
# build — or nothing at all on a fresh build).
# A SCOPED run rebuilds only its own env's copy: `bin/build.sh acc` must not
# write into docs/production/. The other env's comparison pages then keep the
# figures from ITS last build, which is the honest reading — they were rendered
# by that run, and their footer still links that run's report.
# `if`, not `[ … ] && …`: the latter is the last command of the list, so a false
# test makes the statement return 1 (the site-wide set -e trap in this repo).
if [ "$HAVE_ACC" = 1 ]; then
    run_step "publish: acceptance vs production (acceptance)" env AXWAY_ENV=acceptance bin/analyses/publish-accvsprod.sh
fi
if [ "$HAVE_PROD" = 1 ]; then
    run_step "publish: acceptance vs production (production)" env AXWAY_ENV=production bin/analyses/publish-accvsprod.sh
fi

# Resolve every page's environment-switch link —
# the twin page in the other env when it exists, else that env's own 404 page
# (docs/<env>/404.html, written by bin/build/publish.sh) — so the switch never hits
# the webserver's error page.
run_step "publish: cross-link the environment switch"    bin/build/crosslink.sh

# ---- RUNTIME-ONLY: the shareable site archive (2026-08-30) ------------------
# In the runtime checkout — recognized by the ABSENT input/.sample-estate
# marker, which only the develop repo carries — every completed build packs
# docs/ into build/st-reports_YYYY-MM-DD_HHMM.7z and copies it to ~/cloud/.
if [ ! -f input/.sample-estate ]; then
    run_step "archive: st-reports .7z -> build/ + ~/cloud/"  bin/build/st-reports-archive.sh
fi

# (The docs/build.html publish was REMOVED 2026-08-29 — the report lives only
# in build/index.html, written by the EXIT trap. The former stage-4 git
# commit + push was removed 2026-07: the build only renders; committing and
# pushing docs/ is a separate, manual decision.)

echo "Done." >&2
