#!/usr/bin/env bash
#
# archive-old-logs.sh — RUNTIME-ONLY build step (2026-09-12, user request):
# keep the CURRENT and the PAST month of log exports in input/, move every
# older one to archive/ (repo root, gitignored) compressed with 7z.
#
# Runs right after the inbox step and BEFORE anything parses, so the parse
# sees the final input set (the parse manifests notice the removed files
# and reparse in full — once a month, when the first old files go).
#
#   the cutoff   the first day of the past month (the build's own clock);
#                a file dated before it is old
#   a file's day its name — logEntry_yyyy-mm-dd.csv / fileTransfer_yyyy-mm-dd.csv
#                (the inbox rule; transferLog_yyyy-mm-dd.csv too) — else the
#                date of its first data record; a file whose day cannot be
#                read stays where it is
#   the archive  archive/<name>.7z, one per file (7z -t7z -mx3 -mmt=on: fast
#                on the multi-GB server exports, still ~6:1 on log text);
#                the archive is TESTED before the original is removed; an
#                existing archive of the same name is replaced — a
#                re-delivered export supersedes its older self
#
# Every failure is a WARNING that leaves the file in input/ — the build goes
# on with what it has. No 7z = nothing archived (a warning). Develop (the
# .sample-estate marker) never runs this — bin/build.sh gates the step — so
# the synthetic estate keeps its whole window.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ARCH=archive
cutoff=$(date -v-1m '+%Y-%m-01')   # macOS date: the first day of the past month
echo "archive: keeping the current and the past month — files dated before $cutoff move to $ARCH/ (7z)." >&2
command -v 7z >/dev/null 2>&1 || { echo "archive: WARNING - 7z not found (brew install p7zip) — nothing archived." >&2; exit 0; }

# csv_ymd FILE -> "yyyy-mm-dd" from the first data record (the inbox rule), "" when none
csv_ymd() {
    awk 'NR > 1 && match($0, /[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9]/) { s = substr($0, RSTART, RLENGTH); print substr(s, 7, 4) "-" substr(s, 1, 2) "-" substr(s, 4, 2); exit }
         NR > 6 { exit }' "$1"
}

moved=0; kept=0; failed=0; bytes=0
shopt -s nullglob
for f in input/server/*.csv input/transfer/*.csv; do
    name=$(basename "$f"); day=""
    case "$name" in
        *_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].csv) day=${name%.csv}; day=${day##*_} ;;
        *) day=$(csv_ymd "$f") ;;
    esac
    if [ -z "$day" ]; then echo "archive: $f carries no readable day — kept." >&2; kept=$((kept + 1)); continue; fi
    if [ "$day" \< "$cutoff" ]; then
        mkdir -p "$ARCH"
        out="$ARCH/$name.7z"
        rm -f "$out"
        # packed from the file's own directory so the archive holds the bare
        # name (a restore lands the file where it is unpacked, not under
        # input/<area>/)
        if ( cd "$(dirname "$f")" && 7z a -t7z -mx3 -mmt=on "$OLDPWD/$out" "$name" >/dev/null 2>&1 ) && 7z t "$out" >/dev/null 2>&1; then
            bytes=$((bytes + $(stat -f%z "$f")))
            rm -f "$f"; moved=$((moved + 1))
            echo "archive: $f ($day) -> $out ($(du -h "$out" | cut -f1 | tr -d ' '))" >&2
        else
            rm -f "$out"; failed=$((failed + 1))
            echo "archive: WARNING - could not pack $f — it stays in input/." >&2
        fi
    else
        kept=$((kept + 1))
    fi
done
shopt -u nullglob
echo "archive: $moved file(s) moved to $ARCH/ ($(awk -v b="$bytes" 'BEGIN { if (b < 1048576) printf "%d KB", b / 1024; else if (b < 1073741824) printf "%.1f MB", b / 1048576; else printf "%.2f GB", b / 1073741824 }') of exports), $kept kept, $failed left in place after a failure." >&2
exit 0
