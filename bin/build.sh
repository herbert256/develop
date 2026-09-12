#!/usr/bin/env bash
#
# build.sh — the whole pipeline in one command (formerly all.sh): the three
# stages parse -> report -> publish for THIS CHECKOUT'S ONE ENVIRONMENT
# (2026-09-11: one repo = one environment — input/environment.txt names it,
# see bin/envlabel.sh; the acceptance/production scope and the two parallel
# env chains are gone). NO git step (removed 2026-07): the build only renders
# docs/ — committing and pushing is a separate, manual decision. Every step is
# timed and its output captured, and the run is written up as an HTML build
# report:
#
#   build/index.html    the report — one row per step (command, start time,
#                       duration, OK/FAILED) plus each step's captured output,
#                       rewritten on every run. It is finalized from an EXIT
#                       trap, so a FAILED or interrupted run still gets its
#                       report, with the failing step on record.
#   build/step-NN.log   the raw per-step output the report embeds.
#   (the docs/ copies were REMOVED 2026-08-29: the report is a LOCAL artifact
#   only, and no page on the published site references a build any more)
#
# build/ is gitignored like data/ — a per-run local artifact, safe to delete.
#
# The stages (each is a separate script):
#
#   1. parse    bin/flow-manager.sh (pre-parse: input/flow-manager/*.json -> data/flow-manager/*.tsv
#               configured entity lists), then bin/transfer/parse.sh +
#               bin/server/parse.sh tokenize the input CSVs into the gitignored
#               caches (only when stale — new/changed input or a changed parse.sh),
#               then bin/session-sites.sh, bin/expire-files.sh, bin/bookend-ok.sh
#               (the three server-log -> transfer joins), bin/build/seen-in-server-log.sh
#               (mark server-log-only entities BLUE in the base result column)
#               and bin/build/result.sh (fill the remaining base results, preserving blue)
#   2. report   bin/transfer/reports.sh, then bin/server/reports.sh, then
#               bin/analyses/reports.sh + bin/dashboards/reports.sh + bin/day/reports.sh
#               -> data/<area>/reports/*.rpt (no HTML). The dependencies are
#               ONE-way: server's site-failures.sh (and a dozen more) read
#               transfer's <entity>.rpt name rosters (a TRANSFER report output)
#               and `exit 1` if missing — so server must never run before
#               transfer (the unknown-* reports read the parse cache instead
#               and already ran in stage 1, via bin/build/seen-in-server-log.sh).
#               The analyses reports read transfer outputs too (showseen.sh's
#               coverage TSVs/METAs, the detail-page slugmaps), and the
#               dashboards reports read the transfer caches + transfer/server
#               .rpt outputs — so both run after transfer and server.
#               Transfer reads nothing from the server REPORTS (its
#               detail-page server KPI comes from the server PARSE cache,
#               built in stage 1), so one pass suffices.
#   3. publish  bin/transfer/publish.sh + bin/server/publish.sh +
#               bin/analyses/publish.sh + bin/dashboards/publish.sh + bin/day/publish.sh +
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
#   bin/build.sh        the whole chain for this checkout's one environment
#   bin/build.sh -h     this text
#
# No arguments: one repo = one environment. The report goes to
# build/index.html and nowhere else.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ---- arguments --------------------------------------------------------------
case "${1:-}" in
    "") ;;
    -h|--help|help)
        sed -n 's/^# \{0,1\}//; 2,/^$/p' "${BASH_SOURCE[0]}" >&2
        printf 'usage: bin/build.sh   (no arguments — one repo = one environment)\n' >&2; exit 0 ;;
    *)  printf 'bin/build.sh: takes no arguments (one repo = one environment since 2026-09-11; the acc/prd scope is gone) — got %s\n' "$1" >&2
        exit 2 ;;
