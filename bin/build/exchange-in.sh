#!/usr/bin/env bash
#
# exchange-in.sh — RUNTIME-ONLY build step (re-created 2026-09-06, user
# request): the git exchange repo at ~/exchange/ as an INBOX for export
# archives, read at the START of the runtime build, before anything parses.
#
#   1. `git pull` the repo (rebase, autostash). A failed pull — offline, a
#      conflict — is a WARNING: nothing is ingested this build.
#   2. Every *.7z in the repo whose name STARTS WITH acc or prd (any case,
#      any directory of the checkout) is an update: acc = acceptance,
#      prd = production. Each is handed to bin/build/st-reports-update.sh,
#      which unpacks it with input/secrets/st-reports.pass and copies its
#      files — at the root of the archive or in any directory inside it —
#      onto input/<environment>/, existing files REPLACED:
#          *.json            -> input/<env>/flow-manager/
#          *.txt             -> input/<env>/
#          transferLog*.csv  -> input/<env>/transfer/
#          logEntry*.csv     -> input/<env>/server/
#      (a repo-layout tree inside the archive is copied as such; anything
#      else is listed and ignored). The archive is deleted only after a
#      fully successful copy.
#   3. Every consumed archive is removed from the repo: commit + push. A
#      failed push is a WARNING; the commit goes out with the next build.
#
# An archive that cannot be ingested (wrong password, corrupt, holds nothing
# routable) is a WARNING: it stays in the repo untouched and the build goes
# on with the inputs it has — an inbox failure must never take the site
# down (2026-09-05: a refused archive stopped the build after the docs tree
# had already been wiped). Fix or remove the file and rebuild.
#
# No git repo at ~/exchange/ = the quiet no-op (AXWAY_EXCHANGE_DIR overrides
# the location, mainly for tests). st-reports-archive.sh pushes the BUILT
# SITE back into the same repo at the end of the build (st-reports.7z) —
# that name never matches acc*/prd*, so it is never read as an inbox file.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

EX="${AXWAY_EXCHANGE_DIR:-$HOME/exchange}"
EXD="${EX/#$HOME/~}"
if [ ! -d "$EX/.git" ]; then
    echo "exchange-in: no git repo at $EXD — skipping (clone the exchange repo there to enable)." >&2
    exit 0
fi

if ! git -C "$EX" pull --rebase --autostash --quiet 2>/dev/null; then
    echo "exchange-in: WARNING - git pull failed in $EXD (offline? a conflict?) — nothing ingested this build." >&2
    exit 0
fi

# ---- the inbox: acc*.7z / prd*.7z anywhere in the checkout ------------------
updates=()
while IFS= read -r -d '' f; do updates+=("$f"); done < <(
    find "$EX" -path "$EX/.git" -prune -o -type f \( -iname 'acc*.7z' -o -iname 'prd*.7z' \) -print0 | sort -z)
if [ ${#updates[@]} -eq 0 ]; then
    echo "exchange-in: pulled $EXD — no acc*/prd* .7z to ingest." >&2
    exit 0
fi

consumed=()
failed=()
for f in "${updates[@]}"; do
    rel="${f#$EX/}"
    echo "exchange-in: ingesting $rel ..." >&2
    # the shared intake: unpack, route, copy, delete the archive on success;
    # its non-zero exit (the file stays) is a warning here, never a build stop
    if bin/build/st-reports-update.sh "$f"; then
        consumed+=("$rel")
    else
        echo "exchange-in: WARNING - $rel was NOT ingested; it stays in $EXD — fix or remove it, then rebuild." >&2
        failed+=("$rel")
    fi
done

if [ ${#consumed[@]} -gt 0 ]; then
    git -C "$EX" add -u -- "${consumed[@]}"
    if git -C "$EX" commit --quiet -m "consumed by the runtime build $(date '+%Y-%m-%d %H:%M'): ${consumed[*]}"; then
        if git -C "$EX" push --quiet 2>/dev/null; then
            echo "exchange-in: ${#consumed[@]} archive(s) consumed and removed from the exchange repo (pushed): ${consumed[*]}" >&2
        else
            echo "exchange-in: WARNING - push failed (offline?) — the removal of ${consumed[*]} is committed locally and goes out with the next build." >&2
        fi
    else
        echo "exchange-in: WARNING - nothing to commit after consuming ${consumed[*]} (already removed?)." >&2
    fi
fi
[ ${#failed[@]} -eq 0 ] || echo "exchange-in: ${#failed[@]} archive(s) left in place: ${failed[*]}" >&2
exit 0
