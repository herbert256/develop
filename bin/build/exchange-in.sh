#!/usr/bin/env bash
#
# exchange-in.sh — RUNTIME-ONLY build step (re-created 2026-09-06, user
# request): the git exchange repo at ~/exchange/ as an INBOX for export
# archives, read at the START of the runtime build, before anything parses.
#
#   1. `git pull` the repo (rebase, autostash). A failed pull — offline, a
#      conflict — is a WARNING: nothing is ingested this build.
#   2. Every *.7z in the repo whose name starts with THIS CHECKOUT'S
#      environment prefix (input/environment.txt via bin/envlabel.sh:
#      Acceptance -> acc*, Production -> prd* / prod*; any case, any
#      directory of the checkout) is an update. One repo = one environment
#      (2026-09-11): the acceptance checkout leaves the prd* archives alone
#      and vice versa, so the two runtime builds share one inbox safely. A
#      MULTI-VOLUME archive (prd-update.7z.001, .002, .003 …) counts once,
#      through its first part — 7z picks the other parts up by itself, and a
#      successful ingest removes every part (2026-09-06, user request). Each
#      is handed to bin/build/st-reports-update.sh, which unpacks it with
#      input/secrets/st-reports.pass and copies its files — at the root of
#      the archive or in any directory inside it — onto input/, existing
#      files REPLACED:
#          *.json            -> input/flow-manager/
#          *.txt             -> input/            (environment.txt never)
#          transferLog*.csv  -> input/transfer/
#          logEntry*.csv     -> input/server/
#      (a repo-layout tree inside the archive is copied as such; an archive
#      that carries the OTHER environment's tree is refused). The archive is
#      deleted only after a fully successful copy.
#   3. Every consumed archive is removed from the repo: commit + push. A
#      failed push is a WARNING; the commit goes out with the next build.
#
# An archive that cannot be ingested (wrong password, corrupt, holds nothing
# routable, names the other environment) is a WARNING: it stays in the repo
# untouched and the build goes on with the inputs it has — an inbox failure
# must never take the site down (2026-09-05: a refused archive stopped the
# build after the docs tree had already been wiped). Fix or remove the file
# and rebuild.
#
# No git repo at ~/exchange/ = the quiet no-op (AXWAY_EXCHANGE_DIR overrides
# the location, mainly for tests). A checkout without an inbox prefix (no
# input/environment.txt, or a label other than Acceptance/Production) reads
# nothing. st-reports-archive.sh pushes the BUILT SITE back into the same
# repo at the end of the build (st-reports-<env>.7z) — that name never
# matches a prefix, so it is never read as an inbox file.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
source bin/envlabel.sh   # ENV_LABEL / ENV_INBOX / env_inbox_find

EX="${AXWAY_EXCHANGE_DIR:-$HOME/exchange}"
EXD="${EX/#$HOME/~}"
# the build report's Inbox block (build/inbox.tsv): source ⇥ status ⇥ name ⇥ detail
inbox_note() { [ -d build ] && printf 'exchange\t%s\t%s\t%s\n' "$1" "$2" "$3" >> build/inbox.tsv; return 0; }
export AXWAY_INBOX_SOURCE=exchange   # st-reports-update.sh notes its outcome under this source
if [ -z "$ENV_INBOX" ]; then
    echo "exchange-in: input/environment.txt says '${ENV_LABEL:-<missing>}' — no inbox prefix for it (Acceptance or Production expected); the exchange repo is not read." >&2
    inbox_note skipped "" "no inbox prefix for environment '${ENV_LABEL:-<missing>}'"
    exit 0
fi
pfxs=$(printf '%s' "$ENV_INBOX" | sed 's/ /*.7z, /g; s/$/*.7z/')   # "acc*.7z" / "prd*.7z, prod*.7z"
if [ ! -d "$EX/.git" ]; then
    echo "exchange-in: no git repo at $EXD — skipping (clone the exchange repo there to enable)." >&2
    inbox_note skipped "" "no git repo at $EXD"
    exit 0
fi

if ! git -C "$EX" pull --rebase --autostash --quiet 2>/dev/null; then
    echo "exchange-in: WARNING - git pull failed in $EXD (offline? a conflict?) — nothing ingested this build." >&2
    inbox_note skipped "" "git pull failed (offline? a conflict?)"
    exit 0
fi

# ---- the inbox: this environment's <prefix>*.7z anywhere in the checkout ---
updates=()
while IFS= read -r -d '' f; do updates+=("$f"); done < <(env_inbox_find "$EX" "$EX/.git")
if [ ${#updates[@]} -eq 0 ]; then
    echo "exchange-in: pulled $EXD — no $pfxs to ingest ($ENV_LABEL)." >&2
    inbox_note none "" "pulled $EXD: no $pfxs"
    exit 0
fi

consumed=()   # every repo path to drop (a multi-volume archive contributes all its parts)
narch=0       # archives ingested
failed=()
for f in "${updates[@]}"; do
    rel="${f#$EX/}"
    # a multi-volume archive: every part shares the name up to the numeric
    # suffix; the intake deletes them all, git must drop them all
    parts=("$rel")
    case "$f" in
        *.7z.001) parts=(); for pf in "${f%.001}".[0-9][0-9][0-9]; do [ -f "$pf" ] && parts+=("${pf#$EX/}"); done ;;
    esac
    echo "exchange-in: ingesting $rel ..." >&2
    # the shared intake: unpack, route, copy, delete the archive on success;
    # its non-zero exit (the file stays) is a warning here, never a build stop
    if bin/build/st-reports-update.sh "$f"; then
        consumed+=("${parts[@]}"); narch=$((narch + 1))
    else
        echo "exchange-in: WARNING - $rel was NOT ingested; it stays in $EXD — fix or remove it, then rebuild." >&2
        failed+=("$rel")
    fi
done

if [ ${#consumed[@]} -gt 0 ]; then
    git -C "$EX" add -u -- "${consumed[@]}"
    if git -C "$EX" commit --quiet -m "consumed by the $ENV_LABEL runtime build $(date '+%Y-%m-%d %H:%M'): ${consumed[*]}"; then
        if git -C "$EX" push --quiet 2>/dev/null; then
            echo "exchange-in: $narch archive(s) consumed and removed from the exchange repo (pushed): ${consumed[*]}" >&2
        else
            echo "exchange-in: WARNING - push failed (offline?) — the removal of ${consumed[*]} is committed locally and goes out with the next build." >&2
        fi
    else
        echo "exchange-in: WARNING - nothing to commit after consuming ${consumed[*]} (already removed?)." >&2
    fi
fi
[ ${#failed[@]} -eq 0 ] || echo "exchange-in: ${#failed[@]} archive(s) left in place: ${failed[*]}" >&2
exit 0