esac
source bin/envlabel.sh   # ENV_LABEL / ENV_KEY / ENV_INBOX from input/environment.txt
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
# Every build CLEARS docs/ and re-seeds the hand-authored files from the
# repo-root assets/ — docs/ is pure build output, and a build can never leave
# a stale page behind. assets/ is the ONE place to edit style.css / report.js
# / slotchart.js / file-search.js and the help pages (see assets/README.txt);
# .nojekyll and topbar-data.js stay generated (ensure_assets).
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
clear_tree docs
mkdir -p docs/assets docs/help
cp assets/style.css assets/report.js assets/slotchart.js assets/file-search.js docs/assets/
awk -f bin/darken-css.awk assets/style.css >> docs/assets/style.css   # the dark theme, generated from the light rules (2026-09-05)
cp -R assets/help/. docs/help/

BUILD_DIR="build"
REPORT="$BUILD_DIR/index.html"
mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR"/step-*.log

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

# log_inventory DIR -> one line per *.csv export in DIR, sorted on First:
#   name <TAB> first <TAB> last <TAB> lines
# First/Last = the oldest/newest record stamp in the file (ccyy-mm-dd
# HH:MM:SS, from the first MM/DD/YYYY HH:MM:SS on each line — the transfer
# export's Start Time, the server export's Time; the continuation lines of a
# multi-line server message carry none and are skipped), Lines = the physical
# lines after the header. The report's two bottom tables (2026-09-12, user
# request). Reading every byte of every export is the count_stats cost
# again, so the answer is CACHED PER FILE under name + size + mtime
# (data/.buildstats/loginv/): a warm build re-reads nothing, a new or changed
# export is scanned once.
log_inventory() {
    local d=$1 f sig cache
    local -a g
    shopt -s nullglob; g=("$d"/*.csv); shopt -u nullglob
    [ ${#g[@]} -gt 0 ] || return 0
    mkdir -p "$BUILD_STATS_DIR/loginv"
    for f in "${g[@]}"; do
        sig=$(stat -f'%N %z %m' "$f" | cksum | cut -d' ' -f1)
        cache="$BUILD_STATS_DIR/loginv/$sig"
        if [ ! -s "$cache" ]; then
            awk -v N="$(basename "$f")" '
                function iso(s) { return substr(s, 7, 4) "-" substr(s, 1, 2) "-" substr(s, 4, 2) " " substr(s, 12) }
                NR > 1 && match($0, /[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
                    t = iso(substr($0, RSTART, RLENGTH))
                    if (first == "" || t < first) first = t
                    if (t > last) last = t }
                END { printf "%s\t%s\t%s\t%d\n", N, first, last, (NR > 0 ? NR - 1 : 0) }' "$f" > "$cache.tmp" && mv "$cache.tmp" "$cache"
        fi
        cat "$cache"
    done | LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k1,1
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
    local r a b c
    local sfiles=0 slines=0 sbytes=0 tfiles=0 tlines=0 tbytes=0
    local cslines=0 csbytes=0 ctlines=0 ctbytes=0
    # NOTE the two-step read. `IFS=$'\t' read … <<<"$(f $(ls …))"` looks
    # equivalent and is not: the assignment is already in effect when the INNER
    # substitution is word-split, so newline stops separating and all 35 export
    # paths arrive as ONE argument — every Input figure came out 0. Globs into
    # an array instead: no ls fork, and safe for spaces.
    local -a g
    shopt -s nullglob
    g=("input/server"/*.csv)
    r=$(count_stats "in-server" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r sfiles slines sbytes <<<"$r"
    g=("input/transfer"/*.csv)
    r=$(count_stats "in-transfer" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r tfiles tlines tbytes <<<"$r"
    g=("data/server/cache/_parse.tsv")
    r=$(count_stats "cache-server" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r a cslines csbytes <<<"$r"
    g=("data/transfer/cache/_files.tsv")
    r=$(count_stats "cache-transfer" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r a ctlines ctbytes <<<"$r"
    shopt -u nullglob
    # the per-export inventory for the report's bottom tables (log_inventory,
    # cached per file) — gathered here, BEFORE the clock, like the figures above
    local sinv tinv
    sinv=$(log_inventory input/server); tinv=$(log_inventory input/transfer)
    # THE INPUT CHANGES (2026-09-06, user request): every file under
    # input/{server,transfer,flow-manager}/ and the *.txt policy files at the
    # input root, compared with the manifest the PREVIOUS build left in
    # build/input-manifest.tsv (path ⇥ size ⇥ mtime): new, updated (size or
    # mtime differs) or removed since then. The manifest is rewritten at the
    # end of this report, so the next build compares against this one. (A
    # manifest in the pre-2026-09 four-column form — env ⇥ path ⇥ size ⇥ mtime
    # — is discarded: the first flat build starts the comparison afresh.)
    local manifest="build/input-manifest.tsv" manifest_new="build/input-manifest.new" changes=""
    find input/server input/transfer input/flow-manager input -maxdepth 1 -type f \
         \( -name '*.csv' -o -name '*.json' -o -name '*.txt' \) 2>/dev/null \
        | LC_ALL=C sort -u | while IFS= read -r f; do
            printf '%s\t%s\t%s\n' "$f" "$(stat -f%z "$f")" "$(stat -f%m "$f")"
          done > "$manifest_new"
    if [ ! -f "$manifest" ] || { [ -s "$manifest" ] && [ "$(head -1 "$manifest" | awk -F'\t' '{ print NF }')" != 3 ]; }; then
        : > "$manifest"
    fi
    changes=$(awk -F'\t' 'NR==FNR { old[$1] = $2 SUBSEP $3; next }
        { seen[$1] = 1
          if (!($1 in old)) print "new\t" $1 "\t" $2
          else if (old[$1] != $2 SUBSEP $3) print "updated\t" $1 "\t" $2 }
        END { for (k in old) if (!(k in seen)) print "removed\t" k "\t" }' \
        "$manifest" "$manifest_new" | LC_ALL=C sort -k2)
    local firstbuild=""
    [ -s "$manifest" ] || firstbuild=1
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
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="0">
<title>Build report — Cloud Reports</title>
HTML
        printf '%s\n' '<script>try{if(localStorage.getItem("axway-theme")==="dark")document.documentElement.setAttribute("data-theme","dark")}catch(e){}</script>'
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
.buildwrap .sxs table{width:auto;margin-top:.4rem}   /* the two log-file tables side by side (style.css .sxs): content-sized, not 100% */
.buildwrap .sxs td,.buildwrap .sxs th{white-space:nowrap}
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
        # publish_lib.sh — the environment label, dropdowns, Entities + search,
        # finder/sitemap/help icons), so the build report looks like every other
        # page. Captured in a subshell so publish_lib's cd/globals stay
        # isolated; a from-scratch clone (or a build that died before any data)
        # yields empty strings and we fall back to a plain-link bar.
        local BUILD_TB
        BUILD_TB=$( source bin/publish_lib.sh >/dev/null 2>&1; render_shared_topbar "$base" "index" ) || true
        if [ -n "${BUILD_TB:-}" ]; then printf '%s' "$BUILD_TB"
        else
            # (the brand's text is the environment label, like render_topbar)
            printf '<div class="topbar"><a class="brand" href="%sindex.html">%s</a><nav class="nav"><a href="%stransfer/index.html">Transfer reports</a><a href="%sserver/index.html">Server reports</a><a href="%sdashboards/index.html">Dashboards</a><a href="%sanalyses/index.html">Analyses</a></nav><span class="tr-group"><span class="tright">Build report</span></span></div>\n' \
                "$base" "$(printf '%s' "${ENV_LABEL:-Cloud}" | esc)" "$base" "$base" "$base" "$base"
        fi
        # THE TIMINGS LIVE IN THE TITLE (2026-08): start → end and the
        # duration are the h1's tail, not a fact block — the end collapses to
        # its time of day when the build stayed inside one calendar day. The
        # environment label sits between (2026-09-11).
        local endshow=$end
        [ "${end%% *}" = "${BUILD_START%% *}" ] && endshow=${end#* }
        printf '<div class="buildwrap">\n<h1>Build report &mdash; %s%s &rarr; %s &middot; %s</h1>\n' \
            "${ENV_LABEL:+$(printf '%s' "$ENV_LABEL" | esc) &mdash; }" "$BUILD_START" "$endshow" "$(hms "$total")"
        # THE FILE-SEARCH CAP WARNING (2026-08): file-search.sh writes
        # file-search-capped.txt when a page hit its row cap and dropped
        # files — a RED banner per capped page, impossible to miss.
        local _cwf="data/analyses/reports/file-search-capped.txt" _cwp _cws _cwk
        if [ -s "$_cwf" ]; then
            while IFS=$'\t' read -r _cwp _cws _cwk; do
                [ -n "$_cwp" ] || continue
                printf '<p class="banner failed">WARNING: %s is CAPPED — %s files shipped, %s files in the window are NOT searchable</p>\n' \
                    "$_cwp" "$_cws" "$_cwk"
            done < "$_cwf"
        fi
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
        printf '<tr><td>Server logs</td><td class="v">%s files, %s lines, %s</td></tr>' "$(hnum "$sfiles")" "$(hnum "$slines")" "$(hbytes "$sbytes")"
        printf '<tr><td>Transfer logs</td><td class="v">%s files, %s lines, %s</td></tr></table></div>\n' "$(hnum "$tfiles")" "$(hnum "$tlines")" "$(hbytes "$tbytes")"
        printf '<div class="bs"><h3>Cached files</h3><table>'
        printf '<tr><td>Server <code>_parse.tsv</code></td><td class="v">%s lines, %s</td></tr>' "$(hnum "$cslines")" "$(hbytes "$csbytes")"
        printf '<tr><td>Transfer <code>_files.tsv</code></td><td class="v">%s lines, %s</td></tr></table></div>\n' "$(hnum "$ctlines")" "$(hbytes "$ctbytes")"
        printf '<div class="bs"><h3>Output</h3><table>'
        printf '<tr><td>HTML files</td><td class="v">%s</td></tr>' "$(hnum "$nhtml")"
        printf '<tr><td>Size</td><td class="v">%s</td></tr></table></div>\n' "$(hbytes "$obytes")"
        printf '</div>\n'
        # ---- Inbox: what the inbox delivered (never named — 2026-09-12) -------
        printf '<h2>Inbox</h2>\n'
        if [ -f input/.sample-estate ]; then
            printf '<p class="bsnote">Not read on the sample estate (develop) — the inbox is runtime-only.</p>\n'
        elif [ -z "${ENV_INBOX:-}" ]; then
            printf '<p class="bsnote">input/environment.txt %s — the inbox is not read (Acceptance or Production expected).</p>\n' \
                "$([ -n "${ENV_LABEL:-}" ] && printf 'says <strong>%s</strong>' "$(printf '%s' "$ENV_LABEL" | esc)" || printf 'is missing')"
        else
            printf '<p class="bsnote">This checkout is <strong>%s</strong>: it consumes the archives named <code>%s</code> in the inbox; the other environment'"'"'s archives stay put. The log exports inside land as <code>logEntry_yyyy-mm-dd.csv</code> and <code>fileTransfer_yyyy-mm-dd.csv</code>, named from their first record'"'"'s date.</p>\n' \
                "$(printf '%s' "$ENV_LABEL" | esc)" "$(printf '%s' "$ENV_INBOX" | sed 's/ /*.7z, /g; s/$/*.7z/')"
            if [ ! -s build/inbox.tsv ]; then
                printf '<p class="bsnote">The inbox step did not run this build.</p>\n'
            else
                printf '<table>\n<tr><th>Outcome</th><th>Archive</th><th>Detail</th></tr>\n'
                local _io _ia _id _cls
                while IFS=$'\t' read -r _io _ia _id; do
                    [ -n "$_io" ] || continue
                    case $_io in consumed) _cls=ok ;; failed) _cls=failed ;; *) _cls="" ;; esac
                    printf '<tr><td class="%s">%s</td><td><code>%s</code></td><td>%s</td></tr>\n' \
                        "$_cls" "$(printf '%s' "$_io" | esc)" "$(printf '%s' "$_ia" | esc)" "$(printf '%s' "$_id" | esc)"
                done < build/inbox.tsv
                printf '</table>\n'
            fi
        fi
        # ---- Input changes since the previous build ----
        printf '<h2>Input changes since the previous build</h2>\n'
        if [ -n "$firstbuild" ]; then
            printf '<p class="bsnote">No previous manifest — this build recorded the input files; the next report lists what changed.</p>\n'
        elif [ -z "$changes" ]; then
            printf '<p class="bsnote">No new, updated or removed input files.</p>\n'
        else
            printf '<table>\n<tr><th>Change</th><th>File</th><th>Size</th></tr>\n'
            local _cw _cf _cz
            while IFS=$'\t' read -r _cw _cf _cz; do
                [ -n "$_cw" ] || continue
                printf '<tr><td class="%s">%s</td><td><code>%s</code></td><td class="r">%s</td></tr>\n' \
                    "$([ "$_cw" = removed ] && echo failed || echo ok)" "$_cw" "$(printf '%s' "$_cf" | esc)" "$([ -n "$_cz" ] && hbytes "$_cz")"
            done <<< "$changes"
            printf '</table>\n'
        fi
        mv -f "$manifest_new" "$manifest"
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
        # ---- the log files (2026-09-12, user request): every server and
        # transfer export in input/, two tables side by side — Name · First ·
        # Last · Lines, sorted on First (log_inventory, gathered up top)
        printf '<h2>Log files</h2>\n<div class="sxs">\n'
        local _spec _lname _lfirst _llast _llines _inv
        for _spec in "Server log files|$sinv" "Transfer log files|$tinv"; do
            _inv="${_spec#*|}"
            printf '<div class="sxscol"><h3>%s</h3>\n<table>\n<tr><th>Name</th><th>First</th><th>Last</th><th class="r">Lines</th></tr>\n' "${_spec%%|*}"
            if [ -z "$_inv" ]; then
                printf '<tr><td colspan="4">(none)</td></tr>\n'
            else
                while IFS=$'\t' read -r _lname _lfirst _llast _llines; do
                    [ -n "$_lname" ] || continue
                    printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td class="r">%s</td></tr>\n' \
                        "$(printf '%s' "$_lname" | esc)" "$(printf '%s' "$_lfirst" | esc)" "$(printf '%s' "$_llast" | esc)" "$(hnum "${_llines:-0}")"
                done <<< "$_inv"
            fi
            printf '</table></div>\n'
        done
        printf '</div>\n'
        printf '<p>Written by <code>bin/build.sh</code> &mdash; raw step logs in <code>build/step-NN.log</code>. Build finished at %s.</p>\n' "$end"
        printf '</div>\n'
        printf '</body>\n</html>\n'
    } > "$out"
}

