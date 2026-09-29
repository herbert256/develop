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
#   docs/tools/build.html the SITE copy of the same report (2026-09-12, user
#                       request; the docs/ copies were removed 2026-08-29 and the
#                       report stayed local-only until then), linked from the
#                       sitemap Tools card — one render, two copies
#   (build/step-NN.log stays local)
#
# build/ is gitignored like data/ — a per-run local artifact, safe to delete.
#
# The stages (each is a separate script):
#
#   1. parse    bin/flow-manager.sh (pre-parse: input/flow-manager/*.json -> data/flow-manager/*.tsv
#               configured entity lists), then bin/transfer/parse.sh +
#               bin/server/parse.sh tokenize the input CSVs into the gitignored
#               caches (in full, every build — fresh-only since 2026-09-28),
#               then bin/session-sites.sh, bin/expire-files.sh, bin/bookend-ok.sh
#               (the three server-log -> transfer joins) and bin/build/result.sh
#               (fill the base result columns: green / red / orange)
#   2. report   bin/transfer/reports.sh, then bin/server/reports.sh, then
#               bin/analyses/reports.sh + bin/dashboards/reports.sh + bin/day/reports.sh
#               -> data/<area>/reports/*.rpt (no HTML). The dependencies are
#               ONE-way: server's site-failures.sh (and a dozen more) read
#               transfer's <entity>.rpt name rosters (a TRANSFER report output)
#               and `exit 1` if missing — so server must never run before
#               transfer (the unknown-* reports read the parse cache instead).
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
# EVERY BUILD IS A FRESH BUILD (2026-09-28, user decision — bin/fresh.sh
# folded in here, the incremental machinery removed): build/, data/ and docs/
# are wiped first, docs/ is re-seeded from the repo-root assets/, and every
# step runs in full from the raw inputs. Nothing checks whether an output is
# already up to date. The one thing carried over is data/.buildstats — the
# build report's input statistics, keyed by each export's name + size + mtime,
# so it can never go stale and a build does not re-read ~20 GB of exports
# just to fill in the report's figures.
#
# Usage (from any directory):
#
#   bin/build.sh        the whole chain for this checkout's one environment
#   bin/build.sh -h     this text
#
# No arguments: one repo = one environment. The report goes to
# build/index.html and docs/tools/build.html; the console of the whole run
# also lands in build/build.log.
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
# The report goes to build/index.html AND docs/tools/build.html (2026-09-12 —
# the site copy, linked from the sitemap Tools card; local-only 2026-08-29..09-12).
# ---- build lock -------------------------------------------------------------
# SYNTAX GATE (2026-09-27): `bash -n` over every bin/**/*.sh BEFORE anything
# is cleared or run — /bin/bash 3.2 exits 0 on a syntax error in a script
# that set an EXIT trap, so a broken report would otherwise go missing from
# a green build (bin/check-syntax.sh says why).
bin/check-syntax.sh || exit 1

# PREFLIGHT (2026-09-28 audit F05): every file the docs/ seed below copies
# must exist BEFORE anything is cleared — a missing asset used to fail the
# seed's cp AFTER data/ and docs/ were already gone: no site, no report.
SEED_ASSETS="style.css report.js slotchart.js all-files-search.js sub-files.js"
_miss=""
for _a in $SEED_ASSETS; do [ -f "assets/$_a" ] || _miss="$_miss assets/$_a"; done
[ -d assets/help ] || _miss="$_miss assets/help/"
if [ -n "$_miss" ]; then
    printf 'bin/build.sh: missing%s — nothing was cleared, the current site stays.\n' "$_miss" >&2
    exit 1
fi

BUILD_DIR="build"
REPORT="$BUILD_DIR/index.html"

