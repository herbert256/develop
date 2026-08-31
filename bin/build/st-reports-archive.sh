#!/usr/bin/env bash
#
# st-reports-archive.sh — RUNTIME-ONLY build step (2026-08-30): pack the
# rendered site into a password-protected archive and drop a copy in the
# cloud-sync folder:
#
#   build/st-reports_YYYY-MM-DD_HHMM.7z   (7z -mx9, whole docs/ tree)
#   ~/cloud/st-reports_YYYY-MM-DD_HHMM.7z (copy)
#
# Invoked by bin/build.sh at the end of a successful chain, and ONLY in the
# runtime checkout (build.sh gates on the ABSENT input/.sample-estate marker
# — the develop repo carries the marker and skips this). A fresh build
# (bin/fresh.sh) clears build/ wholesale, archives included (2026-08-30) —
# the ~/cloud/ copies are the keepers; *.7z is gitignored in both repos.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

command -v 7z >/dev/null 2>&1 || { echo "st-reports-archive: 7z not found (brew install p7zip)." >&2; exit 1; }
[ -d docs ] || { echo "st-reports-archive: no docs/ tree to archive." >&2; exit 1; }

# ---- the archive password (2026-08-31, user request) ------------------------
# NEVER hardcoded (the old literal lives on in git history — treat it as
# burned; archives made before this change still open with it). The secret
# lives in input/secrets/st-reports.pass:
#   - input/ because a secret is IRREPLACEABLE: rm -rf data/ stays safe, and
#     bin/runtime.sh never syncs input/ — each checkout keeps its own.
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
out="build/st-reports_${stamp}.7z"
mkdir -p build
rm -f "$out"

# 7z's per-file listing is noise in the build report — keep its summary only.
# -mhe=on encrypts the archive HEADERS too: without the password not even the
# page names are listable.
7z a -t7z -mx9 -mhe=on -p"$pass" "$out" docs >/dev/null

mkdir -p "$HOME/cloud"
cp "$out" "$HOME/cloud/"
echo "Wrote $out ($(du -h "$out" | cut -f1 | tr -d ' ')) and copied it to ~/cloud/." >&2
