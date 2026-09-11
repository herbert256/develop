#!/usr/bin/env bash
#
# bin/runtime.sh — refresh one or more RUNTIME checkouts from this DEVELOP
# repo, then rebuild each site from its own (real) data:
#
#   bin/runtime.sh /path/to/runtime-acceptance [/path/to/runtime-production ...]
#
#   1. validate EVERY target first (nothing is touched until all pass)
#   2. sync the develop-maintained code into each checkout: bin/ and assets/
#      (rsync -a --delete: exec bits kept, deletions propagate) plus
#      .gitattributes; remove CLAUDE.md / ARCHITECTURE.md there — a runtime
#      repo carries only its own README.md (it is operated, never developed;
#      AI never reads or edits it)
#   3. run each checkout's bin/fresh.sh IN SEQUENCE — a full cold rebuild of
#      its site (wipes its data/ + docs/, reparses its real exports). Never in
#      parallel: every runtime build reads and pushes the shared ~/exchange
#      repo and ~/cloud drop. A failed build does not stop the loop (the
#      sites are independent, and the code is already synced everywhere); the
#      exit status is 1 when any build failed.
#
# One repo = one environment (2026-09-11): a runtime checkout names its
# environment in input/environment.txt (Acceptance / Production) — required
# here, so the retired two-environment checkout (nested input/<env>/, no
# label) is refused rather than half-built.
#
# NEVER synced: input/ (the runtime repo's REAL, irreplaceable exports, its
# own policy files and its environment.txt — develop's are sample-flavoured),
# README.md, .gitignore (runtime keeps ignoring its *.csv bulk), data/, docs/,
# build/ — and, inside bin/, THIS SCRIPT and bin/sample/ (develop-only
# tooling): the sync excludes them, and --delete-excluded removes any copy an
# earlier refresh left in the runtime checkout.
# No git operations either way: committing in a runtime repo stays manual.
#
set -euo pipefail
DEV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -lt 1 ]; then
    echo "usage: bin/runtime.sh <runtime-checkout> [<runtime-checkout> ...]" >&2
    exit 2
fi

# ---- 1. validate every target ---------------------------------------------
RTS=()
for arg in "$@"; do
    RT="$(cd "$arg" 2>/dev/null && pwd)" || { echo "runtime.sh: $arg is not a directory." >&2; exit 2; }
    [ "$RT" != "$DEV" ] || { echo "runtime.sh: $arg is this develop repo." >&2; exit 2; }
    for seen in ${RTS[@]+"${RTS[@]}"}; do
        [ "$seen" != "$RT" ] || { echo "runtime.sh: $arg given twice." >&2; exit 2; }
    done
    # the target must BE a runtime checkout of this project
    [ -d "$RT/.git" ] && [ -d "$RT/input" ] \
        || { echo "runtime.sh: $RT does not look like a checkout of this project (.git, input/)." >&2; exit 2; }
    [ -s "$RT/input/environment.txt" ] \
        || { echo "runtime.sh: $RT has no input/environment.txt — a runtime checkout names its environment there (one line: Acceptance or Production)." >&2; exit 2; }
    # the sample-estate marker means SAMPLE data — i.e. a develop checkout, not
    # a runtime repo; refuse rather than turn a second develop into a runtime
    [ ! -f "$RT/input/.sample-estate" ] \
        || { echo "runtime.sh: $RT carries input/.sample-estate (a develop checkout?) — refusing." >&2; exit 2; }
    # never yank scripts out from under a RUNNING build there
    if [ -d "$RT/data/.buildlock" ]; then
        lock_pid=$(cat "$RT/data/.buildlock/pid" 2>/dev/null || true)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "runtime.sh: a build (PID $lock_pid) is running in $RT — try again when it is done." >&2
            exit 1
        fi
    fi
    RTS+=("$RT")
done

# ---- 2. sync the code into every checkout ---------------------------------
for RT in "${RTS[@]}"; do
    echo "runtime.sh: syncing bin/ and assets/ -> $RT ..." >&2
    # /runtime.sh and /sample/ are anchored to the bin/ transfer root; the
    # --delete-excluded also REMOVES them from the target when a prior refresh
    # copied them there
    rsync -a --delete --delete-excluded --exclude=.DS_Store \
          --exclude=/runtime.sh --exclude=/sample/ "$DEV/bin/" "$RT/bin/"
    rsync -a --delete --exclude=.DS_Store "$DEV/assets/" "$RT/assets/"
    cp "$DEV/.gitattributes" "$RT/.gitattributes"
    # the runtime repo documents itself with README.md alone
    rm -f "$RT/CLAUDE.md" "$RT/ARCHITECTURE.md"
done

# ---- 3. rebuild each site, one after the other ----------------------------
failed=()
for RT in "${RTS[@]}"; do
    label=$(head -1 "$RT/input/environment.txt")
    echo "runtime.sh: rebuilding $RT ($label) via bin/fresh.sh ..." >&2
    if ( cd "$RT" && bin/fresh.sh ); then
        echo "runtime.sh: $RT rebuilt OK — report: $RT/build/index.html" >&2
    else
        echo "runtime.sh: *** $RT build FAILED (see $RT/build/index.html) — continuing with the next checkout." >&2
        failed+=("$RT")
    fi
done
if [ ${#failed[@]} -gt 0 ]; then
    echo "runtime.sh: ${#failed[@]} of ${#RTS[@]} rebuild(s) FAILED: ${failed[*]}" >&2
    exit 1
fi
echo "runtime.sh: all ${#RTS[@]} runtime checkout(s) rebuilt." >&2