# kill_tree PID — terminate PID and its whole DESCENDANT tree. A background
# step spawns its own worker pools (parse/report/publish children, awk,
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
    write_report "$REPORT" "$rc"
    printf '\nBuild report: %s\n' "$REPORT" >&2
    rm -rf "$BUILD_LOCK"
}
trap finalize_report EXIT

# --- stages 1-3, ONE LINEAR CHAIN (2026-09-11; until then two env chains ran
#     side by side). Every intra-chain dependency — transfer reports before
#     server reports, analyses before seen-in-server-log, publishes last —
#     holds in the order below. What overlaps: the TWO PARSES (bin/server/parse.sh
#     in the background beside bin/transfer/parse.sh — independent inputs and
#     caches; the transfer parse's trailing session-sites/expire-files re-marks
#     are suppressed via AXWAY_SKIP_SESSIONS=1/AXWAY_SKIP_EXPIRE=1 — they would
#     read the server cache mid-rewrite — and the explicit steps right after the
#     barrier do them instead), details.sh beside transfer phase 1 + the server
#     reports, dashboards beside day, and the two heaviest publishes.
#
# 1. parse — flow-manager.sh (config caches), the two parse.sh, then
#    session-sites.sh (learn the real subscription of UCx groups from the
#    server log's route lines, by the shared session id; re-derives the
#    transfer caches when it learned something), expire-files.sh (needs both
#    parse caches: flips Waiting files whose staged copy the File Maintenance
#    sweep deleted to Expired, _files.tsv cols 2/22), bookend-ok.sh,
#    seen-in-server-log.sh (marks the server-log-only entities blue) and
#    result.sh (fills the rest of the base result columns, preserving blue).
# 2. report — transfer BEFORE server and analyses (both read transfer report
#    outputs); the analyses step ends with seen-in-server-log (fresh pda.rpt);
#    dashboards + day after both areas.
# 3. publish — per-area publishes, then bin/build/publish.sh (the index pages
#    live in dirs the per-area scripts clear; it also writes the home).
export GENERATED_AT="$(date '+%Y-%m-%d %H:%M')"   # one footer stamp shared by all publish processes

