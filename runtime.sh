#!/usr/bin/env bash
#
# runtime.sh — refresh the RUNTIME repo from this DEVELOP repo, then rebuild
# its site from its own (real) data:
#
#   ./runtime.sh /path/to/runtime
#
#   1. sync the develop-maintained code into the runtime checkout:
#      bin/ and assets/ (rsync -a --delete: exec bits kept, deletions
#      propagate) plus .gitattributes
#   2. remove CLAUDE.md / ARCHITECTURE.md there — the runtime repo carries
#      only its own README.md (it is operated, never developed; AI never
#      reads or edits it)
#   3. exec the runtime repo's bin/fresh.sh — full cold rebuild of its site
#      (wipes its data/ + docs/, reparses its real exports)
#
# NEVER synced: input/ (the runtime repo's REAL, irreplaceable exports and
# its own policy files — develop's are sample-flavoured), README.md,
# .gitignore (runtime keeps ignoring its *.csv bulk), data/, docs/, build/,
# and this script itself (root-level, outside bin/ — that is deliberate).
# No git operations either way: committing in runtime stays manual.
#
set -euo pipefail
DEV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ne 1 ]; then
    echo "usage: ./runtime.sh <path-to-runtime-repo>" >&2
    exit 2
fi
RT="$(cd "$1" 2>/dev/null && pwd)" || { echo "runtime.sh: $1 is not a directory." >&2; exit 2; }

# ---- sanity: the target must BE a runtime checkout of this project ----------
[ -d "$RT/.git" ] && [ -d "$RT/input" ] && [ -f "$RT/bin/build.sh" ] \
    || { echo "runtime.sh: $RT does not look like a repo of this project (.git, input/, bin/build.sh)." >&2; exit 2; }
[ "$RT" != "$DEV" ] \
    || { echo "runtime.sh: target equals this develop repo." >&2; exit 2; }
# the sample-estate marker means SAMPLE data — i.e. a develop checkout, not
# the runtime repo; refuse rather than turn a second develop into a runtime
[ ! -f "$RT/input/.sample-estate" ] \
    || { echo "runtime.sh: $RT carries input/.sample-estate (a develop checkout?) — refusing." >&2; exit 2; }

# ---- never yank scripts out from under a RUNNING build there ----------------
if [ -d "$RT/data/.buildlock" ]; then
    lock_pid=$(cat "$RT/data/.buildlock/pid" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        echo "runtime.sh: a build (PID $lock_pid) is running in $RT — try again when it is done." >&2
        exit 1
    fi
fi

echo "runtime.sh: syncing bin/ and assets/ -> $RT ..." >&2
rsync -a --delete --exclude=.DS_Store "$DEV/bin/" "$RT/bin/"
rsync -a --delete --exclude=.DS_Store "$DEV/assets/" "$RT/assets/"
cp "$DEV/.gitattributes" "$RT/.gitattributes"

# the runtime repo documents itself with README.md alone
rm -f "$RT/CLAUDE.md" "$RT/ARCHITECTURE.md"

echo "runtime.sh: rebuilding the runtime site (bin/fresh.sh) ..." >&2
cd "$RT"
exec bin/fresh.sh
