#!/usr/bin/env bash
#
# bin/runtime-lib.sh — the develop -> runtime refresh, shared by bin/acc.sh
# and bin/prd.sh (sourced, not run). One repo = one environment (2026-09-11):
# the two runtime checkouts sit BESIDE this develop repo in the same parent
# directory — ../runtime-acceptance and ../runtime-production — so the two
# wrappers take no argument (they replaced the path-taking bin/runtime.sh,
# 2026-09-11, user request).
#
# runtime_refresh NAME   (NAME = runtime-acceptance | runtime-production)
#   1. validate the target: ../NAME exists, is a checkout of this project
#      (.git + input/), names its environment in input/environment.txt, is
#      not a develop checkout (no input/.sample-estate) and has no build
#      running
#   2. sync the develop-maintained code into it: bin/ and assets/ (rsync -a
#      --delete: exec bits kept, deletions propagate) plus .gitattributes;
#      remove CLAUDE.md / ARCHITECTURE.md there — a runtime repo carries only
#      its own README.md (it is operated, never developed; AI never reads or
#      edits it)
#   3. exec the checkout's bin/fresh.sh — a full cold rebuild of its site
#      (wipes its data/ + docs/, reparses its real exports); its exit status
#      is the wrapper's, its report the checkout's build/index.html
#
# NEVER synced: input/ (the REAL, irreplaceable exports, the policy files and
# environment.txt), README.md, .gitignore (a runtime repo keeps ignoring its
# *.csv bulk), data/, docs/, build/ — and, inside bin/, the develop-only
# tooling: acc.sh, prd.sh, this file and bin/sample/; the sync excludes them
# and --delete-excluded removes any copy an earlier refresh left behind.
# No git operations either way: committing in a runtime repo stays manual.
# Run acc.sh and prd.sh one AFTER the other, never at the same time — both
# builds read and push the shared ~/exchange repo and ~/cloud drop.
#
runtime_refresh() {
    local name=$1 me=${0##*/} dev rt lock_pid
    dev="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    rt="$(cd "$dev/../$name" 2>/dev/null && pwd)" \
        || { echo "$me: $dev/../$name is not a directory — the runtime checkouts sit beside this develop repo." >&2; exit 2; }
    # the target must BE a runtime checkout of this project
    [ -d "$rt/.git" ] && [ -d "$rt/input" ] \
        || { echo "$me: $rt does not look like a checkout of this project (.git, input/)." >&2; exit 2; }
    [ -s "$rt/input/environment.txt" ] \
        || { echo "$me: $rt has no input/environment.txt — a runtime checkout names its environment there (one line: Acceptance or Production)." >&2; exit 2; }
    # the sample-estate marker means SAMPLE data — i.e. a develop checkout, not
    # a runtime repo; refuse rather than turn a second develop into a runtime
    [ ! -f "$rt/input/.sample-estate" ] \
        || { echo "$me: $rt carries input/.sample-estate (a develop checkout?) — refusing." >&2; exit 2; }
    # never yank scripts out from under a RUNNING build there
    if [ -d "$rt/data/.buildlock" ]; then
        lock_pid=$(cat "$rt/data/.buildlock/pid" 2>/dev/null || true)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "$me: a build (PID $lock_pid) is running in $rt — try again when it is done." >&2
            exit 1
        fi
    fi

    echo "$me: syncing bin/ and assets/ -> $rt ..." >&2
    # the develop-only tooling is anchored to the bin/ transfer root; the
    # --delete-excluded also REMOVES it from the target when a prior refresh
    # copied it there
    rsync -a --delete --delete-excluded --exclude=.DS_Store \
          --exclude=/acc.sh --exclude=/prd.sh --exclude=/runtime-lib.sh --exclude=/runtime.sh --exclude=/sample/ \
          "$dev/bin/" "$rt/bin/"
    rsync -a --delete --exclude=.DS_Store "$dev/assets/" "$rt/assets/"
    cp "$dev/.gitattributes" "$rt/.gitattributes"
    # the runtime repo documents itself with README.md alone
    rm -f "$rt/CLAUDE.md" "$rt/ARCHITECTURE.md"

    echo "$me: rebuilding $rt ($(head -1 "$rt/input/environment.txt")) via bin/fresh.sh ..." >&2
    cd "$rt"
    exec bin/fresh.sh
}
