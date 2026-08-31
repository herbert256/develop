#!/usr/bin/env bash
#
# exchange-in.sh — RUNTIME-ONLY build step (2026-08-31, user request): the
# GIT-BASED exchange inbox, run FIRST in the build (before the ~/cloud intake
# and the HAVE_ACC/HAVE_PROD detection).
#
#   1. `git pull` the exchange repo at ~/exchange/ (rebase, autostash; a
#      failed pull — offline, a conflict — is a WARNING: the build continues
#      with the checkout as-is and update.7z is not touched).
#   2. When ~/exchange/update.7z exists: ingest it exactly like the ~/cloud
#      intake — bin/build/st-reports-update.sh with the file as its argument
#      (unpack with input/secrets/st-reports.pass, copy the six
#      input/<env>/{flow-manager,server,transfer}/ directories onto the
#      checkout, delete the archive only after a fully successful copy; a bad
#      archive FAILS the build and the file stays).
#   3. Commit + push the consumption (the deleted update.7z), so the sending
#      side sees it was taken. A failed push is a WARNING — the commit is
#      local and goes out with the next build's push.
#
# No git repo at ~/exchange/ = the quiet no-op (this machine has no exchange
# clone; AXWAY_EXCHANGE_DIR overrides the location, mainly for tests).
# st-reports-archive.sh pushes the BUILT SITE back into the same repo at the
# end of the build (st-reports.7z, stable name).
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

EX="${AXWAY_EXCHANGE_DIR:-$HOME/exchange}"
if [ ! -d "$EX/.git" ]; then
    echo "exchange-in: no git repo at $EX — skipping (clone the exchange repo there to enable)." >&2
    exit 0
fi

if ! git -C "$EX" pull --rebase --autostash --quiet; then
    echo "exchange-in: WARNING - git pull failed in $EX (offline? a conflict?) — continuing with the checkout as-is; update.7z is NOT touched this build." >&2
    exit 0
fi

UPD="$EX/update.7z"
if [ ! -f "$UPD" ]; then
    echo "exchange-in: pulled $EX — no update.7z to ingest." >&2
    exit 0
fi

# the shared intake (unpack, copy the six dirs, delete on success; a failure
# exits 1 and keeps the file — the build stops rather than parse stale input)
bin/build/st-reports-update.sh "$UPD"

if [ -n "$(git -C "$EX" status --porcelain)" ]; then
    git -C "$EX" add -A
    git -C "$EX" commit --quiet -m "update.7z consumed by the runtime build $(date '+%Y-%m-%d %H:%M')"
fi
if git -C "$EX" push --quiet 2>/dev/null; then
    echo "exchange-in: consumption pushed to the exchange repo." >&2
else
    echo "exchange-in: WARNING - push failed (offline?) — the consumption commit is local and goes out with the next build." >&2
fi