# bg_step_start LABEL COMMAND [ARG...] / bg_step_wait — one step running in
# the background beside the foreground run_steps: output goes to its own log
# only (no console tee — two live streams would interleave), and the STEPS
# record is appended at WAIT time with the full start->finish span. At most
# ONE bg step may be in flight (single set of globals).
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

# ---- RUNTIME-ONLY: ingest delivered updates BEFORE anything parses ---------
# ONE inbox (2026-09-12, user request — the ~/cloud drop folder is gone): the
# git repo exchange-in.sh pulls (~/exchange/ by default; the report and every
# message call it "the inbox", never by name). It reads ONLY this
# environment's archives (input/environment.txt -> the prefixes acc* /
# prd*+prod*, bin/envlabel.sh; one repo = one environment, 2026-09-11):
# every <prefix>*.7z in it, unpacked with the st-reports password and routed
# onto input/ by st-reports-update.sh (the *.json exports told apart BY
# CONTENT and named subscriptions.json / partners.json -> flow-manager/,
# *.txt -> the input root, the two log exports RENAMED to
# logEntry_yyyy-mm-dd.csv / fileTransfer_yyyy-mm-dd.csv from their first
# record's date; existing files
# replaced), then removed from the repo and pushed. A bad archive is a
# WARNING that stays in place — the build goes on. The same repo receives
# the built site at the end (st-reports-archive.sh, st-reports-<env>.7z —
# never read as an inbox file).
# Runs BEFORE the have-config check just below, so an update delivering the
# checkout's first exports enables the build in the same run.
# Develop (the .sample-estate marker) never ingests — its estate is generated.
: > build/inbox.tsv   # the report's Inbox block: the inbox scripts append one line per outcome
if [ ! -f input/.sample-estate ]; then
    run_step "inbox: ingest ${ENV_INBOX:-<no prefix>}* .7z -> input/" bin/build/exchange-in.sh
    # RETENTION (2026-09-12, user request): the current and the past month of
    # log exports stay in input/; everything older moves to archive/ (repo
    # root, gitignored) as one 7z per file — after the inbox, before the
    # parse, so the parse sees the final set (archive-old-logs.sh)
    run_step "archive: log exports older than the past month -> archive/ (7z)" bin/build/archive-old-logs.sh