# ONE build per checkout: a build wipes and rewrites build/, data/ and docs/,
# so two overlapping runs — a second terminal, an automation overlap — would
# pull the trees out from under each other. mkdir is the atomic primitive
# (bash-3.2-safe; macOS has no flock); the owner PID is recorded so a lock
# whose holder died is reclaimed automatically instead of demanding a manual
# rm. It lives in build/ — the one tree the wipe below empties AROUND it —
# and is released by the EXIT trap (finalize_report).
BUILD_LOCK="$BUILD_DIR/.buildlock"
mkdir -p "$BUILD_DIR"
# A STALE lock is reclaimed under a second atomic lock, .buildlock.reclaim,
# and its PID re-read while holding it (2026-09-29 audit F09: two builds that
# both saw the same dead PID could both remove-and-recreate the lock — the
# later rm took the first one's fresh lock — and both run). Whoever loses the
# reclaim lock, or finds a live owner on the re-read, refuses. A reclaim lock
# older than a minute is itself stale (its holder died in the few lines below).
# The release checks the PID too: only the owner removes the lock.
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    lock_pid=$(cat "$BUILD_LOCK/pid" 2>/dev/null || true)
    # a lock with no PID yet is being taken THIS instant (mkdir, then the pid
    # file): give its owner a moment instead of reclaiming a live lock
    if [ -z "$lock_pid" ]; then sleep 2; lock_pid=$(cat "$BUILD_LOCK/pid" 2>/dev/null || true); fi
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        printf 'bin/build.sh: another build (PID %s) is already running — refusing to overlap.\n' "$lock_pid" >&2
        exit 1
    fi
    [ -n "$(find "$BUILD_LOCK.reclaim" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rm -rf "$BUILD_LOCK.reclaim"
    if ! mkdir "$BUILD_LOCK.reclaim" 2>/dev/null; then
        printf 'bin/build.sh: another build is reclaiming the stale lock — refusing to overlap.\n' >&2
        exit 1
    fi
    lock_pid2=$(cat "$BUILD_LOCK/pid" 2>/dev/null || true)
    if [ -n "$lock_pid2" ] && [ "$lock_pid2" != "$lock_pid" ] && kill -0 "$lock_pid2" 2>/dev/null; then
        rmdir "$BUILD_LOCK.reclaim" 2>/dev/null || true
        printf 'bin/build.sh: another build (PID %s) took the lock first — refusing to overlap.\n' "$lock_pid2" >&2
        exit 1
    fi
    printf 'bin/build.sh: reclaiming stale build lock (PID %s not running).\n' "${lock_pid:-unknown}" >&2
    rm -rf "$BUILD_LOCK"
    if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
        rmdir "$BUILD_LOCK.reclaim" 2>/dev/null || true
        printf 'bin/build.sh: lost the lock race to another build — refusing to overlap.\n' >&2
        exit 1
    fi
    printf '%s\n' "$$" > "$BUILD_LOCK/pid"
    rmdir "$BUILD_LOCK.reclaim" 2>/dev/null || true
fi
printf '%s\n' "$$" > "$BUILD_LOCK/pid"
release_lock() { [ "$(cat "$BUILD_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$BUILD_LOCK"; return 0; }
# Until finalize_report takes the EXIT trap over (it needs the step machinery
# defined below), a failure in the wipe or the seed — a full disk, a signal —
# still releases the lock and says where the run died (2026-09-28 audit F05).
trap '_rc=$?; [ "$_rc" -eq 0 ] || printf "*** bin/build.sh: FAILED during the wipe/seed (exit %d) — no build report for this run.\n" "$_rc" >&2; release_lock' EXIT

# ---- THE WIPE: build/, data/, docs/ (formerly bin/fresh.sh) -----------------
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

# build/ goes FIRST — every prior run's report, step logs and (runtime) the
# st-reports archives (the stable-name copy in the outbox repo is the keeper),
# plus any trash an interrupted run left — everything but the lock just
# taken. It is cleared BEFORE the tee below opens build/build.log: a later
# clear would unlink the log this very run is writing.
echo "build.sh: clearing build/ ..." >&2
for _e in "$BUILD_DIR"/* "$BUILD_DIR"/.[!.]*; do
    [ -e "$_e" ] || continue
    [ "$_e" = "$BUILD_LOCK" ] || clear_tree "$_e"
done

# every line of this run also lands in build/build.log (the per-run log dir;
# never the repo root)
exec > >(tee "$BUILD_DIR/build.log") 2>&1


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
# Counting lines means reading every byte: the production server exports are
# ~20 GB, read purely to fill in a report line. So the answer is cached under a
# SIGNATURE of the file list (name + size + mtime): unchanged inputs are never
# re-read, and a changed one recounts that group only. It lives in
# data/.buildstats, the one directory the build's wipe carries over (the
# signature means it can never go stale).
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
# (data/.buildstats/loginv/): an unchanged export is never re-read, a new or
# changed one is scanned once.
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
                END { printf "%s\t%s\t%s\t%d\n", N, (first == "" ? "-" : first), (last == "" ? "-" : last), (NR > 0 ? NR - 1 : 0) }' "$f" > "$cache.tmp" && mv "$cache.tmp" "$cache"   # "-" for no stamp: an EMPTY field collapsed in the TAB read below (2026-09-28 fix)
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
# step_cpu FILE — the CPU seconds of a `times` dump (shell + children, user +
# system; "?" when the step left none — e.g. it exited through set -e)
step_cpu() {
    [ -s "$1" ] || { printf '?'; return 0; }
    awk 'function t(v,   m) { m = v; sub(/m.*/, "", m); sub(/^[0-9]+m/, "", v); sub(/s$/, "", v); return m * 60 + v }
         { s += t($1) + t($2) } END { printf "%.0fs", s }' "$1"
}
run_step() {
    local label=$1; shift
    STEP_N=$((STEP_N+1))
    local logf; logf=$BUILD_DIR/step-$(printf '%02d' "$STEP_N").log
    local start; start=$(date '+%H:%M:%S')
    printf '\n=== %d. %s ===\n' "$STEP_N" "$label" >&2
    local t0 t1 status=0
    t0=$(date +%s)
    # the step's CPU (2026-09-29, build speed): `times` in the pipeline's own
    # subshell — its shell + its reaped children; measured in THIS shell the
    # figure would also take in a background step reaped meanwhile
    { "$@"; _st=$?; times > "$logf.cpu"; exit "$_st"; } 2>&1 | tee "$logf" || status=$?   # pipefail: tee cannot mask a failure
    t1=$(date +%s)
    # \037 (unit separator), not '|', so a step whose command legitimately
    # contains a pipe can never misalign the 6-field read in the report.
    STEPS+=("$label"$'\037'"$*"$'\037'"$start"$'\037'"$((t1-t0))"$'\037'"$status"$'\037'"$logf")
    # the stage's duration ON THE CONSOLE (2026-09-27, user request): a
    # runtime build is judged by its console only, never by its report or logs
    printf -- '--- %d. %s: %ds  [cpu %s]\n' "$STEP_N" "$label" "$((t1-t0))" "$(step_cpu "$logf.cpu")" >&2
    if [ "$status" -ne 0 ]; then
        printf '*** step %d FAILED (exit %d): %s\n' "$STEP_N" "$status" "$label" >&2
        exit "$status"
    fi
}


