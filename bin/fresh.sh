#!/usr/bin/env bash
#
# fresh.sh — the FULL FRESH BUILD in one command (2026-08-29): wipe every
# derived tree and rebuild both environments from the raw inputs.
#
#   1. clear build/ — every prior run's report, step logs and (runtime) the
#                     st-reports archives (2026-08-30: their keepers are the
#                     ~/cloud/ copies). Cleared BEFORE the log tee below
#                     opens build/fresh.log — clearing after would unlink
#                     the very file this run is writing.
#   2. clear data/  — every parse cache, report and stamp (documented safe:
#                     input/ holds everything irreplaceable)
#   3. clear docs/  — the whole published site
#   4. seed docs/   — the hand-authored files from the repo-root assets/
#                     (style.css / report.js / slotchart.js / file-search.js
#                     -> docs/assets/, assets/help/ -> docs/help/)
#   5. bin/build.sh — the whole chain, both environments (build.sh re-clears
#                     its scope and re-seeds on its own; the explicit steps
#                     above make THIS script's contract obvious and cover a
#                     build.sh that dies before its own clear)
#
# No arguments — a fresh build is always BOTH environments (a scoped wipe
# would delete the other env's data without rebuilding it).
#
# Usage:
#   bin/fresh.sh
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ $# -gt 0 ]; then
    printf 'bin/fresh.sh takes no arguments (a fresh build is always both environments).\n' >&2
    exit 2
fi

# refuse to pull the trees out from under a RUNNING build (rm -rf data would
# also delete its lock) — same liveness test as build.sh's own lock
if [ -d data/.buildlock ]; then
    lock_pid=$(cat data/.buildlock/pid 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        printf 'bin/fresh.sh: a build (PID %s) is running — refusing to wipe under it.\n' "$lock_pid" >&2
        exit 1
    fi
fi

# Finder can drop a .DS_Store into a directory WHILE rm walks the tree — the
# rm then fails with "Directory not empty" although everything else is gone.
# Sweep the .DS_Store files and try again; the LAST attempt runs with stderr
# visible, so a genuine failure (permissions, an open file) still aborts the
# script with rm's own message (set -e).
clear_tree() {
    local d=$1 attempt
    for attempt in 1 2; do
        rm -rf "$d" 2>/dev/null && return 0
        find "$d" -name .DS_Store -delete 2>/dev/null || true
    done
    rm -rf "$d"
}

# build/ goes FIRST, before the tee below opens build/fresh.log — a later
# clear would unlink the log this very run is writing.
echo "fresh.sh: clearing build/ ..." >&2
clear_tree build

# every line of this run — fresh.sh's own steps and the whole build behind
# the exec — also lands in build/fresh.log (the per-run log dir; never the
# repo root). The tee holds the fd across the exec, so build.sh's output
# keeps flowing into it.
mkdir -p build
exec > >(tee build/fresh.log) 2>&1

echo "fresh.sh: clearing data/ and docs/ ..." >&2
clear_tree data
clear_tree docs

echo "fresh.sh: seeding docs/ from assets/ ..." >&2
mkdir -p docs/assets docs/help
cp assets/style.css assets/report.js assets/slotchart.js assets/file-search.js docs/assets/
cp -R assets/help/. docs/help/

exec bin/build.sh