fi

if [ ! -f input/flow-manager/partners.json ] || [ ! -f input/flow-manager/subscriptions.json ]; then
    printf 'bin/build.sh: no input/flow-manager/{partners,subscriptions}.json — nothing to build (drop the FlowManager exports there, or run bin/flow-manager-synth.sh to synthesize them from the transfer logs).\n' >&2
    exit 1
fi
printf '\n=== building %s (report -> %s) ===\n' "${ENV_LABEL:-<unlabelled checkout — write input/environment.txt>}" "$REPORT" >&2

. "$(dirname "${BASH_SOURCE[0]}")/fastawk.sh"   # create data/.awkshim ONCE, before parallel children race for it
run_step "config: extract the configured entity lists"                    bin/flow-manager.sh

# ---- 1. parse ---------------------------------------------------------------
bg_step_start "parse: server log cache"                                   bin/server/parse.sh
run_step "parse: transfer log cache"                                      env AXWAY_SKIP_EXPIRE=1 AXWAY_SKIP_SESSIONS=1 bin/transfer/parse.sh
bg_step_wait
# the three server-log -> transfer joins, in this order: the session step
# may re-derive _files.tsv (resetting col 22), so expire re-marks after it
run_step "server log -> transfer: attribute UCx flows by session"         bin/session-sites.sh
run_step "server log -> transfer: mark expired staged files"              bin/expire-files.sh
run_step "server log -> transfer: settle failed Files by ok bookend"      bin/bookend-ok.sh
run_step "server log -> transfer: mark server-only entities blue"         bin/build/seen-in-server-log.sh
run_step "result: subscription outcomes -> base caches"                   bin/build/result.sh
# The blue step may APPEND SSH-logon-discovered names to the base rosters —
# names the server parse's mention scan (which ran above) did not know, so
# their detail pages would lose the server-log table on a from-scratch
# build. It drops a .rescan-mentions marker then; this re-run rescans
# exactly once (tokenize skips via the manifest; without the marker the
# whole call is a seconds-long no-op). 2026-08-15 fresh-build fix.
if [ -f data/server/cache/.rescan-mentions ]; then
    run_step "parse: rescan server mentions (appended names)"             bin/server/parse.sh
