#!/usr/bin/env bash
#
# exchange-in.sh — RUNTIME-ONLY build step (2026-08-31, user request): the
# GIT-BASED exchange inbox, run FIRST in the build (before the ~/cloud intake
# and the HAVE_ACC/HAVE_PROD detection).
#
#   1. `git pull` the exchange repo at ~/exchange/ (rebase, autostash; a
#      failed pull — offline, a conflict — is a WARNING: the build continues
#      with the checkout as-is and no archive is touched).
#   2. EVERY *.7z in ~/exchange/ except the outbound st-reports*.7z is an
#      update (2026-09-04: the inbox used to accept only the name update.7z,
#      and deliveries named input.7z / logEntry_09-03.7z / Downloads.7z sat
#      there unread while the site stayed stale). Each is ingested exactly
#      like the ~/cloud intake — bin/build/st-reports-update.sh with the file
#      as its argument (unpack with input/secrets/st-reports.pass, copy the
#      exports onto input/<env>/{flow-manager,server,transfer}/ — the repo
#      tree or loose CSV/JSON files routed by name, see that header — and
#      delete the archive only after a fully successful copy; a bad archive
#      FAILS the build and the file stays).
#   3. Commit + push the consumption (the deleted archives), so the sending
#      side sees they were taken. A failed push is a WARNING — the commit is
#      local and goes out with the next build's push.
#
# No git repo at ~/exchange/ = the quiet no-op (this machine has no exchange
# clone; AXWAY_EXCHANGE_DIR overrides the location, mainly for tests).
# st-reports-archive.sh pushes the BUILT SITE back into the same repo at the
# end of the build (st-reports.7z, stable name) — never an inbox file.
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
    echo "exchange-in: WARNING - git pull failed in $EX (offline? a conflict?) — continuing with the checkout as-is; no archive is touched this build." >&2
    exit 0
fi

# ---- the inbox: every *.7z that is not our own outbound site archive -------
updates=()
for f in "$EX"/*.7z; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
        st-reports.7z|st-reports_*.7z) continue ;;
    esac
    updates+=("$f")
done
if [ ${#updates[@]} -eq 0 ]; then
    echo "exchange-in: pulled $EX — no *.7z update to ingest." >&2
    exit 0
fi

# the shared intake (unpack, copy, delete on success; a failure exits 1 and
# keeps the file — the build stops rather than parse stale input)
names=()
for f in "${updates[@]}"; do
    echo "exchange-in: ingesting $(basename "$f") ..." >&2
    bin/build/st-reports-update.sh "$f"
    names+=("$(basename "$f")")
done

if [ -n "$(git -C "$EX" status --porcelain)" ]; then
    git -C "$EX" add -A
    git -C "$EX" commit --quiet -m "${names[*]} consumed by the runtime build $(date '+%Y-%m-%d %H:%M')"
fi
if git -C "$EX" push --quiet 2>/dev/null; then
    echo "exchange-in: consumption of ${names[*]} pushed to the exchange repo." >&2
else
    echo "exchange-in: WARNING - push failed (offline?) — the consumption commit is local and goes out with the next build." >&2
fi