# write_report FILE RC [NOTE] — render the report of the steps recorded so
# far. Called from the EXIT trap for the local build/index.html AND the site copy
# docs/tools/build.html (2026-09-12, user request; one render, two copies) — on success,
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
    local _st0; _st0=$(date +%s)
    shopt -s nullglob
    g=("input/server"/*.csv)
    r=$(count_stats "in-server" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r sfiles slines sbytes <<<"$r"
    g=("input/transfer"/*.csv)
    r=$(count_stats "in-transfer" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r tfiles tlines tbytes <<<"$r"
    # the server cache (~6 GB in production) is rewritten by every fresh build,
    # so a count_stats signature never hits: its parse writes its row count
    # to _parse.count (2026-09-29 audit) — read that when it is not older than
    # the cache, else count
    if [ -s data/server/cache/_parse.count ] && [ -f data/server/cache/_parse.tsv ] \
       && [ ! data/server/cache/_parse.count -ot data/server/cache/_parse.tsv ]; then
        cslines=$(head -1 data/server/cache/_parse.count | tr -dc '0-9'); csbytes=$(stat -f%z data/server/cache/_parse.tsv)
    else
        g=("data/server/cache/_parse.tsv")
        r=$(count_stats "cache-server" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r a cslines csbytes <<<"$r"
    fi
    g=("data/transfer/cache/_files.tsv")
    r=$(count_stats "cache-transfer" ${g[@]+"${g[@]}"}); IFS=$'\t' read -r a ctlines ctbytes <<<"$r"
    shopt -u nullglob
    # the per-export inventory for the report's bottom tables (log_inventory,
    # cached per file) — gathered here, BEFORE the clock, like the figures above
    local sinv tinv _keep _c
    sinv=$(log_inventory input/server); tinv=$(log_inventory input/transfer)
    # PRUNE the per-export inventory cache (2026-09-29 audit: 408 entries, 272
    # stale): keep only the signatures of the exports in input/ right now
    if [ -d "$BUILD_STATS_DIR/loginv" ]; then
        _keep=$(for _c in input/server/*.csv input/transfer/*.csv; do [ -f "$_c" ] && stat -f'%N %z %m' "$_c" | cksum | cut -d' ' -f1; done)
        for _c in "$BUILD_STATS_DIR"/loginv/*; do
            [ -f "$_c" ] || continue
            case $'\n'"$_keep"$'\n' in *$'\n'"${_c##*/}"$'\n'*) ;; *) rm -f "$_c" ;; esac
        done
    fi
    printf 'TIME %5ds  build report: input + cache statistics (%s)\n' "$(( $(date +%s) - _st0 ))" "$out" >&2
    t1=$(date +%s); total=$((t1 - BUILD_T0)); end=$(date '+%Y-%m-%d %H:%M:%S')
    # The report carries the site's standard fixed top bar (the help pages'
    # plain-link style — no dropdown machinery, the report must render even
    # when a build died before any publish). The report's own styles below
    # scope to .buildwrap so style.css keeps the body padding that clears the
    # fixed bar; without the stylesheet (a from-scratch clone) the page still
    # renders, just with a plain bar. The report is rendered ONCE with the
    # @B@ placeholder for its docs-root prefix and written TWICE (2026-09-12,
    # user request): build/index.html sits OUTSIDE docs/, so there @B@ becomes
    # ../docs/; docs/tools/build.html is the SITE copy (linked from the
    # sitemap's Tools card), one level below the root, so there @B@ is ../.
    # One render = identical timings in both copies.
    local base="@B@"
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
<title>Build report — Axway ST reports</title>
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
.bs th[scope=row]{background:none;color:inherit;font-weight:normal;text-align:left;border:0;padding:.1rem .9rem .1rem 0;white-space:nowrap}
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
            # (the three area start pages went 2026-09-29 — reports/index.html is THE start page)
            printf '<div class="topbar"><a class="brand" href="%sindex.html">%s</a><nav class="nav"><a href="%sreports/index.html">Reports</a><a href="%sdashboards/index.html">Dashboards</a></nav><span class="tr-group"><span class="tright">Build report</span></span></div>\n' \
                "$base" "$(printf '%s' "${ENV_LABEL:-Cloud}" | esc)" "$base" "$base"
        fi
        # THE TIMINGS LIVE IN THE TITLE (2026-08): start → end and the
        # duration are the h1's tail, not a fact block — the end collapses to
        # its time of day when the build stayed inside one calendar day. The
        # environment label sits between (2026-09-11).
        local endshow=$end
        [ "${end%% *}" = "${BUILD_START%% *}" ] && endshow=${end#* }
        printf '<div class="buildwrap">\n<h1>Build report &mdash; %s%s &rarr; %s &middot; %s</h1>\n' \
            "${ENV_LABEL:+$(printf '%s' "$ENV_LABEL" | esc) &mdash; }" "$BUILD_START" "$endshow" "$(hms "$total")"
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
        printf '<tr><th scope="row">Server logs</th><td class="v">%s files, %s lines, %s</td></tr>' "$(hnum "$sfiles")" "$(hnum "$slines")" "$(hbytes "$sbytes")"
        printf '<tr><th scope="row">Transfer logs</th><td class="v">%s files, %s lines, %s</td></tr></table></div>\n' "$(hnum "$tfiles")" "$(hnum "$tlines")" "$(hbytes "$tbytes")"
        printf '<div class="bs"><h3>Cached files</h3><table>'
        printf '<tr><th scope="row">Server <code>_parse.tsv</code></th><td class="v">%s lines, %s</td></tr>' "$(hnum "$cslines")" "$(hbytes "$csbytes")"
        printf '<tr><th scope="row">Transfer <code>_files.tsv</code></th><td class="v">%s lines, %s</td></tr></table></div>\n' "$(hnum "$ctlines")" "$(hbytes "$ctbytes")"
        printf '<div class="bs"><h3>Output</h3><table>'
        printf '<tr><th scope="row">HTML files</th><td class="v">%s</td></tr>' "$(hnum "$nhtml")"
        printf '<tr><th scope="row">Size</th><td class="v">%s</td></tr></table></div>\n' "$(hbytes "$obytes")"
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
                # \037, not TAB: an EMPTY archive column (the none/skipped notes) collapsed
                # and put the detail text in the Archive cell (2026-09-28 fix)
                while IFS=$'\037' read -r _io _ia _id; do
                    [ -n "$_io" ] || continue
                    case $_io in consumed) _cls=ok ;; failed) _cls=failed ;; *) _cls="" ;; esac
                    printf '<tr><td class="%s">%s</td><td><code>%s</code></td><td>%s</td></tr>\n' \
                        "$_cls" "$(printf '%s' "$_io" | esc)" "$(printf '%s' "$_ia" | esc)" "$(printf '%s' "$_id" | esc)"
                done < <(tr '\t' '\037' < build/inbox.tsv)
                printf '</table>\n'
            fi
        fi
        [ -n "$note" ] && printf '<p>%s</p>\n' "$note"
        printf '<table>\n<tr><th>#</th><th>Step</th><th>Command</th><th>Started</th><th>Duration</th><th>Status</th></tr>\n'
        # THE STEP'S OWN NUMBER, in step order (2026-09-28 fix): a background
        # step is RECORDED at its wait, so the record order is not the step
        # order and the running index disagreed with the console's "=== N."
        # and build/step-NN.log — the number is read back from that log name
        local rec label cmd start dur status logf i=0 sn
        local -a ORDERED=()
        while IFS= read -r rec; do ORDERED+=("$rec"); done < <(
            for rec in ${STEPS[@]+"${STEPS[@]}"}; do
                logf=${rec##*$'\037'}; sn=${logf##*step-}; sn=${sn%.log}
                printf '%d\037%s\n' "$((10#${sn:-0}))" "$rec"
            done | LC_ALL=C sort -t$'\037' -k1,1n | cut -d$'\037' -f2-)
        for rec in ${ORDERED[@]+"${ORDERED[@]}"}; do
            i=$((i+1))
            IFS=$'\037' read -r label cmd start dur status logf <<<"$rec"
            sn=${logf##*step-}; sn=$((10#${sn%.log}))
            printf '<tr><td class="r">%d</td><td>%s</td><td class="cmd">%s</td><td class="r">%s</td><td class="r">%s</td>' \
                "$sn" "$(printf '%s' "$label" | esc)" "$(printf '%s' "$cmd" | esc)" "$start" "$(hms "$dur")"
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
            for rec in ${ORDERED[@]+"${ORDERED[@]}"}; do
                IFS=$'\037' read -r label cmd start dur status logf <<<"$rec"
                sn=${logf##*step-}; sn=$((10#${sn%.log}))
                open=''; word='OK'
                if [ "$status" -ne 0 ]; then open=' open'; word="FAILED (exit $status)"; fi
                printf '<details%s><summary>%d. %s &mdash; %s &mdash; %s</summary><pre>' \
                    "$open" "$sn" "$(printf '%s' "$label" | esc)" "$(hms "$dur")" "$word"
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
                while IFS=$'\037' read -r _lname _lfirst _llast _llines; do   # \037: an empty cached field must not shift the rest
                    [ -n "$_lname" ] || continue
                    printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td class="r">%s</td></tr>\n' \
                        "$(printf '%s' "$_lname" | esc)" "$(printf '%s' "$_lfirst" | esc)" "$(printf '%s' "$_llast" | esc)" "$(hnum "${_llines:-0}")"
                done <<< "$(printf '%s' "$_inv" | tr '\t' '\037')"
            fi
            printf '</table></div>\n'
        done
        printf '</div>\n'
        printf '<p>Written by <code>bin/build.sh</code> &mdash; raw step logs in <code>build/step-NN.log</code>. Build finished at %s.</p>\n' "$end"
        printf '</div>\n'
        printf '</body>\n</html>\n'
    } > "$out.tmp"
    # the two copies (see `base` above): the local report and the site copy
    [ -n "${REPORT_PRELIM:-}" ] || sed 's#@B@#../docs/#g' "$out.tmp" > "$out"   # the preliminary render is the SITE copy only
    mkdir -p docs/tools && sed 's#@B@#../#g' "$out.tmp" > docs/tools/build.html
    rm -f "$out.tmp"
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
    # set -e stays ON inside an EXIT trap in bash 3.2 (2026-09-29 audit,
    # tested): one failing command in the report writer aborted the trap —
    # no report, the lock left behind, a green build exiting 1
    set +e
    if [ -n "${BG_PID:-}" ]; then kill_tree "$BG_PID"; wait "$BG_PID" 2>/dev/null || true; fi
    if [ -n "${BG2_PID:-}" ]; then kill_tree "$BG2_PID"; wait "$BG2_PID" 2>/dev/null || true; fi
    write_report "$REPORT" "$rc" || printf '*** bin/build.sh: the build report could not be written completely\n' >&2
    printf '\nBuild report: %s\n' "$REPORT" >&2
    release_lock
    exit "$rc"
}
trap finalize_report EXIT
# A SIGNAL ENDS THE BUILD AS A FAILURE (2026-09-28 fix): after an untrapped
# TERM/HUP bash 3.2 runs the EXIT trap with $? = 0, so a killed build was
# reported "Build succeeded" and released its lock while its step still ran.
# bash defers a trapped signal until the running foreground step returns, so
# the build stops right after it — lock held until then — with the FAILED
# report (128 + the signal number).
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- stages 1-3, ONE LINEAR CHAIN (2026-09-11; until then two env chains ran
#     side by side). Every intra-chain dependency — transfer reports before
#     server reports, publishes last —
#     holds in the order below. What overlaps: the TWO PARSES (bin/server/parse.sh
#     in the background beside bin/transfer/parse.sh — independent inputs and
#     caches; the server-log -> transfer steps run after the barrier, on the
#     finished server cache), details.sh beside transfer phase 1 + the server
#     reports, dashboards beside day, and the two heaviest publishes.
#
# 1. parse — flow-manager.sh (config caches), the two parse.sh, then
#    session-sites.sh (learn the real subscription of "Unknown" groups from the
#    server log's route lines, by the shared session id; re-derives the
#    transfer caches when it learned something), expire-files.sh (needs both
#    parse caches: flips Waiting files whose staged copy the File Maintenance
#    sweep deleted to Expired, _files.tsv cols 2/22), bookend-ok.sh and
#    result.sh (fills the base result columns).
# 2. report — transfer BEFORE server and analyses (both read transfer report
#    outputs);
#    dashboards + day after both areas.
# 3. publish — per-area publishes, then bin/build/publish.sh (the index pages
#    live in dirs the per-area scripts clear; it also writes the home).
# BYTE-ORDER COLLATION for every step (2026-09-29 audit): ~80 report sorts
# run without LC_ALL=C, so their tie order followed the machine's locale.
# LC_COLLATE only — LC_ALL would also switch LC_CTYPE, which the slugify tr
# reference path depends on for non-ASCII names.
export LC_COLLATE=C
# the BUILD ID (2026-09-29): render_rpt.awk stamps it as data-v on a
# subscription page's Files table — the cache-buster of its day list
# docs/search/all/s/<slug>.js, which is written after the pages render
export AXWAY_BUILD_ID="$BUILD_T0"

# bg_step_start LABEL COMMAND [ARG...] / bg_step_wait — one step running in
# the background beside the foreground run_steps: output goes to its own log
# only (no console tee — two live streams would interleave), and the STEPS
# record is appended at WAIT time with the full start->finish span. At most
# ONE bg step may be in flight (single set of globals).
BG_LABEL=""; BG_N=0; BG_CMD=""; BG_START=""; BG_T0=""; BG_LOGF=""; BG_PID=""
bg_step_start() {
    [ -z "${BG_PID:-}" ] || { printf '*** bin/build.sh: background slot 1 still busy — bg_step_wait missing before "%s"\n' "$1" >&2; exit 1; }
    BG_LABEL=$1; shift
    STEP_N=$((STEP_N+1))
    BG_N=$STEP_N
    BG_LOGF=$BUILD_DIR/step-$(printf '%02d' "$STEP_N").log
    BG_START=$(date '+%H:%M:%S'); BG_T0=$(date +%s); BG_CMD="$*"
    printf '\n=== %d. %s (in background) ===\n' "$STEP_N" "$BG_LABEL" >&2
    # the subshell records the step's OWN end (2026-09-27): measured at the
    # wait, a step that finished long before looked as slow as the
    # foreground work beside it
    rm -f "$BG_LOGF.end"
    ( "$@"; _bgst=$?; times > "$BG_LOGF.cpu"; date +%s > "$BG_LOGF.end"; exit "$_bgst" ) > "$BG_LOGF" 2>&1 &
    BG_PID=$!
}
bg_step_wait() {
    local status=0 t1 tw0 tw1
    tw0=$(date +%s)
    wait "$BG_PID" || status=$?
    BG_PID=""   # reaped: the EXIT trap must never kill_tree a PID the system may reuse (2026-09-29 audit)
    tw1=$(date +%s)
    t1=$tw1; [ -s "$BG_LOGF.end" ] && t1=$(cat "$BG_LOGF.end")
    STEPS+=("$BG_LABEL"$'\037'"$BG_CMD"$'\037'"$BG_START"$'\037'"$((t1-BG_T0))"$'\037'"$status"$'\037'"$BG_LOGF")
    # its duration + the per-script TIME lines (bin/timing.sh) its log holds
    # go to the console now — a background step never streams there; the
    # WAIT is how long the foreground chain blocked on it (0 = off the
    # critical path)
    grep '^TIME ' "$BG_LOGF" >&2 || true
    printf -- '--- %d. %s (in background): %ds, waited %ds  [cpu %s]\n' "$BG_N" "$BG_LABEL" "$((t1-BG_T0))" "$((tw1-tw0))" "$(step_cpu "$BG_LOGF.cpu")" >&2
    if [ "$status" -ne 0 ]; then
        printf '*** background step FAILED (exit %d): %s — output:\n' "$status" "$BG_LABEL" >&2
        tail -40 "$BG_LOGF" >&2
        exit "$status"
    fi
}
# bg2_step_start / bg2_step_wait — a SECOND background slot (2026-09-27,
# speed round 4), the same code over its own globals: the server mention
# scan runs beside the logon summary (slot 1) and the joins below.
BG2_LABEL=""; BG2_N=0; BG2_CMD=""; BG2_START=""; BG2_T0=""; BG2_LOGF=""; BG2_PID=""
bg2_step_start() {
    [ -z "${BG2_PID:-}" ] || { printf '*** bin/build.sh: background slot 2 still busy — bg2_step_wait missing before "%s"\n' "$1" >&2; exit 1; }
    BG2_LABEL=$1; shift
    STEP_N=$((STEP_N+1))
    BG2_N=$STEP_N
    BG2_LOGF=$BUILD_DIR/step-$(printf '%02d' "$STEP_N").log
    BG2_START=$(date '+%H:%M:%S'); BG2_T0=$(date +%s); BG2_CMD="$*"
    printf '\n=== %d. %s (in background) ===\n' "$STEP_N" "$BG2_LABEL" >&2
    rm -f "$BG2_LOGF.end"
    ( "$@"; _bgst=$?; times > "$BG2_LOGF.cpu"; date +%s > "$BG2_LOGF.end"; exit "$_bgst" ) > "$BG2_LOGF" 2>&1 &
    BG2_PID=$!
}
bg2_step_wait() {
    local status=0 t1 tw0 tw1
    tw0=$(date +%s)
    wait "$BG2_PID" || status=$?
    BG2_PID=""   # reaped (see bg_step_wait)
    tw1=$(date +%s)
    t1=$tw1; [ -s "$BG2_LOGF.end" ] && t1=$(cat "$BG2_LOGF.end")
    STEPS+=("$BG2_LABEL"$'\037'"$BG2_CMD"$'\037'"$BG2_START"$'\037'"$((t1-BG2_T0))"$'\037'"$status"$'\037'"$BG2_LOGF")
    grep '^TIME ' "$BG2_LOGF" >&2 || true
    printf -- '--- %d. %s (in background): %ds, waited %ds  [cpu %s]\n' "$BG2_N" "$BG2_LABEL" "$((t1-BG2_T0))" "$((tw1-tw0))" "$(step_cpu "$BG2_LOGF.cpu")" >&2
    if [ "$status" -ne 0 ]; then
        printf '*** background step FAILED (exit %d): %s — output:\n' "$status" "$BG2_LABEL" >&2
        tail -40 "$BG2_LOGF" >&2
        exit "$status"
    fi
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
    # (the RETENTION step — archive-old-logs.sh, moving the exports older than
    # the past month out of input/ into archive/<name>.7z — was REMOVED
    # 2026-09-28, user request: every delivered export stays in input/)
fi

if [ ! -f input/flow-manager/partners.json ] || [ ! -f input/flow-manager/subscriptions.json ]; then
    printf 'bin/build.sh: no input/flow-manager/{partners,subscriptions}.json — nothing to build (drop the FlowManager exports there, or run bin/flow-manager-synth.sh to synthesize them from the transfer logs).\n' >&2
    exit 1
fi
# THE WIPE comes only NOW (2026-09-29 audit): after the inbox step and the
# have-config check above, so a checkout missing its FlowManager exports (or
# an inbox step that dies) leaves the previous site and data untouched — the
# F05 class the preflight guards. Nothing above reads data/ or docs/.
# FAST CLEAR (2026-09-27, build-speed round 3): data/ and docs/ are RENAMED
# into build/.trash — one directory rename each, instant on one filesystem —
# and deleted in the BACKGROUND while the build runs (a runtime data/ holds a
# 3 GB cache and thousands of small files; docs/ ~10k pages). docs/ is pure
# build output, so a build can never leave a stale page behind.
move_aside() {   # $1 = dir
    [ -e "$1" ] || return 0
    mkdir -p "$BUILD_DIR/.trash"
    mv "$1" "$BUILD_DIR/.trash/$1.$$" 2>/dev/null || clear_tree "$1"
}
echo "build.sh: clearing data/ and docs/ ..." >&2
_fc0=$(date +%s)
move_aside data
move_aside docs
# ...EXCEPT the build report's input statistics (2026-09-27, speed round 6):
# data/.buildstats caches the line counts and the per-export First/Last
# inventory under each file's name + size + mtime, so it can never go stale —
# and without it every build re-read every export (~20 GB in production) just
# to fill in the report's figures.
if [ -d "$BUILD_DIR/.trash/data.$$/.buildstats" ]; then
    mkdir -p data && mv "$BUILD_DIR/.trash/data.$$/.buildstats" data/
fi
{ rm -rf "$BUILD_DIR/.trash" >/dev/null 2>&1 & } 2>/dev/null
echo "build.sh: data/ and docs/ moved aside in $(( $(date +%s) - _fc0 ))s (deleted in the background)." >&2

# ---- SEED docs/ (2026-08-29, user decision) ---------------------------------
# the hand-authored files from the repo-root assets/ (the build report lands
# back in docs/tools/build.html at the very end, from the EXIT trap —
# 2026-09-12). assets/ is the ONE place to edit style.css / report.js /
# slotchart.js / all-files-search.js / sub-files.js and
# the help pages (see assets/README.txt); .nojekyll and topbar-data.js stay
# generated (ensure_assets).
echo "build.sh: seeding docs/ from assets/ ..." >&2
mkdir -p docs/assets docs/help
_seed=(); for _a in $SEED_ASSETS; do _seed+=("assets/$_a"); done   # the preflight's list
cp "${_seed[@]}" docs/assets/
# (the dark theme — generated from the light rules by bin/darken-css.awk and
# appended here — went 2026-09-29 with its ◐ toggle, user request)
cp -R assets/help/. docs/help/

printf '\n=== building %s (report -> %s) ===\n' "${ENV_LABEL:-<unlabelled checkout — write input/environment.txt>}" "$REPORT" >&2

. "$(dirname "${BASH_SOURCE[0]}")/fastawk.sh"   # create data/.awkshim ONCE, before parallel children race for it
# ---- 1. parse ---------------------------------------------------------------
# THE SERVER PARSE STARTS BEFORE THE CONFIG STEP (2026-09-27, speed round 6):
# with AXWAY_SKIP_MENTIONS it only tokenizes + merges the exports — it reads
# no config — so it runs beside flow-manager.sh too, not only beside the
# transfer parse.
bg_step_start "parse: server log cache"                                   env AXWAY_SKIP_MENTIONS=1 bin/server/parse.sh
run_step "config: extract the configured entity lists"                    bin/flow-manager.sh
run_step "parse: transfer log cache"                                      bin/transfer/parse.sh
# THE DISCOVERED HOSTS FIRST (2026-09-29, build speed): result.sh's stage 0
# for the hosts alone, while the server parse is still running — so the
# mention scan below, which starts the moment that parse is done, matches
# them in its ONE pass. Until then the scan ran before result.sh discovered
# them, and every production build paid the appended-names RESCAN (~13 s,
# its discovered host is in the server log) plus a second result.sh run
# (~4 s) on the critical path; both steps below stay as the safety net. Safe
# here: nothing before result.sh reads base/_hosts.tsv; the session-sites
# re-derive can move a leg, so the `discover` step below re-checks.
run_step "result: discover the transfer-log hosts (before the mention scan)" bin/build/result.sh discover-hosts
bg_step_wait
# THE MENTION SCAN IN THE BACKGROUND (2026-09-27, speed round 4): the server
# parse above stops at the finished cache (AXWAY_SKIP_MENTIONS); its
# per-entity mention caches are built here, beside the logon summary and the
# server-log -> transfer joins below — which read only the cache — and are
# waited for before result.sh, their first reader (AXWAY_MENTIONS_ONLY: the
# mention build over the finished cache, the discovered hosts included).
bg2_step_start "parse: server mention caches"                               env AXWAY_MENTIONS_ONLY=1 bin/server/parse.sh
# THE LOGON SUMMARY (2026-09-27): built ONCE, in the background beside the
# server-log -> transfer steps below (it reads only the finished server parse
# cache) and waited for before the report stage — its two consumers, details.sh
# and logon.sh, used to compute it side by side (bin/build/logon-summary.sh).
# (2026-09-29: the server reports that read only the server cache were tried
# in this slot too, plain and niced — the server-log -> transfer steps are
# CPU-bound parallel scans, not idle time: session-sites went 8 -> 12-14 s,
# the mention scan 20 -> 25 s, the build +6..+11 s. Reverted.)
bg_step_start "server log: logon summary (per login + per address)"         bin/build/logon-summary.sh
# the three server-log -> transfer joins, in this order: the session step
# may re-derive _files.tsv (resetting col 22), so expire re-marks after it
run_step "server log -> transfer: attribute Unknown flows by session"     bin/session-sites.sh
# ... then the discovery's second half (result.sh `discover`, 2026-09-29):
# the host re-check against the transfer caches session-sites re-derived,
# and the transfer-log-discovered SUBSCRIPTIONS (never earlier: the re-derive
# reads base/_subscriptions.tsv). A change or an append drops the rescan
# marker — production discovers no subscription, so normally nothing fires.
run_step "result: discover the transfer-log subscriptions (+ re-check the hosts)" bin/build/result.sh discover
run_step "server log -> transfer: mark expired staged files"              bin/expire-files.sh
run_step "server log -> transfer: settle failed Files by ok bookend"      bin/bookend-ok.sh
# THE PUBLISHED FILE PAGES (2026-09-29, user request: per subscription only
# the newest OK File and the three newest Failed Files get a docs/files/
# page) — the outcomes are final now; every page writer and linker reads it
run_step "transfer: the published File pages (newest OK + 3 errors per subscription)" bin/transfer/filepages.sh
bg2_step_wait   # the mention caches: result.sh reads them
run_step "result: subscription outcomes -> base caches"                   bin/build/result.sh
# result.sh (discover_logged) may APPEND transfer-log-discovered names to the
# base rosters — names the server parse's mention scan (which ran above) did
# not know, so their detail pages would lose the server-log table on a
# from-scratch build. It drops a .rescan-mentions marker then, and the mention
# build runs once more — skipped inside when no server-log line holds one of
# the appended names (mention_rescan_needed). 2026-08-15 fresh-build fix.
if [ -f data/server/cache/.rescan-mentions ]; then
    run_step "parse: rescan server mentions (appended names)"             env AXWAY_MENTIONS_ONLY=1 bin/server/parse.sh
fi
# ... and when that rescan RAN (parse.sh leaves .rescanned), the colours are
# computed again (2026-09-28 fix): result.sh coloured the appended names
# before their Error/Warn rings existed, so a discovered flow with a server-log
# error after its last transfer stayed green. The second run discovers
# nothing new (the names are in the rosters now) and drops no marker.
if [ -f data/server/cache/.rescanned ]; then
    run_step "result: re-colour after the mention rescan"                 bin/build/result.sh
fi
# WENT-KAPUT EARLY (2026-08): its inputs are all parse-phase artifacts
# (_files.tsv, the mention caches, the xref pairs, the base colours), and
# its _kaput-evidence.tsv sidecar is the one stamp source failed.sh used
# to gain only in the evidence catch-up — running it here makes the
# reddening-session tables (and so the _srvsubs-map) FINAL on failed.sh's
# FIRST run, so details.sh (which reads that map) needs no second run. It
# runs ONLY here — bin/server/reports.sh leaves it out.
run_step "report: went-kaput (early — the failed/details evidence)"       bin/server/reports/went-kaput.sh

# ---- 2. report --------------------------------------------------------------
# details.sh is the longest report step and only the transfer PHASE 2
# (showseen, ranking — they read its .rpts/slugmaps) needs it, so it runs
# in the BACKGROUND (2026-07) while phase 1 and then the server reports
# (whose rosters are phase-1 outputs) go through in the foreground.
# (2026-09-28, speed round 27: details.sh runs in the SECOND slot, so the
# logon summary — still in the first, started after the server parse — is
# waited for only before the server reports: logon.sh there and fe-overview.sh
# in the analyses step read it, no phase-1 report does, and details.sh reads it
# only after its producers, ~40 s into its run, long after the summary ended —
# were it ever still running, ensure_logons would compute it again, slower but
# identical. bg2 is free here: the mention caches were waited for before
# result.sh, and dashboards + day start in it only after this wait.)
bg2_step_start "report: detail pages .rpt files"                          env AXWAY_WAIT_FAILED=1 bin/transfer/reports/details.sh
run_step "report: transfer .rpt files (phase 1)"                          bin/transfer/reports.sh phase1
bg_step_wait   # the logon summary: logon.sh (server reports) + fe-overview.sh (analyses) read it
run_step "report: server .rpt files"                                      bin/server/reports.sh
bg2_step_wait  # details.sh
# dashboards and day both need the two areas' reports and nothing of each
# other — disjoint output dirs, so they overlap (2026-08) — and since
# 2026-09-27 (speed round 8) they run BESIDE THE PUBLISHES below, in the
# second background slot, waited for right before the dashboards publish:
# nothing from here to there reads their outputs or rewrites their inputs
# (the transfer + server reports, the caches, colour/, the config). ONE
# exception, served first in the foreground: whether monitor.rpt EXISTS
# sets the top bar's Monitor link in every page a publish bakes (publish_lib
# TB_MON, folded into the ?v= stamp) — so monitor.sh runs here, once, and
# bin/dashboards/reports.sh leaves it out.
# STARTED RIGHT AFTER THE SERVER REPORTS (2026-09-29, build speed — until
# then after phase 2 + the analyses reports, ~6 s later, and the build then
# waited up to 8 s for it): their inputs are the transfer caches, phase-1
# reports (topview, anomalies, from-green-to-red, only-red), the server
# reports and their slot sidecars (topview, went-kaput, no-remote-dir/-files,
# pesit / event-queue / uc<n>-slots), colour/ and the config — all final here.
# Checked: phase 2 writes showseen / ranking, the analyses step data/analyses/,
# the cross-* and entity-search .rpt files and data/first-seen/ — none of
# them an input here, and nothing below reads data/day/ or overview.rpt
# before the wait. monitor.sh (the transfer cache only) moved up with them, so
# the dashboards' orphaned-.rpt.tmp sweep can never meet its atomic write.
run_step "report: dashboards monitor (the top bar's Monitor flag)"        bin/dashboards/reports/monitor.sh
bg2_step_start "report: dashboards + day pages .rpt files"                bash -c 'bin/dashboards/reports.sh & d=$!; bin/day/reports.sh; s=$?; wait "$d" || s=$?; exit "$s"'
run_step "report: transfer .rpt files (phase 2)"                          bin/transfer/reports.sh phase2
run_step "report: analyses .rpt files"                                    bin/analyses/reports.sh
# (cross-reference runs inside the analyses step since the 2026-07 move of
# the Analyses-menu reports into bin/analyses/reports/)

# ---- 3. publish -------------------------------------------------------------
# the two heaviest publishes write DISJOINT trees — docs/transfer vs
# docs/details — so the detail pages render in the background beside the
# report pages (2026-07; ~11 s off the critical path)
bg_step_start "publish: detail pages"                                     bin/transfer/publish-details.sh
# FIRSTPASS (2026-09-29): every transfer page but docs/files/ — the transfer
# catch-up below renders that directory from the .rpt sets the failed.sh
# catch-up rewrites, so it renders ONCE per build (nothing in between reads it)
run_step "publish: transfer report pages"                                 bin/transfer/publish.sh firstpass
bg_step_wait
run_step "publish: partner group pages"                                   bin/analyses/publish-partner-groups.sh
run_step "publish: server report pages"                                   bin/server/publish.sh
run_step "publish: analyses + coverage pages"                             bin/analyses/publish.sh
# THE EVIDENCE CATCH-UP (2026-08): reports that read evidence steps AFTER
# them produce — failed.sh the kaput/boxes classifications (the server
# reports and publish-insights above), failed-files.sh the reasons failed.sh
# classifies, failing-reasons.sh reads failed-files.rpt. Their first runs happen
# before that evidence exists, so they run AGAIN here, and the pages they
# feed are re-rendered below.
# failed.sh in its explicit CATCH-UP MODE (2026-09-29, build speed — the
# whole script ran again, both server-log passes included): only the
# server-failing set's reasons (the boxes sidecar), their pages, the two
# lists (their red-run columns read phase-1 peers) and the _srvsubs
# sidecars; the trace is at THE MODE in the script
run_step "report catch-up: failed subscriptions"                          bin/transfer/reports/failed.sh catchup
run_step "report catch-up: failed files"                                  bin/transfer/reports/failed-files.sh   # 2026-09-14: the reasons the failed.sh catch-up just classified
run_step "report catch-up: unknown transfers"                             bin/transfer/reports/unknown-transfers.sh   # 2026-09-29: the File-page links of the sets the failed.sh catch-up just rewrote
run_step "report catch-up: error reasons"                                 bin/analyses/reports/failing-reasons.sh
# (The DETAIL-PAGES re-render that ran here — 2026-08 — is GONE, 2026-09-29,
# build speed: the detail pages read the detail .rpt files, the slugmaps,
# the base colours and the published File-page set (_filepages.tsv, final
# before phase 1), never a failed.sh output, and failed.sh's catch-up mode no
# longer rewrites the error/File .rpt sets — a probe build compared the first
# render with the re-render: identical but for the display renames, which
# the sweep below applies to the final pages anyway.)
# THE TAIL IN PARALLEL (2026-09-29, build speed): the all files search, the
# dashboards and the day pages go to the second slot together, BESIDE the two
# publish catch-ups below (the tail left most cores idle, ~11 s in a row).
# Checked: the all files search reads the data rosters the failed.sh
# catch-up above settled (errors/ + files/ .rpt sets, the slugmap), never a
# rendered page; dashboards + day read their own .rpt (the slot's previous
# step) — none reads what the catch-ups write, and every writer owns its own
# docs/ directory (topbar-data.js: an atomic rename, _asset_put).
bg2_step_wait   # the dashboards + day reports (started before the publishes)
bg2_step_start "publish: all files search + dashboards + day pages"         bash -c 'bin/analyses/publish-all-files.sh & a=$!; bin/dashboards/publish.sh && bin/day/publish.sh; s=$?; wait "$a" || s=$?; exit "$s"'
# THE TWO PUBLISH CATCH-UPS run in their explicit CATCH-UP MODE (2026-09-29;
# until then both re-ran their whole script): each re-renders ONLY the pages
# that read what the report catch-ups above rewrote — the dependency trace is
# in each script (THE CATCH-UP MODE). The analyses one: Configured
# subscriptions (failed-files.rpt), Failed Subscriptions + its All view and
# Error reasons (its box-reason sidecar is not recomputed — see below).
# THE BOXES-REASON CATCH-UP (2026-08): the Entities Error view's Reason
# column reads analyses/reports/_subs-boxes.tsv, which the analyses
# publishes above (publish-insights.sh) write AFTER the transfer publish
# already ran — on a fresh data/ the box-tier reasons would render blank
# until the NEXT build — and failed-sub-all.rpt + _srvsubs.tsv, which the
# failed.sh catch-up rewrote. The transfer catch-up mode re-renders the
# Subscriptions entity views, the Failed files page (failed-files.rpt) and
# the whole docs/files/ tree (the errors/ + files/ .rpt sets failed.sh wrote;
# its ONLY render in the build — the first pass above is `firstpass`) —
# nothing else of the transfer area.
# THE TWO CATCH-UPS SIDE BY SIDE (2026-09-29, build speed — they ran one
# after the other, ~4 s each, in the half-idle tail). The box-reason sidecar
# _subs-boxes.tsv — the one thing the transfer catch-up took from the
# analyses one — is NOT recomputed any more: the analyses publish above wrote
# it, and nothing it reads has changed since (the report-stage lists, the
# server reports, _kaput-evidence.tsv and failed.sh's _errpage-evidence.tsv,
# which the failed.sh CATCH-UP MODE leaves as the full run wrote it — a
# catch-up that rewrote the evidence would need the sidecar step back here).
# (The `catchup-pages` name went 2026-09-29: `catchup` is that mode now.)
# Checked: the analyses
# catch-up renders docs/analyses/ only (Configured subscriptions, Failed
# Subscriptions + its All view, Error reasons — from failed-files.rpt,
# failed*.rpt, failing-reasons.rpt) and reads no page; the transfer catch-up
# renders docs/transfer/entities/subscription-*, failed-files,
# unknown-transfers and docs/files/ from the data/ trees and reads no
# docs/analyses/ page; both share only topbar-data.js, written atomically.
run_step "publish catch-ups: analyses (failed pages) + transfer (boxes reasons)" bash -c 'bin/analyses/publish.sh catchup & a=$!; bin/transfer/publish.sh catchup; s=$?; wait "$a" || s=$?; exit "$s"'
# (THE ALL FILES SEARCH — 2026-09-27, user request, "Implementation 3, all
# files": one day shard per data day + the bloom-filter manifest, and the
# search/all-files.html page — runs in the second slot started above, after
# the failed.sh catch-up: its rows link the files/ pages that catch-up
# settled, so the rosters it reads are final. Outside the per-area
# publishes, like publish-partner-groups.sh — a manual re-publish runs it too.)
bg2_step_wait   # the all files search + dashboards + day pages
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
    # THE BUILD REPORT MUST BE IN THE PACK (2026-09-21, user report: the sitemap
    # link to the build page did not work on the delivered site). The site
    # copy docs/tools/build.html is written by the EXIT trap — AFTER this
    # step packed docs/ — and the build's wipe removed the previous one, so
    # the archive carried the Tools-card link without its page. A PRELIMINARY
    # site copy is rendered right here, from the steps recorded so far (all
    # but this one); the EXIT trap overwrites it with the complete report
    # on the build's own site. It leaves build/index.html to the final
    # render.
    REPORT_PRELIM=1
    write_report "$REPORT" 0 "This copy was written just before the site was packed for the outbox, so the delivered site carries its build report: the archive step and the final timings are not in it &mdash; the site of the build itself has the complete report."
    unset REPORT_PRELIM
    run_step "archive: st-reports-${ENV_KEY:-?} .7z -> build/ + outbox"  bin/build/st-reports-archive.sh
fi

# (The report is written by the EXIT trap to build/index.html AND, since
# 2026-09-12, to the site copy docs/tools/build.html — linked from the sitemap
# Tools card. The former stage-4 git commit + push was removed 2026-07: the
# build only renders; committing and pushing docs/ is a separate, manual
# decision.)

echo "Done." >&2