fi
# WENT-KAPUT EARLY (2026-08): its inputs are all parse-phase artifacts
# (_files.tsv, the mention caches, the xref pairs, the base colours), and
# its _kaput-evidence.tsv sidecar is the one stamp source failed.sh used
# to gain only in the evidence catch-up — running it here makes the
# reddening-session tables (and so the _srvsubs-map) FINAL on failed.sh's
# FIRST run, which lets the expensive details catch-up self-gate to a
# skip. The server-reports step re-invokes it later and skips (fresh).
run_step "report: went-kaput (early — the failed/details evidence)"       bin/server/reports/went-kaput.sh

# ---- 2. report --------------------------------------------------------------
# details.sh is the longest report step and only the transfer PHASE 2
# (showseen, ranking — they read its .rpts/slugmaps) needs it, so it runs
# in the BACKGROUND (2026-07) while phase 1 and then the server reports
# (whose rosters are phase-1 outputs) go through in the foreground.
bg_step_start "report: detail pages .rpt files"                           bin/transfer/reports/details.sh
run_step "report: transfer .rpt files (phase 1)"                          bin/transfer/reports.sh phase1
run_step "report: server .rpt files"                                      bin/server/reports.sh
bg_step_wait
run_step "report: transfer .rpt files (phase 2)"                          bin/transfer/reports.sh phase2
run_step "report: analyses .rpt files"                                    bin/analyses/reports.sh
# (seen-in-server-log runs INSIDE the analyses step now — last, after the
# pda.rpt it reads; cross-reference runs there too since the 2026-07 move
# of the Analyses-menu reports into bin/analyses/reports/)
# dashboards and day both need the two areas' reports and nothing of each
# other — disjoint output dirs, so they overlap (2026-08)
bg_step_start "report: dashboards .rpt files"                             bin/dashboards/reports.sh
run_step "report: day pages .rpt files"                                   bin/day/reports.sh
bg_step_wait

