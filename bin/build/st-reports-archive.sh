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

stamp=$(date '+%Y-%m-%d_%H%M')
out="build/st-reports_${stamp}.7z"
mkdir -p build
rm -f "$out"

# 7z's per-file listing is noise in the build report — keep its summary only.
# -mhe=on encrypts the archive HEADERS too: without the password not even the
# page names are listable.
7z a -t7z -mx9 -mhe=on -pboika "$out" docs >/dev/null

mkdir -p "$HOME/cloud"
cp "$out" "$HOME/cloud/"
echo "Wrote $out ($(du -h "$out" | cut -f1 | tr -d ' ')) and copied it to ~/cloud/." >&2
