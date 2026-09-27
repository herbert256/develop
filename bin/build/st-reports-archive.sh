#!/usr/bin/env bash
#
# st-reports-archive.sh — RUNTIME-ONLY build step (2026-08-30): pack the
# rendered site into a password-protected archive and, since 2026-08-31
# (user request), commit + push it into the OUTBOX — the same git repo the
# inbox step pulls, at ~/exchange/ — under the stable name st-reports-<env>.7z:
#
#   build/st-reports-<env>_YYYY-MM-DD_HHMM.7z   (7z -mx9, whole docs/ tree)
#   ~/exchange/st-reports-<env>.7z              (stable name, committed + pushed)
#
# (The ~/cloud/ copy is gone — 2026-09-12, user request: the outbox is the
# repo alone; build/ keeps the stamped copy until the next fresh build.)
# Invoked by bin/build.sh at the end of a successful chain, and ONLY in the
# runtime checkout (build.sh gates on the ABSENT input/.sample-estate marker
# — the develop repo carries the marker and skips this). A fresh build
# (bin/fresh.sh) clears build/ wholesale, archives included (2026-08-30);
# *.7z is gitignored in both repos.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
source bin/envlabel.sh   # ENV_KEY names the archives
[ -n "$ENV_KEY" ] || { echo "st-reports-archive: input/environment.txt missing or empty — the archive name carries the environment (st-reports-<env>_<stamp>.7z) so the two runtime repos never overwrite each other's copy; write the label (Acceptance / Production) and rebuild." >&2; exit 1; }

# 7zz (the official 7-Zip, brew install sevenzip) first, p7zip's 7z as the
# fallback — see the compression note below
if command -v 7zz >/dev/null 2>&1; then Z7=7zz
elif command -v 7z >/dev/null 2>&1; then Z7=7z
else echo "st-reports-archive: neither 7zz nor 7z found (brew install sevenzip)." >&2; exit 1; fi
[ -d docs ] || { echo "st-reports-archive: no docs/ tree to archive." >&2; exit 1; }

# ---- the archive password (2026-08-31, user request) ------------------------
# NEVER hardcoded (the old literal lives on in git history — treat it as
# burned; archives made before this change still open with it). The secret
# lives in input/secrets/st-reports.pass:
#   - input/ because a secret is IRREPLACEABLE: rm -rf data/ stays safe, and
#     the develop->runtime sync (bin/acc.sh, bin/prd.sh) never touches input/ — each checkout keeps its own.
#   - the folder SELF-IGNORES (its own .gitignore says "*"), so it stays out
#     of git in any checkout without relying on the top-level .gitignore
#     (which carries input/secrets/ too, belt and braces).
#   - generated ON FIRST RUN (openssl rand -base64 32 — ~256 bits), then
#     KEPT: one stable password opens every archive ever uploaded. chmod 600.
# Passing -p on the command line is visible in `ps` while 7z runs — 7z has no
# non-interactive password-from-file mode — acceptable on a single-user
# machine, and the reason the value at least never sits in the script.
PASSF="input/secrets/st-reports.pass"
if [ ! -s "$PASSF" ]; then
    mkdir -p input/secrets
    printf '*\n' > input/secrets/.gitignore
    openssl rand -base64 32 > "$PASSF"
    chmod 600 "$PASSF"
    echo "st-reports-archive: NEW archive password generated in $PASSF — back it up; every archive from now on needs it." >&2
fi
chmod 600 "$PASSF" 2>/dev/null || true
pass=$(cat "$PASSF")

stamp=$(date '+%Y-%m-%d_%H%M')
out="build/st-reports-${ENV_KEY}_${stamp}.7z"
mkdir -p build
rm -f "$out"

# 7z's per-file listing is noise in the build report — keep its summary only.
# -mhe=on encrypts the archive HEADERS too: without the password not even the
# page names are listable.
# BLOCKED LZMA2 (2026-09-27, build-speed round 1): -mx9 alone is ONE LZMA2
# block for a site this size, so 7-Zip cannot use more than two threads —
# 45-48 s single-handedly on production, the build's last step. 64 MB blocks
# (c=64m, the -mx9 64 MB dictionary kept) compress up to five blocks at once:
# on the develop site 1.4x faster for +6% size, several times faster on
# production's ~300 MB. p7zip 17's 7z reads the result (tested); the p7zip
# fallback keeps the old, unblocked call.
_al0=$(date +%s)   # phase laps on the build console (2026-09-27, speed round 5)
_alap() { local _t1; _t1=$(date +%s); printf 'TIME %5ds  archive: %s\n' "$((_t1 - _al0))" "$1" >&2; _al0=$_t1; }
if [ "$Z7" = 7zz ]; then
    7zz a -t7z -mx9 -mmt=on -m0=LZMA2:d=64m:c=64m -mhe=on -p"$pass" "$out" docs >/dev/null
else
    7z a -t7z -mx9 -mhe=on -p"$pass" "$out" docs >/dev/null
fi

echo "Wrote $out ($(du -h "$out" | cut -f1 | tr -d ' '))." >&2
_alap "7z"

# ---- the OUTBOX copy (2026-08-31, user request) ------------------------------
# The same archive into the outbox repo under the STABLE name
# st-reports-<env>.7z, committed and pushed: the receiving side always finds
# the newest site there (a timestamped name per build would grow the repo
# without bound — the stamp lives in build/ and in the pages themselves).
# Pull first so a concurrent drop on the other side never makes the push
# non-fast-forward; every failure here is a WARNING — the archive is already
# safe in build/, and a local commit goes out with the next build's push. No
# git repo there = quiet skip.
EX="${AXWAY_EXCHANGE_DIR:-$HOME/exchange}"
if [ -d "$EX/.git" ]; then
    cp "$out" "$EX/st-reports-${ENV_KEY}.7z"
    git -C "$EX" pull --rebase --autostash --quiet 2>/dev/null \
        || echo "outbox: WARNING - pull failed (offline?) — pushing on top of the local state." >&2
    _alap "outbox copy + pull"
    if [ -n "$(git -C "$EX" status --porcelain)" ]; then
        git -C "$EX" add -A
        git -C "$EX" commit --quiet -m "st-reports-${ENV_KEY} ${stamp}"
    fi
    _alap "outbox commit"
    if git -C "$EX" push --quiet 2>/dev/null; then
        echo "outbox: st-reports-${ENV_KEY}.7z pushed." >&2
    else
        echo "outbox: WARNING - push failed (offline?) — the commit is local and goes out with the next build." >&2
    fi
    _alap "outbox push"
else
    echo "outbox: no git repo at ${EX/#$HOME/~} — the archive stays in build/ only." >&2
fi