# ---- 3. publish -------------------------------------------------------------
# the two heaviest publishes write DISJOINT trees — docs/transfer vs
# docs/details — so the detail pages render in the background beside the
# report pages (2026-07; ~11 s off the critical path)
bg_step_start "publish: detail pages"                                     bin/transfer/publish-details.sh
run_step "publish: transfer report pages"                                 bin/transfer/publish.sh
bg_step_wait
run_step "publish: partner group pages"                                   bin/analyses/publish-partner-groups.sh
run_step "publish: server report pages"                                   bin/server/publish.sh
run_step "publish: analyses + coverage pages"                             bin/analyses/publish.sh
# THE EVIDENCE CATCH-UP (2026-08): three reports read evidence that steps
# AFTER them produce — failed.sh the kaput/boxes classifications (the
# server reports and publish-insights above), failing-reasons.sh reads
# failed.rpt, and details.sh the _srvsubs.tsv map failed.sh writes. On a
# fresh data/ their first runs happened before that evidence existed, and
# closing the gaps used to take a whole SECOND build. Re-running them
# here folds the convergence into THIS build. Self-gating: every input is
# cmp-guarded and listed in the consumer's skip_if_fresh deps, so a warm
# build skips each step in ~0 s.
run_step "report catch-up: failed subscriptions"                          bin/transfer/reports/failed.sh
run_step "report catch-up: error reasons"                                 bin/analyses/reports/failing-reasons.sh
# The DETAIL-PAGES catch-up runs in the BACKGROUND beside everything
# below (2026-08): it touches only data/…/details + docs/details,
# which none of the remaining steps read. With the _srvsubs-map split it
# fires only when the section membership/stamps truly changed (a fresh
# estate, a flow entering/leaving the server-failing set) — a reason-only
# rerun of failed.sh above leaves the map byte-identical and this pair
# skips in ~0 s.
bg_step_start "catch-up: detail pages (.rpt + publish)"                   bash -c 'bin/transfer/reports/details.sh && bin/transfer/publish-details.sh'
run_step "publish catch-up: analyses (failed pages)"                      bin/analyses/publish.sh
# THE BOXES-REASON CATCH-UP (2026-08): the Entities Error view's Reason
# column reads analyses/reports/_subs-boxes.tsv, which the analyses
# publish above (publish-insights.sh) writes AFTER the transfer publish
# already ran — on a fresh data/ the box-tier reasons would render blank
# until the NEXT build. Re-invoking the transfer publish here folds the
# catch-up into THIS build (it also re-renders the errors/ pages the
# failed.sh catch-up refreshed). Self-gating: the sidecar is cmp-guarded
# and a dep of the transfer stamp, so when its content did not change
# this step skips in ~0 s.
run_step "publish: transfer catch-up (boxes reasons)"                     bin/transfer/publish.sh
run_step "publish: dashboards"                                            bin/dashboards/publish.sh
run_step "publish: day pages"                                             bin/day/publish.sh
bg_step_wait
# the index pages + the home LAST: they live in dirs the per-area publishes
# clear, and the home reads every area's outputs
run_step "publish: index pages + home"                                    bin/build/publish.sh

# The DISPLAY RENAME sweep (2026-08-30) — the LAST page-touching step, so
# nothing rewrites a page behind it: input/rename.txt's presentation renames
# land on the rendered pages and the client data payloads; the caches and
# .rpt files keep the real values.
run_step "publish: display renames (input/rename.txt)"                    bin/build/display-rename.sh

# ---- RUNTIME-ONLY: the shareable site archive (2026-08-30) ------------------
# In a runtime checkout — recognized by the ABSENT input/.sample-estate
# marker, which only the develop repo carries — every completed build packs
# docs/ into build/st-reports-<env>_YYYY-MM-DD_HHMM.7z and pushes it into the
# OUTBOX (the inbox repo) as the stable st-reports-<env>.7z (2026-08-31, user
# request; the <env> since 2026-09-11; the ~/cloud copy went 2026-09-12).
if [ ! -f input/.sample-estate ]; then
    run_step "archive: st-reports-${ENV_KEY:-?} .7z -> build/ + outbox"  bin/build/st-reports-archive.sh
fi

# (The docs/build.html publish was REMOVED 2026-08-29 — the report lives only
# in build/index.html, written by the EXIT trap. The former stage-4 git
# commit + push was removed 2026-07: the build only renders; committing and
# pushing docs/ is a separate, manual decision.)

echo "Done." >&2
